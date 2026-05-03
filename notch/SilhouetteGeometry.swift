//
//  SilhouetteGeometry.swift
//  notch
//
//  Shared outline: bottom = inward quarters; top = **outward** quarters (bulge uses NE/NW circle quadrants).
//  Centers at `(±rb, minY + rb)`. Outer boundary: arc along **θ ∈ [0, −π/2]** (TR) and **[−π/2, −π]** (TL), then flat at `y = minY`
//  between apexes — **not** the SE/SW quadrants (those look like an inner fillet / flat top).
//

import SwiftUI

enum SilhouetteGeometry {

    static func outwardTopPanelPath(in rect: CGRect, bottomCornerRadius: CGFloat = NotchMetrics.panelCornerRadiusLimit) -> Path {
        let W = rect.width
        let H = rect.height
        let minX = rect.minX
        let minY = rect.minY

        // Zero / undersized `rect` (common on first SwiftUI layout pass) makes `clampedCornerRadius` → 0 and kills all arcs.
        guard W >= 2, H >= 2 else {
            return Path(CGRect(x: minX, y: minY, width: max(W, 1), height: max(H, 1)))
        }

        let rb = max(
            1,
            min(
                NotchMetrics.clampedCornerRadius(width: W, height: H, limit: bottomCornerRadius),
                min(W, H) / 2 - 0.5
            )
        )

        // Vertical side walls inset by exactly one radius so top chamfers extend outward by `rb`.
        let sideBleed = min(rb, W / 2 - 1)
        let bodyMinX = minX + sideBleed
        let bodyMaxX = minX + W - sideBleed

        let brCenter = CGPoint(x: bodyMaxX - rb, y: minY + H - rb)
        let blCenter = CGPoint(x: bodyMinX + rb, y: minY + H - rb)

        // Apex flush with the rect top — the panel window is anchored to the screen top, so this lands on the bezel edge.
        let topY = minY
        let rightShoulder = CGPoint(x: bodyMaxX, y: topY + rb)
        let rightApex = CGPoint(x: bodyMaxX + rb, y: topY)
        let leftApex = CGPoint(x: bodyMinX - rb, y: topY)
        let leftShoulder = CGPoint(x: bodyMinX, y: topY + rb)

        // Centers for the outward top quarters sit *outside* the body so the swept arc bulges away from the interior.
        let trCenter = CGPoint(x: bodyMaxX + rb, y: topY + rb)
        let tlCenter = CGPoint(x: bodyMinX - rb, y: topY + rb)

        var path = Path()

        path.move(to: CGPoint(x: bodyMinX + rb, y: minY + H))
        path.addLine(to: CGPoint(x: bodyMaxX - rb, y: minY + H))

        // Bottom-right inward quarter (same convention as `ExpandedPanelBottomEdgeShape`).
        path.addArc(
            center: brCenter,
            radius: rb,
            startAngle: Angle(radians: Double(polarAngle(from: brCenter, to: CGPoint(x: bodyMaxX - rb, y: minY + H)))),
            endAngle: Angle(radians: Double(polarAngle(from: brCenter, to: CGPoint(x: bodyMaxX, y: minY + H - rb)))),
            clockwise: true
        )

        // Right vertical side up to top shoulder.
        path.addLine(to: rightShoulder)

        // Top-right outward quarter: shoulder (west of trCenter) → apex (north of trCenter).
        // `clockwise: false` selects the short NW-quadrant sweep; `true` would take the 270° long way.
        path.addArc(
            center: trCenter,
            radius: rb,
            startAngle: Angle(radians: Double(polarAngle(from: trCenter, to: rightShoulder))),
            endAngle: Angle(radians: Double(polarAngle(from: trCenter, to: rightApex))),
            clockwise: false
        )

        // Flat top segment between outer scallop apexes.
        path.addLine(to: leftApex)

        // Top-left outward quarter: apex (north of tlCenter) → shoulder (east of tlCenter).
        path.addArc(
            center: tlCenter,
            radius: rb,
            startAngle: Angle(radians: Double(polarAngle(from: tlCenter, to: leftApex))),
            endAngle: Angle(radians: Double(polarAngle(from: tlCenter, to: leftShoulder))),
            clockwise: false
        )

        // Left vertical side down.
        path.addLine(to: CGPoint(x: bodyMinX, y: minY + H - rb))

        path.addArc(
            center: blCenter,
            radius: rb,
            startAngle: Angle(radians: Double(polarAngle(from: blCenter, to: CGPoint(x: bodyMinX, y: minY + H - rb)))),
            endAngle: Angle(radians: Double(polarAngle(from: blCenter, to: CGPoint(x: bodyMinX + rb, y: minY + H)))),
            clockwise: true
        )

        path.closeSubpath()
        return path
    }

    private static func polarAngle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

}

/// Unified panel outline for expanded clipboard + swollen hover (`SilhouetteGeometry.outwardTopPanelPath`).
struct PanelSilhouetteShape: Shape {
    var bottomCornerRadius: CGFloat = NotchMetrics.panelCornerRadiusLimit

    func path(in rect: CGRect) -> Path {
        SilhouetteGeometry.outwardTopPanelPath(in: rect, bottomCornerRadius: bottomCornerRadius)
    }
}

/// Black panel fill — `Shape.fill` so layout and antialiasing match `PanelSilhouetteShape` / `clipShape` exactly.
struct PanelSilhouetteCanvasFill: View {
    var width: CGFloat
    var height: CGFloat
    var bottomCornerRadius: CGFloat = NotchMetrics.panelCornerRadiusLimit

    var body: some View {
        PanelSilhouetteShape(bottomCornerRadius: bottomCornerRadius)
            .fill(Color.black)
            .frame(width: width, height: height)
    }
}
