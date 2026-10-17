import QtQuick

// The design system's label: small mono capitals, widely spaced.
// For section tags and metadata ("RECENTS", "SHIFT+ESC TO STOP"); named Caption (QtQuick.Controls has a Label).
Text {
    color: Style.muted
    font.family: Style.mono
    font.pixelSize: 9
    font.letterSpacing: 1.4
    font.capitalization: Font.AllUppercase
}
