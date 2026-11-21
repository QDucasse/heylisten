#!/usr/bin/env python3
"""heylisten Claude Code hook: turns hook events into marker files.

Registered for Notification, Stop, UserPromptSubmit, PostToolUse, SessionEnd.
Writes ~/.claude/heylisten/<session_id>.json with {"state": "permission"|"reply", ...}.
Never fails loudly: always exits 0, never prints to stdout.
"""
import json
import os
import sys
import time

MARKER_DIR = os.environ.get(
    "HEYLISTEN_DIR", os.path.join(os.path.expanduser("~"), ".claude", "heylisten")
)


def marker_path(sid):
    safe = "".join(c for c in sid if c.isalnum() or c in "-_")
    return os.path.join(MARKER_DIR, safe + ".json") if safe else None


def read_marker(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def write_marker(path, data):
    os.makedirs(MARKER_DIR, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def remove(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def classify_notification(ev):
    ntype = ev.get("notification_type") or ""
    msg = ev.get("message") or ""
    if ntype in ("permission_prompt", "elicitation_dialog"):
        return "permission"
    if ntype == "idle_prompt":
        return "reply"
    if ntype == "auth_success":
        return None
    low = msg.lower()
    if "permission" in low or "approve" in low:
        return "permission"
    if "waiting for your input" in low:
        return "reply"
    return None


def main():
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return
    sid = ev.get("session_id") or ""
    path = marker_path(sid)
    if not path:
        return
    name = ev.get("hook_event_name") or ""
    cur = read_marker(path)
    now = time.time()

    def mark(state, message=""):
        write_marker(path, {
            "sessionId": sid,
            "state": state,
            "message": message,
            "ts": now,
            "cwd": ev.get("cwd") or "",
        })

    if name == "Notification":
        state = classify_notification(ev)
        if state == "permission":
            mark("permission", ev.get("message") or "")
        elif state == "reply" and not (cur and cur.get("state") == "permission"):
            # idle_prompt repeats; keep the original Stop timestamp if present.
            if not cur:
                mark("reply", ev.get("message") or "")
    elif name == "Stop":
        mark("reply", "Turn finished")
    elif name in ("UserPromptSubmit", "SessionEnd"):
        remove(path)
    elif name == "PostToolUse":
        if cur and cur.get("state") == "permission":
            remove(path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
