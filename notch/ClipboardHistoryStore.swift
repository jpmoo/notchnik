//
//  ClipboardHistoryStore.swift
//  notch
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum ClipboardPayload {
    case text(String)
    case image(NSImage)
    case file(URL)
    case fileGroup([URL])
}

struct ClipboardItem: Identifiable {
    let id: UUID
    var isPinned: Bool
    let payload: ClipboardPayload
    let createdAt: Date
    /// Pre-rasterized 2× thumbnail for image payloads. Cells render this instead of the full-resolution
    /// NSImage so SwiftUI doesn't re-downsample multi-megapixel originals on every layout pass.
    /// For `.file` items pointing to image types, this is filled asynchronously via QuickLook.
    var thumbnail: NSImage?
    /// `.file` items whose URL points to an image type render full-size like an `.image` cell instead of
    /// the icon + filename layout. Set at insert/load time so the view doesn't have to hit disk metadata.
    var rendersAsImagePreview: Bool = false
    /// True for `.file`/`.fileGroup` items whose backing path no longer exists. Cells dim the thumbnail and
    /// show a warning glyph; pasting still attempts the URL but Finder will refuse with its usual error.
    var isStaleFileReference: Bool = false
    /// SHA-256 of the canonical PNG bytes for `.image` payloads. Cached at insert/load so identity checks
    /// against the current pasteboard (capture-if-missing, active-item refresh) don't have to re-encode
    /// every stored NSImage to TIFF/PNG on every poll.
    var imageHash: Data?
}

private func sha256Hash(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

/// Canonical PNG-byte view of whatever image is on the pasteboard. Tries direct `public.png` first
/// (zero re-encode), then `public.tiff`, then HEIC/JPEG/HEIF via NSBitmapImageRep. Used both as the
/// disk-saved representation and the source for `imageHash`.
private func canonicalPasteboardImagePNG(_ pb: NSPasteboard) -> Data? {
    if let png = pb.data(forType: .png) { return png }
    if let tiff = pb.data(forType: .tiff),
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        return png
    }
    let other: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.jpeg-2000")
    ]
    for type in other {
        if let data = pb.data(forType: type),
           let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
    }
    return nil
}

/// Last-resort PNG derivation when the original pasteboard bytes weren't available (e.g., reading from
/// `[NSImage.self]` pasteboard objects). Pays the `tiffRepresentation` cost we otherwise avoid.
private func derivePNG(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

/// Cheap existence check for a single payload's underlying paths. Group is "stale if any URL is missing".
private func clipboardFileMissing(for payload: ClipboardPayload) -> Bool {
    switch payload {
    case .file(let url):
        return url.isFileURL && !FileManager.default.fileExists(atPath: url.path)
    case .fileGroup(let urls):
        return urls.contains { $0.isFileURL && !FileManager.default.fileExists(atPath: $0.path) }
    case .text, .image:
        return false
    }
}

/// Longest-side budget for cached thumbnails (points). Bitmap is rasterized at 2× for Retina.
private let clipboardThumbnailMaxDimension: CGFloat = 200

/// One-shot Finder-icon lookup. `NSWorkspace.icon(forFile:)` consults LaunchServices and may hit disk
/// (custom icons, `.app` bundles, embedded thumbnails); cells previously called it on every layout.
private func fileIcon(for url: URL) -> NSImage {
    NSWorkspace.shared.icon(forFile: url.path)
}

/// True when the file's UTI conforms to `public.image` — used to decide whether to request a Quick Look
/// thumbnail. Cheap: only reads the resource value, never opens the file.
private func fileURLPointsToImage(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let values = try? url.resourceValues(forKeys: [.contentTypeKey])
    return values?.contentType?.conforms(to: .image) ?? false
}

/// Async preview generation via QuickLook. Never loads the full file into memory the way `NSImage(contentsOf:)`
/// does. Falls back to nil if QuickLook can't produce a representation; callers keep the generic Finder icon.
private func generateImagePreviewThumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
    let pointSize = NSSize(width: clipboardThumbnailMaxDimension, height: clipboardThumbnailMaxDimension)
    let scale = NSScreen.main?.backingScaleFactor ?? 2.0
    let request = QLThumbnailGenerator.Request(
        fileAt: url,
        size: pointSize,
        scale: scale,
        representationTypes: .thumbnail
    )
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
        let image = rep?.nsImage
        DispatchQueue.main.async { completion(image) }
    }
}

private func makeClipboardThumbnail(from image: NSImage) -> NSImage? {
    let size = image.size
    guard size.width > 1, size.height > 1 else { return nil }
    let scale = min(clipboardThumbnailMaxDimension / max(size.width, size.height), 1.0)
    let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    let pixelsWide = Int((target.width * 2).rounded())
    let pixelsHigh = Int((target.height * 2).rounded())
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = target

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: target),
               from: .zero,
               operation: .copy,
               fraction: 1.0)

    let thumb = NSImage(size: target)
    thumb.addRepresentation(rep)
    return thumb
}

private struct PersistedClipboardRecord: Codable {
    enum PayloadKind: String, Codable {
        case text
        case image
        case file
        case fileGroup
    }

    let id: UUID
    let createdAt: Date
    let kind: PayloadKind
    let text: String?
    let imageFileName: String?
    let fileURLString: String?
    let fileURLStrings: [String]?
    /// Omitted in older manifests = unpinned.
    let isPinned: Bool?
}

final class ClipboardHistoryStore: ObservableObject {
    private static let storageFolderName = "NotchNik"
    private static let manifestFileName = "clipboard_history.json"
    private static let imagesFolderName = "clipboard_images"

    @Published private(set) var items: [ClipboardItem] = []
    /// History item whose payload currently matches the general pasteboard (text, image, or file).
    @Published private(set) var pasteboardActiveItemID: UUID?

    /// Optional hook fired whenever a file URL is captured from the pasteboard (single file or
    /// any URL within a file group). AppDelegate wires this to FilePenStore.add when the user
    /// has opted in via `filePenAutoCaptureFromPasteboard`. Receives URLs in the order they
    /// appeared on the pasteboard.
    var onFileURLCaptured: ((URL) -> Void)?

    /// Fired when a file URL leaves clipboard history — either because the user deleted that
    /// clip or cleared the entire history. AppDelegate wires this to FilePenStore.removeMatching
    /// so the pen mirrors the deletion. Unlike `onFileURLCaptured` this is NOT gated on the
    /// auto-capture toggle: an explicit clipboard deletion always cascades.
    var onFileURLRemoved: ((URL) -> Void)?

    private let settings: AppSettingsStore
    private var lastChangeCount: Int
    private var skipNextCapture = false
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Memoized hash of the current pasteboard image, keyed by `pb.changeCount`. Computing the hash
    /// requires reading PNG/TIFF bytes (and possibly converting); caching means we do it at most once
    /// per actual clipboard change, not once per 0.35s poll.
    private var cachedPasteboardImageHash: (changeCount: Int, hash: Data?)?

    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Self.storageFolderName, isDirectory: true)
    }

    private var manifestURL: URL {
        storageDirectory.appendingPathComponent(Self.manifestFileName)
    }

    private var imagesDirectory: URL {
        storageDirectory.appendingPathComponent(Self.imagesFolderName, isDirectory: true)
    }

    init(settings: AppSettingsStore) {
        self.settings = settings
        lastChangeCount = NSPasteboard.general.changeCount
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        loadPersistedItems()
        enforceMaxItems(settings.maxClipboardItems)
        settings.$maxClipboardItems
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] max in
                self?.enforceMaxItems(max)
            }
            .store(in: &cancellables)
        startPolling()
    }

    private func enforceMaxItems(_ max: Int) {
        let cap = AppSettingsStore.clampMax(max)
        guard items.count > cap else { return }
        let overflow = items.count - cap
        let dropped = Array(items.suffix(overflow))
        items.removeLast(overflow)
        for old in dropped {
            if case .image = old.payload {
                deleteImageFile(id: old.id)
            }
        }
        persist()
        refreshPasteboardActiveItem()
    }

    /// Pinned clips first (newest copy time first), then unpinned (newest first).
    private func normalizeDisplayOrder() {
        let pinned = items.filter(\.isPinned).sorted { $0.createdAt > $1.createdAt }
        let unpinned = items.filter { !$0.isPinned }.sorted { $0.createdAt > $1.createdAt }
        items = pinned + unpinned
    }

    func togglePin(id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isPinned.toggle()
        normalizeDisplayOrder()
        persist()
        refreshPasteboardActiveItem()
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func loadPersistedItems() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([PersistedClipboardRecord].self, from: data) else { return }

        var loaded: [ClipboardItem] = []
        for record in records {
            switch record.kind {
            case .text:
                guard let text = record.text else { continue }
                loaded.append(
                    ClipboardItem(
                        id: record.id,
                        isPinned: record.isPinned ?? false,
                        payload: .text(text),
                        createdAt: record.createdAt,
                        thumbnail: nil
                    )
                )
            case .image:
                guard let name = record.imageFileName else { continue }
                let url = imagesDirectory.appendingPathComponent(name)
                guard let imageData = try? Data(contentsOf: url), let img = NSImage(data: imageData) else { continue }
                loaded.append(
                    ClipboardItem(
                        id: record.id,
                        isPinned: record.isPinned ?? false,
                        payload: .image(img),
                        createdAt: record.createdAt,
                        thumbnail: makeClipboardThumbnail(from: img),
                        imageHash: sha256Hash(imageData)
                    )
                )
            case .file:
                guard let raw = record.fileURLString,
                      let url = URL(string: raw) else { continue }
                loaded.append(
                    ClipboardItem(
                        id: record.id,
                        isPinned: record.isPinned ?? false,
                        payload: .file(url),
                        createdAt: record.createdAt,
                        thumbnail: fileIcon(for: url),
                        rendersAsImagePreview: fileURLPointsToImage(url),
                        isStaleFileReference: clipboardFileMissing(for: .file(url))
                    )
                )
            case .fileGroup:
                guard let raws = record.fileURLStrings else { continue }
                let urls = raws.compactMap { URL(string: $0) }
                guard !urls.isEmpty else { continue }
                loaded.append(
                    ClipboardItem(
                        id: record.id,
                        isPinned: record.isPinned ?? false,
                        payload: .fileGroup(urls),
                        createdAt: record.createdAt,
                        thumbnail: urls.first.flatMap { fileIcon(for: $0) },
                        isStaleFileReference: clipboardFileMissing(for: .fileGroup(urls))
                    )
                )
            }
        }
        items = loaded
        normalizeDisplayOrder()
        refreshPasteboardActiveItem()

        // Regenerate previews for image-file items now that they're back in `items`.
        for item in items {
            if case .file(let url) = item.payload {
                requestImagePreviewIfNeeded(for: item.id, url: url)
            }
        }
    }

    /// Marks which clip matches what’s on `NSPasteboard.general` for UI highlighting.
    func refreshPasteboardActiveItem() {
        let pb = NSPasteboard.general

        let fileURLs = fileURLsFromPasteboard(pb)
        if fileURLs.count > 1 {
            pasteboardActiveItemID = items.first { item in
                if case .fileGroup(let existing) = item.payload {
                    return fileURLGroupsEqual(existing, fileURLs)
                }
                return false
            }?.id
            return
        }

        if let fileURL = firstFileURLFromPasteboard(pb) {
            pasteboardActiveItemID = items.first { item in
                if case .file(let existing) = item.payload {
                    return fileURLsEqual(existing, fileURL)
                }
                return false
            }?.id
            return
        }

        if let str = pb.string(forType: .string), !str.isEmpty {
            pasteboardActiveItemID = items.first { item in
                if case .text(let t) = item.payload { return t == str }
                return false
            }?.id
            return
        }

        if let hash = currentPasteboardImageHash() {
            pasteboardActiveItemID = items.first { $0.imageHash == hash }?.id
            return
        }

        pasteboardActiveItemID = nil
    }

    /// Hash of the current pasteboard image's canonical PNG bytes, computed at most once per
    /// `pb.changeCount`. Returns nil when no image is on the pasteboard.
    private func currentPasteboardImageHash() -> Data? {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        if let cache = cachedPasteboardImageHash, cache.changeCount == cc {
            return cache.hash
        }
        let hash = canonicalPasteboardImagePNG(pb).map(sha256Hash)
        cachedPasteboardImageHash = (cc, hash)
        return hash
    }

    /// On-demand sync for UI events (e.g. opening expanded view): captures current pasteboard payload
    /// only when it's not already represented in history.
    func captureCurrentPasteboardIfMissing() {
        let pb = NSPasteboard.general
        let fileURLs = fileURLsFromPasteboard(pb)
        if fileURLs.count > 1 {
            let exists = items.contains { item in
                if case .fileGroup(let existing) = item.payload {
                    return fileURLGroupsEqual(existing, fileURLs)
                }
                return false
            }
            if !exists {
                insert(.fileGroup(fileURLs))
            } else {
                refreshPasteboardActiveItem()
            }
            // Forward to file-pen hook regardless of dedupe, so the pen stays in sync with whatever
            // is currently on the pasteboard. FilePenStore.add already dedupes by path.
            fileURLs.forEach { onFileURLCaptured?($0) }
            return
        }

        // Same ordering as `captureCurrentPasteboard`: file URL beats image so we don't decode the file.
        if let fileURL = fileURLs.first {
            let exists = items.contains { item in
                if case .file(let existing) = item.payload {
                    return fileURLsEqual(existing, fileURL)
                }
                return false
            }
            if !exists {
                insert(.file(fileURL))
            } else {
                refreshPasteboardActiveItem()
            }
            onFileURLCaptured?(fileURL)
            return
        }

        if let pasteboardHash = currentPasteboardImageHash() {
            if items.contains(where: { $0.imageHash == pasteboardHash }) {
                refreshPasteboardActiveItem()
            } else if let img = firstImageFromPasteboard(pb) {
                insert(.image(img), sourcePNG: canonicalPasteboardImagePNG(pb))
            }
            return
        }

        if let str = firstStringFromPasteboard(pb), !str.isEmpty {
            let exists = items.contains { item in
                if case .text(let existing) = item.payload {
                    return existing == str
                }
                return false
            }
            if !exists {
                insert(.text(str))
            } else {
                refreshPasteboardActiveItem()
            }
            return
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let records: [PersistedClipboardRecord] = items.map { item in
            switch item.payload {
            case .text(let string):
                return PersistedClipboardRecord(
                    id: item.id,
                    createdAt: item.createdAt,
                    kind: .text,
                    text: string,
                    imageFileName: nil,
                    fileURLString: nil,
                    fileURLStrings: nil,
                    isPinned: item.isPinned
                )
            case .image:
                let name = "\(item.id.uuidString).png"
                return PersistedClipboardRecord(
                    id: item.id,
                    createdAt: item.createdAt,
                    kind: .image,
                    text: nil,
                    imageFileName: name,
                    fileURLString: nil,
                    fileURLStrings: nil,
                    isPinned: item.isPinned
                )
            case .file(let url):
                return PersistedClipboardRecord(
                    id: item.id,
                    createdAt: item.createdAt,
                    kind: .file,
                    text: nil,
                    imageFileName: nil,
                    fileURLString: url.absoluteString,
                    fileURLStrings: nil,
                    isPinned: item.isPinned
                )
            case .fileGroup(let urls):
                return PersistedClipboardRecord(
                    id: item.id,
                    createdAt: item.createdAt,
                    kind: .fileGroup,
                    text: nil,
                    imageFileName: nil,
                    fileURLString: nil,
                    fileURLStrings: urls.map(\.absoluteString),
                    isPinned: item.isPinned
                )
            }
        }

        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: [.atomic])
    }

    /// Writes a pre-encoded PNG buffer for an image clip. Replaces the old `saveImageToDisk(NSImage)`
    /// path that forced a `tiffRepresentation` round-trip — we already have PNG bytes by this point.
    private func writeImagePNG(_ png: Data, id: UUID) {
        let url = imagesDirectory.appendingPathComponent("\(id.uuidString).png")
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try? png.write(to: url, options: .atomic)
    }

    private func deleteImageFile(id: UUID) {
        let url = imagesDirectory.appendingPathComponent("\(id.uuidString).png")
        try? FileManager.default.removeItem(at: url)
    }

    private func startPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        if pb.changeCount != lastChangeCount {
            lastChangeCount = pb.changeCount
            if skipNextCapture {
                skipNextCapture = false
            } else {
                captureCurrentPasteboard()
            }
        }
        refreshPasteboardActiveItem()
    }

    private func captureCurrentPasteboard() {
        let pb = NSPasteboard.general
        let fileURLs = fileURLsFromPasteboard(pb)

        // File URLs always win over the image branch — otherwise `NSImage(contentsOf:)` loads and decodes
        // the entire file (multi-GB stall, huge in-memory NSImage) just to decide it was a file all along.
        if fileURLs.count > 1 {
            insert(.fileGroup(fileURLs))
            fileURLs.forEach { onFileURLCaptured?($0) }
            return
        }
        if let url = fileURLs.first {
            insert(.file(url))
            onFileURLCaptured?(url)
            return
        }

        if let img = firstImageFromPasteboard(pb) {
            insert(.image(img), sourcePNG: canonicalPasteboardImagePNG(pb))
            return
        }

        if let str = firstStringFromPasteboard(pb), !str.isEmpty {
            insert(.text(str))
        }
    }

    private func firstImageFromPasteboard(_ pb: NSPasteboard) -> NSImage? {
        if let objects = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = objects.first {
            return img
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let img = imageFromFileURL(url) {
                    return img
                }
            }
        }

        let candidateTypes: [NSPasteboard.PasteboardType] = [
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.jpeg-2000"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif")
        ]
        for type in candidateTypes {
            if let data = pb.data(forType: type), let img = NSImage(data: data) {
                return img
            }
        }

        if let item = pb.pasteboardItems?.first {
            if let raw = item.string(forType: NSPasteboard.PasteboardType("public.file-url")),
               let url = URL(string: raw),
               let img = imageFromFileURL(url) {
                return img
            }

            if let raw = item.string(forType: .fileURL),
               let url = URL(string: raw),
               let img = imageFromFileURL(url) {
                return img
            }
        }

        if let tiff = pb.data(forType: .tiff), let img = NSImage(data: tiff) {
            return img
        }

        if let png = pb.data(forType: .png), let img = NSImage(data: png) {
            return img
        }

        return nil
    }

    private func imageFromFileURL(_ url: URL) -> NSImage? {
        guard url.isFileURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func firstFileURLFromPasteboard(_ pb: NSPasteboard) -> URL? {
        // Don't filter by `imageFromFileURL == nil` — that calls `NSImage(contentsOf:)` and would load
        // multi-GB files into memory just to check. Capture flow now treats every file URL as `.file`.
        fileURLsFromPasteboard(pb).first
    }

    private func fileURLsFromPasteboard(_ pb: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let read = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            urls.append(contentsOf: read.filter(\.isFileURL))
        }

        if let item = pb.pasteboardItems?.first {
            let types: [NSPasteboard.PasteboardType] = [
                .fileURL,
                NSPasteboard.PasteboardType("public.file-url")
            ]
            for type in types {
                if let raw = item.string(forType: type),
                   let url = URL(string: raw),
                   url.isFileURL {
                    urls.append(url)
                }
            }
        }

        var seen = Set<String>()
        var unique: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    private func fileURLsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func fileURLGroupsEqual(_ lhs: [URL], _ rhs: [URL]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if !fileURLsEqual(a, b) { return false }
        }
        return true
    }

    private func firstStringFromPasteboard(_ pb: NSPasteboard) -> String? {
        if !fileURLsFromPasteboard(pb).isEmpty {
            return nil
        }

        if let objects = pb.readObjects(forClasses: [NSString.self], options: nil) as? [NSString],
           let s = objects.first as String?, !s.isEmpty {
            return s
        }

        if let objects = pb.readObjects(forClasses: [NSAttributedString.self], options: nil) as? [NSAttributedString],
           let s = objects.first?.string, !s.isEmpty {
            return s
        }

        if let objects = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = objects.first {
            let s = url.absoluteString
            if !s.isEmpty { return s }
        }

        if let s = pb.string(forType: .string), !s.isEmpty {
            return s
        }

        let candidateTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
            NSPasteboard.PasteboardType("public.utf16-plain-text"),
            NSPasteboard.PasteboardType("public.text"),
            NSPasteboard.PasteboardType("public.url")
        ]

        if let item = pb.pasteboardItems?.first {
            for type in candidateTypes {
                if let s = item.string(forType: type), !s.isEmpty {
                    return s
                }
            }
            for type in item.types {
                if let s = item.string(forType: type), !s.isEmpty {
                    return s
                }
            }
        }

        return nil
    }

    private func insert(_ payload: ClipboardPayload, sourcePNG: Data? = nil) {
        let id = UUID()
        let created = Date()

        switch payload {
        case .text(let string):
            let item = ClipboardItem(id: id, isPinned: false, payload: .text(string), createdAt: created, thumbnail: nil)
            items.insert(item, at: 0)
        case .image(let image):
            // Prefer raw PNG bytes from the pasteboard so we skip `image.tiffRepresentation` (the
            // multi-megabyte hot path for big images). `derivePNG` is a fallback for in-memory NSImages.
            let png = sourcePNG ?? derivePNG(from: image)
            if let png { writeImagePNG(png, id: id) }
            let item = ClipboardItem(
                id: id,
                isPinned: false,
                payload: .image(image),
                createdAt: created,
                thumbnail: makeClipboardThumbnail(from: image),
                imageHash: png.map(sha256Hash)
            )
            items.insert(item, at: 0)
        case .file(let url):
            let isImage = fileURLPointsToImage(url)
            let item = ClipboardItem(
                id: id,
                isPinned: false,
                payload: .file(url),
                createdAt: created,
                thumbnail: fileIcon(for: url),
                rendersAsImagePreview: isImage,
                isStaleFileReference: clipboardFileMissing(for: .file(url))
            )
            items.insert(item, at: 0)
            requestImagePreviewIfNeeded(for: id, url: url)
        case .fileGroup(let urls):
            let item = ClipboardItem(
                id: id,
                isPinned: false,
                payload: .fileGroup(urls),
                createdAt: created,
                thumbnail: urls.first.flatMap { fileIcon(for: $0) },
                isStaleFileReference: clipboardFileMissing(for: .fileGroup(urls))
            )
            items.insert(item, at: 0)
        }

        normalizeDisplayOrder()

        let overflow = items.count - settings.maxClipboardItems
        if overflow > 0 {
            let dropped = Array(items.suffix(overflow))
            items.removeLast(overflow)
            for old in dropped {
                if case .image = old.payload {
                    deleteImageFile(id: old.id)
                }
            }
        }

        persist()
        refreshPasteboardActiveItem()
    }

    func applyToPasteboard(_ item: ClipboardItem) {
        skipNextCapture = true

        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.payload {
        case .text(let string):
            pb.setString(string, forType: .string)
        case .image(let image):
            pb.writeObjects([image])
        case .file(let url):
            pb.writeObjects([url as NSURL])
        case .fileGroup(let urls):
            pb.writeObjects(urls.map { $0 as NSURL })
        }

        lastChangeCount = pb.changeCount
        refreshPasteboardActiveItem()
    }

    /// Re-checks the existence of every `.file`/`.fileGroup` payload's backing path and updates the stale
    /// flag in place. Cheap (one stat call per file); call when the panel opens, not on every render.
    func refreshFileExistenceFlags() {
        for i in items.indices {
            let stale = clipboardFileMissing(for: items[i].payload)
            if items[i].isStaleFileReference != stale {
                items[i].isStaleFileReference = stale
            }
        }
    }

    /// For `.file` items whose URL points to an image type, request a QuickLook preview asynchronously and
    /// swap the cached Finder icon for the preview when it arrives. No-op for non-image types.
    private func requestImagePreviewIfNeeded(for id: UUID, url: URL) {
        guard fileURLPointsToImage(url) else { return }
        generateImagePreviewThumbnail(for: url) { [weak self] preview in
            guard let self, let preview else { return }
            guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[i].thumbnail = preview
        }
    }

    /// Opens a Quick Look preview of the item without writing anything to the pasteboard. Text and image
    /// payloads materialize as temp files; file/file-group payloads point QuickLook at the original URL.
    func previewItem(_ item: ClipboardItem) {
        let url: URL?
        switch item.payload {
        case .text(let str):
            url = writeTempPreviewText(str, id: item.id)
        case .image:
            let candidate = imagesDirectory.appendingPathComponent("\(item.id.uuidString).png")
            url = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        case .file(let fileURL):
            url = fileURL
        case .fileGroup(let urls):
            url = urls.first
        }
        guard let url else { return }
        QuickLookPreviewer.shared.show(url: url)
    }

    private func writeTempPreviewText(_ text: String, id: UUID) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNikPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id.uuidString).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Removes every clip from history and the on-disk PNGs that back image payloads. Does NOT touch the
    /// system pasteboard — clearing history shouldn't surprise the user by also wiping what they just copied.
    func clearAll() {
        for item in items {
            if case .image = item.payload {
                deleteImageFile(id: item.id)
            }
            switch item.payload {
            case .file(let url):
                onFileURLRemoved?(url)
            case .fileGroup(let urls):
                urls.forEach { onFileURLRemoved?($0) }
            case .text, .image:
                break
            }
        }
        items.removeAll()
        cachedPasteboardImageHash = nil
        persist()
        refreshPasteboardActiveItem()
    }

    func deleteItem(id: UUID) {
        let wasActive = pasteboardActiveItemID == id
        if let item = items.first(where: { $0.id == id }) {
            if case .image = item.payload {
                deleteImageFile(id: id)
            }
            switch item.payload {
            case .file(let url):
                onFileURLRemoved?(url)
            case .fileGroup(let urls):
                urls.forEach { onFileURLRemoved?($0) }
            case .text, .image:
                break
            }
        }
        items.removeAll { $0.id == id }
        // If the deleted item is what the system pasteboard currently holds, wipe the pasteboard too —
        // otherwise the next poll tick would re-capture it and the deletion would silently undo itself.
        if wasActive {
            let pb = NSPasteboard.general
            skipNextCapture = true
            pb.clearContents()
            lastChangeCount = pb.changeCount
        }
        persist()
        refreshPasteboardActiveItem()
    }
}

/// Routes clip preview requests to the system Quick Look panel. Holding a single shared instance avoids
/// the dance of inserting/removing ourselves from the responder chain — the panel is happy as long as a
/// data source is set before `reloadData()`.
final class QuickLookPreviewer: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPreviewer()
    private var previewURL: URL?
    private var willCloseObserver: NSObjectProtocol?
    /// Whether a Quick Look preview is currently on screen. AppDelegate reads this to suppress its
    /// outside-click panel-dismiss while preview is up (clicks in QL are technically "outside").
    private(set) var isVisible: Bool = false

    func show(url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        // `.accessory` apps can take key windows just fine — no need to promote to `.regular` (which
        // would put a dock icon up). Activating ignoringOtherApps is enough to bring QL forward.
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        isVisible = true

        // Our overlay panel sits at `.statusBar` which is above QL's level — drop it to `.normal` so QL
        // appears in front, then restore when QL closes.
        adjustOverlayPanelLevel(.normal)

        if willCloseObserver == nil {
            willCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.isVisible = false
                self?.adjustOverlayPanelLevel(.statusBar)
            }
        }
    }

    /// Walks `NSApp.windows` to find our `NotchOverlayPanel` and sets its level. Avoids tight coupling
    /// to AppDelegate — the previewer doesn't need a back-reference, just the runtime window list.
    private func adjustOverlayPanelLevel(_ level: NSWindow.Level) {
        for window in NSApp.windows where window is NotchOverlayPanel {
            window.level = level
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}
