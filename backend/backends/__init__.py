"""Chat backends: one module per kind of AI, all speaking the same protocol
to the popup (see docs/PROTOCOL.md).

A backend module defines `Backend(cfg)` with:

  info()                         -> dict   name, models, features, theme (shown by the popup)
  sessions()                     -> list   recent chats [{id, file, cwd, title, mtime, live, owned, url}]
  bridge(session, cwd, model, fork)        run one chat: JSON commands on stdin, events on stdout
  summary(path)                  -> dict   {title, last} of a chat, for balloon messages
  complete(system, prompt)       -> str    one-shot text (the balloon's AI-written lines)
  terminal_command(session, cwd) -> list   argv to continue a chat in a terminal ([] = not possible)
"""
import importlib

BACKENDS = {
    "claude-code": "claude_code",
    "openai": "openai_compat",
}


def load(cfg, name=None):
    name = name or cfg.get("backend") or "claude-code"
    mod = BACKENDS.get(name)
    if not mod:
        raise SystemExit(f"unknown backend {name!r}; known: {', '.join(BACKENDS)}")
    return importlib.import_module(f"backends.{mod}").Backend(cfg)
