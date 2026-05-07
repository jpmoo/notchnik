//
//  FilePen.swift
//  notch
//
//  Drop target + drag source for files held in the panel between locations. Drops onto the collapsed
//  notch register the URL here (no clipboard write); dragging an item out hands the URL back to the
//  drop destination so Finder/desktop can move or copy it.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct FilePenItem: Identifiable, Codable, Equatable {
    let id: UUID
    let urlString: String
    let addedAt: Date
    /// Security-scoped bookmark (App Sandbox). Persists user-grant access across app launches so a
    /// pen entry created in a previous session is still readable today. Nil when bookmarking failed
    /// (e.g., source not user-granted) — in which case access is best-effort and may fail later.
    var bookmarkData: Data?

    var url: URL? { URL(string: urlString) }
}

@MainActor
final class FilePenStore: ObservableObject {
    @Published private(set) var items: [FilePenItem] = []
    /// Computed each `refreshMissingFlags` call; keyed by item id.
    @Published private(set) var missing: Set<UUID> = []

    private static let manifestFileName = "file_pen.json"
    private static let storageFolderName = "NotchNik"

    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Self.storageFolderName, isDirectory: true)
    }

    private var manifestURL: URL {
        storageDirectory.appendingPathComponent(Self.manifestFileName)
    }

    init() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        load()
        refreshMissingFlags()
    }

    /// Add a URL to the pen. Skips duplicates (same path) — the user just gets a recency bump.
    /// Caller should pass the URL that came directly from the powerbox-extended drop so we can
    /// capture a security-scoped bookmark while the grant is fresh.
    func add(_ url: URL) {
        guard url.isFileURL else { return }
        if let i = items.firstIndex(where: { ($0.url?.standardizedFileURL.path ?? "") == url.standardizedFileURL.path }) {
            let bumped = items.remove(at: i)
            items.insert(bumped, at: 0)
        } else {
            // Capture a bookmark while we still have the powerbox grant from the drop. Without this,
            // a relaunch would lose access to the file under sandbox.
            let bookmarkData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let item = FilePenItem(
                id: UUID(),
                urlString: url.absoluteString,
                addedAt: Date(),
                bookmarkData: bookmarkData
            )
            items.insert(item, at: 0)
        }
        refreshMissingFlags()
        save()
    }

    /// Resolves a fresh URL from the saved bookmark and starts a security-scoped access session.
    /// The caller MUST balance this with `stopAccess(_:)` once they're done — typically when the
    /// drag session ends. Returns nil if bookmarking is unavailable / stale; the caller can fall
    /// back to the stored `urlString` (best-effort, will fail under sandbox after relaunch).
    func startAccess(itemID: UUID) -> URL? {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let item = items[i]
        if let bookmark = item.bookmarkData {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let started = resolved.startAccessingSecurityScopedResource()
                if stale {
                    // Refresh the bookmark while we still have access; saves us a future failure.
                    if let fresh = try? resolved.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        items[i].bookmarkData = fresh
                        save()
                    }
                }
                return started ? resolved : nil
            }
        }
        return item.url
    }

    func stopAccess(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        missing.remove(id)
        save()
    }

    /// Removes any pen entry whose URL points at the same file as `url` (path-equality on the
    /// standardized file URL). Used to keep the pen in sync when the matching clipboard item is
    /// deleted — the user's expectation is that deleting from clipboard also clears the pen.
    func removeMatching(url: URL) {
        guard url.isFileURL else { return }
        let target = url.standardizedFileURL.path
        let beforeCount = items.count
        items.removeAll { item in
            (item.url?.standardizedFileURL.path ?? "") == target
        }
        if items.count != beforeCount {
            save()
        }
    }

    /// Removes every entry from the pen's manifest. Does NOT delete the underlying files — the pen
    /// only ever holds references, never copies, so there's nothing on disk to clean up here.
    func clearAll() {
        items.removeAll()
        missing.removeAll()
        save()
    }

    func clearMissing() {
        items.removeAll { missing.contains($0.id) }
        missing.removeAll()
        save()
    }

    /// Called shortly after a drag begins; if the source path no longer exists by the time we check,
    /// Finder/desktop performed a move and we should drop the pen entry. If the file is still there,
    /// the OS did a copy (or the drag was cancelled) and we leave the entry alone.
    func reconcileAfterDrag(itemID: UUID, after delay: TimeInterval = 2.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let item = self.items.first(where: { $0.id == itemID }) else { return }
            guard let url = item.url, url.isFileURL else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                self.remove(id: itemID)
            }
        }
    }

    /// Stat each URL and update `missing`. Cheap; safe to call on panel open.
    func refreshMissingFlags() {
        var nowMissing: Set<UUID> = []
        for item in items {
            guard let url = item.url, url.isFileURL else {
                nowMissing.insert(item.id); continue
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                nowMissing.insert(item.id)
            }
        }
        if nowMissing != missing { missing = nowMissing }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([FilePenItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}

// MARK: - Section view

struct FilePenView: View {
    @EnvironmentObject private var store: FilePenStore
    @EnvironmentObject private var settings: AppSettingsStore
    var searchText: String = ""

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 10)]

    private var dragHintText: String {
        let def = settings.filePenDefaultAction.label.lowercased()
        let cmd = settings.filePenCommandAction.label.lowercased()
        return "Drag to \(def), ⌘-drag to \(cmd)."
    }

    /// Live-filtered items (filename substring, case-insensitive). Empty query passes everything.
    private var visibleItems: [FilePenItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.items }
        return store.items.filter { item in
            (item.url?.lastPathComponent.lowercased().contains(needle)) ?? false
        }
    }

    var body: some View {
        if store.items.isEmpty {
            SectionPlaceholderView(
                icon: PanelSection.files.iconName,
                title: "File Pen",
                detail: "Drag a file onto the notch to drop it here. Drag it out to copy or move it."
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(dragHintText)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                let visible = visibleItems
                if visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.45))
                        Text("No files match “\(searchText)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(visible) { item in
                                FilePenCell(
                                    item: item,
                                    isMissing: store.missing.contains(item.id),
                                    onDelete: { store.remove(id: item.id) }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                    }
                    .clipped()
                }
            }
        }
    }
}

private struct FilePenCell: View {
    let item: FilePenItem
    let isMissing: Bool
    let onDelete: () -> Void

    @State private var hovered = false

    var body: some View {
        let url = item.url
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // 1. Visual icon and background.
                ZStack {
                    if let url {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .saturation(isMissing ? 0 : 1)
                            .opacity(isMissing ? 0.5 : 1)
                    } else {
                        Image(systemName: "questionmark.square.dashed")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .frame(width: 100, height: 70)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            (hovered ? Color.accentColor : Color.white.opacity(0.15)),
                            lineWidth: hovered ? 2 : 1
                        )
                )

                // 2. NSDraggingSource overlay (full cell area). On top of visual but UNDER buttons.
                //    Receives mouseDown only on areas not covered by hovered buttons.
                FilePenDragSource(
                    itemID: item.id,
                    onDragEnded: { op in
                        // .move: OS moved the file → remove the now-stale pen entry.
                        // .copy / [] (cancelled): leave the pen entry in place.
                        if op.contains(.move) { onDelete() }
                    }
                )
                .frame(width: 100, height: 70)

                // 3. Missing warning — purely decorative, doesn't intercept clicks.
                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .font(.system(size: 14))
                        .shadow(color: .black.opacity(0.55), radius: 1.5, y: 0.5)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .frame(width: 100, height: 70)
                        .allowsHitTesting(false)
                        .help("Original file is missing")
                }

                // 4. Hover trash button — top of stack, intercepts its own click.
                if hovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 1, y: 0.5)
                            .frame(width: 15, height: 15)
                            .padding(3.5)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove from File Pen")
                    .padding(2)
                }
            }
            .onHover { hovered = $0 }

            Text(url?.lastPathComponent ?? item.urlString)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(isMissing ? 0.45 : 0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(width: 110)
        }
        .padding(.top, 8)
    }
}

// MARK: - NSView-backed drag source

/// Bridges SwiftUI cells to AppKit's `NSDraggingSource` so we can control the drag operation mask.
/// The wrapped NSView's `sourceOperationMaskFor` honors macOS cross-app convention: COPY by default,
/// MOVE when Option is held. SwiftUI's `.onDrag` doesn't expose the mask, so we drop down to AppKit.
private struct FilePenDragSource: NSViewRepresentable {
    @EnvironmentObject private var store: FilePenStore
    @EnvironmentObject private var settings: AppSettingsStore
    let itemID: UUID
    let onDragEnded: (NSDragOperation) -> Void

    func makeNSView(context: Context) -> FilePenDragSourceView {
        let view = FilePenDragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FilePenDragSourceView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: FilePenDragSourceView) {
        view.itemID = itemID
        view.store = store
        view.onDragEnded = onDragEnded
        view.defaultDragOperation = settings.filePenDefaultAction.nsDragOperation
        view.commandDragOperation = settings.filePenCommandAction.nsDragOperation
    }
}

final class FilePenDragSourceView: NSView, NSDraggingSource {
    var itemID: UUID?
    weak var store: FilePenStore?
    var onDragEnded: ((NSDragOperation) -> Void)?
    /// Operation when no modifier is held. User-configurable; defaults to `.copy`.
    var defaultDragOperation: NSDragOperation = .copy
    /// Operation when ⌘ is held. User-configurable; defaults to `.move`.
    var commandDragOperation: NSDragOperation = .move

    private var mouseDownPoint: NSPoint?
    /// URL for which we currently hold a security-scoped access session. Released when the drag ends.
    private var activeAccessURL: URL?
    private static let dragThreshold: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return NSEvent.modifierFlags.contains(.command) ? commandDragOperation : defaultDragOperation
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let itemID, let store, let start = mouseDownPoint else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard hypot(dx, dy) >= Self.dragThreshold else { return }
        mouseDownPoint = nil

        // Resolve the bookmark and start the security-scoped session before handing the URL off to
        // the pasteboard. If we don't, a sandboxed app reads the URL but Finder gets a path it can't
        // verify against our entitlement, and the drop is silently refused.
        guard let liveURL = store.startAccess(itemID: itemID), liveURL.isFileURL else { return }
        activeAccessURL = liveURL

        let dragItem = NSDraggingItem(pasteboardWriter: liveURL as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: liveURL.path)
        let imgSize: CGFloat = 64
        let cursorPoint = self.convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(
            NSRect(x: cursorPoint.x - imgSize / 2, y: cursorPoint.y - imgSize / 2, width: imgSize, height: imgSize),
            contents: icon
        )
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let op = operation
        let releasedURL = activeAccessURL
        activeAccessURL = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let releasedURL { self.store?.stopAccess(releasedURL) }

            if op.contains(.move) {
                self.onDragEnded?(.move)
                return
            }
            // Sandbox/cross-app drags sometimes report `.copy` or `[]` even when the destination
            // performed a move. Filesystem fallback: if the source vanished, treat as move so the
            // pen entry doesn't linger as a dead reference.
            if let url = releasedURL {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        self.onDragEnded?(.move)
                    } else {
                        self.onDragEnded?(op)
                    }
                }
            } else {
                self.onDragEnded?(op)
            }
        }
    }
}
