#!/usr/bin/env python3
"""Collect user decisions, apply explicit answers, and report decidability."""

import argparse
import json
import os
import re
import stat
import sys
import uuid

BYTE_LIMIT = 1048576
MARKER_LIMIT = 256
QUESTION_LIMIT = 2048
CRITERION_LIMIT = 512
PHASES = ("plan", "develop", "verify")
SECTIONS = ("Purpose", "Actors", "Behaviors", "Constraints", "Dependencies", "AcceptanceDefinition")
INLINE = re.compile(r"\[NEEDS CLARIFICATION:\s*([^]\n]+)\]")
FENCE = re.compile(r"^```octopus-clarifications[ \t]*\r?\n(.*?)^```[ \t]*\r?$", re.M | re.S)
DISPLAY = re.compile(r"^<!-- BEGIN octopus-open-decisions -->\n.*?^<!-- END octopus-open-decisions -->\n?", re.M | re.S)
ID = re.compile(r"^(?:C[0-9]{3,}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$")


class InvalidInput(ValueError):
    pass


def read_text(path):
    parent, name = os.path.split(os.path.abspath(path))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    directory = os.open(os.sep, flags)
    try:
        for part in os.path.realpath(parent).split(os.sep):
            if part:
                child = os.open(part, flags, dir_fd=directory)
                os.close(directory)
                directory = child
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or not before.st_mode & 0o444:
                raise InvalidInput("input is not a readable regular file")
            if before.st_size > BYTE_LIMIT:
                raise InvalidInput("input exceeds byte limit")
            chunks, size = [], 0
            while size <= BYTE_LIMIT:
                chunk = os.read(fd, min(65536, BYTE_LIMIT + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
            if size > BYTE_LIMIT:
                raise InvalidInput("input exceeds byte limit")
            after = os.fstat(fd)
            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise InvalidInput("input changed during read")
            text = b"".join(chunks).decode("utf-8")
            if any((ord(c) < 32 and c not in "\n\r\t") or ord(c) == 127 for c in text):
                raise InvalidInput("input contains control characters")
            return text
        finally:
            os.close(fd)
    finally:
        os.close(directory)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidInput("duplicate JSON key")
        result[key] = value
    return result


def invalid_constant(_value):
    raise InvalidInput("invalid JSON constant")


def parse_json(text):
    return json.loads(text, object_pairs_hook=unique_object, parse_constant=invalid_constant)


def normalize(question):
    return " ".join(question.split()).casefold()


def string_list(value):
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > MARKER_LIMIT or any(not isinstance(s, str) or not s.strip() or len(s) > 128 or any(ord(c) < 32 for c in s) for s in value):
        raise InvalidInput("invalid marker list")
    return list(dict.fromkeys(value))


def section_name(text):
    key = re.sub(r"[^a-z]", "", text.casefold())
    aliases = {"purpose": "Purpose", "actors": "Actors", "behaviors": "Behaviors", "behaviours": "Behaviors",
               "constraints": "Constraints", "dependencies": "Dependencies", "acceptance": "AcceptanceDefinition",
               "acceptancecriteria": "AcceptanceDefinition", "acceptancedefinition": "AcceptanceDefinition"}
    return aliases.get(key)


def valid_provenance(value):
    return (isinstance(value, dict) and value.get("kind") == "native_question_response"
            and value.get("actor") == "user" and isinstance(value.get("response_id"), str)
            and bool(value["response_id"].strip()))


def marker_list(value):
    if isinstance(value, dict):
        if type(value.get("schema_version")) is not int or value["schema_version"] != 1:
            raise InvalidInput("invalid marker schema")
        value = value.get("markers")
    if not isinstance(value, list) or len(value) > MARKER_LIMIT:
        raise InvalidInput("invalid marker collection")
    return value


def normalize_marker(value):
    if not isinstance(value, dict):
        raise InvalidInput("invalid marker")
    question = value.get("question")
    if not isinstance(question, str) or not question.strip() or len(question) > QUESTION_LIMIT or any(ord(c) < 32 for c in question) or "]" in question:
        raise InvalidInput("invalid question")
    result = {"question": question.strip(), "kind": "user_decision", "category": value.get("category", "scope"),
              "requirements": string_list(value.get("requirements")), "task_ids": string_list(value.get("task_ids")),
              "phases": string_list(value.get("phases", [value["phase"]] if "phase" in value else list(PHASES))),
              "sections": string_list(value.get("sections")), "blocking_phases": string_list(value.get("blocking_phases")),
              "blocking_reason": value.get("blocking_reason", ""), "status": "open", "answer_provenance": None}
    if result["category"] not in ("scope", "constraints", "policy", "acceptance"):
        raise InvalidInput("invalid user decision category")
    if any(p not in PHASES for p in result["phases"] + result["blocking_phases"]):
        raise InvalidInput("invalid marker phase")
    if not isinstance(result["blocking_reason"], str):
        raise InvalidInput("invalid blocking reason")
    for key in ("id", "identity"):
        if value.get(key) is not None:
            if not isinstance(value[key], str) or not value[key] or len(value[key]) > 128:
                raise InvalidInput("invalid marker identity")
            result[key] = value[key]
    if "id" in result and not ID.fullmatch(result["id"]):
        raise InvalidInput("invalid marker ID")
    if (value.get("status") == "answered" and valid_provenance(value.get("answer_provenance"))
            and isinstance(value.get("answer"), str) and value["answer"].strip()):
        result.update(status="answered", answer=value["answer"], answer_provenance=value["answer_provenance"])
    return result


def structured_blocks(text):
    protected = None
    position, consumed = 0, 0
    for line in text.splitlines(keepends=True):
        start = position
        position += len(line)
        if start < consumed:
            continue
        boundary = re.match(r"^[ \t]*(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if protected:
            if boundary and boundary.group(1)[0] == protected[0] and len(boundary.group(1)) >= protected[1] and not boundary.group(2).strip():
                protected = None
        elif line.startswith("```octopus-clarifications"):
            match = FENCE.match(text, start)
            if match:
                yield match
                consumed = match.end()
            else:
                protected = ("`", 3)
        elif boundary:
            protected = (boundary.group(1)[0], len(boundary.group(1)))


def replace_structured(text, replacement):
    pieces, end = [], 0
    for match in structured_blocks(text):
        pieces.extend([text[end:match.start()], replacement])
        end = match.end()
    pieces.append(text[end:])
    return "".join(pieces)


def transform_inline(text, callback):
    output = []
    fence = None
    for line in text.splitlines(keepends=True):
        boundary = re.match(r"^[ \t]*(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if boundary:
            token = boundary.group(1)[0]
            if fence is None:
                fence = (token, len(boundary.group(1)))
            elif fence[0] == token and len(boundary.group(1)) >= fence[1] and not boundary.group(2).strip():
                fence = None
            output.append(line)
        elif fence or re.match(r"^[ \t]*>", line):
            output.append(line)
        else:
            output.append(INLINE.sub(callback, line))
    return "".join(output)


def parse_markers(text, origin, warnings):
    structured, excluded = [], set()
    if len(re.findall(r"^```octopus-clarifications[ \t]*\r?$", text, re.M)) != len(list(FENCE.finditer(text))):
        warnings.append(origin + ": incomplete clarification block")
    for match in structured_blocks(text):
        try:
            entries = parse_json(match.group(1))
            if not isinstance(entries, list) or len(entries) > MARKER_LIMIT:
                raise InvalidInput("invalid structured marker collection")
            for entry in entries:
                if not isinstance(entry, dict):
                    warnings.append(origin + ": invalid structured marker")
                    continue
                if entry.get("kind") != "user_decision":
                    if isinstance(entry.get("question"), str):
                        excluded.add(normalize(entry["question"]))
                    warnings.append(origin + ": excluded non-user decision marker")
                    continue
                try:
                    marker = normalize_marker(entry)
                    # Current model-authored text never supplies a user answer.
                    marker.update(status="open", answer_provenance=None)
                    marker.pop("answer", None)
                    marker["_provided"] = list(entry)
                    structured.append(marker)
                except InvalidInput as exc:
                    warnings.append(origin + ": " + str(exc))
                    if isinstance(entry.get("question"), str):
                        excluded.add(normalize(entry["question"]))
        except (ValueError, RecursionError):
            warnings.append(origin + ": malformed clarification block")
    inline = []
    active_section = None
    active_depth = 0
    known = {normalize(m["question"]): m for m in structured}
    clean = replace_structured(text, "")
    code_fence = None
    for line in clean.splitlines():
        boundary = re.match(r"^[ \t]*(`{3,}|~{3,})(.*)$", line)
        if boundary:
            token = boundary.group(1)[0]
            if code_fence is None:
                code_fence = (token, len(boundary.group(1)))
            elif code_fence[0] == token and len(boundary.group(1)) >= code_fence[1] and not boundary.group(2).strip():
                code_fence = None
            continue
        if code_fence or re.match(r"^[ \t]*>", line):
            continue
        heading = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if heading:
            depth = len(line) - len(line.lstrip("#"))
            selected = section_name(heading.group(1))
            if selected:
                active_section, active_depth = selected, depth
            elif depth <= active_depth:
                active_section = None
        for match in INLINE.finditer(line):
            question = match.group(1).strip()
            if normalize(question) in excluded:
                continue
            if normalize(question) in known:
                marker = known[normalize(question)]
                if active_section and active_section not in marker["sections"]:
                    marker["sections"].append(active_section)
            else:
                marker = normalize_marker({"question": question, "sections": [active_section] if active_section else []})
                marker["_provided"] = ["sections"]
                marker["_inline"] = True
                inline.append(marker)
                known[normalize(question)] = marker
    if len(structured) + len(inline) > MARKER_LIMIT:
        raise InvalidInput("too many clarification markers")
    return structured + inline, excluded


def batches(markers, umbrella=None):
    opened = [m for m in markers if m["status"] == "open"]
    if len(opened) <= 3:
        return [{"question_id": m["id"], "question": m["question"], "marker_ids": [m["id"]],
                 "requirements": m["requirements"], "task_ids": m["task_ids"], "phases": m["phases"]} for m in opened]
    requirements = sorted({r for m in opened for r in m["requirements"]})
    tasks = sorted({t for m in opened for t in m["task_ids"]})
    scope = ", ".join(requirements + tasks) or "the feature scope and acceptance contract"
    question = {"question_id": "umbrella", "question": "The request is underspecified across " + scope + ". Which scope, constraint, policy, and acceptance choices should govern the affected work?",
                "marker_ids": [m["id"] for m in opened], "requirements": requirements, "task_ids": tasks}
    if (isinstance(umbrella, dict) and umbrella.get("status") == "answered"
            and valid_provenance(umbrella.get("answer_provenance"))
            and isinstance(umbrella.get("answer"), str) and umbrella["answer"].strip()):
        question.update(status="answered", answer=umbrella["answer"],
                        answer_provenance=umbrella["answer_provenance"],
                        answer_marker_ids=string_list(umbrella.get("answer_marker_ids", umbrella.get("marker_ids"))))
    return [question]


def score(spec, markers):
    contents = {name: [] for name in SECTIONS}
    current = None
    current_depth = 0
    clean = replace_structured(spec, "")
    for line in clean.splitlines():
        heading = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if heading:
            selected = section_name(heading.group(1))
            depth = len(line) - len(line.lstrip("#"))
            if selected:
                current, current_depth = selected, depth
                continue
            if depth <= current_depth:
                current = None
        if current:
            contents[current].append(line)
    opened = [m for m in markers if m["status"] == "open"]
    affected = {section_name(s) for m in opened for s in m["sections"]}
    details = []
    for name in SECTIONS:
        body = "\n".join(contents[name])
        visible = re.sub(r"<!--.*?-->", "", INLINE.sub("", body), flags=re.S)
        filled = bool(visible.strip())
        referenced = {token for token in re.findall(r"\b(?:FR-[0-9]+|US[0-9]+|B[0-9]+|T[0-9]+)\b", body)}
        blocked = name in affected or any(referenced.intersection(m["requirements"] + m["task_ids"]) for m in opened)
        details.append({"criterion": name, "weight": 1, "filled": filled, "decidable": filled and not blocked})
    acceptance = contents["AcceptanceDefinition"]
    scenario, prose = [], []
    parts = []
    for line in acceptance:
        text = INLINE.sub("", line).strip().lstrip("-* ")
        hit = re.match(r"^(Given|When|Then)\s+(.+)$", text, re.I)
        if hit:
            word = hit.group(1).lower()
            if word == "given":
                parts = [text]
            elif word == "when" and len(parts) == 1:
                parts.append(text)
            elif word == "then" and len(parts) == 2:
                parts.append(text)
                scenario.append("\n".join(parts))
                parts = []
        else:
            condition = re.match(r"^(?:Postcondition|Post-condition):\s*(.+)$", text, re.I)
            if condition:
                prose.append(condition.group(1))
    if len(scenario) + len(prose) > CRITERION_LIMIT:
        raise InvalidInput("too many acceptance criteria")
    acceptance_open = any("AcceptanceDefinition" in [section_name(s) for s in m["sections"]]
                          and not m["requirements"] and not m["task_ids"] for m in opened)
    for kind, entries, weight in (("scenario", scenario, 2), ("postcondition", prose, 1)):
        for index, text in enumerate(entries, 1):
            refs = set(re.findall(r"\b(?:FR-[0-9]+|US[0-9]+|B[0-9]+|T[0-9]+)\b", text))
            blocked = acceptance_open or any(refs.intersection(m["requirements"] + m["task_ids"]) for m in opened)
            details.append({"criterion": "acceptance-" + kind + "-" + str(index), "weight": weight,
                            "filled": True, "decidable": not blocked})
    possible = sum(item["weight"] for item in details)
    filled = sum(item["weight"] for item in details if item["filled"])
    decidable = sum(item["weight"] for item in details if item["decidable"])
    # An unscoped retained decision still prevents a false full-completeness claim.
    unscoped_penalty = int(bool(opened and decidable == possible))
    if unscoped_penalty:
        decidable = max(0, decidable - 1)
    return {"unscoped_decision_penalty": unscoped_penalty, "filled": filled, "decidable": decidable, "possible": possible,
            "percentage": min(99 if opened else 100, round(100 * decidable / possible)),
            "open_count": len(opened), "criteria": details}


def collect(spec, challenge="", previous=None):
    warnings = []
    retained = []
    for raw in marker_list(previous) if previous is not None else []:
        marker = normalize_marker(raw)
        if "id" not in marker:
            raise InvalidInput("previous marker lacks ID")
        marker.setdefault("identity", marker["id"])
        if any(old["id"] == marker["id"] or old["identity"] == marker["identity"] for old in retained):
            raise InvalidInput("duplicate previous marker identity")
        retained.append(marker)
    incoming, excluded = parse_markers(spec, "spec", warnings)
    extra, challenge_excluded = parse_markers(challenge, "challenge", warnings)
    incoming.extend(extra)
    excluded.update(challenge_excluded)
    previous_umbrella = previous.get("umbrella") if isinstance(previous, dict) else None
    if isinstance(previous_umbrella, dict) and isinstance(previous_umbrella.get("question"), str):
        umbrella_question = normalize(previous_umbrella["question"])
        incoming = [m for m in incoming if normalize(m["question"]) != umbrella_question]
        excluded.add(umbrella_question)
    next_number = max([int(m["id"][1:]) for m in retained if m["id"].startswith("C")] + [0]) + 1
    for item in incoming:
        matches = [m for m in retained if (item.get("id") and m["id"] == item["id"])
                   or (item.get("identity") and m["identity"] == item["identity"])]
        if not matches and not item.get("id") and not item.get("identity"):
            matches = [m for m in retained if normalize(m["question"]) == normalize(item["question"])]
        if len(matches) > 1:
            raise InvalidInput("ambiguous marker identity")
        if matches:
            old = matches[0]
            if item.get("identity") and item["identity"] != old["identity"]:
                raise InvalidInput("marker identity changed for existing ID")
            old["question"] = item["question"]
            provided = item.get("_provided", [])
            for key in ("requirements", "task_ids", "phases", "sections", "blocking_phases"):
                if key in provided:
                    old[key] = list(dict.fromkeys(old[key] + item[key])) if item.get("_inline") else item[key]
                elif key == "sections" and item[key]:
                    old[key] = list(dict.fromkeys(old[key] + item[key]))
            for key in ("blocking_reason", "category"):
                if key in provided:
                    old[key] = item[key]
        else:
            if item.get("id") and any(m["id"] == item["id"] for m in retained):
                raise InvalidInput("reused marker ID")
            item.setdefault("id", "C" + str(next_number).zfill(3))
            next_number = max(next_number + 1, int(item["id"][1:]) + 1 if item["id"].startswith("C") else next_number + 1)
            item.setdefault("identity", str(uuid.uuid4()))
            item.pop("_provided", None)
            item.pop("_inline", None)
            retained.append(item)
    if len(retained) > MARKER_LIMIT:
        raise InvalidInput("too many retained clarification markers")
    batch = batches(retained, previous_umbrella)
    spec_text = DISPLAY.sub("", spec)
    if len([m for m in retained if m["status"] == "open"]) > 3:
        spec_text = transform_inline(spec_text, lambda _match: "")
        spec_text = replace_structured(spec_text, "")
        additions = ["[NEEDS CLARIFICATION: " + batch[0]["question"] + "]"]
        warnings.append("pervasive inference: retained underlying marker IDs and batched one umbrella question")
    else:
        spec_text = transform_inline(spec_text, lambda match: "" if normalize(match.group(1)) in excluded else match.group(0))
        visible = set()
        def remember(match):
            visible.add(normalize(match.group(1)))
            return match.group(0)
        transform_inline(spec_text, remember)
        additions = ["[NEEDS CLARIFICATION: " + m["question"] + "]" for m in retained
                     if m["status"] == "open" and normalize(m["question"]) not in visible]
    if additions:
        spec_text += ("" if spec_text.endswith("\n") else "\n") + "\n<!-- BEGIN octopus-open-decisions -->\n## Open user decisions\n\n" + "\n".join(additions) + "\n<!-- END octopus-open-decisions -->\n"
    umbrella = batch[0] if batch and batch[0]["question_id"] == "umbrella" else previous_umbrella
    return {"schema_version": 1, "markers": retained, "spec_text": spec_text, "umbrella": umbrella,
            "batch": batch, "score": score(spec, retained), "warnings": warnings}


def state_markers(value):
    markers = [normalize_marker(m) for m in marker_list(value)]
    seen_ids, seen_identities = set(), set()
    for marker in markers:
        if "id" not in marker or marker["id"] in seen_ids:
            raise InvalidInput("missing or duplicate marker ID")
        seen_ids.add(marker["id"])
        identity = marker.get("identity", marker["id"])
        if identity in seen_identities:
            raise InvalidInput("duplicate marker identity")
        seen_identities.add(identity)
    return markers


def answer(markers, answers):
    retained = state_markers(markers)
    if isinstance(answers, dict):
        answers = answers.get("answers")
    if not isinstance(answers, list) or len(answers) > MARKER_LIMIT:
        raise InvalidInput("invalid answers collection")
    warnings = []
    umbrella = markers.get("umbrella") if isinstance(markers, dict) else None
    if isinstance(umbrella, dict):
        umbrella = dict(umbrella)
    for response in answers:
        if not isinstance(response, dict):
            warnings.append("ignored malformed answer")
            continue
        umbrella_response = (response.get("question_id") == "umbrella"
                             and isinstance(umbrella, dict) and umbrella.get("question_id") == "umbrella")
        matches = [m for m in retained if m.get("id") == response.get("question_id")]
        if not umbrella_response and len(matches) != 1:
            warnings.append("ignored unmatched answer")
            continue
        text = response.get("answer")
        if (not valid_provenance(response.get("provenance")) or response.get("complete", True) is not True
                or not isinstance(text, str) or not text.strip()):
            warnings.append("ignored answer without complete explicit user provenance")
            continue
        if umbrella_response:
            # Preserve the summary separately. Resolve each constituent only
            # from a native response carrying that marker's ID.
            umbrella.update(status="answered", answer=text, answer_provenance=response["provenance"],
                            answer_marker_ids=string_list(umbrella.get("marker_ids")))
        else:
            matches[0].update(status="answered", answer=text, answer_provenance=response["provenance"])
    batch = batches(retained, umbrella)
    if batch and batch[0]["question_id"] == "umbrella":
        umbrella = batch[0]
    return {"schema_version": 1, "markers": retained, "batch": batch, "umbrella": umbrella,
            "open_count": sum(m["status"] == "open" for m in retained), "warnings": warnings}


def gate(markers, phase, task_id=None, requirements=None):
    retained = state_markers(markers)
    opened = [m for m in retained if m["status"] == "open"]
    requirements = requirements or []
    if any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*(?:[-.][A-Za-z0-9]+)?", r) for r in requirements):
        raise InvalidInput("invalid requirement identifier")
    blocked = []
    for marker in opened:
        matches = (task_id and task_id in marker["task_ids"]) or set(requirements).intersection(marker["requirements"])
        if matches and phase in marker["blocking_phases"] and marker["blocking_reason"].strip():
            blocked.append({"id": marker.get("id"), "reason": marker["blocking_reason"],
                            "task_ids": marker["task_ids"], "requirements": marker["requirements"]})
    return {"schema_version": 1, "phase": phase, "open_count": len(opened), "batch": batches(retained, markers.get("umbrella") if isinstance(markers, dict) else None),
            "blocked": blocked, "blocked_ids": [m["id"] for m in blocked], "allowed": not blocked, "warnings": []}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    gathering = commands.add_parser("collect")
    gathering.add_argument("--spec", required=True)
    gathering.add_argument("--challenge")
    gathering.add_argument("--previous")
    answering = commands.add_parser("answer")
    answering.add_argument("--markers", required=True)
    answering.add_argument("--answers", required=True)
    gating = commands.add_parser("gate")
    gating.add_argument("--markers", required=True)
    gating.add_argument("--phase", required=True, choices=PHASES)
    gating.add_argument("--task-id")
    gating.add_argument("--requirements", nargs="*", default=[])
    args = parser.parse_args()
    try:
        if args.command == "collect":
            output = collect(read_text(args.spec), read_text(args.challenge) if args.challenge else "",
                             parse_json(read_text(args.previous)) if args.previous else None)
        elif args.command == "answer":
            output = answer(parse_json(read_text(args.markers)), parse_json(read_text(args.answers)))
        else:
            output = gate(parse_json(read_text(args.markers)), args.phase, args.task_id, args.requirements)
    except (OSError, ValueError, RecursionError) as exc:
        message = str(exc) if isinstance(exc, InvalidInput) else "unavailable or malformed clarification input"
        print(json.dumps({"schema_version": 1, "markers": [], "batch": [], "warnings": [message], "error": message}))
        return 1
    print(json.dumps(output, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
