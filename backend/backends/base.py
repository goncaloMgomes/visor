"""Bits every backend shares: writing events to the popup, tool-call labels,
the robot's own session list, and the instructions every AI gets."""
import difflib
import json
import os
import re
import sys
import threading

from common import STATE_DIR

_EMIT_LOCK = threading.Lock()
ROBOT_SESSIONS = os.path.join(STATE_DIR, "robot-sessions.json")
DESKTOP_MCP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "desktop_mcp.py")


def emit(ev):
    with _EMIT_LOCK:
        sys.stdout.write(json.dumps(ev) + "\n")
        sys.stdout.flush()


def home_short(p):
    return re.sub(r"^/home/[^/]+", "~", str(p))


def popup_prompt(computer_use):
    """What every chat AI is told about where it lives."""
    p = ("The user is talking to you from a small chat popup that drops down from an "
         "animated robot face in a corner of their Linux desktop. The popup is narrow "
         "(about 420-600px), so keep answers short and skimmable. Each message may start "
         "with a <desktop-context> block naming the focused window and, when the user "
         "shares their screen, where to find a screenshot of what they were doing when "
         "the popup opened. Looking at a screenshot is slow and costly: only look when "
         "the question can't be answered without seeing the screen. If the context has "
         "no screenshot, the user turned screen sharing off: don't try to see the screen.")
    if computer_use:
        p += (" You can also use the computer: the `desktop` tools list/focus/launch windows, "
              "drive the mouse and keyboard (click, type, key, scroll, drag) and take "
              "screenshots. Prefer the tools that don't need the screen (windows, focus, "
              "launch, key) and take a screenshot only when you have to see something, e.g. "
              "to find where to click or to check a result you can't verify otherwise. The "
              "chat popup closes when the user clicks elsewhere, so tell them what you're "
              "about to do before taking over the mouse.")
    return p


def tool_summary(name, inp):
    v = ""
    if isinstance(inp, dict):
        v = inp.get("file_path") or inp.get("pattern") or inp.get("query") or inp.get("url") \
            or inp.get("command") or inp.get("path") or inp.get("description") or ""
    v = home_short(v).splitlines()[0][:70] if v else ""
    return f"{name}  {v}" if v else name


def tool_event(name, inp):
    """A tool call: one-line label, plus the full command for shell tools and
    +/- line counts for edits."""
    ev = {"type": "tool", "text": tool_summary(name, inp), "name": name, "code": "", "desc": ""}
    if isinstance(inp, dict):
        if name in ("Bash", "PowerShell", "shell") and inp.get("command"):
            ev["code"] = str(inp["command"])[:4000]
            ev["desc"] = str(inp.get("description") or "")[:120]
        v = inp.get("file_path") or inp.get("pattern") or inp.get("query") or inp.get("url") \
            or inp.get("path") or inp.get("description") or inp.get("prompt") or inp.get("text") \
            or inp.get("keys") or ""
        if not ev["code"] and v:
            ev["arg"] = home_short(v).splitlines()[0][:200]
        pairs = []
        if name == "Edit":
            pairs = [(inp.get("old_string") or "", inp.get("new_string") or "")]
        elif name == "MultiEdit":
            pairs = [(e.get("old_string") or "", e.get("new_string") or "") for e in inp.get("edits") or []]
        elif name == "Write":
            pairs = [("", inp.get("content") or "")]
        for a, b in pairs:
            for d in difflib.ndiff(str(a).splitlines(), str(b).splitlines()):
                if d.startswith("+ "):
                    ev["add"] = ev.get("add", 0) + 1
                elif d.startswith("- "):
                    ev["del"] = ev.get("del", 0) + 1
    return ev


def desktop_context(c):
    """The <desktop-context> block in front of a message (text part only)."""
    ctx = []
    if c.get("window"):
        ctx.append(f"Focused window: {c['window']}")
    if c.get("screenshot") and os.path.exists(c["screenshot"]):
        ctx.append(f"Screenshot of the screen when the popup opened (look only if needed): {c['screenshot']}")
    return ("<desktop-context>\n" + "\n".join(ctx) + "\n</desktop-context>\n\n") if ctx else ""


CTX_RE = re.compile(r"<desktop-context>.*?</desktop-context>\s*", re.S)


def robot_sessions():
    try:
        with open(ROBOT_SESSIONS) as f:
            return set(json.load(f))
    except (OSError, ValueError):
        return set()


def remember_robot_session(sid):
    ids = robot_sessions()
    if not sid or sid in ids:
        return
    ids.add(sid)
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(ROBOT_SESSIONS, "w") as f:
        json.dump(sorted(ids)[-500:], f)


def json_from_text(text):
    """The first JSON object in a model's reply (tolerates ```json fences and chatter)."""
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        pass
    m = re.search(r"\{.*\}", text or "", re.S)
    if m:
        try:
            return json.loads(m.group(0))
        except ValueError:
            pass
    return None
