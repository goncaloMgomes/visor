#!/usr/bin/env python3
"""Make room for the robot at the right end of Waybar.

  waybar.py status            what's running, the bar's margin and geometry (JSON)
  waybar.py make-room         set the bar's right margin, restart Waybar, wait for it
  waybar.py remove            undo make-room (and don't do it again on start)

The edit is a `"margin-right"` on every top bar, tagged `/* visor: was … */` so
`remove` can put the old value back; the first edit also leaves a
`<config>.visor-backup`. Waybar's config is JSONC, so it's edited as text and
the comments and formatting stay as they were.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import STATE_DIR, load_config, write_json  # noqa: E402

ROBOT_W = 64            # the robot's window (62 px) and a 2 px gap
MARK = re.compile(r'\s*/\* visor: was (.*?) \*/')
STATE = os.path.join(STATE_DIR, "waybar.json")


# --- Waybar processes -----------------------------------------------------------
def processes():
    out = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/comm") as f:
                if f.read().strip() != "waybar":
                    continue
            with open(f"/proc/{pid}/environ", "rb") as f:   # this session's bars only
                env = dict(e.split(b"=", 1) for e in f.read().split(b"\0") if b"=" in e)
            if env.get(b"WAYLAND_DISPLAY", b"").decode() != os.environ.get("WAYLAND_DISPLAY", ""):
                continue
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = [a.decode() for a in f.read().split(b"\0") if a]
            out.append({"pid": int(pid), "argv": argv, "cwd": os.readlink(f"/proc/{pid}/cwd")})
        except OSError:
            pass
    return out


def unit_active():
    try:
        return subprocess.run(["systemctl", "--user", "is-active", "--quiet", "waybar.service"],
                              timeout=3).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def config_path(procs):
    for p in procs:
        a = p["argv"]
        for i, arg in enumerate(a):
            if arg in ("-c", "--config") and i + 1 < len(a):
                return os.path.join(p["cwd"], os.path.expanduser(a[i + 1]))
            if arg.startswith("--config="):
                return os.path.join(p["cwd"], os.path.expanduser(arg.split("=", 1)[1]))
    home = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    dirs = [os.path.join(home, "waybar")] + [os.path.join(d, "waybar") for d in
            (os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(":")]
    for d in dirs:
        for name in ("config.jsonc", "config"):
            if os.path.isfile(os.path.join(d, name)):
                return os.path.join(d, name)
    return ""


# --- a small JSONC reader that remembers where things are ---------------------
class Jsonc:
    """Parses JSONC (comments, trailing commas) and records, for every object,
    where its `{` is and the text span of each member's value."""

    def __init__(self, text):
        self.s, self.i = text, 0

    def ws(self):
        s = self.s
        while self.i < len(s):
            if s[self.i] in " \t\r\n":
                self.i += 1
            elif s.startswith("//", self.i):
                j = s.find("\n", self.i)
                self.i = len(s) if j < 0 else j
            elif s.startswith("/*", self.i):
                j = s.find("*/", self.i + 2)
                self.i = len(s) if j < 0 else j + 2
            else:
                break

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == "{":
            return self.obj()
        if c == "[":
            return self.arr()
        if c == '"':
            return self.string()
        m = re.compile(r'-?\d+(\.\d+)?([eE][-+]?\d+)?|true|false|null').match(self.s, self.i)
        if not m:
            raise ValueError(f"unexpected {c!r} at {self.i}")
        self.i = m.end()
        return json.loads(m.group())

    def string(self):
        m = re.compile(r'"(?:[^"\\]|\\.)*"').match(self.s, self.i)
        self.i = m.end()
        return json.loads(m.group())

    def obj(self):
        o = {"open": self.i, "members": {}}
        self.i += 1
        while True:
            self.ws()
            if self.s[self.i] == "}":
                self.i += 1
                return o
            key = self.string()
            self.ws()
            self.i += 1  # :
            self.ws()
            start = self.i
            v = self.value()
            o["members"][key] = (v, start, self.i)
            self.ws()
            if self.s[self.i] == ",":
                self.i += 1

    def arr(self):
        a = []
        self.i += 1
        while True:
            self.ws()
            if self.s[self.i] == "]":
                self.i += 1
                return a
            a.append(self.value())
            self.ws()
            if self.s[self.i] == ",":
                self.i += 1


def plain(v):
    return {k: plain(m[0]) for k, m in v["members"].items()} if isinstance(v, dict) and "members" in v else \
           [plain(x) for x in v] if isinstance(v, list) else v


def top_bars(text):
    root = Jsonc(text).value()
    bars = root if isinstance(root, list) else [root]
    return [b for b in bars if isinstance(b, dict) and plain(b).get("position", "top") == "top"]


def css_box(v):
    """Waybar's "margin": "t r b l" (CSS shorthand) or a number -> [t, r, b, l]."""
    if isinstance(v, (int, float)):
        return [int(v)] * 4
    p = [int(x) for x in str(v).split()] if str(v).strip() else [0]
    return {1: p * 4, 2: p * 2, 3: p + [p[1]]}.get(len(p), p[:4])


def right_margin(bar):
    m = plain(bar)
    if any(k in m for k in ("margin-top", "margin-right", "margin-bottom", "margin-left")):
        return int(m.get("margin-right", 0)), m
    if "margin" in m:
        return css_box(m["margin"])[1], m
    return 0, m


def need(cfg):
    return ROBOT_W + int(cfg.get("position", {}).get("marginRight", 0))


# --- where the bar is on screen (for the animation) -------------------------
def geometry():
    """Waybar's layer surfaces on Hyprland: [{monitor, x, y, w, h, gx, gy}]."""
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return []
    try:
        layers = json.loads(subprocess.run(["hyprctl", "layers", "-j"], capture_output=True, text=True, timeout=3).stdout)
        mons = {m["name"]: m for m in json.loads(subprocess.run(["hyprctl", "monitors", "-j"],
                                                                 capture_output=True, text=True, timeout=3).stdout)}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return []
    out = []
    for name, v in layers.items():
        m = mons.get(name, {"x": 0, "y": 0})
        for level in v.get("levels", {}).values():
            for l in level:
                if l.get("namespace") == "waybar":
                    out.append({"monitor": name, "pid": l.get("pid"), "gx": l["x"], "gy": l["y"],
                                "x": l["x"] - m["x"], "y": l["y"] - m["y"], "w": l["w"], "h": l["h"]})
    return out


def status():
    cfg = load_config()
    procs = processes()
    path = config_path(procs)
    st = {"running": bool(procs), "config": path, "need": need(cfg), "right": None,
          "needsRoom": False, "bars": [], "done": False, "error": ""}
    try:
        with open(STATE) as f:
            st["done"] = bool(json.load(f).get("done"))
    except (OSError, ValueError):
        pass
    if not path:
        return st
    try:
        with open(path) as f:
            bars = top_bars(f.read())
    except (OSError, ValueError, IndexError, AttributeError) as e:
        st["error"] = f"can't read {path}: {e}"
        return st
    if bars:
        rights = [right_margin(b) for b in bars]
        st["right"] = min(r for r, _ in rights)
        st["needsRoom"] = st["right"] < st["need"]
        # without Hyprland the bar's place comes from its config (if it has a height)
        b = rights[0][1]
        box = css_box(b["margin"]) if "margin" in b and "margin-top" not in b and "margin-left" not in b else \
              [b.get("margin-top", 0), st["right"], 0, b.get("margin-left", 0)]
        st["fromConfig"] = {"top": box[0], "left": box[3], "right": st["right"], "height": b.get("height", 0)}
    st["bars"] = geometry() if procs else []
    return st


# --- editing ---------------------------------------------------------------------
def edit(text, px):
    """Set every top bar's right margin to px; returns the new text."""
    edits = []   # (start, end, replacement), applied back to front
    for bar in top_bars(text):
        mem = bar["members"]
        individual = any(k in mem for k in ("margin-top", "margin-right", "margin-bottom", "margin-left"))
        if "margin-right" in mem:
            v, a, b = mem["margin-right"]
            if MARK.match(text, b) or v >= px:
                continue
            edits.append((a, b, f"{px} /* visor: was {text[a:b]} */"))
        elif "margin" in mem and not individual:
            v, a, b = mem["margin"]
            box = css_box(v)
            if box[1] >= px:
                continue
            box[1] = px
            edits.append((a, b, '"' + " ".join(map(str, box)) + f'" /* visor: was {text[a:b]} */'))
        else:
            o = bar["open"] + 1
            nl = text.find("\n", o)
            indent = re.match(r"[ \t]*", text[nl + 1:]).group() if nl >= 0 else ""
            edits.append((o, o, f'\n{indent}"margin-right": {px} /* visor: was none */,'))
    for a, b, rep in sorted(edits, reverse=True):
        text = text[:a] + rep + text[b:]
    return text


def unedit(text):
    # inserted keys go away whole; replaced values get their old text back
    text = re.sub(r'\n[ \t]*"margin-right": \d+ /\* visor: was none \*/,', "", text)
    return re.sub(r'(?:\d+|"[^"\n]*") /\* visor: was (.*?) \*/', lambda m: m.group(1), text)


def restart(old):
    """Restart Waybar the way it was started; wait until the new bar is up."""
    if unit_active():
        subprocess.run(["systemctl", "--user", "restart", "waybar.service"], timeout=10)
    else:
        for p in old:
            try:
                os.kill(p["pid"], signal.SIGTERM)
            except OSError:
                pass
        t = time.time()
        while time.time() - t < 3 and any(os.path.exists(f"/proc/{p['pid']}") for p in old):
            time.sleep(0.05)
        for p in old:
            subprocess.Popen(p["argv"], cwd=p["cwd"], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pids = {p["pid"] for p in old}
    t = time.time()
    while time.time() - t < 8:
        time.sleep(0.1)
        if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
            if any(b["pid"] not in pids for b in geometry()):
                time.sleep(0.35)   # its first frame
                return True
        elif time.time() - t > 1.2 and processes():
            return True
    return False


def make_room():
    st = status()
    if not st["running"] or not st["config"]:
        return {"ok": False, "error": "Waybar isn't running"}
    path = st["config"]
    if not st["needsRoom"]:
        write_json(STATE, {"done": True, "config": path})
        return {"ok": True, "changed": False}
    if not os.access(path, os.W_OK):
        # e.g. the system-wide /etc/xdg/waybar config: leave it to the user
        return {"ok": False, "error": f"{path} isn't writable; add \"margin-right\": {st['need']} to your bar"}
    with open(path) as f:
        text = f.read()
    new = edit(text, st["need"])
    if not os.path.exists(path + ".visor-backup"):
        shutil.copy(path, path + ".visor-backup")
    with open(path, "w") as f:
        f.write(new)
    ok = restart(processes())
    write_json(STATE, {"done": True, "config": path})
    return {"ok": ok, "changed": True, "error": "" if ok else "Waybar didn't come back"}


def remove():
    procs = processes()
    path = config_path(procs)
    changed = False
    if path and os.path.isfile(path):
        with open(path) as f:
            text = f.read()
        new = unedit(text)
        if new != text:
            with open(path, "w") as f:
                f.write(new)
            changed = True
            if procs:
                restart(procs)
    write_json(STATE, {"done": True, "declined": True})
    return {"ok": True, "changed": changed, "config": path}


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    fn = {"status": status, "make-room": make_room, "remove": remove}.get(cmd)
    if not fn:
        sys.exit(__doc__)
    print(json.dumps(fn()))
