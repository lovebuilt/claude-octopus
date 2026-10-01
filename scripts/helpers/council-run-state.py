#!/usr/bin/env python3
"""Serialize council beacons and same-key supersession within one pool."""

import contextlib
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import time


@contextlib.contextmanager
def pool_lock(pool):
    # Kernel locks release when their owner exits, including SIGKILL. Never
    # unlink the lock file: doing so would let writers lock different inodes.
    with (pool / ".run-state.lock").open("a", encoding="utf-8") as handle:
        deadline = time.monotonic() + 10
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("council run-state lock remained busy")
                time.sleep(0.02)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def read_record(path, best_effort=True):
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
        return record if isinstance(record, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}
    except OSError:
        if not best_effort:
            raise
        return {}


def atomic_text(path, text):
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".tmp.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_record(path, record):
    atomic_text(path, json.dumps(record) + "\n")


def creation_order(record):
    order = record.get("created_order", 0)
    return order if isinstance(order, int) and not isinstance(order, bool) and order > 0 else 0


def pool_records(pool, include_staging=False):
    # A sibling may be removed or become unreadable while a poller scans it.
    # The current run's lock and writes still fail if their own paths are broken.
    try:
        for directory in pool.iterdir():
            try:
                if not directory.is_dir() or (directory.name.startswith(".") and not include_staging):
                    continue
            except OSError:
                continue
            path = directory / "run-status.json"
            record = read_record(path)
            if record:
                yield path, record
    except OSError:
        return


def write_status(run_dir, record):
    pool = run_dir.parent
    path = run_dir / "run-status.json"
    with pool_lock(pool):
        existing = read_record(path, best_effort=False)
        if existing:
            # An older completion must merge the supersession mark while holding
            # the same lock as the newer run's scanner.
            record["created_order"] = creation_order(existing)
            record["superseded"] = existing.get("superseded") is True
            record["superseded_by"] = existing.get("superseded_by")
        else:
            counter = pool / ".run-state-sequence"
            try:
                sequence = int(counter.read_text(encoding="utf-8"))
            except (FileNotFoundError, ValueError):
                sequence = 0
            # Include unpublished staging beacons so concurrent creation cannot
            # reuse an order even while another run awaits its directory rename.
            sequence = max([sequence] + [creation_order(item) for _, item in pool_records(pool, True)]) + 1
            atomic_text(counter, str(sequence) + "\n")
            record["created_order"] = sequence
            record["superseded"] = False
            record["superseded_by"] = None
        write_record(path, record)


def supersede(pool, current_dir, key, pointer_name):
    with pool_lock(pool):
        records = [(path, record) for path, record in pool_records(pool)
                   if record.get("supersede_key") == key]
        current_path = current_dir / "run-status.json"
        if not any(path == current_path for path, _ in records):
            return
        # The counter orders current runs even when same-second PID suffixes
        # sort backwards. Legacy beacons have no counter and precede new runs.
        newest_path, newest = max(records, key=lambda item: (creation_order(item[1]), item[1].get("run_id", "")))
        newest_id = newest.get("run_id") or newest_path.parent.name
        for path, record in records:
            updated = dict(record)
            updated["superseded"] = path != newest_path
            updated["superseded_by"] = newest_id if path != newest_path else None
            if updated != record:
                write_record(path, updated)
        atomic_text(pool / pointer_name, newest_id + "\n")


def main():
    if sys.argv[1] == "write":
        write_status(Path(sys.argv[2]), json.load(sys.stdin))
    elif sys.argv[1] == "supersede":
        supersede(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5])
    else:
        raise ValueError("unknown council run-state operation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TimeoutError) as error:
        print("Council run-state update failed: " + str(error), file=sys.stderr)
        sys.exit(1)
