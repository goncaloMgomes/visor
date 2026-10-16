#!/usr/bin/env bash
# Claude Code hook -> Visor mood (status adapter, see docs/PROTOCOL.md).
# Reads the hook JSON on stdin, writes the mood to $XDG_RUNTIME_DIR/visor/state
# and the claude.ai link of the session that fired it to .../url. Events the
# speech balloon cares about (turn started/finished, needs approval, error) are
# appended to .../events as JSON lines.
# Never fails the hook: any error just leaves the face as it was.
# Install with `visor setup claude-code`.

# the robot's own background calls (remarks.py) don't move the face
[ -n "$VISOR_QUIET" ] && exit 0
command -v jq >/dev/null || exit 0

dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/visor"
mkdir -p "$dir" 2>/dev/null || exit 0

IFS=$'\x1f' read -r event sid ntype tool transcript < <(
    jq -r '[.hook_event_name // "", .session_id // "", .notification_type // "", .tool_name // "", .transcript_path // ""] | join("\u001f")' 2>/dev/null
) || exit 0

note() {   # note <kind>
    [ -n "$transcript" ] || return 0
    jq -nc --arg k "$1" --arg s "$sid" --arg p "$transcript" --argjson t "$(date +%s)" \
        '{kind: $k, sid: $s, transcript: $p, t: $t, source: "claude-code"}' >> "$dir/events" 2>/dev/null
}

case "$event" in
    SessionStart)       mood=idle ;;
    UserPromptSubmit)   mood=thinking; note start ;;
    PreToolUse)
        case "$tool" in
            AskUserQuestion|ExitPlanMode) mood=input ;;
            *)                            mood=working ;;
        esac ;;
    PostToolUse)        mood=thinking ;;
    PostToolUseFailure) mood=nervous ;;
    SubagentStart)      mood=working ;;
    PermissionRequest)  mood=input; note ask ;;
    Notification)
        case "$ntype" in
            permission_prompt|elicitation_dialog) mood=input; note ask ;;
            idle_prompt)                          mood=idle ;;
            *)                                    exit 0 ;;
        esac ;;
    Stop)               mood=done; note stop ;;
    StopFailure)        mood=error; note error ;;
    SessionEnd)         mood=idle ;;
    *)                  exit 0 ;;
esac

# Remote Control sessions (cse_…) live at claude.ai/code/session_…
case "$sid" in
    cse_*)     printf '%s\n' "https://claude.ai/code/session_${sid#cse_}" > "$dir/url" ;;
    session_*) printf '%s\n' "https://claude.ai/code/$sid" > "$dir/url" ;;
esac

printf '%s\n' "$mood" > "$dir/state"
exit 0
