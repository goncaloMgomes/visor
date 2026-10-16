import QtQuick
import QtQuick.Shapes

// A soft accent glow (300 px, Style.spotlight opacity) that follows the
// cursor over its parent and fades in on hover. Put it right after the
// parent's background so content stays above it.
Shape {
    id: spot
    property real radius: Style.radius
    property real diameter: 300
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    visible: Style.spotlight > 0
    opacity: hover.hovered ? 1 : 0
    Behavior on opacity { Motion {} }

    HoverHandler { id: hover; target: spot.parent }

    ShapePath {
        strokeWidth: -1
        fillGradient: RadialGradient {
            centerX: hover.point.position.x; centerY: hover.point.position.y
            focalX: centerX; focalY: centerY
            centerRadius: spot.diameter / 2
            GradientStop { position: 0; color: Style.alpha(Style.accent, Style.spotlight) }
            GradientStop { position: 1; color: Style.alpha(Style.accent, 0) }
        }
        PathRectangle { width: spot.width; height: spot.height; radius: spot.radius }
    }
}
