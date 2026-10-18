import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Effects

// Chat popup that drops down beneath the face. Each tab is a Conversation
// (its own backend and history) and keeps running in the background. This
// window holds the frame, the tab strip, the settings the tabs share, and the
// last conversation for the next start.
PanelWindow {
    id: panel

    property bool open: false
    property string runDir
    property string stateHome
    property string helper
    property var backend: ({})           // chat.py info's backend: name, models, features, mode
    property var cfg: ({})
    property bool hasService: false
    property string serviceLabel: ""
    readonly property string aiName: backend.name || "Assistant"
    readonly property var feat: backend.features || ({})
    property string windowInfo: ""
    property bool shotOk: false
    property int shotSerial: 0
    property bool shareScreen: true
    signal moodRequested(string mood)
    signal sleepRequested()              // stop the service the robot mirrors
    signal needsYou(string text)         // a permission request or question while the popup is closed
    // a transparent layer: only the panel drawn inside is visible; keys go to it while it's open
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "visor-chat"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    // the tabs: one Conversation each, the current one on screen
    property var convs: []
    property var cur: null
    readonly property real tabsH: 30
    readonly property string transcript: cur ? cur.transcript : ""
    readonly property var ask0: cur ? cur.ask0 : null
    readonly property bool asking: cur ? cur.asking : false

    readonly property string shotPath: runDir + "/screen.jpg"
    // Screen off: the AI can't see the screen at all. The snapshot moves to a
    // file it isn't told about (the chip still shows it), and the desktop
    // screenshot tool refuses while runDir/screen-off exists.
    readonly property string hiddenShotPath: runDir + "/screen-hidden.jpg"
    property int shareSerial: 0
    Process {
        id: shareProc
        onExited: panel.shareSerial++
    }
    function applyShare() {
        if (!runDir) return
        shareProc.running = false
        shareProc.command = ["sh", "-c", shareScreen
            ? 'r="$1"; rm -f "$r/screen-off"; [ -e "$r/screen-hidden.jpg" ] && mv -f "$r/screen-hidden.jpg" "$r/screen.jpg"; true'
            : 'r="$1"; mkdir -p "$r"; touch "$r/screen-off"; [ -e "$r/screen.jpg" ] && mv -f "$r/screen.jpg" "$r/screen-hidden.jpg"; true',
            "sh", runDir]
        shareProc.running = true
    }
    onShareScreenChanged: applyShare()
    onShotSerialChanged: if (!shareScreen) applyShare()   // a new snapshot while sharing is off
    onRunDirChanged: applyShare()


    visible: open
    anchors { top: true; right: true }
    // where the panel sits (from the screen's top-right corner); the window
    // starts `room` px further out so the panel's shadow isn't cut off
    property real chatTop: 46
    property real chatRight: 8
    readonly property real room: Style.shadows ? 12 : 0
    margins { top: Math.max(0, chatTop - room); right: Math.max(0, chatRight - room) }
    // The (transparent) window always has the largest allowed size and only
    // the panel drawn inside it changes: resizing never resizes the surface,
    // so there's no compositor round trip per mouse move and no flicker when
    // a drag starts or ends. The mask lets clicks around the panel through.
    property bool resizing: false
    readonly property real maxW: Math.min(1400, (screen ? screen.width : 1920) - 16)
    readonly property real maxH: (screen ? screen.height : 1200) - 70
    implicitWidth: maxW
    implicitHeight: maxH
    // the panel's final place (the frame's entrance animation scales and moves
    // it, and a Region taken mid-animation left the bottom strip unclickable)
    mask: Region { item: hitArea }

    // size (drag the left/bottom edges) and model choice, remembered
    property real panelW: 420
    property real panelH: 560
    function clampW(w) { return Math.max(340, Math.min(maxW, w)) }
    function clampH(h) { return Math.max(380, Math.min(maxH, h)) }

    // drag bookkeeping, in coordinates relative to the window's top-right
    // corner (they stay valid while the window grows/shrinks around them)
    property real dragX: 0
    property real dragY: 0
    property real dragW: 0
    property real dragH: 0
    function cornerPos(item, m) {
        const p = item.mapToItem(null, m.x, m.y)
        return { x: p.x - panel.width, y: p.y }
    }
    function startResize(item, m) {
        const c = cornerPos(item, m)
        dragX = c.x; dragY = c.y; dragW = panelW; dragH = panelH
        resizing = true
    }
    function moveResize(item, m, horiz, vert) {
        const c = cornerPos(item, m)
        if (horiz) panelW = clampW(dragW + dragX - c.x)
        if (vert) panelH = clampH(dragH + c.y - dragY)
    }
    function endResize() {
        resizing = false
        savePrefs()
    }

    // permission mode and pinned state, remembered in chat.json
    readonly property var models: backend.models || []
    // for new chats: chat.model in config.json (each chat can switch on its own)
    readonly property string model: backend.defaultModel || ""
    function setDefaultModel(id) {
        // written to config.json, which comes back through `chat.py info`
        Quickshell.execDetached([helper, "set", "chat.model", JSON.stringify(id)])
    }
    // permission mode (Ask / Edits / Auto / Plan…), when the backend has modes
    readonly property var modes: backend.modes || []
    property string savedMode: ""        // the user's pick
    readonly property string modeId: modes.some(x => x.id === savedMode) ? savedMode : (backend.mode ? backend.mode.id || "" : "")
    readonly property var modeInfo: modes.find(x => x.id === modeId) || backend.mode || null
    // pinned: stays open while you use other windows (clicks outside go through)
    property bool pinned: false
    onPinnedChanged: savePrefs()
    property var saved: null             // the last conversation (survives restarts)

    FileView {
        id: prefs
        path: panel.stateHome ? panel.stateHome + "/chat.json" : ""
        printErrors: false
        blockLoading: true
        Component.onCompleted: reload()
        onLoaded: {
            try {
                const p = JSON.parse(text())
                if (p.w) panel.panelW = panel.clampW(p.w)
                if (p.h) panel.panelH = panel.clampH(p.h)
                if (p.mode) panel.savedMode = p.mode
                panel.pinned = !!p.pinned
                if (p.last && p.last.id) panel.saved = p.last
                if (p.tabs && p.tabs.length) Qt.callLater(panel.restoreTabs, p.tabs, p.cur || 0)
            } catch (e) {}
        }
    }
    function savePrefs() {
        if (restoring) return
        // the current tab's conversation is the one to come back to
        if (cur && cur.sessionId) saved = { id: cur.sessionId, at: cur.lastActive }
        // and the open tabs, to bring back after a restart (busy ones by their relay's key)
        const open = convs.filter(c => c.sessionId || c.busy)
        const tabs = open.map(c => ({ key: c.key, id: c.sessionId, cwd: c.sessionCwd, title: c.sessionTitle,
                                      file: c.transcript, at: c.lastActive, model: c.pickedModel, busy: c.busy }))
        Quickshell.execDetached(["mkdir", "-p", stateHome])
        prefs.setText(JSON.stringify({ w: panelW, h: panelH, mode: savedMode, pinned: pinned, last: saved,
                                       tabs: tabs, cur: Math.max(0, open.indexOf(cur)) }))
    }
    // the tabs that were open last time; each reattaches to its chat if that's still running
    property bool restoring: false
    function restoreTabs(tabs, curIndex) {
        if (convs.length) return
        restoring = true
        for (const t of tabs) {
            const c = addConv()
            if (t.key) c.key = t.key
            c.sessionId = t.id || ""; c.sessionCwd = t.cwd || ""; c.transcript = t.file || ""
            if (t.title) c.sessionTitle = t.title
            c.lastActive = t.at || 0; c.pickedModel = t.model || ""
            if (t.id || t.busy) c.startBridge(t.id, t.cwd, false)
        }
        cur = convs[Math.min(curIndex, convs.length - 1)] || null
        restoring = false
    }

    // tabs ---------------------------------------------------------------
    Component { id: convComp; Conversation {} }
    function addConv() {
        const c = convComp.createObject(frame, { win: panel })
        convs = convs.concat([c])
        return c
    }
    function activate(c) {
        cur = c
        c.unread = false
        c.focusInput()
    }
    function ensure() {
        if (!cur) activate(addConv())
        return cur
    }
    // a new chat in a new tab; an empty tab is reused rather than piling up
    function newTab() {
        if (cur && cur.empty) { cur.focusInput(); return cur }
        saved = null
        const c = addConv()
        activate(c)
        savePrefs()
        return c
    }
    function closeTab(c) {
        if (convs.length === 1) { c.reset(); saved = null; savePrefs(); return }
        const i = convs.indexOf(c)
        convs = convs.filter(x => x !== c)
        if (cur === c) activate(convs[Math.max(0, i - 1)])
        c.close()
        savePrefs()
    }
    // a session from the picker: its tab if it's open, else a new tab
    function openSession(s) {
        const have = convs.find(c => c.sessionId === s.id)
        if (have) { activate(have); savePrefs(); return }
        newTab().pick(s)
    }

    // what the robot's IPC and the shell drive: the current tab
    function newChat() { newTab() }
    function ask(text) { ensure().ask(text) }
    function answer(label) { if (cur) cur.answer(label) }
    function permit(allow, always) { if (cur) cur.permit(allow, always) }
    function skipQuestion() { if (cur) cur.skipQuestion() }
    function showSession(path) { ensure().showSession(path) }

    onOpenChanged: if (open) { ensure().focusInput(); cur.resumeCheck(); enter.restart() }

    Shortcut { sequence: "Ctrl+N"; enabled: panel.open; onActivated: panel.newTab() }
    Shortcut { sequence: "Ctrl+P"; enabled: panel.open; onActivated: panel.pinned = !panel.pinned }

    ParallelAnimation {
        id: enter
        Motion { target: frame; property: "opacity"; from: 0; to: 1 }
        Motion { target: settle; property: "y"; from: -8; to: 0 }
        Motion { target: frame; property: "scale"; from: 0.98; to: 1 }
    }
    Item {
        id: hitArea
        anchors { top: parent.top; right: parent.right
                  topMargin: panel.chatTop - panel.margins.top; rightMargin: panel.chatRight - panel.margins.right }
        width: panel.panelW
        height: panel.panelH
    }
    Item {
        id: frame
        anchors { top: parent.top; right: parent.right
                  topMargin: panel.chatTop - panel.margins.top; rightMargin: panel.chatRight - panel.margins.right }
        width: panel.panelW
        height: panel.panelH
        transformOrigin: Item.TopRight
        transform: Translate { id: settle }

        HoverHandler { id: frameHover }
        Elevation { anchors.fill: parent; lifted: frameHover.hovered }
        Ambient { anchors.fill: parent; running: panel.open }
        Spotlight {}
        Rectangle {   // hairline border, brighter under the cursor
            anchors.fill: parent
            radius: Style.radius
            color: "transparent"
            border.width: 1
            border.color: frameHover.hovered ? Style.panelBorderHi : Style.panelBorder
            Behavior on border.color { ColorMotion { duration: Style.standard } }
        }
        Rectangle {   // light catching the top edge
            anchors { top: parent.top; topMargin: 1; horizontalCenter: parent.horizontalCenter }
            width: parent.width - 2 * Style.radius
            height: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: "#00ffffff" }
                GradientStop { position: 0.5; color: Style.alpha("#ffffff", Style.ambient ? 0.14 : 0) }
                GradientStop { position: 1; color: "#00ffffff" }
            }
        }


    Keys.onEscapePressed: event => {
        if ((event.modifiers & Qt.ShiftModifier) && cur && cur.busy) cur.stop()
        else if (cur && (cur.modelMenuOpen || cur.modeMenuOpen)) { cur.modelMenuOpen = false; cur.modeMenuOpen = false }
        else panel.open = false
    }

    // tab strip: a dot shows a tab is busy, asking, or finished while you were elsewhere
    ListView {
        id: tabRow
        z: 5
        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 6; leftMargin: 10; rightMargin: 8 }
        height: 24
        orientation: ListView.Horizontal
        spacing: 4
        clip: true
        model: panel.convs
        delegate: Rectangle {
            id: tab
            required property var modelData
            readonly property bool current: modelData === panel.cur
            readonly property bool lit: modelData.busy || modelData.unread || modelData.asks.length > 0
            height: 24
            width: Math.min(170, tabTitle.implicitWidth + (lit ? 44 : 30) + (panel.convs.length > 1 ? 14 : 0))
            radius: Style.controlRadius
            color: current ? Style.surfaceHover : tabHover.hovered ? Style.surface : "transparent"
            Behavior on color { ColorMotion {} }

            // tracks the whole tab, including while the pointer is over the ✕ (a sibling MouseArea would steal containsMouse)
            HoverHandler { id: tabHover }

            MouseArea {   // first, so the close button above it still gets its clicks
                id: tabArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { panel.activate(tab.modelData); panel.savePrefs() }
            }
            Rectangle {
                visible: tab.lit
                anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                width: 6; height: 6; radius: 3
                color: tab.modelData.asks.length > 0 ? Style.warn : Style.accent
            }
            Text {
                id: tabTitle
                anchors { left: parent.left; leftMargin: tab.lit ? 22 : 10; right: closeBtn.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
                text: tab.modelData.sessionTitle
                color: tab.current ? Style.fg : Style.muted
                font.family: Style.sans; font.pixelSize: 11
                elide: Text.ElideRight
            }
            Text {
                id: closeBtn
                anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                visible: panel.convs.length > 1 && (tabHover.hovered || tab.current)
                text: "✕"
                color: closeArea.containsMouse ? Style.fg : Style.muted
                font.family: Style.sans; font.pixelSize: 10
                MouseArea {
                    id: closeArea
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.closeTab(tab.modelData)
                }
            }
        }
    }


        // resize: the panel hangs from the top-right corner, so the left and
        // bottom edges (and the corner between them) are the ones to drag
        MouseArea {
            id: gripW
            z: 10
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: 18; bottomMargin: 16 }
            width: 8
            cursorShape: Qt.SizeHorCursor
            onPressed: m => panel.startResize(gripW, m)
            onPositionChanged: m => panel.moveResize(gripW, m, true, false)
            onReleased: panel.endResize()
            onCanceled: panel.endResize()
        }
        MouseArea {
            id: gripH
            z: 10
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 16; rightMargin: 18 }
            height: 8
            cursorShape: Qt.SizeVerCursor
            onPressed: m => panel.startResize(gripH, m)
            onPositionChanged: m => panel.moveResize(gripH, m, false, true)
            onReleased: panel.endResize()
            onCanceled: panel.endResize()
        }
        MouseArea {
            id: gripC
            z: 11
            anchors { left: parent.left; bottom: parent.bottom }
            width: 18; height: 18
            cursorShape: Qt.SizeBDiagCursor
            onPressed: m => panel.startResize(gripC, m)
            onPositionChanged: m => panel.moveResize(gripC, m, true, true)
            onReleased: panel.endResize()
            onCanceled: panel.endResize()
        }
    }
}
