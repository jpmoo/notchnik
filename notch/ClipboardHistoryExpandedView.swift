//
//  ClipboardHistoryExpandedView.swift
//  notch
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Builds a drag item provider that exposes an image in multiple formats so it can be dropped
/// into anything that accepts a paste — rich text fields (Mail, Messages, Notes), image wells,
/// Finder, etc. Registers PNG, TIFF, and the NSImage object itself; targets pick whichever
/// representation they understand. Plain single-line text fields (URL bars, search) won't
/// accept images regardless — same as a paste.
private func makeImageItemProvider(_ image: NSImage) -> NSItemProvider {
    let provider = NSItemProvider()
    let tiff = image.tiffRepresentation
    if let tiff,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
    }
    if let tiff {
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { completion in
            completion(tiff, nil)
            return nil
        }
    }
    // Some receivers ask for the NSImage object directly; keep this as a fallback.
    provider.registerObject(image, visibility: .all)
    return provider
}

/// Builds a drag item provider for one or more files that "behaves like a paste" — Finder /
/// file inputs receive the file URL(s); plain-text fields receive the file path(s) as text
/// (newline-joined for multiple), matching what NSPasteboard would yield from a Finder copy.
/// SwiftUI's `.onDrag` only allows ONE NSItemProvider, so for multi-file groups we drag the
/// first URL as the file representation but expose all paths in the text fallback.
private func makeFileItemProvider(urls: [URL]) -> NSItemProvider {
    let primary = urls.first
    let provider = primary.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
    let pathsText = urls.map { $0.path }.joined(separator: "\n")
    if let data = pathsText.data(using: .utf8), !data.isEmpty {
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
    }
    return provider
}

/// Bottom boundary only: left arc, straight segment, right arc — for accent stroke (matches `PanelSilhouetteShape` geometry).
private struct ExpandedPanelBottomEdgeShape: Shape {
    var bottomCornerRadius: CGFloat = NotchMetrics.panelCornerRadiusLimit

    func path(in rect: CGRect) -> Path {
        let W = rect.width
        let H = rect.height
        let minX = rect.minX
        let minY = rect.minY

        // Half-stroke inset so the centered 2pt stroke sits fully inside the silhouette.
        let inset = NotchMetrics.notchAccentBorderWidth / 2
        let rb = NotchMetrics.clampedCornerRadius(width: W, height: H, limit: bottomCornerRadius)
        let sideBleed = min(rb, W / 2 - 1)
        let bodyMinX = minX + sideBleed + inset
        let bodyMaxX = minX + W - sideBleed - inset
        let bottomY = minY + H - inset

        let blCenter = CGPoint(x: bodyMinX + rb, y: bottomY - rb)
        let brCenter = CGPoint(x: bodyMaxX - rb, y: bottomY - rb)

        var path = Path()

        path.move(to: CGPoint(x: bodyMinX, y: bottomY - rb))

        path.addArc(
            center: blCenter,
            radius: rb,
            startAngle: Angle(radians: Double(polarAngle(from: blCenter, to: CGPoint(x: bodyMinX, y: bottomY - rb)))),
            endAngle: Angle(radians: Double(polarAngle(from: blCenter, to: CGPoint(x: bodyMinX + rb, y: bottomY)))),
            clockwise: true
        )

        path.addLine(to: CGPoint(x: bodyMaxX - rb, y: bottomY))

        path.addArc(
            center: brCenter,
            radius: rb,
            startAngle: Angle(radians: Double(polarAngle(from: brCenter, to: CGPoint(x: bodyMaxX - rb, y: bottomY)))),
            endAngle: Angle(radians: Double(polarAngle(from: brCenter, to: CGPoint(x: bodyMaxX, y: bottomY - rb)))),
            clockwise: true
        )

        return path
    }

    private func polarAngle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }
}

/// Loads the app logo asset once. The asset is an Image Set named `NotchnikLogo` (the file inside is
/// `notchnik-logo.jpg`, but `NSImage(named:)` uses the *asset* name, which is the imageset folder).
private let appLogoImage: NSImage? = NSImage(named: "NotchnikLogo")

private enum ClipboardChrome {
    static let accent = Color(nsColor: .controlAccentColor)

    static func labelOnAccent(_ accentNS: NSColor = .controlAccentColor) -> Color {
        guard let rgb = accentNS.usingColorSpace(.deviceRGB) else {
            return .white
        }
        let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return lum > 0.55 ? .black : .white
    }
}

struct ClipboardHistoryExpandedView: View {
    @EnvironmentObject private var clipboard: ClipboardHistoryStore
    @EnvironmentObject private var sessionActions: NotchSessionActions
    @EnvironmentObject private var layout: NotchLayoutModel
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var filePen: FilePenStore
    @EnvironmentObject private var insightsChat: InsightsChatStore

    @State private var deleteCandidate: ClipboardItem?
    @State private var confirmingClearAll = false
    @State private var confirmingClearAllFiles = false
    @State private var clipboardSearchText: String = ""
    @State private var filePenSearchText: String = ""

    @ViewBuilder
    private func sectionContent(for section: PanelSection) -> some View {
        switch section {
        case .clipboard:
            clipboardSection
        case .calendar:
            CalendarAgendaView()
        case .files:
            FilePenView(searchText: filePenSearchText)
        case .insights:
            InsightsView()
        }
    }

    /// Slide transition that respects the user's intent: forward = new section enters from the right,
    /// outgoing slides off to the left; backward = the mirror.
    private func slideTransition(for direction: NotchLayoutModel.SectionTransitionDirection) -> AnyTransition {
        let inEdge: Edge = direction == .forward ? .trailing : .leading
        let outEdge: Edge = direction == .forward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: inEdge), removal: .move(edge: outEdge))
    }

    /// Live-filtered clipboard items. Empty query returns the full list. Match: text payloads by
    /// substring; file/file-group payloads by filename. Image payloads pass when the query is empty,
    /// otherwise drop out (no useful text to search).
    private var filteredClipboardItems: [ClipboardItem] {
        let needle = clipboardSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return clipboard.items }
        return clipboard.items.filter { item in
            switch item.payload {
            case .text(let s): return s.lowercased().contains(needle)
            case .file(let url): return url.lastPathComponent.lowercased().contains(needle)
            case .fileGroup(let urls): return urls.contains { $0.lastPathComponent.lowercased().contains(needle) }
            case .image: return false
            }
        }
    }

    /// Existing clipboard view extracted so the section switch is readable.
    @ViewBuilder
    private var clipboardSection: some View {
        let visible = filteredClipboardItems
        if clipboard.items.isEmpty {
            // Match the placeholder style used by Calendar / Files so all three empty-states feel consistent.
            SectionPlaceholderView(
                icon: PanelSection.clipboard.iconName,
                title: "Clipboard",
                detail: "Start copying things into the clipboard. I'll keep track of them here."
            )
        } else if visible.isEmpty {
            // Search query active but nothing matches.
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                Text("No matches for “\(clipboardSearchText)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: thumbnailColumns, spacing: gridSpacing) {
                    ForEach(visible) { item in
                        ClipboardThumbnailCell(
                            item: item,
                            isPasteboardActive: clipboard.pasteboardActiveItemID == item.id,
                            onSelect: { clipboard.applyToPasteboard(item) },
                            onTogglePin: { clipboard.togglePin(id: item.id) },
                            onDeleteRequest: { deleteCandidate = item },
                            onPreview: { clipboard.previewItem(item) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Newest-first array fills left → right, then wraps to the next row (top-left is newest).
    private let gridSpacing: CGFloat = 10

    private var thumbnailColumns: [GridItem] {
        [GridItem(.adaptive(minimum: NotchMetrics.clipboardThumbnailColumnMinimum), spacing: gridSpacing)]
    }

    var body: some View {
        GeometryReader { geo in
            // Size must track the *live* hosting rect while AppKit animates the window. A fixed 600× panel inside a
            // window that grows from notch-width → full width is wider than the window mid-animation; layout clips
            // and it looks like the panel “slides in from the right” instead of growing/descending with the frame.
            let w = max(2, geo.size.width)
            let h = max(2, geo.size.height)
            let topFlatInset = NotchMetrics.expandedPanelTopFlatInset(width: w, height: h)

            ZStack {
                PanelSilhouetteCanvasFill(width: w, height: h)

                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: topFlatInset + NotchMetrics.clipboardExpandedTopMargin)

                    Group {
                        if layout.isFrameAnimating {
                            // Skip heavy grid layout while the window frame is animating; we re-render at rest.
                            Color.clear
                        } else {
                            sectionContent(for: layout.currentSection)
                                // `.id` makes SwiftUI treat each section as a new view so the transition fires.
                                .id(layout.currentSection)
                                .transition(slideTransition(for: layout.sectionTransitionDirection))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Clip so a sliding-in section can't leak below the carousel area before the animation lands.
                    .clipped()

                    // Bottom carousel area — outside the scroll region so the grid never slides over it.
                    if !layout.isFrameAnimating {
                        PanelSectionCarousel()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                            .padding(.bottom, 10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(PanelSilhouetteShape())
            }
            .frame(width: w, height: h)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                // App logo in the panel's reserved top margin. Suppressed during the resize animation
                // so the image isn't laid out at intermediate widths during the expand.
                if !layout.isFrameAnimating, let logo = appLogoImage {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 36)
                        .padding(.leading, 28)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Mirrors the logo on the left: same vertical band (just below the silhouette's top lip),
                // pinned to the right wall.
                HStack(spacing: 10) {
                    // Live search box — appears for sections that have searchable items, sits to the
                    // left of the section's trash button. Bound to the section-specific @State.
                    if layout.currentSection == .clipboard {
                        ChromeSearchField(text: $clipboardSearchText, placeholder: "Search clips")
                    } else if layout.currentSection == .files {
                        ChromeSearchField(text: $filePenSearchText, placeholder: "Search files")
                    }

                    // Clear-all is clipboard-specific; hide it on Calendar / Files sections.
                    if layout.currentSection == .clipboard {
                        Button {
                            confirmingClearAll = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Clear all clips")
                        .disabled(clipboard.items.isEmpty)
                        .opacity(clipboard.items.isEmpty ? 0.35 : 1)
                    }

                    // File Pen clear-all (only on the Files section). Removes pen entries; never
                    // touches the underlying files.
                    if layout.currentSection == .files {
                        Button {
                            confirmingClearAllFiles = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Clear all entries from File Pen")
                        .disabled(filePen.items.isEmpty)
                        .opacity(filePen.items.isEmpty ? 0.35 : 1)
                    }

                    // Insights "clear conversation" button — visible only on Insights, disabled when
                    // there's nothing to clear.
                    if layout.currentSection == .insights {
                        Button {
                            insightsChat.clear()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Clear conversation")
                        .disabled(insightsChat.messages.isEmpty)
                        .opacity(insightsChat.messages.isEmpty ? 0.35 : 1)
                    }

                    // Calendar view-mode toggle. Icon represents the *other* mode (the one you'll
                    // switch to on tap), so on time-block view we show the agenda glyph and vice-versa.
                    if layout.currentSection == .calendar {
                        Button {
                            settings.calendarViewMode = settings.calendarViewMode == .timeBlock ? .agenda : .timeBlock
                        } label: {
                            Image(systemName: settings.calendarViewMode.toggleIconName)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help(settings.calendarViewMode == .timeBlock ? "Switch to agenda view" : "Switch to time-block view")
                    }

                    SettingsLink {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("NotchNik Settings")
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            // Stay `.accessory` so no dock icon shows up alongside the Settings window;
                            // SwiftUI's Settings scene works fine in accessory apps.
                            NSApp.activate(ignoringOtherApps: true)
                            sessionActions.triggerCollapseExpandedPanel()
                        }
                    )
                }
                .padding(.trailing, 28)
                .padding(.top, 13)
            }
            .overlay {
                // Inline confirmation — `.confirmationDialog` would attach a system sheet whose
                // rectangular backdrop spills past the silhouette. Custom overlay sits inside the
                // clipped panel and matches the rest of the UI.
                if deleteCandidate != nil {
                    DeleteConfirmationOverlay(
                        onConfirm: {
                            if let id = deleteCandidate?.id { clipboard.deleteItem(id: id) }
                            deleteCandidate = nil
                        },
                        onCancel: { deleteCandidate = nil }
                    )
                    .clipShape(PanelSilhouetteShape())
                } else if confirmingClearAll {
                    DeleteConfirmationOverlay(
                        title: "Clear all clips?",
                        message: "Every saved clip will be removed. Your current pasteboard contents are unaffected.",
                        confirmLabel: "Clear All",
                        onConfirm: {
                            clipboard.clearAll()
                            confirmingClearAll = false
                        },
                        onCancel: { confirmingClearAll = false }
                    )
                    .clipShape(PanelSilhouetteShape())
                } else if confirmingClearAllFiles {
                    DeleteConfirmationOverlay(
                        title: "Clear File Pen?",
                        message: "Every entry will be removed from the File Pen. Your actual files are not deleted — only the references stored here.",
                        confirmLabel: "Clear All",
                        onConfirm: {
                            filePen.clearAll()
                            confirmingClearAllFiles = false
                        },
                        onCancel: { confirmingClearAllFiles = false }
                    )
                    .clipShape(PanelSilhouetteShape())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Compact pill-shaped search input for the panel chrome. Renders a magnifier glyph + a plain
/// text field, plus an inline X button that clears when there's a query. Width is fixed so the
/// surrounding chrome (trash, gear) doesn't shift as the user types.
private struct ChromeSearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .focused($focused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 150)
        .background(
            Capsule().fill(Color.white.opacity(focused ? 0.16 : 0.1))
        )
        .overlay(
            Capsule().strokeBorder(
                focused ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.08),
                lineWidth: 1
            )
        )
        .animation(.easeInOut(duration: 0.12), value: focused)
    }
}

/// Three-icon section carousel: active in the center at full brightness, neighbors flanking it dimmed.
/// Click any icon to make it active; AppDelegate also routes two-finger horizontal swipes here.
private struct PanelSectionCarousel: View {
    @EnvironmentObject private var layout: NotchLayoutModel
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        let order = settings.orderedVisibleSections
        let current = layout.currentSection

        HStack(spacing: 14) {
            // Render every visible section in the user's order — count ranges from 1 to all of
            // them. The active section is highlighted; the rest are dimmed neighbors.
            ForEach(order, id: \.self) { section in
                iconButton(section, role: section == current ? .active : .neighbor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.white.opacity(0.06))
        )
        .animation(.easeInOut(duration: 0.18), value: current)
    }

    private enum Role { case active, neighbor }

    @ViewBuilder
    private func iconButton(_ s: PanelSection, role: Role) -> some View {
        Button {
            layout.switchSection(to: s)
        } label: {
            Image(systemName: s.iconName)
                .font(.system(size: role == .active ? 13 : 11, weight: role == .active ? .semibold : .regular))
                .foregroundStyle(role == .active ? Color.white : Color.white.opacity(0.4))
                .frame(width: role == .active ? 22 : 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.label)
    }
}

/// Generic stand-in shown for sections that are empty / not built out yet. Shared with the calendar
/// agenda's no-feeds and no-events states.
struct SectionPlaceholderView: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Inline replacement for `.confirmationDialog`. Dim-and-prompt rendered inside the silhouette so
/// nothing extends past the panel's curved edges. Used for both per-item delete and clear-all.
private struct DeleteConfirmationOverlay: View {
    var title: String = "Remove this clip?"
    var message: String = "It will no longer appear in this history."
    var confirmLabel: String = "Remove"
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.18))
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Button(action: onConfirm) {
                        Text(confirmLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ClipboardChrome.labelOnAccent(.systemRed))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.red)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(
                // Lighter than the panel's pure-black background so the dialog reads as a separate
                // surface, plus an accent-colored stroke + soft shadow to lift it visually.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(ClipboardChrome.accent.opacity(0.55), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 18, x: 0, y: 6)
                    .shadow(color: ClipboardChrome.accent.opacity(0.35), radius: 22, x: 0, y: 0)
            )
        }
    }
}

private struct ClipboardThumbnailCell: View {
    let item: ClipboardItem
    let isPasteboardActive: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onDeleteRequest: () -> Void
    let onPreview: () -> Void

    @State private var hovered = false
    @State private var showCopiedPill = false

    private var thumb: CGFloat { NotchMetrics.clipboardThumbnailSize }

    private var isHighlighted: Bool { hovered || isPasteboardActive }

    private static let copiedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Button {
                        onSelect()
                        showCopiedPill = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            showCopiedPill = false
                        }
                    } label: {
                        thumbnail
                            .frame(width: thumb, height: thumb)
                            .clipped()
                            .saturation(item.isStaleFileReference ? 0 : 1)
                            .opacity(item.isStaleFileReference ? 0.5 : 1)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        isHighlighted ? ClipboardChrome.accent : Color.white.opacity(0.15),
                                        lineWidth: isHighlighted ? 2.5 : 1
                                    )
                            )
                            .overlay(alignment: .topLeading) {
                                if item.isStaleFileReference {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .orange)
                                        .font(.system(size: 14))
                                        .shadow(color: .black.opacity(0.55), radius: 1.5, y: 0.5)
                                        .padding(6)
                                        .help("Original file is missing")
                                }
                            }
                            .compositingGroup()
                            .shadow(
                                color: ClipboardChrome.accent.opacity(isHighlighted ? 0.2 : 0),
                                radius: isHighlighted ? NotchMetrics.clipboardThumbnailHighlightGlowOuterRadius : 0,
                                x: 0,
                                y: 0
                            )
                            .shadow(
                                color: ClipboardChrome.accent.opacity(isHighlighted ? 0.44 : 0),
                                radius: isHighlighted ? NotchMetrics.clipboardThumbnailHighlightGlowRadius : 0,
                                x: 0,
                                y: 0
                            )
                            .animation(.easeInOut(duration: 0.18), value: isHighlighted)
                    }
                    .buttonStyle(.plain)
                    // Drag the clip out to any drop target (URL field, text editor, Finder, etc.).
                    // The pasteboard is untouched and the item stays in the panel — this is a copy
                    // drag, not a move. For fileGroups, drags the first URL (SwiftUI's `.onDrag`
                    // can only return one NSItemProvider).
                    .onDrag {
                        switch item.payload {
                        case .text(let s):
                            return NSItemProvider(object: s as NSString)
                        case .image(let img):
                            return makeImageItemProvider(img)
                        case .file(let url):
                            return makeFileItemProvider(urls: [url])
                        case .fileGroup(let urls):
                            return makeFileItemProvider(urls: urls)
                        }
                    }

                    if showCopiedPill {
                        Text("Copied!")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ClipboardChrome.labelOnAccent())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(ClipboardChrome.accent))
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: showCopiedPill)
                    }
                }

                if hovered || item.isPinned {
                    HStack(spacing: 5) {
                        Button(action: onTogglePin) {
                            Image(systemName: item.isPinned ? "pin.fill" : "pin")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(item.isPinned ? ClipboardChrome.accent : Color.white)
                                .shadow(color: .black.opacity(item.isPinned || hovered ? 0 : 0.45), radius: 1, y: 0.5)
                                .frame(width: 15, height: 15)
                                .padding(3.5)
                                .background {
                                    if hovered {
                                        Circle().fill(Color.black.opacity(0.55))
                                    }
                                }
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.isPinned ? "Unpin" : "Pin to top")

                        if hovered {
                            Button(action: onPreview) {
                                Image(systemName: "eye")
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
                            .help("Preview without copying")

                            Button(action: onDeleteRequest) {
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
                            .help("Remove from history")
                        }
                    }
                    .padding(.top, 2)
                    .padding(.trailing, 2)
                    .zIndex(10)
                }
            }
            .frame(width: thumb + 12)

            Text(Self.copiedAtFormatter.string(from: item.createdAt))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: thumb + 12)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.payload {
        case .text(let string):
            Text(String(string.prefix(800)))
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.leading)
                .lineLimit(14)
                .padding(.top, 19)
                .padding(.leading, 15)
                .padding(.trailing, 15)
                .padding(.bottom, 8)
                .frame(width: thumb, height: thumb, alignment: .topLeading)
        case .image(let image):
            // Prefer the pre-rasterized 2× thumbnail to avoid downsampling the original on every layout.
            Image(nsImage: item.thumbnail ?? image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumb, height: thumb)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .file(let url) where item.rendersAsImagePreview:
            // Image file: render the QuickLook preview (or the Finder icon as fallback) full-size, like
            // a captured `.image` payload. The preview is filled in asynchronously after insert.
            Image(nsImage: item.thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumb, height: thumb)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .file(let url):
            VStack(spacing: 8) {
                Image(nsImage: item.thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)

                Text(url.lastPathComponent)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
            }
            .frame(width: thumb, height: thumb, alignment: .center)
        case .fileGroup(let urls):
            VStack(spacing: 6) {
                Image(nsImage: item.thumbnail ?? NSWorkspace.shared.icon(forFile: urls.first?.path ?? "/"))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)

                Text("\(urls.count) files")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
            }
            .frame(width: thumb, height: thumb, alignment: .center)
        }
    }
}
