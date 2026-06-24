//
//  FileDragMonitor.swift
//  notch
//

import AppKit
import Combine

/// Detects whether the user is currently dragging a file (from any app on the system) and
/// publishes `isFileDragActive`. `NotchDropPillView` listens to this to show the drop pill only
/// during a real drag.
///
/// Polls at 30Hz. The fundamental signal is "the drag pasteboard's `changeCount` advanced WHILE
/// the left mouse button is held" — that's how a source app announces a fresh drag session. We
/// continuously track the pasteboard's count while the mouse is idle, then watch for it to
/// advance during a mouse-down. This rejects two false positives that bit earlier versions: a
/// plain click on our own UI (the drag pb may carry stale file URLs from a previous drag), and
/// re-detecting the same drag after the user briefly releases and re-presses.
@MainActor
final class FileDragMonitor: ObservableObject {
    @Published private(set) var isFileDragActive: Bool = false

    private var timer: Timer?
    /// Snapshot of `NSPasteboard(name: .drag).changeCount` while the mouse is idle. A drag
    /// session is "real" iff the count advances past this snapshot during a mouse-down.
    private var idleChangeCount: Int = 0
    /// Deferred clear-to-false so the flag doesn't flip the same runloop pass AppKit is
    /// concluding an in-flight drop — that race was hanging the app on drop.
    private var pendingClear: DispatchWorkItem?

    init() {
        // Seed the idle baseline so a stale pb at app launch doesn't get treated as a fresh drag
        // on the very first click.
        idleChangeCount = NSPasteboard(name: .drag).changeCount

        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.01
        timer = t
    }

    deinit {
        timer?.invalidate()
        pendingClear?.cancel()
    }

    private func tick() {
        let leftDown = (NSEvent.pressedMouseButtons & 1) != 0
        let pb = NSPasteboard(name: .drag)

        if !leftDown {
            // Mouse is up. Keep the idle baseline tracking the current pb so the next mouse-down
            // has an accurate "what was the count before I clicked" reference. Then schedule a
            // deferred clear of the active flag — AppKit may still be concluding a drop, and
            // flipping @Published mid-conclusion was hanging the app.
            idleChangeCount = pb.changeCount
            if isFileDragActive, pendingClear == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let stillUp = (NSEvent.pressedMouseButtons & 1) == 0
                        if stillUp { self.isFileDragActive = false }
                        self.pendingClear = nil
                    }
                }
                pendingClear = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
            }
            return
        }

        // Mouse is down. Cancel any pending clear (user re-pressed within grace window).
        pendingClear?.cancel()
        pendingClear = nil

        // Once a fresh drag is confirmed, don't keep probing the drag pasteboard — AppKit
        // briefly locks it during the drop transition and a competing read at that moment
        // was hanging the app.
        if isFileDragActive { return }

        // Only flag a fresh drag when the count advances PAST the idle baseline AND files are
        // on the drag pb. Equal-or-lower count means whatever's on the pb is stale (e.g., the
        // user just clicked a button; the pb wasn't rewritten by a source app).
        guard pb.changeCount > idleChangeCount else { return }
        if (pb.types?.contains(.fileURL)) ?? false {
            isFileDragActive = true
        }
    }
}
