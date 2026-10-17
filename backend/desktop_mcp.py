#!/usr/bin/env python3
"""Computer use for the robot's chats: a tiny MCP server (stdio, no
dependencies) that lets Claude see and drive this Hyprland desktop.

  screenshot    the screen (or the focused window) as an image
  click / move / drag / scroll   the mouse
  type / key    the keyboard (wtype: any text, any layout)
  windows / focus / launch       Hyprland windows

Coordinates are those of the screenshot image (1280 px wide), the server
scales them to the screen. The mouse buttons and the wheel come from a
virtual uinput device (the user needs write access to /dev/uinput, e.g. the
`uinput` group); the pointer is placed with Hyprland's cursor dispatcher.
Needs Hyprland, grim and wtype. The chat backends start it when
chat.computerUse is on in ~/.config/visor/config.json.
"""
import base64
import fcntl
import json
import os
import struct
import subprocess
import sys
import tempfile
import time

SHOT_W = 1280                    # screenshots are scaled to this width
# Hyprland configured in Lua takes Lua dispatchers; hyprlang configs take the classic ones
LUA = os.path.exists(os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                                  "hypr", "hyprland.lua"))

# --- the screen ----------------------------------------------------------------

def mark_control():
    """Say that the screen is being driven: the robot shows its screen icon and the
    Waybar module lights up (both read $XDG_RUNTIME_DIR/visor, see the sys file)."""
    d = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "visor")
    path = os.path.join(d, "control")
    try:
        os.makedirs(d, exist_ok=True)
        was = os.path.getmtime(path) if os.path.exists(path) else 0
        with open(path, "w") as f:
            f.write(str(time.time()))
        if time.time() - was > 3:   # once per burst, not on every call
            with open(os.path.join(d, "sys"), "a") as f:
                f.write("screen on\n")
    except OSError:
        pass   # decoration only, never a reason to fail a tool call


def hyprctl_json(*args):
    out = subprocess.run(["hyprctl", *args, "-j"], capture_output=True, text=True, timeout=5).stdout
    return json.loads(out or "null")


def monitor():
    """The focused monitor: its logical size and position."""
    mons = hyprctl_json("monitors") or []
    m = next((m for m in mons if m.get("focused")), mons[0] if mons else None)
    if not m:
        return {"x": 0, "y": 0, "w": 1920, "h": 1200}
    sc = m.get("scale", 1) or 1
    w, h = m["width"] / sc, m["height"] / sc
    if m.get("transform", 0) % 2:
        w, h = h, w
    return {"x": m["x"], "y": m["y"], "w": round(w), "h": round(h)}


def factor():
    """screenshot px -> logical screen px"""
    return monitor()["w"] / SHOT_W


def to_screen(x, y):
    m = monitor()
    f = m["w"] / SHOT_W
    return m["x"] + x * f, m["y"] + y * f


def dispatch(*args):
    r = subprocess.run(["hyprctl", "dispatch", *args], capture_output=True, text=True, timeout=5)
    out = (r.stdout + r.stderr).strip()
    return "" if out == "ok" else out


def move_to(x, y):
    sx, sy = to_screen(x, y)
    if LUA:
        dispatch("hl.dsp.cursor.move({ x = %d, y = %d })" % (round(sx), round(sy)))
    else:
        dispatch("movecursor", str(round(sx)), str(round(sy)))
    time.sleep(0.03)


def settle():
    """after a jump, give the app under the pointer a moment to see it arrive
    (a press right after the cursor teleports can be missed)"""
    time.sleep(0.12)


# --- the virtual mouse (uinput) --------------------------------------------------

EV_SYN, EV_KEY, EV_REL = 0, 1, 2
REL_X, REL_Y, REL_HWHEEL, REL_WHEEL = 0, 1, 6, 8
BUTTONS = {"left": 0x110, "right": 0x111, "middle": 0x112}
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
UI_DEV_CREATE = 0x5501


class Mouse:
    def __init__(self):
        self.fd = None

    def open(self):
        if self.fd is not None:
            return
        fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
        for b in BUTTONS.values():
            fcntl.ioctl(fd, UI_SET_KEYBIT, b)
        for r in (REL_X, REL_Y, REL_WHEEL, REL_HWHEEL):
            fcntl.ioctl(fd, UI_SET_RELBIT, r)
        # struct uinput_user_dev: name[80], input_id (4 x u16), ff_effects_max, 4 x 64 ints
        dev = struct.pack("80sHHHHi", b"visor-mouse", 0x06, 0x1, 0x1, 1, 0) + b"\0" * (4 * 64 * 4)
        os.write(fd, dev)
        fcntl.ioctl(fd, UI_DEV_CREATE)
        self.fd = fd
        time.sleep(0.4)   # let libinput/Hyprland pick the new device up

    def emit(self, etype, code, value):
        now = time.time()
        os.write(self.fd, struct.pack("llHHi", int(now), int((now % 1) * 1e6), etype, code, value))

    def sync(self):
        self.emit(EV_SYN, 0, 0)

    def button(self, name, down):
        self.open()
        self.emit(EV_KEY, BUTTONS[name], 1 if down else 0)
        self.sync()

    def click(self, name="left", count=1):
        for i in range(count):
            self.button(name, True)
            time.sleep(0.02)
            self.button(name, False)
            time.sleep(0.07)

    def wheel(self, dy, dx=0):
        self.open()
        for _ in range(abs(int(dy))):
            self.emit(EV_REL, REL_WHEEL, -1 if dy > 0 else 1)   # dy > 0 scrolls down
            self.sync()
            time.sleep(0.02)
        for _ in range(abs(int(dx))):
            self.emit(EV_REL, REL_HWHEEL, 1 if dx > 0 else -1)
            self.sync()
            time.sleep(0.02)


MOUSE = Mouse()

# --- tools -------------------------------------------------------------------------

SCREEN_OFF = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "visor", "screen-off")


def t_screenshot(a):
    if os.path.exists(SCREEN_OFF):   # the popup's Screen switch
        return "The user turned screen sharing off in the chat popup, so you can't see the screen. Ask them to describe it."
    m = monitor()
    geo = None
    if a.get("window") == "focused":
        w = hyprctl_json("activewindow") or {}
        if w.get("at"):
            geo = "%d,%d %dx%d" % (w["at"][0], w["at"][1], w["size"][0], w["size"][1])
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
        path = f.name
    try:
        if geo:
            cmd = ["grim", "-t", "jpeg", "-q", "80", "-g", geo, path]
        else:
            cmd = ["grim", "-t", "jpeg", "-q", "80", "-s", "%.4f" % (SHOT_W / m["w"]), "-o", focused_output(), path]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip() or "grim failed")
        data = base64.b64encode(open(path, "rb").read()).decode()
    finally:
        os.unlink(path)
    cur = cursor_shot()
    note = ("Screenshot of the focused window (its own pixels; use a full screenshot for click coordinates)."
            if geo else
            "Screen %dx%d px (screenshot coordinates). Cursor at (%d, %d)." % (SHOT_W, round(m["h"] * SHOT_W / m["w"]), *cur))
    return [{"type": "image", "data": data, "mimeType": "image/jpeg"}, {"type": "text", "text": note}]


def focused_output():
    mons = hyprctl_json("monitors") or []
    m = next((m for m in mons if m.get("focused")), mons[0] if mons else {})
    return m.get("name", "")


def cursor_shot():
    out = subprocess.run(["hyprctl", "cursorpos"], capture_output=True, text=True).stdout
    try:
        x, y = (float(v) for v in out.split(","))
    except ValueError:
        return (0, 0)
    m = monitor()
    f = m["w"] / SHOT_W
    return (round((x - m["x"]) / f), round((y - m["y"]) / f))


def t_click(a):
    if "x" in a and "y" in a:
        move_to(a["x"], a["y"])
        settle()
    MOUSE.click(a.get("button", "left"), 2 if a.get("double") else 1)
    return "clicked %s at %s" % (a.get("button", "left"), cursor_shot())


def t_move(a):
    move_to(a["x"], a["y"])
    return "cursor at %s" % (cursor_shot(),)


def t_drag(a):
    move_to(a["x1"], a["y1"])
    settle()
    MOUSE.button("left", True)
    time.sleep(0.05)
    steps = 12
    for i in range(1, steps + 1):
        move_to(a["x1"] + (a["x2"] - a["x1"]) * i / steps, a["y1"] + (a["y2"] - a["y1"]) * i / steps)
    time.sleep(0.05)
    MOUSE.button("left", False)
    return "dragged to %s" % (cursor_shot(),)


def t_scroll(a):
    if "x" in a and "y" in a:
        move_to(a["x"], a["y"])
    MOUSE.wheel(a.get("dy", 0), a.get("dx", 0))
    return "scrolled"


def t_type(a):
    r = subprocess.run(["wtype", "-d", "4", "--", a["text"]], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "wtype failed")
    return "typed %d characters" % len(a["text"])


MODS = {"ctrl": "ctrl", "control": "ctrl", "shift": "shift", "alt": "alt", "super": "logo",
        "meta": "logo", "win": "logo", "logo": "logo", "altgr": "altgr"}
KEYS = {"enter": "Return", "return": "Return", "esc": "Escape", "escape": "Escape", "tab": "Tab",
        "space": "space", "backspace": "BackSpace", "delete": "Delete", "del": "Delete",
        "up": "Up", "down": "Down", "left": "Left", "right": "Right", "home": "Home", "end": "End",
        "pageup": "Prior", "pagedown": "Next", "insert": "Insert"}


def t_key(a):
    """key: "ctrl+shift+t", "enter", "alt+F4", or several separated by spaces"""
    for combo in a["keys"].split():
        parts = combo.split("+")
        mods = [MODS[p.lower()] for p in parts[:-1] if p.lower() in MODS]
        key = parts[-1]
        key = KEYS.get(key.lower(), key)
        cmd = ["wtype"]
        for m in mods:
            cmd += ["-M", m]
        cmd += ["-k", key]
        for m in reversed(mods):
            cmd += ["-m", m]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip() or "wtype failed")
        time.sleep(0.05)
    return "pressed " + a["keys"]


def t_windows(a):
    f = factor()
    m = monitor()
    out = []
    for c in hyprctl_json("clients") or []:
        if not c.get("mapped", True) or c.get("hidden"):
            continue
        x, y = (c["at"][0] - m["x"]) / f, (c["at"][1] - m["y"]) / f
        out.append("%s  class=%s  title=%r  workspace=%s  at=(%d,%d) size=%dx%d%s" % (
            c["address"], c["class"], c["title"], c["workspace"]["name"], x, y,
            c["size"][0] / f, c["size"][1] / f, "  [focused]" if c.get("focusHistoryID") == 0 else ""))
    return "\n".join(out) or "no windows"


def t_focus(a):
    w = a["window"]
    sel = w if w.startswith("address:") else ("address:" + w if w.startswith("0x") else "class:" + w)
    if LUA:
        return dispatch('hl.dsp.focus({ window = "%s" })' % sel.replace('"', "")) or "focused " + w
    return dispatch("focuswindow", sel) or "focused " + w


def t_launch(a):
    # through Hyprland, so the app belongs to the desktop session, not to the AI
    if not LUA:
        return dispatch("exec", a["command"]) or "launched"
    cmd = a["command"].replace("\\", "\\\\").replace('"', '\\"')
    return dispatch('hl.dsp.exec_cmd("%s")' % cmd) or "launched"


XY = {"x": {"type": "number", "description": "x in screenshot pixels"},
      "y": {"type": "number", "description": "y in screenshot pixels"}}
TOOLS = {
    "screenshot": (t_screenshot, "Take a screenshot of the user's desktop (1280 px wide). Coordinates for the "
                   "mouse tools are in this image's pixels. Take a fresh one after acting to check the result.",
                   {"window": {"type": "string", "enum": ["screen", "focused"],
                               "description": "'focused' for just the focused window (default: whole screen)"}}, []),
    "click": (t_click, "Click at (x, y) (screenshot pixels), or where the cursor is if omitted.",
              {**XY, "button": {"type": "string", "enum": ["left", "right", "middle"]},
               "double": {"type": "boolean"}}, []),
    "move": (t_move, "Move the mouse pointer to (x, y) (screenshot pixels), e.g. to hover.", XY, ["x", "y"]),
    "drag": (t_drag, "Drag with the left button from (x1, y1) to (x2, y2) (screenshot pixels).",
             {"x1": {"type": "number"}, "y1": {"type": "number"}, "x2": {"type": "number"}, "y2": {"type": "number"}},
             ["x1", "y1", "x2", "y2"]),
    "scroll": (t_scroll, "Scroll the mouse wheel at (x, y): dy > 0 scrolls down, dx > 0 right (in notches).",
               {**XY, "dy": {"type": "integer"}, "dx": {"type": "integer"}}, []),
    "type": (t_type, "Type text into the focused window (any characters).",
             {"text": {"type": "string"}}, ["text"]),
    "key": (t_key, "Press keys / shortcuts in the focused window, e.g. 'enter', 'ctrl+l', 'ctrl+shift+t', "
                   "'alt+Tab'. Several separated by spaces are pressed in order.",
            {"keys": {"type": "string"}}, ["keys"]),
    "windows": (t_windows, "List open windows (address, class, title, workspace, position/size in screenshot pixels).",
                {}, []),
    "focus": (t_focus, "Focus a window by address (0x...) or class.", {"window": {"type": "string"}}, ["window"]),
    "launch": (t_launch, "Start an application (shell command, e.g. 'firefox https://x.com' or 'nautilus').",
               {"command": {"type": "string"}}, ["command"]),
}

# --- MCP over stdio -------------------------------------------------------------------

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def handle(req):
    method, rid = req.get("method"), req.get("id")
    if rid is None:
        return   # notification
    if method == "initialize":
        ver = (req.get("params") or {}).get("protocolVersion", "2025-06-18")
        return send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": ver, "capabilities": {"tools": {}},
            "serverInfo": {"name": "desktop", "version": "1.0"},
            "instructions": "Computer use for the user's Hyprland desktop: screenshot, then click/type/key."}})
    if method == "ping":
        return send({"jsonrpc": "2.0", "id": rid, "result": {}})
    if method == "tools/list":
        tools = [{"name": n, "description": d, "inputSchema": {"type": "object", "properties": p, "required": r}}
                 for n, (_, d, p, r) in TOOLS.items()]
        return send({"jsonrpc": "2.0", "id": rid, "result": {"tools": tools}})
    if method == "tools/call":
        p = req.get("params") or {}
        fn = TOOLS.get(p.get("name"), (None,))[0]
        if not fn:
            return send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "unknown tool"}})
        try:
            mark_control()
            out = fn(p.get("arguments") or {})
            content = out if isinstance(out, list) else [{"type": "text", "text": str(out)}]
            return send({"jsonrpc": "2.0", "id": rid, "result": {"content": content}})
        except Exception as e:
            return send({"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": "error: %s" % e}], "isError": True}})
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(req)


if __name__ == "__main__":
    main()
