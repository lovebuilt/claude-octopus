#!/usr/bin/env bash
# Exercise the shared runtime boundary with actual artifacts and offline seats.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Feature analysis runtime"
test_case "shared revision cache and bounded independent semantic seat"
if PYTHONDONTWRITEBYTECODE=1 python3 - "$SCRIPT_DIR/../../scripts/lib/feature-analysis-runtime.sh" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

LIBRARY = Path(sys.argv.pop(1)).resolve()


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.feature = self.root / "specs/001-feature"
        self.feature.mkdir(parents=True)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        self.manifest = {"schema_version": 1, "feature_id": "test-feature", "complexity": "simple",
                         "authors": [{"provider": "claude", "model": "author-model"}]}
        self.write_manifest()
        (self.feature / "spec.md").write_text("- **B1**: First\n- **FR001**: Second\n")
        self.contract = {"schema_version": 1, "feature_id": "test-feature", "tasks": []}
        self.write_tasks()
        self.env = dict(os.environ, FEATURE_SOURCE_ROOT=str(self.root),
                        FEATURE_SELECTED="specs/001-feature", FEATURE_RUNTIME_DIR=str(self.runtime),
                        FIXTURE_ROOT=str(self.root), FIXTURE_MODE="success", FIXTURE_UNAVAILABLE="",
                        FIXTURE_BLOCKED="", FIXTURE_QUOTA="", FIXTURE_PIN="gpt-6.1-sol-pin",
                        OCTOPUS_CODEX_REASONING_LEVEL="high", PYTHONDONTWRITEBYTECODE="1")
        self.stub = r'''
octo_provider_canonical() {
    case "${1%%:*}" in
      codex*) printf 'codex\n';; agy*|gemini*|antigravity) printf 'agy\n';;
      claude-sdk*|anthropic-api|claude*) printf 'claude\n';;
      openrouter) printf 'openrouter\n';; *) return 1;;
    esac
}
octo_provider_allowed() { [[ ",${FIXTURE_BLOCKED:-}," != *",$1,"* ]]; }
octo_quota_is_dead() { [[ ",${FIXTURE_QUOTA:-}," == *",$1,"* ]]; }
octo_provider_readiness_result() {
    printf '%s|%s\n' "$1" "$2" >> "$FIXTURE_ROOT/readiness"
    [[ "$2" == static ]] || return 2
    if [[ ",${FIXTURE_UNAVAILABLE:-}," == *",$1,"* ]]; then
      printf '{"status":"degraded"}\n'
    else printf '{"status":"available"}\n'; fi
}
get_agent_model() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FIXTURE_ROOT/models"
    case "$1" in codex*) printf '%s\n' "$FIXTURE_PIN";; agy*) printf 'gemini-pin\n';; *) printf 'claude-sonnet-pin\n';; esac
}
run_agent_sync_consultative() {
    [[ "$3" == 45 && "$4" == reviewer && "$5" == feature-analysis ]] || return 2
    printf '%s|%s|%s\n' "$1" "$OCTOPUS_CODEX_REASONING_LEVEL" "$5" >> "$FIXTURE_ROOT/calls"
    printf '%s' "$2" > "$FIXTURE_ROOT/prompt"
    case "$FIXTURE_MODE" in
      failed) printf 'private failure\n'; return 1;;
      timeout) printf 'private timeout\n'; return 124;;
      refusal) printf '{"schema_version":1,"status":"refused","findings":[]}\n'; return 0;;
      malformed) printf 'not JSON private text\n'; return 0;;
      slow) sleep 0.3;;
    esac
    python3 - "$FEATURE_ANALYSIS_CONTEXT" "$FIXTURE_MODE" <<'RESPONSE'
import json, sys
from pathlib import Path
context = json.loads(Path(sys.argv[1]).read_text())
snapshot = context["snapshots"][0]
first = snapshot["lines"][0]
source = {"path": snapshot["path"], "digest": snapshot["digest"],
          "line_start": first["line"], "line_end": first["line"], "quote": first["text"]}
if sys.argv[2] == "fabricated": source["quote"] = "Fabricated quote."
if sys.argv[2] == "wrong_digest": source["digest"] = "0" * 64
if sys.argv[2] == "outside": source["path"] = "../outside"
if sys.argv[2] == "stale":
    path = Path(context["source_root"]) / snapshot["path"]
    path.write_text(path.read_text() + "Changed during semantic review.\n")
response = {"schema_version": 1, "findings": [{"kind": "consistency", "severity": "medium",
            "summary": "Independently authored observation.", "sources": [source]}]}
print("## UNVERIFIED CONSULTATIVE OUTPUT\n\nAdvisory only.\n\n```octopus-feature-analysis")
print(json.dumps(response))
print("```\n\n## END UNVERIFIED CONSULTATIVE OUTPUT")
RESPONSE
}
'''

    def tearDown(self):
        self.tmp.cleanup()

    def write_manifest(self):
        (self.feature / "feature.json").write_text(json.dumps(self.manifest))

    def write_tasks(self):
        (self.feature / "tasks.md").write_text("```octopus-tasks\n" + json.dumps(self.contract) + "\n```\n")

    def command(self):
        return ["/bin/bash", "-c", self.stub + '\nsource "$1"\nfeature_analysis_preimplement\n',
                "feature-analysis-runtime", str(LIBRARY)]

    def run_boundary(self):
        result = subprocess.run(self.command(), env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        for raw_text in ("private failure", "private timeout", "not JSON private text"):
            self.assertNotIn(raw_text, result.stdout)
        return json.loads(result.stdout)

    def call_count(self):
        calls = self.root / "calls"
        return len(calls.read_text().splitlines()) if calls.exists() else 0

    def test_triggered_one_independent_seat_preserves_pin_and_effort(self):
        result = self.run_boundary()
        self.assertEqual(result["status"], "reviewed")
        self.assertEqual(result["attempts"], 1)
        self.assertEqual(result["selected"]["provider"], "codex")
        self.assertEqual(result["selected"]["model"], self.env["FIXTURE_PIN"])
        self.assertEqual(self.call_count(), 1)
        self.assertIn("codex:" + self.env["FIXTURE_PIN"] + "|high|feature-analysis", (self.root / "calls").read_text())
        self.assertEqual(result["verification"], "exact_source_quotes_only")
        summary = json.loads(Path(result["verified_summary_path"]).read_text())
        self.assertEqual(len(summary["findings"]), 1)

    def test_clean_complex_zero_calls_and_no_readiness(self):
        self.manifest["complexity"] = "complex"
        self.write_manifest()
        self.contract["tasks"] = [{"id": "T001", "identity": "stable", "requirements": ["B1", "FR001"]}]
        self.write_tasks()
        result = self.run_boundary()
        self.assertEqual(result["attempts"], 0)
        self.assertEqual(self.call_count(), 0)
        self.assertFalse((self.root / "readiness").exists())

    def test_single_artifact_zero_calls(self):
        (self.feature / "tasks.md").unlink()
        result = self.run_boundary()
        self.assertEqual(result["attempts"], 0)
        self.assertFalse((self.root / "readiness").exists())

    def test_missing_any_author_identity_skips(self):
        for authors in ([], [{"model": "known"}], [{"provider": "claude"}, {"provider": "unidentified"}]):
            with self.subTest(authors=authors):
                self.manifest["authors"] = authors
                self.write_manifest()
                result = self.run_boundary()
                self.assertEqual(result["attempts"], 0)
        self.assertEqual(self.call_count(), 0)

    def test_provider_wide_author_and_alias_exclusion(self):
        self.manifest["authors"] = [{"provider": "codex", "model": "another-model"},
                                    {"provider": "gemini-fast", "model": "another-model"},
                                    {"provider": "claude-sdk", "model": "another-model"}]
        self.write_manifest()
        result = self.run_boundary()
        self.assertEqual(result["attempts"], 0)
        self.assertEqual(self.call_count(), 0)

    def test_unavailable_claim_prevents_later_second_host_attempt(self):
        self.env["FIXTURE_UNAVAILABLE"] = "codex,agy,claude-sonnet"
        first = self.run_boundary()
        self.assertEqual(first["attempts"], 0)
        self.env["FIXTURE_UNAVAILABLE"] = ""
        second = self.run_boundary()
        self.assertEqual(first["analysis_digest"], second["analysis_digest"])
        self.assertEqual(self.call_count(), 0)

    def test_failure_timeout_refusal_and_malformed_are_advisory(self):
        for mode in ("failed", "timeout", "refusal", "malformed"):
            with self.subTest(mode=mode):
                self.env["FIXTURE_MODE"] = mode
                (self.feature / "spec.md").write_text((self.feature / "spec.md").read_text() + mode + "\n")
                result = self.run_boundary()
                self.assertEqual(result["attempts"], 1)
                self.assertNotEqual(result["status"], "reviewed")
                before = self.call_count()
                self.run_boundary()
                self.assertEqual(before, self.call_count())
        self.assertEqual(self.call_count(), 4)

    def test_repeat_and_administrative_manifest_changes_share_attempt(self):
        first = self.run_boundary()
        original_report_time = Path(first["report_path"]).stat().st_mtime_ns
        self.run_boundary()
        self.manifest.update(analysis={"done": True}, phase="develop", task_completion=[], clarifications=[])
        self.write_manifest()
        second = self.run_boundary()
        self.assertEqual(first["analysis_digest"], second["analysis_digest"])
        self.assertEqual(self.call_count(), 1)
        self.assertEqual(original_report_time, Path(second["report_path"]).stat().st_mtime_ns)

    def test_changed_artifact_revision_gets_one_new_attempt(self):
        self.run_boundary()
        (self.feature / "spec.md").write_text((self.feature / "spec.md").read_text() + "New revision.\n")
        self.run_boundary()
        self.run_boundary()
        self.assertEqual(self.call_count(), 2)

    def test_concurrent_host_and_runtime_calls_have_one_claim(self):
        self.env["FIXTURE_MODE"] = "slow"
        processes = [subprocess.Popen(self.command(), env=self.env, text=True, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE) for _ in range(2)]
        for process in processes:
            stdout, stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0, stderr)
            json.loads(stdout)
        self.assertEqual(self.call_count(), 1)

    def test_fabricated_wrong_digest_external_and_stale_quotes_not_published(self):
        for mode in ("fabricated", "wrong_digest", "outside", "stale"):
            with self.subTest(mode=mode):
                self.env["FIXTURE_MODE"] = mode
                (self.feature / "spec.md").write_text((self.feature / "spec.md").read_text() + mode + "\n")
                result = self.run_boundary()
                self.assertEqual(result["attempts"], 1)
                self.assertNotEqual(result["status"], "reviewed")
                self.assertFalse(Path(result["verified_summary_path"]).exists())

    def test_allowlist_and_quota_narrow_selection(self):
        self.env["FIXTURE_BLOCKED"] = "codex"
        result = self.run_boundary()
        self.assertEqual(result["selected"]["provider"], "agy")
        (self.feature / "spec.md").write_text((self.feature / "spec.md").read_text() + "Revision\n")
        self.env["FIXTURE_BLOCKED"] = ""
        self.env["FIXTURE_QUOTA"] = "codex,agy"
        result = self.run_boundary()
        self.assertEqual(result["attempts"], 0)

    def test_unknown_routing_functions_skip_advisory(self):
        command = ["/bin/bash", "-c", 'source "$1"; feature_analysis_preimplement', "runtime", str(LIBRARY)]
        result = subprocess.run(command, env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["attempts"], 0)

    def test_runtime_symlink_is_not_followed_and_artifacts_not_changed(self):
        before = {p: p.read_bytes() for p in self.feature.iterdir()}
        outside = self.root / "elsewhere"
        outside.mkdir()
        (self.runtime / "analysis").symlink_to(outside, target_is_directory=True)
        result = self.run_boundary()
        self.assertEqual(result["attempts"], 0)
        self.assertFalse(list(outside.iterdir()))
        self.assertEqual(before, {p: p.read_bytes() for p in self.feature.iterdir()})

    def test_artifact_author_provenance_is_included_and_invalidates_selection(self):
        first = self.run_boundary()
        self.manifest["artifacts"] = {"spec": {"path": "spec.md", "authors": [{"provider": "codex", "model": "author-pin"}]}}
        self.write_manifest()
        second = self.run_boundary()
        self.assertNotEqual(first["analysis_digest"], second["analysis_digest"])
        self.assertEqual(second["selected"]["provider"], "agy")

    def test_claude_profile_is_used_when_other_providers_authored(self):
        self.manifest["authors"] = [{"provider": "codex", "model": "author"}, {"provider": "agy", "model": "author"}]
        self.write_manifest()
        result = self.run_boundary()
        self.assertEqual(result["selected"]["agent"], "claude-sonnet")
        self.assertEqual(result["selected"]["provider"], "claude")
        self.assertEqual(self.call_count(), 1)

    def test_one_high_impact_finding_only_complex_feature_can_dispatch(self):
        self.contract["tasks"] = [{"id": "T001", "identity": "stable", "requirements": ["B1"]}]
        self.write_tasks()
        first = self.run_boundary()
        self.assertEqual(first["attempts"], 0)
        self.manifest["complexity"] = "complex"
        self.write_manifest()
        second = self.run_boundary()
        self.assertEqual(second["attempts"], 1)
        self.assertEqual(second["trigger"], "complex_high_impact_finding")

    def test_clean_bounded_empty_semantic_response_is_valid(self):
        self.stub = self.stub.replace('case "$FIXTURE_MODE" in', '''case "$FIXTURE_MODE" in
      empty) printf '{"schema_version":1,"findings":[]}\\n'; return 0;;''', 1)
        self.env["FIXTURE_MODE"] = "empty"
        result = self.run_boundary()
        self.assertEqual(result["status"], "reviewed")
        self.assertEqual(result["verified_findings"], 0)

    def test_oversized_semantic_output_is_private_and_not_verified(self):
        self.stub = self.stub.replace('case "$FIXTURE_MODE" in', '''case "$FIXTURE_MODE" in
      overlong) python3 -c 'print("x" * 200000)'; return 0;;''', 1)
        self.env["FIXTURE_MODE"] = "overlong"
        result = self.run_boundary()
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["attempts"], 1)
        raw = Path(result["receipt_path"]).parent / "semantic.raw"
        self.assertEqual(raw.stat().st_size, 131072)
        self.assertEqual(raw.stat().st_mode & 0o777, 0o600)

    def test_policy_claim_without_policy_and_plan_quotes_is_unverified(self):
        self.stub = self.stub.replace('"kind": "consistency"', '"kind": "policy_violation"')
        result = self.run_boundary()
        self.assertEqual(result["status"], "unverified")
        self.assertFalse(Path(result["verified_summary_path"]).exists())

    def test_policy_claim_quotes_both_bound_policy_and_current_plan(self):
        text = "Use approved storage.\n"
        policy = self.root / "policy-snapshot.json"
        policy.write_text(json.dumps({"schema_version": 1, "source": "AGENTS.md", "text": text,
                                      "digest": hashlib.sha256(text.encode()).hexdigest()}))
        self.env["FEATURE_POLICY_SNAPSHOT"] = str(policy)
        (self.feature / "plan.md").write_text("Use alternate storage.\n")
        self.stub = self.stub.replace('response = {"schema_version": 1,', '''policy_snapshot = next(s for s in context["snapshots"] if s["path"] == "AGENTS.md")
policy_line = policy_snapshot["lines"][0]
policy_evidence = {"path": policy_snapshot["path"], "digest": policy_snapshot["digest"],
                   "line_start": policy_line["line"], "line_end": policy_line["line"], "quote": policy_line["text"]}
response = {"schema_version": 1,''')
        self.stub = self.stub.replace('"kind": "consistency"', '"kind": "policy_violation"')
        self.stub = self.stub.replace('"sources": [source]', '"sources": [source, policy_evidence]')
        result = self.run_boundary()
        self.assertEqual(result["status"], "reviewed")
        summary = json.loads(Path(result["verified_summary_path"]).read_text())
        self.assertEqual(len(summary["findings"][0]["sources"]), 2)

    def test_absent_optional_runtime_snapshot_preserves_deterministic_report(self):
        self.env["FEATURE_POLICY_SNAPSHOT"] = str(self.root / "absent-policy.json")
        result = self.run_boundary()
        self.assertTrue(Path(result["report_path"]).exists())
        self.assertEqual(self.call_count(), 1)

    def test_relative_runtime_contract_resolves_under_feature_source_root(self):
        contract = {"schema_version": 1, "feature_id": "test-feature", "tasks": [
                    {"id": "T001", "identity": "stable", "requirements": ["B1", "FR001"]}]}
        (self.root / "contract.json").write_text(json.dumps(contract))
        self.env["FEATURE_TASK_CONTRACT"] = "contract.json"
        result = self.run_boundary()
        self.assertEqual(result["attempts"], 0)
        self.assertEqual(self.call_count(), 0)


unittest.main()
PY
then test_pass
else test_fail "feature analysis runtime fixtures failed"
fi
test_case "source safe with caller options and traps"
if /bin/bash -c '
  set +e +u
  flags=$-
  directory=$PWD
  traps=$(trap -p)
  source "$1"
  source "$1"
  [[ "$flags" == "$-" && "$directory" == "$PWD" && "$traps" == "$(trap -p)" ]]
  declare -F feature_analysis_preimplement >/dev/null
' runtime "$SCRIPT_DIR/../../scripts/lib/feature-analysis-runtime.sh"; then
    test_pass
else test_fail "runtime library changed caller state"
fi
test_case "AGY feature-analysis crash cannot retry"
if (
    source "$SCRIPT_DIR/../../scripts/lib/agent-sync.sh"
    fixture="$TEST_TMP_DIR/analysis-signal"
    mkdir -p "$fixture/results"
    export RESULTS_DIR="$fixture/results"
    fake_provider="$fixture/provider.sh"
    export ATTEMPT_FILE="$fixture/attempts"
    cat > "$fake_provider" <<'PROVIDER'
#!/usr/bin/env bash
printf 'attempt\n' >> "$ATTEMPT_FILE"
printf 'synthetic crash\n' >&2
exit 139
PROVIDER
    chmod 755 "$fake_provider"
    log() { :; }
    classify_task() { printf 'standard\n'; }
    get_role_for_context() { printf 'reviewer\n'; }
    apply_persona() { printf '%s\n' "$2"; }
    load_earned_skills() { :; }
    build_provider_context() { :; }
    enforce_context_budget() { printf '%s\n' "$1"; }
    get_agent_model() { printf 'fixture-model\n'; }
    estimate_agent_call_cost() { printf '0\n'; }
    check_provider_health() { return 0; }
    record_agent_call() { :; }
    run_contract_transition() { :; }
    get_agent_command() { printf '%s\n' "$fake_provider"; }
    build_provider_env() { PROVIDER_ENV_ARRAY=(); }
    octo_dispatch_command_argv_json() { printf '[]\n'; }
    octo_dispatch_plan_create() { printf '{}\n'; }
    octo_dispatch_plan_load_argv() { OCTO_DISPATCH_PLAN_ARGV=("$fake_provider"); }
    octo_dispatch_plan_record() { :; }
    run_with_timeout() { printf '%s\n' "$1" >> "$fixture/timeouts"; shift; "$@"; }
    stop_quota_watcher() { :; }
    update_agent_status() { :; }
    octo_estimate_tokens_for_file() { printf '0\n'; }
    classify_agent_output() { printf 'ok:\n'; }
    wrap_cli_output() { printf '%s\n' "$2"; }
    write_agent_status() { :; }
    for global_timeout in 0 600; do
        : > "$ATTEMPT_FILE"
        : > "$fixture/timeouts"
        rc=0
        OCTOPUS_AGENT_TIMEOUT="$global_timeout" OCTOPUS_PERSISTENCE_AVAILABLE=true run_agent_sync 'agy:fixture-model' 'Check artifacts' 45 reviewer feature-analysis >"$fixture/output" 2>"$fixture/error" || rc=$?
        attempts="$(wc -l < "$ATTEMPT_FILE" | tr -d ' ')"
        actual_timeout="$(cat "$fixture/timeouts")"
        if [[ "$rc" != 139 || "$attempts" != 1 || ! "$actual_timeout" =~ ^[1-9][0-9]*$ ]] ||
            [[ "$actual_timeout" -gt 45 ]]; then
            printf 'Signal fixture rc=%s attempts=%s timeout=%s\n' "$rc" "$attempts" "$actual_timeout" >&2
            cat "$fixture/error" >&2
            exit 1
        fi
    done
); then test_pass
else test_fail "feature analysis caused more than one AGY provider invocation"
fi
test_summary
