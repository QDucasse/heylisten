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
MARK = "heylisten/hook.py"
# event -> matcher (None = no matcher key)
EVENTS = {
    "Notification": None,
    "Stop": None,
    "UserPromptSubmit": None,
    "PostToolUse": "*",
    "SessionEnd": None,
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
    for event, matcher in EVENTS.items():
        groups = hooks.get(event, [])
        kept = [g for g in groups if not is_ours(g)]
        if not uninstall:
            entry = {"hooks": [{"type": "command", "command": HOOK_CMD, "timeout": 5}]}
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
