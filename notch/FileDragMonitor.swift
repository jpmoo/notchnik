//
//  FileDragMonitor.swift
//  notch
//

import AppKit
import Combine

/// Detects whether the user is currently dragging a file (from any app on the system) and
/// publishes `isFileDragActive`. `NotchOverlayView` listens to this to temporarily grow its drop
/// catchment downward; `AppDelegate` listens to resize the host panel to match.
///
/// Polls `NSEvent.pressedMouseButtons` + `NSPasteboard(name: .drag)` at 30Hz instead of using
/// `NSEvent` monitors — those monitors get suppressed while an OS-level drag session is in
/// progress (events are routed directly to the drag manager), so they miss the very state we
/// want to detect. The poll is microscopic (one Int read + one pasteboard `types` check) and
/// only flips `isFileDragActive` when the verdict changes, so SwiftUI bodies don't churn.
@MainActor
final class FileDragMonitor: ObservableObject {
    @Published private(set) var isFileDragActive: Bool = false

    private var timer: Timer?
    /// Memoize the last drag pasteboard `changeCount` we evaluated. While a drag is in progress
    /// the count is stable, so we only do the (slightly heavier) `types` check when it shifts.
    private var lastDragChangeCount: Int = -1
    private var lastDragHadFiles: Bool = false

    init() {
        // 30Hz is plenty for UI feedback — the user perceives drag-start → catchment-grow as
        // instantaneous at this rate. `tolerance` lets the OS coalesce the firings to save CPU.
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.01
        timer = t
    }

    deinit {
        timer?.invalidate()
    }

    private func tick() {
        // Bit 0 of `pressedMouseButtons` is the left button. If it's not held, there's no drag —
        // bail before touching the pasteboard at all.
        let leftDown = (NSEvent.pressedMouseButtons & 1) != 0
        guard leftDown else {
            if isFileDragActive { isFileDragActive = false }
            lastDragHadFiles = false
            return
        }

        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != lastDragChangeCount {
            lastDragChangeCount = pb.changeCount
            // `types` is a cheap header read — no payload load. We only need to know whether a
            // file-URL representation was registered, not to read the URLs themselves.
            lastDragHadFiles = pb.types?.contains(.fileURL) ?? false
        }

        if lastDragHadFiles != isFileDragActive {
            isFileDragActive = lastDragHadFiles
        }
    }
}
