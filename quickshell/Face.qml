import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell.Io

// Robot-helmet companion. Set `mood` from outside:
// idle | thinking | working | input | done | error | love | sleep | nervous | battery
// Ambient (shown while the AI is idle): music, sleep when the user is away;
// the idle face gets sleepier towards night (`sleepiness`) and follows the
// mouse; "yawn" peeks in on waking and at night. "sys" peeks show system
// events (volume, brightness, wifi, bluetooth, devices, keep-awake).
Item {
    id: root

    property string mood: "idle"
    property string shown: "idle"

    implicitWidth: 72
    implicitHeight: 58

    property string icon: ""             // "" (face) | bubble | question | battery
    property string eyeStyle: "oval"     // oval | happy | closed | heart | angry | x | chevron
    property string mouthStyle: "curve"  // curve | o | open | wavy
    property real eyeOpen: 1
    property real smile: 0.6
    property real lookX: 0
    property real lookY: 0
    property real blink: 1
    property real tilt: 0
    property real bob: 1.2 * Math.sin(clock * Math.PI / 1.4)   // gentle hover, 2.8 s period
    property real glow: 1
    property color accent: "#45e3ff"

    Behavior on eyeOpen { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    Behavior on smile   { NumberAnimation { duration: 320; easing.type: Easing.OutBack } }
    Behavior on lookX   { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }
    Behavior on lookY   { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }
    Behavior on tilt    { NumberAnimation { duration: 400; easing.type: Easing.OutBack } }
    Behavior on accent  { ColorAnimation  { duration: 400 } }

    readonly property var table: ({
        idle:     { icon: "",         eyes: "oval",    mouth: "curve", eye: 1.0,  smile: 0.6,  color: "#45e3ff", roam: 0.6,  bx: 0.0, by: 0.0,  glanceMs: 2200, tilt: 0,  glow: 1.0 },
        thinking: { icon: "bubble",   eyes: "oval",    mouth: "curve", eye: 0.7,  smile: 0.0,  color: "#a78bfa", roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 3000, tilt: 5,  glow: 0.9 },
        working:  { icon: "",         eyes: "oval",    mouth: "curve", eye: 1.0,  smile: 0.3,  color: "#4fb8ff", roam: 1.0,  bx: 0.0, by: 0.2,  glanceMs: 450,  tilt: 0,  glow: 1.0 },
        input:    { icon: "question", eyes: "oval",    mouth: "o",     eye: 1.25, smile: 0.0,  color: "#ffb347", roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 1500, tilt: -5, glow: 1.0 },
        done:     { icon: "",         eyes: "chevron", mouth: "open",  eye: 1.0,  smile: 1.0,  color: "#5dffa0", roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 4000, tilt: 0,  glow: 1.0 },
        error:    { icon: "",         eyes: "x",       mouth: "curve", eye: 1.0,  smile: -0.6, color: "#ff3b5c", roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 2000, tilt: 0,  glow: 1.0 },
        love:     { icon: "",         eyes: "heart",   mouth: "curve", eye: 1.0,  smile: 0.8,  color: "#ff5c8a", roam: 0.2,  bx: 0.0, by: 0.0,  glanceMs: 2500, tilt: 4,  glow: 1.0 },
        sleep:    { icon: "",         eyes: "closed",  mouth: "curve", eye: 1.0,  smile: 0.0,  color: "#45e3ff", roam: 0.0,  bx: -1.2, by: 0.6, glanceMs: 5000, tilt: -6, glow: 0.4 },
        nervous:  { icon: "",         eyes: "oval",    mouth: "wavy",  eye: 0.9,  smile: 0.0,  color: "#45e3ff", roam: 0.5,  bx: 0.0, by: 0.0,  glanceMs: 350,  tilt: 0,  glow: 0.8 },
        pet:      { icon: "",         eyes: "happy",   mouth: "open",  eye: 1.0,  smile: 1.0,  color: "#ff8fb1", roam: 0.0,  bx: 0.0, by: -0.3, glanceMs: 4000, tilt: 0,  glow: 1.0 },
        music:    { icon: "",         eyes: "closed",  mouth: "curve", eye: 1.0,  smile: 0.8,  color: "#5ef2d0", roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 4000, tilt: 0,  glow: 1.0 },
        drowsy:   { icon: "",         eyes: "oval",    mouth: "curve", eye: 0.5,  smile: 0.15, color: "#45e3ff", roam: 0.2,  bx: 0.0, by: 0.4,  glanceMs: 4500, tilt: -3, glow: 0.55 },
        curious:  { icon: "",         eyes: "oval",    mouth: "o",     eye: 1.3,  smile: 0.0,  color: "#7cf0ff", roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 4000, tilt: 9,  glow: 1.0 },
        sys:      { icon: "sys",      eyes: "oval",    mouth: "curve", eye: 1.0,  smile: 0.5,  color: "",        roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 4000, tilt: 0,  glow: 1.0 },
        yawn:     { icon: "",         eyes: "closed",  mouth: "yawn",  eye: 1.0,  smile: 0.0,  color: "#45e3ff", roam: 0.0,  bx: 0.0, by: -0.5, glanceMs: 4000, tilt: -8, glow: 0.7 },
        greet:    { icon: "",         eyes: "happy",   mouth: "open",  eye: 1.0,  smile: 1.0,  color: "#45e3ff", roam: 0.0,  bx: -0.6, by: 0.2, glanceMs: 4000, tilt: 5,  glow: 1.0 },
        off:      { icon: "",         eyes: "closed",  mouth: "curve", eye: 1.0,  smile: 0.0,  color: "#7f849c", roam: 0.0,  bx: 0.0, by: 0.8,  glanceMs: 8000, tilt: -10, glow: 0.12 },
        // weather (peeked in when it fits; `fx` adds the effect)
        sunny:    { icon: "",         eyes: "oval",    mouth: "curve", eye: 1.0,  smile: 0.9,  color: "#ffd166", roam: 0.3,  bx: 0.0, by: 0.0,  glanceMs: 2500, tilt: 4,  glow: 1.0, fx: "sun" },
        rainy:    { icon: "",         eyes: "oval",    mouth: "curve", eye: 0.9,  smile: -0.25, color: "#5ab0ff", roam: 0.2, bx: 0.0, by: -1.0, glanceMs: 2000, tilt: 0,  glow: 0.9, fx: "rain" },
        cloudy:   { icon: "",         eyes: "oval",    mouth: "curve", eye: 0.75, smile: 0.05, color: "#9fb4c7", roam: 0.2,  bx: 0.0, by: 0.6,  glanceMs: 3000, tilt: -3, glow: 0.7, fx: "cloud" },
        snowy:    { icon: "",         eyes: "happy",   mouth: "open",  eye: 1.0,  smile: 0.9,  color: "#dff6ff", roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 3000, tilt: 3,  glow: 1.0, fx: "snow" },
        stormy:   { icon: "",         eyes: "oval",    mouth: "o",     eye: 1.3,  smile: 0.0,  color: "#b388ff", roam: 0.5,  bx: 0.0, by: 0.0,  glanceMs: 500,  tilt: -4, glow: 1.0, fx: "storm" },
        hot:      { icon: "",         eyes: "oval",    mouth: "wavy",  eye: 0.6,  smile: 0.0,  color: "#ff8a5c", roam: 0.1,  bx: 0.0, by: 0.4,  glanceMs: 3000, tilt: -5, glow: 1.0, fx: "sweat" },
        cold:     { icon: "",         eyes: "closed",  mouth: "wavy",  eye: 1.0,  smile: 0.0,  color: "#9ad8ff", roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 3000, tilt: 0,  glow: 0.9, fx: "shiver" },
        foggy:    { icon: "",         eyes: "oval",    mouth: "curve", eye: 0.6,  smile: 0.0,  color: "#a8b0b8", roam: 0.4,  bx: 0.0, by: 0.0,  glanceMs: 2500, tilt: 0,  glow: 0.5, fx: "fog" },
        battery:  { icon: "battery",  eyes: "oval",    mouth: "curve", eye: 1.0,  smile: 0.0,  color: "",        roam: 0.0,  bx: 0.0, by: 0.0,  glanceMs: 4000, tilt: 0,  glow: 1.0 }
    })

    // Things worth a comment in the speech balloon (the shell picks the words):
    // plugged / unplugged / battery (level) / late / pet / purr
    signal remark(string kind, var info)

    property string fx: ""          // weather effect of the face being shown
    property real shiver: 0
    SequentialAnimation on shiver {
        running: root.fx === "shiver"
        loops: Animation.Infinite
        NumberAnimation { to: 1.4;  duration: 45 }
        NumberAnimation { to: -1.4; duration: 45 }
        onRunningChanged: if (!running) root.shiver = 0
    }

    // --- talking ------------------------------------------------------------
    // While the speech balloon is writing, the mouth flaps open and shut.
    property bool talking: false
    property bool talkOpen: false
    readonly property string mouthNow: talking && talkOpen ? "o" : mouthStyle
    Timer {
        running: root.talking
        repeat: true
        interval: 140
        onTriggered: { root.talkOpen = !root.talkOpen && Math.random() > 0.2; interval = 90 + Math.random() * 110 }
        onRunningChanged: if (!running) root.talkOpen = false
    }

    // --- the service (optional) -------------------------------------------
    // With a service configured, the robot *is* that service: when it isn't
    // running it is fully asleep ("off") and nothing else moves it; while it
    // is being started (`waking`) it yawns. Set from outside.
    property bool remoteOn: true
    property bool waking: false
    onRemoteOnChanged: {
        revertTimer.stop()
        if (remoteOn) { shown = "yawn"; revertTimer.interval = 3500; revertTimer.restart() }   // stretch, then back to work
        else shown = baseMood()
    }
    onWakingChanged: if (!remoteOn) shown = baseMood()

    // --- petting -----------------------------------------------------------
    // Hovering = being petted: happy eyes, blush, leaning into the hand.
    // Stroking back and forth builds `petEnergy`; past a threshold it purrs
    // (wiggles, heart eyes, brighter glow). Set from outside: hovered, handX, stroke().
    property bool hovered: false
    property real handX: 0          // -1 (left) .. 1 (right)
    property real petEnergy: 0
    readonly property bool petting: remoteOn && (hovered || petLinger.running)
    readonly property bool purring: petting && petEnergy > 1.2
    property real wiggle: 0

    function stroke(dx) { petEnergy = Math.min(3, petEnergy + Math.abs(dx) / 60) }

    onHoveredChanged: if (!hovered) petLinger.restart()
    onPettingChanged: apply()
    // only real petting (stroking it back and forth) may get a comment, never
    // just passing over it
    readonly property bool stroked: petting && petEnergy > 0.6
    onStrokedChanged: if (stroked) remark("pet", null)
    onPurringChanged: { apply(); if (purring) remark("purr", null) }
    onHandXChanged: if (petting) { lookX = handX * 1.2; lookY = -0.3 }

    Timer { id: petLinger; interval: 1200 }
    Timer {   // affection fades when the stroking stops
        running: root.petEnergy > 0
        repeat: true
        interval: 50
        onTriggered: root.petEnergy = Math.max(0, root.petEnergy - (root.hovered ? 0.03 : 0.08))
    }
    SequentialAnimation on wiggle {
        running: root.purring
        loops: Animation.Infinite
        NumberAnimation { to: 2.5;  duration: 70 }
        NumberAnimation { to: -2.5; duration: 70 }
        onRunningChanged: if (!running) root.wiggle = 0
    }

    function current() { return table[petting ? "pet" : shown] || table.idle }

    // how sleepy the resting face is right now (0 day .. 1 middle of the night)
    readonly property real drowse: (!petting && shown === "idle") ? sleepiness : 0
    function apply() {
        const m = current()
        icon = m.icon
        eyeStyle = purring ? "heart" : m.eyes
        mouthStyle = m.mouth
        eyeOpen = m.eye * (1 - 0.55 * drowse)
        smile = m.smile * (1 - 0.7 * drowse)
        accent = m.color || (shown === "sys" ? sysColor : battColor)
        tilt = m.tilt - 4 * drowse
        glow = m.glow * (1 - 0.45 * drowse)
        fx = petting ? "" : (m.fx || "")
        glance()
    }
    onDrowseChanged: apply()

    // --- following the mouse -------------------------------------------------
    // Set from outside: the pointer in screen coordinates and where the robot
    // sits. The resting (and curious) face looks at it while it's moving.
    property real cursorX: -1
    property real cursorY: -1
    property real eyeOriginX: 1890
    property real eyeOriginY: 23
    property real cursorAt: 0           // ms of the last movement
    readonly property bool watching: !petting && (shown === "idle" || shown === "curious")
    function lookAtCursor() {
        if (cursorX < 0 || Date.now() - cursorAt > 6000) return false
        const dx = cursorX - eyeOriginX, dy = cursorY - eyeOriginY
        // the robot sits in the top-right corner, so almost everything is
        // down-left: spread that range over the eyes' full travel
        lookX = Math.max(-1.3, Math.min(0.8, dx / 700))
        lookY = Math.max(-0.4, Math.min(1.3, dy / 420))
        return true
    }
    onCursorAtChanged: if (watching) lookAtCursor()

    function glance() {
        if (petting) { lookX = handX * 1.2; lookY = -0.3; return }
        if (watching && lookAtCursor()) return
        const m = current()
        lookX = m.bx + (Math.random() * 2 - 1) * m.roam
        lookY = m.by + 0.5 * drowse + (Math.random() * 2 - 1) * m.roam * 0.3
    }

    // a quick tilted "hm?" when the user clicks somewhere (not every time)
    function curious() {
        if (!remoteOn || petting || (shown !== "idle" && shown !== "curious")) return
        peek("curious", false, 1600)
        lookAtCursor()
    }

    // --- system events -------------------------------------------------------
    property real sysBump: 1
    property real sysRing: 1
    property real sysDrop: 0
    property real sysWobble: 0
    onSysSerialChanged: { sysAnim.restart() }
    ParallelAnimation {
        id: sysAnim
        SequentialAnimation {
            NumberAnimation { target: root; property: "sysBump"; to: 1.28; duration: 90; easing.type: Easing.OutQuad }
            NumberAnimation { target: root; property: "sysBump"; to: 1; duration: 260; easing.type: Easing.OutBack }
        }
        NumberAnimation { target: root; property: "sysRing"; from: 0; to: 1; duration: 700; easing.type: Easing.OutCubic }
        SequentialAnimation {   // switching off: the icon sags
            PropertyAction { target: root; property: "sysDrop"; value: 0 }
            NumberAnimation { target: root; property: "sysDrop"; to: 1; duration: 450; easing.type: Easing.OutBounce }
        }
        SequentialAnimation {   // a plugged device wiggles in
            NumberAnimation { target: root; property: "sysWobble"; to: 1; duration: 80 }
            NumberAnimation { target: root; property: "sysWobble"; to: -1; duration: 120 }
            NumberAnimation { target: root; property: "sysWobble"; to: 0; duration: 160; easing.type: Easing.OutBack }
        }
    }
    // sysEvent(kind, on, level): wifi | bt | btdev | vol | bright | usb | coffee
    // pops a glowing icon on the visor for a moment (level 0..1, or -1 = none)
    property string sysKind: ""
    property bool sysOn: true
    property real sysLevel: -1
    property int sysSerial: 0
    readonly property color sysColor: ({ wifi: "#4fb8ff", bt: "#6f8cff", btdev: "#6f8cff", vol: "#5ef2d0",
                                         bright: "#ffd166", usb: "#c3a6ff", coffee: "#e0a96d",
                                         screen: "#c026ff" })[sysKind] || "#45e3ff"
    readonly property string sysGlyph: {
        switch (sysKind) {
        case "wifi":   return sysOn ? "\u{f05a9}" : "\u{f05aa}"
        case "bt":     return sysOn ? "\u{f00af}" : "\u{f00b2}"
        case "btdev":  return sysOn ? "\u{f00b1}" : "\u{f00b2}"
        case "vol":    return !sysOn || sysLevel <= 0 ? "\u{f075f}" : sysLevel < 0.34 ? "\u{f057f}" : sysLevel < 0.67 ? "\u{f0580}" : "\u{f057e}"
        case "bright": return sysLevel < 0.5 ? "\u{f00de}" : "\u{f00e0}"
        case "usb":    return "\u{f0553}"
        case "coffee": return sysOn ? "\u{f0176}" : "\u{f04b2}"
        case "screen": return "\u{f0379}"
        }
        return ""
    }
    function sysEvent(kind, on, level, ms) {
        if (!remoteOn) return
        sysKind = kind; sysOn = on; sysLevel = level === undefined ? -1 : level
        sysSerial++
        if (shown === "sys") { accent = sysColor; revertTimer.interval = ms || 1800; revertTimer.restart(); return }
        peek("sys", true, ms || 1800)
    }

    // --- ambient life ------------------------------------------------------
    // Set from outside: musicPlaying (MPRIS), sysIdle (user away). The clock
    // is read here. These only colour the face while the AI itself is idle.
    property bool musicPlaying: false
    property bool sysIdle: false
    property int hour: new Date().getHours()
    property real hourF: new Date().getHours() + new Date().getMinutes() / 60
    // night.{sleepyFrom, asleepFrom, asleepUntil, awakeBy, lateHour} (hours; set from outside)
    property var night: null
    readonly property int lateHour: night?.lateHour ?? 23
    readonly property bool late: hour >= lateHour || hour < 6
    // 0 by day; from sleepyFrom (21:00) the eyes start drooping, fully sleepy
    // asleepFrom–asleepUntil (00:30–05:00), awake again by awakeBy (07:00)
    function nightH(v, d) { const x = v ?? d; return x < 12 ? x + 24 : x }
    readonly property real sleepiness: {
        const h = hourF < 12 ? hourF + 24 : hourF
        const a = nightH(night?.sleepyFrom, 21), b = nightH(night?.asleepFrom, 0.5)
        const c = nightH(night?.asleepUntil, 5), d = nightH(night?.awakeBy, 7)
        if (h < a) return 0
        if (h < b) return (h - a) / Math.max(0.01, b - a)
        if (h < c) return 1
        if (h < d) return (d - h) / Math.max(0.01, d - c)
        return 0
    }
    readonly property var calmStates: ["idle", "sleep", "music", "drowsy", "curious"]

    Timer {
        running: true
        repeat: true
        interval: 60000
        onTriggered: { const d = new Date(); root.hour = d.getHours(); root.hourF = d.getHours() + d.getMinutes() / 60 }
    }

    function baseMood() {
        if (!remoteOn) return waking ? "yawn" : "off"
        // done / error / battery are moments, not states: shown briefly, then idle
        const m = (mood === "done" || mood === "battery" || mood === "error") ? "idle" : mood
        if (m !== "idle") return m
        if (sysIdle) return "sleep"
        if (musicPlaying) return "music"
        return "idle"   // time of day no longer changes the resting face; see onLate/onMorning
    }
    function refreshAmbient() {
        if (revertTimer.running) return
        if (calmStates.indexOf(shown) >= 0) shown = baseMood()
    }
    onMusicPlayingChanged: refreshAmbient()
    // late at night: a word in the balloon (the face itself is sleepy already)
    onLateChanged: if (late && !sysIdle) remark("late", null)
    onSysIdleChanged: {
        if (!sysIdle && shown === "sleep" && mood === "idle") peek("yawn", true)   // stretch on waking
        else refreshAmbient()
    }

    // the yawn itself: mouth opens slowly, holds, snaps shut (repeats while
    // the yawn face stays, e.g. while Remote Control is waking up)
    property real yawnOpen: 0
    SequentialAnimation on yawnOpen {
        running: root.mouthStyle === "yawn"
        loops: Animation.Infinite
        NumberAnimation { from: 0; to: 0.35; duration: 350; easing.type: Easing.OutQuad }
        NumberAnimation { to: 1; duration: 1000; easing.type: Easing.InOutSine }
        PauseAnimation { duration: 700 }
        NumberAnimation { to: 0.05; duration: 650; easing.type: Easing.InOutQuad }
        PauseAnimation { duration: 1400 }
        onRunningChanged: if (!running) root.yawnOpen = 0
    }

    // a yawn now and then at night
    Timer {
        running: root.sleepiness > 0.45 && !root.sysIdle
        repeat: true
        interval: 600000
        onTriggered: {
            if (root.shown === "idle" || root.shown === "drowsy") root.peek("yawn", false)
            interval = 480000 + Math.random() * 420000
        }
    }

    onMoodChanged: {
        if (!remoteOn) return
        if (mood === "done" || mood === "battery") { shown = mood; revertTimer.interval = 3500; revertTimer.restart() }
        else if (mood === "error") { shown = "error"; revertTimer.interval = 4000; revertTimer.restart() }
        else shown = baseMood()
    }
    onShownChanged: apply()
    Component.onCompleted: { shown = baseMood(); apply(); if (lowBatt) peek("battery", false) }

    // transient moods ("done", battery peeks) fall back to the requested mood
    Timer {
        id: revertTimer
        interval: 3500
        onTriggered: root.shown = root.baseMood()
    }

    // --- battery -------------------------------------------------------
    // The battery never owns the face: it peeks in for a few seconds when the
    // charger is (un)plugged, when the level drops past 20/10/5 %, and every
    // few minutes while low and nothing else is going on.
    // /sys/class/power_supply names (detected by chat.py info; "" = none, e.g. a desktop)
    property string batteryName: ""
    property string acName: ""
    readonly property string psDir: "/sys/class/power_supply/"
    FileView { id: battCap;  path: root.batteryName ? root.psDir + root.batteryName + "/capacity" : ""; blockLoading: true; printErrors: false }
    FileView { id: battStat; path: root.batteryName ? root.psDir + root.batteryName + "/status" : "";   blockLoading: true; printErrors: false }
    FileView { id: acOnline; path: root.acName ? root.psDir + root.acName + "/online" : "";             blockLoading: true; printErrors: false }
    function readPower() { if (batteryName) { battCap.reload(); battStat.reload() } if (acName) acOnline.reload() }
    onBatteryNameChanged: readPower()
    // the kernel announces (un)plugging and level changes as power_supply
    // uevents, so react to those right away instead of waiting for a poll
    Process {
        id: udev
        running: root.batteryName !== ""
        command: ["udevadm", "monitor", "--kernel", "--subsystem-match=power_supply"]
        stdout: SplitParser { onRead: powerSettle.restart() }
        onRunningChanged: if (!running) restartUdev.start()
    }
    Timer { id: restartUdev; interval: 5000; onTriggered: udev.running = root.batteryName !== "" }
    Timer {   // several uevents arrive together; the battery status follows a moment later
        id: powerSettle
        interval: 80
        onTriggered: { root.readPower(); powerFollowUp.restart() }
    }
    Timer { id: powerFollowUp; interval: 1500; onTriggered: root.readPower() }
    Timer {   // fallback, in case the uevent stream isn't there
        running: true
        repeat: true
        interval: 30000
        onTriggered: root.readPower()
    }
    readonly property int battLevel: parseInt(battCap.text()) || 0
    // the charger flips the instant the cable goes in; the battery's status lags and says
    // "Not charging"/"Full" when plugged in at the charge limit
    readonly property bool charging: acOnline.text().trim() === "1" || battStat.text().trim() === "Charging"
    readonly property bool lowBatt: battLevel > 0 && battLevel <= 20 && !charging
    readonly property int battBand: charging || battLevel <= 0 ? 0 : battLevel <= 5 ? 3 : battLevel <= 10 ? 2 : battLevel <= 20 ? 1 : 0
    readonly property color battColor: charging ? "#5dffa0" : battLevel <= 20 ? "#ff5a3c" : battLevel <= 40 ? "#ffb347" : "#5dffa0"
    onBattColorChanged: if (shown === "battery") accent = battColor

    // Briefly show a transient state, then fall back to baseMood().
    // urgent = a real change worth interrupting a busy (not blocked) face for.
    function peek(name, urgent, ms) {
        if (!remoteOn) return
        if (shown === "input" || shown === "error") return
        if (!urgent && calmStates.indexOf(shown) < 0) return
        revertTimer.interval = ms || 3500
        if (shown === name) { revertTimer.restart(); return }
        shown = name
        revertTimer.restart()
    }
    property int _lastBand: battBand
    onChargingChanged: { peek("battery", true); remark(charging ? "plugged" : "unplugged", battLevel) }
    onBattBandChanged: {
        if (battBand > _lastBand) { peek("battery", true); remark("battery", battLevel) }
        _lastBand = battBand
    }
    Timer {
        running: root.lowBatt
        repeat: true
        interval: 300000
        onTriggered: root.peek("battery", false)
    }

    // --- life ------------------------------------------------------------
    Timer {
        running: true
        repeat: true
        interval: 1000
        onTriggered: {
            root.glance()
            interval = root.current().glanceMs * (0.6 + Math.random() * 0.8)
        }
    }

    Timer {
        running: root.shown !== "sleep" && root.shown !== "off"
        repeat: true
        interval: 3000
        onTriggered: {
            blinkAnim.restart()
            interval = 2000 + Math.random() * 4000
        }
    }
    SequentialAnimation {
        id: blinkAnim
        NumberAnimation { target: root; property: "blink"; to: 0.08; duration: 70; easing.type: Easing.InQuad }
        NumberAnimation { target: root; property: "blink"; to: 1.0;  duration: 120; easing.type: Easing.OutQuad }
    }

    // nodding to the music
    property real beat: 0
    property real sway: 0
    SequentialAnimation on beat {
        running: root.shown === "music" && !root.petting
        loops: Animation.Infinite
        NumberAnimation { to: 1; duration: 270; easing.type: Easing.OutQuad }
        NumberAnimation { to: 0; duration: 270; easing.type: Easing.InQuad }
        onRunningChanged: if (!running) root.beat = 0
    }
    SequentialAnimation on sway {
        running: root.shown === "music" && !root.petting
        loops: Animation.Infinite
        NumberAnimation { to: 4;  duration: 1080; easing.type: Easing.InOutSine }
        NumberAnimation { to: -4; duration: 1080; easing.type: Easing.InOutSine }
        onRunningChanged: if (!running) root.sway = 0
    }

    SequentialAnimation {
        loops: Animation.Infinite
        running: root.shown === "input"
        NumberAnimation { target: root; property: "glow"; to: 0.35; duration: 500; easing.type: Easing.InOutSine }
        NumberAnimation { target: root; property: "glow"; to: 1.0;  duration: 500; easing.type: Easing.InOutSine }
        onRunningChanged: if (!running) root.glow = root.current().glow
    }

    // Slow, never-ending motion (hover, zzz, notes, typing dots, "?") is driven
    // by a 30 fps clock instead of an animation: an always-running animation
    // makes Qt redraw the whole face at the display's 120 Hz.
    property real clock: 0
    Timer {
        running: true
        repeat: true
        interval: 33
        onTriggered: root.clock += 0.033
    }
    // shared phase for looping glyph animations (typing dots, zzz)
    readonly property real phase: (clock / 2.4) % 1

    // --- pieces ------------------------------------------------------------
    component Eye: Item {
        id: eye
        property string style: "oval"
        property real open: 1
        property color tint: "white"
        property bool mirrored: false
        width: 10
        height: 12

        Rectangle {
            anchors.centerIn: parent
            width: 7
            height: Math.max(1.5, 10 * eye.open)
            radius: width / 2
            color: eye.tint
            opacity: eye.style === "oval" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }
        Shape {   // ^ happy
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: eye.style === "happy" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            ShapePath {
                strokeColor: eye.tint; strokeWidth: 2.2; fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: 1; startY: 8
                PathQuad { x: 9; y: 8; controlX: 5; controlY: 0 }
            }
        }
        Shape {   // ‿ closed
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: eye.style === "closed" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            ShapePath {
                strokeColor: eye.tint; strokeWidth: 2; fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: 1; startY: 6
                PathQuad { x: 9; y: 6; controlX: 5; controlY: 10 }
            }
        }
        Shape {   // heart
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: eye.style === "heart" ? 1 : 0
            scale: eye.style === "heart" ? 1 : 0.4
            Behavior on opacity { NumberAnimation { duration: 160 } }
            Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
            ShapePath {
                strokeColor: "transparent"; fillColor: eye.tint
                PathSvg { path: "M5 11 C1.5 8.5 0 6.4 0 4.2 C0 2.4 1.3 1.2 2.8 1.2 C3.8 1.2 4.6 1.8 5 2.6 C5.4 1.8 6.2 1.2 7.2 1.2 C8.7 1.2 10 2.4 10 4.2 C10 6.4 8.5 8.5 5 11 Z" }
            }
        }
        Shape {   // angry: slanted top, lower towards the nose
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: eye.style === "angry" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            transform: Scale { origin.x: 5; xScale: eye.mirrored ? -1 : 1 }
            ShapePath {
                strokeColor: "transparent"; fillColor: eye.tint
                PathSvg { path: "M1.5 2 L8.5 5.5 L8.5 8 C8.5 10 7 11.5 5 11.5 C3 11.5 1.5 10 1.5 8 Z" }
            }
        }
        Shape {   // × dead
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: eye.style === "x" ? 1 : 0
            scale: eye.style === "x" ? 1 : 0.5
            Behavior on opacity { NumberAnimation { duration: 160 } }
            Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
            ShapePath {
                strokeColor: eye.tint; strokeWidth: 2; fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathSvg { path: "M2 3 L8 9 M8 3 L2 9" }
            }
        }
        Shape {   // > <  squeezed
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: eye.style === "chevron" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            transform: Scale { origin.x: 5; xScale: eye.mirrored ? -1 : 1 }
            ShapePath {
                strokeColor: eye.tint; strokeWidth: 2.2; fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M2.5 2.5 L8 6 L2.5 9.5" }
            }
        }
    }

    // --- head ------------------------------------------------------------
    Item {
        id: head
        width: 72
        height: 58
        opacity: root.shown === "off" ? 0.7 : 1   // powered down
        Behavior on opacity { NumberAnimation { duration: 600 } }
        y: root.bob - root.beat * 1.6
        rotation: root.tilt + root.wiggle + root.sway + root.shiver + (root.petting ? root.handX * 7 : 0)
        Behavior on rotation { enabled: !root.purring && root.shown !== "music" && root.fx !== "shiver"; NumberAnimation { duration: 180; easing.type: Easing.OutQuad } }
        transformOrigin: Item.Bottom

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#99000000"
            shadowBlur: 0.4
            shadowVerticalOffset: 1.5
            shadowHorizontalOffset: 0
        }

        // ear pieces with ridges
        Repeater {
            model: 2
            Rectangle {
                x: index === 0 ? 0 : 63
                y: 18
                width: 9
                height: 22
                radius: 4
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#dfe4ea" }
                    GradientStop { position: 1.0; color: "#8995a5" }
                }
                Repeater {
                    model: 2
                    Rectangle {
                        x: (parent.x === 0 ? 2 : 4.5) + index * 2.5
                        y: 5
                        width: 1
                        height: 12
                        radius: 0.5
                        color: "#6b7686"
                        opacity: 0.6
                    }
                }
            }
        }

        // helmet shell
        Rectangle {
            id: shell
            x: 4
            y: 2
            width: 64
            height: 54
            radius: 23
            border.width: 1
            border.color: "#7f8a99"
            gradient: Gradient {
                GradientStop { position: 0.0;  color: "#ffffff" }
                GradientStop { position: 0.55; color: "#e5e9ee" }
                GradientStop { position: 1.0;  color: "#b3bbc6" }
            }

            // chin grille
            Repeater {
                model: 2
                Rectangle {
                    x: 28.5 + index * 4.5
                    y: 47
                    width: 2.5
                    height: 4.5
                    radius: 1.2
                    color: "#6b7686"
                }
            }

            // visor, tinted by the mood colour
            Rectangle {
                id: visor
                x: 7
                y: 9
                width: 50
                height: 36
                radius: 15
                clip: true
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.tint("#2b3d58", Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.30)) }
                    GradientStop { position: 1.0; color: Qt.tint("#0b1322", Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)) }
                }

                // glass highlight
                Rectangle {
                    x: 6; y: 3
                    width: 20; height: 4
                    radius: 2
                    rotation: -10
                    color: "#ffffff"
                    opacity: 0.12
                }

                Item {
                    id: glyphs
                    anchors.fill: parent
                    visible: false

                    // ---- the face
                    Item {
                        id: face
                        anchors.fill: parent
                        // weather moods show only their widget, no eyes or mouth
                        opacity: root.icon === "" && root.fx === "" ? 1 : 0
                        scale: root.icon === "" && root.fx === "" ? 1 : 0.6
                        Behavior on opacity { NumberAnimation { duration: 180 } }
                        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }

                        Eye {
                            x: 10 + root.lookX * 3
                            y: 9 + root.lookY * 2
                            style: root.eyeStyle
                            open: root.eyeOpen * root.blink
                            tint: root.accent
                        }
                        Eye {
                            x: 30 + root.lookX * 3
                            y: 9 + root.lookY * 2
                            style: root.eyeStyle
                            open: root.eyeOpen * root.blink
                            tint: root.accent
                            mirrored: true
                        }

                        Item {
                            id: mouth
                            width: parent.width
                            height: parent.height
                            x: root.lookX * 1.5
                            y: root.lookY

                            Shape {   // curve
                                anchors.fill: parent
                                preferredRendererType: Shape.CurveRenderer
                                opacity: root.mouthNow === "curve" ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 160 } }
                                ShapePath {
                                    strokeColor: root.accent; strokeWidth: 2; fillColor: "transparent"
                                    capStyle: ShapePath.RoundCap
                                    startX: 19; startY: 26
                                    PathQuad { x: 31; y: 26; controlX: 25; controlY: 26 + root.smile * 7 }
                                }
                            }
                            Rectangle {   // o
                                x: 22; y: 24
                                width: 6; height: 7
                                radius: 3
                                color: "transparent"
                                border.width: 1.8
                                border.color: root.accent
                                opacity: root.mouthNow === "o" ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 160 } }
                            }
                            Rectangle {   // yawn: opens wide, holds, then closes again
                                x: 25 - width / 2
                                y: 23 - height * 0.4
                                width: 5 + root.yawnOpen * 6
                                height: 2 + root.yawnOpen * 11
                                radius: width / 2
                                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.25)
                                border.width: 1.8
                                border.color: root.accent
                                opacity: root.mouthNow === "yawn" ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 160 } }
                            }
                            Shape {   // open D smile
                                anchors.fill: parent
                                preferredRendererType: Shape.CurveRenderer
                                opacity: root.mouthNow === "open" ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 160 } }
                                ShapePath {
                                    strokeColor: "transparent"; fillColor: root.accent
                                    PathSvg { path: "M20 24 L30 24 Q30 31 25 31 Q20 31 20 24 Z" }
                                }
                            }
                            Shape {   // wavy
                                anchors.fill: parent
                                preferredRendererType: Shape.CurveRenderer
                                opacity: root.mouthNow === "wavy" ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: 160 } }
                                ShapePath {
                                    strokeColor: root.accent; strokeWidth: 1.8; fillColor: "transparent"
                                    capStyle: ShapePath.RoundCap
                                    PathSvg { path: "M18 27 Q19.75 24 21.5 27 Q23.25 30 25 27 Q26.75 24 28.5 27 Q30.25 30 32 27" }
                                }
                            }
                        }

                    }

                    // ---- petting: blush
                    Item {
                        anchors.fill: parent
                        opacity: root.petting ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        Repeater {
                            model: 2
                            Rectangle {
                                x: index === 0 ? 6 : 37
                                y: 20
                                width: 7; height: 3.5
                                radius: 1.75
                                color: "#ff6b9a"
                                opacity: 0.75
                            }
                        }
                    }

                    // ---- weather widgets (glow with the face). Shown via opacity:
                    // `visible` toggles inside this hidden layer source never render.
                    Item {
                        id: wx
                        anchors.fill: parent
                        readonly property bool on: root.fx !== ""
                        // clouds sit on top when something falls out of them
                        readonly property bool fall: root.fx === "rain" || root.fx === "snow" || root.fx === "storm"
                        opacity: on ? 1 : 0
                        scale: on ? 1 : 0.6
                        Behavior on opacity { NumberAnimation { duration: 180 } }
                        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }

                        // sun: disc with slowly turning rays (sunny; small and to the left when hot)
                        Item {
                            readonly property bool hot: root.fx === "sweat"
                            opacity: root.fx === "sun" || hot ? 1 : 0
                            width: 30; height: 30
                            x: hot ? 2 : 10
                            y: hot ? 4 : 3
                            scale: hot ? 0.75 : 1
                            Rectangle {
                                x: 8; y: 8; width: 14; height: 14; radius: 7
                                color: root.accent
                            }
                            Item {
                                anchors.fill: parent
                                rotation: root.clock * 12
                                Repeater {
                                    model: 8
                                    Item {
                                        anchors.fill: parent
                                        rotation: index * 45
                                        Rectangle {
                                            x: 14; y: 0.5
                                            width: 2.2; height: 4.5 + (index % 2) * 1.2 * Math.sin(root.clock * 3)
                                            radius: 1.1
                                            color: root.accent
                                        }
                                    }
                                }
                            }
                        }

                        // cloud: big and drifting when cloudy, up top for rain / snow / storm
                        Item {
                            opacity: root.fx === "cloud" || wx.fall ? 1 : 0
                            width: 16; height: 9
                            transformOrigin: Item.TopLeft
                            scale: wx.fall ? 1.55 : 1.8
                            x: wx.fall ? 12.6 : 10.6 + Math.sin(root.clock * 0.6) * 3
                            y: wx.fall ? 2 : 9
                            Shape {
                                anchors.fill: parent
                                preferredRendererType: Shape.CurveRenderer
                                ShapePath {
                                    strokeColor: "transparent"; fillColor: root.accent
                                    PathSvg { path: "M4 9 C1.5 9 0 7.5 0 5.8 C0 4 1.6 2.7 3.4 2.9 C4 1.2 5.6 0 7.6 0 C10 0 11.9 1.6 12.3 3.6 C14 3.3 16 4.6 16 6.4 C16 7.9 14.8 9 13.2 9 Z" }
                                }
                            }
                        }
                        // a small second cloud behind when it's just cloudy
                        Item {
                            opacity: root.fx === "cloud" ? 0.55 : 0
                            width: 16; height: 9
                            transformOrigin: Item.TopLeft
                            scale: 0.9
                            x: 30 - Math.sin(root.clock * 0.45) * 3
                            y: 6
                            Shape {
                                anchors.fill: parent
                                preferredRendererType: Shape.CurveRenderer
                                ShapePath {
                                    strokeColor: "transparent"; fillColor: root.accent
                                    PathSvg { path: "M4 9 C1.5 9 0 7.5 0 5.8 C0 4 1.6 2.7 3.4 2.9 C4 1.2 5.6 0 7.6 0 C10 0 11.9 1.6 12.3 3.6 C14 3.3 16 4.6 16 6.4 C16 7.9 14.8 9 13.2 9 Z" }
                                }
                            }
                        }
                        Repeater {   // rain falling out of the cloud
                            model: 5
                            Rectangle {
                                readonly property real t: (root.clock * 1.6 + index * 0.41) % 1
                                opacity: (root.fx === "rain" || root.fx === "storm") ? 0.9 * (1 - t * 0.5) : 0
                                x: 16 + index * 4.5 - t * 2
                                y: 16 + t * 17
                                width: 1.4; height: 4
                                radius: 0.7
                                rotation: 15
                                color: root.accent
                            }
                        }
                        Repeater {   // snowflakes drifting down from the cloud
                            model: 5
                            Rectangle {
                                readonly property real t: (root.clock * 0.4 + index * 0.37) % 1
                                opacity: root.fx === "snow" ? 1 - t * 0.4 : 0
                                x: 15 + index * 4.5 + Math.sin((root.clock + index) * 2.2) * 1.5
                                y: 16 + t * 17
                                width: 2.4; height: 2.4
                                radius: 1.2
                                color: root.accent
                            }
                        }
                        Shape {   // lightning bolt that flashes now and then
                            readonly property real k: (root.clock % 2.6)
                            opacity: root.fx === "storm" && (k < 0.12 || (k > 0.22 && k < 0.3)) ? 1 : 0
                            preferredRendererType: Shape.CurveRenderer
                            x: 21; y: 15
                            width: 8; height: 12
                            scale: 1.3
                            ShapePath {
                                strokeColor: "transparent"; fillColor: "#fff3a0"
                                PathSvg { path: "M4.5 0 L0.5 6.5 L3.5 6.5 L2 12 L7.5 4.6 L4.4 4.6 L6 0 Z" }
                            }
                        }

                        // thermometer: nearly full when hot, almost empty when cold
                        Item {
                            readonly property real level: root.fx === "sweat" ? 0.9 : 0.12
                            opacity: root.fx === "sweat" || root.fx === "shiver" ? 1 : 0
                            x: root.fx === "sweat" ? 30 : 29
                            y: 4
                            width: 10; height: 29
                            Rectangle {   // tube
                                x: 2.5; y: 0; width: 5; height: 22; radius: 2.5
                                color: "transparent"
                                border.width: 1.5
                                border.color: root.accent
                            }
                            Rectangle {   // bulb
                                x: 0; y: 19; width: 10; height: 10; radius: 5
                                color: root.accent
                            }
                            Rectangle {   // mercury
                                x: 4; width: 2; radius: 1
                                height: 3 + 17 * parent.level
                                y: 21 - height
                                color: root.accent
                            }
                        }
                        Text {   // snowflake beside the thermometer when cold
                            x: 6; y: 6
                            text: "❄"
                            color: root.accent
                            font.pixelSize: 19
                            rotation: root.clock * 20
                            opacity: root.fx === "shiver" ? 1 : 0
                        }

                        Repeater {   // fog: soft bands sliding back and forth
                            model: 4
                            Rectangle {
                                opacity: root.fx === "fog" ? 0.85 - index * 0.12 : 0
                                width: [26, 34, 22, 30][index]
                                x: 25 - width / 2 + Math.sin(root.clock * 0.7 + index * 1.7) * 5
                                y: 8 + index * 6
                                height: 3; radius: 1.5
                                color: root.accent
                            }
                        }
                    }

                    // ---- icon: typing bubble
                    Item {
                        anchors.fill: parent
                        opacity: root.icon === "bubble" ? 1 : 0
                        scale: root.icon === "bubble" ? 1 : 0.6
                        Behavior on opacity { NumberAnimation { duration: 180 } }
                        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }

                        Rectangle {
                            x: 9; y: 10
                            width: 32; height: 16
                            radius: 8
                            color: "transparent"
                            border.width: 1.8
                            border.color: root.accent
                        }
                        Repeater {
                            model: 3
                            Rectangle {
                                // bump travels across the dots
                                readonly property real k: Math.max(0, 1 - Math.abs(((root.phase * 2) % 1) * 4 - 0.5 - index) * 1.2)
                                x: 18.5 + index * 5.5
                                y: 16.5 - k * 2
                                width: 3.5; height: 3.5
                                radius: 1.75
                                color: root.accent
                                opacity: 0.4 + 0.6 * k
                            }
                        }
                    }

                    // ---- icon: question mark
                    Text {
                        anchors.centerIn: parent
                        text: "?"
                        color: root.accent
                        font.pixelSize: 24
                        font.bold: true
                        rotation: Math.sin(root.phase * Math.PI * 4) * 10
                        opacity: root.icon === "question" ? 1 : 0
                        scale: root.icon === "question" ? 1 : 0.4
                        Behavior on opacity { NumberAnimation { duration: 180 } }
                        Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }
                    }

                    // ---- icon: battery
                    Item {
                        anchors.fill: parent
                        opacity: root.icon === "battery" ? 1 : 0
                        scale: root.icon === "battery" ? 1 : 0.6
                        Behavior on opacity { NumberAnimation { duration: 180 } }
                        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }

                        Rectangle {
                            x: 11; y: 11
                            width: 26; height: 14
                            radius: 3
                            color: "transparent"
                            border.width: 1.8
                            border.color: root.accent
                        }
                        Rectangle {
                            x: 37.5; y: 15
                            width: 2.5; height: 6
                            radius: 1
                            color: root.accent
                        }
                        Rectangle {
                            x: 14.5; y: 14.5
                            height: 7
                            width: Math.max(2.5, 19 * root.battLevel / 100)
                            radius: 1.5
                            color: root.battColor
                            SequentialAnimation on opacity {
                                running: root.lowBatt
                                loops: Animation.Infinite
                                NumberAnimation { to: 0.2; duration: 450 }
                                NumberAnimation { to: 1.0; duration: 450 }
                            }
                        }
                    }
                    // ---- icon: system event (volume, brightness, wifi, bluetooth, usb, keep-awake)
                    Item {
                        anchors.fill: parent
                        opacity: root.icon === "sys" ? 1 : 0
                        scale: root.icon === "sys" ? 1 : 0.5
                        Behavior on opacity { NumberAnimation { duration: 160 } }
                        Behavior on scale { NumberAnimation { duration: 280; easing.type: Easing.OutBack } }

                        // ripple for things switching on / connecting
                        Rectangle {
                            readonly property bool on: root.sysOn && ["wifi", "bt", "btdev", "usb", "coffee"].indexOf(root.sysKind) >= 0
                            x: 25 - width / 2
                            y: (root.sysLevel >= 0 ? 13 : 17) - height / 2
                            width: 10 + root.sysRing * 34
                            height: width
                            radius: width / 2
                            color: "transparent"
                            border.width: 1.5
                            border.color: root.accent
                            opacity: on ? (1 - root.sysRing) * 0.9 : 0
                        }
                        Text {
                            x: 25 - width / 2
                            y: (root.sysLevel >= 0 ? 13 : 17) - height / 2 + (root.sysOn ? 0 : root.sysDrop * 3)
                            text: root.sysGlyph
                            color: root.accent
                            opacity: root.sysOn || root.sysKind === "vol" ? 1 : 0.55
                            font.family: "Symbols Nerd Font Mono"   // icons; any Nerd Font works too
                            font.pixelSize: 22
                            scale: root.sysBump
                            rotation: root.sysKind === "usb" ? -root.sysWobble * 12 : 0
                        }
                        // steam over the coffee cup
                        Repeater {
                            model: 3
                            Rectangle {
                                readonly property real t: (root.clock * 0.9 + index * 0.33) % 1
                                opacity: root.sysKind === "coffee" && root.sysOn ? Math.sin(t * Math.PI) * 0.9 : 0
                                x: 20 + index * 4 + Math.sin((root.clock * 3 + index) * 2) * 1.2
                                y: 7 - t * 7
                                width: 1.6; height: 3.5
                                radius: 0.8
                                color: root.accent
                            }
                        }
                        // level bar
                        Rectangle {
                            x: 10; y: 27
                            width: 30; height: 3.5
                            radius: 1.75
                            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.25)
                            opacity: root.sysLevel >= 0 ? 1 : 0
                            Rectangle {
                                width: Math.max(height, parent.width * Math.min(1, Math.max(0, root.sysOn ? root.sysLevel : 0)))
                                height: parent.height
                                radius: parent.radius
                                color: root.accent
                                Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
                            }
                        }
                    }
                }

                MultiEffect {
                    source: glyphs
                    anchors.fill: glyphs
                    shadowEnabled: true
                    shadowColor: root.accent
                    shadowOpacity: Math.min(1, root.glow + (root.purring ? 0.3 : 0))
                    shadowBlur: root.purring ? 0.9 : 0.6
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                    blurMax: 12
                }

                // ---- weather overlay that shouldn't glow
                Rectangle {   // lightning lights up the whole visor
                    anchors.fill: parent
                    radius: visor.radius
                    color: "#ffffff"
                    readonly property real k: (root.clock % 2.6)
                    opacity: root.fx === "storm" && (k < 0.08 || (k > 0.22 && k < 0.27)) ? 0.35 : 0
                }
            }

            // sweat drop on the helmet when it's hot
            Shape {
                visible: root.fx === "sweat"
                preferredRendererType: Shape.CurveRenderer
                x: 54
                y: 6 + ((root.clock * 0.6) % 1) * 8
                width: 6; height: 9
                opacity: 1 - ((root.clock * 0.6) % 1) * 0.6
                ShapePath {
                    strokeColor: "#2f7fd6"; strokeWidth: 0.8
                    fillColor: "#8fd0ff"
                    PathSvg { path: "M3 0 C3 0 0 4 0 6 C0 7.7 1.3 9 3 9 C4.7 9 6 7.7 6 6 C6 4 3 0 3 0 Z" }
                }
            }

            // glowing visor rim
            Rectangle {
                x: visor.x - 1
                y: visor.y - 1
                width: visor.width + 2
                height: visor.height + 2
                radius: visor.radius + 1
                color: "transparent"
                border.width: 1.5
                border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35 + 0.4 * root.glow)
            }
        }
    }

    // --- zzz and music notes ---------------------------------------------
    // Big and free to float out of the visor and past the helmet (up and to
    // the right). Their own glow layer, sized to cover where they drift.
    Item {
        id: floaters
        x: -10; y: -34
        width: 110; height: 90
        visible: root.shown === "sleep" || root.shown === "off" || (root.shown === "music" && !root.petting)
        layer.enabled: visible
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: root.accent
            shadowOpacity: 0.9
            shadowBlur: 0.5
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 0
            blurMax: 10
        }
        // start point: the visor's upper right corner (head coords 50,22)
        readonly property real ox: 60
        readonly property real oy: 62 + root.bob

        Repeater {   // zzz while sleeping
            model: 3
            Text {
                readonly property real t: (root.phase + index / 3) % 1
                text: "z"
                color: root.accent
                font.pixelSize: Math.round(9 + t * 9)
                font.bold: true
                x: floaters.ox + t * 26 + Math.sin(t * 6) * 2
                y: floaters.oy - t * 36 - height / 2
                opacity: root.shown === "sleep" || root.shown === "off" ? Math.sin(t * Math.PI) : 0
            }
        }
        Repeater {   // music notes drifting up
            model: 3
            Text {
                readonly property real t: (root.phase * 1.5 + index / 3) % 1
                text: index === 1 ? "♫" : "♪"
                color: root.accent
                font.pixelSize: Math.round(11 + t * 7)
                font.bold: true
                x: floaters.ox - 4 + t * 24 + Math.sin(t * 9 + index) * 3
                y: floaters.oy - t * 36 - height / 2
                opacity: root.shown === "music" && !root.petting ? Math.sin(t * Math.PI) : 0
            }
        }
    }
}
