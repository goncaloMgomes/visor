# Plugging an AI into Visor

Visor connects to AI tools in two separate ways, and an AI can use either one or both:

1. **Status**: the face shows what an AI tool is doing (thinking, working, needs you, done). Any tool that can run a command when something happens can do this.
2. **Chat**: the popup you get by clicking the robot. A *backend* runs the conversation.

```
 AI tool (Claude Code, Codex, your script…)                     ┌──────────────┐
   └─ adapter / `visor signal` ─► $XDG_RUNTIME_DIR/visor/state ─►│              │
                                   $XDG_RUNTIME_DIR/visor/events ►│  the robot   │
                                                                  │ (Quickshell) │
 chat popup ◄── JSON lines ──► backend/chat.py bridge ──► backend │              │
                                                                  └──────────────┘
```

---

## 1. Status

### The easy way: `visor signal`

```sh
visor signal thinking            # set the face
visor signal working
visor signal --event ask  --title "Deploy script"            # "?" face + "needs your approval" balloon
visor signal --event stop --title "Fix login" --text "Done, 3 files changed"
visor signal --event error --title "Fix login"
visor signal idle
```

Moods: `idle`, `thinking`, `working`, `input` (needs you; it stays until the next mood), `done` and `error` (both show briefly, then idle), `nervous` (a tool failed), and `love`.

Events (`--event`) also put a message in the speech balloon:

| Event | Default mood | Balloon |
|---|---|---|
| `start` | thinking | nothing; it marks when a turn started |
| `stop` | done | "*title* is done: *text*". Turns under 20 s after their `start` (same `--sid`) aren't announced |
| `ask` | input | "*title* needs your approval" |
| `error` | error | "*title* hit an error" |

The variable `VISOR_QUIET=1` makes `visor signal` do nothing. The robot sets it on its own background AI calls so they don't move the face.

### The files underneath

Adapters can also write the files directly, which is faster than starting Python on every hook:

- **`$XDG_RUNTIME_DIR/visor/state`**: one line, the mood. The robot watches the file.
- **`$XDG_RUNTIME_DIR/visor/events`**: append one JSON object per line:
  ```json
  {"kind": "stop", "t": 1760000000, "source": "my-agent", "sid": "abc", "title": "Fix login", "text": "Done"}
  ```
  Instead of `title`/`text`, an event can give a `transcript` path. The backend named by `source` then summarises it (`chat.py summary <transcript> <source>`). When `source` is the popup's own backend, clicking the balloon opens that chat in the popup.

### Adapters included

| Tool | Adapter | How to connect it | What the face sees |
|---|---|---|---|
| **Claude Code** | `adapters/claude-code/hook.sh` | `visor setup claude-code` (adds hooks to `~/.claude/settings.json`, with a backup) | everything: thinking, each tool, permission prompts, questions, done, errors |
| **OpenAI Codex CLI** | `adapters/codex/notify.py` | `visor setup codex` prints the `notify = [...]` line for `~/.codex/config.toml` | finished turns only (Codex's `notify` doesn't report more) |
| **Anything else** | `visor signal` | call it from the tool's hooks, plugins or a wrapper script | whatever you report |

Writing a new adapter: map the tool's events onto the moods above. See `hook.sh` for a complete example. Pull requests for Gemini CLI, OpenCode, Aider and others are welcome.

---

## 2. Chat backends

The popup starts `backend/chat.py bridge <session|new> <cwd> <model> <fork 0|1>` and talks to it in JSON lines. The bridge loads the backend named by `backend` in the config.

### Included

- **`claude-code`**: runs Claude Code headless (`claude -p`, stream-json). It needs Claude Code installed and logged in (a subscription or an API key). It brings Claude Code's tools, permission prompts and questions. Recents lists every Claude Code session on the machine, and ↗ continues a chat in a terminal.
- **`openai`**: any `/chat/completions` API (OpenAI, OpenRouter, Gemini's OpenAI endpoint, Mistral, Groq, DeepSeek, Ollama, LM Studio, llama.cpp, vLLM). It uses only the Python standard library. Chats are saved in `~/.local/state/visor/chats/`. With `chat.computerUse`, the model gets the desktop tools and the popup asks before each action.

Example configs:

```jsonc
// Ollama, fully local
{ "backend": "openai",
  "backends": { "openai": { "name": "Llama", "baseUrl": "http://localhost:11434/v1",
                            "apiKeyEnv": "", "defaultModel": "llama3.2" } } }

// OpenRouter, with a model picker
{ "backend": "openai",
  "backends": { "openai": { "name": "OpenRouter", "baseUrl": "https://openrouter.ai/api/v1",
                            "apiKeyEnv": "OPENROUTER_API_KEY",
                            "models": [ { "id": "provider/model-a", "name": "Model A" },
                                        { "id": "provider/model-b", "name": "Model B" } ] } } }
```

API keys: `apiKey` (in the file), `apiKeyEnv` (an environment variable; note that programs started by your compositor may not see variables set in your shell's rc file), or `apiKeyCommand` (e.g. `"pass show openrouter"`).

### Writing a backend

Add `backend/backends/<name>.py` with a `Backend(cfg)` class and register it in `backends/__init__.py`. The methods are listed at the top of that file: `info`, `sessions`, `bridge`, `summary`, `complete` and `terminal_command`. `openai_compat.py` is a complete example in about 400 lines.

**`info()`** tells the popup what to show:

```json
{ "id": "my-ai", "name": "My AI",
  "models": [{"id": "fast", "name": "Fast", "blurb": "Quick answers"}], "defaultModel": "fast",
  "mode": {"label": "Ask", "tip": "Asks before acting"},
  "features": {"permissions": true, "questions": false, "terminal": false, "modelSwitch": true},
  "available": true }
```

Set `mode: null` to hide the mode chip and `models: []` to hide the model picker. `available: false` makes the popup say it isn't set up.

**The bridge.** Commands arrive on stdin, one JSON object per line:

| `op` | Fields | Meaning |
|---|---|---|
| `send` | `text`, `screenshot` (path or ""), `window` | a message from the user |
| `stop` | | interrupt the reply |
| `model` | `model` | switch model (also mid-chat) |
| `permit` | `id`, `allow`, `always`, `answers`, `message` | answer a `permission` event |
| `release` | | free resources (e.g. before the chat continues in a terminal) |

Events go to stdout, one JSON object per line:

| `type` | Fields | Meaning |
|---|---|---|
| `reset` | | clear the view (sent first, then the history) |
| `user` | `text` | a past user message (history only) |
| `delta` | `id`, `text` | a piece of a reply being written |
| `text` | `id`, `text` | a finished reply block (replaces the deltas with the same `id`) |
| `tool` | `name`, `text`, `arg`, `code`, `desc`, `add`, `del` | a tool call (`code` = a shell command, shown in a block) |
| `model` | `value`, `label`, `alias` | the model actually answering (`alias` = its id in `models`) |
| `busy` | `value` | working / idle; send `false` after the history |
| `activity` | `text` | a short "what I'm doing" for the spinner |
| `permission` | `id`, `tool`, `title`, `desc`, `code`, `always`, `questions` | ask the user; `questions` (AskUserQuestion format) makes it a question card |
| `permission_cancel` | `id` | the request went away |
| `session` | `id`, `transcript` | the chat's id and file, once it exists |
| `turn_end`, `interrupted`, `error {text}`, `exited {code}` | | |

**`complete(system, prompt, schema=None)`** returns text, used for the balloon's AI-written lines. The reply should be the JSON object the prompt asks for; fences and extra chatter are tolerated.
