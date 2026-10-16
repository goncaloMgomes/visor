import QtQuick

// A button on the chat's permission / question card (ChatPanel.qml).
Rectangle {
    id: ab
    property string label
    property bool primary: false
    signal clicked()
    height: 28; radius: 8
    width: abText.implicitWidth + 22
    color: primary ? (abArea.containsMouse ? "#e08a6d" : "#d97757")
                   : (abArea.containsMouse ? "#3a3a37" : "transparent")
    border.width: primary ? 0 : 1
    border.color: "#26dedcd1"
    Text {
        id: abText
        anchors.centerIn: parent
        text: ab.label
        color: ab.primary ? "#ffffff" : "#faf9f5"
        font.family: "Noto Sans"; font.pixelSize: 12; font.weight: Font.Medium
    }
    MouseArea {
        id: abArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ab.clicked()
    }
}
