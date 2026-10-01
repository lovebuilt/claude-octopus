#!/usr/bin/env python3
"""Exercise analysis through its CLI with repository and runtime fixtures."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(sys.argv.pop(1)).resolve()


class AnalysisTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.feature = self.root / "specs/001-test"
        self.feature.mkdir(parents=True)
        self.manifest = {"schema_version": 1, "feature_id": "feature-uuid",
                         "complexity": "simple"}
        self.write("feature.json", json.dumps(self.manifest))

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, text):
        (self.feature / name).write_text(text, encoding="utf-8")

    def tasks(self, requirements=None, **overrides):
        task = {"id": "T001", "identity": "identity-1", "requirements": requirements or [],
                "kind": "coding", "title": "Do work", "reads": [], "files": [],
                "creates": [], "dependencies": [], "parallel_hint": False, "status": "pending"}
        task.update(overrides)
        return {"schema_version": 1, "feature_id": "feature-uuid", "tasks": [task],
                "tombstones": [], "high_watermark": 1}

    def task_file(self, contract):
        self.write("tasks.md", "# Tasks\n```octopus-tasks\n" + json.dumps(contract, indent=2) + "\n```\n")

    def analyze(self, *args, success=True, shell=False, feature="specs/001-test"):
        # No provider binaries exist in this PATH. The helper must only parse.
        tripwire = self.root / "bin"
        tripwire.mkdir(exist_ok=True)
        for name in ("claude", "codex", "curl", "wget"):
            executable = tripwire / name
            executable.write_text("#!/bin/sh\nprintf called >> '" + str(self.root / "calls") + "'\nexit 99\n")
            executable.chmod(0o755)
        python = tripwire / "python3"
        if not python.exists():
            python.symlink_to(sys.executable)
        env = dict(os.environ, PATH=str(tripwire), PYTHONDONTWRITEBYTECODE="1")
        command = [sys.executable, str(HELPER), "analyze"]
        if shell:
            library = HELPER.parent.parent / "lib/feature-analysis.sh"
            command = ["/bin/bash", "-c", 'source "$1"; shift; octo_feature_analyze "$@"',
                       "feature-analysis", str(library)]
        result = subprocess.run([*command, "--root", str(self.root),
                                 "--feature", feature, *args], env=env,
                                text=True, capture_output=True, timeout=10)
        self.assertFalse((self.root / "calls").exists())
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        return result

    def kinds(self, report):
        return {f["kind"] for f in report["findings"]}

    def test_orphans_preserve_ids_without_dispatch(self):
        self.write("spec.md", "# Requirements\n- **B1**: Alpha\n- **FR001**: Beta\n- **US1**: Gamma\n")
        self.task_file(self.tasks(["B1"], id="T008"))
        report = self.analyze()
        self.assertTrue(report["eligible"])
        missing = [f for f in report["findings"] if f["kind"] == "requirement_uncovered"]
        self.assertEqual({f["requirement_ids"][0] for f in missing}, {"FR001", "US1"})
        self.assertTrue(report["escalate"]["eligible"])
        self.task_file(self.tasks([], id="T008"))
        report = self.analyze()
        orphan = next(f for f in report["findings"] if f["kind"] == "task_unlinked")
        self.assertEqual(orphan["task_ids"], ["T008"])

    def test_unknown_mentions_are_not_requirements(self):
        self.write("spec.md", "Discuss B99 and FR777 later, with 8 servers and 12 clients.\n- **B1**: Real\n")
        self.task_file(self.tasks(["B1"]))
        self.assertEqual(self.analyze()["findings"], [])

    def test_exact_enum_count_term_identifier_quotes(self):
        self.write("spec.md", "| Enum | Values |\n|---|---|\n| State | pending, done |\n"
                   "- Count: retries = 2\n- Term: seat = provider/model\n- Identifier: mode = safe\n")
        self.write("plan.md", "| Enum | Values |\n|---|---|\n| State | pending, failed |\n"
                   "- Count: retries = 3\n- Term: seat = model\n- Identifier: mode = fast\n")
        report = self.analyze()
        self.assertEqual(len(report["findings"]), 4)
        for finding in report["findings"]:
            self.assertEqual(finding["kind"], "declaration_conflict")
            self.assertEqual(len(finding["sources"]), 2)
            for source in finding["sources"]:
                lines = (self.root / source["path"]).read_text().splitlines()
                self.assertEqual(source["quote"], "\n".join(lines[source["line_start"]-1:source["line_end"]]))

    def test_random_prose_and_enum_order_do_not_conflict(self):
        self.write("spec.md", "There are 2 apples.\n- Enum: State = [done, pending]\n")
        self.write("plan.md", "There are 30 cars.\n- Enum: State = [pending, done]\n")
        self.assertEqual(self.analyze()["findings"], [])

    def test_future_creates_and_real_files(self):
        (self.root / "src").mkdir()
        (self.root / "src/main.py").write_text("pass\n")
        self.write("spec.md", "- **FR-001**: Work\n")
        self.task_file(self.tasks(["FR-001"], files=["src/*.py"], creates=["src/new/sub/file.py"]))
        self.assertEqual(self.analyze()["findings"], [])

    def test_unresolved_files_invalid_creates_and_links(self):
        (self.root / "leaf").write_text("file")
        (self.root / "linked").symlink_to(self.root / "leaf")
        self.write("spec.md", "- **B1**: Work\n")
        self.task_file(self.tasks(["B1"], files=["missing/*.py", "linked"],
                                  creates=["leaf/new", "../escape", ".git/config", ".GIT/config"]))
        report = self.analyze()
        self.assertEqual(len([f for f in report["findings"] if f["kind"] == "path_unresolved"]), 6)

    def test_id_drift_reorder_reword_and_tombstones(self):
        self.write("spec.md", "- **B1**: Work\n")
        old = self.tasks(["B1"])
        previous = self.root / "previous.json"
        previous.write_text(json.dumps(old))
        self.task_file(self.tasks(["B1"], title="Reworded title"))
        self.assertEqual(self.analyze("--previous", str(previous))["findings"], [])
        self.task_file(self.tasks(["B1"], id="T002"))
        report = self.analyze("--previous", str(previous))
        self.assertIn("task_id_drift", self.kinds(report))
        self.task_file(self.tasks(["B1"], identity="unrelated-identity"))
        self.assertIn("task_id_reused", self.kinds(self.analyze("--previous", str(previous))))
        old["tasks"] = []
        old["tombstones"] = [{"id": "T001", "identity": "retired"}]
        previous.write_text(json.dumps(old))
        self.assertIn("task_id_reused", self.kinds(self.analyze("--previous", str(previous))))

    def test_single_artifact_skips_even_complex(self):
        self.manifest["complexity"] = "complex"
        self.write("feature.json", json.dumps(self.manifest))
        self.write("spec.md", "- **B1**: Work\n")
        report = self.analyze()
        self.assertFalse(report["eligible"])
        self.assertEqual(report["findings"], [])
        self.assertFalse(report["escalate"]["eligible"])

    def test_clean_complex_and_single_high_threshold(self):
        self.manifest["complexity"] = "complex"
        self.write("feature.json", json.dumps(self.manifest))
        self.write("spec.md", "- **B1**: Work\n")
        self.task_file(self.tasks(["B1"]))
        self.assertFalse(self.analyze()["escalate"]["eligible"])
        self.task_file({"schema_version": 1, "tasks": []})
        report = self.analyze()
        self.assertEqual(len(report["findings"]), 1)
        self.assertTrue(report["escalate"]["eligible"])
        self.manifest["complexity"] = "simple"
        self.write("feature.json", json.dumps(self.manifest))
        self.assertFalse(self.analyze()["escalate"]["eligible"])

    def policy_fixture(self, fabricated=False):
        text = "# Policy\nUse approved storage.\n"
        digest = hashlib.sha256(text.encode()).hexdigest()
        snapshot = self.root.parent / (self.root.name + "-policy.json")
        self.addCleanup(lambda: snapshot.unlink(missing_ok=True))
        snapshot.write_text(json.dumps({"schema_version": 1, "source": "AGENTS.md",
                                       "digest": digest, "text": text,
                                       "passages": [{"line": 1, "text": "# Policy"},
                                                    {"line": 2, "text": "Use approved storage."}]}))
        action = "Use other storage."
        plan = action + "\n"
        ref = {"source": "AGENTS.md", "digest": digest, "line_start": 2, "line_end": 2,
               "quote": "Invented rule." if fabricated else "Use approved storage.",
               "plan_digest": hashlib.sha256(plan.encode()).hexdigest(),
               "plan_line_start": 1, "plan_line_end": 1, "plan_action": action}
        self.write("spec.md", "# Spec\n")
        self.write("plan.md", plan)
        # A separate artifact avoids a circular plan digest over its own finding.
        self.write("tasks.md", "```octopus-policy-findings\n" + json.dumps([ref]) + "\n```\n")
        return snapshot

    def test_policy_exact_quotes_verified_without_semantic_guess(self):
        snapshot = self.policy_fixture()
        report = self.analyze("--policy", str(snapshot))
        self.assertIn("policy_violation", self.kinds(report))
        finding = next(f for f in report["findings"] if f["kind"] == "policy_violation")
        self.assertEqual(finding["sources"][0]["quote"], "Use approved storage.")
        self.assertEqual(finding["sources"][1]["quote"], "Use other storage.")

    def test_fabricated_or_absent_policy_is_not_violation(self):
        snapshot = self.policy_fixture(True)
        report = self.analyze("--policy", str(snapshot))
        self.assertNotIn("policy_violation", self.kinds(report))
        self.assertIn("policy_reference_invalid", self.kinds(report))
        report = self.analyze()
        self.assertNotIn("policy_violation", self.kinds(report))
        self.assertIn("policy_reference_invalid", self.kinds(report))

    def test_bound_policy_digest_mismatch_is_warning(self):
        snapshot = self.policy_fixture()
        data = json.loads(snapshot.read_text())
        data["digest"] = "0" * 64
        snapshot.write_text(json.dumps(data))
        report = self.analyze("--policy", str(snapshot))
        self.assertNotIn("policy_violation", self.kinds(report))
        self.assertTrue(report["warnings"])

    def test_digest_stable_changes_with_artifacts_and_complexity(self):
        self.write("spec.md", "# Spec\n")
        self.write("plan.md", "# Plan\n")
        report = self.analyze()
        self.assertEqual(report["analysis_digest"], self.analyze()["analysis_digest"])
        self.write("plan.md", "# Plan\nMore.\n")
        self.assertNotEqual(report["analysis_digest"], self.analyze()["analysis_digest"])
        before = self.analyze()["analysis_digest"]
        self.manifest["complexity"] = "complex"
        self.write("feature.json", json.dumps(self.manifest))
        self.assertNotEqual(before, self.analyze()["analysis_digest"])

    def test_malformed_contract_warns_without_fake_coverage(self):
        self.write("spec.md", "- **B1**: Work\n")
        self.write("tasks.md", "```octopus-tasks\nnot json\n```\n")
        report = self.analyze()
        self.assertEqual(report["findings"], [])
        self.assertTrue(report["warnings"])

    def test_bounded_nofollow_utf8_control_reads(self):
        self.write("spec.md", "# Spec\n")
        outside = self.root / "outside"
        outside.write_text("DO_NOT_QUOTE")
        (self.feature / "plan.md").symlink_to(outside)
        report = self.analyze()
        self.assertFalse(report["eligible"])
        self.assertNotIn("DO_NOT_QUOTE", json.dumps(report))
        (self.feature / "plan.md").unlink()
        (self.feature / "plan.md").write_bytes(b"\xff")
        self.assertFalse(self.analyze()["eligible"])
        (self.feature / "plan.md").write_bytes(b"hello\x1bsecret")
        self.assertFalse(self.analyze()["eligible"])
        (self.feature / "plan.md").write_bytes(b"x" * (1048576 + 1))
        self.assertFalse(self.analyze()["eligible"])
        (self.root / "runtime.json").symlink_to(outside)
        self.analyze("--contract", str(self.root / "runtime.json"), success=False)

    def test_structured_declarations_and_supported_legacy_tasks(self):
        self.write("spec.md", "- **US1**: Work\n```octopus-declarations\n"
                   '{"enums":{"State":["a","b"]},"counts":{"workers":2}}\n```\n')
        self.write("plan.md", "- Enum: State = [a, c]\n- Count: workers = 3\n")
        self.write("tasks.md", "- [ ] T001 [P] [US1] Do work\n")
        report = self.analyze()
        self.assertEqual(len(report["findings"]), 2)
        self.assertEqual(self.kinds(report), {"declaration_conflict"})

    def test_external_contract_and_artifacts_not_modified(self):
        self.write("spec.md", "- **B1**: Work\n")
        self.write("tasks.md", "# Tasks\n")
        contract = self.root.parent / (self.root.name + "-contract.json")
        self.addCleanup(lambda: contract.unlink(missing_ok=True))
        contract.write_text(json.dumps(self.tasks(["B1"])))
        before = {p: p.read_bytes() for p in self.feature.iterdir()}
        self.assertEqual(self.analyze("--contract", str(contract))["findings"], [])
        self.assertEqual(before, {p: p.read_bytes() for p in self.feature.iterdir()})

    def test_code_examples_are_not_declarations_or_legacy_tasks(self):
        self.write("spec.md", "```markdown\n- **B9**: Example\n- Count: retries = 9\n```\n- **B1**: Real\n")
        self.write("plan.md", "- Count: retries = 2\n")
        self.task_file(self.tasks(["B1"]))
        self.assertEqual(self.analyze()["findings"], [])

    def test_malformed_identity_and_tombstones_warn_without_crashing(self):
        self.write("spec.md", "- **B1**: Real\n")
        self.task_file(self.tasks(["B1"], identity=["invalid"]))
        report = self.analyze()
        self.assertEqual(report["findings"], [])
        self.assertTrue(report["warnings"])
        self.task_file(self.tasks(["B1"]))
        previous = self.root / "previous.json"
        old = self.tasks(["B1"])
        old["tombstones"] = [{"id": []}]
        previous.write_text(json.dumps(old))
        report = self.analyze("--previous", str(previous))
        self.assertEqual(report["findings"], [])
        self.assertTrue(report["warnings"])

    def test_real_requirement_table_and_unknown_task_reference(self):
        self.write("spec.md", "| ID | Requirement |\n|---|---|\n| FR-002 | Work |\n")
        self.task_file(self.tasks(["FR-999"]))
        report = self.analyze()
        self.assertEqual(self.kinds(report), {"requirement_uncovered", "task_requirement_unknown"})

    def test_manifest_cannot_select_outside_feature(self):
        (self.root / "elsewhere.md").write_text("- **B99**: Private\n")
        self.write("spec.md", "# Spec\n")
        self.write("plan.md", "# Plan\n")
        self.manifest["artifacts"] = {"spec": "elsewhere.md", "plan": {"path": "../elsewhere.md"}}
        self.write("feature.json", json.dumps(self.manifest))
        report = self.analyze()
        self.assertFalse(report["eligible"])
        self.assertNotIn("Private", json.dumps(report))

    def test_descriptor_replacement_races_and_global_scan_bounds(self):
        module_spec = importlib.util.spec_from_file_location("feature_analysis_fixture_module", HELPER)
        module = importlib.util.module_from_spec(module_spec)
        sys.modules[module_spec.name] = module
        module_spec.loader.exec_module(module)
        reader = module.ConfinedRoot(str(self.root))
        self.addCleanup(reader.close)
        safe = self.root / "safe.md"
        safe.write_text("safe")
        outside = self.root.parent / (self.root.name + "-outside")
        self.addCleanup(lambda: outside.unlink(missing_ok=True))
        outside.write_text("PRIVATE_OUTSIDE")
        real_open = os.open

        def swap(path, flags, **kwargs):
            if path == "safe.md":
                safe.unlink()
                safe.symlink_to(outside)
            return real_open(path, flags, **kwargs)

        with patch.object(module.os, "open", swap):
            with self.assertRaises(OSError):
                reader.read("safe.md")
        reader.scan_count = module.MAX_SCAN
        with self.assertRaises(ValueError):
            reader.expand("*.md")

    def test_large_valid_contract_parses_with_bounded_source_quotes(self):
        self.write("spec.md", "- **B1**: Work\n")
        contract = self.tasks(["B1"])
        template = contract["tasks"][0]
        contract["tasks"] = [dict(template, id=f"T{n:03}", identity=f"identity-{n}", title="x" * 100)
                             for n in range(1, 120)]
        self.task_file(contract)
        self.assertGreater((self.feature / "tasks.md").stat().st_size, 16384)
        self.assertEqual(self.analyze()["findings"], [])

    def test_source_safe_shell_bridge_executes_actual_analysis(self):
        self.write("spec.md", "- **B1**: Work\n")
        self.task_file(self.tasks(["B1"]))
        self.assertEqual(self.analyze(shell=True), self.analyze())

    def test_complexity_does_not_make_medium_or_duplicate_findings_trigger(self):
        self.manifest["complexity"] = "complex"
        self.write("feature.json", json.dumps(self.manifest))
        self.write("spec.md", "- Count: workers = 2\n")
        self.write("plan.md", "- Count: workers = 3\n- Count: workers = 3\n")
        report = self.analyze()
        self.assertEqual(self.kinds(report), {"declaration_conflict"})
        self.assertFalse(report["escalate"]["eligible"])

    def test_nested_labelled_examples_are_not_contracts(self):
        self.write("spec.md", "- **B1**: Real\n")
        example = "````markdown\n```octopus-tasks\n" + json.dumps(self.tasks([])) + "\n```\n````\n"
        self.write("tasks.md", example + "Use octopus-tasks for export.\n- [ ] T001 [B1] Real work\n")
        self.assertEqual(self.analyze()["findings"], [])

    def test_fifo_and_linked_feature_root_rejected_without_blocking(self):
        self.write("spec.md", "# Spec\n")
        os.mkfifo(self.feature / "plan.md")
        self.assertFalse(self.analyze()["eligible"])
        original = self.feature
        renamed = original.with_name("original")
        original.rename(renamed)
        original.symlink_to(renamed, target_is_directory=True)
        self.analyze(success=False)

    def test_manifest_repeated_artifact_counts_once(self):
        self.write("spec.md", "# Spec\n")
        self.manifest["artifacts"] = {"spec": "spec.md", "plan": "spec.md", "tasks": "spec.md"}
        self.write("feature.json", json.dumps(self.manifest))
        report = self.analyze()
        self.assertFalse(report["eligible"])
        self.assertFalse(report["escalate"]["eligible"])

    def test_legacy_root_only_whole_dot_or_empty_is_allowed(self):
        (self.root / "spec.md").write_text("- **B1**: Real\n")
        (self.root / "plan.md").write_text("# Plan\n")
        dot = self.analyze(feature=".")
        empty = self.analyze(feature="")
        self.assertTrue(dot["eligible"])
        self.assertEqual(dot, empty)
        self.analyze(feature="specs/./001-test", success=False)
        self.analyze(feature="specs/../specs/001-test", success=False)

    def test_explicit_runtime_policy_findings_avoid_self_hash(self):
        snapshot = self.policy_fixture()
        text = (self.feature / "tasks.md").read_text()
        candidates = json.loads(text.split("\n", 1)[1].rsplit("\n```", 1)[0])
        (self.feature / "tasks.md").unlink()
        runtime = self.root / "findings.json"
        runtime.write_text(json.dumps({"schema_version": 1, "findings": candidates}))
        report = self.analyze("--policy", str(snapshot), "--findings", str(runtime))
        self.assertEqual(self.kinds(report), {"policy_violation"})

    def test_administrative_manifest_updates_do_not_change_analysis_digest(self):
        self.write("spec.md", "# Spec\n")
        self.write("plan.md", "# Plan\n")
        self.manifest["artifacts"] = {"spec": {"path": "spec.md", "updated_at": "before"},
                                      "plan": {"path": "plan.md", "run_id": "old"}}
        self.write("feature.json", json.dumps(self.manifest))
        before = self.analyze()["analysis_digest"]
        self.manifest.update(analysis={"status": "reviewed"}, phase="develop", task_completion=[],
                             clarifications={"asked": True})
        self.manifest["artifacts"]["spec"]["updated_at"] = "after"
        self.manifest["artifacts"]["plan"]["run_id"] = "new"
        self.write("feature.json", json.dumps(self.manifest))
        self.assertEqual(before, self.analyze()["analysis_digest"])

    def test_glob_cannot_enter_case_variant_git_metadata(self):
        control = self.root / ".GIT"
        control.mkdir()
        (control / "config").write_text("git control plane")
        self.write("spec.md", "- **B1**: Real\n")
        self.task_file(self.tasks(["B1"], files=[".?IT/*"]))
        self.assertEqual(self.kinds(self.analyze()), {"path_unresolved"})


if __name__ == "__main__":
    unittest.main()
