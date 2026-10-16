#!/usr/bin/env python3
"""OpenAI Codex CLI -> Visor (status adapter).

Codex runs its `notify` program with one JSON argument when a turn finishes.
Add to ~/.codex/config.toml (or run `visor setup codex` to print the line):

    notify = ["python3", "/path/to/visor/adapters/codex/notify.py"]

Codex only reports finished turns, so the face shows "done" plus a balloon
with the reply; it can't show thinking/working the way Claude Code's hooks do.
"""
import json
import os
import subprocess
import sys

VISOR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "bin", "visor")


def main():
    try:
        n = json.loads(sys.argv[-1])
    except (ValueError, IndexError):
        return
    if n.get("type") != "agent-turn-complete":
        return
    asked = n.get("input-messages") or n.get("input_messages") or []
    title = (asked[0] if asked else "Codex").strip().splitlines()[0][:60] if asked else "Codex"
    last = n.get("last-assistant-message") or n.get("last_assistant_message") or ""
    subprocess.run([VISOR, "signal", "--event", "stop", "--source", "codex",
                    "--sid", str(n.get("turn-id") or ""), "--title", title, "--text", last], check=False)


if __name__ == "__main__":
    main()
