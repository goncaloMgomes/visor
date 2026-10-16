import QtQuick
import QtQuick.Shapes

// A text button. variant: "primary" (accent, glowing), "secondary" (glass),
// "ghost" (text until hovered). Used on the permission / question card.
Item {
    id: ab
    property string label
    property bool primary: false
    property string variant: primary ? "primary" : "secondary"
    signal clicked()

    readonly property bool isPrimary: variant === "primary"
    readonly property bool hot: area.containsMouse
    height: 28
    width: abText.implicitWidth + 24
    scale: area.pressed ? 0.98 : 1
    Behavior on scale { Motion { duration: Style.quick } }
    activeFocusOnTab: true
    Keys.onReturnPressed: ab.clicked()
    Keys.onSpacePressed: ab.clicked()
    Accessible.role: Accessible.Button
    Accessible.name: label

    Elevation {
        anchors.fill: parent
        visible: ab.isPrimary && Style.shadows
        radius: Style.controlRadius
        glow: true
        lifted: ab.hot
        depth: 0.4
    }
    Rectangle {
        id: face
        anchors.fill: parent
        radius: Style.controlRadius
        color: ab.isPrimary ? (ab.hot ? Style.accentHi : Style.accent)
             : ab.variant === "secondary" ? (ab.hot ? Style.surfaceHover : Style.surface)
             : (ab.hot ? Style.surface : "transparent")
        Behavior on color { ColorMotion {} }
        border.width: ab.isPrimary ? 1 : 0
        border.color: Style.alpha(Style.accentHi, 0.5)
    }
    // inset highlight along the top edge
    Rectangle {
        visible: ab.variant !== "ghost"
        anchors { top: parent.top; topMargin: 1; left: parent.left; right: parent.right; leftMargin: Style.controlRadius / 2; rightMargin: Style.controlRadius / 2 }
        height: 1
        color: Style.alpha("#ffffff", ab.isPrimary ? 0.2 : 0.08)
    }
    // shine: a light band sweeps across a primary button on hover
    Shape {
        anchors.fill: parent
        visible: ab.isPrimary && !Style.reducedMotion
        preferredRendererType: Shape.CurveRenderer
        property real sweep: -1
        opacity: ab.hot ? 1 : 0
        Behavior on opacity { Motion { duration: Style.quick } }
        NumberAnimation on sweep { running: ab.hot; from: -1; to: 2; duration: 900; easing.type: Easing.BezierSpline; easing.bezierCurve: Style.expoOut }
        ShapePath {
            strokeWidth: -1
            fillGradient: LinearGradient {
                x1: (parent.sweep - 0.4) * ab.width; y1: 0
                x2: (parent.sweep + 0.4) * ab.width; y2: ab.height
                GradientStop { position: 0; color: "#00ffffff" }
                GradientStop { position: 0.5; color: "#2effffff" }
                GradientStop { position: 1; color: "#00ffffff" }
            }
            PathRectangle { width: ab.width; height: ab.height; radius: Style.controlRadius }
        }
    }
    // focus ring
    Rectangle {
        anchors { fill: parent; margins: -3 }
        radius: Style.controlRadius + 3
        color: "transparent"
        border.width: 2
        border.color: Style.alpha(Style.accent, 0.5)
        visible: ab.activeFocus
    }
    Text {
        id: abText
        anchors.centerIn: parent
        text: ab.label
        color: ab.isPrimary ? Style.onAccent : (ab.hot || ab.variant === "secondary" ? Style.fg : Style.muted)
        font.family: Style.sans; font.pixelSize: 12; font.weight: Font.Medium
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ab.clicked()
    }
}
