pragma Singleton
import Quickshell
import QtQuick

// Design tokens for the robot's popups: one place for colour, type, radius,
// elevation and motion. Values come from the theme (themes/*.json, set by
// shell.qml from `chat.py info`); the fallbacks here are the linear theme.
Singleton {
    id: s
    property var theme: ({})
    property bool reducedMotion: false

    // --- colour
    readonly property color bgDeep: theme.bgDeep || "#020203"
    readonly property color bgBase: theme.bgBase || "#050506"
    readonly property color bgElevated: theme.bgElevated || "#0a0a0c"
    readonly property color bgTop: theme.bgTop || "#0a0a0f"
    readonly property color surface: theme.surface || "#0dffffff"
    readonly property color surfaceHover: theme.surfaceHover || "#14ffffff"
    readonly property color cardTop: theme.cardTop || "#14ffffff"
    readonly property color cardBottom: theme.cardBottom || "#05ffffff"
    readonly property color inputBg: theme.inputBg || "#0f0f12"
    readonly property color codeBg: theme.codeBg || bgElevated
    readonly property color fg: theme.fg || "#ededef"
    readonly property color subtle: theme.subtle || "#99ffffff"
    readonly property color muted: theme.muted || "#8a8f98"
    readonly property color accent: theme.accent || "#5e6ad2"
    readonly property color accentHi: theme.accentHi || "#6872d9"
    readonly property color accentDim: theme.accentDim || "#1e2142"
    readonly property color accentGlow: theme.accentGlow || "#4d5e6ad2"
    readonly property color line: theme.line || "#0fffffff"
    readonly property color lineHi: theme.lineHi || "#1affffff"
    readonly property color lineAccent: theme.lineAccent || "#4d5e6ad2"
    readonly property color onAccent: theme.onAccent || "#ffffff"
    readonly property color ok: theme.ok || "#4cc38a"
    readonly property color bad: theme.bad || "#eb5757"
    readonly property color warn: theme.warn || "#e5b454"
    readonly property color errorFg: theme.errorFg || "#f2a3a3"

    // --- type
    readonly property string sans: theme.sans || "Inter"
    readonly property string serif: theme.serif || sans
    readonly property string mono: theme.mono || "monospace"
    readonly property string spark: theme.spark || "✦"
    readonly property var spinGlyphs: theme.spinGlyphs || ["·", "•", "●", "•"]
    readonly property var verbs: theme.verbs || ["Thinking"]
    readonly property string welcome: theme.welcome || "How can I help?"

    // --- shape
    readonly property int radius: theme.radius ?? 16             // containers, cards
    readonly property int controlRadius: theme.controlRadius ?? 8 // buttons, inputs

    // --- effects (themes switch them on)
    readonly property var fx: theme.effects || ({})
    readonly property bool ambient: !!fx.ambient
    readonly property real gridOpacity: fx.grid ?? 0
    readonly property real noiseOpacity: fx.noise ?? 0
    readonly property real spotlight: fx.spotlight ?? 0
    readonly property bool shadows: !!fx.shadows
    readonly property bool gradientText: !!fx.gradientText
    readonly property var blobs: theme.blobs || []

    // --- motion: quick precise moves, expo-out, nothing bounces
    readonly property int quick: reducedMotion ? 0 : 200
    readonly property int standard: reducedMotion ? 0 : 300
    readonly property int entrance: reducedMotion ? 0 : 600
    readonly property var expoOut: [0.16, 1, 0.3, 1, 1, 1]

    // `c` may be a color or a "#rrggbb" string (theme JSON)
    function alpha(c, a) { const k = Qt.lighter(c, 1); return Qt.rgba(k.r, k.g, k.b, a) }
    function hex(c) { return "#" + [c.r, c.g, c.b].map(v => ("0" + Math.round(v * 255).toString(16)).slice(-2)).join("") }
}
