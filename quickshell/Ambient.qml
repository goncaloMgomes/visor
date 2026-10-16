import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

// The layered background of a popup surface:
//   1. a radial base gradient from the top centre (bgTop → bgBase → bgDeep)
//   2. a noise tile, barely there, against banding
//   3. pools of coloured light (the theme's `blobs`) floating slowly
//   4. a 64 px grid
// Every layer is clipped to the rounded rectangle (`radius`). Blob positions
// and sizes are fractions of the surface. Animates only while `running`.
Item {
    id: amb
    property real radius: Style.radius
    property bool running: true

    // The light moves a few pixels over seconds, so a 20 fps clock is plenty
    // (and costs a third of animating every frame).
    property real t: 0
    Timer {
        running: amb.running && Style.ambient && !Style.reducedMotion && amb.visible
        repeat: true
        interval: 50
        onTriggered: amb.t += interval
    }

    // 1 + 3: one Shape, every path the same rounded rectangle with its own gradient
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: amb.width / 2; centerY: 0
                focalX: centerX; focalY: centerY
                centerRadius: Math.max(amb.width, amb.height) * 1.1
                GradientStop { position: 0; color: Style.bgTop }
                GradientStop { position: 0.5; color: Style.bgBase }
                GradientStop { position: 1; color: Style.bgDeep }
            }
            PathRectangle { width: amb.width; height: amb.height; radius: amb.radius }
        }
    }
    Repeater {
        model: Style.ambient ? Style.blobs : []
        delegate: Shape {
            id: blob
            required property var modelData
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            readonly property real size: Math.max(amb.width, amb.height) * (modelData.r ?? 0.6)
            // float: 0 → -20 px → 0; pulse: opacity breathing (both sine, from the shared clock)
            readonly property real fl: modelData.float || 0
            readonly property real pl: modelData.pulse || 0
            readonly property real drift: fl ? -10 + 10 * Math.cos(2 * Math.PI * amb.t / fl) : 0
            readonly property real breathe: pl ? 0.725 + 0.275 * Math.cos(2 * Math.PI * amb.t / pl) : 1
            opacity: breathe
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: amb.width * blob.modelData.x + blob.drift * 0.35
                    centerY: amb.height * blob.modelData.y + blob.drift
                    focalX: centerX; focalY: centerY
                    centerRadius: blob.size / 2
                    GradientStop { position: 0; color: Style.alpha(blob.modelData.color, blob.modelData.opacity) }
                    GradientStop { position: 0.5; color: Style.alpha(blob.modelData.color, blob.modelData.opacity * 0.55) }
                    GradientStop { position: 1; color: Style.alpha(blob.modelData.color, 0) }
                }
                PathRectangle { width: amb.width; height: amb.height; radius: amb.radius }
            }
        }
    }

    // 2 + 4: static layers, rounded by a mask (re-rendered only on resize)
    Item {
        anchors.fill: parent
        visible: Style.noiseOpacity > 0 || Style.gridOpacity > 0
        layer.enabled: visible
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: roundMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
        }
        Image {
            anchors.fill: parent
            source: "assets/noise.png"
            fillMode: Image.Tile
            opacity: Style.noiseOpacity
            smooth: false
        }
        Canvas {
            id: grid
            anchors.fill: parent
            opacity: Style.gridOpacity
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const g = getContext("2d")
                g.reset()
                g.strokeStyle = "#ffffff"
                g.lineWidth = 1
                g.beginPath()
                for (let x = 64.5; x < width; x += 64) { g.moveTo(x, 0); g.lineTo(x, height) }
                for (let y = 64.5; y < height; y += 64) { g.moveTo(0, y); g.lineTo(width, y) }
                g.stroke()
            }
        }
    }
    Rectangle {
        id: roundMask
        anchors.fill: parent
        radius: amb.radius
        visible: false
        layer.enabled: true
    }
}
