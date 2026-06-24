//
//  NotchDropPillView.swift
//  notch
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Free-floating drop target shown below the notch only while a system-wide file drag is in
/// progress. Gives the user a generous, well-clear-of-the-screen-edge place to release a file
/// without triggering macOS's edge-based Mission Control gesture.
///
/// The drop hit area is a native AppKit `NSView` wrapped via `NSViewRepresentable`. SwiftUI's
/// `.onDrop` machinery was hanging the app when the underlying view animated / changed identity
/// at the moment AppKit was delivering the drop. AppKit's `NSDraggingDestination` callbacks are
/// independent of SwiftUI's view tree, so the drop target stays stable through the drop event
/// regardless of what the surrounding view is animating.
struct NotchDropPillView: View {
    @EnvironmentObject private var filePen: FilePenStore
    @EnvironmentObject private var fileDragMonitor: FileDragMonitor
    @State private var dropTargeted = false

    var body: some View {
        let active = fileDragMonitor.isFileDragActive
        ZStack {
            // Visible capsule — pure decoration; never receives input. Hit-testing disabled so
            // it can animate freely without colliding with the drop layer's lifecycle.
            Capsule(style: .continuous)
                .fill(Color.black.opacity(dropTargeted ? 0.92 : 0.78))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            dropTargeted ? Color.accentColor : Color.white.opacity(0.35),
                            lineWidth: dropTargeted ? 3 : 1.5
                        )
                )
                .overlay(
                    HStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Drop into pen")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                .frame(width: NotchMetrics.dropPillWidth, height: NotchMetrics.dropPillHeight)
                .opacity(active ? 1 : 0)
                .scaleEffect(active ? 1 : 0.85)
                .allowsHitTesting(false)

            // Drop layer — AppKit-native. Always in the SwiftUI tree (so its NSView lifecycle
            // is stable) but only accepts dragged types while `active` is true, set via a
            // simple register/unregister inside the view's `updateNSView`.
            NativeFileDropZone(
                isActive: active,
                isTargeted: $dropTargeted,
                onURLs: { urls in
                    for url in urls {
                        filePen.add(url)
                    }
                }
            )
            .frame(width: NotchMetrics.dropPillWidth, height: NotchMetrics.dropPillHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: active)
        .animation(.easeOut(duration: 0.14), value: dropTargeted)
    }
}

/// SwiftUI bridge for an AppKit `NSView` that owns the drop target. The visible pill capsule is
/// rendered separately in SwiftUI — this representable is purely about the drop hit region.
private struct NativeFileDropZone: NSViewRepresentable {
    let isActive: Bool
    @Binding var isTargeted: Bool
    let onURLs: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDropZoneNSView {
        let view = FileDropZoneNSView()
        view.onURLs = onURLs
        view.isTargetedHandler = { newValue in
            // Hop to next runloop pass before mutating the binding — avoids reentrancy with
            // AppKit drag callbacks.
            DispatchQueue.main.async { isTargeted = newValue }
        }
        view.setActive(isActive)
        return view
    }

    func updateNSView(_ nsView: FileDropZoneNSView, context: Context) {
        nsView.onURLs = onURLs
        nsView.setActive(isActive)
    }
}

/// Native drop view. We deliberately keep its lifecycle outside of any conditional SwiftUI
/// rendering and animate-driven re-identification, so AppKit can safely deliver the drop even
/// while the visible decoration is mid-animation. Registration for dragged types is the toggle
/// that controls whether drops are accepted.
private final class FileDropZoneNSView: NSView {
    var onURLs: (([URL]) -> Void)?
    var isTargetedHandler: ((Bool) -> Void)?
    private var isActive: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            registerForDraggedTypes([.fileURL])
        } else {
            unregisterDraggedTypes()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isActive else { return [] }
        isTargetedHandler?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargetedHandler?(false)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isActive ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { isActive }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { isTargetedHandler?(false) }
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              !urls.isEmpty else {
            return false
        }
        // Confirmation sound first (cheap), then defer the store mutation off the drop pass so
        // synchronous file I/O inside FilePenStore.add doesn't run inside AppKit's drag
        // conclusion.
        NSSound(named: "Pop")?.play()
        let handler = onURLs
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                handler?(urls)
            }
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        // Nothing extra — handler runs in performDragOperation.
    }
}
