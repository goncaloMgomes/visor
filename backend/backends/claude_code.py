"""Claude Code backend.

Chats run Claude Code headless (`claude -p` with stream-json in and out, the
interface the Claude Agent SDK uses). Replies stream in as they are written,
and permission requests and AskUserQuestion questions come to the popup.
Sessions are Claude Code's own transcripts under ~/.claude/projects, so the
popup's Recents also lists chats started in a terminal.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

from common import RUN_DIR
from backends.base import (CTX_RE, DESKTOP_MCP, desktop_context, emit, json_from_text, popup_prompt,
                           remember_robot_session, robot_sessions, tool_event)

PROJECTS = os.path.expanduser("~/.claude/projects")
REGISTRY = os.path.expanduser("~/.claude/sessions")
IDLE_EXIT = 30 * 60   # a chat's Claude process exits after this long unused; it's resumed on the next message
PASTE_RE = re.compile(r"</?pasted_content[^>]*>")
# text Claude Code itself puts in the user's turn (command output, compaction notes)
HARNESS_PREFIXES = ("<", "[Request interrupted", "This session is being continued from a previous conversation",
                    "Caveat: The messages below")
MODES = {   # id -> (label, tip); the popup's mode menu lists all but bypassPermissions
    "default": ("Ask", "Claude asks before editing files or running commands"),
    "acceptEdits": ("Edits", "Claude edits files without asking, and asks before running commands"),
    "auto": ("Auto", "Auto mode: Claude acts without asking, risky actions are blocked"),
    "plan": ("Plan", "Plan mode: Claude only reads and proposes a plan"),
    "bypassPermissions": ("Bypass", "Claude never asks: every action is allowed"),
}


# ------------------------------------------------------------------ helpers
def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def clean_user(text):
    text = CTX_RE.sub("", PASTE_RE.sub("", text)).strip()
    if not text or text.startswith(HARNESS_PREFIXES):   # harness-injected messages
        return ""
    return text


def registry():
    """pid -> registry entry for Claude Code processes that are still alive."""
    out = {}
    for f in glob.glob(os.path.join(REGISTRY, "*.json")):
        try:
            with open(f) as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        if d.get("sessionId") and os.path.exists(f"/proc/{d.get('pid')}"):
            out[int(d["pid"])] = d
    return out


def transcript_path(cwd, sid):
    found = glob.glob(os.path.join(PROJECTS, "*", sid + ".jsonl"))
    if found:
        return found[0]
    return os.path.join(PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", cwd), sid + ".jsonl")


def bridge_url(bridge):
    return f"https://claude.ai/code/{bridge}" if bridge else ""


def events_of(o):
    """Popup events for one transcript line."""
    if o.get("isSidechain"):
        return []
    t = o.get("type")
    if t == "system" and o.get("subtype") in ("turn_duration", "stop_hook_summary"):
        return [{"type": "turn_end"}]
    if t == "user" and not o.get("isMeta"):
        raw = text_of(o.get("message", {}).get("content"))
        if raw.startswith("[Request interrupted"):
            return [{"type": "interrupted"}]
        text = clean_user(raw)
        return [{"type": "user", "text": text}] if text else []
    if t == "assistant":
        ev = []
        msg = o.get("message", {})
        for b in msg.get("content") or []:
            if b.get("type") == "text" and b.get("text", "").strip():
                ev.append({"type": "text", "text": b["text"].strip()})
            elif b.get("type") == "tool_use":
                ev.append(tool_event(b.get("name", ""), b.get("input")))
        model = msg.get("model") or ""
        if model.startswith("claude-"):
            ev.insert(0, {"type": "model", "value": model, "label": model_label(model)})
        if msg.get("stop_reason") == "end_turn":   # not every session writes turn_duration
            ev.append({"type": "turn_end"})
        return ev
    return []


def model_label(model):
    """claude-opus-4-1-2025… -> "Opus 4.1"; the alias it belongs to"""
    m = re.match(r"claude-(\w+?)-(\d+)-(\d+)", model or "")
    return f"{m.group(1).capitalize()} {m.group(2)}.{m.group(3)}" if m else model


def model_alias(model):
    m = re.match(r"claude-(opus|sonnet|haiku)", model or "")
    return m.group(1) if m else ""


def history(path):
    """reset + the transcript's last 60 messages + its model."""
    hist, last_model = [], None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                for ev in events_of(o):
                    if ev["type"] in ("user", "text", "tool"):
                        hist.append(ev)
                    elif ev["type"] == "model":
                        last_model = ev
    except OSError:
        pass
    emit({"type": "reset"})
    for ev in hist[-60:]:
        emit(ev)
    if last_model:
        last_model["alias"] = model_alias(last_model["value"])
        emit(last_model)


def ask_event(rid, req):
    """A permission request (or AskUserQuestion) as a popup event."""
    name = req.get("tool_name") or ""
    inp = req.get("input") or {}
    ev = tool_event(name, inp)
    ev.update({"type": "permission", "id": rid, "tool": name,
               "title": req.get("title") or "",
               "desc": req.get("description") or ev.get("desc") or "",
               "always": bool(req.get("permission_suggestions"))})
    if name == "AskUserQuestion":
        ev["questions"] = inp.get("questions") or []
    return ev


def mcp_config():
    path = os.path.join(RUN_DIR, "desktop-mcp.json")
    os.makedirs(RUN_DIR, exist_ok=True)
    with open(path, "w") as f:
        json.dump({"mcpServers": {"desktop": {"type": "stdio", "command": DESKTOP_MCP}}}, f)
    return path


# ------------------------------------------------------------------ one chat
class Bridge:
    def __init__(self, be, session, cwd, model, fork, mode=""):
        self.be = be
        self.perm = mode if mode in MODES else be.mode()
        self.sid = "" if session in ("", "new") else session
        self.cwd = cwd if cwd and os.path.isdir(cwd) else be.default_cwd()
        self.model = model if model in be.model_ids() else be.default_model()
        self.fork = fork == "1"
        self.proc = None
        self.busy = False
        self.stopping = False
        self.pending = {}        # request_id -> can_use_tool request
        self.last_use = time.time()
        self.lock = threading.Lock()
        self.req = 0
        self.err = ""

    # -- Claude process
    def spawn(self):
        chat = self.be.cfg["chat"]
        cmd = [self.be.claude(), "-p", "--input-format", "stream-json", "--output-format", "stream-json",
               "--include-partial-messages", "--verbose",
               "--model", self.model, "--permission-mode", self.perm,
               "--permission-prompt-tool", "stdio",
               "--append-system-prompt", popup_prompt(chat.get("computerUse")), "--add-dir", RUN_DIR]
        if chat.get("computerUse"):
            cmd += ["--mcp-config", mcp_config()]
        if self.sid:
            cmd += ["--resume", self.sid]
            if self.fork:
                cmd.append("--fork-session")
        else:
            cmd += ["--name", "Visor · " + time.strftime("%-d %b %H:%M")]
        self.proc = subprocess.Popen(cmd, cwd=self.cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        self.fork = False
        self.text_n = {}         # message id -> text blocks seen (streamed)
        self.final_n = {}        # message id -> text blocks seen (complete)
        self.msg = ""
        threading.Thread(target=self.read, args=(self.proc,), daemon=True).start()
        threading.Thread(target=self.read_err, args=(self.proc,), daemon=True).start()
        self.control({"subtype": "initialize"})

    def write(self, o):
        p = self.proc
        if not p or p.poll() is not None:
            return False
        try:
            with self.lock:
                p.stdin.write(json.dumps(o) + "\n")
                p.stdin.flush()
            return True
        except (BrokenPipeError, OSError):
            return False

    def control(self, request):
        self.req += 1
        return self.write({"type": "control_request", "request_id": f"visor-{self.req}", "request": request})

    def end(self):
        p, self.proc = self.proc, None
        if p and p.poll() is None:
            try:
                p.stdin.close()
            except OSError:
                pass
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                p.terminate()

    def read_err(self, p):
        for line in p.stderr:
            self.err = (self.err + line)[-600:]

    def read(self, p):
        for line in p.stdout:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            try:
                self.handle(o)
            except Exception as e:   # one odd event shouldn't end the chat
                emit({"type": "error", "text": f"bridge: {e}"})
        code = p.wait()
        if p is self.proc or self.busy:
            self.proc = None
            if self.busy:
                self.busy = False
                emit({"type": "error", "text": "Claude stopped unexpectedly. " + self.err.strip()[-300:]})
                emit({"type": "busy", "value": False})
            emit({"type": "exited", "code": code})

    def handle(self, o):
        t = o.get("type")
        if o.get("parent_tool_use_id"):   # a subagent's own messages
            return
        if t == "system":
            st = o.get("subtype")
            if st == "init":
                sid = o.get("session_id") or ""
                if sid and sid != self.sid:
                    self.sid = sid
                remember_robot_session(self.sid)
                emit({"type": "session", "id": self.sid, "transcript": transcript_path(self.cwd, self.sid)})
            elif st == "task_summary" and o.get("detail"):
                emit({"type": "activity", "text": o["detail"]})
        elif t == "stream_event":
            e = o.get("event") or {}
            et = e.get("type")
            if et == "message_start":
                self.msg = (e.get("message") or {}).get("id") or ""
            elif et == "content_block_start" and (e.get("content_block") or {}).get("type") == "text":
                k = self.text_n.get(self.msg, 0)
                self.text_n[self.msg] = k + 1
                self.cur = f"{self.msg}:{k}"
            elif et == "content_block_delta" and (e.get("delta") or {}).get("type") == "text_delta":
                emit({"type": "delta", "id": getattr(self, "cur", ""), "text": e["delta"].get("text", "")})
        elif t == "assistant":
            msg = o.get("message") or {}
            mid = msg.get("id") or ""
            model = msg.get("model") or ""
            if model.startswith("claude-"):
                emit({"type": "model", "value": model, "label": model_label(model), "alias": model_alias(model)})
            for b in msg.get("content") or []:
                if b.get("type") == "text" and b.get("text", "").strip():
                    k = self.final_n.get(mid, 0)
                    self.final_n[mid] = k + 1
                    emit({"type": "text", "id": f"{mid}:{k}", "text": b["text"].strip()})
                elif b.get("type") == "tool_use":
                    emit(tool_event(b.get("name", ""), b.get("input")))
        elif t == "result":
            self.busy = False
            self.last_use = time.time()
            if self.stopping:
                emit({"type": "interrupted"})
            elif o.get("is_error"):
                emit({"type": "error", "text": str(o.get("result") or o.get("subtype") or "Error")[:400]})
            self.stopping = False
            for rid in list(self.pending):
                emit({"type": "permission_cancel", "id": rid})
            self.pending.clear()
            emit({"type": "turn_end"})
        elif t == "control_request":
            rid = o.get("request_id")
            req = o.get("request") or {}
            if req.get("subtype") == "can_use_tool":
                self.pending[rid] = req
                emit(ask_event(rid, req))
            else:   # nothing else is expected; don't leave Claude waiting
                self.write({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
        elif t == "control_cancel_request":
            rid = o.get("request_id")
            if self.pending.pop(rid, None) is not None:
                emit({"type": "permission_cancel", "id": rid})

    # -- commands from the popup
    def send(self, c):
        text = str(c.get("text") or "").strip()
        if not text:
            return
        prompt = desktop_context(c) + text   # Claude reads the screenshot itself (it's in --add-dir)
        if not self.proc or self.proc.poll() is not None:
            self.spawn()
        self.busy = True
        self.last_use = time.time()
        emit({"type": "busy", "value": True})
        if not self.write({"type": "user", "message": {"role": "user", "content": prompt}}):
            self.busy = False
            emit({"type": "error", "text": "Couldn't reach Claude. " + self.err.strip()[-300:]})
            emit({"type": "busy", "value": False})

    def permit(self, c):
        rid = c.get("id")
        req = self.pending.pop(rid, None)
        if req is None:
            return
        if c.get("allow"):
            inp = dict(req.get("input") or {})
            if c.get("answers"):
                inp["answers"] = c["answers"]
            resp = {"behavior": "allow", "updatedInput": inp}
            if c.get("always") and req.get("permission_suggestions"):
                resp["updatedPermissions"] = req["permission_suggestions"]
        else:
            resp = {"behavior": "deny", "message": c.get("message") or "The user declined this in the chat popup."}
        self.write({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": resp}})

    def idle_watch(self):
        while True:
            time.sleep(60)
            if self.proc and not self.busy and not self.pending and time.time() - self.last_use > IDLE_EXIT:
                self.end()

    def run(self):
        if self.sid:
            history(transcript_path(self.cwd, self.sid))
        else:
            emit({"type": "reset"})
        emit({"type": "busy", "value": False})
        threading.Thread(target=self.idle_watch, daemon=True).start()
        for line in sys.stdin:
            try:
                c = json.loads(line)
            except ValueError:
                continue
            op = c.get("op")
            if op == "send":
                self.send(c)
            elif op == "stop":
                if self.busy:
                    self.stopping = True
                    self.control({"subtype": "interrupt"})
            elif op == "model":
                if c.get("model") in self.be.model_ids():
                    self.model = c["model"]
                    self.control({"subtype": "set_model", "model": self.model})
            elif op == "mode":
                if c.get("mode") in MODES:
                    self.perm = c["mode"]
                    if self.proc and self.proc.poll() is None:
                        self.control({"subtype": "set_permission_mode", "mode": self.perm})
            elif op == "permit":
                self.permit(c)
            elif op == "release":
                self.end()
        self.end()   # the popup went away


# ------------------------------------------------------------------ backend
class Backend:
    def __init__(self, cfg):
        self.cfg = cfg
        self.opts = cfg["backends"]["claude-code"]

    def claude(self):
        cmd = self.opts.get("command") or "claude"
        return shutil.which(cmd) or shutil.which(os.path.expanduser("~/.local/bin/claude")) or cmd

    def model_ids(self):
        return [m["id"] for m in self.opts.get("models") or []]

    def default_model(self):
        m = self.cfg["chat"].get("model") or self.opts.get("defaultModel") or "sonnet"
        return m

    def default_cwd(self):
        cwd = self.cfg["chat"]["cwd"]
        return cwd if os.path.isdir(cwd) else os.path.expanduser("~")

    def mode(self):
        m = self.cfg["chat"].get("permissionMode") or "default"
        return m if m in MODES else "default"

    def info(self):
        label, tip = MODES[self.mode()]
        return {
            "id": "claude-code",
            "name": "Claude",
            "models": self.opts.get("models") or [],
            "defaultModel": self.default_model(),
            "mode": {"id": self.mode(), "label": label, "tip": tip},
            "modes": [{"id": k, "label": v[0], "tip": v[1]} for k, v in MODES.items()
                      if k != "bypassPermissions" or self.mode() == k],
            "features": {"permissions": True, "questions": True, "terminal": True,
                         "modelSwitch": True, "recentsFromElsewhere": True},
            "terminalLabel": "Continue in Claude Code (terminal)",
            "available": bool(shutil.which(self.claude())),
        }

    def terminal_command(self, session, cwd):
        return [self.claude(), "--resume", session] if session else []

    def sessions(self):
        out = []
        live = {d["sessionId"]: d.get("bridgeSessionId") or "" for d in registry().values()}
        mine = robot_sessions()
        files = sorted(glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")), key=os.path.getmtime, reverse=True)
        seen = set()
        for path in files:
            sid = os.path.basename(path)[:-6]
            if sid in seen:   # same session copied under several project dirs
                continue
            seen.add(sid)
            cwd = title = first = None
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    for line in f:
                        try:
                            o = json.loads(line)
                        except ValueError:
                            continue
                        t = o.get("type")
                        if cwd is None and o.get("cwd"):
                            cwd = o["cwd"]
                        if t in ("custom-title", "ai-title"):
                            title = o.get("customTitle") or o.get("aiTitle") or title
                        elif t == "user" and first is None and not o.get("isMeta"):
                            first = clean_user(text_of(o.get("message", {}).get("content"))) or None
            except OSError:
                continue
            if not cwd or cwd.startswith("/tmp") or not (title or first):
                continue
            label = (title or first).strip().splitlines()[0]
            out.append({"id": sid, "file": path, "cwd": cwd, "title": label[:70],
                        "mtime": int(os.path.getmtime(path)), "live": sid in live,
                        "owned": sid in mine, "url": bridge_url(live.get(sid))})
            if len(out) >= 25:
                break
        return out

    def bridge(self, session, cwd, model, fork, mode=""):
        Bridge(self, session, cwd, model, fork, mode).run()

    def summary(self, path):
        title, last = None, ""
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        o = json.loads(line)
                    except ValueError:
                        continue
                    t = o.get("type")
                    if t in ("custom-title", "ai-title"):
                        title = o.get("customTitle") or o.get("aiTitle") or title
                    elif t == "user" and title is None and not o.get("isMeta"):
                        first = clean_user(text_of(o.get("message", {}).get("content")))
                        if first:
                            title = first.splitlines()[0]
                    elif t == "assistant" and not o.get("isSidechain"):
                        txt = text_of(o.get("message", {}).get("content")).strip()
                        if txt:
                            last = txt
        except OSError:
            pass
        return {"title": (title or "Claude")[:60], "last": last}

    def complete(self, system, prompt, schema=None):
        """One `claude -p` call on the user's Claude subscription or API key."""
        env = dict(os.environ, VISOR_QUIET="1")   # the hook ignores the robot's own calls
        cmd = [self.claude(), "-p", prompt, "--model", self.opts.get("remarksModel") or "haiku",
               "--effort", "low", "--system-prompt", system, "--tools", "", "--no-session-persistence",
               "--max-turns", "2", "--output-format", "json"]
        if schema:
            cmd += ["--json-schema", json.dumps(schema)]
        with tempfile.TemporaryDirectory() as cwd:   # nothing project-specific gets loaded
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=240, cwd=cwd, env=env)
        d = json_from_text(r.stdout)
        if not isinstance(d, dict):
            raise RuntimeError("claude -p failed: " + (r.stderr or r.stdout)[:300])
        if isinstance(d.get("structured_output"), dict):
            return json.dumps(d["structured_output"])
        return d.get("result") or ""
