import QtQuick
import QtQuick.Shapes

// Text drawn as vector paths with a gradient fill:
//   vertical (default)  white → white 70 %, for headlines
//   shimmer: true       accent → light indigo → accent, sweeping sideways
// Falls back to plain text when the theme has no gradientText.
Item {
    id: gt
    property string text
    property font font
    property bool shimmer: false
    property color color: Style.fg
    implicitWidth: metrics.advanceWidth
    implicitHeight: metrics.height

    TextMetrics { id: metrics; font: gt.font; text: gt.text }

    Text {
        visible: !Style.gradientText
        text: gt.text; font: gt.font; color: gt.color
    }

    property real phase: 0
    NumberAnimation on phase {
        running: gt.shimmer && gt.visible && Style.gradientText && !Style.reducedMotion
        from: 0; to: 1; duration: 2400; loops: Animation.Infinite
    }

    Shape {
        visible: Style.gradientText
        width: gt.implicitWidth; height: gt.implicitHeight
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillGradient: gt.shimmer ? shimmerGrad : vertGrad
            PathText { x: 0; y: 0; text: gt.text; font: gt.font }
        }
    }
    LinearGradient {
        id: vertGrad
        x1: 0; y1: 0; x2: 0; y2: gt.implicitHeight
        GradientStop { position: 0; color: Style.fg }
        GradientStop { position: 0.5; color: Style.alpha(Style.fg, 0.95) }
        GradientStop { position: 1; color: Style.alpha(Style.fg, 0.7) }
    }
    LinearGradient {
        id: shimmerGrad
        spread: ShapeGradient.RepeatSpread
        x1: (gt.phase - 1) * gt.implicitWidth * 2; y1: 0
        x2: x1 + gt.implicitWidth * 2; y2: 0
        GradientStop { position: 0; color: Style.accent }
        GradientStop { position: 0.5; color: Qt.lighter(Style.accent, 1.45) }
        GradientStop { position: 1; color: Style.accent }
    }
}
