"""OpenAI-compatible backend: any server with a /chat/completions endpoint.

That covers OpenAI, OpenRouter, Google Gemini (its OpenAI endpoint), Mistral,
Groq, DeepSeek, and local models through Ollama, LM Studio, llama.cpp or vLLM.
Only the Python standard library is used.

Chats are stored as JSON files in ~/.local/state/visor/chats/. Screenshots
are sent as images when `vision` is on. With chat.computerUse, the model gets
the desktop tools (desktop_mcp.py, spoken to over MCP) and the popup asks
before each action unless chat.permissionMode is "auto" or "bypassPermissions".
"""
import base64
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

from common import STATE_DIR, write_json
from backends.base import (DESKTOP_MCP, desktop_context, emit, popup_prompt, remember_robot_session,
                           tool_event)

CHATS = os.path.join(STATE_DIR, "chats")
MAX_STEPS = 25                     # tool rounds per message
READ_ONLY_TOOLS = {"screenshot", "windows"}


# ------------------------------------------------------------------ MCP client (desktop tools)
class Mcp:
    def __init__(self, command):
        self.p = subprocess.Popen([command], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.n = 0
        self.lock = threading.Lock()
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "visor", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.tools = self.call("tools/list", {}).get("tools", [])

    def call(self, method, params):
        with self.lock:
            self.n += 1
            self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
            self.p.stdin.flush()
            while True:
                line = self.p.stdout.readline()
                if not line:
                    raise RuntimeError("desktop tools stopped")
                msg = json.loads(line)
                if msg.get("id") == self.n:
                    if "error" in msg:
                        raise RuntimeError(msg["error"].get("message", "tool error"))
                    return msg.get("result") or {}

    def openai_tools(self):
        return [{"type": "function", "function": {"name": "desktop__" + t["name"], "description": t["description"],
                                                  "parameters": t["inputSchema"]}} for t in self.tools]

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(3)
        except Exception:
            self.p.kill()


# ------------------------------------------------------------------ HTTP
class Api:
    def __init__(self, opts):
        self.opts = opts
        self.base = (opts.get("baseUrl") or "").rstrip("/")
        self._key = None

    def key(self):
        if self._key is None:
            o = self.opts
            k = o.get("apiKey") or (os.environ.get(o["apiKeyEnv"]) if o.get("apiKeyEnv") else "") or ""
            if not k and o.get("apiKeyCommand"):
                r = subprocess.run(o["apiKeyCommand"], shell=True, capture_output=True, text=True, timeout=20)
                k = r.stdout.strip().splitlines()[0] if r.stdout.strip() else ""
            self._key = k
        return self._key

    def request(self, body):
        headers = {"Content-Type": "application/json", **(self.opts.get("headers") or {})}
        if self.key():
            headers["Authorization"] = "Bearer " + self.key()
        req = urllib.request.Request(self.base + "/chat/completions", data=json.dumps(body).encode(),
                                     headers=headers, method="POST")
        try:
            return urllib.request.urlopen(req, timeout=300)
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:400]
            try:
                detail = json.loads(detail).get("error", {}).get("message") or detail
            except (ValueError, AttributeError):
                pass
            raise RuntimeError(f"{e.code}: {detail}")
        except urllib.error.URLError as e:
            raise RuntimeError(f"can't reach {self.base}: {e.reason}")

    def complete(self, messages, model):
        with self.request({"model": model, "messages": messages}) as r:
            d = json.load(r)
        return (d.get("choices") or [{}])[0].get("message", {}).get("content") or ""

    def stream(self, messages, model, tools, on_text, cancelled):
        """Streams one reply. Returns (text, tool_calls); stops early when cancelled()."""
        body = {"model": model, "messages": messages, "stream": True}
        if tools:
            body["tools"] = tools
        text, calls = "", {}
        with self.request(body) as r:
            for raw in r:
                if cancelled():
                    break
                line = raw.decode(errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except ValueError:
                    continue
                if chunk.get("error"):
                    raise RuntimeError(str(chunk["error"].get("message") or chunk["error"]))
                for ch in chunk.get("choices") or []:
                    d = ch.get("delta") or {}
                    if d.get("content"):
                        text += d["content"]
                        on_text(d["content"])
                    for tc in d.get("tool_calls") or []:
                        c = calls.setdefault(tc.get("index", 0), {"id": "", "name": "", "arguments": ""})
                        c["id"] = tc.get("id") or c["id"]
                        f = tc.get("function") or {}
                        c["name"] += f.get("name") or ""
                        c["arguments"] += f.get("arguments") or ""
        return text, [calls[i] for i in sorted(calls)]


# ------------------------------------------------------------------ one chat
class Bridge:
    def __init__(self, be, session, cwd, model, fork, mode=""):
        self.be = be
        self.api = Api(be.opts)
        self.model = model if model in be.model_ids() else be.default_model()
        self.chat = be.load(session) if session not in ("", "new") else None
        self.cwd = cwd or be.cfg["chat"]["cwd"]
        self.busy = False
        self.stopping = False
        self.pending = {}           # permission id -> [Event, answer]
        self.mcp = None
        self.computer = bool(be.cfg["chat"].get("computerUse"))
        self.ask = (mode or be.cfg["chat"].get("permissionMode")) not in ("auto", "bypassPermissions")

    def system(self):
        extra = self.be.opts.get("systemPrompt") or ""
        return popup_prompt(self.computer) + (("\n\n" + extra) if extra else "")

    def save(self):
        self.chat["updated"] = int(time.time())
        write_json(self.be.path(self.chat["id"]), self.chat)

    def new_chat(self, first):
        cid = uuid.uuid4().hex[:12]
        self.chat = {"id": cid, "title": first.strip().splitlines()[0][:70], "cwd": self.cwd,
                     "model": self.model, "created": int(time.time()), "messages": []}
        remember_robot_session(cid)

    def history(self):
        emit({"type": "reset"})
        if self.chat:
            for m in self.chat["messages"][-60:]:
                if m["role"] == "user" and m.get("shown"):
                    emit({"type": "user", "text": m["shown"]})
                elif m["role"] == "assistant":
                    if m.get("content"):
                        emit({"type": "text", "text": m["content"]})
                    for tc in m.get("tool_calls") or []:
                        emit(self.tool_ev(tc["function"]["name"], tc["function"].get("arguments")))
            if self.chat.get("model"):
                emit({"type": "model", "value": self.chat["model"], "alias": self.chat["model"],
                      "label": self.be.label(self.chat["model"])})
        emit({"type": "busy", "value": False})

    def tool_ev(self, name, args):
        try:
            a = json.loads(args or "{}") if isinstance(args, str) else (args or {})
        except ValueError:
            a = {}
        return tool_event("mcp__desktop__" + name.replace("desktop__", ""), a)

    # -- a turn: runs in its own thread so stop/permit keep working
    def turn(self, c):
        try:
            self._turn(c)
        except Exception as e:
            emit({"type": "error", "text": str(e)[:400]})
        finally:
            if self.stopping:
                emit({"type": "interrupted"})
            self.busy = False
            self.stopping = False
            emit({"type": "turn_end"})

    def _turn(self, c):
        text = str(c.get("text") or "").strip()
        if not self.chat:
            self.new_chat(text)
            emit({"type": "session", "id": self.chat["id"], "transcript": self.be.path(self.chat["id"])})
        msgs = self.chat["messages"]
        content = desktop_context({"window": c.get("window")}) + text
        msgs.append({"role": "user", "content": content, "shown": text})
        user_idx = len(msgs) - 1   # the screenshot goes with this message
        self.chat["model"] = self.model
        self.save()

        tools = None
        if self.computer:
            if not self.mcp:
                self.mcp = Mcp(DESKTOP_MCP)
            tools = self.mcp.openai_tools()

        shot = c.get("screenshot") if self.be.opts.get("vision", True) else ""
        extra_images = []          # this turn's images (not saved)
        for step in range(MAX_STEPS):
            req = [{"role": "system", "content": self.system()}]
            for i, m in enumerate(msgs):
                m = {k: v for k, v in m.items() if k != "shown"}
                if i == user_idx and shot and os.path.exists(shot):
                    m["content"] = [{"type": "text", "text": m["content"]}, image_part(shot)]
                req.append(m)
            req += extra_images
            mid = f"{self.chat['id']}-{len(msgs)}"

            def on_text(t):
                emit({"type": "delta", "id": mid, "text": t})

            out, calls = self.api.stream(req, self.model, tools, on_text, lambda: self.stopping)
            emit({"type": "model", "value": self.model, "alias": self.model, "label": self.be.label(self.model)})
            am = {"role": "assistant", "content": out or None}
            if calls:
                am["tool_calls"] = [{"id": tc["id"] or f"call_{step}_{i}", "type": "function",
                                     "function": {"name": tc["name"], "arguments": tc["arguments"] or "{}"}}
                                    for i, tc in enumerate(calls)]
            msgs.append(am)
            self.save()
            if out.strip():
                emit({"type": "text", "id": mid, "text": out.strip()})
            if self.stopping or not calls:
                return
            for tc in am["tool_calls"]:
                result, images = self.run_tool(tc)
                msgs.append({"role": "tool", "tool_call_id": tc["id"], "content": result})
                if images and self.be.opts.get("vision", True):
                    extra_images = [{"role": "user", "content": [{"type": "text", "text": "(the screenshot the tool took)"}]
                                     + [{"type": "image_url", "image_url": {"url": f"data:{mt};base64,{d}"}} for d, mt in images]}]
                if self.stopping:
                    break
            self.save()
            if self.stopping:
                return
        emit({"type": "error", "text": f"Stopped after {MAX_STEPS} tool rounds."})

    def run_tool(self, tc):
        name = tc["function"]["name"].replace("desktop__", "")
        try:
            args = json.loads(tc["function"]["arguments"] or "{}")
        except ValueError:
            return "error: the arguments weren't valid JSON", []
        ev = self.tool_ev(name, args)
        emit(ev)
        if self.ask and name not in READ_ONLY_TOOLS:
            rid = "p" + uuid.uuid4().hex[:8]
            wait = [threading.Event(), None]
            self.pending[rid] = wait
            emit(dict(ev, type="permission", id=rid, tool="mcp__desktop__" + name, title="", always=False,
                      desc=ev.get("arg") or ""))
            while not wait[0].wait(0.2):
                if self.stopping:
                    self.pending.pop(rid, None)
                    emit({"type": "permission_cancel", "id": rid})
                    return "The user stopped the reply.", []
            if not wait[1].get("allow"):
                return wait[1].get("message") or "The user declined this action.", []
        try:
            res = self.mcp.call("tools/call", {"name": name, "arguments": args})
        except Exception as e:
            return f"error: {e}", []
        texts = [p.get("text", "") for p in res.get("content") or [] if p.get("type") == "text"]
        images = [(p["data"], p.get("mimeType", "image/jpeg")) for p in res.get("content") or [] if p.get("type") == "image"]
        return "\n".join(texts) or "done", images

    def run(self):
        self.history()
        for line in sys.stdin:
            try:
                c = json.loads(line)
            except ValueError:
                continue
            op = c.get("op")
            if op == "send" and not self.busy:
                self.busy = True
                emit({"type": "busy", "value": True})
                threading.Thread(target=self.turn, args=(c,), daemon=True).start()
            elif op == "stop" and self.busy:
                self.stopping = True
            elif op == "mode":
                self.ask = c.get("mode") not in ("auto", "bypassPermissions")
            elif op == "model" and c.get("model") in self.be.model_ids():
                self.model = c["model"]
            elif op == "permit":
                w = self.pending.pop(c.get("id"), None)
                if w:
                    w[1] = c
                    w[0].set()
        if self.mcp:
            self.mcp.close()


def image_part(path):
    with open(path, "rb") as f:
        data = base64.b64encode(f.read()).decode()
    return {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + data}}


# ------------------------------------------------------------------ backend
class Backend:
    def __init__(self, cfg):
        self.cfg = cfg
        self.opts = cfg["backends"]["openai"]

    def models(self):
        ms = list(self.opts.get("models") or [])
        d = self.default_model()
        if d and d not in [m["id"] for m in ms]:
            ms.insert(0, {"id": d, "name": d, "blurb": ""})
        return ms

    def model_ids(self):
        return [m["id"] for m in self.models()]

    def default_model(self):
        return self.cfg["chat"].get("model") or self.opts.get("defaultModel") or \
            ((self.opts.get("models") or [{}])[0].get("id") or "")

    def label(self, model):
        return next((m.get("name") or m["id"] for m in self.models() if m["id"] == model), model)

    def path(self, cid):
        return os.path.join(CHATS, cid + ".json")

    def load(self, cid):
        try:
            with open(self.path(cid)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def info(self):
        computer = bool(self.cfg["chat"].get("computerUse"))
        ask = self.cfg["chat"].get("permissionMode") not in ("auto", "bypassPermissions")
        return {
            "id": "openai",
            "name": self.opts.get("name") or "Assistant",
            "models": self.models(),
            "defaultModel": self.default_model(),
            "mode": ({"id": "default" if ask else "auto", "label": "Ask" if ask else "Auto",
                      "tip": "Asks before using the mouse or keyboard" if ask else "Uses the mouse and keyboard without asking"}
                     if computer else None),
            "modes": [{"id": "default", "label": "Ask", "tip": "Asks before using the mouse or keyboard"},
                      {"id": "auto", "label": "Auto", "tip": "Uses the mouse and keyboard without asking"}] if computer else [],
            "features": {"permissions": computer, "questions": False, "terminal": False,
                         "modelSwitch": True, "recentsFromElsewhere": False},
            "available": bool(self.default_model()) and bool(self.opts.get("baseUrl")),
        }

    def terminal_command(self, session, cwd):
        return []

    def sessions(self):
        out = []
        try:
            names = [n for n in os.listdir(CHATS) if n.endswith(".json")]
        except OSError:
            names = []
        paths = sorted((os.path.join(CHATS, n) for n in names), key=os.path.getmtime, reverse=True)[:25]
        for p in paths:
            try:
                with open(p) as f:
                    c = json.load(f)
            except (OSError, ValueError):
                continue
            out.append({"id": c["id"], "file": p, "cwd": c.get("cwd", ""), "title": c.get("title") or "Chat",
                        "mtime": int(os.path.getmtime(p)), "live": False, "owned": True, "url": ""})
        return out

    def bridge(self, session, cwd, model, fork, mode=""):
        Bridge(self, session, cwd, model, fork, mode).run()

    def summary(self, path):
        try:
            with open(path) as f:
                c = json.load(f)
        except (OSError, ValueError):
            return {"title": self.opts.get("name") or "Assistant", "last": ""}
        last = next((m["content"] for m in reversed(c.get("messages", []))
                     if m["role"] == "assistant" and m.get("content")), "")
        return {"title": c.get("title") or "Chat", "last": last}

    def complete(self, system, prompt, schema=None):
        model = self.opts.get("remarksModel") or self.default_model()
        if not model:
            raise RuntimeError("no model configured for the openai backend")
        return Api(self.opts).complete([{"role": "system", "content": system},
                                        {"role": "user", "content": prompt}], model)
