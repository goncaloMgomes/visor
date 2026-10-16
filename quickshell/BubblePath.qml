import QtQuick
import QtQuick.Shapes

// pill body + curved tail as one outline; drawn twice, the darker copy
// nudged down-left so the line looks thicker there, like a pen stroke
// (pill-shaped body with a curved tail rising from its top-right towards the robot)
ShapePath {
    id: bp
    property real h          // body height
    property real rr         // end radius
    property real aa         // x where the right end starts curving
    property real tip        // x of the tail's tip
    joinStyle: ShapePath.RoundJoin
    capStyle: ShapePath.RoundCap
    startX: bp.rr; startY: 0
    PathLine { x: bp.aa - 30; y: 0 }
    PathQuad { x: bp.tip - 1; y: -16; controlX: bp.aa - 12; controlY: -2 }       // sweep up
    PathQuad { x: bp.tip + 3; y: -15; controlX: bp.tip + 1.5; controlY: -19 }   // round tip
    PathQuad { x: bp.aa + 2; y: 0.6; controlX: bp.aa - 1; controlY: -7 }         // back into the body
    // quarter arcs + straight sides: one half-circle arc per end only fits
    // when h == 2*rr; on taller (multi-line) bubbles Qt grows the radius to
    // h/2 and the ends bulge out past the bubble's box and get cut off
    PathArc { x: bp.aa + bp.rr; y: bp.rr; radiusX: bp.rr; radiusY: bp.rr }
    PathLine { x: bp.aa + bp.rr; y: bp.h - bp.rr }
    PathArc { x: bp.aa; y: bp.h; radiusX: bp.rr; radiusY: bp.rr }
    PathLine { x: bp.rr; y: bp.h }
    PathArc { x: 0; y: bp.h - bp.rr; radiusX: bp.rr; radiusY: bp.rr }
    PathLine { x: 0; y: bp.rr }
    PathArc { x: bp.rr; y: 0; radiusX: bp.rr; radiusY: bp.rr }
}
