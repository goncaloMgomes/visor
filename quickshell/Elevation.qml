import QtQuick
import QtQuick.Effects

// Layered shadow for a rounded surface. Place it behind the surface, filling it:
// a 1 px highlight ring + a soft diffuse shadow + ambient darkness + an
// optional accent glow (`lifted`, e.g. on hover). Nothing when the theme has no shadows.
Item {
    id: el
    property real radius: Style.radius
    property bool lifted: false        // hover state: deeper shadow, accent glow
    property bool glow: false          // accent glow even at rest (primary buttons)
    property color glowColor: Style.accent
    property real depth: 1             // scales offset/blur: 0.5 for small controls
    visible: Style.shadows

    // diffuse + ambient darkness
    Rectangle {
        id: body
        anchors.fill: parent
        radius: el.radius
        color: "#000000"
        layer.enabled: el.visible
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#000000"
            shadowBlur: 1
            blurMax: Math.round(48 * el.depth)
            shadowVerticalOffset: (el.lifted ? 8 : 2) * el.depth
            shadowOpacity: el.lifted ? 0.55 : 0.42
            Behavior on shadowVerticalOffset { Motion {} }
            Behavior on shadowOpacity { Motion {} }
        }
        opacity: 0.999   // only the shadow shows; the body sits under the surface
    }
    // accent glow
    Rectangle {
        anchors.fill: parent
        radius: el.radius
        color: el.glowColor
        opacity: (el.glow || el.lifted) ? 1 : 0
        Behavior on opacity { Motion {} }
        layer.enabled: el.visible
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: el.glowColor
            shadowBlur: 1
            blurMax: Math.round(64 * el.depth)
            shadowOpacity: el.glow ? 0.3 : 0.1
            shadowVerticalOffset: el.glow ? 4 * el.depth : 0
        }
    }
}
