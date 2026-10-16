import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

// Cartoon speech bubble that pops out under the robot, above the windows, and
// types its message out like someone writing it. say(text, {ms, action})
// queues a message; one shows at a time. opts.onShow runs when it appears. While `suppressed` (chat open,
// fullscreen, locked) messages wait in the queue. A newer message doesn't open
// a second bubble: the open one rubs its text out and writes the new one.
// Chit-chat waits its turn behind a message about a session (has an action).
PanelWindow {
    id: balloon

    property bool suppressed: false
    property bool muted: false               // speech balloons switched off (right-click menu)
    onMutedChanged: if (muted) { queue = []; incoming = null; if (current) dismiss() }
    property var queue: []
    property var current: null
    property var incoming: null                 // replaces `current` once its text is rubbed out
    readonly property bool erasing: incoming !== null
    property int typed: 0                       // characters revealed so far
    readonly property bool typing: current !== null && typed < full.length
    readonly property string full: current ? current.text : ""
    signal activated(var item)

    readonly property color paper: "#f7fcff"
    readonly property color ink: "#1d2b36"

    visible: current !== null
    anchors { top: true; right: true }
    margins { top: 36; right: 4 }
    // spare room around the card for the pop-in bounce (it scales past 1),
    // otherwise the window clips the bubble's edges while it pops
    readonly property real bounce: 0.12
    readonly property real roomL: Math.ceil(card.width * bounce) + 4
    readonly property real roomB: Math.ceil(card.height * bounce) + 10
    implicitWidth: card.width + roomL + 4
    implicitHeight: card.height + roomB + 4
    mask: Region { item: card }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "visor-balloon"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // how long a finished message stays up, relative to the `ms` asked for
    readonly property real holdScale: 0.45
    readonly property real typeSpeed: 1.5   // 1 = the original pace

    function say(text, opts) {
        const o = opts || {}
        if (muted) { if (o.onShow) o.onShow(); return }   // the face still reacts
        const item = { text: text, ms: o.ms || 6000, action: o.action || null, onShow: o.onShow || null, t: Date.now() }
        // a bubble is up and staying up: write the news into it, unless that
        // would wipe a session message with mere chit-chat
        const live = current && !suppressed && !popOut.running
        const busy = incoming || current
        if (live && !(busy.action && !item.action)) {
            if (incoming && incoming.action && !item.action) queue.unshift(incoming)
            swapTo(item)
            return
        }
        queue.push(item)
        if (!current) next()
    }

    function fresh() {
        // chit-chat held back (fullscreen, chat open, locked) goes stale: only
        // messages about sessions (they have an action) wait longer than 30 s
        const now = Date.now()
        queue = queue.filter(q => q.action || now - q.t < 30000)
    }

    // start rubbing out the open bubble's text; typeTimer then writes `item`
    function swapTo(item) {
        hideTimer.stop()
        incoming = item
        if (item.onShow) item.onShow()   // the face reacts right away
        typeTimer.interval = 16
        typeTimer.restart()
    }

    function next() {
        fresh()
        if (suppressed || queue.length === 0) return
        typed = 0
        current = queue.shift()
        if (current.onShow) current.onShow()
        hideTimer.stop()
        popIn.restart()
        typeTimer.interval = 380   // a beat after the pop before writing starts
        typeTimer.restart()
    }

    function dismiss() {
        if (incoming) { queue.unshift(incoming); incoming = null }
        hideTimer.stop()
        typeTimer.stop()
        popOut.restart()
    }

    onSuppressedChanged: {
        if (suppressed && current) {   // put it back and show it later
            queue.unshift(incoming || current)
            incoming = null
            popIn.stop(); swapPop.stop(); popOut.stop(); typeTimer.stop(); hideTimer.stop()
            current = null
        } else if (!suppressed && !current) {
            next()
        }
    }

    // Human-ish typing: ~23 ms a letter with some jitter, a little longer
    // after spaces, and real pauses after punctuation (all divided by typeSpeed).
    Timer {
        id: typeTimer
        onTriggered: {
            if (!balloon.current) return
            if (balloon.erasing) {
                // rub out from the end in ~20 quick steps, never splitting an emoji
                let n = Math.max(0, balloon.typed - Math.max(1, Math.ceil(balloon.current.text.length / 20)))
                while (n > 0 && /[\udc00-\udfff️‍]/.test(balloon.full[n])) n--
                balloon.typed = n
                if (n > 0) { interval = 16; restart(); return }
                // empty: the bubble takes the new message's size with a little bob
                balloon.current = balloon.incoming
                balloon.incoming = null
                swapPop.restart()
                interval = 220
                restart()
                return
            }
            let n = balloon.typed + 1
            // never stop half-way through an emoji (surrogate pair, variation
            // selector, zero-width joiner)
            while (n < balloon.full.length && /[\udc00-\udfff\ufe0f\u200d]/.test(balloon.full[n])) n++
            balloon.typed = n
            if (balloon.typed >= balloon.full.length) {
                hideTimer.interval = balloon.current.ms * balloon.holdScale
                hideTimer.restart()
                return
            }
            const c = balloon.full[balloon.typed - 1]
            let ms = 20 + Math.random() * 28
            if (c === " ") ms += 15
            else if (c === "," || c === ";" || c === ":") ms += 110
            else if (c === "." || c === "!" || c === "?" || c === "…") ms += 230
            interval = Math.round(ms / balloon.typeSpeed)
            restart()
        }
    }

    Timer {
        id: hideTimer
        onTriggered: {
            if (hover.containsMouse) { restart(); return }
            balloon.fresh()
            // more waiting: write it into this bubble instead of a new one
            if (balloon.queue.length > 0 && !balloon.suppressed) balloon.swapTo(balloon.queue.shift())
            else balloon.dismiss()
        }
    }

    SequentialAnimation {
        id: swapPop
        NumberAnimation { target: card; property: "pop"; to: 0.94; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation { target: card; property: "pop"; to: 1; duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.7 }
    }

    SequentialAnimation {
        id: popIn
        PropertyAction { target: card; property: "opacity"; value: 0 }
        PropertyAction { target: card; property: "pop"; value: 0.4 }
        ParallelAnimation {
            NumberAnimation { target: card; property: "opacity"; to: 1; duration: 140 }
            // overshoot 1.7 peaks at ~1.1x, inside the window's bounce room
            NumberAnimation { target: card; property: "pop"; to: 1; duration: 420; easing.type: Easing.OutBack; easing.overshoot: 1.7 }
        }
    }
    SequentialAnimation {
        id: popOut
        ParallelAnimation {
            NumberAnimation { target: card; property: "opacity"; to: 0; duration: 180 }
            NumberAnimation { target: card; property: "pop"; to: 0.8; duration: 180; easing.type: Easing.InBack }
        }
        ScriptAction { script: { balloon.current = null; balloon.next() } }
    }

    function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

    // `card` is the bubble plus room around it: the effect layer below renders
    // only inside card's box, so the tail, the rounded ends, the heavier pen
    // stroke and the shadow all need space inside it or they get clipped.
    Item {
        id: card
        x: balloon.roomL
        y: 4
        width: bw + 2 * sideRoom
        height: bh + tailRoom + sideRoom
        // grow out of the tail's tip (right under the robot), so the bubble
        // stays put against the screen's right edge while it bounces
        property real pop: 1
        transform: Scale {
            origin.x: card.sideRoom + card.tipX
            origin.y: 0
            xScale: card.pop
            yScale: card.pop
        }

        readonly property real sideRoom: 6     // left/right/bottom room
        readonly property real tailRoom: 22     // room for the tail
        readonly property real padX: 18
        readonly property real padY: 11
        // the bubble itself
        readonly property real bw: Math.min(300, Math.max(120, measure.implicitWidth + 2 * padX))
        readonly property real bh: Math.max(40, words.implicitHeight + 2 * padY)
        readonly property real r: Math.min(bh / 2, 24)
        readonly property real a: bw - r       // where the right end starts curving
        readonly property real tipX: bw - 26   // the robot's centre, in bubble coordinates

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#55000000"
            shadowBlur: 0.45
            shadowVerticalOffset: 3
            shadowHorizontalOffset: -1
        }

        Item {
            id: bubble
            x: card.sideRoom
            y: card.tailRoom
            width: card.bw
            height: card.bh

            Shape {
                x: -1.1; y: 1.1
                width: bubble.width; height: bubble.height
                preferredRendererType: Shape.CurveRenderer
                BubblePath {
                    h: card.bh; rr: card.r; aa: card.a; tip: card.tipX
                    fillColor: "transparent"; strokeColor: balloon.ink; strokeWidth: 3
                }
            }
            Shape {
                width: bubble.width; height: bubble.height
                preferredRendererType: Shape.CurveRenderer
                BubblePath {
                    h: card.bh; rr: card.r; aa: card.a; tip: card.tipX
                    fillColor: balloon.paper; strokeColor: balloon.ink; strokeWidth: 2.4
                }
            }
        }

        // sizes the bubble for the whole message so it doesn't grow while typing
        Text {
            id: measure
            visible: false
            text: balloon.full
            font: words.font
        }

        Text {
            id: words
            x: card.sideRoom + card.padX
            y: card.tailRoom + card.padY
            width: card.bw - 2 * card.padX
            wrapMode: Text.Wrap
            color: balloon.ink
            font.pixelSize: 13
            lineHeight: 1.1
            // the unwritten rest is laid out invisibly so lines never re-wrap
            textFormat: Text.StyledText
            text: balloon.esc(balloon.full.substring(0, balloon.typed))
                  + "<font color=\"#00000000\">" + balloon.esc(balloon.full.substring(balloon.typed)) + "</font>"
        }

        MouseArea {
            id: hover
            anchors.fill: bubble
            hoverEnabled: true
            cursorShape: balloon.current && balloon.current.action ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
                if (balloon.erasing) return
                if (balloon.typing) { balloon.typed = balloon.full.length; typeTimer.stop(); hideTimer.interval = balloon.current.ms * balloon.holdScale; hideTimer.restart(); return }
                const item = balloon.current
                balloon.dismiss()
                if (item && item.action) balloon.activated(item)
            }
        }
    }
}
