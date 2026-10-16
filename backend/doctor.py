#!/usr/bin/env python3
"""`visor doctor`: what's installed, what's configured, what will work."""
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import CONFIG_FILE, load_config, power_supplies  # noqa: E402
import backends  # noqa: E402

if sys.stdout.isatty():
    OK, WARN, BAD = "\033[32m✓\033[0m", "\033[33m!\033[0m", "\033[31m✗\033[0m"
else:
    OK, WARN, BAD = "✓", "!", "✗"


def line(mark, text, hint=""):
    print(f"  {mark} {text}" + (f"\n      {hint}" if hint else ""))


def tool(name, why, needed=False):
    if shutil.which(name):
        line(OK, f"{name}")
    else:
        line(BAD if needed else WARN, f"{name} not found: {why}")


def main():
    cfg = load_config()
    print("Needed")
    tool("qs", "Quickshell runs the robot (package: quickshell)", True)
    tool("python3", "the chat backends", True)
    print("Optional")
    tool("jq", "the Claude Code hook")
    tool("grim", "the screenshot the chat can see")
    tool("curl", "weather")
    tool("udevadm", "battery/charger and USB reactions")
    tool("brightnessctl", "brightness reactions (scripts/sysevent.sh)")

    print("Desktop")
    hypr = bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"))
    wl = bool(os.environ.get("WAYLAND_DISPLAY"))
    line(OK if wl else BAD, "Wayland session" if wl else "not a Wayland session: Quickshell needs one")
    line(OK if hypr else WARN, "Hyprland" if hypr else
         "not Hyprland: click-outside-to-close, fullscreen hiding via workspaces, workspace previews "
         "and computer use are off; everything else works")
    bat, ac = power_supplies()
    line(OK if bat else WARN, f"battery {bat}" + (f", charger {ac}" if ac else "") if bat else "no battery found (fine on a desktop)")

    print("Config")
    if "_error" in cfg:
        line(BAD, cfg["_error"])
    elif os.path.exists(CONFIG_FILE):
        line(OK, CONFIG_FILE)
    else:
        line(WARN, "no config file, using defaults", "visor setup config")
    try:
        info = backends.load(cfg).info()
        line(OK if info.get("available") else BAD, f"backend {cfg['backend']}: {info.get('name')}"
             + ("" if info.get("available") else " (not ready)"),
             "" if info.get("available") else
             ("install Claude Code, or set backends.claude-code.command" if cfg["backend"] == "claude-code"
              else "set backends.openai.baseUrl and defaultModel (and an API key unless it's local)"))
    except SystemExit as e:
        line(BAD, str(e))

    if cfg["backend"] == "claude-code" or shutil.which("claude"):
        try:
            with open(os.path.expanduser("~/.claude/settings.json")) as f:
                s = json.load(f)
            hooked = "adapters/claude-code/hook.sh" in json.dumps(s.get("hooks", {}))
        except (OSError, ValueError):
            hooked = False
        line(OK if hooked else WARN, "Claude Code hooks installed" if hooked else
             "Claude Code hooks not installed: the face won't follow Claude Code sessions",
             "" if hooked else "visor setup claude-code")

    if cfg["chat"].get("computerUse"):
        print("Computer use")
        line(OK if hypr else BAD, "Hyprland" if hypr else "needs Hyprland")
        tool("wtype", "typing and keys", True)
        ok = os.access("/dev/uinput", os.W_OK)
        line(OK if ok else BAD, "/dev/uinput writable" if ok else "/dev/uinput not writable: no mouse clicks",
             "" if ok else "sudo usermod -aG uinput $USER (or input) and log in again")
    unit = cfg["service"].get("unit")
    if unit:
        print("Service")
        line(OK, f"the robot sleeps while {unit} is stopped")


if __name__ == "__main__":
    main()
