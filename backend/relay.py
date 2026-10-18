"""Chats that outlive the popup.

Each chat tab's bridge runs under a small relay process of its own, outside the
robot's process, so reloading or restarting the robot doesn't end a reply that
is being written. The popup talks to it through `chat.py attach`, which
forwards stdin/stdout to the relay's socket (starting the relay first if it
isn't running). On connect the relay replays the chat so far, so a tab that
comes back after a reload shows everything, including a reply still arriving.

  chat.py attach <key> <bridge args…>   the popup's end (key = the tab)
  chat.py relay <key> <bridge args…>    the relay itself (started by attach)

A relay ends when the popup sends {"op": "quit"} (tab closed or reused), when
its bridge exits, or when nobody has attached for GRACE seconds and the chat
isn't busy or waiting for an answer.
"""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time

from common import RUN_DIR

SOCK_DIR = os.path.join(RUN_DIR, "chats")
GRACE = 10 * 60
CHAT_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chat.py")


def sock_path(key):
    return os.path.join(SOCK_DIR, re.sub(r"[^A-Za-z0-9_-]", "", key)[:64] + ".sock")


def connect(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
        return s
    except OSError:
        s.close()
        return None


# ------------------------------------------------------------------ relay
class Relay:
    def __init__(self, key, args):
        self.path = sock_path(key)
        self.args = args
        self.lock = threading.Lock()
        self.log = []            # events to replay to the next popup
        self.client = None
        self.alone_since = time.time()
        self.busy = False
        self.pending = set()     # permission requests not answered yet
        self.queued = []         # messages sent mid-reply, until the AI reads them
        self.child = None
        self.reset_seen = False

    def listen(self):
        os.makedirs(SOCK_DIR, exist_ok=True)
        if os.path.exists(self.path):
            s = connect(self.path)
            if s:                # another relay already has this chat
                s.close()
                return None
            os.unlink(self.path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.path)
        srv.listen(4)
        return srv

    def to_client(self, line):
        c = self.client
        if c is None:
            return
        try:
            c.sendall(line.encode())
        except OSError:
            self.drop(c)

    def drop(self, c):
        if self.client is c:
            self.client = None
            self.alone_since = time.time()
        try:
            c.close()
        except OSError:
            pass

    def record(self, ev):
        """Keep what a fresh popup needs to show the chat as it is now."""
        t = ev.get("type")
        if t == "reset":
            # a message sent while the bridge was starting is logged before its first reset
            kept = [e for e in self.log if e.get("type") == "user"] if not self.reset_seen else []
            self.reset_seen = True
            self.log = [ev] + kept
            return
        elif t == "text" and ev.get("id"):   # the whole block replaces its streamed pieces
            self.log = [e for e in self.log if not (e.get("type") == "delta" and e.get("id") == ev["id"])]
        elif t == "busy":
            self.busy = bool(ev.get("value"))
        elif t == "turn_end":
            self.busy = False
        elif t == "permission":
            self.pending.add(ev.get("id"))
        elif t == "permission_cancel":
            self.pending.discard(ev.get("id"))
        elif t == "consumed":   # a queued message joined the chat: replay it as one
            if self.queued:
                self.log.append(self.queued.pop(0))
            return
        self.log.append(ev)

    def pump_child(self):
        for line in self.child.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            with self.lock:
                self.record(ev)
                self.to_client(line if line.endswith("\n") else line + "\n")
        self.child.wait()
        self.finish()

    def from_client(self, c):
        f = c.makefile("r", encoding="utf-8", errors="replace")
        try:
            for line in f:
                try:
                    cmd = json.loads(line)
                except ValueError:
                    continue
                op = cmd.get("op")
                if op == "quit":
                    self.finish()
                    return
                with self.lock:
                    if op == "send":
                        user = {"type": "user", "text": str(cmd.get("text") or "").strip()}
                        if cmd.get("images"):
                            user["images"] = len(cmd["images"])
                        if cmd.get("queued"):
                            self.queued.append(user)
                        else:
                            self.log.append(user)
                    elif op == "permit":
                        self.pending.discard(cmd.get("id"))
                        self.log.append({"type": "permission_cancel", "id": cmd.get("id")})
                try:
                    self.child.stdin.write(line if line.endswith("\n") else line + "\n")
                    self.child.stdin.flush()
                except (OSError, ValueError):
                    pass
        except OSError:
            pass
        with self.lock:
            self.drop(c)

    def accept(self, srv):
        while True:
            c, _ = srv.accept()
            with self.lock:
                if self.client is not None:   # the newest popup wins
                    self.drop(self.client)
                self.client = c
                replay = [{"type": "replay", "value": True}] + self.log + [{"type": "replay", "value": False}]
                try:
                    c.sendall("".join(json.dumps(e) + "\n" for e in replay).encode())
                except OSError:
                    self.drop(c)
                    continue
            threading.Thread(target=self.from_client, args=(c,), daemon=True).start()

    def finish(self):
        try:
            os.unlink(self.path)
        except OSError:
            pass
        ch = self.child
        if ch and ch.poll() is None:
            try:
                ch.stdin.close()
            except OSError:
                pass
            try:
                ch.wait(8)
            except subprocess.TimeoutExpired:
                ch.terminate()
        os._exit(0)

    def run(self):
        srv = self.listen()
        if srv is None:
            return
        self.child = subprocess.Popen([sys.executable, CHAT_PY, "bridge"] + self.args,
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        threading.Thread(target=self.pump_child, daemon=True).start()
        threading.Thread(target=self.accept, args=(srv,), daemon=True).start()
        while True:
            time.sleep(15)
            with self.lock:
                idle = (self.client is None and not self.busy and not self.pending
                        and time.time() - self.alone_since > GRACE)
            if idle:
                self.finish()


def relay(key, args):
    Relay(key, args).run()


# ------------------------------------------------------------------ attach
def start_relay(key, args):
    cmd = [sys.executable, CHAT_PY, "relay", key] + args
    # its own systemd scope, so stopping whatever started the robot doesn't take the chat with it
    if shutil.which("systemd-run") and os.path.isdir(os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"), "systemd")):
        cmd = ["systemd-run", "--user", "--scope", "--collect", "--quiet", "setsid", "-f"] + cmd
        subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)


def attach(key, args):
    path = sock_path(key)
    s = connect(path)
    if s is None:
        start_relay(key, args)
        for _ in range(100):
            time.sleep(0.05)
            s = connect(path)
            if s:
                break
    if s is None:   # no relay: run the chat here (it ends with the popup)
        os.execv(sys.executable, [sys.executable, CHAT_PY, "bridge"] + args)

    def down():
        while True:
            try:
                data = s.recv(65536)
            except OSError:
                data = b""
            if not data:
                os._exit(0)
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
    threading.Thread(target=down, daemon=True).start()
    for line in sys.stdin:
        try:
            s.sendall(line.encode())
        except OSError:
            break
        if '"quit"' in line:
            time.sleep(1)   # the relay closes the socket as it ends
            break
    os._exit(0)
