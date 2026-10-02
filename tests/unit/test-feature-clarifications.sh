#!/usr/bin/env bash
# Exercise clarification state through actual CLI calls in temporary directories.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "feature clarifications"
test_case "actual Python helper acceptance"
if python3 - "$PROJECT_ROOT" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(sys.argv[1])
HELPER = REPO / "scripts/helpers/feature-clarifications.py"
WRAPPER = REPO / "scripts/lib/feature-clarifications.sh"
FULL_SPEC = """# Specification
## Purpose
Serve account owners.
## Actors
Account owner and administrator.
## Behaviors
FR-001: Export a report.
## Constraints
Keep audit history.
## Dependencies
Use the existing database.
## Acceptance Definition
Given an account owner
When the owner requests FR-001 export
Then one report is returned.
Postcondition: The report has its expected columns.
"""


def fence(markers):
    return "\n```octopus-clarifications\n" + json.dumps(markers) + "\n```\n"


def decision(question, **extra):
    result = dict(question=question, kind="user_decision", category="scope")
    result.update(extra)
    return result


def explicit(question_id, answer="Keep the existing scope.", **extra):
    return dict(question_id=question_id, answer=answer,
                provenance={"kind": "native_question_response", "actor": "user", "response_id": "native-round-1"}, **extra)


class ClarificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="octopus-clarifications-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.serial = 0

    def file(self, content, name=None):
        self.serial += 1
        path = self.root / (name or "fixture " + str(self.serial))
        path.write_text(content, encoding="utf-8")
        return path

    def json_file(self, value):
        return self.file(json.dumps(value))

    def call(self, *args, ok=True):
        proc = subprocess.run([sys.executable, str(HELPER), *map(str, args)],
                              text=True, capture_output=True, timeout=10)
        self.assertEqual(proc.returncode, 0 if ok else 1, proc.stderr + proc.stdout)
        return json.loads(proc.stdout)

    def collect(self, spec=FULL_SPEC, challenge=None, previous=None):
        path = self.file(spec)
        before = path.read_bytes()
        args = ["collect", "--spec", path]
        if challenge is not None:
            args += ["--challenge", self.file(challenge)]
        if previous is not None:
            args += ["--previous", self.json_file(previous)]
        output = self.call(*args)
        self.assertEqual(path.read_bytes(), before)
        return output

    def answer(self, markers, responses):
        return self.call("answer", "--markers", self.json_file(markers), "--answers", self.json_file(responses))

    def gate(self, markers, phase="develop", task=None, requirements=None):
        args = ["gate", "--markers", self.json_file(markers), "--phase", phase]
        if task is not None:
            args += ["--task-id", task]
        if requirements is not None:
            args += ["--requirements", *requirements]
        return self.call(*args)

    def test_inline_and_challenger_decisions_merge_without_source_rewrite(self):
        source = FULL_SPEC + "\nQuoted source stays exact.\n[NEEDS CLARIFICATION: Which export formats?]\n"
        challenge = "Challenge\n[NEEDS CLARIFICATION: What is the acceptance threshold?]\n"
        result = self.collect(source, challenge)
        self.assertEqual(len(result["markers"]), 2)
        self.assertTrue(result["spec_text"].startswith(source))
        self.assertIn("[NEEDS CLARIFICATION: What is the acceptance threshold?]", result["spec_text"])
        self.assertEqual(len(result["batch"]), 2)
        self.assertLess(result["score"]["percentage"], 100)

    def test_classification_excludes_technical_and_unknown_kinds(self):
        markers = [{"kind": "technical", "question": "Which library function is fastest?"},
                   {"kind": "unknown", "question": "Is this unresolved?"},
                   decision("Which acceptance threshold?", category="acceptance")]
        spec = FULL_SPEC + fence(markers[:2]) + "[NEEDS CLARIFICATION: Which library function is fastest?]\n"
        result = self.collect(spec, fence(markers[2:]))
        self.assertEqual([m["question"] for m in result["markers"]], ["Which acceptance threshold?"])
        self.assertNotIn("[NEEDS CLARIFICATION: Which library function is fastest?]", result["spec_text"])
        self.assertTrue(result["warnings"])

    def test_identity_keeps_ids_after_reorder_and_reword(self):
        initial = self.collect(FULL_SPEC + fence([decision("Which format?", identity="format-choice"),
                                                decision("Which retention?", identity="retention-choice")]))
        ids = {m["identity"]: m["id"] for m in initial["markers"]}
        replanned = self.collect(FULL_SPEC + fence([decision("What retention period should apply?", identity="retention-choice"),
                                                  decision("What output format should apply?", identity="format-choice")]), previous=initial)
        self.assertEqual(len(replanned["markers"]), 2)
        self.assertEqual({m["identity"]: m["id"] for m in replanned["markers"]}, ids)
        self.assertIn("What output format should apply?", replanned["spec_text"])

    def test_removed_unanswered_marker_is_retained_and_rendered(self):
        initial = self.collect(FULL_SPEC + "[NEEDS CLARIFICATION: Which format?]\n")
        rerun = self.collect(FULL_SPEC, previous=initial)
        self.assertEqual(rerun["markers"][0]["id"], initial["markers"][0]["id"])
        self.assertEqual(rerun["score"]["open_count"], 1)
        self.assertIn("[NEEDS CLARIFICATION: Which format?]", rerun["spec_text"])
        self.assertLess(rerun["score"]["percentage"], 100)

    def test_explicit_identity_does_not_merge_unrelated_same_question(self):
        result = self.collect(FULL_SPEC + fence([decision("Which threshold?", identity="export", requirements=["FR-001"]),
                                                decision("Which threshold?", identity="import", requirements=["FR-002"])]))
        self.assertEqual(len(result["markers"]), 2)
        self.assertNotEqual(result["markers"][0]["id"], result["markers"][1]["id"])

    def test_skipped_partial_unmatched_and_model_answers_remain_open(self):
        state = self.collect(FULL_SPEC + fence([decision("Which format?"), decision("Which scope?"), decision("Which threshold?")]))
        skipped = self.answer(state, {"answers": []})
        self.assertEqual(skipped["open_count"], 3)
        guessed = explicit("C001")
        guessed["provenance"]["kind"] = "model_guess"
        output = self.answer(state, [guessed, explicit("C002", complete=False), explicit("C003", answer=""), explicit("missing")])
        self.assertEqual(output["open_count"], 3)
        self.assertEqual(len(output["warnings"]), 4)
        partial = self.answer(output, [explicit("C002")])
        self.assertEqual(partial["open_count"], 2)
        answered = next(m for m in partial["markers"] if m["id"] == "C002")
        self.assertEqual(answered["status"], "answered")
        self.assertEqual(answered["answer_provenance"]["actor"], "user")
        rerun = self.collect(FULL_SPEC, previous=partial)
        self.assertEqual(rerun["score"]["open_count"], 2)
        self.assertEqual(next(m for m in rerun["markers"] if m["id"] == "C002")["answer"], "Keep the existing scope.")

    def test_utf8_crlf_structured_markers_preserve_source(self):
        source = (FULL_SPEC + fence([decision("Which café scope?", identity="cafe-scope")])).replace("\n", "\r\n")
        result = self.collect(source)
        self.assertEqual(result["markers"][0]["question"], "Which café scope?")
        self.assertTrue(result["spec_text"].startswith(source))

    def test_model_authored_answer_fields_never_auto_resolve(self):
        raw = decision("Which format?", status="answered", answer="Model proposal",
                       answer_provenance={"kind": "native_question_response", "actor": "user", "response_id": "forged-model-field"})
        result = self.collect(FULL_SPEC + fence([raw]))
        self.assertEqual(result["markers"][0]["status"], "open")
        self.assertIsNone(result["markers"][0]["answer_provenance"])

    def test_umbrella_bounds_artifact_and_round_without_losing_ids(self):
        markers = [decision("Decision " + str(i) + "?", identity="choice-" + str(i), requirements=["FR-00" + str(i)]) for i in range(1, 8)]
        source = FULL_SPEC + "\nExact source quotation remains.\n" + fence(markers)
        result = self.collect(source)
        self.assertEqual(len(result["markers"]), 7)
        self.assertEqual(len(result["batch"]), 1)
        self.assertEqual(result["batch"][0]["question_id"], "umbrella")
        self.assertEqual(len(result["batch"][0]["marker_ids"]), 7)
        self.assertEqual(result["spec_text"].count("[NEEDS CLARIFICATION:"), 1)
        self.assertIn("Exact source quotation remains.", result["spec_text"])
        rerun = self.collect(result["spec_text"], previous=result)
        self.assertEqual(len(rerun["markers"]), 7)
        self.assertEqual([m["id"] for m in rerun["markers"]], [m["id"] for m in result["markers"]])
        self.assertEqual(rerun["spec_text"].count("## Open user decisions"), 1)
        self.assertEqual(rerun["spec_text"].count("[NEEDS CLARIFICATION:"), 1)
        umbrella_answer = self.answer(rerun, [explicit("umbrella")])
        self.assertEqual(umbrella_answer["open_count"], 7)
        self.assertFalse(umbrella_answer["warnings"])
        self.assertEqual(umbrella_answer["umbrella"]["status"], "answered")
        self.assertEqual(umbrella_answer["umbrella"]["answer"], "Keep the existing scope.")
        self.assertEqual(umbrella_answer["umbrella"]["answer_provenance"]["response_id"], "native-round-1")
        self.assertEqual(umbrella_answer["umbrella"]["answer_marker_ids"], [m["id"] for m in rerun["markers"]])
        refreshed = self.collect(rerun["spec_text"], previous=umbrella_answer)
        self.assertEqual(refreshed["umbrella"], umbrella_answer["umbrella"])
        self.assertEqual(refreshed["batch"][0]["answer"], "Keep the existing scope.")
        self.assertEqual(refreshed["score"]["open_count"], 7)
        self.assertTrue(all(m["status"] == "open" and m["answer_provenance"] is None for m in refreshed["markers"]))
        partial = self.answer(rerun, [explicit(m["id"]) for m in rerun["markers"][:4]])
        smaller = self.collect(rerun["spec_text"], previous=partial)
        self.assertEqual(smaller["score"]["open_count"], 3)
        self.assertEqual(len(smaller["batch"]), 3)
        self.assertEqual(smaller["spec_text"].count("[NEEDS CLARIFICATION:"), 3)

    def test_umbrella_answer_preserves_unresolved_gates_and_new_scope(self):
        markers = [decision("Choice " + str(i) + "?", identity="choice-" + str(i), task_ids=["T001"],
                            blocking_phases=["develop"], blocking_reason="The output depends on this choice.") for i in range(4)]
        initial = self.collect(FULL_SPEC + fence(markers))
        question_id = initial["batch"][0]["question_id"]
        response = explicit(question_id, answer="Use CSV for all four choices.")
        answered = self.answer(initial, [response])
        self.assertEqual(answered["umbrella"]["answer"], response["answer"])
        self.assertEqual(answered["open_count"], 4)
        gate = self.gate(answered, task="T001")
        self.assertFalse(gate["allowed"])
        self.assertEqual(gate["blocked_ids"], [m["id"] for m in initial["markers"]])
        self.assertEqual(gate["batch"][0]["answer_provenance"], response["provenance"])
        revised = self.collect(FULL_SPEC + fence(markers[::-1] + [decision("Which retention?", identity="retention")]), previous=answered)
        self.assertEqual(revised["score"]["open_count"], 5)
        self.assertEqual(revised["umbrella"]["answer_marker_ids"], initial["umbrella"]["marker_ids"])
        self.assertEqual(len(revised["umbrella"]["marker_ids"]), 5)
        self.assertEqual(revised["umbrella"]["answer"], response["answer"])

    def test_umbrella_only_explicit_constituent_answers_resolve_markers(self):
        initial = self.collect(FULL_SPEC + fence([decision("Choice " + str(i) + "?") for i in range(4)]))
        summary = explicit(initial["batch"][0]["question_id"], answer="Resolve every choice with CSV.")
        partial = self.answer(initial, [summary, explicit("C001", "CSV only.")])
        self.assertEqual(partial["open_count"], 3)
        self.assertEqual([m["id"] for m in partial["markers"] if m["status"] == "answered"], ["C001"])
        refreshed = self.collect(FULL_SPEC, previous=partial)
        self.assertEqual(refreshed["umbrella"]["answer"], summary["answer"])
        self.assertEqual([q["question_id"] for q in refreshed["batch"]], ["C002", "C003", "C004"])
        resolved = self.answer(refreshed, [explicit(q["question_id"], "CSV only.") for q in refreshed["batch"]])
        self.assertEqual(resolved["open_count"], 0)
        self.assertEqual(resolved["umbrella"]["answer_provenance"], summary["provenance"])
        self.assertTrue(all(m["answer"] == "CSV only." for m in resolved["markers"]))

    def test_umbrella_requires_complete_native_user_provenance(self):
        initial = self.collect(FULL_SPEC + fence([decision("Choice " + str(i) + "?") for i in range(4)]))
        guessed = explicit("umbrella")
        guessed["provenance"]["kind"] = "model_guess"
        output = self.answer(initial, [guessed, explicit("umbrella", complete=False), explicit("umbrella", answer="")])
        self.assertEqual(output["open_count"], 4)
        self.assertEqual(len(output["warnings"]), 3)
        self.assertNotIn("answer", output["umbrella"])
        self.assertNotIn("answer_provenance", output["umbrella"])

    def test_task_gate_blocks_only_matching_explicit_load_bearing_decisions(self):
        state = self.collect(FULL_SPEC + fence([decision("Which format?", task_ids=["T001"], requirements=["FR-001"],
                                                       phases=["develop"], blocking_phases=["develop"],
                                                       blocking_reason="T001 cannot select its output contract until the format is chosen."),
                                                decision("Which scope?", task_ids=["T002"], phases=["develop"])]))
        affected = self.gate(state, task="T001")
        self.assertFalse(affected["allowed"])
        self.assertEqual(affected["blocked_ids"], ["C001"])
        self.assertIn("cannot select", affected["blocked"][0]["reason"])
        self.assertTrue(self.gate(state, task="T002")["allowed"])
        self.assertTrue(self.gate(state, task="T003")["allowed"])
        self.assertTrue(self.gate(state, phase="plan", task="T001")["allowed"])
        self.assertTrue(self.gate(state)["allowed"])
        self.assertFalse(self.gate(state, requirements=["FR-001"])["allowed"])
        self.assertEqual(self.gate(state)["open_count"], 2)
        answered = self.answer(state, [explicit("C001", answer="CSV only.")])
        self.assertTrue(self.gate(answered, task="T001")["allowed"])

    def test_replan_can_clear_old_gate_context_without_dropping_question(self):
        initial = self.collect(FULL_SPEC + fence([decision("Which format?", identity="format-choice", task_ids=["T001"],
                                                          blocking_phases=["develop"], blocking_reason="The old contract needs this decision.")]))
        self.assertFalse(self.gate(initial, task="T001")["allowed"])
        revised = self.collect(FULL_SPEC + fence([decision("Which format?", identity="format-choice", task_ids=[],
                                                          blocking_phases=[], blocking_reason="")]), previous=initial)
        self.assertEqual(revised["markers"][0]["id"], initial["markers"][0]["id"])
        self.assertEqual(revised["markers"][0]["status"], "open")
        self.assertTrue(self.gate(revised, task="T001")["allowed"])

    def test_empty_reason_does_not_create_a_gate_block(self):
        state = self.collect(FULL_SPEC + fence([decision("Which scope?", task_ids=["T001"], blocking_phases=["develop"])]))
        self.assertTrue(self.gate(state, task="T001")["allowed"])

    def test_score_six_sections_scenario_two_prose_one(self):
        score = self.collect()["score"]
        self.assertEqual({key: score[key] for key in ("filled", "decidable", "possible", "percentage", "open_count")},
                         {"filled": 9, "decidable": 9, "possible": 9, "percentage": 100, "open_count": 0})
        weights = {item["criterion"]: item["weight"] for item in score["criteria"]}
        self.assertEqual(weights["acceptance-scenario-1"], 2)
        self.assertEqual(weights["acceptance-postcondition-1"], 1)
        missing = self.collect("## Purpose\nPurpose only.\n")["score"]
        self.assertEqual((missing["filled"], missing["decidable"], missing["possible"]), (1, 1, 6))

    def test_open_affected_sections_and_scenarios_earn_zero(self):
        spec = FULL_SPEC.replace("FR-001: Export a report.", "FR-001: Export a report. [NEEDS CLARIFICATION: Which format?]")
        result = self.collect(spec)
        behavior = next(i for i in result["score"]["criteria"] if i["criterion"] == "Behaviors")
        scenario = next(i for i in result["score"]["criteria"] if i["criterion"] == "acceptance-scenario-1")
        self.assertTrue(behavior["filled"])
        self.assertFalse(behavior["decidable"])
        # Inline placement affects Behaviors. Explicit requirement metadata also affects its scenario.
        structured = decision("Which format?", requirements=["FR-001"], sections=["Behaviors"])
        scored = self.collect(FULL_SPEC + fence([structured]))["score"]
        self.assertFalse(next(i for i in scored["criteria"] if i["criterion"] == "acceptance-scenario-1")["decidable"])
        self.assertLess(scored["decidable"], scored["filled"])
        self.assertLess(scored["percentage"], 100)

    def test_generated_appendix_does_not_fill_missing_acceptance(self):
        spec = FULL_SPEC.split("## Acceptance Definition")[0] + "## Acceptance Definition\n"
        initial = self.collect(spec, "[NEEDS CLARIFICATION: Which threshold?]")
        rerun = self.collect(initial["spec_text"], previous=initial)
        acceptance = next(i for i in rerun["score"]["criteria"] if i["criterion"] == "AcceptanceDefinition")
        self.assertFalse(acceptance["filled"])

    def test_invalid_files_bounds_and_duplicate_state_fail_closed(self):
        target = self.file(FULL_SPEC)
        link = self.root / "link.md"
        link.symlink_to(target)
        self.assertIn("error", self.call("collect", "--spec", link, ok=False))
        target.write_bytes(b"x" * 1048577)
        self.assertIn("error", self.call("collect", "--spec", target, ok=False))
        target.write_bytes(b"\xff")
        self.assertIn("error", self.call("collect", "--spec", target, ok=False))
        target.write_text(FULL_SPEC + fence([decision("Which format?")]))
        initial = self.call("collect", "--spec", target)
        initial["markers"].append(initial["markers"][0])
        self.assertIn("error", self.call("gate", "--markers", self.json_file(initial), "--phase", "develop", ok=False))
        initial["markers"] = [{"question": "Missing ID?"}]
        self.assertIn("error", self.call("answer", "--markers", self.json_file(initial), "--answers", self.json_file([]), ok=False))

    def test_quoted_marker_examples_are_preserved_and_do_not_ask_questions(self):
        quote = "\n> [NEEDS CLARIFICATION: Quoted source?]\n```text\n[NEEDS CLARIFICATION: Code example?]\n```\n"
        initial = self.collect(FULL_SPEC + quote)
        self.assertEqual(initial["markers"], [])
        self.assertTrue(initial["spec_text"].endswith(quote))
        nested = "\n````markdown\n" + fence([decision("Quoted structured example?")]) + "````\n"
        self.assertEqual(self.collect(FULL_SPEC + nested)["markers"], [])
        quote += nested
        questions = fence([decision("Choice " + str(i) + "?") for i in range(5)])
        bounded = self.collect(FULL_SPEC + quote + questions)
        self.assertIn(quote, bounded["spec_text"])
        self.assertEqual(len(bounded["markers"]), 5)

    def test_malformed_marker_blocks_warn_and_scoring_bounds_fail_closed(self):
        result = self.collect(FULL_SPEC + "\n```octopus-clarifications\nnot-json\n```\n")
        self.assertIn("spec: malformed clarification block", result["warnings"])
        result = self.collect(FULL_SPEC + "\n```octopus-clarifications\n[]\n")
        self.assertIn("spec: incomplete clarification block", result["warnings"])
        spec = self.file(FULL_SPEC + "\n" + "Postcondition: Expected result.\n" * 513)
        self.assertIn("error", self.call("collect", "--spec", spec, ok=False))

    def test_bash_wrappers_source_safe_collect_answer_gate(self):
        spec = self.file(FULL_SPEC + "[NEEDS CLARIFICATION: Which format?]\n")
        command = 'set -eu; before="$-"; source "$1"; [[ "$-" == "$before" ]]; feature_clarifications_collect "$2"'
        proc = subprocess.run(["/bin/bash", "-c", command, "clarification-wrapper", str(WRAPPER), str(spec)], capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        state = json.loads(proc.stdout)
        markers = self.json_file(state)
        answers = self.json_file([explicit("C001")])
        command = 'set -eu; source "$1"; feature_clarifications_answer "$2" "$3"'
        proc = subprocess.run(["/bin/bash", "-c", command, "clarification-wrapper", str(WRAPPER), str(markers), str(answers)], capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["open_count"], 0)
        command = 'set -eu; source "$1"; feature_clarifications_gate "$2" develop T001 FR-001'
        proc = subprocess.run(["/bin/bash", "-c", command, "clarification-wrapper", str(WRAPPER), str(markers)], capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(json.loads(proc.stdout)["allowed"])


unittest.main(argv=["feature-clarifications"], verbosity=2)
PY
then
    test_pass
else
    test_fail "Python acceptance failed"
fi
test_summary
