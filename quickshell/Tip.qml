import QtQuick
import QtQuick.Controls

// Tooltip in the popups' style, instead of Qt's yellow default.
ToolTip {
    id: tipItem
    delay: 450
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Style.quick; easing.type: Easing.BezierSpline; easing.bezierCurve: Style.expoOut } }
    exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Style.quick } }
    contentItem: Text {
        text: tipItem.text
        color: Style.fg
        font.family: Style.sans; font.pixelSize: 11
    }
    background: Rectangle {
        color: Style.bgElevated
        radius: Style.controlRadius
        border.width: 1
        border.color: Style.lineHi
    }
}
