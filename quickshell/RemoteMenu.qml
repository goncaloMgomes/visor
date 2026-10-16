import Quickshell
import Quickshell.Io
import QtQuick

// Right-click menu on the robot: the robot's settings (speech balloons on/off,
// the city for the weather, and a Settings page for config.json, SettingsPage.qml)
// and, when a service is configured, its state with Start / Restart / Stop
// (Restart and Stop ask for a second click).
PopupWindow {
    id: menu

    property bool open: false
    property string unit: ""             // systemd --user unit ("" = no service section)
    property string label: ""
    property string countPattern: ""     // pgrep -f pattern for the unit's children, shown as "N sessions"
    property bool weatherOn: true
    property bool remoteOn: false
    property bool waking: false
    signal startRequested()
    signal stopRequested()
    signal restartRequested()
    property string city: ""
    property bool balloonsOn: true
    property bool editing: false          // typing the city (needs the keyboard)
    signal citySet(string name)
    signal balloonsSet(bool on)

    // the Settings page
    property string page: "main"          // "main" | "settings"
    property var cfg: ({})
    property var backendInfo: ({})
    property var themes: []
    signal configSet(string key, var value)
    signal configFileRequested()

    property string armed: ""            // "stop" | "restart" waiting for the 2nd click
    property int sessions: -1
    property string since: ""
    Timer { id: disarm; interval: 3000; onTriggered: menu.armed = "" }

    // room around the card for its shadow
    readonly property real pad: 14
    visible: open
    color: "transparent"
    implicitWidth: 260 + 2 * pad
    implicitHeight: box.height + 2 * pad

    onOpenChanged: {
        if (open) enter.restart()
        armed = ""
        editing = false
        page = "main"
        if (open && unit && !info.running) info.running = true
    }
    onEditingChanged: if (editing) { cityInput.text = city; cityInput.selectAll(); cityInput.forceActiveFocus() }

    // since when the service has been up (and how many sessions it hosts, with countPattern)
    Process {
        id: info
        command: ["sh", "-c", 'u="$1"; c="$2"; p=$(systemctl --user show -p MainPID --value "$u"); '
                  + 'if [ -n "$c" ] && [ "$p" -gt 0 ] 2>/dev/null; then pgrep -c -P "$p" -f "$c" || echo 0; else echo -1; fi; '
                  + 'systemctl --user show -p ActiveEnterTimestamp --value "$u"', "sh", menu.unit, menu.countPattern]
        stdout: StdioCollector {
            onStreamFinished: {
                const l = this.text.trim().split("\n")
                menu.sessions = parseInt(l[0])
                const m = /(\d+):(\d+):\d+/.exec(l[1] || "")
                menu.since = m ? m[1] + ":" + m[2] : ""
            }
        }
    }
    Timer { running: menu.open && menu.unit !== ""; repeat: true; interval: 3000; onTriggered: if (!info.running) info.running = true }

    // the card fades in and settles 6 px down (expo-out)
    ParallelAnimation {
        id: enter
        Motion { target: box; property: "opacity"; from: 0; to: 1 }
        Motion { target: box; property: "y"; from: menu.pad - 6; to: menu.pad }
    }
    Elevation { x: box.x; y: box.y; width: box.width; height: box.height; opacity: box.opacity }
    Item {
        id: box
        x: menu.pad; y: menu.pad
        width: menu.implicitWidth - 2 * menu.pad
        height: (menu.page === "settings" ? settings.implicitHeight : col.implicitHeight) + 12
        Ambient { anchors.fill: parent; running: menu.open }
        Spotlight {}
        Rectangle {   // hairline border
            anchors.fill: parent
            radius: Style.radius
            color: "transparent"
            border.width: 1
            border.color: Style.line
        }

        SettingsPage {
            id: settings
            x: 6; y: 6
            width: parent.width - 12
            visible: menu.page === "settings"
            active: visible
            cfg: menu.cfg
            backend: menu.backendInfo
            themes: menu.themes
            onSetValue: (key, value) => menu.configSet(key, value)
            onBack: menu.page = "main"
            onOpenFile: { menu.open = false; menu.configFileRequested() }
        }

        Column {
            id: col
            x: 6; y: 6
            visible: menu.page === "main"
            width: parent.width - 12
            spacing: 2

            // status
            Item {
                visible: menu.unit !== ""
                width: col.width
                height: visible ? 44 : 0
                Rectangle {
                    id: dot
                    x: 8; anchors.verticalCenter: parent.verticalCenter
                    width: 8; height: 8; radius: 4
                    color: menu.remoteOn ? Style.ok : menu.waking ? Style.warn : Style.muted
                }
                Column {
                    anchors { left: dot.right; leftMargin: 10; verticalCenter: parent.verticalCenter }
                    Text {
                        text: menu.remoteOn ? menu.label + " is on" : menu.waking ? "Starting " + menu.label + "…" : menu.label + " is off"
                        color: Style.fg; font.family: Style.sans; font.pixelSize: 13; font.weight: Font.Medium
                    }
                    Text {
                        visible: menu.remoteOn && (menu.sessions >= 0 || menu.since !== "")
                        text: [menu.sessions >= 0 ? (menu.sessions === 1 ? "1 session" : menu.sessions + " sessions") : "",
                               menu.since ? "up since " + menu.since : ""].filter(x => x).join(" · ")
                        color: Style.muted; font.family: Style.sans; font.pixelSize: 11
                    }
                }
            }
            Rectangle { visible: menu.unit !== ""; width: col.width; height: visible ? 1 : 0; color: Style.line }

            Repeater {
                model: [
                    { id: "start",   label: "Start",   icon: "▶", show: !menu.remoteOn && !menu.waking },
                    { id: "restart", label: "Restart", icon: "↻", show: menu.remoteOn },
                    { id: "stop",    label: "Stop",    icon: "⏻", show: menu.remoteOn }
                ]
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool isArmed: menu.armed === modelData.id
                    visible: modelData.show && menu.unit !== ""
                    width: col.width
                    height: visible ? 32 : 0
                    radius: Style.controlRadius
                    color: isArmed ? Style.accentDim : hover.containsMouse ? Style.surface : "transparent"
                    Text {
                        id: ic
                        x: 8; width: 18
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: row.modelData.icon
                        color: row.isArmed ? Style.accent : Style.muted
                        font.pixelSize: 13
                    }
                    Text {
                        anchors { left: ic.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
                        text: row.isArmed ? "Click again to " + row.modelData.label.toLowerCase() + " " + menu.label
                                          : row.modelData.label
                        color: row.isArmed ? Style.accent : Style.fg
                        font.family: Style.sans; font.pixelSize: row.isArmed ? 11 : 13
                    }
                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const id = row.modelData.id
                            if (id === "start") { menu.open = false; menu.startRequested(); return }
                            if (menu.armed !== id) { menu.armed = id; disarm.restart(); return }
                            menu.open = false
                            if (id === "stop") menu.stopRequested(); else menu.restartRequested()
                        }
                    }
                }
            }

            Rectangle { visible: menu.unit !== ""; width: col.width; height: visible ? 1 : 0; color: Style.line }

            // speech balloons on / off
            Rectangle {
                width: col.width
                height: 32
                radius: Style.controlRadius
                color: balloonHover.containsMouse ? Style.surface : "transparent"
                Text {
                    id: bIc
                    x: 8; width: 18
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: "❝"
                    color: Style.muted
                    font.family: Style.sans; font.pixelSize: 14
                }
                Text {
                    anchors { left: bIc.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    text: "Speech balloons"
                    color: Style.fg; font.family: Style.sans; font.pixelSize: 13
                }
                Rectangle {   // switch
                    anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    width: 30; height: 17; radius: 8.5
                    color: menu.balloonsOn ? Style.accent : Style.surfaceHover
                    Behavior on color { ColorMotion {} }
                    Rectangle {
                        width: 13; height: 13; radius: 6.5
                        y: 2
                        x: menu.balloonsOn ? parent.width - width - 2 : 2
                        color: Style.fg
                        Behavior on x { Motion { duration: Style.quick } }
                    }
                }
                MouseArea {
                    id: balloonHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: menu.balloonsSet(!menu.balloonsOn)
                }
            }

            // weather city
            Rectangle {
                visible: menu.weatherOn
                width: col.width
                height: visible ? 32 : 0
                radius: Style.controlRadius
                color: menu.editing ? Style.surface : cityHover.containsMouse ? Style.surface : "transparent"
                border.width: menu.editing ? 1 : 0
                border.color: Style.accent
                Text {
                    id: wIc
                    x: 8; width: 18
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: "☁"
                    color: Style.muted
                    font.family: Style.sans; font.pixelSize: 14
                }
                Text {
                    visible: !menu.editing
                    anchors { left: wIc.right; leftMargin: 8; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    text: menu.city ? "Weather: " + menu.city : "Set weather city…"
                    elide: Text.ElideRight
                    color: menu.city ? Style.fg : Style.muted
                    font.family: Style.sans; font.pixelSize: 13
                }
                TextInput {
                    id: cityInput
                    visible: menu.editing
                    anchors { left: wIc.right; leftMargin: 8; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    color: Style.fg
                    selectionColor: Style.accent
                    font.family: Style.sans; font.pixelSize: 13
                    clip: true
                    Text {
                        visible: !cityInput.text
                        text: "City, Country — Enter to save"
                        color: Style.muted
                        font: cityInput.font
                    }
                    Keys.onReturnPressed: { menu.citySet(text); menu.editing = false }
                    Keys.onEnterPressed: { menu.citySet(text); menu.editing = false }
                    Keys.onEscapePressed: menu.editing = false
                }
                MouseArea {
                    id: cityHover
                    anchors.fill: parent
                    visible: !menu.editing
                    hoverEnabled: true
                    cursorShape: Qt.IBeamCursor
                    onClicked: menu.editing = true
                }
            }

            Rectangle { width: col.width; height: 1; color: Style.line }

            // → the Settings page
            Rectangle {
                width: col.width
                height: 32
                radius: Style.controlRadius
                color: settingsHover.containsMouse ? Style.surface : "transparent"
                Text {
                    id: sIc
                    x: 8; width: 18
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: "⚙"
                    color: Style.muted
                    font.family: Style.sans; font.pixelSize: 14
                }
                Text {
                    anchors { left: sIc.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    text: "Settings"
                    color: Style.fg; font.family: Style.sans; font.pixelSize: 13
                }
                Text {
                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    text: "›"
                    color: Style.muted; font.family: Style.sans; font.pixelSize: 16
                }
                MouseArea {
                    id: settingsHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { menu.editing = false; menu.page = "settings" }
                }
            }
        }
    }
}
