import Quickshell
import QtQuick

// The right-click menu's settings page: the everyday options of
// ~/.config/visor/config.json. Each change is written straight back with
// `chat.py set`; the robot re-reads the file when it changes, so it applies
// right away (chat options from the next chat). The rest is in the file itself.
Item {
    id: page

    property var cfg: ({})
    property var backend: ({})
    property var themes: []
    property bool active: false
    signal setValue(string key, var value)
    signal back()
    signal openFile()

    property string expanded: ""   // the choice row showing its options
    property string editing: ""    // the text / number row being typed in
    onActiveChanged: { expanded = ""; editing = ""; list.contentY = 0 }

    readonly property string home: Quickshell.env("HOME")
    function get(key) {
        let o = cfg
        for (const k of key.split(".")) o = o?.[k]
        return o
    }
    function shown(row) {
        const v = get(row.key)
        if (row.type === "choice") {
            const o = (row.options ?? []).find(o => o.v === (v ?? ""))
            return o ? o.label : String(v ?? "")
        }
        if (row.type === "number") return v === undefined ? "" : v + (row.unit ? " " + row.unit : "")
        const s = String(v ?? "")
        return home && s.startsWith(home) ? "~" + s.slice(home.length) : s
    }

    readonly property bool claudeCode: (cfg.backend ?? "claude-code") === "claude-code"
    readonly property var rows: [
        { section: "General" },
        { key: "name", label: "Your name", type: "text", empty: "none" },
        { key: "theme", label: "Chat theme", type: "choice",
          options: themes.map(t => ({ v: t, label: t.charAt(0).toUpperCase() + t.slice(1) })) },
        { key: "reducedMotion", label: "Reduce motion", type: "toggle" },
        { key: "idleSeconds", label: "Sleep when away", type: "number", unit: "s" },
        { key: "waybar.makeRoom", label: "Make room in Waybar", type: "toggle" },
        { section: "Chat" },
        { key: "backend", label: "AI", type: "choice",
          options: [{ v: "claude-code", label: "Claude Code" }, { v: "openai", label: "OpenAI-compatible" }] },
        { key: "chat.model", label: "Model", type: "choice",
          options: [{ v: "", label: "Default" }].concat((backend.models ?? []).map(m => ({ v: m.id, label: m.name || m.id }))) },
        { key: "chat.permissionMode", label: "Permissions", type: "choice", show: claudeCode,
          options: [{ v: "default", label: "Ask" }, { v: "acceptEdits", label: "Accept edits" },
                    { v: "auto", label: "Auto" }, { v: "plan", label: "Plan" },
                    { v: "bypassPermissions", label: "Bypass (no checks)" }] },
        { key: "chat.computerUse", label: "Computer use", type: "toggle" },
        { key: "chat.shareScreen", label: "Share screen", type: "toggle" },
        { key: "chat.cwd", label: "Folder", type: "text", empty: "~" },
        { key: "chat.resumeMinutes", label: "Continue chats for", type: "number", unit: "min" },
        { section: "Extras" },
        { key: "features.weather", label: "Weather", type: "toggle" },
        { key: "features.remarks", label: "AI remarks", type: "toggle" },
        { section: "Service" },
        { key: "service.unit", label: "Unit", type: "text", empty: "none" },
        { key: "service.label", label: "Name", type: "text", empty: "from the unit" }
    ]

    implicitHeight: header.height + list.height + footer.height + 4

    // ‹ Settings
    Rectangle {
        id: header
        width: page.width
        height: 32
        radius: Style.controlRadius
        color: backHover.containsMouse ? Style.surface : "transparent"
        Text {
            id: backIc
            x: 8; width: 18
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: "‹"
            color: Style.muted
            font.family: Style.sans; font.pixelSize: 18
        }
        Text {
            anchors { left: backIc.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
            text: "Settings"
            color: Style.fg; font.family: Style.sans; font.pixelSize: 13; font.weight: Font.Medium
        }
        MouseArea {
            id: backHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: page.back()
        }
    }

    Flickable {
        id: list
        anchors.top: header.bottom
        width: page.width
        height: Math.min(contentHeight, 430)
        contentHeight: rowsCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: rowsCol
            width: list.width
            spacing: 2

            Repeater {
                model: page.rows
                delegate: Column {
                    id: row
                    required property var modelData
                    readonly property bool isSection: !!modelData.section
                    readonly property bool isEditing: page.editing === modelData.key
                    readonly property bool isExpanded: page.expanded === modelData.key
                    visible: modelData.show !== false
                    width: rowsCol.width

                    // section title
                    Text {
                        visible: row.isSection
                        height: visible ? 26 : 0
                        leftPadding: 8
                        verticalAlignment: Text.AlignBottom
                        bottomPadding: 4
                        text: row.modelData.section ?? ""
                        color: Style.muted
                        font.family: Style.sans; font.pixelSize: 11; font.weight: Font.Medium
                        font.capitalization: Font.AllUppercase; font.letterSpacing: 0.6
                    }

                    // the setting
                    Rectangle {
                        visible: !row.isSection
                        width: row.width
                        height: visible ? 32 : 0
                        radius: Style.controlRadius
                        color: row.isEditing || row.isExpanded || rowHover.containsMouse ? Style.surface : "transparent"
                        border.width: row.isEditing ? 1 : 0
                        border.color: Style.accent

                        Text {
                            id: name
                            visible: !row.isEditing
                            x: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.label ?? ""
                            color: Style.fg; font.family: Style.sans; font.pixelSize: 13
                        }
                        // current value (text, number, choice)
                        Text {
                            visible: !row.isEditing && row.modelData.type !== "toggle"
                            anchors { left: name.right; leftMargin: 10; right: parent.right; rightMargin: 10
                                      verticalCenter: parent.verticalCenter }
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideLeft
                            readonly property string v: row.isSection ? "" : page.shown(row.modelData)
                            text: (v || row.modelData.empty || "") + (row.modelData.type === "choice" ? (row.isExpanded ? "  ▴" : "  ▾") : "")
                            color: v ? Style.subtle : Style.muted
                            font.family: Style.sans; font.pixelSize: 12
                        }
                        // switch
                        Rectangle {
                            visible: row.modelData.type === "toggle"
                            readonly property bool on: !row.isSection && page.get(row.modelData.key) === true
                            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                            width: 30; height: 17; radius: 8.5
                            color: on ? Style.accent : Style.surfaceHover
                            Behavior on color { ColorMotion {} }
                            Rectangle {
                                width: 13; height: 13; radius: 6.5
                                y: 2
                                x: parent.on ? parent.width - width - 2 : 2
                                color: Style.fg
                                Behavior on x { Motion { duration: Style.quick } }
                            }
                        }
                        // typing a text / number value
                        TextInput {
                            id: input
                            visible: row.isEditing
                            anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 10
                                      verticalCenter: parent.verticalCenter }
                            color: Style.fg
                            selectionColor: Style.accent
                            font.family: Style.sans; font.pixelSize: 13
                            clip: true
                            validator: row.modelData.type === "number" ? digits : null
                            IntValidator { id: digits; bottom: 0 }
                            Text {
                                visible: !input.text
                                text: (row.modelData.label ?? "") + " — Enter to save"
                                color: Style.muted
                                font: input.font
                            }
                            function save() {
                                const t = text.trim()
                                const k = row.modelData.key
                                if (row.modelData.type === "number") { if (t !== "") page.setValue(k, parseInt(t)) }
                                else page.setValue(k, t === "" ? null : t)
                                page.editing = ""
                            }
                            Keys.onReturnPressed: save()
                            Keys.onEnterPressed: save()
                            Keys.onEscapePressed: page.editing = ""
                        }
                        MouseArea {
                            id: rowHover
                            anchors.fill: parent
                            visible: !row.isEditing
                            hoverEnabled: true
                            cursorShape: row.modelData.type === "text" || row.modelData.type === "number" ? Qt.IBeamCursor : Qt.PointingHandCursor
                            onClicked: {
                                const r = row.modelData
                                if (r.type === "toggle") { page.setValue(r.key, page.get(r.key) !== true); return }
                                if (r.type === "choice") { page.expanded = row.isExpanded ? "" : r.key; page.editing = ""; return }
                                page.expanded = ""
                                page.editing = r.key
                                const v = page.get(r.key)
                                input.text = r.key === "chat.cwd" ? page.shown(r) : String(v ?? "")
                                input.selectAll()
                                input.forceActiveFocus()
                            }
                        }
                    }

                    // a choice's options
                    Column {
                        visible: row.isExpanded
                        width: row.width
                        Repeater {
                            model: row.isExpanded ? row.modelData.options : []
                            delegate: Rectangle {
                                id: opt
                                required property var modelData
                                readonly property bool current: (page.get(row.modelData.key) ?? "") === modelData.v
                                width: row.width
                                height: 28
                                radius: Style.controlRadius
                                color: optHover.containsMouse ? Style.surface : "transparent"
                                Text {
                                    x: 22
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: opt.modelData.label
                                    color: opt.current ? Style.accent : Style.fg
                                    font.family: Style.sans; font.pixelSize: 12
                                }
                                Text {
                                    visible: opt.current
                                    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                    text: "✓"
                                    color: Style.accent
                                    font.pixelSize: 12
                                }
                                MouseArea {
                                    id: optHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        // "" (the backend's default model) = drop the key
                                        page.setValue(row.modelData.key, opt.modelData.v === "" ? null : opt.modelData.v)
                                        page.expanded = ""
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // everything else
    Rectangle {
        id: footer
        anchors { top: list.bottom; topMargin: 4 }
        width: page.width
        height: 32
        radius: Style.controlRadius
        color: fileHover.containsMouse ? Style.surface : "transparent"
        Text {
            id: fileIc
            x: 8; width: 18
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: "{ }"
            color: Style.muted
            font.family: Style.sans; font.pixelSize: 11
        }
        Text {
            anchors { left: fileIc.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
            text: "Open config.json…"
            color: Style.fg; font.family: Style.sans; font.pixelSize: 13
        }
        MouseArea {
            id: fileHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: page.openFile()
        }
    }
}
