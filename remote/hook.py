#!/usr/bin/env python3
"""heylisten Claude Code hook: turns hook events into marker files.

Registered for Notification, Stop, UserPromptSubmit, PostToolUse, SessionEnd, and SessionStart
(matcher "compact"). Writes ~/.claude/heylisten/<session_id>.json with
{"state": "permission"|"reply", ...}, and <session_id>.ctx.json with {"tokens": N, "ttl": S, "ts": T}
(context size and prompt-cache lifetime at the end of the last turn, read from the transcript).
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


def context_usage(transcript):
    """(tokens, cache ttl in seconds) as of the last main-thread API call. Tokens: its input plus
    cached input. TTL: 300 if the latest cache write went to the 5-minute cache, else 3600 (a
    turn that only read the cache doesn't say; the 1-hour cache is the default).
    Reads only the transcript's tail (it can be many MB)."""
    try:
        with open(transcript, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 512 * 1024))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return None
    tokens = ttl = None
    for line in reversed(lines):
        if '"usage"' not in line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue   # the first line is usually cut in half
        if d.get("type") != "assistant" or d.get("isSidechain"):
            continue
        u = (d.get("message") or {}).get("usage") or {}
        if tokens is None:
            n = sum(u.get(k) or 0 for k in
                    ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
            if n > 0:   # synthetic messages (errors, interrupts) carry zero usage
                tokens = n
        cc = u.get("cache_creation") or {}
        if ttl is None and (cc.get("ephemeral_1h_input_tokens") or cc.get("ephemeral_5m_input_tokens")):
            ttl = 3600 if cc.get("ephemeral_1h_input_tokens") else 300
        if tokens is not None and ttl is not None:
            break
    return tokens, ttl or 3600


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
    ctx_path = path[:-len(".json")] + ".ctx.json"
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
        tokens, ttl = context_usage(ev.get("transcript_path") or "")
        if tokens:
            write_marker(ctx_path, {"tokens": tokens, "ttl": ttl, "ts": now})
    elif name == "UserPromptSubmit":
        remove(path)
    elif name == "SessionEnd":
        remove(path)
        remove(ctx_path)
    elif name == "SessionStart":
        # Only registered for source "compact": the old count is stale until the next Stop.
        remove(ctx_path)
    elif name == "PostToolUse":
        if cur and cur.get("state") == "permission":
            remove(path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
