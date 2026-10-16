#!/bin/sh
# Install Visor for this user: ~/.local/share/visor + ~/.local/bin/visor.
#   ./install.sh          copy the files
#   ./install.sh --link   symlink this checkout instead (for development)
# Then: visor setup config, visor setup claude-code (if you use Claude Code), visor doctor.
set -e
SRC=$(cd "$(dirname "$0")" && pwd)
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/visor"
BIN="$HOME/.local/bin"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 ($2)"; MISSING=1; }; }
need qs "Quickshell, e.g. pacman -S quickshell"
need python3 "Python 3"
[ -n "$MISSING" ] && { echo "install those first"; exit 1; }

mkdir -p "$(dirname "$DEST")" "$BIN"
if [ "$1" = "--link" ]; then
    rm -rf "$DEST"; ln -s "$SRC" "$DEST"
    echo "linked $DEST -> $SRC"
else
    rm -rf "$DEST"; mkdir -p "$DEST"
    for d in bin backend quickshell themes adapters extras scripts packaging; do cp -r "$SRC/$d" "$DEST/"; done
    cp "$SRC/config.example.json" "$SRC/LICENSE" "$SRC/README.md" "$DEST/"
    find "$DEST" -name __pycache__ -prune -exec rm -rf {} +
    echo "installed to $DEST"
fi
ln -sf "$DEST/bin/visor" "$BIN/visor"
echo "command: $BIN/visor"

mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
sed "s|^ExecStart=.*|ExecStart=$BIN/visor start|" "$SRC/packaging/systemd/visor.service" \
    > "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/visor.service"
systemctl --user daemon-reload 2>/dev/null || true

"$BIN/visor" setup config || true
cat <<MSG

Next:
  visor doctor                      see what works on this machine
  visor setup claude-code           follow Claude Code sessions (adds hooks; backs up settings.json)
  visor                             start it now

Start it with your desktop, either:
  systemctl --user enable --now visor.service    (compositors that start graphical-session.target, e.g. via uwsm)
  or add 'exec-once = visor' to hyprland.conf / 'exec visor' to your sway config
MSG
case ":$PATH:" in *":$BIN:"*) ;; *) echo; echo "note: $BIN isn't in your PATH";; esac
