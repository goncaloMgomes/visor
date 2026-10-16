import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls

// Chat popup that drops down beneath the face. Each chat runs through
// `chat.py bridge`, which talks to the configured backend (Claude Code, an
// OpenAI-compatible API, …; see docs/PROTOCOL.md): replies stream in, and
// permission requests and questions are answered here.
PanelWindow {
    id: panel

    property bool open: false
    property string runDir
    property string stateHome
    property string helper
    property var theme: ({})             // colours, fonts, spinner (themes/*.json)
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

    // ⏻ needs a second click within 3 s: stopping the service may end its sessions
    property bool stopArmed: false
    Timer { id: disarm; interval: 3000; onTriggered: panel.stopArmed = false }

    readonly property string shotPath: runDir + "/screen.jpg"

    // current conversation
    property string sessionId: ""        // "" = new chat
    property string sessionCwd: ""
    property string sessionTitle: "New chat"
    property bool forkPending: false     // live elsewhere: first message goes to a copy
    property string transcript: ""       // the chat's transcript (the robot uses it to skip balloons)
    property bool busy: false
    property bool sessionsOpen: false

    // Reopening the popup shows the last conversation again, unless it is
    // gone or nobody touched it for a while.
    readonly property int resumeMinutes: cfg.chat?.resumeMinutes ?? 30
    property real lastActive: 0          // ms; sends and replies
    property var saved: null             // last conversation, from chat.json (survives restarts)
    property string checkId: ""          // conversation being checked on open
    property real checkAt: 0
    property bool deciding: false        // hide the old conversation until the check is done
    property bool historyDone: false     // events after the history are live

    // what the AI is doing right now (its own short summary), for the spinner
    property string activity: ""
    // permission requests and AskUserQuestion questions waiting for an answer
    property var asks: []
    readonly property var ask0: asks.length ? asks[0] : null
    readonly property bool asking: ask0 !== null && ask0.tool === "AskUserQuestion"
    property int qIndex: 0               // question being shown
    property var qAnswers: ({})
    property var qPicked: []             // multi-select choices for the current question

    visible: open
    anchors { top: true; right: true }
    margins { top: 46; right: 8 }
    // The (transparent) window always has the largest allowed size and only
    // the panel drawn inside it changes: resizing never resizes the surface,
    // so there's no compositor round trip per mouse move and no flicker when
    // a drag starts or ends. The mask lets clicks around the panel through.
    property bool resizing: false
    readonly property real maxW: Math.min(1400, (screen ? screen.width : 1920) - 16)
    readonly property real maxH: (screen ? screen.height : 1200) - 70
    implicitWidth: maxW
    implicitHeight: maxH
    mask: Region { item: frame }

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
    property string savedModel: ""           // the user's pick, remembered in chat.json
    readonly property var models: backend.models || []
    // for new / restarted chats: the saved pick if this backend has it, else its default
    readonly property string model: models.some(x => x.id === savedModel) ? savedModel : (backend.defaultModel || "")
    property string currentModel: ""         // what the session actually runs (from the bridge)
    property string currentAlias: ""         // …as one of `models` ("" = unknown)
    property string currentLabel: ""
    property bool modelMenuOpen: false
    readonly property string activeAlias: currentAlias || model
    readonly property string modelLabel: {
        if (currentLabel) return currentLabel
        const k = models.find(x => x.id === model)
        return k ? k.name : model
    }
    function chooseModel(alias) {
        modelMenuOpen = false
        if (alias === activeAlias) return
        savedModel = alias
        currentModel = ""; currentAlias = ""; currentLabel = ""
        savePrefs()
        // switched in place, from the next reply on (no restart)
        if (bridgeUp) command({ op: "model", model: alias })
    }

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
                if (p.model) panel.savedModel = p.model
                if (p.last && p.last.id) panel.saved = p.last
            } catch (e) {}
        }
    }
    function savePrefs() {
        if (sessionId) saved = { id: sessionId, at: lastActive }
        Quickshell.execDetached(["mkdir", "-p", stateHome])
        prefs.setText(JSON.stringify({ w: panelW, h: panelH, model: savedModel, last: saved }))
    }
    function touch() { lastActive = Date.now(); savePrefs() }

    // on open: keep (or bring back) the last conversation, or start fresh
    function resumeCheck() {
        if (wantFile || busy) { refreshSessions(); return }
        const c = sessionId ? { id: sessionId, at: lastActive } : saved
        if (!c || !c.id) { refreshSessions(); return }
        checkId = c.id; checkAt = c.at || 0
        deciding = true
        refreshSessions()
    }
    function finishCheck(list) {
        const id = checkId
        checkId = ""
        deciding = false
        if (busy || asks.length || (sessionId && sessionId !== id)) return
        const s = list.find(x => x.id === id)
        const at = Math.max(checkAt, s ? s.mtime * 1000 : 0)
        if (!s || Date.now() - at > resumeMinutes * 60000) {
            if (sessionId) newChat()
            saved = null
            savePrefs()
        } else if (!sessionId) {
            pick(s, at)
        }
    }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "visor-chat"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    onOpenChanged: {
        if (open) { input.forceActiveFocus(); resumeCheck() }
        else { stopArmed = false; modelMenuOpen = false }
    }

    // palette and fonts from the theme (themes/*.json; "theme" in the config)
    readonly property color bg: theme.bg || "#1d2026"
    readonly property color surface: theme.surface || "#272b33"
    readonly property color raised: theme.raised || "#30353f"
    readonly property color userBubble: theme.userBubble || "#2e343e"
    readonly property color line: theme.line || "#26d6e2f0"
    readonly property color lineHi: theme.lineHi || "#4dd6e2f0"
    readonly property color fg: theme.fg || "#eef2f6"
    readonly property color text2: theme.text2 || "#c3cad4"
    readonly property color dim: theme.dim || "#8a93a1"
    readonly property color accent: theme.accent || "#3fc8e4"
    readonly property color accentHi: theme.accentHi || "#6fd8ee"
    readonly property color accentDim: theme.accentDim || "#25505a"
    readonly property color onAccent: theme.onAccent || "#ffffff"
    readonly property color ok: theme.ok || "#8fca7a"
    readonly property color bad: theme.bad || "#e86f6a"
    readonly property color errorFg: theme.errorFg || "#f2a6a2"
    readonly property string sans: theme.sans || "Noto Sans"
    readonly property string serif: theme.serif || sans   // the welcome line
    readonly property string spark: theme.spark || "✦"
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    function hex(c) { return c.toString().slice(0, 7) }    // for <font color> in rich text

    // spinner while a reply is on its way
    readonly property var spinGlyphs: theme.spinGlyphs || ["·", "•", "●", "•"]
    readonly property var verbs: theme.verbs || ["Thinking"]
    property int spin: 0
    property string verb: "Thinking"
    Timer { running: panel.busy && panel.open; repeat: true; interval: 120; onTriggered: panel.spin = (panel.spin + 1) % panel.spinGlyphs.length }
    onBusyChanged: if (busy) verb = verbs[Math.floor(Math.random() * verbs.length)]

    function toolLabel(t) {   // "Read  ~/x" -> "Read(~/x)"
        const i = t.indexOf("  ")
        return i < 0 ? t : t.substring(0, i) + "(" + t.substring(i + 2) + ")"
    }

    ListModel { id: messages }
    ListModel { id: sessionList }

    // ---------------------------------------------------------------- backend
    function refreshSessions() { sessProc.running = true }

    // select the session whose transcript is `path` once the list is loaded
    property string wantFile: ""
    function showSession(path) { wantFile = path; refreshSessions() }

    Process {
        id: sessProc
        command: [panel.helper, "sessions"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = []
                try { list = JSON.parse(this.text) } catch (e) { return }
                sessionList.clear()
                if (panel.checkId) panel.finishCheck(list)
                for (const s of list) {
                    sessionList.append(s)
                    if (panel.wantFile && s.file === panel.wantFile) {
                        panel.wantFile = ""
                        panel.pick(s)
                    }
                    if (s.id === panel.sessionId) {   // pick up the title the AI gave it
                        panel.sessionTitle = s.title
                        if (!panel.sessionCwd) panel.sessionCwd = s.cwd
                    }
                }
            }
        }
    }

    // the chat's bridge to the AI (chat.py bridge): JSON commands in, JSON events out
    property bool bridgeUp: false
    property bool restarting: false
    property var bridgeCmd: []
    property var queued: []              // commands waiting for the bridge to start
    Process {
        id: bridge
        stdinEnabled: true
        stdout: SplitParser { onRead: line => panel.handleEvent(line) }
        onStarted: {
            panel.bridgeUp = true
            for (const c of panel.queued) write(JSON.stringify(c) + "\n")
            panel.queued = []
        }
        onExited: {
            panel.bridgeUp = false
            if (panel.restarting) { panel.restarting = false; panel.launchBridge(); return }
            if (panel.busy) { panel.busy = false; panel.addRow("error", "The chat stopped unexpectedly.") }
        }
    }
    function command(c) {
        if (bridgeUp) bridge.write(JSON.stringify(c) + "\n")
        else queued.push(c)
    }
    function startBridge(id, cwd, fork) {
        bridgeCmd = [helper, "bridge", id || "new", cwd || "", model, fork ? "1" : "0"]
        queued = []
        if (bridge.running) { restarting = true; bridgeUp = false; bridge.running = false }
        else launchBridge()
    }
    function launchBridge() { bridge.command = bridgeCmd; bridge.running = true }
    function stopBridge() { restarting = false; queued = []; bridgeUp = false; bridge.running = false }

    property var streamRows: ({})        // streamed reply id -> row
    function handleEvent(line) {
        let ev
        try { ev = JSON.parse(line) } catch (e) { return }
        if (historyDone && ["text", "tool", "turn_end"].includes(ev.type)) touch()
        switch (ev.type) {
        case "reset": messages.clear(); streamRows = {}; historyDone = false; break
        case "user": {   // history only: live messages are shown when sent
            const i = echoes.indexOf(norm(ev.text))
            if (i >= 0) echoes.splice(i, 1)
            addRow("user", ev.text)
            break
        }
        case "delta": {   // a reply being written
            const r = streamRows[ev.id]
            if (r === undefined) streamRows[ev.id] = addRow("assistant", ev.text)
            else {
                const stick = view.atYEnd   // follow the reply unless you scrolled up
                messages.setProperty(r, "text", messages.get(r).text + ev.text)
                if (stick) view.positionViewAtEnd()
            }
            activity = ""
            break
        }
        case "text": {
            const r = ev.id ? streamRows[ev.id] : undefined
            if (r === undefined) addRow("assistant", ev.text)
            else messages.setProperty(r, "text", ev.text)
            break
        }
        case "tool": addRow("tool", ev.text, ev); break
        case "model": currentModel = ev.value; currentAlias = ev.alias || ""; currentLabel = ev.label || ev.value; break
        case "activity": activity = ev.text; break
        case "busy":
            // after the history, put back messages sent before the bridge was ready
            if (!historyDone) for (const t of echoes) addRow("user", t)
            busy = ev.value || echoes.length > 0
            historyDone = true
            break
        case "session":
            if (sessionId !== ev.id) { sessionId = ev.id; refreshSessions() }
            transcript = ev.transcript
            forkPending = false
            touch()
            break
        case "permission":
            asks = asks.concat([ev])
            if (asks.length === 1) { qIndex = 0; qAnswers = {}; qPicked = [] }
            if (!open) needsYou(ev.tool === "AskUserQuestion" ? aiName + " has a question for you"
                                                               : aiName + " needs your OK to use " + toolName(ev.tool))
            break
        case "permission_cancel": dropAsk(ev.id); break
        case "error": addRow("error", ev.text); break
        case "interrupted": addRow("error", "Stopped."); break
        case "turn_end":
            if (busy) refreshSessions()
            busy = false
            echoes = []
            activity = ""
            break
        }
    }

    function dropAsk(id) {
        const was = ask0 ? ask0.id : ""
        asks = asks.filter(a => a.id !== id)
        if (was === id) { qIndex = 0; qAnswers = {}; qPicked = [] }
    }
    function permit(allow, always) {
        if (!ask0) return
        command({ op: "permit", id: ask0.id, allow: allow, always: !!always })
        dropAsk(ask0.id)
    }
    // AskUserQuestion: one question at a time; the answers go back together
    function answer(label) {
        const q = ask0.questions[qIndex]
        const a = qAnswers
        a[q.question] = label
        qAnswers = a
        qPicked = []
        if (qIndex + 1 < ask0.questions.length) { qIndex++; return }
        command({ op: "permit", id: ask0.id, allow: true, answers: qAnswers })
        dropAsk(ask0.id)
    }
    function togglePick(label) {
        qPicked = qPicked.includes(label) ? qPicked.filter(x => x !== label) : qPicked.concat([label])
    }
    function skipQuestion() {
        if (!ask0) return
        command({ op: "permit", id: ask0.id, allow: false, message: "The user skipped the question." })
        dropAsk(ask0.id)
    }

    // consecutive tool calls fold into one "Ran 2 commands, read x.png ›" row
    function addRow(role, text, ev) {
        const e = ev || {}
        if (role === "tool") {
            const t = { text: text, name: e.name || "", code: e.code || "", desc: e.desc || "",
                        arg: e.arg || "", add: e.add || 0, del: e.del || 0 }
            const n = messages.count
            if (n && messages.get(n - 1).role === "tools") {
                const items = JSON.parse(messages.get(n - 1).items)
                items.push(t)
                messages.setProperty(n - 1, "items", JSON.stringify(items))
                view.positionViewAtEnd()
                return n - 1
            }
            messages.append({ role: "tools", text: "", items: JSON.stringify([t]) })
        } else {
            messages.append({ role: role, text: text, items: "[]" })
        }
        view.positionViewAtEnd()
        return messages.count - 1
    }

    function baseName(p) { return String(p).replace(/\/+$/, "").split("/").pop() }
    function toolName(n) { return n.replace(/^mcp__desktop__/, "desktop ").replace(/^mcp__(\w+?)__/, "$1 ") }
    function groupSummary(items) {
        let cmds = 0, finds = 0, web = 0, screen = 0, agents = 0, asked = 0, add = 0, del = 0
        const reads = [], edits = [], other = []
        for (const t of items) {
            const n = t.name || t.text.split("  ")[0]
            if (n === "Bash" || n === "PowerShell") cmds++
            else if (n === "Read") reads.push(baseName(t.arg))
            else if (["Edit", "MultiEdit", "Write", "NotebookEdit"].includes(n)) {
                if (!edits.includes(baseName(t.arg))) edits.push(baseName(t.arg))
                add += t.add || 0; del += t.del || 0
            }
            else if (n === "Grep" || n === "Glob") finds++
            else if (n === "WebSearch" || n === "WebFetch") web++
            else if (n.startsWith("mcp__desktop__")) screen++
            else if (n === "Agent" || n === "Task") agents++
            else if (n === "AskUserQuestion") asked++
            else if (!other.includes(toolName(n))) other.push(toolName(n))
        }
        const files = (verb, a) => a.length === 1 ? verb + " " + a[0] : verb + " " + a.length + " files"
        const parts = []
        if (cmds) parts.push("ran " + cmds + (cmds === 1 ? " command" : " commands"))
        if (reads.length) parts.push(files("read", reads))
        if (edits.length) parts.push(files("edited", edits))
        if (finds) parts.push("searched the code")
        if (web) parts.push("searched the web")
        if (screen) parts.push("used the screen")
        if (agents) parts.push(agents === 1 ? "ran an agent" : "ran " + agents + " agents")
        if (asked) parts.push("asked you a question")
        if (other.length) parts.push("used " + other.join(", "))
        const t = parts.join(", ")
        return { text: t.charAt(0).toUpperCase() + t.slice(1), add: add, del: del }
    }

    function send() { ask(input.text) }

    property var echoes: []   // sent messages the bridge's history hasn't shown yet
    function norm(t) { return String(t).replace(/\s+/g, " ").trim() }

    function ask(raw) {
        const text = String(raw).trim()
        if (!text) return
        if (asking) { input.text = ""; answer(text); return }   // a typed answer to the AI's question
        if (busy) return
        input.text = ""
        sessionsOpen = false
        busy = true
        echoes.push(norm(text))
        addRow("user", text)
        touch()
        if (!bridge.running) startBridge(sessionId, sessionCwd, forkPending)
        command({ op: "send", text: text, screenshot: (shareScreen && shotOk) ? shotPath : "", window: windowInfo })
    }

    function stop() { if (busy) command({ op: "stop" }) }

    // carry on in a terminal (backends that have a CLI); replies here then go to a copy
    function continueInTerminal() {
        if (!sessionId || busy || !feat.terminal) return
        termProc.command = [helper, "terminal", sessionId, sessionCwd || Quickshell.env("HOME")]
        termProc.running = true
    }
    Process {
        id: termProc
        stdout: StdioCollector {
            onStreamFinished: {
                let argv = []
                try { argv = JSON.parse(this.text) } catch (e) {}
                if (!argv.length) return
                panel.stopBridge()
                // chat.terminal from the config, else xdg-terminal-exec, else $TERMINAL -e
                const term = panel.cfg.chat?.terminal ?? []
                const cwd = panel.sessionCwd || Quickshell.env("HOME")
                const run = ["sh", "-c", 'cd "$1" 2>/dev/null; shift; exec "$@"', "sh", cwd].concat(argv)
                if (term.length) Quickshell.execDetached(term.concat(run))
                else Quickshell.execDetached(["sh", "-c",
                    'if command -v xdg-terminal-exec >/dev/null; then exec xdg-terminal-exec "$@"; '
                    + 'else exec "${TERMINAL:-xterm}" -e "$@"; fi', "sh"].concat(run))
                panel.forkPending = true
                panel.open = false
            }
        }
    }

    function newChat() {
        if (busy) return
        stopBridge()
        sessionId = ""; sessionCwd = ""; sessionTitle = "New chat"; forkPending = false
        transcript = ""; currentModel = ""; currentAlias = ""; currentLabel = ""; activity = ""
        lastActive = 0; echoes = []; asks = []
        saved = null; savePrefs()
        messages.clear()
        sessionsOpen = false
        input.forceActiveFocus()
    }

    function pick(s, at) {
        if (busy) return
        sessionsOpen = false
        if (s.id === sessionId) return
        sessionId = s.id; sessionCwd = s.cwd; sessionTitle = s.title; transcript = s.file
        currentModel = ""; currentAlias = ""; currentLabel = ""; activity = ""; echoes = []; asks = []
        lastActive = at || Date.now()
        savePrefs()
        forkPending = s.live && !s.owned
        busy = false
        startBridge(s.id, s.cwd, forkPending)   // shows its history; the AI starts on the first message
        input.forceActiveFocus()
    }

    function segments(text) {   // split a reply into markdown and ``` code blocks
        const out = []
        const re = /^[ \t]*```([\w+#.-]*)[^\n]*\n([\s\S]*?)^[ \t]*```[ \t]*$/gm
        let last = 0, m
        while ((m = re.exec(text)) !== null) {
            const before = text.substring(last, m.index).trim()
            if (before) out.push({ code: false, lang: "", text: before })
            out.push({ code: true, lang: m[1] || "", text: m[2].replace(/\n$/, "") })
            last = re.lastIndex
        }
        const rest = text.substring(last).trim()
        if (rest || out.length === 0) out.push({ code: false, lang: "", text: rest })
        return out
    }
    function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

    function ago(t) {
        const s = Date.now() / 1000 - t
        if (s < 3600) return Math.max(1, Math.round(s / 60)) + " min"
        if (s < 86400) return Math.round(s / 3600) + " h"
        return Math.round(s / 86400) + " d"
    }

    // ---------------------------------------------------------------- UI
    component IconButton: Rectangle {
        id: btn
        property string glyph
        property string tip
        property bool alert: false
        signal clicked()
        width: 28; height: 28; radius: 8
        color: alert ? panel.alpha(panel.bad, 0.7) : hover.containsMouse ? panel.surface : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }
        Text {
            anchors.centerIn: parent
            text: btn.glyph
            color: btn.alert || hover.containsMouse ? panel.fg : panel.dim
            font.family: panel.sans; font.pixelSize: 15
        }
        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
        Tip { visible: hover.containsMouse && btn.tip !== ""; text: btn.tip }
    }

    Rectangle {
        id: frame
        anchors { top: parent.top; right: parent.right }
        width: panel.panelW
        height: panel.panelH
        radius: 18
        color: panel.bg
        border.width: 1
        border.color: panel.line

        Keys.onEscapePressed: { if (panel.modelMenuOpen) panel.modelMenuOpen = false; else panel.open = false }

        // header: spark, session title (opens the picker), actions
        Item {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 8; leftMargin: 10; rightMargin: 8 }
            height: 40

            Rectangle {
                id: picker
                anchors { left: parent.left; right: buttons.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                height: 38; radius: 10
                color: pickHover.containsMouse || panel.sessionsOpen ? panel.surface : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                    id: spark
                    anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    text: panel.spark
                    color: panel.accent
                    font.pixelSize: 20
                }
                Column {
                    anchors { left: spark.right; leftMargin: 8; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    spacing: 1
                    Row {
                        width: parent.width
                        spacing: 4
                        Text {
                            width: Math.min(implicitWidth, parent.width - 14)
                            text: panel.sessionTitle
                            color: panel.fg
                            font.family: panel.sans; font.pixelSize: 13; font.weight: Font.Medium
                            elide: Text.ElideRight
                        }
                        Text {
                            text: panel.sessionsOpen ? "⌃" : "⌄"
                            color: panel.dim
                            font.pixelSize: 11
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Text {
                        width: parent.width
                        visible: text !== ""
                        text: panel.forkPending ? "Open elsewhere · your reply continues in a copy" : ""
                        color: panel.dim
                        font.family: panel.sans; font.pixelSize: 10
                        elide: Text.ElideRight
                    }
                }
                MouseArea {
                    id: pickHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { panel.sessionsOpen = !panel.sessionsOpen; if (panel.sessionsOpen) panel.refreshSessions() }
                }
            }

            Row {
                id: buttons
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 0
                IconButton { glyph: "✎"; tip: "New chat"; onClicked: panel.newChat() }
                IconButton {
                    visible: panel.sessionId !== "" && !!panel.feat.terminal
                    glyph: "↗"
                    tip: panel.backend.terminalLabel || "Continue in a terminal"
                    onClicked: panel.continueInTerminal()
                }
                IconButton {
                    visible: panel.hasService
                    glyph: "⏻"
                    alert: panel.stopArmed
                    tip: panel.stopArmed ? "Click again to stop " + panel.serviceLabel
                                         : "Put the robot to sleep (stop " + panel.serviceLabel + ")"
                    onClicked: {
                        if (panel.stopArmed) { panel.stopArmed = false; panel.sleepRequested() }
                        else { panel.stopArmed = true; disarm.restart() }
                    }
                }
                IconButton { glyph: "✕"; tip: "Close (Esc)"; onClicked: panel.open = false }
            }
        }

        Rectangle {
            id: rule
            anchors { top: header.bottom; topMargin: 6; left: parent.left; right: parent.right }
            height: 1
            color: panel.line
        }

        // conversation
        ListView {
            id: view
            anchors { top: rule.bottom; left: parent.left; right: parent.right; bottom: askCard.visible ? askCard.top : composer.top
                      topMargin: 10; leftMargin: 14; rightMargin: 10; bottomMargin: 8 }
            clip: true
            spacing: 12
            model: messages
            opacity: panel.deciding ? 0 : 1
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            onCountChanged: positionViewAtEnd()

            // mouse wheel notches start a flick, so they use the same physics as a
            // drag (no fighting with the built-in wheel); touchpads keep their own scrolling
            readonly property real wheelFlick: 1400   // px/s per wheel notch
            WheelHandler {
                acceptedDevices: PointerDevice.Mouse
                onWheel: event => {
                    event.accepted = true
                    if (event.angleDelta.y !== 0) view.flick(0, event.angleDelta.y / 120 * view.wheelFlick)
                }
            }

            // replies arrive a message at a time: a spinner in the meantime
            footer: Item {
                width: view.width
                height: panel.busy ? 30 : 0
                Row {
                    visible: panel.busy
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    spacing: 7
                    Text {
                        width: 14
                        horizontalAlignment: Text.AlignHCenter
                        text: panel.spinGlyphs[panel.spin]
                        color: panel.accent
                        font.pixelSize: 15
                    }
                    Text {   // the AI's own summary of what it's doing, else a spinner verb
                        width: Math.min(implicitWidth, parent.width - 140)
                        text: (panel.ask0 ? "Waiting for you" : panel.activity || panel.verb) + "…"
                        color: panel.accent
                        font.family: panel.sans; font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        visible: !panel.ask0
                        text: "(esc to interrupt)"
                        color: panel.dim
                        font.family: panel.sans; font.pixelSize: 11
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            delegate: Item {
                id: row
                required property string role
                required property string text
                required property string items
                readonly property bool mine: role === "user"
                readonly property var tools: role === "tools" ? JSON.parse(items) : []
                readonly property var summary: role === "tools" ? panel.groupSummary(tools) : null
                property bool open: false   // tool groups stay folded until clicked
                width: view.width - 8
                height: role === "tools" ? toolCol.height : role === "assistant" ? replyCol.height : bubble.height

                // your messages and errors: a bubble
                Rectangle {
                    id: bubble
                    visible: row.mine || row.role === "error"
                    anchors.right: row.mine ? parent.right : undefined
                    width: row.mine ? Math.min(body.implicitWidth + 28, row.width * 0.86) : row.width
                    height: body.height + (row.mine ? 18 : 14)
                    radius: 12
                    color: row.mine ? panel.userBubble : panel.alpha(panel.bad, 0.18)
                    TextEdit {
                        id: body
                        x: row.mine ? 14 : 10
                        y: row.mine ? 9 : 7
                        width: row.mine ? row.width * 0.86 - 28 : row.width - 20
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        textFormat: TextEdit.PlainText
                        text: bubble.visible ? row.text : ""
                        color: row.mine ? panel.fg : panel.errorFg
                        font.family: panel.sans; font.pixelSize: 14
                        selectionColor: panel.alpha(panel.accent, 0.4)
                        selectedTextColor: panel.fg
                    }
                }

                // tool calls, folded: "Ran 2 commands, edited x  +4 -1 ›";
                // open, each call is a ⏺ Name(arg) line, commands in a code block
                Column {
                    id: toolCol
                    visible: row.role === "tools"
                    width: row.width
                    spacing: 6
                    Item {
                        width: parent.width
                        height: Math.max(sumText.height, 18)
                        Row {
                            id: sumRow
                            spacing: 6
                            width: parent.width
                            Text {
                                id: sumText
                                width: Math.min(implicitWidth, sumRow.width - diffBadge.width - chev.width - 14)
                                text: row.summary ? row.summary.text : ""
                                color: sumArea.containsMouse ? panel.text2 : panel.dim
                                font.family: panel.sans; font.pixelSize: 13
                                wrapMode: Text.Wrap
                            }
                            Rectangle {
                                id: diffBadge
                                visible: row.summary && (row.summary.add || row.summary.del)
                                width: visible ? diffRow.implicitWidth + 8 : 0
                                height: 16; radius: 4
                                y: 1
                                color: panel.alpha(panel.ok, 0.12)
                                Row {
                                    id: diffRow
                                    anchors.centerIn: parent
                                    spacing: 3
                                    Text {
                                        text: row.summary ? "+" + row.summary.add : ""
                                        color: panel.ok
                                        font.family: "monospace"; font.pixelSize: 10
                                    }
                                    Text {
                                        text: row.summary ? "-" + row.summary.del : ""
                                        color: panel.bad
                                        font.family: "monospace"; font.pixelSize: 10
                                    }
                                }
                            }
                            Text {
                                id: chev
                                text: row.open ? "⌄" : "›"
                                color: panel.dim
                                font.family: panel.sans; font.pixelSize: 13
                            }
                        }
                        MouseArea {
                            id: sumArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: row.open = !row.open
                        }
                    }
                    Repeater {
                        model: row.open ? row.tools : []
                        delegate: Column {
                            id: call
                            required property var modelData
                            property bool expanded: false   // commands stay folded until clicked
                            width: toolCol.width
                            spacing: 5
                            Item {
                                width: parent.width
                                height: toolLine.height
                                Text {   // tool bullet
                                    x: 4; y: 3
                                    text: "⏺"
                                    color: panel.ok
                                    font.pixelSize: 10
                                }
                                Text {
                                    id: toolLine
                                    x: 20
                                    width: parent.width - 20
                                    wrapMode: Text.Wrap
                                    textFormat: Text.StyledText
                                    readonly property var t: call.modelData
                                    text: !t.name ? panel.esc(panel.toolLabel(t.text))
                                        : "<b>" + panel.esc(panel.toolName(t.name)) + "</b>"
                                          + (t.code ? (t.desc ? "  <font color=\"" + panel.hex(panel.dim) + "\">" + panel.esc(t.desc) + "</font>" : "")
                                             : t.arg ? "<font color=\"" + panel.hex(panel.dim) + "\">(" + panel.esc(t.arg) + ")</font>" : "")
                                          + (t.code ? "  <font color=\"" + panel.hex(panel.dim) + "\">" + (call.expanded ? "▾" : "▸") + "</font>" : "")
                                    color: panel.text2
                                    font.family: panel.sans; font.pixelSize: 12
                                }
                                // click the line to show or hide its command
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: call.modelData.code !== ""
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: call.expanded = !call.expanded
                                }
                            }
                            CodeBlock {
                                visible: call.modelData.code !== "" && call.expanded
                                x: 20
                                width: parent.width - 20
                                code: call.modelData.code
                                lang: "bash"
                                maxLines: 6
                            }
                        }
                    }
                }

                // the AI's reply: markdown, with ``` blocks as code blocks
                Column {
                    id: replyCol
                    visible: row.role === "assistant"
                    width: row.width
                    spacing: 8
                    Repeater {
                        model: replyCol.visible ? panel.segments(row.text) : []
                        delegate: Item {
                            id: seg
                            required property var modelData
                            width: replyCol.width
                            height: modelData.code ? block.height : md.height
                            TextEdit {
                                id: md
                                visible: !seg.modelData.code
                                width: parent.width
                                readOnly: true
                                selectByMouse: true
                                wrapMode: TextEdit.Wrap
                                textFormat: TextEdit.MarkdownText
                                text: seg.modelData.code ? "" : seg.modelData.text
                                color: panel.fg
                                font.family: panel.sans; font.pixelSize: 14
                                selectionColor: panel.alpha(panel.accent, 0.4)
                                selectedTextColor: panel.fg
                            }
                            CodeBlock {
                                id: block
                                visible: seg.modelData.code
                                width: parent.width
                                code: seg.modelData.code ? seg.modelData.text : ""
                                lang: seg.modelData.lang
                            }
                        }
                    }
                }
            }

            // empty state
            Column {
                anchors.centerIn: parent
                visible: messages.count === 0 && !panel.busy && !panel.deciding
                width: parent.width - 40
                spacing: 10
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: panel.spark
                    color: panel.accent
                    font.pixelSize: 34
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: panel.backend.available === false ? panel.aiName + " isn't set up yet"
                                                            : (panel.theme.welcome || "How can I help?")
                    color: panel.fg
                    font.family: panel.serif; font.pixelSize: 21
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: panel.backend.available === false ? "Run `visor doctor` in a terminal to see what's missing."
                        : panel.shotOk && panel.shareScreen ? "I can see what you were doing on screen."
                        : "Ask me anything."
                    color: panel.dim
                    font.family: panel.sans; font.pixelSize: 12
                }
            }
        }

        // session picker ("Recents")
        Rectangle {
            visible: panel.sessionsOpen
            anchors { top: rule.bottom; left: parent.left; right: parent.right; bottom: composer.top; margins: 8 }
            radius: 12
            color: panel.bg
            border.width: 1
            border.color: panel.line

            Text {
                id: recents
                x: 12; y: 10
                text: "Recents"
                color: panel.dim
                font.family: panel.sans; font.pixelSize: 11; font.weight: Font.Medium
            }

            ListView {
                anchors { top: recents.bottom; topMargin: 6; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 4 }
                clip: true
                spacing: 1
                model: sessionList
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                delegate: Rectangle {
                    id: srow
                    required property var model
                    readonly property bool current: srow.model.id === panel.sessionId
                    width: ListView.view.width
                    height: 44
                    radius: 9
                    color: sHover.containsMouse || current ? panel.surface : "transparent"
                    Rectangle {   // current chat marker
                        visible: srow.current
                        x: 0; anchors.verticalCenter: parent.verticalCenter
                        width: 3; height: 18; radius: 1.5
                        color: panel.accent
                    }
                    Column {
                        anchors { left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        spacing: 2
                        Text {
                            width: parent.width
                            text: srow.model.title
                            color: panel.fg
                            font.family: panel.sans; font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                        Row {
                            spacing: 6
                            Text {
                                text: srow.model.cwd.replace(/^\/home\/[^/]+/, "~") + " · " + panel.ago(srow.model.mtime)
                                color: panel.dim
                                font.family: panel.sans; font.pixelSize: 10
                            }
                            Text {
                                visible: srow.model.owned || srow.model.live
                                text: srow.model.owned ? panel.spark + " robot" : "● live"
                                color: panel.accent
                                font.family: panel.sans; font.pixelSize: 10
                            }
                        }
                    }
                    MouseArea {
                        id: sHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.pick(srow.model)
                    }
                }
            }
        }

        // a permission request or a question from the AI, above the composer
        Rectangle {
            id: askCard
            visible: panel.ask0 !== null
            anchors { left: parent.left; right: parent.right; bottom: composer.top; leftMargin: 10; rightMargin: 10; bottomMargin: 6 }
            height: askCol.implicitHeight + 24
            radius: 14
            color: panel.surface
            border.width: 1
            border.color: panel.alpha(panel.accent, 0.4)

            readonly property var q: panel.asking ? panel.ask0.questions[panel.qIndex] : null

            Column {
                id: askCol
                x: 12; y: 12
                width: parent.width - 24
                spacing: 8

                // --- permission
                Text {
                    visible: !panel.asking
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.StyledText
                    text: !panel.ask0 || panel.asking ? ""
                        : "Allow <b>" + panel.esc(panel.ask0.title || panel.toolName(panel.ask0.tool)) + "</b>?"
                    color: panel.fg
                    font.family: panel.sans; font.pixelSize: 13
                }
                Text {
                    visible: !panel.asking && text !== ""
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: panel.ask0 && !panel.asking ? (panel.ask0.desc || (panel.ask0.code ? "" : panel.ask0.arg || "")) : ""
                    color: panel.text2
                    font.family: panel.sans; font.pixelSize: 12
                }
                CodeBlock {
                    visible: panel.ask0 !== null && !panel.asking && panel.ask0.code !== ""
                    width: parent.width
                    code: visible ? panel.ask0.code : ""
                    lang: "bash"
                    maxLines: 6
                }
                Row {
                    visible: !panel.asking
                    spacing: 6
                    AskButton { label: "Allow"; primary: true; onClicked: panel.permit(true, false) }
                    AskButton { visible: panel.ask0 !== null && panel.ask0.always; label: "Always allow"; onClicked: panel.permit(true, true) }
                    AskButton { label: "Deny"; onClicked: panel.permit(false, false) }
                }

                // --- AskUserQuestion
                Row {
                    visible: panel.asking
                    spacing: 8
                    Rectangle {
                        visible: askCard.q !== null && !!askCard.q.header
                        height: 18; radius: 5
                        width: hdr.implicitWidth + 12
                        color: panel.alpha(panel.accent, 0.2)
                        Text {
                            id: hdr
                            anchors.centerIn: parent
                            text: askCard.q ? (askCard.q.header || "") : ""
                            color: panel.accentHi
                            font.family: panel.sans; font.pixelSize: 10; font.weight: Font.Medium
                        }
                    }
                    Text {
                        visible: panel.asking && panel.ask0.questions.length > 1
                        text: panel.asking ? (panel.qIndex + 1) + " of " + panel.ask0.questions.length : ""
                        color: panel.dim
                        font.family: panel.sans; font.pixelSize: 10
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                Text {
                    visible: panel.asking
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: askCard.q ? askCard.q.question : ""
                    color: panel.fg
                    font.family: panel.sans; font.pixelSize: 13; font.weight: Font.Medium
                }
                Repeater {
                    model: askCard.q ? askCard.q.options : []
                    delegate: Rectangle {
                        id: opt
                        required property var modelData
                        required property int index
                        readonly property bool picked: panel.qPicked.includes(modelData.label)
                        width: askCol.width
                        height: optCol.implicitHeight + 14
                        radius: 9
                        color: optArea.containsMouse || picked ? panel.raised : "transparent"
                        border.width: 1
                        border.color: picked ? panel.accent : panel.line
                        Column {
                            id: optCol
                            x: 10; y: 7
                            width: parent.width - 20
                            spacing: 2
                            Text {
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: (opt.index + 1) + ". " + opt.modelData.label
                                color: panel.fg
                                font.family: panel.sans; font.pixelSize: 13
                            }
                            Text {
                                visible: !!opt.modelData.description
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: opt.modelData.description || ""
                                color: panel.dim
                                font.family: panel.sans; font.pixelSize: 11
                            }
                        }
                        MouseArea {
                            id: optArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: askCard.q.multiSelect ? panel.togglePick(opt.modelData.label) : panel.answer(opt.modelData.label)
                        }
                    }
                }
                Row {
                    visible: panel.asking
                    spacing: 6
                    AskButton {
                        visible: askCard.q !== null && !!askCard.q.multiSelect
                        label: "Next"; primary: true
                        onClicked: if (panel.qPicked.length) panel.answer(panel.qPicked.join(", "))
                    }
                    AskButton { label: "Skip"; onClicked: panel.skipQuestion() }
                    Text {
                        text: "or type your own answer below"
                        color: panel.dim
                        font.family: panel.sans; font.pixelSize: 11
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }

        // composer: a text box with the send button, and
        // the session's controls (screen, permission mode, model) underneath
        Item {
            id: composer
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 10; bottomMargin: 8 }
            height: box.height + 4 + controls.height

            Rectangle {
                id: box
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: Math.min(170, Math.max(36, input.implicitHeight) + 12)
                radius: 14
                color: panel.surface
                border.width: 1
                border.color: input.activeFocus ? panel.lineHi : panel.line
                Behavior on border.color { ColorAnimation { duration: 150 } }

                ScrollView {
                    anchors { top: parent.top; left: parent.left; right: sendBtn.left; bottom: parent.bottom
                              topMargin: 4; bottomMargin: 4; leftMargin: 6; rightMargin: 4 }
                    TextArea {
                        id: input
                        placeholderText: panel.asking ? "Type your own answer…"
                                       : panel.busy ? panel.aiName + " is replying…"
                                       : messages.count === 0 ? (panel.theme.welcome || "How can I help?") : "Reply to " + panel.aiName + "…"
                        placeholderTextColor: panel.dim
                        color: panel.fg
                        font.family: panel.sans; font.pixelSize: 14
                        wrapMode: TextArea.Wrap
                        selectionColor: panel.alpha(panel.accent, 0.4)
                        background: null
                        Keys.onReturnPressed: event => {
                            if (event.modifiers & Qt.ShiftModifier) event.accepted = false
                            else panel.send()
                        }
                        Keys.onEscapePressed: event => {
                            if (panel.modelMenuOpen) panel.modelMenuOpen = false
                            else if (panel.busy) panel.stop()
                            else panel.open = false
                        }
                    }
                }

                Rectangle {
                    id: sendBtn
                    readonly property bool ready: panel.busy || input.text.trim() !== ""
                    // while the AI waits on a question, a typed answer is sent instead of stopping
                    readonly property bool stopping: panel.busy && !(panel.asking && input.text.trim() !== "")
                    // centred beside one line of text, kept at the bottom when it grows
                    anchors.right: parent.right
                    anchors.rightMargin: (box.height - height) / 2 > 10 ? 8 : (box.height - height) / 2
                    y: input.lineCount <= 1 ? (box.height - height) / 2 : box.height - height - 8
                    width: 28; height: 28; radius: 8
                    color: !ready ? panel.accentDim : sendHover.containsMouse ? panel.accentHi : panel.accent
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        visible: !sendBtn.stopping
                        anchors.centerIn: parent
                        text: "↑"
                        color: sendBtn.ready ? panel.onAccent : panel.alpha(panel.onAccent, 0.5)
                        font.family: panel.sans; font.pixelSize: 16; font.bold: true
                    }
                    Rectangle {   // stop: a drawn square, the ■ glyph sits off-centre
                        visible: sendBtn.stopping
                        anchors.centerIn: parent
                        width: 10; height: 10; radius: 2
                        color: panel.onAccent
                    }
                    MouseArea {
                        id: sendHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: sendBtn.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: sendBtn.stopping ? panel.stop() : panel.send()
                    }
                }
            }

            Item {
                id: controls
                anchors { top: box.bottom; topMargin: 4; left: parent.left; right: parent.right; leftMargin: 2 }
                height: 28

                Row {
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    spacing: 2

                    Rectangle {   // permission mode (when the backend has one)
                        visible: !!panel.backend.mode
                        height: 26; radius: 7
                        width: modeText.implicitWidth + 14
                        color: modeArea.containsMouse ? panel.surface : "transparent"
                        Text {
                            id: modeText
                            anchors.centerIn: parent
                            text: panel.backend.mode ? panel.backend.mode.label : ""
                            color: panel.text2
                            font.family: panel.sans; font.pixelSize: 12
                        }
                        MouseArea { id: modeArea; anchors.fill: parent; hoverEnabled: true }
                        Tip { visible: modeArea.containsMouse && !!panel.backend.mode; text: panel.backend.mode ? panel.backend.mode.tip : "" }
                    }

                    // screenshot chip: what the AI will see; click to stop sharing
                    Rectangle {
                        id: chip
                        visible: panel.shotOk
                        height: 26; radius: 7
                        width: chipRow.implicitWidth + 14
                        color: chipHover.containsMouse ? panel.surface : "transparent"
                        Row {
                            id: chipRow
                            anchors.centerIn: parent
                            spacing: 6
                            Rectangle {
                                width: 26; height: 16; radius: 3
                                color: "#000000"
                                clip: true
                                anchors.verticalCenter: parent.verticalCenter
                                Image {
                                    anchors.fill: parent
                                    source: panel.shotOk ? "file://" + panel.shotPath + "?" + panel.shotSerial : ""
                                    cache: false
                                    asynchronous: true
                                    fillMode: Image.PreserveAspectCrop
                                    opacity: panel.shareScreen ? 1 : 0.25
                                }
                            }
                            Text {
                                text: panel.shareScreen ? "Screen" : "Screen off"
                                color: panel.shareScreen ? panel.text2 : panel.dim
                                font.family: panel.sans; font.pixelSize: 12
                                font.strikeout: !panel.shareScreen
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        MouseArea {
                            id: chipHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panel.shareScreen = !panel.shareScreen
                        }
                        Tip {
                            visible: chipHover.containsMouse
                            text: panel.shareScreen ? panel.aiName + " can see this screenshot (click to stop sharing)"
                                                    : "Screenshot not shared (click to share)"
                        }
                    }
                }

                Rectangle {   // model picker
                    id: modelBtn
                    visible: panel.models.length > 0
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    height: 26; radius: 7
                    width: modelRow.implicitWidth + 14
                    color: modelArea.containsMouse || panel.modelMenuOpen ? panel.surface : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Row {
                        id: modelRow
                        anchors.centerIn: parent
                        spacing: 4
                        Text {
                            text: panel.modelLabel
                            color: modelArea.containsMouse || panel.modelMenuOpen ? panel.fg : panel.text2
                            font.family: panel.sans; font.pixelSize: 12
                        }
                        Text {
                            text: "⌄"
                            color: panel.dim
                            font.pixelSize: 10
                        }
                    }
                    MouseArea {
                        id: modelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: panel.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: if (!panel.busy && panel.models.length > 1) panel.modelMenuOpen = !panel.modelMenuOpen
                    }
                    Tip { visible: modelArea.containsMouse && panel.busy; text: "Change the model once " + panel.aiName + " has finished" }
                }
            }
        }

        // model menu, opening upward from the composer
        Rectangle {
            id: modelMenu
            visible: panel.modelMenuOpen
            z: 5
            anchors { bottom: composer.bottom; bottomMargin: 32; right: composer.right }
            width: 250
            height: menuCol.implicitHeight + 12
            radius: 12
            color: panel.surface
            border.width: 1
            border.color: panel.lineHi
            Column {
                id: menuCol
                x: 6; y: 6
                width: parent.width - 12
                Repeater {
                    model: panel.models
                    delegate: Rectangle {
                        id: mrow
                        required property var modelData
                        readonly property bool current: modelData.id === panel.activeAlias
                        width: menuCol.width
                        height: 46
                        radius: 8
                        color: mArea.containsMouse ? panel.raised : "transparent"
                        Column {
                            anchors { left: parent.left; leftMargin: 10; right: check.left; verticalCenter: parent.verticalCenter }
                            spacing: 2
                            Text {
                                text: mrow.modelData.name
                                color: panel.fg
                                font.family: panel.sans; font.pixelSize: 13
                            }
                            Text {
                                width: parent.width
                                visible: text !== ""
                                text: mrow.modelData.blurb || ""
                                color: panel.dim
                                font.family: panel.sans; font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            id: check
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            text: mrow.current ? "✓" : ""
                            color: panel.accent
                            font.pixelSize: 14
                        }
                        MouseArea {
                            id: mArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panel.chooseModel(mrow.modelData.id)
                        }
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
