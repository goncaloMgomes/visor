#!/usr/bin/env python3
"""Connect Visor to the AI tools on this computer.

  visor setup config              write ~/.config/visor/config.json (if missing)
  visor setup claude-code         add the hooks to ~/.claude/settings.json (backup first)
  visor setup claude-code --remove
  visor setup codex               how to add the notify script to ~/.codex/config.toml
"""
import json
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import CONFIG_FILE, ROOT  # noqa: E402

CLAUDE_SETTINGS = os.path.expanduser("~/.claude/settings.json")
HOOK = os.path.join(ROOT, "adapters", "claude-code", "hook.sh")
EVENTS = {   # hook event -> needs a matcher
    "SessionStart": False, "UserPromptSubmit": False, "PreToolUse": True, "PostToolUse": True,
    "PostToolUseFailure": True, "PermissionRequest": True, "Notification": False, "SubagentStart": False,
    "Stop": False, "StopFailure": False, "SessionEnd": False,
}


def is_ours(group):
    return any("adapters/claude-code/hook.sh" in (h.get("command") or "") for h in group.get("hooks", []))


def claude_code(remove):
    try:
        with open(CLAUDE_SETTINGS) as f:
            settings = json.load(f)
    except FileNotFoundError:
        settings = {}
    except ValueError as e:
        sys.exit(f"{CLAUDE_SETTINGS} isn't valid JSON ({e}); fix it first")
    if os.path.exists(CLAUDE_SETTINGS):
        backup = f"{CLAUDE_SETTINGS}.bak-visor-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(CLAUDE_SETTINGS, backup)
        print(f"backup: {backup}")
    hooks = settings.setdefault("hooks", {})
    for event, matcher in EVENTS.items():
        groups = [g for g in hooks.get(event, []) if not is_ours(g)]
        if not remove:
            g = {"hooks": [{"type": "command", "command": HOOK, "timeout": 5}]}
            if matcher:
                g = {"matcher": "*", **g}
            groups.append(g)
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    if not hooks:
        settings.pop("hooks")
    os.makedirs(os.path.dirname(CLAUDE_SETTINGS), exist_ok=True)
    with open(CLAUDE_SETTINGS, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(("removed the Visor hooks from " if remove else "added the Visor hooks to ") + CLAUDE_SETTINGS)
    if not remove and not shutil.which("jq"):
        print("note: the hook needs jq, which isn't installed")


def codex():
    script = os.path.join(ROOT, "adapters", "codex", "notify.py")
    print("Add this line near the top of ~/.codex/config.toml (before any [section]):\n")
    print(f'notify = ["python3", "{script}"]')


def config():
    if os.path.exists(CONFIG_FILE):
        print(f"{CONFIG_FILE} already exists")
        return
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    shutil.copy(os.path.join(ROOT, "config.example.json"), CONFIG_FILE)
    print(f"wrote {CONFIG_FILE}; edit it, then `visor restart`")


def main():
    a = sys.argv[1:]
    what = a[0] if a else ""
    if what == "claude-code":
        claude_code("--remove" in a)
    elif what == "codex":
        codex()
    elif what == "config":
        config()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
