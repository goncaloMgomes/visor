import QtQuick
import Quickshell

// A code block for the chat: language label, Copy button, light syntax
// colouring, and long code folded to `maxLines` with a "show more" toggle.
Rectangle {
    id: cb

    property string code: ""
    property string lang: ""
    property int maxLines: 14
    property bool expanded: false
    property bool copied: false

    readonly property color dim: Style.muted
    readonly property string mono: Style.mono
    readonly property int lines: code === "" ? 0 : code.split("\n").length
    readonly property bool long: lines > maxLines

    radius: Style.controlRadius + 2
    color: Style.codeBg
    border.width: 1
    border.color: Style.line
    height: head.height + clipper.height + (long ? more.height : 8)

    // header: language + copy
    Item {
        id: head
        width: parent.width
        height: 26
        Text {
            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
            text: (cb.lang || "code").toUpperCase()
            color: cb.dim
            font.family: cb.mono; font.pixelSize: 9; font.letterSpacing: 1.2
        }
        Text {
            id: copy
            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
            text: cb.copied ? "Copied" : "Copy"
            color: copyArea.containsMouse ? Style.fg : cb.dim
            Behavior on color { ColorMotion {} }
            font.family: Style.sans; font.pixelSize: 10
            MouseArea {
                id: copyArea
                anchors { fill: parent; margins: -6 }
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    Quickshell.execDetached(["wl-copy", "--", cb.code])
                    cb.copied = true
                    copiedTimer.restart()
                }
            }
        }
        Timer { id: copiedTimer; interval: 1500; onTriggered: cb.copied = false }
    }

    FontMetrics { id: fm; font: body.font }

    Item {
        id: clipper
        x: 10
        y: head.height
        width: parent.width - 20
        height: cb.long && !cb.expanded ? Math.min(body.contentHeight, cb.maxLines * fm.lineSpacing + 2) : body.contentHeight
        clip: true

        TextEdit {
            id: body
            width: parent.width
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.RichText
            text: cb.highlight(cb.code, cb.lang)
            color: Style.fg
            font.family: cb.mono; font.pixelSize: 11
            selectionColor: Style.alpha(Style.accent, 0.4)
            selectedTextColor: Style.fg
        }

        Rectangle {   // fade the folded bottom edge
            visible: cb.long && !cb.expanded
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 18
            gradient: Gradient {
                GradientStop { position: 0; color: Style.alpha(Style.codeBg, 0) }
                GradientStop { position: 1; color: Style.codeBg }
            }
        }
    }

    Text {
        id: more
        visible: cb.long
        x: 10
        y: clipper.y + clipper.height
        height: 24
        verticalAlignment: Text.AlignVCenter
        text: cb.expanded ? "Show less" : "Show " + (cb.lines - cb.maxLines) + " more lines"
        color: moreArea.containsMouse ? Style.accentHi : Style.accent
        font.family: Style.sans; font.pixelSize: 10
        MouseArea {
            id: moreArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: cb.expanded = !cb.expanded
        }
    }

    // --- light syntax colouring ------------------------------------------------
    function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

    function highlight(src, language) {
        const L = (language || "").toLowerCase()
        const shell = ["", "bash", "sh", "shell", "zsh", "fish", "console"].indexOf(L) >= 0
        const cLike = ["js", "javascript", "ts", "typescript", "c", "cpp", "c++", "java", "go", "rust", "rs",
                       "qml", "css", "json", "kotlin", "swift", "cs", "lua"].indexOf(L) >= 0
        const kw = shell
            ? "if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|return|local|export|sudo|echo|cd|exit"
            : "if|else|elif|for|while|do|return|def|class|import|from|as|const|let|var|function|new|true|false|null|None|True|False|async|await|export|try|except|catch|finally|with|in|of|and|or|not|self|this|struct|fn|pub|use|impl|match|local|then|end|property|readonly"
        const never = "(?!)"
        const re = new RegExp([
            cLike ? "(\\/\\/[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/)" : "((?:^|[ \\t])#[^\\n]*)",   // 1 comment
            "(\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'|`[^`]*`)",            // 2 string
            shell ? "(\\$\\{?[\\w@#?*!-]+\\}?)" : never,                                    // 3 variable
            "(\\b\\d+(?:\\.\\d+)?\\b)",                                                       // 4 number
            shell ? "((?:^|(?=[ \\t]))[ \\t]--?[A-Za-z][\\w-]*)" : never,                  // 5 flag
            "(\\b(?:" + kw + ")\\b)"                                                          // 6 keyword
        ].join("|"), "gm")
        const colors = [null, Style.hex(Style.muted), "#a9c98d", "#e5c07b", "#e0a370", "#86b8d6", "#c4a7e7"]
        let out = "", last = 0, m
        while ((m = re.exec(src)) !== null) {
            if (m[0] === "") { re.lastIndex++; continue }
            out += esc(src.substring(last, m.index))
            let g = 1
            while (g < 7 && m[g] === undefined) g++
            const style = g === 1 ? "color:" + colors[g] + ";font-style:italic" : "color:" + colors[g]
            out += "<span style=\"" + style + "\">" + esc(m[0]) + "</span>"
            last = re.lastIndex
        }
        out += esc(src.substring(last))
        return "<div style=\"white-space:pre-wrap\">" + out + "</div>"
    }
}
