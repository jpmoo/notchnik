//
//  NotchDropPillView.swift
//  notch
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Free-floating drop target shown below the notch *only* while a system-wide file drag is in
/// progress. Gives the user a generous, well-clear-of-the-screen-edge place to release a file
/// without triggering macOS's edge-based Mission Control gesture. Accepts file URLs and forwards
/// them to `FilePenStore`.
struct NotchDropPillView: View {
    @EnvironmentObject private var filePen: FilePenStore
    @EnvironmentObject private var fileDragMonitor: FileDragMonitor
    @State private var dropTargeted = false

    var body: some View {
        // The capsule view is ALWAYS present (so its `.onDrop` doesn't get torn down at the
        // moment AppKit delivers the drop — that race was hanging the app). Visibility is
        // controlled by opacity and hit-testing instead. Outside an active drag, opacity is 0
        // and hit-testing is disabled, so the pill is invisible and inert.
        let active = fileDragMonitor.isFileDragActive
        ZStack {
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
                .contentShape(Capsule(style: .continuous))
                .opacity(active ? 1 : 0)
                .scaleEffect(active ? 1 : 0.85)
                .allowsHitTesting(active)
                .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                    let any = handleFileDrop(providers: providers)
                    if any { NSSound(named: "Pop")?.play() }
                    return any
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: active)
        .animation(.easeOut(duration: 0.14), value: dropTargeted)
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var any = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: NSURL.self) else { continue }
            any = true
            _ = provider.loadObject(ofClass: NSURL.self) { [filePen] obj, _ in
                guard let url = obj as? URL, url.isFileURL else { return }
                // Hop to main via DispatchQueue (not Task) and add an extra tick so the drop
                // completion has fully unwound before we mutate FilePenStore — synchronous file
                // I/O inside `add` (manifest write + bookmark capture) on the same runloop pass
                // as the drop delivery has been freezing the drop transition.
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        filePen.add(url)
                    }
                }
            }
        }
        return any
    }
}
