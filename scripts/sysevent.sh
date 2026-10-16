#!/bin/sh
# Changes something and tells the robot about it: one line in
# $XDG_RUNTIME_DIR/visor/sys, which shell.qml reads.
#   sysevent.sh bright 5%+     brightnessctl, then "bright <percent>"
#   sysevent.sh caffeine on    just the line (keep-awake on/off)
# Bind your brightness keys to it, e.g. in hyprland.conf:
#   bindel = , XF86MonBrightnessUp, exec, /path/to/visor/scripts/sysevent.sh bright 5%+
d="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/visor"
mkdir -p "$d"
case "$1" in
    bright)
        pct=$(brightnessctl -m -e4 -n2 set "$2" | cut -d, -f4 | tr -d '%')
        echo "bright $pct" >> "$d/sys" ;;
    *)  echo "$*" >> "$d/sys" ;;
esac
# keep the file small
[ "$(wc -l < "$d/sys")" -gt 200 ] && { tail -n 50 "$d/sys" > "$d/sys.tmp"; cat "$d/sys.tmp" > "$d/sys"; rm -f "$d/sys.tmp"; }
exit 0
