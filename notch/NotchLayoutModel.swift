//
//  NotchLayoutModel.swift
//  notch
//

import AppKit
import Combine
import SwiftUI

/// Top-level "section" the expanded panel is currently showing. Other sections are placeholders for now.
enum PanelSection: Int, CaseIterable {
    case clipboard
    case calendar
    case files
    case insights

    var iconName: String {
        switch self {
        case .clipboard: return "list.clipboard"
        case .calendar: return "calendar"
        case .files: return "tray.full"
        case .insights: return "sparkles"
        }
    }

    var label: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .calendar: return "Calendar"
        case .files: return "File Pen"
        case .insights: return "Insights"
        }
    }

    var previous: PanelSection {
        let count = PanelSection.allCases.count
        return PanelSection(rawValue: (rawValue - 1 + count) % count) ?? .clipboard
    }

    var next: PanelSection {
        PanelSection(rawValue: (rawValue + 1) % PanelSection.allCases.count) ?? .clipboard
    }

    /// Visibility-aware navigation: cycles only through sections in `order`. Falls back to `self`
    /// when nothing else is visible. Caller passes `settings.orderedVisibleSections`.
    func previous(in order: [PanelSection]) -> PanelSection {
        guard !order.isEmpty else { return self }
        let i = order.firstIndex(of: self) ?? 0
        return order[(i - 1 + order.count) % order.count]
    }

    func next(in order: [PanelSection]) -> PanelSection {
        guard !order.isEmpty else { return self }
        let i = order.firstIndex(of: self) ?? 0
        return order[(i + 1) % order.count]
    }
}

final class NotchLayoutModel: ObservableObject {
    @Published var baseWidth: CGFloat
    @Published var baseHeight: CGFloat
    @Published var isClickExpanded = false
    /// True while the AppKit window frame is mid-animation (expand or collapse). The expanded clipboard view
    /// uses this to skip its heavy per-frame work (grid layout, dual-shadow accent stroke) until the window
    /// frame settles, so the resize itself isn't dragged down by SwiftUI relayout cost.
    @Published var isFrameAnimating = false
    /// Currently-selected section in the bottom carousel. Defaults to clipboard on launch.
    @Published var currentSection: PanelSection = .clipboard
    /// Direction of the most recent section change. Drives the slide-in/out transition on the section
    /// content view: `.forward` slides new content in from the right, `.backward` from the left.
    @Published var sectionTransitionDirection: SectionTransitionDirection = .forward

    enum SectionTransitionDirection { case forward, backward }

    /// Updates current section and the implied transition direction in one animated transaction.
    ///
    /// Subtlety: SwiftUI captures a view's removal transition at the time it was last present in the
    /// view tree. If we change `sectionTransitionDirection` and `currentSection` in the *same* render
    /// pass, the about-to-be-removed view has already cached the OLD direction's removal — so the
    /// first time we reverse direction after a string of same-direction swipes, the outgoing panel
    /// flies the wrong way. Fix: update direction first, let SwiftUI re-render with the new transition
    /// modifier value visible on the still-present view, then on the next run-loop tick swap the
    /// section under `withAnimation` so the removal uses the freshly-captured direction.
    func switchSection(to target: PanelSection) {
        guard target != currentSection else { return }
        let direction: SectionTransitionDirection = target == currentSection.next ? .forward : .backward
        if sectionTransitionDirection != direction {
            sectionTransitionDirection = direction
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentSection != target else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    self.currentSection = target
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                currentSection = target
            }
        }
    }
    /// When `GeometryReader.safeAreaInsets.top` is 0 (hosting views sometimes omit it), pull the overlay up by this much so the lip isn’t clipped / inset visually.
    @Published private(set) var estimatedTopSafeInset: CGFloat = 0

    init(baseWidth: CGFloat, baseHeight: CGFloat) {
        self.baseWidth = baseWidth
        self.baseHeight = baseHeight
    }

    convenience init(screen: NSScreen) {
        let size = NotchGeometry.notchSize(for: screen)
        self.init(baseWidth: size.width, baseHeight: size.height)
        estimatedTopSafeInset = size.height
    }

    func update(from screen: NSScreen) {
        let size = NotchGeometry.notchSize(for: screen)
        baseWidth = size.width
        baseHeight = size.height
        estimatedTopSafeInset = size.height
    }
}
