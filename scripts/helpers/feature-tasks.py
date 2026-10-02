#!/usr/bin/env python3
"""Parse portable task records and validate a bounded execution wave."""

import argparse
import fnmatch
import functools
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import select
import stat
import subprocess
import sys
import time
import uuid
import unicodedata

MAX_BYTES = 2 * 1024 * 1024
MAX_TASKS = 256
MAX_PATHS = 4096
MAX_SCAN = 20000
SCAN_SECONDS = 5
TASK_ID = re.compile(r"T[0-9]{3,9}\Z")
PATH_TEXT = re.compile(r"[A-Za-z0-9_.@%+/*?\[\]-]+\Z")
CONCRETE_TEXT = re.compile(r"[A-Za-z0-9_.@%+/-]+\Z")
TASK_KEYS = {"id", "identity", "requirements", "kind", "title", "task", "reads",
             "files", "creates", "dependencies", "parallel_hint", "status", "supersedes"}


class Invalid(ValueError):
    pass


def digest(value):
    data = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return "sha256:" + hashlib.sha256(data.encode()).hexdigest()


def read_text(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise Invalid("input is not a regular file")
        raw = handle.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise Invalid("input exceeds the byte limit")
    text = raw.decode("utf-8")
    if any(ord(c) < 32 and c not in "\n\r\t" for c in text):
        raise Invalid("input contains control characters")
    return text


def read_json(path):
    return json.loads(read_text(path))


def valid_uuid(value):
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def strings(value, name, maximum=64):
    if not isinstance(value, list) or len(value) > maximum:
        raise Invalid(name + " must be a bounded string array")
    if any(not isinstance(item, str) or not item or len(item) > 1024 or
           any(ord(c) < 32 for c in item) for item in value):
        raise Invalid(name + " contains an invalid string")
    if len(set(value)) != len(value):
        raise Invalid(name + " contains duplicates")
    return list(value)


def normalize(contract, feature_id=None, require_identity=False):
    top_keys = {"schema_version", "feature_id", "tasks", "tombstones", "high_watermark", "contract_digest", "diagnostics", "legacy"}
    if not isinstance(contract, dict) or type(contract.get("schema_version")) is not int or contract.get("schema_version") != 1 or set(contract) - top_keys:
        raise Invalid("unsupported task contract version")
    fid = contract.get("feature_id", feature_id)
    if not valid_uuid(fid) or feature_id is not None and fid != feature_id:
        raise Invalid("feature identity is missing or does not match")
    raw_tasks = contract.get("tasks")
    if not isinstance(raw_tasks, list) or not 0 < len(raw_tasks) <= MAX_TASKS:
        raise Invalid("tasks must contain 1 through 256 records")
    tasks = []
    seen_ids, seen_identity = set(), set()
    for raw in raw_tasks:
        if not isinstance(raw, dict) or set(raw) - TASK_KEYS:
            raise Invalid("task contains unsupported fields")
        task = dict(raw)
        tid, identity = task.get("id"), task.get("identity")
        if tid is not None and (not isinstance(tid, str) or not TASK_ID.fullmatch(tid) or int(tid[1:]) == 0 or tid in seen_ids):
            raise Invalid("invalid or duplicate task ID")
        if identity is not None and (not valid_uuid(identity) or identity in seen_identity):
            raise Invalid("invalid or duplicate task identity")
        if require_identity and (tid is None or identity is None):
            raise Invalid("execution requires reconciled task identities")
        seen_ids.add(tid)
        seen_identity.add(identity)
        title = task.get("title")
        if not isinstance(title, str) or not title.strip() or len(title) > 4096:
            raise Invalid("task title is missing or oversized")
        if task.get("kind", "coding") not in ("coding", "reasoning"):
            raise Invalid("unsupported task kind")
        task.update(kind=task.get("kind", "coding"), title=title.strip())
        for key in ("requirements", "reads", "files", "creates", "dependencies", "supersedes"):
            task[key] = strings(task.get(key, []), key)
        if not all(TASK_ID.fullmatch(dep) for dep in task["dependencies"]):
            raise Invalid("dependency must name a task ID")
        if not isinstance(task.get("parallel_hint", False), bool):
            raise Invalid("parallel_hint must be boolean")
        task["parallel_hint"] = task.get("parallel_hint", False)
        task["status"] = task.get("status", "pending")
        if task["status"] not in ("pending", "completed", "failed", "retired", "in-progress"):
            raise Invalid("unsupported task status")
        task["task"] = task.get("task", title.strip())
        if not isinstance(task["task"], str) or not task["task"].strip() or len(task["task"]) > 8192:
            raise Invalid("task instructions are missing or oversized")
        if task["kind"] == "reasoning" and (task["files"] or task["creates"]):
            raise Invalid("reasoning task cannot claim writes")
        tasks.append(task)
    if require_identity:
        history = contract.get("tombstones", [])
        if not isinstance(history, list) or len(history) > 4096:
            raise Invalid("invalid task history")
        history_ids, history_uuids = set(seen_ids), set(seen_identity)
        for item in history:
            if not isinstance(item, dict) or set(item) - {"id", "identity", "fingerprint", "status"}:
                raise Invalid("invalid retired task record")
            tid, identity = item.get("id"), item.get("identity")
            if not isinstance(tid, str) or not TASK_ID.fullmatch(tid) or int(tid[1:]) == 0 or tid in history_ids or not valid_uuid(identity) or identity in history_uuids:
                raise Invalid("task history reuses an identity")
            history_ids.add(tid)
            history_uuids.add(identity)
        high = contract.get("high_watermark", max(int(tid[1:]) for tid in history_ids))
        if type(high) is not int or high < max(int(tid[1:]) for tid in history_ids) or high > 999999999:
            raise Invalid("task history high watermark is inconsistent")
    return {"schema_version": 1, "feature_id": fid, "tasks": tasks}


def anchor(task):
    keys = ("requirements", "kind", "reads", "files", "creates")
    value = {key: sorted(task[key]) if isinstance(task[key], list) else task[key] for key in keys}
    if not any(task[key] for key in ("requirements", "reads", "files", "creates")):
        value["title"] = task["title"]
    return digest(value)


def seal(contract):
    contract = dict(contract)
    contract.pop("contract_digest", None)
    contract["contract_digest"] = digest({key: value for key, value in contract.items() if key not in ("diagnostics", "legacy")})
    return contract


def reconcile(previous, incoming):
    new = normalize(incoming)
    old = normalize(previous, new["feature_id"], True) if previous else None
    if previous and previous.get("contract_digest") != seal(previous)["contract_digest"]:
        raise Invalid("previous task history digest does not match")
    prior_tasks = old["tasks"] if old else []
    tombstones = previous.get("tombstones", []) if previous else []
    if not isinstance(tombstones, list) or len(tombstones) > 4096:
        raise Invalid("invalid task tombstones")
    used_ids = set()
    for retired in tombstones:
        if not isinstance(retired, dict) or not TASK_ID.fullmatch(str(retired.get("id", ""))) or int(retired["id"][1:]) == 0 or not valid_uuid(retired.get("identity")) or retired["id"] in used_ids:
            raise Invalid("invalid retired task identity")
        used_ids.add(retired["id"])
    previous_by_id = {task["id"]: task for task in prior_tasks}
    previous_by_identity = {task["identity"]: task for task in prior_tasks}
    used_ids.update(previous_by_id)
    high = previous.get("high_watermark", 0) if previous else 0
    if type(high) is not int or high < 0 or high > 999999998:
        raise Invalid("invalid task high watermark")
    high = max([high] + [int(tid[1:]) for tid in used_ids])
    if not old:
        high = max([high] + [int(task["id"][1:]) for task in new["tasks"] if task.get("id")])
    retained, output, remap = set(), [], {}
    for task in new["tasks"]:
        requested_id = task.get("id")
        requested_identity = task.get("identity")
        candidate = None
        if not task["supersedes"]:
            if requested_identity:
                candidate = previous_by_identity.get(requested_identity)
                if old and candidate is None:
                    raise Invalid("unrecognized persistent task identity")
                if candidate and requested_id and candidate["id"] != requested_id:
                    raise Invalid("task ID does not match its persistent identity")
                if candidate and anchor(candidate) != anchor(task) and not (
                    candidate["kind"] == task["kind"] and
                    (set(candidate["requirements"]) & set(task["requirements"]) or
                     set(candidate["files"] + candidate["creates"]) & set(task["files"] + task["creates"]))):
                    raise Invalid("persistent identity reused for unrelated work")
            elif requested_id in previous_by_id:
                candidate = previous_by_id[requested_id]
                if anchor(candidate) != anchor(task):
                    raise Invalid("task ID reused for unrelated scope; use supersedes or a new task")
            else:
                matches = [item for item in prior_tasks if anchor(item) == anchor(task) and item["id"] not in retained]
                if len(matches) == 1:
                    candidate = matches[0]
        if candidate:
            if candidate["id"] in retained:
                raise Invalid("persistent identity reused in multiple tasks")
            task["id"], task["identity"] = candidate["id"], candidate["identity"]
            retained.add(task["id"])
        else:
            if requested_id in used_ids and not task["supersedes"]:
                raise Invalid("retired task ID cannot be reused")
            for reference in task["supersedes"]:
                if reference not in previous_by_id and reference not in previous_by_identity:
                    raise Invalid("supersedes references an unknown prior task")
            # Preserve declared first-import IDs, then allocate only above history.
            if not old and requested_id:
                task["id"] = requested_id
                high = max(high, int(requested_id[1:]))
            else:
                high += 1
                if high > 999999999:
                    raise Invalid("task ID allocation exhausted")
                task["id"] = "T%03d" % high
            task["identity"] = str(uuid.uuid5(uuid.UUID(new["feature_id"]), task["id"] + ":" + anchor(task))) if not old else str(uuid.uuid4())
            task["status"] = "pending"
        if requested_id:
            remap[requested_id] = task["id"]
        output.append(task)
    for task in output:
        task["dependencies"] = [remap.get(dep, dep) for dep in task["dependencies"]]
        for reference in task["supersedes"]:
            prior = previous_by_id.get(reference) or previous_by_identity.get(reference)
            if prior and prior["id"] in retained:
                raise Invalid("superseded task cannot remain active")
    retired_ids = {item["id"] for item in tombstones}
    for task in prior_tasks:
        if task["id"] not in retained and task["id"] not in retired_ids:
            tombstones.append({"id": task["id"], "identity": task["identity"], "fingerprint": anchor(task), "status": "retired"})
    return seal({"schema_version": 1, "feature_id": new["feature_id"], "tasks": output,
                 "tombstones": tombstones, "high_watermark": high})


def parse_tasks(path, feature_id, raw=False):
    text = read_text(path)
    blocks, active = [], None
    for line in text.splitlines(keepends=True):
        if re.fullmatch(r"```octopus-tasks[^\S\n]*\n?", line):
            if active is not None:
                raise Invalid("nested octopus-tasks contract")
            active = []
        elif active is not None and line.strip() == "```":
            blocks.append("".join(active))
            active = None
        elif active is not None:
            active.append(line)
    if active is not None:
        raise Invalid("unterminated octopus-tasks contract")
    if len(blocks) > 1:
        raise Invalid("multiple octopus-tasks contracts")
    if blocks:
        incoming = normalize(json.loads(blocks[0]), feature_id)
        # Parsing is repeatable for published contracts; reconciliation assigns new IDs.
        if all(task.get("id") and task.get("identity") for task in incoming["tasks"]):
            original = json.loads(blocks[0])
            normalize(original, feature_id, True)
            incoming["tombstones"] = original.get("tombstones", [])
            incoming["high_watermark"] = original.get("high_watermark", max(int(task["id"][1:]) for task in incoming["tasks"]))
            sealed = seal(incoming)
            if original.get("contract_digest") and original["contract_digest"] != sealed["contract_digest"]:
                raise Invalid("published task contract digest does not match")
            return sealed
        if raw:
            return incoming
        return reconcile(None, incoming)
    tasks = []
    for match in re.finditer(r"^\s*- \[([ xX])\]\s+(T[0-9]{3,9})\s+(.+)$", text, re.M):
        checked, tid, body = match.groups()
        parallel = bool(re.search(r"\[P\]", body))
        requirements = re.findall(r"\[(US[0-9]+|FR-[0-9]+)\]", body)
        title = re.sub(r"\[(?:P|US[0-9]+|FR-[0-9]+)\]\s*", "", body).strip()
        # Only explicit backtick paths or labelled clauses grant file authority.
        files = re.findall(r"`([A-Za-z0-9_.@%+/*?\[\]-]+)`", title)
        task = {"id": tid, "title": title, "requirements": requirements, "files": files,
                "parallel_hint": parallel, "status": "completed" if checked.lower() == "x" else "pending"}
        for label, key in (("Files", "files"), ("Creates", "creates"), ("Reads", "reads"), ("Depends", "dependencies")):
            clause = re.search(r"\b" + label + r":\s*([^;\n]+)", body)
            if clause:
                task[key] = [part.strip().strip("`") for part in clause[1].split(",") if part.strip()]
        tasks.append(task)
    if not tasks:
        return {"schema_version": 1, "feature_id": feature_id, "tasks": [], "legacy": True,
                "diagnostics": ["No supported task metadata; retain legacy planning."]}
    if raw:
        return normalize({"schema_version": 1, "feature_id": feature_id, "tasks": tasks}, feature_id)
    contract = reconcile(None, {"schema_version": 1, "feature_id": feature_id, "tasks": tasks})
    contract["diagnostics"] = ["Imported Spec Kit metadata; checkbox status is not completion proof."]
    return seal(contract)


def git_bytes(root, *arguments):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process = subprocess.Popen(["git", "-c", "core.fsmonitor=false", "-C", str(root), *arguments], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=environment)
    data, deadline = bytearray(), time.monotonic() + SCAN_SECONDS
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise Invalid("Git validation exceeded the time limit")
            block = os.read(process.stdout.fileno(), min(65536, MAX_BYTES + 1 - len(data)))
            if not block:
                break
            data.extend(block)
            if len(data) > MAX_BYTES:
                raise Invalid("Git validation exceeded the output limit")
        if process.wait(timeout=max(0.01, deadline - time.monotonic())):
            raise Invalid("Git state could not be validated")
        return bytes(data)
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def git_state(root):
    if Path(os.fsdecode(git_bytes(root, "rev-parse", "--show-toplevel")).strip()).resolve() != root:
        raise Invalid("execution root must be the repository root")
    raw = git_bytes(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no")
    records = raw.split(b"\0")
    changed, index = [], 0
    while index < len(records):
        record = records[index]
        index += 1
        if not record:
            continue
        if len(record) < 4:
            raise Invalid("invalid Git status record")
        changed.append(os.fsdecode(record[3:]))
        if b"R" in record[:2] or b"C" in record[:2]:
            if index >= len(records) or not records[index]:
                raise Invalid("incomplete Git rename record")
            changed.append(os.fsdecode(records[index]))
            index += 1
    return {"status": raw.hex(), "head": git_bytes(root, "rev-parse", "HEAD").decode().strip()}, changed


def safe_path(path, glob=False):
    if not isinstance(path, str) or not path or not PATH_TEXT.fullmatch(path):
        raise Invalid("path is not supported by the execution scope contract")
    path = path.rstrip("/")
    parts = path.split("/")
    if path.startswith("/") or any(part in ("", ".", "..", ".git") for part in parts):
        raise Invalid("path is outside repository authority")
    if not glob and not CONCRETE_TEXT.fullmatch(path):
        raise Invalid("planned create must be a concrete path")
    return path.rstrip("/")


def path_matches(path, pattern):
    parts, pattern_parts = tuple(path.split("/")), tuple(pattern.rstrip("/").split("/"))
    if len(parts) > 128 or len(pattern_parts) > 128:
        raise Invalid("path pattern exceeds its depth limit")
    @functools.lru_cache(maxsize=MAX_SCAN)
    def matches(parts, pattern):
        if not pattern:
            return not parts
        if pattern[0] == "**":
            return matches(parts, pattern[1:]) or bool(parts) and matches(parts[1:], pattern)
        return bool(parts) and fnmatch.fnmatchcase(parts[0], pattern[0]) and matches(parts[1:], pattern[1:])
    return matches(parts, pattern_parts)


class Snapshot:
    def __init__(self, root):
        self.root = root
        self.deadline = time.monotonic() + SCAN_SECONDS
        self.count = 0
        info = root.lstat()
        self.facts = {".": [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns]}

    def check(self):
        self.count += 1
        if self.count > MAX_SCAN or time.monotonic() > self.deadline:
            raise Invalid("filesystem validation exceeded its scan limit")

    def inspect(self, relative):
        self.check()
        current = self.root
        for part in relative.split("/"):
            current = current / part
            try:
                info = current.lstat()
            except FileNotFoundError:
                return None
            if stat.S_ISLNK(info.st_mode):
                raise Invalid("symlink component cannot grant write authority")
            self.facts[str(current.relative_to(self.root))] = [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
        if not stat.S_ISREG(info.st_mode) and not stat.S_ISDIR(info.st_mode):
            raise Invalid("non-file scope cannot grant authority")
        return info

    def walk(self, directory):
        pending = [directory]
        found = []
        while pending:
            folder = pending.pop()
            self.check()
            with os.scandir(self.root / folder) as entries:
                names = sorted(entry.name for entry in entries)
            for name in names:
                self.check()
                if name == ".git":
                    continue
                relative = str(PurePosixPath(folder) / name) if folder else name
                info = self.inspect(relative)
                if info is None:
                    raise Invalid("filesystem changed during validation")
                found.append(relative)
                if len(found) > MAX_PATHS:
                    raise Invalid("path expansion exceeded its result limit")
                if stat.S_ISDIR(info.st_mode):
                    pending.append(relative)
        return found

    def expand(self, declaration, create=False):
        path = safe_path(declaration, glob=not create)
        if create:
            if self.inspect(path) is not None:
                raise Invalid("planned create already exists")
            ancestor = str(PurePosixPath(path).parent)
            while ancestor != ".":
                info = self.inspect(ancestor)
                if info is not None:
                    if not stat.S_ISDIR(info.st_mode):
                        raise Invalid("planned create ancestor is not a directory")
                    break
                ancestor = str(PurePosixPath(ancestor).parent)
            return [{"path": path, "directory": False, "inode": None, "create": True}]
        if any(char in path for char in "*?["):
            prefix = []
            for part in path.split("/"):
                if any(char in part for char in "*?["):
                    break
                prefix.append(part)
            base = "/".join(prefix)
            if base and self.inspect(base) is None:
                raise Invalid("glob prefix does not exist")
            if base and not stat.S_ISDIR(self.inspect(base).st_mode):
                raise Invalid("glob prefix is not a directory")
            candidates = self.walk(base)
            # Path.match keeps ordinary stars within one component. Recursive **
            # has explicit directory semantics rather than fnmatch's slash matching.
            paths = []
            for item in candidates:
                self.check()
                if path_matches(item, path):
                    paths.append(item)
            if not paths:
                raise Invalid("glob matched no paths")
        else:
            paths = [path]
        claims = []
        for item in paths:
            safe_path(item)
            info = self.inspect(item)
            if info is None:
                raise Invalid("declared path does not exist")
            directory = stat.S_ISDIR(info.st_mode)
            claims.append({"path": item, "directory": directory, "inode": [info.st_dev, info.st_ino], "create": False})
            if directory:
                # Keep the directory claim even when it is empty.
                for child in self.walk(item):
                    child_info = self.inspect(child)
                    claims.append({"path": child, "directory": stat.S_ISDIR(child_info.st_mode),
                                   "inode": [child_info.st_dev, child_info.st_ino], "create": False})
        if len(claims) > MAX_PATHS:
            raise Invalid("path expansion exceeded its result limit")
        return claims


def collision_path(path):
    """Conservatively detect aliases without changing exact scope authority."""
    return unicodedata.normalize("NFC", unicodedata.normalize("NFC", path).casefold())


def overlap(a, b):
    left, right = collision_path(a["path"]), collision_path(b["path"])
    return left == right or a.get("inode") is not None and a.get("inode") == b.get("inode") or \
        a["directory"] and right.startswith(left + "/") or \
        b["directory"] and left.startswith(right + "/")


def path_state(root, path):
    """Hash one path through directory descriptors, without following symlinks."""
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        parts = path.split("/")
        for component in parts[:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        info = os.stat(parts[-1], dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            return {"type": "directory", "mode": stat.S_IMODE(info.st_mode)}
        if not stat.S_ISREG(info.st_mode):
            raise Invalid("completion evidence cannot follow non-file paths")
        if info.st_size > 16 * 1024 * 1024:
            raise Invalid("completion evidence exceeded its file byte limit")
        child = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=descriptor)
        with os.fdopen(child, "rb") as handle:
            hashed = hashlib.sha256()
            remaining = 16 * 1024 * 1024 + 1
            while remaining:
                block = handle.read(min(65536, remaining))
                if not block:
                    break
                hashed.update(block)
                remaining -= len(block)
            if not remaining:
                raise Invalid("completion evidence exceeded its file byte limit")
            after = os.fstat(handle.fileno())
            if (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns):
                raise Invalid("completion path changed while hashing")
        return {"type": "file", "mode": stat.S_IMODE(info.st_mode), "digest": "sha256:" + hashed.hexdigest()}
    except FileNotFoundError:
        return {"type": "missing"}
    finally:
        os.close(descriptor)


def capture(root, contract, selected_wave, wave_digest, completed, status, evidence):
    if digest(selected_wave) != wave_digest or selected_wave.get("contract_digest") != contract.get("contract_digest"):
        raise Invalid("parent wave snapshot seal does not match")
    normalized = normalize(contract, require_identity=True)
    if seal(contract)["contract_digest"] != contract.get("contract_digest"):
        raise Invalid("task contract digest does not match")
    execution_root = Path(root).resolve()
    if selected_wave.get("execution_root_digest") != digest(str(execution_root)):
        raise Invalid("parent wave belongs to another execution root")
    by_id = {task["id"]: task for task in normalized["tasks"]}
    if not isinstance(completed, dict) or completed.get("contract_digest") != contract["contract_digest"]:
        completed = {"contract_digest": contract["contract_digest"], "tasks": []}
    records = [item for item in completed.get("tasks", []) if isinstance(item, dict)]
    snapshot = Snapshot(execution_root)
    for selected in selected_wave["selected"]:
        task = by_id.get(selected["id"])
        if not task or task["identity"] != selected["identity"]:
            raise Invalid("parent selected identity does not match")
        states = {}
        if status == "completed":
            paths = set(selected.get("expanded_files", []) + selected["creates"])
            for path in selected["files"] + selected["creates"]:
                info = snapshot.inspect(path)
                if info and stat.S_ISDIR(info.st_mode):
                    paths.update(snapshot.walk(path))
            if len(paths) > MAX_PATHS:
                raise Invalid("completion evidence exceeded its path limit")
            total_bytes = 0
            for path in sorted(paths):
                snapshot.check()
                state = path_state(execution_root, path)
                states[path] = state
                if state["type"] == "file":
                    total_bytes += (execution_root / path).stat().st_size
                    if total_bytes > 64 * 1024 * 1024:
                        raise Invalid("completion evidence exceeded its total byte limit")
        records = [item for item in records if item.get("id") != selected["id"]]
        record = {"id": task["id"], "identity": task["identity"], "contract_digest": contract["contract_digest"],
                  "status": status, "parent_verified": True, "evidence": evidence}
        if status == "completed":
            record["write_evidence"] = {"execution_root_digest": digest(str(execution_root)), "paths": states,
                                        "launch_snapshot": selected_wave["snapshot_digest"]}
        records.append(record)
    return {"contract_digest": contract["contract_digest"], "tasks": records}


def resume(root, source_root, contract, history, baseline):
    """Check historical bytes without granting current-run completion authority."""
    deadline = time.monotonic() + 15
    def budget():
        if time.monotonic() > deadline:
            raise Invalid("historical verification exceeded its time limit")
    normalized = normalize(contract, require_identity=True)
    expected = seal(contract)["contract_digest"]
    if contract.get("contract_digest") != expected:
        raise Invalid("task contract digest does not match")
    if not isinstance(baseline, str) or not re.fullmatch(r"[a-f0-9]{40,64}", baseline):
        raise Invalid("resume requires an immutable current HEAD")
    if not isinstance(history, dict) or history.get("schema_version") != 1 or history.get("contract_digest") != expected or not isinstance(history.get("tasks"), list) or len(history["tasks"]) > MAX_TASKS:
        raise Invalid("unsupported historical task evidence")
    roots = [Path(root).resolve()]
    if source_root and Path(source_root).resolve() not in roots:
        roots.append(Path(source_root).resolve())
    states, dirt, snapshots = [], [], []
    for checkout in roots:
        state, dirty = git_state(checkout)
        if state["head"] != baseline:
            raise Invalid("resume HEAD does not match the parent baseline")
        states.append(state); dirt.append(dirty); snapshots.append(Snapshot(checkout))
    by_id = {task["id"]: task for task in normalized["tasks"]}
    candidates, rejected, seen = {}, [], set()
    for record in history["tasks"]:
        budget()
        tid = record.get("id") if isinstance(record, dict) else None
        task = by_id.get(tid)
        try:
            if not task or tid in seen or record.get("identity") != task["identity"] or record.get("status") != "completed" or record.get("contract_digest") != expected:
                raise Invalid("historical identity or contract does not match")
            seen.add(tid)
            if task["kind"] != "coding":
                raise Invalid("historical reasoning result has no committed output scope")
            evidence = record.get("evidence")
            if not isinstance(evidence, dict) or set(evidence) - {"run_id", "baseline_commit", "files"} or not isinstance(evidence.get("run_id"), str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,256}", evidence["run_id"]):
                raise Invalid("historical run evidence is missing")
            old_head = evidence.get("baseline_commit")
            if not isinstance(old_head, str) or not re.fullmatch(r"[a-f0-9]{40,64}", old_head):
                raise Invalid("historical baseline is missing")
            files = evidence.get("files")
            if not isinstance(files, list) or not 0 < len(files) <= MAX_PATHS:
                raise Invalid("historical scope evidence is missing")
            file_states = {}
            for item in files:
                if not isinstance(item, dict) or set(item) - {"relativepath", "type", "mode", "digest"}:
                    raise Invalid("unsupported historical file evidence")
                path = item.get("relativepath")
                if not isinstance(path, str) or len(path) > 1024 or any(ord(char) < 32 for char in path) or path.startswith("/") or any(part in ("", ".", "..", ".git") for part in path.split("/")) or path in file_states:
                    raise Invalid("historical file path is outside authority")
                value = {key: item[key] for key in ("type", "mode", "digest") if key in item}
                if value.get("type") not in ("file", "directory", "missing"):
                    raise Invalid("historical path type is unsupported")
                file_states[path] = value
            for index, checkout in enumerate(roots):
                budget()
                snapshot = snapshots[index]
                git_bytes(checkout, "merge-base", "--is-ancestor", old_head, baseline)
                claims, scope_paths = [], set()
                for declaration in task["reads"]:
                    snapshot.expand(declaration)
                for declaration in task["files"] + task["creates"]:
                    declaration = safe_path(declaration, glob=declaration in task["files"])
                    if snapshot.inspect(declaration) is None and not any(char in declaration for char in "*?["):
                        expanded = [{"path": declaration, "directory": False, "inode": None}]
                    else:
                        expanded = snapshot.expand(declaration)
                    claims.extend(expanded); scope_paths.update(claim["path"] for claim in expanded)
                if not scope_paths.issubset(file_states):
                    raise Invalid("historical evidence omits current task scope")
                total_bytes = 0
                for path, expected_state in file_states.items():
                    budget()
                    snapshot.check()
                    permitted = False
                    for declaration in task["files"] + task["creates"]:
                        if path_matches(path, declaration) or path.startswith(declaration.rstrip("/") + "/") and file_states.get(declaration.rstrip("/"), {}).get("type") == "directory":
                            permitted = True
                    if not permitted:
                        raise Invalid("historical evidence exceeds task authority")
                    actual = path_state(checkout, path)
                    if actual != expected_state:
                        raise Invalid("historical scope fingerprint does not match")
                    tree = git_bytes(checkout, "ls-tree", "-z", baseline, "--", path)
                    if actual["type"] == "file":
                        total_bytes += (checkout / path).stat().st_size
                        if total_bytes > 64 * 1024 * 1024:
                            raise Invalid("historical evidence exceeded its byte limit")
                        header, tree_path = tree.rstrip(b"\0").split(b"\t", 1)
                        mode, kind, oid = header.split()
                        current_oid = git_bytes(checkout, "hash-object", "--no-filters", "--", path).strip()
                        if tree_path.decode() != path or kind != b"blob" or mode not in (b"100644", b"100755") or oid != current_oid or bool(actual["mode"] & 0o111) != (mode == b"100755"):
                            raise Invalid("historical scope does not match committed HEAD")
                    elif actual["type"] == "missing":
                        if tree or path in task["creates"]:
                            raise Invalid("historical missing path is not committed completion")
                    elif not tree or not any(other.startswith(path + "/") and state["type"] == "file" for other, state in file_states.items()):
                        raise Invalid("historical directory has no committed files")
                for dirty_path in dirt[index]:
                    snapshot.check()
                    try:
                        info = snapshot.inspect(dirty_path)
                    except (Invalid, OSError):
                        info = None
                    change = {"path": dirty_path, "directory": bool(info and stat.S_ISDIR(info.st_mode)), "inode": [info.st_dev, info.st_ino] if info else None}
                    if any(overlap(claim, change) for claim in claims):
                        raise Invalid("historical task scope has uncommitted user changes")
            candidates[tid] = {"id": tid, "identity": task["identity"], "status": "completed", "contract_digest": expected, "evidence": evidence}
        except (Invalid, OSError, ValueError, subprocess.SubprocessError):
            if task:
                candidates.pop(tid, None)
                rejected.append({"id": tid, "reason": "historical identity, committed scope or evidence could not be verified"})
    changed = True
    while changed:
        changed = False
        for tid in list(candidates):
            if any(dep not in candidates for dep in by_id[tid]["dependencies"]):
                rejected.append({"id": tid, "reason": "historical dependency lacks verified completion"})
                del candidates[tid]; changed = True
    # Reject cycles even when every member presented otherwise matching evidence.
    cycle_cache = {}
    def acyclic(tid, visiting):
        budget()
        if tid in visiting:
            return False
        if tid not in cycle_cache:
            cycle_cache[tid] = all(acyclic(dep, visiting | {tid}) for dep in by_id[tid]["dependencies"] if dep in candidates)
        return cycle_cache[tid]
    candidates = {tid: value for tid, value in candidates.items() if acyclic(tid, set())}
    for index, checkout in enumerate(roots):
        final, _ = git_state(checkout)
        if final != states[index]:
            raise Invalid("Git state changed during historical verification")
    return {"schema_version": 1, "contract_digest": expected, "baseline": baseline,
            "tasks": list(candidates.values()), "rejected": rejected,
            "snapshot_digest": digest({"contract": expected, "history": history, "roots": [str(value) for value in roots], "git": states, "facts": [snapshot.facts for snapshot in snapshots], "tasks": list(candidates.values())})}


def wave(root, source_root, contract, completed, limit):
    deadline = time.monotonic() + 15
    def budget():
        if time.monotonic() > deadline:
            raise Invalid("wave validation exceeded its time limit")
    comparisons = 0
    def conflicts(first, second):
        nonlocal comparisons
        comparisons += 1
        if comparisons % 256 == 0:
            budget()
        return overlap(first, second)
    normalized = normalize(contract, require_identity=True)
    expected = seal({key: value for key, value in contract.items() if key != "contract_digest"})["contract_digest"]
    if contract.get("contract_digest") != expected:
        raise Invalid("task contract digest is missing or does not match")
    tasks = normalized["tasks"]
    by_id = {task["id"]: task for task in tasks}
    proof, excluded, owned = set(), {}, {}
    execution_root = Path(root).resolve()
    if isinstance(completed, dict) and completed.get("contract_digest") == expected:
        for record in completed.get("tasks", []):
            if not isinstance(record, dict):
                continue
            task = by_id.get(record.get("id"))
            if task and record.get("identity") == task["identity"] and record.get("parent_verified") is True and \
               record.get("contract_digest") == expected and \
               isinstance(record.get("evidence"), str) and record["evidence"].strip():
                if record.get("status") == "completed":
                    proof.add(task["id"])
                    writes = record.get("write_evidence", {})
                    if isinstance(writes, dict) and writes.get("execution_root_digest") == digest(str(execution_root)) and isinstance(writes.get("paths"), dict):
                        owned.update(writes["paths"])
                elif record.get("status") in ("failed", "blocked"):
                    excluded[task["id"]] = "parent recorded task " + record["status"]
    roots = [execution_root]
    if source_root and Path(source_root).resolve() not in roots:
        roots.append(Path(source_root).resolve())
    initial_git, dirty, snapshots = [], [], []
    for checkout in roots:
        state, paths = git_state(checkout)
        initial_git.append(state)
        dirty.append(paths)
        snapshots.append(Snapshot(checkout))
    blocked = {}
    def block(tid, reason):
        blocked.setdefault(tid, [])
        if reason not in blocked[tid]:
            blocked[tid].append(reason)
    closure_cache = {}
    def closure(tid, visiting):
        budget()
        if tid in visiting:
            raise Invalid("dependency cycle")
        if tid in closure_cache:
            return closure_cache[tid]
        task = by_id.get(tid)
        if task is None:
            raise Invalid("missing dependency " + tid)
        result = set()
        for dep in task["dependencies"]:
            result.add(dep)
            result.update(closure(dep, visiting | {tid}))
        closure_cache[tid] = result
        return result
    ready, claims, reads, concrete = [], {}, {}, {}
    serial = []
    for task in tasks:
        budget()
        tid = task["id"]
        if tid in proof:
            continue
        if tid in excluded:
            block(tid, excluded[tid])
        try:
            dependencies = closure(tid, set())
            missing = sorted(dependencies - proof)
            if missing:
                block(tid, "unverified dependencies: " + ", ".join(missing))
        except Invalid as error:
            block(tid, str(error))
        writes, contexts = [], []
        try:
            if task["kind"] == "coding" and not (task["files"] or task["creates"]):
                raise Invalid("coding task has no declared write authority")
            for path in task["files"]:
                writes.extend(snapshots[0].expand(path))
            for path in task["creates"]:
                writes.extend(snapshots[0].expand(path, True))
            for path in task["reads"]:
                # A missing input produced by an explicit dependency is resolved
                # on a later wave. It does not grant write authority now.
                contexts.extend(snapshots[0].expand(path))
            for index, paths in enumerate(dirty):
                root_writes = writes
                if index:
                    root_writes = []
                    for claim in writes:
                        info = snapshots[index].inspect(claim["path"])
                        root_writes.append({**claim, "inode": [info.st_dev, info.st_ino] if info else None})
                    # Dirty original files may match a glob even when they were
                    # never copied into the isolated execution checkout.
                    for path in paths:
                        budget()
                        for declaration in task["files"]:
                            if any(char in declaration for char in "*?[") and path_matches(path, declaration):
                                root_writes.append({"path": path, "directory": False, "inode": None})
                for path in paths:
                    budget()
                    try:
                        change_info = snapshots[index].inspect(path)
                    except (Invalid, OSError):
                        change_info = None
                    change = {"path": path, "directory": bool(change_info and stat.S_ISDIR(change_info.st_mode)),
                              "inode": [change_info.st_dev, change_info.st_ino] if change_info else None}
                    if any(conflicts(claim, change) for claim in root_writes):
                        if index == 0 and path in owned and path_state(execution_root, path) == owned[path]:
                            continue
                        raise Invalid("uncommitted changes overlap task authority in " + ("execution" if index == 0 else "source") + " checkout")
        except (Invalid, OSError) as error:
            block(tid, str(error))
            serial.append({"id": tid, "reason": str(error)})
        claims[tid], reads[tid] = writes, contexts
        concrete[tid] = {"files": sorted({claim["path"] for claim in writes if not claim["create"] and CONCRETE_TEXT.fullmatch(claim["path"])}),
                         "creates": sorted({claim["path"] for claim in writes if claim["create"]}),
                         "reads": sorted({claim["path"] for claim in contexts if CONCRETE_TEXT.fullmatch(claim["path"])}),
                         "expanded_files": sorted({claim["path"] for claim in writes if not claim["create"]})}
        if tid not in blocked:
            ready.append(tid)
    for tid in list(ready):
        budget()
        for producer in tasks:
            pid = producer["id"]
            if pid == tid or pid in proof:
                continue
            if any(conflicts(reader, writer) for reader in reads[tid] for writer in claims[pid]) and pid not in by_id[tid]["dependencies"]:
                block(tid, "read/write producer has no declared dependency: " + pid)
        if tid in blocked:
            ready.remove(tid)
    for tid in ready:
        if not by_id[tid]["parallel_hint"]:
            serial.append({"id": tid, "reason": "parallel hint narrows this task to serial execution"})
    for index, tid in enumerate(ready):
        budget()
        for other in ready[index + 1:]:
            if any(conflicts(a, b) for a in claims[tid] for b in claims[other]):
                serial.append({"id": tid, "reason": "write authority overlaps " + other})
                serial.append({"id": other, "reason": "write authority overlaps " + tid})
    selected_ids = ready[:1] if any(item["id"] in ready for item in serial) else ready[:limit]
    selected = [{**by_id[tid], **concrete[tid], "execution_index": index + 1} for index, tid in enumerate(selected_ids)]
    # Recheck every observed inode and both Git snapshots before publishing a wave.
    snapshot_facts = []
    for index, snapshot in enumerate(snapshots):
        for path, fact in list(snapshot.facts.items()):
            budget()
            info = (snapshot.root / path).lstat()
            now = [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
            if now != fact:
                raise Invalid("filesystem changed during wave validation")
        final_git, _ = git_state(roots[index])
        if final_git != initial_git[index]:
            raise Invalid("Git state changed during wave validation")
        snapshot_facts.append(snapshot.facts)
    adapter = {"schema_version": 1, "subtasks": [
        {"id": task["execution_index"], "kind": task["kind"], "title": task["title"],
         "reads": task["reads"], "files": task["files"], "creates": task["creates"], "task": task["task"]}
        for task in selected]}
    diagnostics = []
    if not any(task["kind"] == "coding" for task in selected):
        adapter = None
        if selected:
            diagnostics.append("Reasoning-only wave uses the existing reasoning path; decomposition v1 requires coding.")
    return {"schema_version": 1, "contract_digest": expected,
            "execution_root_digest": digest(str(execution_root)),
            "snapshot_digest": digest({"contract": expected, "git": initial_git, "facts": snapshot_facts, "selected": selected}),
            "ready_ids": ready, "completed_ids": sorted(proof), "selected": selected,
            "decomposition": adapter, "blocked_pending": [{"id": tid, "reasons": reasons} for tid, reasons in blocked.items()],
            "serial_reasons": serial, "diagnostics": diagnostics}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    parse = commands.add_parser("parse")
    parse.add_argument("--tasks", required=True)
    parse.add_argument("--feature-id", required=True)
    parse.add_argument("--raw", action="store_true")
    rec = commands.add_parser("reconcile")
    rec.add_argument("--previous", required=True)
    rec.add_argument("--incoming", required=True)
    schedule = commands.add_parser("wave")
    schedule.add_argument("--root", required=True)
    schedule.add_argument("--source-root")
    schedule.add_argument("--contract", required=True)
    schedule.add_argument("--completed", required=True)
    schedule.add_argument("--limit", type=int, required=True)
    record = commands.add_parser("capture")
    for flag in ("root", "contract", "wave", "wave-digest", "completed", "evidence"):
        record.add_argument("--" + flag, required=True)
    record.add_argument("--status", choices=("completed", "failed", "blocked"), required=True)
    resume_parser = commands.add_parser("resume")
    for flag in ("root", "contract", "history", "baseline"):
        resume_parser.add_argument("--" + flag, required=True)
    resume_parser.add_argument("--source-root")
    args = parser.parse_args()
    try:
        if args.command == "parse":
            if not valid_uuid(args.feature_id):
                raise Invalid("invalid feature UUID")
            output = parse_tasks(args.tasks, args.feature_id, args.raw)
        elif args.command == "reconcile":
            previous = read_json(args.previous)
            output = reconcile(previous if previous else None, read_json(args.incoming))
        elif args.command == "wave":
            if not 1 <= args.limit <= 6:
                raise Invalid("wave limit must be between 1 and 6")
            output = wave(args.root, args.source_root, read_json(args.contract), read_json(args.completed), args.limit)
        elif args.command == "resume":
            output = resume(args.root, args.source_root, read_json(args.contract), read_json(args.history), args.baseline)
        else:
            output = capture(args.root, read_json(args.contract), read_json(args.wave), args.wave_digest,
                             read_json(args.completed), args.status, args.evidence)
        print(json.dumps(output, sort_keys=True, ensure_ascii=True))
        return 0
    except (Invalid, OSError, ValueError, TypeError, RecursionError, subprocess.SubprocessError):
        # Never print input text or paths from an exception, which may be private.
        print(json.dumps({"schema_version": 1, "error": "invalid-task-metadata", "diagnostics": ["Task metadata or repository validation failed; use safe planning fallback."]}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
