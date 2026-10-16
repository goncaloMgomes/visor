import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

// The first time the robot starts next to a Waybar that has no room for it,
// it squeezes in: a snapshot of the bar covers the real one while Waybar
// restarts with a right margin (backend/waybar.py), then the robot slides in
// from the screen edge and shoves the bar's end over, twice, into its new
// place. The snapshot fades into the real (restarted) bar and the real robot
// takes over. With reduced motion, or without the bar's geometry, it just
// makes the room.
Scope {
    id: room

    property var screen: null
    property string helper: ""             // backend/waybar.py
    property string runDir: ""
    property real finalX: 0                 // where the robot's window ends up
    property real finalY: 0
    property bool active: false
    signal finished(bool changed)

    property var bar: null                  // {x, y, w, h, gx, gy} on this screen
    property real cut: 0                    // how far the bar's end moves (px)
    property real rx: 0                     // the robot's x, screen coordinates
    property string mood: "curious"
    property bool ready: false              // Waybar is back, with the margin
    property bool changed: false
    readonly property real screenW: screen ? screen.width : 1920
    readonly property real peekX: screenW - 24   // half in view, already pushing
    readonly property real barEnd: bar ? bar.x + bar.w : 0
    readonly property real gap: bar ? finalX - (barEnd - cut) : 2

    function start(st) {
        if (active) return
        const b = (st.bars || [])[0]
        const conf = st.fromConfig || {}
        bar = b ? b : conf.height ? { x: conf.left, y: conf.top, h: conf.height,
                                      w: screenW - conf.left - conf.right, gx: conf.left, gy: conf.top } : null
        cut = Math.max(0, st.need - (st.right ?? 0))
        ready = false; changed = false
        rx = screenW + 8
        mood = "curious"
        shot.opacity = 1
        active = true
        if (!bar || Style.reducedMotion) { bar = null; edit.running = true; return }
        // the snapshot first, then Waybar restarts underneath it
        grab.command = ["grim", "-g", `${bar.gx},${bar.gy} ${bar.w}x${bar.h}`, room.runDir + "/bar.png"]
        settle.restart()
    }
    // the overlay is mapped (empty) by now; give the compositor's open animation,
    // if any, time to finish before the bar's picture goes on it
    Timer { id: settle; interval: 400; onTriggered: grab.running = true }

    Process {
        id: grab
        onExited: code => {
            if (code !== 0) { room.bar = null; edit.running = true; return }
            img.source = ""
            img.source = "file://" + room.runDir + "/bar.png"
        }
    }
    Process {
        id: edit
        command: [room.helper, "make-room"]
        stdout: StdioCollector {
            onStreamFinished: {
                let r = {}
                try { r = JSON.parse(this.text) } catch (e) {}
                room.changed = !!r.changed
                if (!r.ok) console.warn("visor: making room in Waybar:", r.error || this.text)
                room.ready = true
                if (!room.bar) room.done()
                else if (!show.running && !enter.running) show.start()
            }
        }
    }

    function done() { active = false; img.source = ""; finished(changed) }

    // the robot's moves; the bar's end follows its left side
    SequentialAnimation {
        id: show
        PropertyAction { target: room; property: "mood"; value: "curious" }
        NumberAnimation { target: room; property: "rx"; to: room.peekX; duration: 520; easing.type: Easing.OutCubic }
        PauseAnimation { duration: 380 }
        PropertyAction { target: room; property: "mood"; value: "working" }
        PropertyAction { target: bot; property: "lean"; value: -12 }
        PauseAnimation { duration: 160 }
        // first shove, a bit past halfway, with a little bounce back
        NumberAnimation { target: room; property: "rx"; to: room.peekX - 0.55 * (room.peekX - room.finalX); duration: 340; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
        PauseAnimation { duration: 240 }
        NumberAnimation { target: room; property: "rx"; to: room.finalX; duration: 520; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
        PropertyAction { target: bot; property: "lean"; value: 0 }
        PropertyAction { target: room; property: "mood"; value: "done" }
        SequentialAnimation {   // a happy hop
            NumberAnimation { target: bot; property: "hop"; to: -5; duration: 140; easing.type: Easing.OutQuad }
            NumberAnimation { target: bot; property: "hop"; to: 0; duration: 260; easing.type: Easing.OutBounce }
        }
        // the snapshot gives way to the real bar
        NumberAnimation { target: shot; property: "opacity"; to: 0; duration: 220; easing.type: Easing.OutCubic }
        PauseAnimation { duration: 500 }
        ScriptAction { script: room.done() }
    }
    // tiny pause after the snapshot is up, so nothing flickers
    Timer { id: enter; interval: 80; onTriggered: edit.running = true }

    PanelWindow {
        id: win
        screen: room.screen
        visible: room.active && room.bar !== null
        anchors { top: true; left: true; right: true }
        implicitHeight: room.bar ? Math.max(room.bar.y + room.bar.h, room.finalY + 46) + 8 : 1
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "visor-make-room"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}
        color: "transparent"

        // the bar's snapshot, squeezed from its right end (what's under the
        // squeezed part is the real bar, restarted with the margin)
        Item {
            id: shot
            x: room.bar ? room.bar.x : 0
            y: room.bar ? room.bar.y : 0
            height: room.bar ? room.bar.h : 0
            width: room.bar ? Math.min(room.bar.w, room.rx - room.gap - room.bar.x) : 0
            visible: img.status === Image.Ready
            Image {
                id: img
                anchors.fill: parent
                fillMode: Image.Stretch
                cache: false
                smooth: true
                onStatusChanged: if (status === Image.Ready && room.active && !room.ready) enter.restart()
                         else if (status === Image.Error && room.active) { room.bar = null; edit.running = true }
            }
        }

        Item {
            id: bot
            property real lean: 0
            property real hop: 0
            Behavior on lean { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            x: room.rx
            y: room.finalY + 3 + hop
            width: 52; height: 40
            rotation: lean
            Face {
                anchors.centerIn: parent
                scale: 0.555
                mood: room.mood
                eyeOriginX: room.rx + 26
                eyeOriginY: room.finalY + 23
            }
        }
    }
}
