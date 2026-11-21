#!/usr/bin/env python3
"""Merge (or remove) heylisten hooks in ~/.claude/settings.json, keeping everything else.

    install_hooks.py              install (idempotent)
    install_hooks.py --uninstall  remove heylisten hook entries
"""
import json
import os
import shutil
import sys

SETTINGS = os.environ.get(
    "CLAUDE_SETTINGS", os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
)
HOOK_CMD = "python3 ~/.local/share/heylisten/hook.py"
# PostToolUse fires after every tool call, but only matters while a permission marker exists
# (you approved, so it's running again). Starting Python costs ~0.3 s per call, so a cheap grep
# skips it otherwise. A false positive (the word in some other marker's message) only means the
# hook runs and does nothing. `if` keeps the exit code 0 when grep finds nothing.
GUARDED_CMD = (
    "if grep -qs '\"permission\"' \"${HEYLISTEN_DIR:-$HOME/.claude/heylisten}\"/*.json; "
    "then " + HOOK_CMD + "; fi"
)
MARK = "heylisten/hook.py"
# event -> (matcher (None = no matcher key), command)
EVENTS = {
    "Notification": (None, HOOK_CMD),
    "Stop": (None, HOOK_CMD),
    "UserPromptSubmit": (None, HOOK_CMD),
    "PostToolUse": ("*", GUARDED_CMD),
    "SessionEnd": (None, HOOK_CMD),
    "SessionStart": ("compact", HOOK_CMD),   # after a compaction: forget the context size
    "StopFailure": (None, HOOK_CMD),         # the turn ended on an API error
    "PreCompact": (None, HOOK_CMD),
    "SubagentStart": (None, HOOK_CMD),
    "SubagentStop": (None, HOOK_CMD),
}


def is_ours(group):
    return any(MARK in (h.get("command") or "") for h in group.get("hooks", []))


def main():
    uninstall = "--uninstall" in sys.argv
    settings = {}
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            settings = json.load(f)
        shutil.copy2(SETTINGS, SETTINGS + ".bak-heylisten")
    hooks = settings.setdefault("hooks", {})
    changed = []
    for event, (matcher, cmd) in EVENTS.items():
        groups = hooks.get(event, [])
        kept = [g for g in groups if not is_ours(g)]
        if not uninstall:
            entry = {"hooks": [{"type": "command", "command": cmd, "timeout": 5}]}
            if matcher is not None:
                entry = {"matcher": matcher, **entry}
            kept.append(entry)
        if kept != groups:
            changed.append(event)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
    if not hooks:
        settings.pop("hooks", None)
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    tmp = SETTINGS + ".tmp-heylisten"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, SETTINGS)
    verb = "removed" if uninstall else "installed"
    print(f"heylisten hooks {verb} in {SETTINGS} ({', '.join(changed) or 'no change'})")


if __name__ == "__main__":
    main()
