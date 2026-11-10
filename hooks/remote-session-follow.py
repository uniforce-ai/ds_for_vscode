#!/usr/bin/env python3
"""Print Codex turn boundaries from ~/.codex/sessions. Message text is dropped."""
import json
import os
import time
from pathlib import Path

KINDS = {"task_started", "task_complete", "turn_aborted"}


def codex_home():
    return Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))


def sessions_root():
    return codex_home() / "sessions"


def newest():
    root = sessions_root()
    if not root.is_dir():
        return None
    files = [path for path in root.glob("*/*/*/*.jsonl") if path.is_file()]
    if not files:
        return None
    return max(files, key=lambda path: path.stat().st_mtime)


def project(line):
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return None
    if obj.get("type") != "event_msg":
        return None
    payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
    name = payload.get("type")
    turn = payload.get("turn_id") or ""
    if name not in KINDS or not isinstance(turn, str) or not turn or len(turn) > 256:
        return None
    return {
        "timestamp": obj.get("timestamp") if isinstance(obj.get("timestamp"), str) else "",
        "type": "event_msg",
        "payload": {"type": name, "turn_id": turn},
    }


def last_event(path):
    size = path.stat().st_size
    window = 262144
    with path.open("rb") as handle:
        if size > window:
            handle.seek(size - window)
            handle.readline()
        data = handle.read()
    found = None
    for raw in data.splitlines():
        item = project(raw.decode("utf-8", "replace"))
        if item is not None:
            found = item
    return found


def emit(item):
    print(json.dumps(item, ensure_ascii=False, separators=(",", ":")), flush=True)


def follow():
    current = None
    offset = 0
    pending = b""
    while True:
        path = newest()
        if path is None:
            time.sleep(0.5)
            continue
        if path != current:
            current = path
            pending = b""
            item = last_event(path)
            offset = path.stat().st_size
            if item is not None:
                emit(item)
            if os.environ.get("DS_CODEX_FOLLOW_ONCE") == "1":
                return
            continue
        size = path.stat().st_size
        if size < offset:
            offset = 0
            pending = b""
        if size > offset:
            with path.open("rb") as handle:
                handle.seek(offset)
                pending += handle.read()
            offset = size
            while b"\n" in pending:
                raw, pending = pending.split(b"\n", 1)
                item = project(raw.decode("utf-8", "replace"))
                if item is not None:
                    emit(item)
        time.sleep(0.4)


if __name__ == "__main__":
    follow()
