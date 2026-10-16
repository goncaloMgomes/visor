#!/usr/bin/env python3
"""Fresh lines for the robot's speech balloon, written by the configured AI.

One call to the backend (`claude -p` with a small model for Claude Code, one
chat completion for OpenAI-compatible APIs) every few hours writes a small
pool of lines per kind of event, knowing the time of day and the weather.
shell.qml picks from ~/.local/state/visor/remarks.json instantly and falls
back to its hand-written lines when the pool is missing or stale.

  remarks.py [--weather "rainy 14 Lisbon"]
"""
import argparse
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import STATE_DIR, load_config, write_json  # noqa: E402
import backends  # noqa: E402
from backends.base import json_from_text  # noqa: E402

OUT = os.path.join(STATE_DIR, "remarks.json")
PER_KIND = 4

# kind -> (when it's said, placeholders it may use)
KINDS = {
    "plugged":   ("the charger was just plugged in", ["{n}"]),
    "unplugged": ("the charger was just unplugged, running on battery", ["{n}"]),
    "battery":   ("the battery is getting low ({n} is the percentage, 20 or less)", ["{n}"]),
    "late":      ("it just turned 23:00, gently suggest bed", []),
    "pet":       ("the user is hovering the mouse over the robot, petting it", []),
    "purr":      ("the user keeps petting the robot, it loves it", []),
    "music":     ("the user just started playing music: {title} by {artist}", ["{title}", "{artist}"]),
    "wifiOn":    ("Wi-Fi was switched on", []),
    "wifiOff":   ("Wi-Fi was switched off", []),
    "btOn":      ("Bluetooth was switched on", []),
    "btOff":     ("Bluetooth was switched off", []),
    "btDevice":  ("a Bluetooth device named {name} just connected", ["{name}"]),
    "usb":       ("a USB device named {name} was just plugged in", ["{name}"]),
    "coffeeOn":  ("the user turned on keep-awake (the computer won't sleep)", []),
    "coffeeOff": ("keep-awake was turned off, sleeping is allowed again", []),
    "weather":   ("the greeting's weather sentence: right now it's {t}°C in {c}, WEATHER", ["{t}", "{c}"]),
}

SYSTEM = (
    "You write lines for a tiny, cute robot that lives in the top-right corner of the "
    "user's screen and comments on what "
    "happens on the computer in a cartoon speech balloon. Its personality: cheerful, "
    "a bit cheeky, curious, warm, never mean or sarcastic. Lines are in English, at "
    "most 80 characters, at most one emoji, no quotes around them, no hashtags. Vary "
    "the wording a lot; don't start every line the same way. Placeholders in curly "
    "braces are filled in later: use them exactly as written and only the ones listed "
    "for that kind."
)


def build_prompt(args):
    now = datetime.datetime.now()
    part = ("early morning" if now.hour < 9 else "morning" if now.hour < 12 else
            "afternoon" if now.hour < 18 else "evening" if now.hour < 22 else "late night")
    weather = args.weather or "unknown"
    lines = [f"It is {now:%A} {part} ({now:%H:%M}). Weather: {weather}.", "",
             f"Write {PER_KIND} different lines for each kind below:"]
    for k, (when, ph) in KINDS.items():
        when = when.replace("WEATHER", weather)
        lines.append(f"- {k}: {when}" + (f" (placeholders: {', '.join(ph)})" if ph else " (no placeholders)"))
    lines += ["", "Reply with only a JSON object: each kind above as a key, its value a list of strings."]
    return "\n".join(lines)


def schema():
    item = {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": PER_KIND + 2}
    return {"type": "object", "properties": {k: item for k in KINDS}, "required": list(KINDS),
            "additionalProperties": False}


def clean(kind, lines):
    """keep lines that are short and only use their kind's placeholders"""
    allowed = set(KINDS[kind][1])
    out = []
    if isinstance(lines, str):
        lines = [lines]
    for line in lines:
        line = line.strip().strip('"“”')
        used = set(re.findall(r"\{[a-z]+\}", line))
        if not line or len(line) > 110 or not used <= allowed:
            continue
        out.append(line)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weather", default="")
    args = ap.parse_args()

    cfg = load_config()
    try:
        reply = backends.load(cfg).complete(SYSTEM, build_prompt(args), schema())
    except Exception as e:
        sys.exit(f"remarks: {e}")
    data = json_from_text(reply)
    if not isinstance(data, dict):
        sys.exit("remarks: no lines in the reply: " + str(reply)[:300])

    pool = {k: clean(k, data.get(k) or []) for k in KINDS}
    pool = {k: v for k, v in pool.items() if v}
    write_json(OUT, {"t": int(datetime.datetime.now().timestamp()), "weather": args.weather, "lines": pool})
    print(json.dumps({"ok": True, "kinds": len(pool)}))


if __name__ == "__main__":
    main()
