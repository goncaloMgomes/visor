#!/usr/bin/env python3
"""Mouse position for the robot on Hyprland with a classic (hyprlang) config:
asks Hyprland's socket for `cursorpos` 10 times a second and writes
"x y 0" to $XDG_RUNTIME_DIR/visor/pointer when it changes. (Clicks can't be
seen this way; the Lua snippet, visor.lua, reports those too.)
shell.qml starts this by itself on Hyprland when there is no hyprland.lua.
"""
import os
import socket
import sys
import time

sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
run = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
if not sig:
    sys.exit("not running under Hyprland")
sock_path = os.path.join(run, "hypr", sig, ".socket.sock")
out = os.path.join(run, "visor", "pointer")
os.makedirs(os.path.dirname(out), exist_ok=True)

last = ""
while True:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            s.connect(sock_path)
            s.sendall(b"cursorpos")
            x, y = s.recv(64).decode().split(",")
        line = f"{int(float(x))} {int(float(y))} 0"
        if line != last:
            with open(out, "w") as f:
                f.write(line + "\n")
            last = line
    except (OSError, ValueError):
        time.sleep(2)
    time.sleep(0.1)
