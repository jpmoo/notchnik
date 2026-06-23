//
//  NotchOverlayView.swift
//  notch
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `.plain` still dims its label to ~70% opacity on press. Using this style keeps the silhouette
/// fully opaque the whole click — otherwise the brief fade reads as a gray/semi-transparent flash
/// while the click-expand animation is starting.
struct NotchPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Visual fill over the notch; grows on hover so the black area reads like a larger notch.
struct NotchOverlayView: View {
    @EnvironmentObject private var layout: NotchLayoutModel
    @EnvironmentObject private var clipboard: ClipboardHistoryStore
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var filePen: FilePenStore
    @State private var hovered = false
    @State private var dropTargeted = false

    /// Height of the hit-test band for hover/drop. Locked to the hardware notch's height as
    /// computed by `NotchGeometry` — that's the exact menu-bar band on the user's screen, no
    /// further. Anything below this passes mouse events through to the apps underneath.
    private var hoverHitHeight: CGFloat {
        layout.baseHeight
    }

    private var hoverExpandedWidth: CGFloat {
        layout.baseWidth
            + 2 * NotchMetrics.hoverHorizontalExpansion
            + 2 * NotchMetrics.expandedPanelSideCornerBleed
    }
    private var hoverExpandedHeight: CGFloat { layout.baseHeight + NotchMetrics.hoverExpansion }

    private var shapeWidth: CGFloat {
        if layout.isClickExpanded { return NotchMetrics.clickExpandedWidth }
        return hovered ? hoverExpandedWidth : layout.baseWidth
    }

    private var shapeHeight: CGFloat {
        if layout.isClickExpanded { return NotchMetrics.clickExpandedHeight }
        return hovered ? hoverExpandedHeight : layout.baseHeight
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if layout.isClickExpanded {
                    ClipboardHistoryExpandedView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.identity)
                        .padding(.horizontal, NotchMetrics.shadowPadding)
                        .padding(.bottom, NotchMetrics.shadowPadding)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Button {
                                // Both state changes share a no-animation transaction so the if/else swap
                                // between collapsed and expanded branches doesn't crossfade.
                                var t = Transaction()
                                t.disablesAnimations = true
                                withTransaction(t) {
                                    hovered = false
                                    // Apply the user's "default tool" preference before opening so
                                    // the panel renders the right section as it animates in.
                                    let target = settings.sectionToOpenWith()
                                    if layout.currentSection != target {
                                        layout.currentSection = target
                                    }
                                    layout.isClickExpanded = true
                                }
                            } label: {
                                ZStack {
                                    Group {
                                        if hovered {
                                            PanelSilhouetteCanvasFill(
                                                width: shapeWidth,
                                                height: shapeHeight + NotchMetrics.expandedPanelTopCornerBleed
                                            )
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        } else {
                                            NotchFillShape()
                                                .fill(Color.black)
                                        }
                                    }

                                    // Bottom accent border on hover removed — the stroke was awkward to fit
                                    // against the curved silhouette.
                                }
                                .frame(
                                    width: shapeWidth,
                                    height: shapeHeight + (hovered ? NotchMetrics.expandedPanelTopCornerBleed : 0),
                                    alignment: .top
                                )
                                .shadow(
                                    color: Color.black.opacity(NotchMetrics.dropShadowOpacity),
                                    radius: NotchMetrics.dropShadowRadius,
                                    x: 0,
                                    y: NotchMetrics.dropShadowYOffset
                                )
                            }
                            .buttonStyle(NotchPressButtonStyle())
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.14)) {
                                    hovered = hovering
                                }
                            }
                            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                                let any = handleFileDrop(providers: providers)
                                if any { playDropConfirmationSound() }
                                return any
                            }
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, NotchMetrics.shadowPadding)
                    .padding(.bottom, NotchMetrics.shadowPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.identity)
                }
            }
            // AppKit animates the window frame; the expanded view must size with that frame (see ClipboardHistoryExpandedView).
            // Disable SwiftUI’s implicit animation on this toggle or it stacks with the resize and reads as a sideways slide.
            .animation(nil, value: layout.isClickExpanded)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Diagnostic: removed `.padding(.top, -topLayoutPull(...))` to test whether the bumps are being clipped above the window top.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    /// Plays a short system sound when a file lands in the pen. Visual confirmation near the notch
    /// would compete with the hardware notch on most MacBooks, so we use audio instead. "Pop" is a
    /// short, light system sound that reads as a successful drop confirmation.
    private func playDropConfirmationSound() {
        NSSound(named: "Pop")?.play()
    }

    /// Pulls file URLs out of dropped item providers and hands them to `FilePenStore`. We use
    /// `loadObject(ofClass: NSURL.self)` instead of `loadDataRepresentation` so the URL arrives with
    /// its powerbox security extension intact — we need that to capture a security-scoped bookmark.
    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var any = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: NSURL.self) else { continue }
            any = true
            _ = provider.loadObject(ofClass: NSURL.self) { obj, _ in
                guard let url = obj as? URL, url.isFileURL else { return }
                Task { @MainActor in
                    filePen.add(url)
                }
            }
        }
        return any
    }

    private static func topLayoutPull(swiftUI: CGFloat, fallback: CGFloat) -> CGFloat {
        if swiftUI > 0.5 { return swiftUI }
        return fallback
    }
}

/// Collapsed hover body: flat top, rounded bottom. **Swollen** fill uses `PanelSilhouetteShape`.
private struct NotchFillShape: Shape {
    private let bottomCornerRadius: CGFloat = NotchMetrics.panelCornerRadiusLimit

    func path(in rect: CGRect) -> Path {
        let minX = rect.minX
        let minY = rect.minY
        let W = rect.width
        let H = rect.height
        let r = NotchMetrics.clampedCornerRadius(width: W, height: H, limit: bottomCornerRadius)

        let blCenter = CGPoint(x: minX + r, y: minY + H - r)
        let brCenter = CGPoint(x: minX + W - r, y: minY + H - r)

        var path = Path()
        path.move(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: minX + W, y: minY))
        path.addLine(to: CGPoint(x: minX + W, y: minY + H - r))

        path.addArc(
            center: brCenter,
            radius: r,
            startAngle: Angle(radians: Double(polarAngle(from: brCenter, to: CGPoint(x: minX + W, y: minY + H - r)))),
            endAngle: Angle(radians: Double(polarAngle(from: brCenter, to: CGPoint(x: minX + W - r, y: minY + H)))),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: minX + r, y: minY + H))

        path.addArc(
            center: blCenter,
            radius: r,
            startAngle: Angle(radians: Double(polarAngle(from: blCenter, to: CGPoint(x: minX + r, y: minY + H)))),
            endAngle: Angle(radians: Double(polarAngle(from: blCenter, to: CGPoint(x: minX, y: minY + H - r)))),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: minX, y: minY))
        path.closeSubpath()
        return path
    }
}

/// Bottom edge only — matches `NotchFillShape` circular arcs.
private struct NotchFillBottomEdgeShape: Shape {
    private let bottomCornerRadius: CGFloat = NotchMetrics.panelCornerRadiusLimit

    func path(in rect: CGRect) -> Path {
        let minX = rect.minX
        let minY = rect.minY
        let W = rect.width
        let H = rect.height
        // Inset by half the stroke width so the centered stroke sits fully inside the silhouette
        // instead of half-spilling into the panel gutter below the notch.
        let inset = NotchMetrics.notchAccentBorderWidth / 2
        let r = NotchMetrics.clampedCornerRadius(width: W, height: H, limit: bottomCornerRadius)
        let sideBleed = min(r, W / 2 - 1)
        let bodyMinX = minX + sideBleed + inset
        let bodyMaxX = minX + W - sideBleed - inset
        let bottomY = minY + H - inset

        let blCenter = CGPoint(x: bodyMinX + r, y: bottomY - r)
        let brCenter = CGPoint(x: bodyMaxX - r, y: bottomY - r)

        var path = Path()
        path.move(to: CGPoint(x: bodyMinX, y: bottomY - r))

        path.addArc(
            center: blCenter,
            radius: r,
            startAngle: Angle(radians: Double(polarAngle(from: blCenter, to: CGPoint(x: bodyMinX, y: bottomY - r)))),
            endAngle: Angle(radians: Double(polarAngle(from: blCenter, to: CGPoint(x: bodyMinX + r, y: bottomY)))),
            clockwise: true
        )

        path.addLine(to: CGPoint(x: bodyMaxX - r, y: bottomY))

        path.addArc(
            center: brCenter,
            radius: r,
            startAngle: Angle(radians: Double(polarAngle(from: brCenter, to: CGPoint(x: bodyMaxX - r, y: bottomY)))),
            endAngle: Angle(radians: Double(polarAngle(from: brCenter, to: CGPoint(x: bodyMaxX, y: bottomY - r)))),
            clockwise: true
        )

        return path
    }
}

/// Hit-test shape that covers only the top band of the panel (matching the hardware notch's
/// vertical extent). Anything below this height passes mouse events through, so maximized
/// browser tabs are still clickable directly under the notch's drop shadow region.
private struct NotchHoverHitShape: Shape {
    let height: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(height, rect.height)))
    }
}

private func polarAngle(from center: CGPoint, to point: CGPoint) -> CGFloat {
    atan2(point.y - center.y, point.x - center.x)
}

#Preview {
    NotchOverlayView()
        .environmentObject(NotchLayoutModel(baseWidth: 174, baseHeight: 32))
        .environmentObject(ClipboardHistoryStore(settings: AppSettingsStore()))
        .environmentObject(NotchSessionActions())
        .environmentObject(AppSettingsStore())
        .environmentObject(FilePenStore())
        .environmentObject(FocusScoreEngine(
            chat: InsightsChatStore(),
            activity: ActivityWatcher(),
            calendar: CalendarFeedStore(),
            settings: AppSettingsStore()
        ))
        .frame(
            width: 174 + 2 * NotchMetrics.hoverHorizontalExpansion + 2 * NotchMetrics.shadowPadding,
            height: 32 + NotchMetrics.hoverExpansion + NotchMetrics.shadowPadding
        )
        .background(Color.gray.opacity(0.35))
}
