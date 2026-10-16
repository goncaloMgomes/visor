import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

// Preview of a workspace's windows while the pointer rests on its dot in
// Waybar (Hyprland only; features.workspacePreview). Waybar can't tell us
// about hover, so the dots' positions are worked out from its layout (the
// `waybar` block of the config: bar margins, dot widths with their margins,
// the group centred in the bar) and matched against the pointer file that
// extras/hyprland/visor.lua writes. Expects one dot for workspace 1 and one
// per existing workspace 2..10; see docs/hyprland.md.
PanelWindow {
    id: win

    property real pointerX: -1
    property real pointerY: -1
    property bool blocked: false          // fullscreen, chat open, ...
    property var bar: ({})                // config `waybar`
    property bool lua: false              // Hyprland configured in Lua (else classic dispatchers)

    // --- Waybar geometry (config `waybar`) ------------------------------------
    readonly property real barLeft: bar.marginLeft ?? 10
    readonly property real barRight: bar.marginRight ?? 64
    readonly property real barTop: bar.top ?? 6
    readonly property real barHeight: bar.height ?? 34
    readonly property real dotW: bar.dot ?? 18          // dot + its margins
    readonly property real activeW: bar.activeDot ?? 38

    readonly property real screenW: screen ? screen.width : 1920
    readonly property int activeId: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1

    // dots Waybar shows: 1 always, then every existing workspace 2..10
    readonly property var dots: {
        const ids = [1]
        for (const ws of Hyprland.workspaces.values)
            if (ws.id > 1 && ws.id <= 10) ids.push(ws.id)
        ids.sort((a, b) => a - b)
        const total = ids.reduce((s, id) => s + (id === activeId ? activeW : dotW), 0)
        let x = (barLeft + screenW - barRight) / 2 - total / 2
        return ids.map(id => {
            const w = id === activeId ? activeW : dotW
            const d = { id: id, x: x, w: w }
            x += w
            return d
        })
    }

    readonly property var dotUnder: {
        if (pointerY < barTop || pointerY > barTop + barHeight) return null
        for (const d of dots)
            if (pointerX >= d.x && pointerX < d.x + d.w) return d
        return null
    }

    // the workspace being previewed (stays while the pointer is on the card)
    property var shownDot: null
    readonly property var workspace: {
        if (!shownDot) return null
        for (const ws of Hyprland.workspaces.values) if (ws.id === shownDot.id) return ws
        return null
    }
    readonly property var windows: workspace ? workspace.toplevels.values.filter(t => t.wayland) : []
    readonly property bool hovering: hoverId >= 0 || cardHover.hovered
    readonly property bool wanted: !blocked && !dismissed && hovering

    // a click (on a dot or a thumbnail) closes the preview until the pointer
    // leaves the dots and the card
    property bool dismissed: false
    function dismiss() { dismissed = true; showTimer.stop(); shownDot = null }
    function clicked() { if (hovering) dismiss() }
    onHoveringChanged: if (!hovering) dismissed = false

    // dots move when workspaces come and go or the active one changes
    onDotsChanged: if (shownDot) shownDot = dots.find(d => d.id === shownDot.id) || null

    // react to the dot changing, not to every pointer update on the same dot
    // (the binding hands out a new object each time)
    readonly property int hoverId: dotUnder ? dotUnder.id : -1
    onHoverIdChanged: {
        if (dismissed || hoverId < 0) return
        if (shownDot) shownDot = dotUnder                 // sliding along the dots
        else showTimer.restart()
    }
    onWantedChanged: wanted ? hideTimer.stop() : hideTimer.restart()
    Timer { id: showTimer; interval: 280; onTriggered: if (win.dotUnder && !win.blocked && !win.dismissed) win.shownDot = win.dotUnder }
    Timer { id: hideTimer; interval: 220; onTriggered: if (!win.wanted) win.shownDot = null }

    readonly property bool open: shownDot !== null && windows.length > 0

    // --- window ------------------------------------------------------------------
    WlrLayershell.namespace: "visor-wspreview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; left: true }
    visible: open || card.opacity > 0
    color: "transparent"

    readonly property real thumbH: 132
    readonly property real maxW: 900
    readonly property real gap: 10
    readonly property real pad: 10

    function aspect(t) {
        const s = t.lastIpcObject && t.lastIpcObject.size
        return s && s[1] > 0 ? Math.max(0.5, Math.min(2.6, s[0] / s[1])) : 16 / 10
    }
    // all thumbnails share one height, shrunk if the row gets too wide
    readonly property real rowScale: {
        const w = windows.reduce((s, t) => s + thumbH * aspect(t), 0) + gap * Math.max(0, windows.length - 1)
        return w > maxW ? maxW / w : 1
    }

    implicitWidth: Math.max(160, row.implicitWidth + pad * 2)
    implicitHeight: row.implicitHeight + pad * 2 + 10
    margins.top: barTop + barHeight + 6
    margins.left: {
        if (!shownDot) return 0
        const cx = shownDot.x + shownDot.w / 2
        return Math.max(8, Math.min(screenW - implicitWidth - 8, cx - implicitWidth / 2))
    }
    Behavior on margins.left { enabled: card.opacity > 0.5; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    Rectangle {
        id: card
        anchors.fill: parent
        anchors.topMargin: 0
        radius: 16
        color: Qt.rgba(17 / 255, 17 / 255, 27 / 255, 0.92)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.22)
        opacity: win.open ? 1 : 0
        scale: win.open ? 1 : 0.94
        transformOrigin: Item.Top
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        HoverHandler { id: cardHover }

        Row {
            id: row
            x: win.pad; y: win.pad
            spacing: win.gap
            Repeater {
                model: win.windows
                Column {
                    id: cell
                    required property var modelData
                    readonly property real w: win.thumbH * win.rowScale * win.aspect(modelData)
                    spacing: 5
                    Rectangle {
                        width: cell.w
                        height: win.thumbH * win.rowScale
                        radius: 8
                        clip: true
                        color: Qt.rgba(1, 1, 1, 0.06)
                        border.width: thumbHover.hovered ? 2 : 0
                        border.color: "#33ccff"
                        ScreencopyView {
                            id: shot
                            anchors.fill: parent
                            anchors.margins: parent.border.width
                            captureSource: win.open ? cell.modelData.wayland : null
                            live: win.open
                            constraintSize: Qt.size(width * 1.5, height * 1.5)
                            // `clip` cuts square: round the capture itself, same
                            // curve as the border around it
                            layer.enabled: true
                            layer.effect: MultiEffect {
                                maskEnabled: true
                                maskSource: shotMask
                                maskThresholdMin: 0.5
                                maskSpreadAtMin: 1.0
                            }
                        }
                        Item {
                            id: shotMask
                            width: shot.width; height: shot.height
                            layer.enabled: true
                            visible: false
                            Rectangle {
                                anchors.fill: parent
                                radius: Math.max(0, 8 - shot.anchors.margins)
                                antialiasing: true
                            }
                        }
                        HoverHandler { id: thumbHover }
                        TapHandler {
                            onTapped: (point, button) => {
                                // focus it, then put the pointer back where it was
                                // (Hyprland warps it to the focused window)
                                const a = String(cell.modelData.address).replace(/^0x/, "")
                                const x = Math.round(win.margins.left + point.scenePosition.x)
                                const y = Math.round(win.margins.top + point.scenePosition.y)
                                Quickshell.execDetached(["sh", "-c", win.lua
                                    ? "hyprctl dispatch 'hl.dsp.focus({ window = \"address:0x" + a + "\" })' >/dev/null; " +
                                      "hyprctl dispatch 'hl.dsp.cursor.move({ x = " + x + ", y = " + y + " })' >/dev/null"
                                    : "hyprctl dispatch focuswindow address:0x" + a + " >/dev/null; " +
                                      "hyprctl dispatch movecursor " + x + " " + y + " >/dev/null"])
                                win.dismiss()
                            }
                        }
                    }
                    Text {
                        width: cell.w
                        text: cell.modelData.title
                        color: "#ffffff"
                        opacity: 0.85
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        font.family: Style.mono
                        font.pixelSize: 12
                    }
                }
            }
        }
    }
}
