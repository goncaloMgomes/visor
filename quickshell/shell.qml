import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Networking
import Quickshell.Bluetooth
import QtQuick

// Visor: a robot companion in the top-right corner of the screen.
// Its mood comes from AI tools through $XDG_RUNTIME_DIR/visor/state (written by
// the adapters, e.g. adapters/claude-code/hook.sh, or `visor signal`); clicking
// it opens a chat popup (ChatPanel.qml) that talks to the configured backend
// and can see a screenshot of what you were doing. Settings:
// ~/.config/visor/config.json (defaults in backend/common.py).
ShellRoot {
    id: shell
    readonly property bool hypr: !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    // something fullscreen (video, game, the screensaver): the robot and all
    // its popups stay out of the way
    readonly property bool fullscreen: hypr ? (Hyprland.focusedWorkspace?.hasFullscreen ?? false)
                                            : (ToplevelManager.activeToplevel?.fullscreen ?? false)
    onFullscreenChanged: if (fullscreen) { chat.open = false; remoteMenu.open = false }
    readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/visor"
    readonly property string stateHome: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/visor"
    readonly property string backendDir: Quickshell.shellDir + "/../backend"
    readonly property string helper: backendDir + "/chat.py"
    readonly property real zoom: 1

    // --- settings -------------------------------------------------------------
    // `chat.py info`: the merged config, the backend's name/models/features,
    // the chat theme and what this machine has. Re-read when the file changes.
    property var info: null
    readonly property var cfg: info ? info.config : ({})
    readonly property var backend: info ? info.backend : ({ name: "Assistant", features: {} })
    readonly property var features: cfg.features ?? ({})
    Process {
        id: infoProc
        running: true
        command: [shell.helper, "info"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { shell.info = JSON.parse(this.text) } catch (e) { console.warn("visor: chat.py info failed:", this.text); return }
                Style.theme = shell.info.theme
                Style.reducedMotion = shell.info.reducedMotion
            }
        }
    }
    FileView {
        path: shell.info ? shell.info.configFile : ""
        watchChanges: true
        printErrors: false
        onFileChanged: if (!infoProc.running) infoProc.running = true
    }

    FileView {
        id: stateFile
        path: runDir + "/state"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }

    // user away for 4 min (respects idle inhibitors, e.g. Waybar's)
    IdleMonitor {
        id: idleMon
        timeout: shell.cfg.idleSeconds ?? 240
        respectInhibitors: true
    }

    // Snapshot the screen and focused window *before* the popup appears,
    // so the AI sees what you were doing rather than the chat itself.
    Process {
        id: shot
        command: ["grim", "-s", "1", "-t", "jpeg", "-q", "80", shell.runDir + "/screen.jpg"]
        onExited: code => {
            chat.shotOk = code === 0
            chat.shotSerial++
            chat.open = true
        }
    }

    // --- the service the robot "is" (optional) ----------------------------
    // With service.unit set (a systemd --user unit, e.g. Claude Code Remote
    // Control), the robot mirrors it: asleep while it isn't running, a click
    // wakes it (starts the unit), the chat's ⏻ puts it to sleep.
    readonly property string remoteUnit: cfg.service?.unit ?? ""
    readonly property string serviceLabel: cfg.service?.label || remoteUnit.replace(/\.service$/, "")
    readonly property bool hasService: remoteUnit !== ""
    property bool remoteOn: true
    property bool waking: false
    onHasServiceChanged: if (!hasService) { remoteOn = true; waking = false }

    Process {
        id: remoteCheck
        command: ["systemctl", "--user", "is-active", shell.remoteUnit]
        stdout: StdioCollector {
            onStreamFinished: {
                shell.remoteOn = this.text.trim() === "active"
                shell.remoteKnown = true
                if (shell.remoteOn) shell.waking = false
            }
        }
    }
    Timer {
        running: shell.hasService
        repeat: true
        triggeredOnStart: true
        interval: shell.waking ? 1000 : 5000
        onTriggered: if (!remoteCheck.running) remoteCheck.running = true
    }
    Timer {   // give up the yawn if the service never comes up
        id: wakeTimeout
        interval: 45000
        onTriggered: shell.waking = false
    }

    function wakeRemote() {
        if (waking || !hasService) return
        waking = true
        wokeByClick = true
        wakeTimeout.restart()
        Quickshell.execDetached(["systemctl", "--user", "start", remoteUnit])
    }
    function sleepRemote() {
        if (!hasService) return
        chat.open = false
        userStopped = true
        balloon.say("Good night! " + serviceLabel + " is off, click me whenever you want me back.", { ms: 6000 })
        Quickshell.execDetached(["systemctl", "--user", "stop", remoteUnit])
        remoteCheck.running = true
    }
    function restartRemote() {
        if (!hasService) return
        chat.open = false
        waking = true
        wokeByClick = true
        userStopped = true   // the brief "down" while restarting isn't news
        wakeTimeout.restart()
        balloon.say("Restarting " + serviceLabel + "… be right back!", { ms: 4000 })
        Quickshell.execDetached(["systemctl", "--user", "restart", remoteUnit])
    }

    // right-click the robot: settings, and the service's status + Start / Restart / Stop
    RemoteMenu {
        id: remoteMenu
        unit: shell.remoteUnit
        label: shell.serviceLabel
        countPattern: shell.cfg.service?.countPattern ?? ""
        weatherOn: shell.features.weather !== false
        anchor.window: faceWin
        anchor.rect.x: faceWin.width - implicitWidth + pad - 4
        anchor.rect.y: faceWin.height + 6 - pad
        remoteOn: shell.remoteOn
        waking: shell.waking
        onStartRequested: shell.wakeRemote()
        onStopRequested: shell.sleepRemote()
        onRestartRequested: shell.restartRemote()
        city: shell.city
        balloonsOn: shell.balloonsOn
        onCitySet: name => shell.setCity(name)
        onBalloonsSet: on => shell.setBalloons(on)
    }
    HyprlandFocusGrab {
        active: shell.hypr && remoteMenu.open
        windows: [remoteMenu, faceWin]
        onCleared: remoteMenu.open = false
    }

    // tell the user when the service goes away on its own (not the quick
    // restart after a resume) and when it comes back
    property bool remoteKnown: false
    property bool userStopped: false
    property bool wokeByClick: false
    property bool announcedDown: false
    Timer {
        id: downNotice
        interval: 20000
        onTriggered: if (!shell.remoteOn && !shell.userStopped) {
            shell.announcedDown = true
            balloon.say("Oops, " + shell.serviceLabel + " stopped on its own. Click me to wake it up again.", { ms: 8000 })
        }
    }
    onRemoteOnChanged: {
        if (!remoteOn) chat.open = false
        if (!remoteKnown || !hasService) return
        if (!remoteOn) {
            if (!userStopped) downNotice.restart()
        } else {
            downNotice.stop()
            if (announcedDown || wokeByClick) balloon.say("I'm awake! " + serviceLabel + " is back on.", { ms: 5000 })
            announcedDown = false; userStopped = false; wokeByClick = false
        }
    }

    // `visor ipc <fn>`: drive the robot from scripts
    IpcHandler {
        target: "robot"
        function chat(): void { shell.toggleChat() }
        // the screensaver calls this first: while the chat holds the focus
        // grab, a new window can't take focus and never goes fullscreen
        function closeChat(): void { chat.open = false; remoteMenu.open = false }
        function capture(on: bool): void { shell.capturing = on }
        // drive the chat from scripts (testing): send a message, answer a request
        // ("allow", "always", "deny", or an option label for a question)
        function chatAsk(text: string): void { chat.ask(text) }
        function chatAnswer(choice: string): void {
            if (chat.asking) choice === "skip" ? chat.skipQuestion() : chat.answer(choice)
            else if (chat.ask0) chat.permit(choice !== "deny", choice === "always")
        }
        function chatNew(): void { chat.newChat() }
        function say(text: string): void { balloon.say(text, { ms: 6000 }) }
        function remoteStart(): void { shell.wakeRemote() }
        function remoteStop(): void { shell.sleepRemote() }
        function remoteRestart(): void { shell.restartRemote() }
        function menu(): void { remoteMenu.open = !remoteMenu.open }
        function remote(): string { return shell.remoteOn ? "on" : "off" }
        function sys(kind: string, on: bool, level: real): void { face.sysEvent(kind, on, level) }
        function curious(): void { face.curious() }
        function city(name: string): void { shell.setCity(name) }
        // a line from the AI-written pool ("" = none), e.g. aiLine plugged 42
        function aiLine(kind: string, arg: string): string {
            const info = /^\d+$/.test(arg) ? parseInt(arg) : kind === "music" ? { title: arg, artist: "Daft Punk" } : arg
            return shell.aiLine(kind, info)
        }
    }

    function toggleChat() {
        remoteMenu.open = false
        if (chat.open) { chat.open = false; return }
        const t = ToplevelManager.activeToplevel
        chat.windowInfo = t ? ((t.appId ?? "") + " — " + (t.title ?? "")) : ""
        if (shell.cfg.chat?.shareScreen === false) { chat.shotOk = false; chat.open = true; return }
        shot.running = true
    }

    ChatPanel {
        id: chat
        chatTop: (shell.cfg.position?.chatTop ?? 46) + (shell.zoom - 1) * 40
        chatRight: shell.cfg.position?.chatRight ?? 8
        runDir: shell.runDir
        stateHome: shell.stateHome
        helper: shell.helper
        backend: shell.backend
        cfg: shell.cfg
        hasService: shell.hasService
        serviceLabel: shell.serviceLabel
        onMoodRequested: mood => stateFile.setText(mood + "\n")
        onSleepRequested: shell.sleepRemote()
        // a permission request or question while the popup is closed: look up and say so
        onNeedsYou: text => {
            stateFile.setText("input\n")
            balloon.say(text, { ms: 12000, action: chat.transcript })
        }
    }

    // keyboard goes to the popup; clicking anywhere else closes it
    // screenshot.sh sets this while slurp picks an area: slurp takes the focus,
    // which would otherwise close the popup before it is captured
    property bool capturing: false
    // (Hyprland only; elsewhere the popup closes with Esc, ✕ or a click on the robot)
    HyprlandFocusGrab {
        active: shell.hypr && chat.open && !shell.capturing
        windows: [chat, faceWin]
        onCleared: chat.open = false
    }

    // --- settings (right-click menu) -------------------------------------------
    // ~/.local/state/visor/settings.json: {city, balloons}
    property string city: ""
    property bool balloonsOn: true
    FileView {
        id: settingsFile
        path: shell.stateHome + "/settings.json"
        printErrors: false
        blockLoading: true
        Component.onCompleted: reload()
        onLoaded: {
            try {
                const o = JSON.parse(text())
                shell.city = o.city || ""
                shell.balloonsOn = o.balloons !== false
            } catch (e) {}
        }
    }
    function saveSettings() {
        Quickshell.execDetached(["mkdir", "-p", stateHome])
        settingsFile.setText(JSON.stringify({ city: city, balloons: balloonsOn }))
    }
    function setCity(name) {
        city = name.trim()
        saveSettings()
        weather = null
        if (city && features.weather !== false) { weatherAsked = true; weatherProc.running = true }
    }
    function setBalloons(on) {
        balloonsOn = on
        saveSettings()
        if (on) balloon.say("Okay, I'll talk again! 😊", { ms: 3500 })
    }

    // --- the pointer (optional; extras/hyprland/visor.lua writes it) -------------
    // $XDG_RUNTIME_DIR/visor/pointer = "x y clicks", updated while it moves.
    // Without it the eyes don't follow the mouse and clicks aren't noticed.
    property int clicks: -1
    property real lastCurious: 0
    FileView {
        id: pointerFile
        path: shell.runDir + "/pointer"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const p = text().trim().split(" ")
            if (p.length < 3) return
            const x = parseFloat(p[0]), y = parseFloat(p[1]), c = parseInt(p[2])
            face.cursorX = x; face.cursorY = y; face.cursorAt = Date.now()
            const wp = wsLoader.item
            if (wp) { wp.pointerX = x; wp.pointerY = y }
            if (shell.clicks >= 0 && c > shell.clicks) { if (wp) wp.clicked(); shell.clicked(x, y) }
            shell.clicks = c
        }
    }
    // Hyprland without the Lua snippet: a small helper reads the cursor from its socket
    Process {
        running: shell.hypr && shell.info !== null && !shell.info.env.hyprlandLua
        command: [Quickshell.shellDir + "/../extras/hyprland/pointer.py"]
    }

    // preview of a workspace's windows when hovering its dot in Waybar
    // (Hyprland + Waybar + the pointer file; features.workspacePreview)
    LazyLoader {
        id: wsLoader
        active: shell.hypr && shell.features.workspacePreview === true
        WsPreview {
            blocked: shell.fullscreen || chat.open || remoteMenu.open
            bar: shell.cfg.waybar ?? ({})
            lua: shell.info ? shell.info.env.hyprlandLua : false
        }
    }

    function clicked(x, y) {
        // not on the robot itself, not too often, and only some clicks
        if (y < 50 && x > face.eyeOriginX - 40) return
        if (chat.open || remoteMenu.open || Date.now() - lastCurious < 20000) return
        if (Math.random() > 0.18) return
        lastCurious = Date.now()
        face.curious()
    }

    // --- system events -----------------------------------------------------------
    // ready after a moment, so the initial values don't count as changes
    property bool sysReady: false
    Timer { running: true; interval: 4000; onTriggered: shell.sysReady = true }

    // volume (PipeWire default output)
    PwObjectTracker { objects: [Pipewire.defaultAudioSink] }
    readonly property var sinkAudio: Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.audio : null
    Connections {
        target: shell.sinkAudio
        function onVolumeChanged() { if (shell.sysReady) face.sysEvent("vol", !shell.sinkAudio.muted, shell.sinkAudio.volume) }
        function onMutedChanged()  { if (shell.sysReady) face.sysEvent("vol", !shell.sinkAudio.muted, shell.sinkAudio.volume) }
    }

    // wifi and bluetooth switched on/off, bluetooth devices (dis)connecting
    Connections {
        target: Networking
        function onWifiEnabledChanged() {
            if (!shell.sysReady) return
            face.sysEvent("wifi", Networking.wifiEnabled, -1, 2200)
            shell.quip(Networking.wifiEnabled ? "wifiOn" : "wifiOff")
        }
    }
    Connections {
        target: Bluetooth.defaultAdapter
        function onEnabledChanged() {
            if (!shell.sysReady) return
            face.sysEvent("bt", Bluetooth.defaultAdapter.enabled, -1, 2200)
            shell.quip(Bluetooth.defaultAdapter.enabled ? "btOn" : "btOff")
        }
    }
    Instantiator {
        model: Bluetooth.devices
        delegate: Connections {
            required property var modelData
            target: modelData
            function onConnectedChanged() {
                if (!shell.sysReady) return
                face.sysEvent("btdev", modelData.connected, modelData.batteryAvailable ? modelData.battery : -1, 2600)
                if (modelData.connected) shell.quip("btDevice", modelData.name || modelData.deviceName)
            }
        }
    }

    // USB devices plugged in / out (hubs and the laptop's own parts left out;
    // a burst of them, like after a resume, is ignored)
    property var usbBlock: ({})
    property var usbTimes: []
    Process {
        id: usbMon
        running: true
        command: ["udevadm", "monitor", "--udev", "--subsystem-match=usb/usb_device", "--property"]
        stdout: SplitParser {
            onRead: line => {
                if (line.trim() === "") { shell.usbEvent(shell.usbBlock); shell.usbBlock = {}; return }
                const i = line.indexOf("=")
                if (i > 0) shell.usbBlock[line.substring(0, i)] = line.substring(i + 1)
            }
        }
        onRunningChanged: if (!running) usbRestart.start()
    }
    Timer { id: usbRestart; interval: 5000; onTriggered: usbMon.running = true }
    function usbEvent(b) {
        if (!sysReady || (b.ACTION !== "add" && b.ACTION !== "remove")) return
        if ((b.TYPE || "").indexOf("9/") === 0) return                        // hub
        const name = (b.ID_MODEL_FROM_DATABASE || b.ID_MODEL || "").replace(/_/g, " ")
        if (/hub|bluetooth|fingerprint|webcam|camera|N-KEY/i.test(name)) return
        const now = Date.now()
        usbTimes = usbTimes.filter(t => now - t < 3000).concat([now])
        if (usbTimes.length > 2) return
        face.sysEvent("usb", b.ACTION === "add", -1, 2400)
        if (b.ACTION === "add") quip("usb", name)
    }

    // brightness and keep-awake: one line each in $XDG_RUNTIME_DIR/visor/sys,
    // written by scripts/sysevent.sh (bind your brightness keys to it, see docs)
    property int sysSeen: -1
    FileView {
        id: sysFile
        path: shell.runDir + "/sys"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const lines = text().split("\n").filter(l => l.trim() !== "")
            if (shell.sysSeen < 0 || lines.length < shell.sysSeen) { shell.sysSeen = lines.length; return }
            for (const l of lines.slice(shell.sysSeen)) {
                const p = l.trim().split(" ")
                if (p[0] === "bright") face.sysEvent("bright", true, parseFloat(p[1]) / 100)
                else if (p[0] === "caffeine") {
                    const on = p[1] === "on"
                    face.sysEvent("coffee", on, -1, 2600)
                    shell.quip(on ? "coffeeOn" : "coffeeOff")
                    if (!on) yawnAfterCoffee.start()
                }
            }
            shell.sysSeen = lines.length
        }
    }
    Timer { id: yawnAfterCoffee; interval: 2700; onTriggered: face.peek("yawn", false) }

    // --- weather ---------------------------------------------------------------
    // For the city set in the right-click menu (no IP lookup), every 30 minutes.
    // It's only mentioned when greeting (boot / unlock), at most every 3 hours.
    property var weather: null          // {kind, temp, city, desc, rise, set, at} — kind as fetched; use liveWeather()
    property var pendingGreet: null     // greeting waiting for a fresh fetch
    property real lastWeatherSay: 0
    property bool weatherAsked: false
    Process {
        id: weatherProc
        command: ["curl", "-s", "-m", "15", "https://wttr.in/" + encodeURIComponent(shell.city) + "?format=j1"]
        stdout: StdioCollector {
            onStreamFinished: {
                let d
                try { d = JSON.parse(this.text) } catch (e) { d = null }
                const w = d ? shell.readWeather(d) : null
                if (!w) { shell.flushGreet(); return }
                const first = !shell.weather
                const changed = shell.weather && shell.liveWeather().kind !== w.kind
                shell.weather = w
                if (first || changed) shell.refreshRemarks(first ? 9000000 : 2700000)   // lines that fit the new weather
                if (first && shell.weatherAsked) { shell.weatherAsked = false; shell.sayWeather() }   // just set the city
                shell.flushGreet()
            }
        }
    }
    readonly property bool weatherOn: city !== "" && features.weather !== false
    Timer {
        running: shell.weatherOn; repeat: true; triggeredOnStart: true
        interval: 1800000
        onTriggered: weatherProc.running = true
    }
    // Timers don't count time spent suspended, so after a resume the 30-minute
    // one above is late: check the wall clock too.
    Timer {
        running: shell.weatherOn; repeat: true; interval: 60000
        onTriggered: if (shell.weatherStale(1800000) && !weatherProc.running) weatherProc.running = true
    }
    function weatherStale(ms) { return !weather || Date.now() - weather.at > ms }

    function minutesOf(t) {   // "07:43 AM" -> minutes after midnight
        const m = /(\d+):(\d+)\s*(AM|PM)/.exec(t || "")
        if (!m) return -1
        return (parseInt(m[1]) % 12 + (m[3] === "PM" ? 12 : 0)) * 60 + parseInt(m[2])
    }
    function readWeather(d) {
        const c = d.current_condition && d.current_condition[0]
        if (!c) return null
        const code = parseInt(c.weatherCode), temp = parseInt(c.temp_C)
        const area = d.nearest_area && d.nearest_area[0]
        const astro = d.weather && d.weather[0] && d.weather[0].astronomy && d.weather[0].astronomy[0]
        const now = new Date(), nowMin = now.getHours() * 60 + now.getMinutes()
        const rise = astro ? minutesOf(astro.sunrise) : -1, set = astro ? minutesOf(astro.sunset) : -1
        const day = rise < 0 || (nowMin > rise && nowMin < set)
        const has = list => list.indexOf(code) >= 0
        let kind
        if (has([200, 386, 389, 392, 395])) kind = "stormy"
        else if (has([179, 182, 227, 230, 317, 320, 323, 326, 329, 332, 335, 338, 350, 362, 365, 368, 371, 374, 377])) kind = "snowy"
        else if (has([176, 185, 263, 266, 281, 284, 293, 296, 299, 302, 305, 308, 311, 314, 353, 356, 359])) kind = "rainy"
        else if (has([143, 248, 260])) kind = "foggy"
        else if (has([119, 122])) kind = "cloudy"
        else kind = day ? "sunny" : "clear"          // 113 clear, 116 partly cloudy
        if (temp >= 30 && (kind === "sunny" || kind === "cloudy" || kind === "clear")) kind = "hot"
        else if (temp <= 3 && kind !== "snowy") kind = "cold"
        const mine = shell.city.split(",")[0].trim()
        return { kind: kind, temp: temp, city: mine || (area ? area.areaName[0].value : ""),
                 desc: c.weatherDesc ? c.weatherDesc[0].value : "", rise: rise, set: set, at: Date.now() }
    }
    // the weather with sunny/clear decided now, not when it was fetched
    function liveWeather() {
        const w = weather
        if (!w || (w.kind !== "sunny" && w.kind !== "clear") || w.rise < 0) return w
        const now = new Date(), m = now.getHours() * 60 + now.getMinutes()
        const kind = m > w.rise && m < w.set ? "sunny" : "clear"
        return Object.assign({}, w, { kind: kind })
    }
    // the face to show with a weather sentence
    function weatherFace() {
        const w = liveWeather()
        return w && w.kind !== "clear" ? w.kind : ""
    }
    // one weather sentence (or "")
    function weatherLine() {
        const w = liveWeather()
        if (!w) return ""
        // the AI's lines, if they were written for this weather
        if (remarkPool && (remarkPool.weather || "").indexOf(w.kind + " ") === 0) {
            const ai = aiLine("weather", { t: w.temp, c: w.city || "town" })
            if (ai) return ai
        }
        const lines = {
            sunny:  ["☀️ Sunny and {t}°C in {c}! Sunglasses on 😎",
                     "😎 {t}°C and sunshine in {c}. Don't forget to go outside today!"],
            clear:  ["✨ Clear skies over {c} tonight, {t}°C.",
                     "🌙 A clear night in {c}, {t}°C. Good stargazing weather!"],
            rainy:  ["☔ It's raining in {c} ({t}°C). Perfect excuse to stay in and code!",
                     "🌧️ Rain in {c}. Grab an umbrella if you head out!"],
            cloudy: ["☁️ Grey skies over {c}, {t}°C. Meh.",
                     "☁️ Cloudy in {c} today, {t}°C. The sun is on a break."],
            snowy:  ["❄️ Snow in {c}! {t}°C, brrr. Snowman break?",
                     "☃️ It's snowing in {c}! Stay warm!"],
            stormy: ["⛈️ Thunderstorm over {c}! I'm hiding under the desk 😨",
                     "⚡ Storm in {c}! Maybe save your work, just in case."],
            hot:    ["🥵 {t}°C in {c}! Is it hot in here or is it just my CPU?",
                     "🥵 It's {t}°C in {c}. Stay hydrated! 💧"],
            cold:   ["🥶 {t}°C in {c}… somebody turn on the heater!",
                     "🥶 Brrr, {t}°C in {c}. Hot chocolate time?"],
            foggy:  ["🌫️ Foggy in {c}. I can't see a thing!",
                     "🌫️ {c} is lost in the fog today, {t}°C."]
        }[w.kind] || []
        if (!lines.length) return ""
        return pick(lines).replace(/\{t\}/g, w.temp).replace(/\{c\}/g, w.city || "town")
    }
    // weather for a greeting: only when it hasn't been mentioned for 3 hours
    function greetingWeather() {
        if (!weather || Date.now() - lastWeatherSay < 3 * 3600000) return ""
        lastWeatherSay = Date.now()
        return weatherLine()
    }
    // say it now, with the weather face (after setting the city)
    function sayWeather() {
        const t = weatherLine()
        if (!t) return
        lastWeatherSay = Date.now()
        const k = weatherFace()
        balloon.say(t, { ms: 7000, onShow: () => { if (k) face.peek(k, true, 8000) } })
    }
    // A greeting is only said together with the weather (so at most every
    // 3 hours, and never without a city). `news` (sessions that finished while
    // away, the service being off) is still said on its own.
    function greet(first, news, fetched) {
        // stale weather (e.g. fetched before a night's suspend): fetch first
        if (!fetched && weatherOn && weatherStale(1200000) && Date.now() - lastWeatherSay >= 3 * 3600000) {
            pendingGreet = { first: first, news: news }
            if (!weatherProc.running) weatherProc.running = true
            greetFallback.restart()
            return
        }
        const w = greetingWeather()
        if (!w) {
            if (news) balloon.say(news, { ms: 7000 })
            return
        }
        const k = weatherFace()
        balloon.say([first, w, news].filter(x => x).join(" "), {
            ms: news ? 9500 : 7000,
            onShow: () => { if (k) face.peek(k, true, 9000); else face.peek("greet", true) }
        })
    }

    function flushGreet() {
        const g = pendingGreet
        if (!g) return
        pendingGreet = null
        greetFallback.stop()
        greet(g.first, g.news, true)   // even if the fetch failed: don't fetch again
    }
    Timer { id: greetFallback; interval: 20000; onTriggered: shell.flushGreet() }

    // --- lines written by the AI (backend/remarks.py) ---------------------------
    // A background call to the backend writes a pool of lines per kind every few
    // hours (time of day, weather); quip() and the weather greeting use them and
    // fall back to the hand-written ones below when the pool is missing or stale.
    property var remarkPool: null       // {t, weather, lines: {kind: [..]}}
    property var remarkUsed: ({})       // kind -> lines already said from this pool
    FileView {
        id: remarksFile
        path: shell.stateHome + "/remarks.json"
        watchChanges: true
        printErrors: false
        blockLoading: true
        onFileChanged: reload()
        onLoaded: {
            try { shell.remarkPool = JSON.parse(text()); shell.remarkUsed = {} } catch (e) {}
        }
    }
    function aiLine(kind, info) {
        const p = remarkPool
        if (!p || !p.lines || Date.now() / 1000 - p.t > 8 * 3600) return ""
        const vars = {
            n: typeof info === "number" ? info : "",
            name: typeof info === "string" ? info : "",
            title: info && info.title || "", artist: info && info.artist || "",
            t: info && info.t !== undefined ? info.t : "", c: info && info.c || ""
        }
        const fill = l => l.replace(/\{(\w+)\}/g, (m, k) => vars[k] === undefined ? m : vars[k])
        // lines whose placeholders all have a value
        const ok = (p.lines[kind] || []).filter(l => !(l.match(/\{\w+\}/g) || []).some(m => vars[m.slice(1, -1)] === ""))
        if (!ok.length) return ""
        const used = remarkUsed[kind] || []
        let fresh = ok.filter(l => used.indexOf(l) < 0)
        if (!fresh.length) { fresh = ok; remarkUsed[kind] = [] }
        const line = pick(fresh)
        remarkUsed[kind] = (remarkUsed[kind] || []).concat([line])
        return fill(line)
    }
    Process {
        id: remarksProc
        stdout: StdioCollector { onStreamFinished: if (this.text.trim()) console.log("remarks:", this.text.trim()) }
    }
    // write a new pool if the current one is older than `maxAge` ms
    function refreshRemarks(maxAge) {
        if (remarksProc.running || !info || features.remarks === false || !backend.available) return
        if (remarkPool && Date.now() - remarkPool.t * 1000 < maxAge) return
        const w = liveWeather()
        const desc = w ? w.kind + " " + w.temp + "°C in " + (w.city || "town") + (w.desc ? " (" + w.desc.trim() + ")" : "") : ""
        remarksProc.command = [backendDir + "/remarks.py", "--weather", desc]
        remarksProc.running = true
    }
    Timer {   // every 2.5 h; the first check a minute after start (not during boot)
        running: true; repeat: true
        interval: 60000
        onTriggered: { shell.refreshRemarks(9000000); interval = 9000000 }
    }

    // --- fun remarks for things happening on the computer ---------------------
    property var lastQuip: ({})
    function pick(list) { return list[Math.floor(Math.random() * list.length)] }
    function quip(kind, info) {
        if (locked || !faceWin.visible || chat.open) return
        const gap = { plugged: 120, unplugged: 120, battery: 0, late: 3600,
                      pet: 900, purr: 600, music: 600, wifiOn: 300, wifiOff: 300, btOn: 300, btOff: 300,
                      btDevice: 600, usb: 300, coffeeOn: 120, coffeeOff: 120 }[kind]
        if (gap === undefined) return
        const now = Date.now() / 1000
        if (lastQuip[kind] && now - lastQuip[kind] < gap) return
        if (kind === "pet" && Math.random() > 0.35) return   // don't comment on every pat
        lastQuip[kind] = now
        const n = info
        let text = aiLine(kind, info)
        if (!text) switch (kind) {
        case "plugged":   text = pick(["Ahh, sweet electricity. Thanks!", "Nom nom nom… charging up.",
                                       "Power snack time! " + n + "% and climbing."]); break
        case "unplugged": text = pick(["Off the leash! " + n + "% to play with.",
                                       "Going wireless! " + n + "% in the tank."]); break
        case "battery":
            text = n <= 5 ? pick(["Mayday, mayday! " + n + "% battery!", n + "%… I can see the light…"])
                 : n <= 10 ? pick(["Running on fumes here… " + n + "%", n + "%! Feed me, please!"])
                 : pick(["I'm getting a bit peckish… " + n + "% left.", "Psst, " + n + "% battery. Charger nearby?"])
            break
        case "late":      text = pick(["It's getting late… Don't stay up too long!",
                                       "Night owl mode activated.",
                                       "11 PM already? Time flies when we're having fun."]); break
        case "wifiOn":    text = pick(["Wi-Fi's back! Hello, internet 🌐", "Reconnecting to the hive mind…"]); break
        case "wifiOff":   text = pick(["Wi-Fi off. Peace and quiet 🤫", "Offline mode! Just you and me now."]); break
        case "btOn":      text = pick(["Bluetooth on! Who wants to be friends?", "Bluetooth's up 📡"]); break
        case "btOff":     text = "Bluetooth off. Bye, gadgets! 👋"; break
        case "btDevice":  text = n ? pick(["Ooh, " + n + " connected! 🎧", "Hi there, " + n + "!"]) : "A new friend connected!"; break
        case "usb":       text = n ? pick(["Something plugged in: " + n + "!", "Ooh, a " + n + "! What's that for? 👀"])
                                   : pick(["Ooh, something new plugged in! 👀", "A USB visitor!"]); break
        case "coffeeOn":  text = pick(["☕ Coffee time! I'll keep the screen awake.", "☕ Wide awake! No sleeping for this computer."]); break
        case "coffeeOff": text = pick(["*yawn* Okay, back to normal sleep rules.", "Caffeine's worn off… sleeping is allowed again."]); break
        case "pet":       text = pick(["Hehe, that tickles! 😆", "Oh, hello there! 😊", "Boop!"]); break
        case "purr":      text = pick(["Purrrrr… 💕", "Hehe, more please! 🥰", "That's the spot! 💕"]); break
        case "music":     text = info.title
                              ? pick(["🎶 Ooh, “" + info.title + "”" + (info.artist ? " by " + info.artist : "") + "! Good taste.",
                                      "🎧 " + (info.artist || "This one") + "! Let me bop along.",
                                      "Music time! 🎶 “" + info.title + "”"])
                              : "Music time! 🎶"
                          break
        }
        if (text) balloon.say(text, { ms: 5000 })
    }

    // what's playing (MPRIS): one comment when the user *starts* playing
    // something after a real break (not on every song change, not when
    // resuming from a short pause). The metadata of a new track arrives in
    // pieces, so it's read a moment later, once it has settled.
    readonly property bool anyPlaying: Mpris.players.values.some(p => p.isPlaying)
    property real stoppedAt: 0           // 0 = nothing played since start
    onAnyPlayingChanged: {
        if (!anyPlaying) { stoppedAt = Date.now(); musicStart.stop(); return }
        if (!sysReady) return                                      // already playing at login
        if (stoppedAt && Date.now() - stoppedAt < 120000) return   // just a pause
        musicStart.restart()
    }
    Timer {
        id: musicStart
        interval: 2000
        onTriggered: {
            const p = Mpris.players.values.find(p => p.isPlaying)
            if (!p || shell.fullscreen) return
            shell.quip("music", { title: p.trackTitle || "", artist: p.trackArtist || "" })
        }
    }

    // --- speech balloon ------------------------------------------------------
    Balloon {
        id: balloon
        // just under the robot, its tail pointing at it
        margins.top: (shell.cfg.position?.marginTop ?? 0) + 36 + (shell.zoom - 1) * 40
        margins.right: (shell.cfg.position?.marginRight ?? 0) + 4
        suppressed: chat.open || remoteMenu.open || !faceWin.visible || shell.locked
        muted: !shell.balloonsOn
        onActivated: item => shell.openSession(item.action)
    }
    function openSession(path) {
        chat.showSession(path)
        if (!chat.open) toggleChat()
    }

    readonly property string userName: cfg.name ?? ""
    function timeGreeting() {
        const h = new Date().getHours()
        const n = userName ? ", " + userName : ""
        if (h >= 5 && h < 12) return "Good morning" + n + "! ☀️"
        if (h >= 12 && h < 19) return "Good afternoon" + n + "!"
        if (h >= 19 && h < 23) return "Good evening" + n + "! 🌙"
        return "Up late" + n + "? 🦉"
    }
    // only worth saying when something's off
    function statusLine() {
        return remoteOn ? "" : serviceLabel + " is asleep. Click me to wake it."
    }

    // greet once per boot ($XDG_RUNTIME_DIR is wiped on reboot); a short gap
    // since we were last alive means it was a restart
    Process {
        id: bootCheck
        running: true
        command: ["sh", "-c", 'r="$1"; s="$2"; mkdir -p "$r" "$s"; touch "$r/events" "$r/sys" "$r/pointer"; [ -e "$r/greeted" ] && { echo seen; exit; }; touch "$r/greeted"; echo new; cut -d" " -f1 /proc/uptime; cat "$s/seen" 2>/dev/null || echo 0',
                  "sh", shell.runDir, shell.stateHome]
        stdout: StdioCollector {
            onStreamFinished: {
                eventsFile.reload(); sysFile.reload(); pointerFile.reload()
                const l = this.text.trim().split("\n")
                if (l[0] !== "new") return
                const uptime = parseFloat(l[1]), lastSeen = parseInt(l[2]) || 0
                if (uptime > 900) return   // started by hand later, not at boot
                const bootTime = Date.now() / 1000 - uptime
                greetTimer.restarted = lastSeen > 0 && bootTime - lastSeen < 900
                greetTimer.start()
            }
        }
    }
    Timer {
        id: greetTimer
        property bool restarted: false
        interval: 2500   // let the desktop settle first
        onTriggered: {
            if (restarted) return   // just a restart of the robot: nothing to say
            // the weather may still be loading right after boot: wait a little for it
            if (shell.weatherOn && !shell.weather && waited < 4) { waited++; restart(); return }
            shell.greet(shell.timeGreeting(), shell.statusLine())
            if (!shell.city && shell.features.weather !== false) askCity.start()
        }
        property int waited: 0
    }
    Timer {   // once per boot, if no city is set yet
        id: askCity
        interval: 12000
        onTriggered: balloon.say("Want weather updates? Right-click me and tell me your city 🌦️", { ms: 7000 })
    }
    Timer {   // remember when we were last alive
        running: true; repeat: true; interval: 60000
        onTriggered: Quickshell.execDetached(["sh", "-c", 'mkdir -p "$1" && date +%s > "$1/seen"', "sh", shell.stateHome])
    }

    // unlocked = the screen locker (hyprlock, swaylock, … see `lockers`) went away
    property bool locked: false
    property var awayTitles: []
    Process {
        id: lockCheck
        command: ["pgrep", "^(" + (shell.cfg.lockers ?? ["hyprlock", "swaylock"]).join("|") + ")$"]
        onExited: code => shell.locked = code === 0
    }
    Timer { running: true; repeat: true; interval: 2000; onTriggered: if (!lockCheck.running) lockCheck.running = true }
    onLockedChanged: {
        if (locked) { awayTitles = []; return }
        const hellos = ["Welcome back!", "There you are!", "Missed you!", "Hey, welcome back!"]
        const n = awayTitles.length
        const text = n === 0 ? statusLine()
                   : n === 1 ? "While you were away, \u201c" + awayTitles[0] + "\u201d finished."
                   : "While you were away, " + n + " sessions finished: "
                     + awayTitles.slice(0, 3).map(t => "\u201c" + t + "\u201d").join(", ") + "."
        greet(hellos[Math.floor(Math.random() * hellos.length)], text)
        awayTitles = []
    }

    // AI sessions (from the adapters / `visor signal`): answer ready, needs approval, error.
    // An event names its chat by `transcript` (the backend summarises it) or
    // carries its own `title` and `text`.
    FileView {
        id: eventsFile
        path: shell.runDir + "/events"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: shell.readEvents()
    }
    property int eventsSeen: -1
    property var turnStart: ({})
    property var lastAsk: ({})
    property var pendingSummaries: []
    property bool summarizing: false

    function readEvents() {
        const lines = eventsFile.text().split("\n").filter(l => l.trim() !== "")
        if (eventsSeen < 0 || lines.length < eventsSeen) { eventsSeen = lines.length; return }
        for (const l of lines.slice(eventsSeen)) {
            let e
            try { e = JSON.parse(l) } catch (x) { continue }
            handleEvent(e)
        }
        eventsSeen = lines.length
    }
    function handleEvent(e) {
        const key = e.transcript || e.sid || e.title || ""
        if (e.kind === "start") { turnStart[key] = e.t; return }
        if (e.kind === "stop") {
            if (turnStart[key] !== undefined && e.t - turnStart[key] < 20) return   // quick replies: no shout
            if (e.transcript && chat.open && chat.transcript === e.transcript) return  // already looking at it
        }
        if (e.kind === "ask") {   // two hooks report the same prompt
            if (lastAsk[key] && e.t - lastAsk[key] < 10) return
            lastAsk[key] = e.t
        }
        if (!e.transcript) { announce(e, { title: e.title || e.source || backend.name, last: e.text || "" }); return }
        pendingSummaries.push(e)
        if (!summarizing) nextSummary()
    }
    Process {
        id: sumProc
        property var ev: null
        stdout: StdioCollector {
            onStreamFinished: {
                let s = { title: sumProc.ev.source || shell.backend.name, last: "" }
                try { s = JSON.parse(this.text) } catch (x) {}
                shell.announce(sumProc.ev, s)
            }
        }
        onExited: { shell.summarizing = false; Qt.callLater(shell.nextSummary) }
    }
    function nextSummary() {
        const e = pendingSummaries.shift()
        if (!e) return
        summarizing = true
        sumProc.ev = e
        sumProc.command = [helper, "summary", e.transcript, e.source || ""]
        sumProc.running = true
    }
    function announce(e, s) {
        if (e.kind === "stop" && locked) { awayTitles = awayTitles.concat([s.title]); return }
        // clicking it opens the chat in the popup when the popup's backend owns it
        const mine = e.transcript && (!e.source || e.source === backend.id)
        const q = "\u201c" + s.title + "\u201d"
        const snippet = s.last.length > 90 ? s.last.substring(0, 88).replace(/\s+\S*$/, "") + "\u2026" : s.last
        const look = mine ? " Click me to have a look." : ""
        const text = e.kind === "stop" ? q + " is done" + (snippet ? ": " + snippet : "!")
                   : e.kind === "ask" ? q + " needs your approval." + look
                   : q + " hit an error." + look
        balloon.say(text, { ms: e.kind === "ask" ? 12000 : 8000, action: mine ? e.transcript : "" })
    }

    PanelWindow {
        id: faceWin
        // step aside for fullscreen windows (videos, games)
        visible: !shell.fullscreen

        anchors {
            top: true
            right: true
        }
        // Waybar: margin-top 6, height 34 -> vertical centre at y 23
        // extra room above and to the right (screen edge) for the zzz/notes to
        // float into; only the robot itself takes clicks
        margins {
            top: shell.cfg.position?.marginTop ?? 0
            right: shell.cfg.position?.marginRight ?? 0
        }
        implicitWidth: 52 * shell.zoom + 10
        implicitHeight: 40 * shell.zoom + 3
        mask: Region { item: holder }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        // the keyboard only while typing the weather city in the menu
        WlrLayershell.keyboardFocus: remoteMenu.editing ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        Item {
            id: holder
            x: 0; y: 3
            width: 52 * shell.zoom
            height: 40 * shell.zoom

            Face {
                id: face
                anchors.centerIn: parent
                // 72x58 artwork -> ~40x32, inside the 34px bar
                scale: (mouse.containsMouse || chat.open ? 0.6 : 0.555) * shell.zoom
                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
                mood: stateFile.text().trim() || "idle"
                remoteOn: shell.remoteOn
                batteryName: shell.info ? shell.info.power.battery : ""
                acName: shell.info ? shell.info.power.ac : ""
                night: shell.cfg.night ?? null
                talking: balloon.typing
                onRemark: (kind, info) => shell.quip(kind, info)
                waking: shell.waking
                sysIdle: idleMon.isIdle
                musicPlaying: Mpris.players.values.some(p => p.isPlaying)
                eyeOriginX: (faceWin.screen ? faceWin.screen.width : 1920) - faceWin.margins.right - 31 * shell.zoom
                eyeOriginY: faceWin.margins.top + 23
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                property real lastX: 0
                onContainsMouseChanged: {
                    face.hovered = containsMouse
                    if (containsMouse) lastX = mouseX
                }
                onPositionChanged: mouse => {
                    face.handX = Math.max(-1, Math.min(1, mouse.x / width * 2 - 1))
                    face.stroke(mouse.x - lastX)
                    lastX = mouse.x
                }
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        chat.open = false
                        remoteMenu.open = !remoteMenu.open
                    } else {
                        remoteMenu.open = false
                        shell.remoteOn ? shell.toggleChat() : shell.wakeRemote()
                    }
                }
            }
        }
    }
}
