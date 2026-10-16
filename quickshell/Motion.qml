import QtQuick

// A NumberAnimation with the design system's expo-out easing and standard
// duration: `Behavior on x { Motion {} }`, `Motion { duration: Style.quick }`.
NumberAnimation {
    duration: Style.standard
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Style.expoOut
}
