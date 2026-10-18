import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import QtQuick.Effects

// One conversation in the chat popup (a tab): its own backend process
// (`chat.py bridge`, see docs/PROTOCOL.md), history and permission prompts.
// Tabs keep running when you switch to another one; ChatPanel.qml holds the
// window, the tabs and the settings they share.
Item {
    id: panel

    required property var win            // the ChatPanel window
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; top: parent.top; topMargin: win.tabsH }
    visible: win.cur === panel

    // the window's settings, read from it
    readonly property bool open: win.open
    readonly property string runDir: win.runDir
    readonly property string stateHome: win.stateHome
    readonly property string helper: win.helper
    readonly property var backend: win.backend
    readonly property var cfg: win.cfg
    readonly property bool hasService: win.hasService
    readonly property string serviceLabel: win.serviceLabel
    readonly property string aiName: win.aiName
    readonly property var feat: win.feat
    readonly property string windowInfo: win.windowInfo
    readonly property bool shotOk: win.shotOk
    readonly property int shotSerial: win.shotSerial
    readonly property bool shareScreen: win.shareScreen
    readonly property string shotPath: win.shotPath
    readonly property string hiddenShotPath: win.hiddenShotPath
    readonly property bool pinned: win.pinned
    readonly property var models: win.models
    property string pickedModel: ""          // this chat's own pick ("" = the default)
    readonly property string defaultModel: win.model
    readonly property string model: models.some(x => x.id === pickedModel) ? pickedModel : defaultModel
    readonly property var modes: win.modes
    readonly property string modeId: win.modeId
    readonly property var modeInfo: win.modeInfo
    readonly property string savedMode: win.savedMode

    property bool unread: false          // finished while another tab was on screen
    readonly property bool empty: !sessionId && !busy && messages.count === 0
    function focusInput() { input.forceActiveFocus() }
    function savePrefs() { win.savePrefs() }

    onOpenChanged: if (!open) { stopArmed = false; modelMenuOpen = false; modeMenuOpen = false }

    // ⏻ needs a second click within 3 s: stopping the service may end its sessions
    property bool stopArmed: false
    Timer { id: disarm; interval: 3000; onTriggered: panel.stopArmed = false }
    // current conversation
    property string sessionId: ""        // "" = new chat
    property string sessionCwd: ""
    property string sessionTitle: "New chat"
    property bool forkPending: false     // live elsewhere: first message goes to a copy
    property string transcript: ""       // the chat's transcript (the robot uses it to skip balloons)
    property bool busy: false
    property bool sessionsOpen: false

    // images pasted into the composer (file paths), sent with the next message
    property var attachments: []
    readonly property bool canAttach: !!feat.images
    // messages sent while the AI is replying, until it reads them ({ text, images });
    // they join the conversation then (the backend's "consumed" event)
    property var queue: []
    readonly property bool canQueue: !!feat.queue
    function fileUrl(p) { return "file://" + String(p).split("/").map(encodeURIComponent).join("/") }

    // Reopening the popup shows the last conversation again, unless it is
    // gone or nobody touched it for a while.
    readonly property int resumeMinutes: cfg.chat?.resumeMinutes ?? 30
    property real lastActive: 0          // ms; sends and replies
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

    property string currentModel: ""         // what the session actually runs (from the bridge)
    property string currentAlias: ""         // …as one of `models` ("" = unknown)
    property string currentLabel: ""
    property bool modelMenuOpen: false
    property bool modeMenuOpen: false
    function chooseMode(id) {
        modeMenuOpen = false
        if (id === modeId) return
        win.savedMode = id
        savePrefs()
        // takes effect right away, also in the middle of a reply
        if (bridgeUp) command({ op: "mode", mode: id })
    }
    readonly property string activeAlias: currentAlias || model
    readonly property string modelLabel: {
        if (currentLabel) return currentLabel
        const k = models.find(x => x.id === model)
        return k ? k.name : model
    }
    function chooseModel(alias) {
        modelMenuOpen = false
        if (alias === activeAlias) return
        pickedModel = alias
        currentModel = ""; currentAlias = ""; currentLabel = ""
        // switched in place, from the next reply on (no restart)
        if (bridgeUp) command({ op: "model", model: alias })
    }

    function touch() { lastActive = Date.now(); savePrefs() }

    // on open: keep (or bring back) the last conversation, or start fresh
    function resumeCheck() {
        if (wantFile || busy) { refreshSessions(); return }
        const c = sessionId ? { id: sessionId, at: lastActive } : win.saved
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
            if (sessionId) reset()
            win.saved = null
            savePrefs()
        } else if (!sessionId) {
            pick(s, at)
        }
    }

    // colours, type, radii and motion: Style.qml (the theme's tokens)

    property int spin: 0
    property string verb: "Thinking"
    Timer { running: panel.busy && panel.open; repeat: true; interval: 120; onTriggered: panel.spin = (panel.spin + 1) % Style.spinGlyphs.length }
    onBusyChanged: if (busy) verb = Style.verbs[Math.floor(Math.random() * Style.verbs.length)]

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

    // the chat's bridge to the AI (chat.py bridge): JSON commands in, JSON events out.
    // It runs under a relay outside the robot (chat.py attach, backend/relay.py), so
    // a reload doesn't end a reply: the tab comes back by its key and is replayed.
    property string key: newKey()
    function newKey() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 8) }
    property bool bridgeUp: false
    property bool restarting: false
    property bool replaying: false       // the relay is replaying the chat so far
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
            panel.replaying = false
            quitWait.stop()
            if (panel.restarting) { panel.restarting = false; panel.launchBridge(); return }
            if (panel.busy) { panel.busy = false; panel.addRow("error", "The chat stopped unexpectedly.") }
            panel.unqueue()
        }
    }
    // after a quit the attach process ends by itself; don't wait on it forever
    Timer { id: quitWait; interval: 2500; onTriggered: bridge.running = false }
    function quitBridge() {
        if (!bridge.running) return false
        if (bridgeUp) { bridge.write(JSON.stringify({ op: "quit" }) + "\n"); quitWait.restart() }
        else bridge.running = false
        bridgeUp = false
        key = newKey()   // the old relay is on its way out
        return true
    }
    function command(c) {
        if (bridgeUp) bridge.write(JSON.stringify(c) + "\n")
        else queued.push(c)
    }
    function startBridge(id, cwd, fork) {
        queued = []
        restarting = quitBridge()
        bridgeCmd = [helper, "attach", key, id || "new", cwd || "", model, fork ? "1" : "0", modeId]
        if (!restarting) launchBridge()
        savePrefs()
    }
    function launchBridge() { bridge.command = bridgeCmd; bridge.running = true }
    function stopBridge() { restarting = false; queued = []; quitBridge() }
    // closing the tab: give the quit a moment to reach the relay before going away
    function close() { stopBridge(); closeLater.start() }
    Timer { id: closeLater; interval: 1500; onTriggered: panel.destroy() }

    property var streamRows: ({})        // streamed reply id -> row
    function handleEvent(line) {
        let ev
        try { ev = JSON.parse(line) } catch (e) { return }
        if (historyDone && !replaying && ["text", "tool", "turn_end"].includes(ev.type)) touch()
        switch (ev.type) {
        case "replay": replaying = ev.value; break
        case "reset": messages.clear(); streamRows = {}; historyDone = false; view.follow = true; break
        case "user": {   // history only: live messages are shown when sent
            const i = echoes.indexOf(norm(ev.text))
            if (i >= 0) echoes.splice(i, 1)
            addRow("user", ev.text, { images: Array(ev.images || 0).fill("") })   // history has no image files
            break
        }
        case "consumed": {   // the AI read a message sent during its reply
            if (!queue.length) break
            const q = queue[0]
            queue = queue.slice(1)
            echoes.push(norm(q.text))
            addRow("user", q.text, { images: q.images })
            break
        }
        case "delta": {   // a reply being written
            const r = streamRows[ev.id]
            if (r === undefined) streamRows[ev.id] = addRow("assistant", ev.text)
            else {
                messages.setProperty(r, "text", messages.get(r).text + ev.text)
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
            if (!open) win.needsYou(ev.tool === "AskUserQuestion" ? aiName + " has a question for you"
                                                               : aiName + " needs your OK to use " + toolName(ev.tool))
            break
        case "permission_cancel": dropAsk(ev.id); break
        case "error": addRow("error", ev.text); break
        case "interrupted": addRow("error", "Stopped."); break
        case "turn_end":
            if (busy) refreshSessions()
            busy = false
            if (win.cur !== panel && !replaying) unread = true
            echoes = []
            activity = ""
            unqueue()
            break
        }
    }

    // queued messages the AI never read go back into the composer
    function unqueue() {
        if (!queue.length) return
        const texts = queue.map(q => q.text).filter(t => t)
        if (input.text.trim()) texts.push(input.text)
        input.text = texts.join("\n\n")
        attachments = queue.reduce((a, q) => a.concat(q.images), []).concat(attachments)
        queue = []
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
                return n - 1
            }
            messages.append({ role: "tools", text: "", items: JSON.stringify([t]), images: "[]" })
        } else {
            if (role === "user") view.follow = true   // sending brings you back down
            messages.append({ role: role, text: text, items: "[]", images: JSON.stringify(e.images || []) })
        }
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
        const images = attachments
        if (asking) {   // a typed answer to the AI's question
            if (text) { input.text = ""; answer(text) }
            return
        }
        if (!text && !images.length) return
        // mid-reply: the AI reads it at its next step (backends with feat.queue)
        const queued = busy
        if (queued && !canQueue) return
        input.text = ""
        attachments = []
        sessionsOpen = false
        if (queued) queue = queue.concat([{ text: text, images: images }])
        else {
            busy = true
            echoes.push(norm(text))
            addRow("user", text, { images: images })
        }
        touch()
        if (!bridge.running) startBridge(sessionId, sessionCwd, forkPending)
        command({ op: "send", text: text, images: images, queued: queued,
                  screenshot: (shareScreen && shotOk) ? shotPath : "", window: windowInfo })
    }

    // Ctrl+V: an image on the clipboard (or image files copied in a file
    // manager) is attached; anything else is pasted as text as usual
    Process {
        id: pasteProc
        stdout: StdioCollector {
            onStreamFinished: {
                // a saved clipboard image's path, or the copied files' URIs
                const files = []
                for (let l of this.text.split("\n")) {
                    l = l.trim()
                    if (l.startsWith("file://")) l = decodeURIComponent(l.slice(7))
                    if (l.startsWith("/") && /\.(png|jpe?g|gif|webp|bmp|tiff?)$/i.test(l)) files.push(l)
                }
                if (files.length) panel.attachments = panel.attachments.concat(files)
                else input.paste()
            }
        }
    }
    function pasteImage() {
        pasteProc.running = false
        pasteProc.command = ["bash", "-c", [
            'd="$1/paste"; mkdir -p "$d"',
            'types=$(wl-paste --list-types 2>/dev/null) || exit 0',
            // text copied from office apps also carries a picture of it: text wins
            "if ! grep -q '^text/plain' <<<\"$types\" && m=$(grep -m1 '^image/' <<<\"$types\"); then",
            '    ext=${m#image/}; ext=${ext%%[;+]*}',
            '    f="$d/paste-$(date +%s%N).${ext:-png}"',
            '    wl-paste --no-newline --type "$m" >"$f" && [ -s "$f" ] && echo "$f"',
            "elif grep -qx 'text/uri-list' <<<\"$types\"; then",
            '    wl-paste --no-newline --type text/uri-list',
            'fi'].join("\n"), "bash", runDir]
        pasteProc.running = true
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
                win.open = false
            }
        }
    }

    // clear this tab's chat (it stays a tab; the window decides what to show)
    function reset() {
        stopBridge()
        sessionId = ""; sessionCwd = ""; sessionTitle = "New chat"; forkPending = false
        transcript = ""; currentModel = ""; currentAlias = ""; currentLabel = ""; activity = ""
        pickedModel = ""; lastActive = 0; echoes = []; asks = []; queue = []; busy = false; unread = false
        messages.clear()
        sessionsOpen = false
    }

    function pick(s, at) {
        if (busy) return
        sessionsOpen = false
        if (s.id === sessionId) return
        sessionId = s.id; sessionCwd = s.cwd; sessionTitle = s.title; transcript = s.file
        currentModel = ""; currentAlias = ""; currentLabel = ""; activity = ""; echoes = []; asks = []; queue = []
        pickedModel = ""; lastActive = at || Date.now()
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
        property bool on: false
        property string icon: ""         // an SVG path on a 24×24 grid, drawn instead of the glyph
        property real iconRotation: 0
        readonly property color fg: on ? Style.accent : alert || hover.containsMouse ? Style.fg : Style.muted
        signal clicked()
        width: 28; height: 28; radius: Style.controlRadius
        color: alert ? Style.alpha(Style.bad, 0.7) : hover.containsMouse || on ? Style.surface : "transparent"
        Behavior on color { ColorMotion {} }
        scale: hover.pressed ? 0.98 : 1
        Behavior on scale { Motion { duration: Style.quick } }
        Accessible.role: Accessible.Button
        Accessible.name: tip
        Shape {
            visible: btn.icon !== ""
            anchors.centerIn: parent
            width: 24; height: 24
            scale: 0.68
            rotation: btn.iconRotation
            Behavior on rotation { Motion { duration: Style.quick } }
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                fillColor: btn.fg
                Behavior on fillColor { ColorMotion {} }
                PathSvg { path: btn.icon }
            }
        }
        Text {
            visible: btn.icon === ""
            anchors.centerIn: parent
            text: btn.glyph
            color: btn.fg
            Behavior on color { ColorMotion {} }
            font.family: Style.sans; font.pixelSize: 15
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


        // a click anywhere else in the panel closes the model / mode menu
        MouseArea {
            z: 4
            anchors.fill: parent
            visible: panel.modelMenuOpen || panel.modeMenuOpen
            onClicked: { panel.modelMenuOpen = false; panel.modeMenuOpen = false }
        }
        // …and so does clicking another window (while pinned)
        readonly property bool winActive: Window.active
        onWinActiveChanged: if (!winActive) { panel.modelMenuOpen = false; panel.modeMenuOpen = false }

        // header: spark, session title (opens the picker), actions
        Item {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 8; leftMargin: 10; rightMargin: 8 }
            height: 40

            Rectangle {
                id: picker
                anchors { left: parent.left; right: buttons.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                height: 38; radius: Style.controlRadius + 2
                color: pickHover.containsMouse || panel.sessionsOpen ? Style.surface : "transparent"
                Behavior on color { ColorMotion {} }

                Text {   // the spark, glowing softly
                    id: spark
                    anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    text: Style.spark
                    color: Style.accent
                    font.pixelSize: 18
                    layer.enabled: Style.shadows
                    layer.effect: MultiEffect { shadowEnabled: true; shadowColor: Style.accent; shadowBlur: 0.6; shadowOpacity: 0.8; shadowVerticalOffset: 0; shadowHorizontalOffset: 0 }
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
                            color: Style.fg
                            font.family: Style.sans; font.pixelSize: 13; font.weight: Font.DemiBold; font.letterSpacing: -0.2
                            elide: Text.ElideRight
                        }
                        Text {
                            text: panel.sessionsOpen ? "⌃" : "⌄"
                            color: Style.muted
                            font.pixelSize: 11
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Text {
                        width: parent.width
                        visible: text !== ""
                        text: panel.forkPending ? "Open elsewhere · your reply continues in a copy" : ""
                        color: Style.muted
                        font.family: Style.sans; font.pixelSize: 10
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
                IconButton {   // a speech bubble with a plus: a new conversation
                    icon: "M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H5.17L4 17.17V4h16v12zm-7-9h-2v3H8v2h3v3h2v-3h3v-2h-3V7z"
                    tip: "New chat (Ctrl+N)"
                    onClicked: win.newTab()
                }
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
                        if (panel.stopArmed) { panel.stopArmed = false; win.sleepRequested() }
                        else { panel.stopArmed = true; disarm.restart() }
                    }
                }
                IconButton {
                    on: panel.pinned
                    // a pushpin: tilted and hollow when off, upright and filled when pinned
                    icon: panel.pinned
                        ? "M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
                        : "M14 4v5c0 1.12.37 2.16 1 3H9c.65-.86 1-1.9 1-3V4h4m3-2H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3V4h1c.55 0 1-.45 1-1s-.45-1-1-1z"
                    iconRotation: panel.pinned ? 0 : 45
                    tip: panel.pinned ? "Pinned: stays open over other windows (Ctrl+P)" : "Keep open while using other windows (Ctrl+P)"
                    onClicked: win.pinned = !win.pinned
                }
                IconButton { glyph: "✕"; tip: "Close (Esc)"; onClicked: win.open = false }
            }
        }

        Rectangle {   // a gradient hairline under the header
            id: rule
            anchors { top: header.bottom; topMargin: 6; left: parent.left; right: parent.right }
            height: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Style.alpha(Style.lineHi, 0) }
                GradientStop { position: 0.5; color: Style.lineHi }
                GradientStop { position: 1; color: Style.alpha(Style.lineHi, 0) }
            }
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
            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                onPressedChanged: view.follow = pressed ? false : view.atYEnd
            }
            // Stay at the bottom while anything grows (new rows, streamed text,
            // rows whose height is only known after layout, the spinner footer),
            // unless you scrolled up; scrolling back to the end follows again.
            property bool follow: true
            function stick() { if (follow && !moving && !dragging) positionViewAtEnd() }
            onMovementStarted: follow = false
            onMovementEnded: follow = atYEnd
            onCountChanged: Qt.callLater(stick)
            onContentHeightChanged: Qt.callLater(stick)
            onHeightChanged: Qt.callLater(stick)
            // new messages fade up 8 px (history loads without animating)
            // New rows fade in by themselves (see the delegate). Not with the
            // view's add transition: an interrupted one left a reply stuck at
            // opacity 0 (there, but invisible), and animating y left rows
            // overlapping when a row above grew.

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
                    id: statusRow
                    visible: panel.busy
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    spacing: 7
                    Text {
                        width: 14
                        horizontalAlignment: Text.AlignHCenter
                        text: Style.spinGlyphs[panel.spin]
                        color: Style.accent
                        font.pixelSize: 15
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    // the AI's own summary of what it's doing, else a verb, with a shimmer
                    readonly property string status: (panel.ask0 ? "Waiting for you" : panel.activity || panel.verb) + "…"
                    readonly property bool fits: statusMetrics.advanceWidth < parent.width - 150
                    TextMetrics { id: statusMetrics; font: statusFont.font; text: statusRow.status }
                    Text { id: statusFont; visible: false; font.family: Style.sans; font.pixelSize: 13; font.weight: Font.Medium }
                    GlowText {
                        visible: parent.fits
                        anchors.verticalCenter: parent.verticalCenter
                        text: parent.status
                        font: statusFont.font
                        shimmer: true
                        color: Style.accent
                    }
                    Text {   // long summaries: plain, elided
                        visible: !parent.fits
                        width: parent.width - 150
                        text: parent.status
                        color: Style.accent
                        font: statusFont.font
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Caption {
                        visible: !panel.ask0
                        text: "shift+esc to stop"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            delegate: Item {
                id: row
                required property int index
                required property string role
                required property string text
                required property string items
                required property string images
                // a row that just arrived fades in; its own animation, which
                // nothing else can interrupt, and always ends fully visible
                NumberAnimation on opacity {
                    id: fadeIn
                    running: false
                    from: 0; to: 1
                    duration: Style.standard
                    easing.type: Easing.BezierSpline; easing.bezierCurve: Style.expoOut
                    onStopped: row.opacity = 1
                }
                Component.onCompleted: if (panel.historyDone && !Style.reducedMotion && index === messages.count - 1) fadeIn.start()
                readonly property bool mine: role === "user"
                readonly property var pics: mine ? JSON.parse(images || "[]") : []   // paths; "" = from history
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
                    width: row.mine ? Math.min(Math.max(body.visible ? body.implicitWidth : 0, picFlow.visible ? picFlow.width : 0) + 28,
                                               row.width * 0.86) : row.width
                    height: (body.visible ? body.y + body.height : picFlow.y + picFlow.height) + (row.mine ? 9 : 7)
                    radius: Style.radius - 2
                    gradient: Gradient {
                        GradientStop { position: 0; color: row.mine ? Style.cardTop : Style.alpha(Style.bad, 0.16) }
                        GradientStop { position: 1; color: row.mine ? Style.cardBottom : Style.alpha(Style.bad, 0.08) }
                    }
                    border.width: 1
                    border.color: row.mine ? Style.line : Style.alpha(Style.bad, 0.3)
                    Rectangle {   // lit top edge
                        anchors { top: parent.top; topMargin: 1; horizontalCenter: parent.horizontalCenter }
                        width: parent.width - 2 * parent.radius
                        height: 1
                        color: Style.alpha("#ffffff", Style.ambient ? 0.08 : 0)
                    }
                    // pasted images: click one to open it
                    Flow {
                        id: picFlow
                        visible: row.pics.length > 0
                        x: 14; y: 9
                        width: Math.min(row.width * 0.86 - 28, row.pics.length * 126 - 6)
                        height: visible ? implicitHeight : 0
                        spacing: 6
                        Repeater {
                            model: row.pics
                            Rectangle {
                                required property string modelData
                                width: 120; height: 80
                                radius: 8
                                clip: true
                                color: Style.surface
                                border.width: 1
                                border.color: Style.line
                                Image {
                                    visible: parent.modelData !== ""
                                    anchors { fill: parent; margins: 1 }
                                    source: parent.modelData ? panel.fileUrl(parent.modelData) : ""
                                    sourceSize.height: 160
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                                Text {   // from the history: the image itself isn't kept
                                    visible: parent.modelData === ""
                                    anchors.centerIn: parent
                                    text: "Image"
                                    color: Style.muted
                                    font.family: Style.sans; font.pixelSize: 12
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: parent.modelData !== ""
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: Quickshell.execDetached(["xdg-open", parent.modelData])
                                }
                            }
                        }
                    }
                    TextEdit {
                        id: body
                        visible: row.text !== "" || !row.mine
                        x: row.mine ? 14 : 10
                        y: picFlow.visible ? picFlow.y + picFlow.height + 6 : row.mine ? 9 : 7
                        width: row.mine ? row.width * 0.86 - 28 : row.width - 20
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        textFormat: TextEdit.PlainText
                        text: bubble.visible ? row.text : ""
                        color: row.mine ? Style.fg : Style.errorFg
                        font.family: Style.sans; font.pixelSize: 14
                        selectionColor: Style.alpha(Style.accent, 0.4)
                        selectedTextColor: Style.fg
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
                                color: sumArea.containsMouse ? Style.subtle : Style.muted
                                font.family: Style.sans; font.pixelSize: 13
                                wrapMode: Text.Wrap
                            }
                            Rectangle {
                                id: diffBadge
                                visible: row.summary && (row.summary.add || row.summary.del)
                                width: visible ? diffRow.implicitWidth + 8 : 0
                                height: 16; radius: 4
                                y: 1
                                color: Style.alpha(Style.ok, 0.12)
                                Row {
                                    id: diffRow
                                    anchors.centerIn: parent
                                    spacing: 3
                                    Text {
                                        text: row.summary ? "+" + row.summary.add : ""
                                        color: Style.ok
                                        font.family: "monospace"; font.pixelSize: 10
                                    }
                                    Text {
                                        text: row.summary ? "-" + row.summary.del : ""
                                        color: Style.bad
                                        font.family: "monospace"; font.pixelSize: 10
                                    }
                                }
                            }
                            Text {
                                id: chev
                                text: row.open ? "⌄" : "›"
                                color: Style.muted
                                font.family: Style.sans; font.pixelSize: 13
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
                                    color: Style.ok
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
                                          + (t.code ? (t.desc ? "  <font color=\"" + Style.hex(Style.muted) + "\">" + panel.esc(t.desc) + "</font>" : "")
                                             : t.arg ? "<font color=\"" + Style.hex(Style.muted) + "\">(" + panel.esc(t.arg) + ")</font>" : "")
                                          + (t.code ? "  <font color=\"" + Style.hex(Style.muted) + "\">" + (call.expanded ? "▾" : "▸") + "</font>" : "")
                                    color: Style.subtle
                                    font.family: Style.sans; font.pixelSize: 12
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
                                color: Style.fg
                                font.family: Style.sans; font.pixelSize: 14
                                selectionColor: Style.alpha(Style.accent, 0.4)
                                selectedTextColor: Style.fg
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
                spacing: 12
                Item {   // the spark in a glowing icon container
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 52; height: 52
                    Elevation { anchors.fill: parent; radius: 12; glow: true; depth: 0.6 }
                    Rectangle {
                        anchors.fill: parent
                        radius: 12
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.tint(Style.bgElevated, Style.surfaceHover) }
                            GradientStop { position: 1; color: Style.bgElevated }
                        }
                        border.width: 1
                        border.color: Style.lineHi
                    }
                    Text {
                        anchors.centerIn: parent
                        text: Style.spark
                        color: Style.accent
                        font.pixelSize: 24
                    }
                }
                Caption {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: panel.aiName
                }
                Text { id: headFont; visible: false; font.family: Style.serif; font.pixelSize: 22; font.weight: Font.DemiBold; font.letterSpacing: -0.6 }
                Item {
                    width: parent.width
                    height: headline.implicitHeight
                    readonly property string text: panel.backend.available === false ? panel.aiName + " isn't set up yet" : Style.welcome
                    GlowText {
                        id: headline
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: parent.text
                        font: headFont.font
                    }
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: panel.backend.available === false ? "Run `visor doctor` in a terminal to see what's missing."
                        : panel.shotOk && panel.shareScreen ? "I can look at your screen if I need to."
                        : "Ask me anything."
                    color: Style.muted
                    font.family: Style.sans; font.pixelSize: 13
                    lineHeight: 1.4
                }
            }
        }

        // session picker ("Recents")
        Item {
            visible: panel.sessionsOpen
            anchors { top: rule.bottom; left: parent.left; right: parent.right; bottom: composer.top; margins: 8 }
            z: 4
            Elevation { anchors.fill: parent; radius: Style.radius - 4 }
            Rectangle {
                anchors.fill: parent
                radius: Style.radius - 4
                color: Style.bgElevated
                border.width: 1
                border.color: Style.lineHi
            }
            Caption {
                id: recents
                x: 14; y: 12
                text: "Recents"
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
                    height: 46
                    radius: Style.controlRadius
                    color: sHover.containsMouse || current ? Style.surface : "transparent"
                    Behavior on color { ColorMotion {} }
                    Rectangle {   // current chat marker
                        visible: srow.current
                        x: 0; anchors.verticalCenter: parent.verticalCenter
                        width: 3; height: 18; radius: 1.5
                        color: Style.accent
                    }
                    Column {
                        anchors { left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        spacing: 2
                        Text {
                            width: parent.width
                            text: srow.model.title
                            color: Style.fg
                            font.family: Style.sans; font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                        Row {
                            spacing: 6
                            Text {
                                text: srow.model.cwd.replace(/^\/home\/[^/]+/, "~") + " · " + panel.ago(srow.model.mtime)
                                color: Style.muted
                                font.family: Style.sans; font.pixelSize: 10
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Rectangle {   // pill
                                visible: srow.model.owned || srow.model.live
                                height: 15; radius: 7.5
                                width: pill.implicitWidth + 12
                                color: Style.alpha(Style.accent, 0.1)
                                border.width: 1
                                border.color: Style.lineAccent
                                anchors.verticalCenter: parent.verticalCenter
                                Caption {
                                    id: pill
                                    anchors.centerIn: parent
                                    text: srow.model.owned ? "robot" : "live"
                                    color: Style.accentHi
                                    font.pixelSize: 8
                                }
                            }
                        }
                    }
                    MouseArea {
                        id: sHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.openSession(srow.model)
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
            radius: Style.radius
            gradient: Gradient {
                GradientStop { position: 0; color: Style.cardTop }
                GradientStop { position: 1; color: Style.cardBottom }
            }
            border.width: 1
            border.color: Style.lineAccent
            Spotlight { radius: askCard.radius }

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
                    color: Style.fg
                    font.family: Style.sans; font.pixelSize: 13
                }
                Text {
                    visible: !panel.asking && text !== ""
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: panel.ask0 && !panel.asking ? (panel.ask0.desc || (panel.ask0.code ? "" : panel.ask0.arg || "")) : ""
                    color: Style.subtle
                    font.family: Style.sans; font.pixelSize: 12
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
                        height: 18; radius: 9
                        width: hdr.implicitWidth + 14
                        color: Style.alpha(Style.accent, 0.1)
                        border.width: 1
                        border.color: Style.lineAccent
                        Caption {
                            id: hdr
                            anchors.centerIn: parent
                            text: askCard.q ? (askCard.q.header || "") : ""
                            color: Style.accentHi
                        }
                    }
                    Text {
                        visible: panel.asking && panel.ask0.questions.length > 1
                        text: panel.asking ? (panel.qIndex + 1) + " of " + panel.ask0.questions.length : ""
                        color: Style.muted
                        font.family: Style.sans; font.pixelSize: 10
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                Text {
                    visible: panel.asking
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: askCard.q ? askCard.q.question : ""
                    color: Style.fg
                    font.family: Style.sans; font.pixelSize: 13; font.weight: Font.Medium
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
                        radius: Style.controlRadius + 2
                        color: optArea.containsMouse || picked ? Style.surfaceHover : Style.surface
                        Behavior on color { ColorMotion {} }
                        border.width: 1
                        border.color: picked ? Style.accent : optArea.containsMouse ? Style.lineHi : Style.line
                        Behavior on border.color { ColorMotion {} }
                        Column {
                            id: optCol
                            x: 10; y: 7
                            width: parent.width - 20
                            spacing: 2
                            Text {
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: (opt.index + 1) + ". " + opt.modelData.label
                                color: Style.fg
                                font.family: Style.sans; font.pixelSize: 13
                            }
                            Text {
                                visible: !!opt.modelData.description
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: opt.modelData.description || ""
                                color: Style.muted
                                font.family: Style.sans; font.pixelSize: 11
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
                    AskButton { label: "Skip"; variant: "ghost"; onClicked: panel.skipQuestion() }
                    Text {
                        text: "or type your own answer below"
                        color: Style.muted
                        font.family: Style.sans; font.pixelSize: 11
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
            height: queueCol.height + attachRow.height + box.height + 4 + controls.height

            // messages sent mid-reply, waiting for the AI to read them
            Column {
                id: queueCol
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: panel.queue.length ? implicitHeight + 6 : 0
                spacing: 4
                Repeater {
                    model: panel.queue
                    Rectangle {
                        required property var modelData
                        width: queueCol.width
                        height: 26
                        radius: Style.controlRadius
                        color: Style.surface
                        border.width: 1
                        border.color: Style.line
                        Text {
                            anchors { left: parent.left; right: parent.right; leftMargin: 10; rightMargin: 10
                                      verticalCenter: parent.verticalCenter }
                            text: "Queued · " + (parent.modelData.text.replace(/\s+/g, " ")
                                  || (parent.modelData.images.length === 1 ? "1 image" : parent.modelData.images.length + " images"))
                            color: Style.muted
                            elide: Text.ElideRight
                            font.family: Style.sans; font.pixelSize: 12
                        }
                    }
                }
            }

            // pasted images for the next message; × removes one
            Flow {
                id: attachRow
                anchors { top: queueCol.bottom; left: parent.left; right: parent.right }
                height: panel.attachments.length ? implicitHeight + 6 : 0
                spacing: 6
                Repeater {
                    model: panel.attachments
                    Rectangle {
                        id: attChip
                        required property string modelData
                        required property int index
                        width: 56; height: 56
                        radius: 8
                        clip: true
                        color: Style.surface
                        border.width: 1
                        border.color: attHover.hovered ? Style.lineHi : Style.line
                        HoverHandler { id: attHover }
                        Image {
                            anchors { fill: parent; margins: 1 }
                            source: panel.fileUrl(attChip.modelData)
                            sourceSize.height: 112
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                        Rectangle {
                            anchors { top: parent.top; right: parent.right; margins: 3 }
                            width: 18; height: 18; radius: 9
                            color: Style.alpha("#000000", 0.65)
                            opacity: attHover.hovered ? 1 : 0.75
                            Text {
                                anchors.centerIn: parent
                                text: "×"
                                color: "#ffffff"
                                font.family: Style.sans; font.pixelSize: 13; font.bold: true
                            }
                            MouseArea {
                                anchors { fill: parent; margins: -3 }
                                cursorShape: Qt.PointingHandCursor
                                onClicked: panel.attachments = panel.attachments.filter((_, i) => i !== attChip.index)
                            }
                        }
                    }
                }
            }

            Rectangle {   // focus ring: 2 px accent, 2 px off the box
                anchors { fill: box; margins: -4 }
                radius: box.radius + 4
                color: "transparent"
                border.width: 2
                border.color: Style.alpha(Style.accent, 0.5)
                opacity: input.activeFocus ? 1 : 0
                Behavior on opacity { Motion { duration: Style.quick } }
            }
            Rectangle {
                id: box
                anchors { top: attachRow.bottom; left: parent.left; right: parent.right }
                height: Math.min(170, Math.max(36, input.implicitHeight) + 12)
                radius: Style.controlRadius + 4
                color: Style.inputBg
                border.width: 1
                border.color: input.activeFocus ? Style.accent : boxHover.hovered ? Style.lineHi : Style.line
                Behavior on border.color { ColorMotion {} }
                HoverHandler { id: boxHover }

                ScrollView {
                    anchors { top: parent.top; left: parent.left; right: sendBtn.left; bottom: parent.bottom
                              topMargin: 4; bottomMargin: 4; leftMargin: 6; rightMargin: 4 }
                    TextArea {
                        id: input
                        placeholderText: panel.asking ? "Type your own answer…"
                                       : panel.busy && panel.canQueue ? "Add to the conversation…"
                                       : panel.busy ? panel.aiName + " is replying…"
                                       : messages.count === 0 ? Style.welcome : "Reply to " + panel.aiName + "…"
                        placeholderTextColor: Style.alpha(Style.muted, 0.8)
                        color: Style.fg
                        font.family: Style.sans; font.pixelSize: 14
                        wrapMode: TextArea.Wrap
                        selectionColor: Style.alpha(Style.accent, 0.4)
                        background: null
                        Keys.onReturnPressed: event => {
                            if (event.modifiers & Qt.ShiftModifier) event.accepted = false
                            else panel.send()
                        }
                        // paste goes through pasteImage(): images attach, text pastes
                        Keys.onPressed: event => {
                            if (panel.canAttach && (event.matches(StandardKey.Paste)
                                    || (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier)))) {
                                event.accepted = true
                                panel.pasteImage()
                            }
                        }
                        // Esc closes (menus first, then the popup); Shift+Esc stops the AI
                        Keys.onEscapePressed: event => {
                            if ((event.modifiers & Qt.ShiftModifier) && panel.busy) panel.stop()
                            else if (panel.modelMenuOpen || panel.modeMenuOpen) { panel.modelMenuOpen = false; panel.modeMenuOpen = false }
                            else win.open = false
                        }
                    }
                }

                Rectangle {
                    id: sendBtn
                    readonly property bool draft: input.text.trim() !== "" || panel.attachments.length > 0
                    readonly property bool ready: panel.busy || draft
                    // while the AI is busy, something typed is sent (an answer to its
                    // question, or a queued message) instead of stopping
                    readonly property bool stopping: panel.busy && !(panel.asking ? input.text.trim() !== "" : panel.canQueue && draft)
                    // centred beside one line of text, kept at the bottom when it grows
                    anchors.right: parent.right
                    anchors.rightMargin: (box.height - height) / 2 > 10 ? 8 : (box.height - height) / 2
                    y: input.lineCount <= 1 ? (box.height - height) / 2 : box.height - height - 8
                    width: 28; height: 28; radius: Style.controlRadius
                    color: !ready ? Style.accentDim : sendHover.containsMouse ? Style.accentHi : Style.accent
                    Behavior on color { ColorMotion {} }
                    scale: sendHover.pressed ? 0.98 : 1
                    Behavior on scale { Motion { duration: Style.quick } }
                    Accessible.role: Accessible.Button
                    Accessible.name: stopping ? "Stop" : "Send"
                    Elevation {   // accent glow once there's something to send
                        anchors.fill: parent
                        z: -1
                        radius: parent.radius
                        glow: sendBtn.ready
                        lifted: sendHover.containsMouse && sendBtn.ready
                        depth: 0.35
                        opacity: sendBtn.ready ? 1 : 0
                        Behavior on opacity { Motion {} }
                    }
                    Rectangle {   // inset highlight
                        anchors { top: parent.top; topMargin: 1; horizontalCenter: parent.horizontalCenter }
                        width: parent.width - parent.radius
                        height: 1
                        color: Style.alpha("#ffffff", sendBtn.ready ? 0.2 : 0.06)
                    }
                    Text {
                        visible: !sendBtn.stopping
                        anchors.centerIn: parent
                        text: "↑"
                        color: sendBtn.ready ? Style.onAccent : Style.alpha(Style.onAccent, 0.5)
                        font.family: Style.sans; font.pixelSize: 16; font.bold: true
                    }
                    Rectangle {   // stop: a drawn square, the ■ glyph sits off-centre
                        visible: sendBtn.stopping
                        anchors.centerIn: parent
                        width: 10; height: 10; radius: 2
                        color: Style.onAccent
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

                    Rectangle {   // permission mode (when the backend has one): click to change
                        visible: !!panel.modeInfo
                        height: 26; radius: Style.controlRadius
                        width: modeRow.implicitWidth + 14
                        color: modeArea.containsMouse || panel.modeMenuOpen ? Style.surface : "transparent"
                        Behavior on color { ColorMotion {} }
                        Row {
                            id: modeRow
                            anchors.centerIn: parent
                            spacing: 4
                            Text {
                                text: panel.modeInfo ? panel.modeInfo.label : ""
                                color: modeArea.containsMouse || panel.modeMenuOpen ? Style.fg : Style.subtle
                                font.family: Style.sans; font.pixelSize: 12
                            }
                            Text {
                                visible: panel.modes.length > 1
                                text: "⌄"
                                color: Style.muted
                                font.pixelSize: 10
                            }
                        }
                        MouseArea {
                            id: modeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: panel.modes.length > 1 ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: if (panel.modes.length > 1) { panel.modelMenuOpen = false; panel.modeMenuOpen = !panel.modeMenuOpen }
                        }
                        Tip { visible: modeArea.containsMouse && !panel.modeMenuOpen && !!panel.modeInfo; text: panel.modeInfo ? panel.modeInfo.tip : "" }
                    }

                    // screenshot chip: what the AI will see; click to stop sharing
                    Rectangle {
                        id: chip
                        visible: panel.shotOk
                        height: 26; radius: Style.controlRadius
                        width: chipRow.implicitWidth + 14
                        color: chipHover.containsMouse ? Style.surface : "transparent"
                        Behavior on color { ColorMotion {} }
                        Row {
                            id: chipRow
                            anchors.centerIn: parent
                            spacing: 6
                            Rectangle {
                                width: 26; height: 16; radius: 3
                                color: Style.bgDeep
                                border.width: 1
                                border.color: Style.lineHi
                                clip: true
                                anchors.verticalCenter: parent.verticalCenter
                                Image {
                                    anchors.fill: parent
                                    source: panel.shotOk ? "file://" + (panel.shareScreen ? panel.shotPath : panel.hiddenShotPath) + "?" + panel.shotSerial + "-" + panel.shareSerial : ""
                                    cache: false
                                    asynchronous: true
                                    fillMode: Image.PreserveAspectCrop
                                    opacity: panel.shareScreen ? 1 : 0.25
                                }
                            }
                            Text {
                                text: panel.shareScreen ? "Screen" : "Screen off"
                                color: panel.shareScreen ? Style.subtle : Style.muted
                                font.family: Style.sans; font.pixelSize: 12
                                font.strikeout: !panel.shareScreen
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        MouseArea {
                            id: chipHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: win.shareScreen = !win.shareScreen
                        }
                        Tip {
                            visible: chipHover.containsMouse
                            text: panel.shareScreen ? panel.aiName + " can look at your screen when it needs to (click to turn off)"
                                                    : panel.aiName + " can't see your screen (click to allow)"
                        }
                    }
                }

                Rectangle {   // model picker
                    id: modelBtn
                    visible: panel.models.length > 0
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    height: 26; radius: Style.controlRadius
                    width: modelRow.implicitWidth + 14
                    color: modelArea.containsMouse || panel.modelMenuOpen ? Style.surface : "transparent"
                    Behavior on color { ColorMotion {} }
                    Row {
                        id: modelRow
                        anchors.centerIn: parent
                        spacing: 4
                        Text {
                            text: panel.modelLabel
                            color: modelArea.containsMouse || panel.modelMenuOpen ? Style.fg : Style.subtle
                            font.family: Style.sans; font.pixelSize: 12
                        }
                        Text {
                            text: "⌄"
                            color: Style.muted
                            font.pixelSize: 10
                        }
                    }
                    MouseArea {
                        id: modelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: panel.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: if (!panel.busy && panel.models.length > 1) { panel.modeMenuOpen = false; panel.modelMenuOpen = !panel.modelMenuOpen }
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
            radius: Style.radius - 4
            color: Style.bgElevated
            border.width: 1
            border.color: Style.lineHi
            onVisibleChanged: if (visible) menuIn.restart()
            transform: Translate { id: menuRise }
            ParallelAnimation {
                id: menuIn
                Motion { target: modelMenu; property: "opacity"; from: 0; to: 1; duration: Style.quick }
                Motion { target: menuRise; property: "y"; from: 6; to: 0 }
            }
            Elevation { anchors.fill: parent; z: -1; radius: parent.radius }
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
                        radius: Style.controlRadius
                        color: mArea.containsMouse ? Style.surface : "transparent"
                        Behavior on color { ColorMotion {} }
                        Column {
                            anchors { left: parent.left; leftMargin: 10; right: check.left; verticalCenter: parent.verticalCenter }
                            spacing: 2
                            Text {
                                text: mrow.modelData.name + (mrow.modelData.id === panel.defaultModel ? "  · default" : "")
                                color: Style.fg
                                font.family: Style.sans; font.pixelSize: 13
                            }
                            Text {
                                width: parent.width
                                visible: text !== ""
                                text: mrow.modelData.blurb || ""
                                color: Style.muted
                                font.family: Style.sans; font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            id: check
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            text: mrow.current ? "✓" : ""
                            color: Style.accent
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
                Rectangle {   // make the current model the one new chats start with
                    visible: panel.activeAlias !== panel.defaultModel && panel.models.some(x => x.id === panel.activeAlias)
                    width: menuCol.width
                    height: 30
                    radius: Style.controlRadius
                    color: defArea.containsMouse ? Style.surface : "transparent"
                    Behavior on color { ColorMotion {} }
                    Text {
                        anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                        text: "Use " + panel.modelLabel + " for new chats"
                        color: defArea.containsMouse ? Style.fg : Style.subtle
                        font.family: Style.sans; font.pixelSize: 12
                    }
                    MouseArea {
                        id: defArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { panel.modelMenuOpen = false; win.setDefaultModel(panel.activeAlias) }
                    }
                }
            }
        }

        // permission-mode menu, opening upward from the mode chip
        Rectangle {
            id: modeMenu
            visible: panel.modeMenuOpen
            z: 5
            anchors { bottom: composer.bottom; bottomMargin: 32; left: composer.left }
            width: 360
            height: modeCol.implicitHeight + 12
            radius: Style.radius - 4
            color: Style.bgElevated
            border.width: 1
            border.color: Style.lineHi
            onVisibleChanged: if (visible) modeIn.restart()
            transform: Translate { id: modeRise }
            ParallelAnimation {
                id: modeIn
                Motion { target: modeMenu; property: "opacity"; from: 0; to: 1; duration: Style.quick }
                Motion { target: modeRise; property: "y"; from: 6; to: 0 }
            }
            Elevation { anchors.fill: parent; z: -1; radius: parent.radius }
            Column {
                id: modeCol
                x: 6; y: 6
                width: parent.width - 12
                Repeater {
                    model: panel.modes
                    delegate: Rectangle {
                        id: drow
                        required property var modelData
                        readonly property bool current: modelData.id === panel.modeId
                        width: modeCol.width
                        height: 46
                        radius: Style.controlRadius
                        color: dArea.containsMouse ? Style.surface : "transparent"
                        Behavior on color { ColorMotion {} }
                        Column {
                            anchors { left: parent.left; leftMargin: 10; right: dcheck.left; verticalCenter: parent.verticalCenter }
                            spacing: 2
                            Text {
                                text: drow.modelData.label
                                color: Style.fg
                                font.family: Style.sans; font.pixelSize: 13
                            }
                            Text {
                                width: parent.width
                                visible: text !== ""
                                text: drow.modelData.tip || ""
                                color: Style.muted
                                font.family: Style.sans; font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            id: dcheck
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            text: drow.current ? "✓" : ""
                            color: Style.accent
                            font.pixelSize: 14
                        }
                        MouseArea {
                            id: dArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panel.chooseMode(drow.modelData.id)
                        }
                    }
                }
            }
        }

}
