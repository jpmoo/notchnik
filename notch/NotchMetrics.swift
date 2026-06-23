//
//  NotchMetrics.swift
//  notch
//

import CoreGraphics

enum NotchMetrics {
    /// Minimum grid cell width for adaptive columns (thumbnail + delete control padding).
    static let clipboardThumbnailColumnMinimum: CGFloat = 116

    /// Clipboard thumbnail tile size (square).
    static let clipboardThumbnailSize: CGFloat = 100
    /// Extra height on hover (downward). See `NotchOverlayView`.
    /// Smaller than `hoverHorizontalExpansion` because the notch's base height is much smaller than its width,
    /// so equal absolute pixels read as a much larger vertical change perceptually.
    static let hoverExpansion: CGFloat = 3

    /// Extra width on hover, each side (`total +2×` this). See `NotchOverlayView`.
    static let hoverHorizontalExpansion: CGFloat = 6

    /// Geometry for the separate "drop pill" panel — a small capsule that appears below the notch
    /// while a system-wide file drag is in progress. Sits well clear of macOS's edge-triggered
    /// Mission Control zone so the user can drop without flinging the cursor to the screen top.
    static let dropPillWidth: CGFloat = 180
    static let dropPillHeight: CGFloat = 44
    /// Distance from the screen's top edge to the **top** of the pill panel's content frame.
    /// Large enough to clear the menu bar + a comfortable safety margin from the edge gesture.
    static let dropPillTopOffset: CGFloat = 110

    /// Duration for panel resize when toggling click-expanded (matches SwiftUI where used).
    static let panelExpandAnimationDuration: Double = 0.28

    /// Fixed size when the overlay is clicked open (was 300×200; doubled).
    static let clickExpandedWidth: CGFloat = 740
    static let clickExpandedHeight: CGFloat = 330

    /// Offset subtracted from `NSScreen.frame.maxY` when anchoring the panel top (`anchorTopY = maxY - this`).
    /// Larger positive values move the overlay down; small negative values can pull it slightly up if host layout insets it.
    static let panelNudgeUp: CGFloat = 0

    /// Reserved space at the top of the expanded clipboard panel; content starts below (top-aligned).
    /// Tuned to clear the logo (36pt tall + 4pt top padding = ~40pt) plus a small gap.
    static let clipboardExpandedTopMargin: CGFloat = 24

    /// Cap for circular corners (`PanelSilhouetteShape`, `NotchFillShape`, …).
    static let panelCornerRadiusLimit: CGFloat = 10

    /// Reserved on **every** panel frame (collapsed + expanded): vertical budget for the outward top bump (`2·rb` below apex); matches `expandedPanelTopFlatInset` range.
    static let expandedPanelTopCornerBleed: CGFloat = 2 * panelCornerRadiusLimit
    /// Extra horizontal budget so top outward shoulders are never clipped by host/window bounds.
    static let expandedPanelSideCornerBleed: CGFloat = panelCornerRadiusLimit * 1.5

    /// Distance from view top (`y = minY`) to the inner flat top (`y = minY + 2·rb`) — spacer for content below the curved lip.
    static func expandedPanelTopFlatInset(width: CGFloat, height: CGFloat, limit: CGFloat = panelCornerRadiusLimit) -> CGFloat {
        2 * clampedCornerRadius(width: width, height: height, limit: limit)
    }

    /// `min(limit, min(width,height) · 0.22)` — keep in sync with shape `cap` logic.
    static func clampedCornerRadius(width: CGFloat, height: CGFloat, limit: CGFloat = panelCornerRadiusLimit) -> CGFloat {
        let cap = min(width, height) * 0.22
        return min(limit, cap)
    }

    /// Bottom outline stroke when hovered / expanded (`controlAccentColor`).
    static let notchAccentBorderWidth: CGFloat = 2

    /// Core blur (pt) for accent bottom edge bleeding into the panel / swollen notch body.
    static let panelBottomAccentGlowRadius: CGFloat = 3

    /// Softer diffusion pass for the bottom accent glow (stacked under the core).
    static let panelBottomAccentGlowDiffuseRadius: CGFloat = 8

    /// Shadow offset for bottom-edge glow (`negative` pulls blur upward into the interior).
    static let panelBottomAccentGlowYOffset: CGFloat = -1.5

    /// Core blur radius for accent glow beyond thumbnail border (hover / pasteboard-selected).
    static let clipboardThumbnailHighlightGlowRadius: CGFloat = 4

    /// Softer outer bloom for a more diffuse highlight (stacked under the core glow).
    static let clipboardThumbnailHighlightGlowOuterRadius: CGFloat = 11

    /// Space around the drawn shape so the drop shadow is not clipped by the panel edge.
    static let shadowPadding: CGFloat = 8

    static let dropShadowRadius: CGFloat = 4
    static let dropShadowYOffset: CGFloat = 2
    static let dropShadowOpacity: Double = 0.35
}
