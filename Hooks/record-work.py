#!/usr/bin/env python3
"""Keep a minimal, private status record for an opted-in local Codex chat."""

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import time
import unicodedata
import uuid


CACHE_DIR = Path.home() / "Library/Application Support/Local OpenAI Usage/active-work"
START = "UserPromptSubmit"
UPDATE = "PostToolUse"
END = {"Stop", "Interrupt", "SessionEnd"}
TURN_FINGERPRINT = "_turnFingerprint"
MAX_INPUT_BYTES = 8 * 1024 * 1024
FALLBACK_TITLE = "本地 Codex"


def safe_title(value):
    if not isinstance(value, str):
        return FALLBACK_TITLE
    name = unicodedata.normalize("NFC", value)
    visible = "".join(
        char for char in name if char in " _-." or unicodedata.category(char)[0] in "LMN"
    )
    return visible[:48].strip(" _-.") or FALLBACK_TITLE


def project_title(cwd):
    if not isinstance(cwd, str):
        return FALLBACK_TITLE
    directory = Path(cwd)
    if not directory.is_absolute() or directory == Path.home():
        return FALLBACK_TITLE
    return safe_title(directory.name)


@contextlib.contextmanager
def private_cache():
    CACHE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory_fd = os.open(CACHE_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(directory_fd)
        if metadata.st_uid != os.getuid():
            raise PermissionError("Unexpected cache directory owner")
        if stat.S_IMODE(metadata.st_mode) != 0o700:
            os.fchmod(directory_fd, 0o700)
        # Serialize updates and deletion so a tool hook cannot resurrect a finished chat.
        fcntl.flock(directory_fd, fcntl.LOCK_EX)
        yield directory_fd
    finally:
        os.close(directory_fd)


def read_record(directory_fd, record):
    try:
        file_fd = os.open(record, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
        with os.fdopen(file_fd, encoding="utf-8") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_size > 4096:
                return None
            data = json.load(source)
            return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def write_record(directory_fd, record, snapshot):
    temp = f".{uuid.uuid4().hex}.tmp"
    file_fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory_fd)
    try:
        with os.fdopen(file_fd, "w", encoding="utf-8") as destination:
            json.dump(snapshot, destination, ensure_ascii=False)
            destination.write("\n")
        os.replace(temp, record, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temp, dir_fd=directory_fd)


def checklist_counts(event, previous):
    if event.get("tool_name") == "update_plan":
        arguments = event.get("tool_input")
        plan = arguments.get("plan") if isinstance(arguments, dict) else None
        if isinstance(plan, list):
            # The built-in function emits PostToolUse after accepting its checklist.
            statuses = [
                step.get("status") if isinstance(step, dict) and isinstance(step.get("step"), str) else None
                for step in plan
            ]
            if all(status in ("pending", "in_progress", "completed") for status in statuses):
                return statuses.count("completed"), len(statuses)

    completed = previous.get("completedSteps")
    total = previous.get("totalSteps")
    if type(completed) is int and type(total) is int and 0 <= completed <= total <= sys.maxsize:
        return completed, total
    return 0, 0


def record_event(event):
    if not isinstance(event, dict) or event.get("agent_id") or event.get("agent_type"):
        return
    event_name = event.get("hook_event_name")
    session = event.get("session_id")
    if not isinstance(event_name, str) or not isinstance(session, str) or not 1 <= len(session) <= 512:
        return
    if event_name != START and event_name != UPDATE and event_name not in END:
        return

    session_key = hashlib.sha256(session.encode("utf-8")).hexdigest()
    record = session_key + ".json"
    turn = event.get("turn_id")
    turn_fingerprint = None
    if isinstance(turn, str) and 1 <= len(turn) <= 512:
        # Compare consecutive turns without saving the session or turn identifier.
        turn_fingerprint = hashlib.sha256((session_key + turn).encode("utf-8")).hexdigest()

    with private_cache() as directory_fd:
        previous = read_record(directory_fd, record)
        previous_turn = previous.get(TURN_FINGERPRINT) if previous is not None else None
        now = int(time.time())
        if event_name == START:
            if turn_fingerprint is not None and turn_fingerprint == previous_turn:
                return
            snapshot = {"title": project_title(event.get("cwd")), "status": "正在处理", "lastSeen": now}
            if turn_fingerprint is not None:
                snapshot.update({TURN_FINGERPRINT: turn_fingerprint, "startedAt": now, "completedToolCalls": 0})
            write_record(directory_fd, record, snapshot)
            return

        if event_name != "SessionEnd" and (previous is None or previous_turn not in (None, turn_fingerprint)):
            return
        if event_name in END:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(record, dir_fd=directory_fd)
            return

        snapshot = {"title": safe_title(previous.get("title")), "status": "执行中", "lastSeen": now}
        if previous_turn is not None:
            snapshot[TURN_FINGERPRINT] = turn_fingerprint
            started_at = previous.get("startedAt")
            completed = previous.get("completedToolCalls")
            if type(started_at) is int and started_at > 0:
                snapshot["startedAt"] = started_at
            if type(completed) is int and 0 <= completed < sys.maxsize:
                snapshot["completedToolCalls"] = completed + 1
            completed_steps, total_steps = checklist_counts(event, previous)
            if total_steps:
                snapshot["completedSteps"] = completed_steps
                snapshot["totalSteps"] = total_steps
        write_record(directory_fd, record, snapshot)


def main():
    os.umask(0o077)
    try:
        data = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        if len(data) <= MAX_INPUT_BYTES:
            record_event(json.loads(data))
        else:
            while sys.stdin.buffer.read(65536):
                pass
    except (OSError, ValueError, RecursionError):
        # Observing progress must never change how Codex handles a turn.
        pass
    print("{}")


if __name__ == "__main__":
    main()
