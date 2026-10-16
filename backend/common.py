"""Paths and settings shared by the robot's helpers.

Settings come from ~/.config/visor/config.json, merged over DEFAULTS below
(the only place defaults live: the QML side asks `chat.py info` for the merged
result instead of keeping its own copy).
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
STATE_HOME = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
CONFIG_FILE = os.environ.get("VISOR_CONFIG") or os.path.join(CONFIG_HOME, "visor", "config.json")
STATE_DIR = os.path.join(STATE_HOME, "visor")
RUN_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}", "visor")
THEMES_DIR = os.path.join(ROOT, "themes")

DEFAULTS = {
    # your name, for greetings ("" = greet without a name)
    "name": "",
    # which AI the chat popup talks to: "claude-code" or "openai"
    # (any OpenAI-compatible API: OpenAI, OpenRouter, Gemini, Ollama, LM Studio, llama.cpp…)
    "backend": "claude-code",
    # chat popup look: "linear" (default), "claude", or a path to your own theme JSON
    "theme": "linear",
    # turn off animations (also on when the desktop's "enable-animations" setting is off)
    "reducedMotion": False,
    "themeOverrides": {},

    "chat": {
        "model": "",                 # "" = the backend's default
        "cwd": "~",                  # where new chats run (matters for coding agents)
        "permissionMode": "default", # claude-code: default | acceptEdits | auto | plan | bypassPermissions
        "computerUse": False,        # let the AI see and drive the desktop (Hyprland only)
        "shareScreen": True,         # send a screenshot of what you were doing with each message
        "terminal": [],              # e.g. ["kitty", "-e"]; [] = xdg-terminal-exec or $TERMINAL -e
        "resumeMinutes": 30,         # reopening the popup continues the last chat if used this recently
    },

    "position": {
        "marginTop": 0,              # the robot's window, from the top-right corner
        "marginRight": 0,
        "chatTop": 46,               # the chat popup, from the top-right corner
        "chatRight": 8,
    },

    # optional systemd --user unit the robot "is": asleep while it isn't running,
    # a click starts it (e.g. Claude Code Remote Control). "" = always awake.
    "service": {"unit": "", "label": ""},

    "power": {"battery": "auto", "ac": "auto"},   # /sys/class/power_supply names; "auto" detects them

    # the idle face gets sleepier from sleepyFrom, is fully sleepy asleepFrom–asleepUntil,
    # awake again by awakeBy (hours, 0.5 = 00:30); lateHour = the "go to bed" remark
    "night": {"sleepyFrom": 21, "asleepFrom": 0.5, "asleepUntil": 5, "awakeBy": 7, "lateHour": 23},

    "idleSeconds": 240,              # away this long = the sleep face
    "lockers": ["hyprlock", "swaylock", "gtklock", "waylock"],

    "features": {
        "weather": True,             # needs a city (right-click menu)
        "remarks": True,             # balloon lines written by the AI every few hours
        "workspacePreview": False,   # Hyprland + Waybar dots only; see docs/hyprland.md
    },

    # Waybar: makeRoom = the first time, shove the bar over to make room for the
    # robot (sets the bar's margin-right; `visor setup waybar --remove` undoes it).
    # The rest is the bar's layout, for the workspace preview only.
    "waybar": {"makeRoom": True,
               "marginLeft": 10, "marginRight": 64, "top": 6, "height": 34, "dot": 18, "activeDot": 38},

    "backends": {
        "claude-code": {
            "command": "claude",
            "models": [
                {"id": "opus", "name": "Opus", "blurb": "Most capable, for complex work"},
                {"id": "sonnet", "name": "Sonnet", "blurb": "Smart and efficient for everyday tasks"},
                {"id": "haiku", "name": "Haiku", "blurb": "Fastest, for quick answers"},
            ],
            "defaultModel": "sonnet",
            "remarksModel": "haiku",
        },
        "openai": {
            "name": "Assistant",                     # what the popup calls it
            "baseUrl": "https://api.openai.com/v1",
            "apiKey": "",                            # or apiKeyEnv / apiKeyCommand
            "apiKeyEnv": "OPENAI_API_KEY",
            "apiKeyCommand": "",                     # e.g. "pass show openai"
            "models": [],                            # [{"id", "name", "blurb"}]; [] = just defaultModel
            "defaultModel": "",
            "remarksModel": "",                      # "" = defaultModel
            "vision": True,                          # send screenshots as images
            "systemPrompt": "",                      # added to the built-in one
            "headers": {},                           # extra HTTP headers (OpenRouter's HTTP-Referer, …)
        },
    },
}


def merge(base, over):
    if not isinstance(base, dict) or not isinstance(over, dict):
        return over
    out = dict(base)
    for k, v in over.items():
        out[k] = merge(base.get(k), v) if isinstance(base.get(k), dict) else v
    return out


def load_config():
    try:
        with open(CONFIG_FILE) as f:
            user = json.load(f)
    except FileNotFoundError:
        user = {}
    except (OSError, ValueError) as e:
        user = {"_error": f"{CONFIG_FILE}: {e}"}
    cfg = merge(DEFAULTS, user)
    cfg["chat"]["cwd"] = os.path.expanduser(cfg["chat"]["cwd"] or "~")
    return cfg


def load_theme(name, overrides=None):
    theme = {}
    if name in ("", "auto", None):
        name = "linear"
    for n in ("linear", name):   # every theme starts from linear, so a theme may set only a few keys
        path = n if os.sep in str(n) else os.path.join(THEMES_DIR, f"{n}.json")
        try:
            with open(os.path.expanduser(path)) as f:
                theme.update(json.load(f))
        except (OSError, ValueError):
            pass
    theme.update(overrides or {})
    return theme


def power_supplies():
    """(battery, ac) names under /sys/class/power_supply, "" when there is none (desktops)."""
    base = "/sys/class/power_supply"
    bat = ac = ""
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return bat, ac
    for n in names:
        try:
            with open(os.path.join(base, n, "type")) as f:
                kind = f.read().strip()
            scope = ""
            if os.path.exists(os.path.join(base, n, "scope")):
                with open(os.path.join(base, n, "scope")) as f:
                    scope = f.read().strip()
        except OSError:
            continue
        if kind == "Battery" and scope != "Device" and not bat:   # skip mice / headsets
            bat = n
        elif kind == "Mains" and not ac:
            ac = n
    return bat, ac


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def append_event(ev):
    """One line in $XDG_RUNTIME_DIR/visor/events (what the speech balloon announces)."""
    os.makedirs(RUN_DIR, exist_ok=True)
    with open(os.path.join(RUN_DIR, "events"), "a") as f:
        f.write(json.dumps(ev, ensure_ascii=False) + "\n")


def set_mood(mood):
    os.makedirs(RUN_DIR, exist_ok=True)
    with open(os.path.join(RUN_DIR, "state"), "w") as f:
        f.write(mood + "\n")
