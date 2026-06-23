//
//  FileDragMonitor.swift
//  notch
//

import AppKit
import Combine

/// Detects system-wide left-mouse drags that carry file URLs on the drag pasteboard and publishes
/// `isFileDragActive` while one is happening. `NotchOverlayView` listens to this to temporarily
/// grow its drop catchment downward; `AppDelegate` listens to resize the host panel to match.
///
/// Uses `NSEvent` global + local monitors so we see drags from any app (Finder, Mail, etc.), not
/// just our own. Global monitors don't fire inside fullscreen apps that have grabbed input — that's
/// a rare case for file drags and not worth a more invasive hook.
@MainActor
final class FileDragMonitor: ObservableObject {
    @Published private(set) var isFileDragActive: Bool = false

    private var globalDragMonitor: Any?
    private var localDragMonitor: Any?
    private var globalUpMonitor: Any?
    private var localUpMonitor: Any?

    /// Most-recent drag pasteboard `changeCount` we evaluated. When it changes, we re-read; while
    /// it's unchanged we skip the pasteboard probe to keep the per-event handler near-free.
    private var lastDragChangeCount: Int = -1

    init() {
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateDragPasteboard() }
        }
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated { self?.evaluateDragPasteboard() }
            return event
        }
        globalUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearDragState() }
        }
        localUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            MainActor.assumeIsolated { self?.clearDragState() }
            return event
        }
    }

    deinit {
        for monitor in [globalDragMonitor, localDragMonitor, globalUpMonitor, localUpMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    private func evaluateDragPasteboard() {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != lastDragChangeCount else {
            // Already known — pasteboard hasn't been rewritten since the last check, so the
            // file-drag verdict is unchanged. No work needed.
            return
        }
        lastDragChangeCount = pb.changeCount
        let hasFiles: Bool = {
            let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
               !urls.isEmpty {
                return true
            }
            return false
        }()
        if hasFiles != isFileDragActive {
            isFileDragActive = hasFiles
        }
    }

    private func clearDragState() {
        if isFileDragActive { isFileDragActive = false }
        lastDragChangeCount = -1
    }
}
