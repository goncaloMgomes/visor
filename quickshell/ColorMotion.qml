import QtQuick

// ColorAnimation counterpart of Motion.qml.
ColorAnimation {
    duration: Style.quick
    easing.type: Easing.BezierSpline
    easing.bezierCurve: Style.expoOut
}
