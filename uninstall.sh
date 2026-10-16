#!/bin/sh
# Remove what install.sh put in place (your config and chats stay unless --purge).
set -e
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/visor"
"$HOME/.local/bin/visor" stop 2>/dev/null || true
systemctl --user disable --now visor.service 2>/dev/null || true
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/visor.service" "$HOME/.local/bin/visor"
[ -f "$HOME/.claude/settings.json" ] && python3 "$DEST/backend/visor_setup.py" claude-code --remove || true
python3 "$DEST/backend/waybar.py" remove >/dev/null 2>&1 || true
rm -rf "$DEST"
if [ "$1" = "--purge" ]; then
    rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/visor" "${XDG_STATE_HOME:-$HOME/.local/state}/visor" "${XDG_RUNTIME_DIR:-/tmp}/visor"
    echo "removed config and chats too"
fi
echo "Visor removed. If you added it to your compositor's autostart or keybinds, remove those lines."
