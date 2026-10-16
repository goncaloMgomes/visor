import QtQuick
import QtQuick.Controls

// Dark tooltip in the chat panel's style, instead of Qt's yellow default.
ToolTip {
    id: tipItem
    delay: 450
    contentItem: Text {
        text: tipItem.text
        color: "#faf9f5"
        font.family: "Noto Sans"; font.pixelSize: 11
    }
    background: Rectangle {
        color: "#141413"
        radius: 7
        border.width: 1
        border.color: "#26dedcd1"
    }
}
