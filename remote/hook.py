#!/usr/bin/env python3
"""heylisten Claude Code hook: turns hook events into marker files.

Registered for Notification, Stop, StopFailure, UserPromptSubmit, PostToolUse, SessionEnd,
SessionStart (matcher "compact"), PreCompact, SubagentStart and SubagentStop. Writes, in
~/.claude/heylisten/:
  <sid>.json             {"state": "permission"|"reply"|"error", ...}: Claude is waiting on you
  <sid>.ctx.json         {"tokens": N, "ttl": S, "ts": T}: context size and prompt-cache lifetime
                         at the end of the last turn, read from the transcript
  <sid>.compacting.json  {"ts": T}: a compaction is running
  <sid>.turn.json        {"ts": T}: when the running turn started (UserPromptSubmit)
  <sid>.agent.<id>.json  {"type": ..., "ts": T}: one per running subagent
Never fails loudly: always exits 0, never prints to stdout.
"""
import json
import os
import sys
import time

MARKER_DIR = os.environ.get(
    "HEYLISTEN_DIR", os.path.join(os.path.expanduser("~"), ".claude", "heylisten")
)


def safe_id(s):
    return "".join(c for c in s if c.isalnum() or c in "-_")


def marker_path(sid):
    safe = safe_id(sid)
    return os.path.join(MARKER_DIR, safe + ".json") if safe else None


# StopFailure's `error` categories, as shown in the notification and hover card.
ERRORS = {
    "rate_limit": "rate limited",
    "overloaded": "API overloaded",
    "authentication_failed": "authentication failed",
    "billing_error": "billing problem",
    "invalid_request": "invalid request",
    "server_error": "API server error",
    "max_output_tokens": "hit the output token limit",
}


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
    stem = path[:-len(".json")]
    ctx_path = stem + ".ctx.json"
    compacting_path = stem + ".compacting.json"
    turn_path = stem + ".turn.json"
    agent_path = stem + ".agent." + safe_id(ev.get("agent_id") or "") + ".json" if ev.get("agent_id") else None
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
        remove(compacting_path)
        remove(turn_path)
        tokens, ttl = context_usage(ev.get("transcript_path") or "")
        if tokens:
            write_marker(ctx_path, {"tokens": tokens, "ttl": ttl, "ts": now})
    elif name == "StopFailure":
        err = ev.get("error") or ""
        mark("error", ERRORS.get(err) or err.replace("_", " ") or "API error")
        remove(compacting_path)
        remove(turn_path)
    elif name == "UserPromptSubmit":
        remove(path)
        remove(compacting_path)
        write_marker(turn_path, {"ts": now})
    elif name == "SessionEnd":
        remove(path)
        remove(ctx_path)
        remove(compacting_path)
        remove(turn_path)
        prefix = os.path.basename(stem) + ".agent."
        for n in os.listdir(MARKER_DIR) if os.path.isdir(MARKER_DIR) else []:
            if n.startswith(prefix):
                remove(os.path.join(MARKER_DIR, n))
    elif name == "SessionStart":
        # Only registered for source "compact": the compaction is over, and the old context
        # count is stale until the next Stop.
        remove(ctx_path)
        remove(compacting_path)
    elif name == "PreCompact":
        write_marker(compacting_path, {"trigger": ev.get("trigger") or "", "ts": now})
    elif name == "SubagentStart" and agent_path:
        write_marker(agent_path, {"type": ev.get("agent_type") or "", "ts": now})
    elif name == "SubagentStop" and agent_path:
        remove(agent_path)
    elif name == "PostToolUse":
        if cur and cur.get("state") == "permission":
            remove(path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
