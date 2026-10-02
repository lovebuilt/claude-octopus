#!/usr/bin/env bash
# Functional policy discovery and citation checks using disposable repositories.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "feature policy"
test_case "actual Python helper acceptance"
if python3 - "$PROJECT_ROOT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(sys.argv[1])
HELPER = REPO / "scripts/helpers/feature-policy.py"
WRAPPER = REPO / "scripts/lib/feature-policy.sh"


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="octopus-policy-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / "project with spaces"
        self.project.mkdir()

    def write(self, path, text):
        file = self.project / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding="utf-8")
        return file

    def call(self, *args, success=True):
        proc = subprocess.run([sys.executable, str(HELPER), *map(str, args)],
                              capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0 if success else 1, proc.stderr + proc.stdout)
        return json.loads(proc.stdout)

    def bind(self, configured=None):
        args = ["bind", "--root", self.project]
        if configured is not None:
            args.extend(["--configured", configured])
        return self.call(*args)

    def test_empty_configured_policy_is_omitted(self):
        self.write("AGENTS.md", "Preserve files.\n")
        selected = self.bind("")
        self.assertEqual(selected["source"], "AGENTS.md")
        self.assertFalse(any(item["path"] == "" for item in selected["candidates"]))
        self.assertFalse(any("unsafe-path ()" in warning for warning in selected["warnings"]))

    def evidence(self):
        self.write("AGENTS.md", "# Guidance\nDo not deploy automatically.\nPreserve unrelated files.\n")
        snapshot = self.bind()
        plan = self.write("plan.md", "# Plan\nDeploy automatically.\nRun local checks.\n")
        finding = {"source": "AGENTS.md", "digest": snapshot["digest"],
                   "line_start": 2, "line_end": 2, "quote": "Do not deploy automatically.",
                   "plan_digest": hashlib.sha256(plan.read_bytes()).hexdigest(),
                   "plan_line_start": 2, "plan_line_end": 2, "plan_action": "Deploy automatically.",
                   "description": "The proposed action contradicts the cited policy."}
        return snapshot, plan, finding

    def verify(self, snapshot, plan, findings, success=True):
        policy_file = self.root / "runtime-policy.json"
        findings_file = self.root / "findings.json"
        policy_file.write_text(json.dumps(snapshot))
        findings_file.write_text(json.dumps(findings))
        return self.call("verify", "--policy", policy_file, "--plan", plan,
                         "--findings", findings_file, success=success)

    def test_agents_only_and_no_creation(self):
        file = self.write("AGENTS.md", "Keep source history.\n")
        before = set(self.project.rglob("*"))
        result = self.bind()
        self.assertEqual(result["source"], "AGENTS.md")
        self.assertEqual(result["digest"], hashlib.sha256(file.read_bytes()).hexdigest())
        self.assertEqual(result["passages"], [{"line": 1, "text": "Keep source history."}])
        self.assertEqual(before, set(self.project.rglob("*")))

    def test_full_precedence_and_passed_over_sources(self):
        paths = [".specify/memory/constitution.md", "docs/policy.md", "AGENTS.md", "CLAUDE.md",
                 "CONTRIBUTING.md", ".github/CONTRIBUTING.md"]
        for path in paths:
            self.write(path, "Policy from " + path + "\n")
        for index, path in enumerate(paths):
            with self.subTest(winner=path):
                result = self.bind("docs/policy.md")
                self.assertEqual(result["source"], path)
                self.assertEqual([item["path"] for item in result["candidates"]], paths)
                self.assertEqual([item["path"] for item in result["candidates"] if item["status"] == "passed-over"], paths[index + 1:])
                (self.project / path).unlink()

    def test_none_is_unbound_without_side_effects(self):
        result = self.bind()
        self.assertIsNone(result["source"])
        self.assertIsNone(result["digest"])
        self.assertIn("no project policy source found", result["warnings"])
        self.assertEqual(list(self.project.iterdir()), [])

    def test_empty_unreadable_and_invalid_sources_fall_through(self):
        self.write(".specify/memory/constitution.md", " \n\t")
        unreadable = self.write("docs/policy.md", "Unavailable.\n")
        unreadable.chmod(0)
        self.addCleanup(unreadable.chmod, 0o600)
        (self.project / "AGENTS.md").write_bytes(b"\xff")
        self.write("CLAUDE.md", "Valid fallback.\n")
        result = self.bind("docs/policy.md")
        self.assertEqual(result["source"], "CLAUDE.md")
        self.assertEqual([item.get("reason") for item in result["candidates"][:3]],
                         ["empty", "unreadable", "invalid-utf8"])
        self.assertEqual(len(result["warnings"]), 3)

    def test_unsafe_configured_paths_cannot_escape(self):
        outside = self.root / "outside-policy.md"
        outside.write_text("External private content.\n")
        self.write("AGENTS.md", "Use the repository policy.\n")
        for configured in ("../outside-policy.md", str(outside), "docs/../policy.md", "./AGENTS.md", "docs//policy.md"):
            with self.subTest(path=configured):
                result = self.bind(configured)
                self.assertEqual(result["source"], "AGENTS.md")
                self.assertEqual(result["candidates"][1]["reason"], "unsafe-path")
                self.assertNotIn("External private content", json.dumps(result))

    def test_leaf_and_directory_symlinks_are_skipped(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "constitution.md").write_text("External content.\n")
        self.project.joinpath(".specify").mkdir()
        self.project.joinpath(".specify/memory").symlink_to(outside, target_is_directory=True)
        self.project.joinpath("AGENTS.md").symlink_to(outside / "constitution.md")
        self.write("CLAUDE.md", "Fallback.\n")
        result = self.bind()
        self.assertEqual(result["source"], "CLAUDE.md")
        self.assertEqual(result["candidates"][0]["reason"], "unsafe-path")
        self.assertEqual(result["candidates"][1]["reason"], "unsafe-path")
        self.assertNotIn("External content", json.dumps(result))

    def test_nonregular_oversized_control_and_line_limits(self):
        self.project.joinpath("AGENTS.md").mkdir()
        self.write("CLAUDE.md", "x" * 262145)
        self.write("CONTRIBUTING.md", "Keep changes.\x00")
        self.write(".github/CONTRIBUTING.md", "x\n" * 10001)
        result = self.bind()
        self.assertIsNone(result["source"])
        self.assertEqual([item.get("reason") for item in result["candidates"][1:]],
                         ["not-regular-file", "too-large", "invalid-text", "too-many-lines"])

    def test_utf8_crlf_and_no_trailing_newline_have_exact_digest(self):
        file = self.project / "AGENTS.md"
        file.write_bytes("# Café\r\nKeep résumé text.".encode())
        result = self.bind()
        self.assertEqual(result["digest"], hashlib.sha256(file.read_bytes()).hexdigest())
        self.assertEqual(result["passages"][0]["text"], "# Café")
        self.assertEqual(result["text"].encode(), file.read_bytes())
        plan = self.write("plan.md", "Keep résumé text.")
        finding = {"source": result["source"], "digest": result["digest"], "line_start": 2,
                   "line_end": 2, "quote": "Keep résumé text.", "plan_digest": hashlib.sha256(plan.read_bytes()).hexdigest(),
                   "plan_line_start": 1, "plan_line_end": 1, "plan_action": "Keep résumé text."}
        checked = self.verify(result, plan, [finding])
        self.assertEqual(checked["verified_violations"], [finding])

    def test_exact_policy_and_plan_evidence_verified_without_rewriting(self):
        snapshot, plan, finding = self.evidence()
        before = plan.read_bytes()
        result = self.verify(snapshot, plan, {"findings": [finding]})
        self.assertEqual(result["verified_violations"], [finding])
        self.assertEqual(result["unsupported_observations"], [])
        self.assertEqual(plan.read_bytes(), before)

    def test_fabricated_policy_plan_source_digest_and_ranges_rejected(self):
        snapshot, plan, finding = self.evidence()
        variants = {"source": "CLAUDE.md", "digest": "0" * 64, "quote": "Invented principle.",
                    "line_start": 100, "line_end": True, "plan_digest": "1" * 64,
                    "plan_action": "Invented action.", "plan_line_start": 0,
                    "plan_line_end": 4}
        observations = []
        for key, value in variants.items():
            item = copy.deepcopy(finding)
            item[key] = value
            observations.append(item)
        observations.append({"description": "A semantic observation without source evidence."})
        result = self.verify(snapshot, plan, observations)
        self.assertEqual(result["verified_violations"], [])
        self.assertEqual(len(result["unsupported_observations"]), len(observations))

    def test_plan_revision_invalidates_old_action_evidence(self):
        snapshot, plan, finding = self.evidence()
        plan.write_text("# Plan\nDeploy automatically.\nRun broader checks.\n")
        result = self.verify(snapshot, plan, [finding])
        self.assertEqual(result["verified_violations"], [])
        self.assertEqual(result["unsupported_observations"][0]["reason"], "plan-digest-mismatch")

    def test_snapshot_mutation_and_missing_policy_do_not_verify(self):
        snapshot, plan, finding = self.evidence()
        for mutation in ("text", "passages"):
            changed = copy.deepcopy(snapshot)
            if mutation == "text":
                changed["text"] += "Unbound principle.\n"
            else:
                changed["passages"][1]["text"] = "Invented principle."
            result = self.verify(changed, plan, [finding])
            self.assertEqual(result["verified_violations"], [])
            self.assertEqual(result["unsupported_observations"][0]["reason"], "invalid-policy-snapshot")
        result = self.verify({"schema_version": 1, "source": None}, plan, [finding])
        self.assertEqual(result["verified_violations"], [])
        self.assertIn("no project policy source found", result["warnings"])

    def test_runtime_input_symlink_invalid_json_and_size_fail_closed(self):
        snapshot, plan, finding = self.evidence()
        policy = self.root / "snapshot.json"
        policy.write_text(json.dumps(snapshot))
        findings = self.root / "findings.json"
        findings.write_text(json.dumps([finding]))
        link = self.root / "link.json"
        link.symlink_to(policy)
        result = self.call("verify", "--policy", link, "--plan", plan, "--findings", findings, success=False)
        self.assertEqual(result["verified_violations"], [])
        policy.write_text("not json")
        self.assertEqual(self.call("verify", "--policy", policy, "--plan", plan, "--findings", findings,
                                   success=False)["error"], "invalid-json")
        plan.write_bytes(b"x" * 1048577)
        policy.write_text(json.dumps(snapshot))
        self.assertEqual(self.call("verify", "--policy", policy, "--plan", plan, "--findings", findings,
                                   success=False)["error"], "too-large")

    def test_large_policy_is_read_fully_without_preview_truncation(self):
        content = "Keep changes scoped. " * 6000 + "\nFinal required instruction.\n"
        file = self.write("AGENTS.md", content)
        result = self.bind()
        self.assertEqual(result["text"], content)
        self.assertEqual(result["digest"], hashlib.sha256(file.read_bytes()).hexdigest())
        self.assertEqual(result["passages"][-1]["text"], "Final required instruction.")

    def test_runtime_json_ambiguity_is_rejected(self):
        snapshot, plan, finding = self.evidence()
        policy = self.root / "snapshot.json"
        policy.write_text(json.dumps(snapshot))
        findings = self.root / "findings.json"
        for content, error in (("{\"findings\":[],\"findings\":[]}", "duplicate-json-key"),
                               ("[NaN]", "invalid-json-constant")):
            findings.write_text(content)
            result = self.call("verify", "--policy", policy, "--plan", plan,
                               "--findings", findings, success=False)
            self.assertEqual(result["error"], error)
        snapshot["schema_version"] = True
        self.assertEqual(self.verify(snapshot, plan, [finding])["verified_violations"], [])

    def test_findings_limit_and_full_line_quotes(self):
        snapshot, plan, finding = self.evidence()
        result = self.verify(snapshot, plan, [finding] * 257, success=False)
        self.assertEqual(result["error"], "invalid-findings")
        finding["quote"] = "Do not deploy"
        self.assertEqual(self.verify(snapshot, plan, [finding])["verified_violations"], [])

    def test_bash_wrappers_are_source_safe_and_match_cli(self):
        snapshot, plan, finding = self.evidence()
        policy = self.root / "runtime.json"
        observations = self.root / "observations.json"
        policy.write_text(json.dumps(snapshot))
        observations.write_text(json.dumps([finding]))
        script = 'set -eu; before="$-"; source "$1"; [[ "$before" == "$-" ]]; feature_policy_bind "$2"'
        proc = subprocess.run(["/bin/bash", "-c", script, "policy-wrapper", str(WRAPPER), str(self.project)],
                              text=True, capture_output=True, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), snapshot)
        script = 'set -eu; source "$1"; feature_policy_verify "$2" "$3" "$4"'
        proc = subprocess.run(["/bin/bash", "-c", script, "policy-wrapper", str(WRAPPER), str(policy), str(plan), str(observations)],
                              text=True, capture_output=True, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["verified_violations"], [finding])


unittest.main(argv=["feature-policy"], verbosity=2)
PY
then
    test_pass
else
    test_fail "Python acceptance failed"
fi
test_summary
