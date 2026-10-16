#!/usr/bin/env python3
"""The robot's helper: settings, and the chat popup's link to the AI.

  chat.py info                     JSON: merged settings, backend info, theme, environment
  chat.py sessions                 JSON list of recent chats
  chat.py bridge <session|new> <cwd> <model> <fork 0|1> [mode]
                                   run a chat (protocol in docs/PROTOCOL.md)
  chat.py summary <transcript> [backend]
                                   JSON {title, last} for balloon messages
  chat.py terminal <session> <cwd> JSON argv to continue a chat in a terminal ([] = can't)

The backend is `backend` in ~/.config/visor/config.json (see backends/).
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import CONFIG_FILE, load_config, load_theme, power_supplies  # noqa: E402
import backends  # noqa: E402


def desktop_animations():
    """The desktop's own "enable animations" switch (GNOME/GTK setting), True if unknown."""
    try:
        r = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "enable-animations"],
                           capture_output=True, text=True, timeout=2)
        return r.stdout.strip() != "false"
    except (OSError, subprocess.TimeoutExpired):
        return True


def info(cfg):
    try:
        be = backends.load(cfg).info()
    except Exception as e:   # a broken backend shouldn't stop the face
        be = {"id": cfg.get("backend"), "name": "Assistant", "models": [], "features": {},
              "available": False, "error": str(e)}
    bat, ac = power_supplies()
    p = cfg["power"]
    return {
        "config": cfg,
        "configFile": CONFIG_FILE,
        "backend": be,
        "theme": load_theme(cfg.get("theme"), cfg.get("themeOverrides")),
        "reducedMotion": bool(cfg.get("reducedMotion")) or not desktop_animations(),
        "power": {"battery": bat if p.get("battery") in ("", "auto", None) else p["battery"],
                  "ac": ac if p.get("ac") in ("", "auto", None) else p["ac"]},
        "env": {
            "hyprland": bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")),
            "hyprlandLua": os.path.exists(os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                                                       "hypr", "hyprland.lua")),
        },
    }


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else ""
    cfg = load_config()
    if cmd == "info":
        print(json.dumps(info(cfg)))
    elif cmd == "sessions":
        print(json.dumps(backends.load(cfg).sessions()))
    elif cmd == "bridge" and len(a) >= 5:
        backends.load(cfg).bridge(a[1], a[2], a[3], a[4], a[5] if len(a) > 5 else "")
    elif cmd == "summary" and len(a) >= 2:
        s = backends.load(cfg, a[2] if len(a) > 2 and a[2] else None).summary(a[1])
        last = re.sub(r"[*_`#>]+", "", s.get("last") or "").strip().replace("\n", " ")
        print(json.dumps({"title": (s.get("title") or "")[:60], "last": last[:140]}))
    elif cmd == "terminal" and len(a) >= 3:
        print(json.dumps(backends.load(cfg).terminal_command(a[1], a[2])))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
