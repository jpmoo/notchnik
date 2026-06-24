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
    /// Deferred clear-to-false so the flag doesn't flip the same runloop pass AppKit is
    /// concluding an in-flight drop — that race was hanging the app on drop. We wait until
    /// the mouse has been up for a brief grace window before clearing.
    private var pendingClear: DispatchWorkItem?

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
        // Bit 0 of `pressedMouseButtons` is the left button.
        let leftDown = (NSEvent.pressedMouseButtons & 1) != 0
        if !leftDown {
            // Mouse just went up (or has been up). Don't flip immediately — AppKit may still
            // be delivering an in-flight drop, and a synchronous state mutation here causes
            // SwiftUI body invalidation + animations to interleave with the drop conclusion,
            // which was hanging the app. Schedule a deferred clear and let any in-flight drop
            // finish unwinding first.
            if isFileDragActive, pendingClear == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Re-check in case the mouse went down again before the timer fired.
                        let stillUp = (NSEvent.pressedMouseButtons & 1) == 0
                        if stillUp {
                            self.isFileDragActive = false
                        }
                        self.lastDragHadFiles = false
                        self.lastDragChangeCount = -1
                        self.pendingClear = nil
                    }
                }
                pendingClear = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
            }
            return
        }

        // Mouse is down. Cancel any pending clear (the user re-pressed before grace expired).
        pendingClear?.cancel()
        pendingClear = nil

        // Once we've already detected an active file drag, do NOT keep probing the drag
        // pasteboard. AppKit briefly locks it during the drop transition and a competing
        // main-thread read at that moment hangs the app. Active stays active until the
        // deferred mouse-up clear runs.
        if isFileDragActive { return }

        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != lastDragChangeCount {
            lastDragChangeCount = pb.changeCount
            // `types` is a cheap header read — no payload load.
            lastDragHadFiles = pb.types?.contains(.fileURL) ?? false
        }

        if lastDragHadFiles {
            isFileDragActive = true
        }
    }
}
