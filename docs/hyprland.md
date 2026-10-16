# Desktop integration

Visor runs on any Wayland compositor that supports the layer-shell protocol (Hyprland, Sway, niri, river, KDE Plasma, Wayfire…), because that's what [Quickshell](https://quickshell.org) needs. Some extras depend on the compositor:

| Feature | Hyprland | Other compositors |
|---|---|---|
| Face, balloons, chat, weather, battery, system events | ✓ | ✓ |
| Hide when something is fullscreen | ✓ (per workspace) | ✓ (focused window) |
| Click outside the chat or menu to close it | ✓ | Esc, ✕ or clicking the robot |
| Eyes follow the mouse | ✓ | – |
| Curious look when you click elsewhere | with the Lua snippet | – |
| Workspace previews under Waybar's dots | opt-in | – |
| Computer use (the AI drives mouse and keyboard) | opt-in | – |
| Screenshot shared with the chat | ✓ (grim) | wlroots-based ones (grim) |

## Placing the robot

By default it sits in the top-right corner of the screen. If a bar is there, either leave room for it in the bar (for Waybar, a `"margin-right": 64` on the bar) or move the robot with `position` in `~/.config/visor/config.json`:

```json
"position": { "marginTop": 0, "marginRight": 0, "chatTop": 46, "chatRight": 8 }
```

## Starting with your desktop

- systemd: `systemctl --user enable --now visor.service`. This works when your session starts `graphical-session.target` (uwsm, most Sway/niri setups and Plasma).
- Hyprland: `exec-once = visor` in `hyprland.conf`, or `hl.exec_cmd("visor")` in a Lua config.
- Sway: `exec visor`.

## Hyprland: the mouse

With a classic `hyprland.conf`, the robot asks Hyprland's socket for the cursor position by itself (`extras/hyprland/pointer.py`), so the eyes follow the mouse. Clicks can't be seen that way.

With a Lua config (`hyprland.lua`), add `extras/hyprland/visor.lua` to it. It reports the cursor and clicks, so the robot also looks curious now and then when you click.

## Brightness and keep-awake

The robot can't see brightness changes by itself. Route your brightness keys through `scripts/sysevent.sh` (it calls `brightnessctl`):

```ini
# hyprland.conf
bindel = , XF86MonBrightnessUp,   exec, ~/.local/share/visor/scripts/sysevent.sh bright 5%+
bindel = , XF86MonBrightnessDown, exec, ~/.local/share/visor/scripts/sysevent.sh bright 5%-
```

For a keep-awake toggle, call `sysevent.sh caffeine on` / `off` from it.

## Workspace previews (Hyprland + Waybar)

Hovering a workspace dot in Waybar shows live thumbnails of that workspace's windows. Waybar can't report hover, so the robot works out where the dots are from your bar's layout. Turn it on and describe the layout:

```json
"features": { "workspacePreview": true },
"waybar": { "marginLeft": 10, "marginRight": 64, "top": 6, "height": 34, "dot": 18, "activeDot": 38 }
```

`dot` and `activeDot` are the widths of a dot and of the active one, including their margins. It expects the dots centred in the bar: one for workspace 1, and one for each existing workspace from 2 to 10. Set `"tooltip": false` on the workspace modules so Waybar's tooltips don't cover the preview.

## Computer use

With `"chat": { "computerUse": true }`, the chat AI gets tools to take screenshots, move and click the mouse, type, press keys, and list, focus or launch windows (`backend/desktop_mcp.py`, a small MCP server). It needs:

- Hyprland, `grim` and `wtype`
- write access to `/dev/uinput` for mouse buttons, e.g. `sudo usermod -aG input $USER` plus a udev rule, or your distro's `uinput` group

With the Claude Code backend it follows Claude Code's permission mode. With the OpenAI backend the popup asks before every action that isn't a screenshot or a window list, unless `chat.permissionMode` is `"auto"`.
