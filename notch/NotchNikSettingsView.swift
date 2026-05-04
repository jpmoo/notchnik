//
//  NotchNikSettingsView.swift
//

import AppKit
import SwiftUI

struct NotchNikSettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var clipboard: ClipboardHistoryStore

    enum SettingsTab: String, Hashable {
        case general, clipboard, calendar, files, insights
    }

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            // Tabs for tools that aren't visible are omitted from the bar entirely. SwiftUI's
            // `.disabled` only dims the *content*; the tab itself stays clickable. Removing them is
            // the only way to make them truly unresponsive on macOS.
            if settings.visibleSections.contains(.clipboard) {
                ClipboardSettingsTab()
                    .tabItem { Label("Clipboard", systemImage: PanelSection.clipboard.iconName) }
                    .tag(SettingsTab.clipboard)
            }

            if settings.visibleSections.contains(.calendar) {
                CalendarSettingsTab()
                    .tabItem { Label("Calendar", systemImage: PanelSection.calendar.iconName) }
                    .tag(SettingsTab.calendar)
            }

            if settings.visibleSections.contains(.files) {
                FileInboxSettingsTab()
                    .tabItem { Label("File Pen", systemImage: PanelSection.files.iconName) }
                    .tag(SettingsTab.files)
            }

            if settings.visibleSections.contains(.insights) {
                InsightsSettingsTab()
                    .tabItem { Label("Insights", systemImage: PanelSection.insights.iconName) }
                    .tag(SettingsTab.insights)
            }
        }
        // Use min/max instead of a fixed `.frame(width:height:)` so the TabView fills the window
        // host completely. On macOS 14+ the Settings scene wraps `TabView` in a split-style host;
        // a fixed-size content view leaves a thin sliver of host chrome on the left edge.
        .frame(minWidth: 520, idealWidth: 520, maxWidth: .infinity,
               minHeight: 380, idealHeight: 380, maxHeight: .infinity)
        .navigationTitle("NotchNik Settings")
        .onAppear {
            // Always land on General when Settings opens, regardless of which tab the user had
            // selected last time.
            selectedTab = .general
            settings.syncStartAtLoginFromSystem()
            Self.bringSettingsChromeToFront()
        }
        .onDisappear {
            // Restore agent-style behavior (no Dock tile) and reset the tab so a re-open starts
            // on General even if `.onAppear` doesn't fire (e.g., when the window is just re-shown
            // from a hidden state rather than rebuilt).
            NSApp.setActivationPolicy(.accessory)
            selectedTab = .general
        }
    }

    /// LSUIElement app + notch panel (`statusBar` window level): activate and lift Settings above the overlay.
    private static func bringSettingsChromeToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let lift: () -> Void = {
            let aboveNotch = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            for window in NSApp.windows where window.isVisible {
                let title = window.title
                guard title.contains("NotchNik") || title == "Settings" else { continue }
                var behavior = window.collectionBehavior
                behavior.formUnion(.moveToActiveSpace)
                window.collectionBehavior = behavior
                window.level = aboveNotch
                window.orderFrontRegardless()
                window.makeKey()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async(execute: lift)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: lift)
    }
}

// MARK: - Tabs

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var settings: AppSettingsStore

    private var defaultStatusMessage: String {
        switch settings.defaultSection {
        case .lastUsed:
            return "Opens to the last-used visible tool."
        case .clipboard:
            return "Opens to Clipboard."
        case .calendar:
            return "Opens to Calendar."
        case .files:
            return "Opens to File Pen."
        case .insights:
            return "Opens to Insights."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Black banner with the centered NotchNik logo. Using `.background(Color.black)`
            // on the bounding frame (rather than `Color.black` as a sibling layer inside the
            // ZStack) keeps the fill from painting outside the layout rect on macOS Settings'
            // sidebar/split layouts, which is what produces a 1px line down the window edge.
            ZStack {
                if let logo = NSImage(named: "NotchnikLogo") {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 52)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
            .background(Color.black)
            .clipShape(Rectangle())

            Form {
                Toggle(
                    "Launch at startup",
                    isOn: Binding(
                        get: { settings.startAtLogin },
                        set: { settings.setStartAtLogin($0) }
                    )
                )
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 80)

            // Reorderable tools list. The List + onMove combo gives us native macOS drag-to-reorder
            // affordances (a grabber on the right side of each row that the user can drag).
            List {
                Section {
                    ForEach(settings.sectionOrder, id: \.self) { section in
                        ToolVisibilityRow(section: section)
                    }
                    .onMove { source, destination in
                        var newOrder = settings.sectionOrder
                        newOrder.move(fromOffsets: source, toOffset: destination)
                        settings.updateSectionOrder(newOrder)
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(defaultStatusMessage)
                            .foregroundStyle(.secondary)
                        Text("Use the arrows to reorder. At least one tool must stay visible.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10))
                }
            }
            .listStyle(.inset)

            Spacer(minLength: 12)

            HStack {
                Spacer()
                Button("Quit NotchNik") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.large)
                .keyboardShortcut("q", modifiers: [.command])
                Spacer()
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("NotchNik Settings")
    }
}

/// One row in the Tools list: a visibility checkbox on the left, a "Default" radio on the right.
/// The checkbox is disabled when this is the only visible section (we always need ≥1). The radio is
/// disabled when the section is hidden, and clicking it again clears the default to "last used".
private struct ToolVisibilityRow: View {
    @EnvironmentObject private var settings: AppSettingsStore
    let section: PanelSection

    private var isVisible: Bool { settings.visibleSections.contains(section) }
    private var isOnlyVisible: Bool { settings.visibleSections == [section] }
    private var isDefault: Bool { settings.explicitDefaultPanelSection == section }

    private var rowIndex: Int? { settings.sectionOrder.firstIndex(of: section) }
    private var isFirst: Bool { rowIndex == 0 }
    private var isLast: Bool { rowIndex == settings.sectionOrder.count - 1 }

    var body: some View {
        HStack(spacing: 12) {
            // Reorder controls — reliable across all macOS versions / list styles, and accessible.
            VStack(spacing: 1) {
                Button {
                    moveUp()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 10)
                }
                .buttonStyle(.borderless)
                .disabled(isFirst)
                .help("Move up")

                Button {
                    moveDown()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 10)
                }
                .buttonStyle(.borderless)
                .disabled(isLast)
                .help("Move down")
            }

            Toggle(isOn: Binding(
                get: { isVisible },
                set: { settings.setVisible(section, $0) }
            )) {
                Label(section.label, systemImage: section.iconName)
            }
            .toggleStyle(.checkbox)
            .disabled(isVisible && isOnlyVisible)

            Spacer()

            Button {
                settings.setExplicitDefaultSection(isDefault ? nil : section)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isDefault ? Color.accentColor : Color.secondary)
                    Text("Default")
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isVisible)
            .opacity(isVisible ? 1 : 0.4)
            .help(isDefault ? "Clear default — open to last-used tool" : "Make this the default tool when opening")
        }
    }

    private func moveUp() {
        guard let i = rowIndex, i > 0 else { return }
        var order = settings.sectionOrder
        order.swapAt(i, i - 1)
        settings.updateSectionOrder(order)
    }

    private func moveDown() {
        guard let i = rowIndex, i < settings.sectionOrder.count - 1 else { return }
        var order = settings.sectionOrder
        order.swapAt(i, i + 1)
        settings.updateSectionOrder(order)
    }
}

private struct ClipboardSettingsTab: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var clipboard: ClipboardHistoryStore

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.maxClipboardItems, in: 1...500) {
                    HStack {
                        Text("Maximum clipboard items to save")
                        Spacer()
                        Text("\(settings.maxClipboardItems)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                HStack {
                    Text("Items currently saved")
                    Spacer()
                    Text("\(clipboard.items.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .navigationTitle("NotchNik Settings")
    }
}

private struct CalendarSettingsTab: View {
    @EnvironmentObject private var calendar: CalendarFeedStore
    @State private var editorFeed: FeedEditorTarget?

    enum FeedEditorTarget: Identifiable {
        case new
        case existing(CalendarFeed)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let f): return f.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if calendar.feeds.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No calendar feeds yet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Add a `.ics` URL to subscribe to a calendar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(calendar.feeds) { feed in
                        FeedRow(feed: feed) {
                            editorFeed = .existing(feed)
                        } onDelete: {
                            calendar.removeFeed(id: feed.id)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    Task { await calendar.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(calendar.feeds.isEmpty || calendar.isRefreshing)

                Spacer()

                Button {
                    editorFeed = .new
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .navigationTitle("NotchNik Settings")
        .sheet(item: $editorFeed) { target in
            switch target {
            case .new:
                CalendarFeedEditor(feed: nil) { name, urlString, color in
                    calendar.addFeed(name: name, urlString: urlString, color: color)
                }
            case .existing(let feed):
                CalendarFeedEditor(feed: feed) { name, urlString, color in
                    var updated = feed
                    updated.name = name
                    updated.urlString = urlString
                    updated.color = ColorRGBA(color)
                    calendar.updateFeed(updated)
                }
            }
        }
    }
}

private struct FeedRow: View {
    let feed: CalendarFeed
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(feed.color.color)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(feed.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(feed.urlString)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let err = feed.lastError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.vertical, 4)
    }
}

private struct CalendarFeedEditor: View {
    var feed: CalendarFeed?
    var onSave: (String, String, Color) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var urlString: String = ""
    @State private var color: Color = .blue

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { urlString.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Validation is lenient: any non-empty name and a URL string containing a scheme. Strict
    /// `URL(string:)` parsing rejects calendar URLs that contain characters most apps tolerate.
    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedURL.contains("://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(feed == nil ? "Add Calendar Feed" : "Edit Calendar Feed")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                LabeledField(label: "Name") {
                    TextField("Personal", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledField(label: "URL (.ics or webcal://)") {
                    TextField("https://example.com/calendar.ics", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LabeledField(label: "Color") {
                    HStack {
                        ColorPicker("", selection: $color, supportsOpacity: false)
                            .labelsHidden()
                        Spacer()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmedName, trimmedURL, color)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            if let feed {
                name = feed.name
                urlString = feed.urlString
                color = feed.color.color
            }
        }
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct FileInboxSettingsTab: View {
    @EnvironmentObject private var settings: AppSettingsStore

    /// Mirrors the panel hint string so the user can see what their settings produce.
    private var summary: String {
        let def = settings.filePenDefaultAction.label.lowercased()
        let cmd = settings.filePenCommandAction.label.lowercased()
        return "Drag to \(def), ⌘-drag to \(cmd)."
    }

    var body: some View {
        Form {
            Section {
                Picker("Default drag action", selection: $settings.filePenDefaultAction) {
                    ForEach(FilePenDragAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }

                Picker("⌘-drag action", selection: $settings.filePenCommandAction) {
                    ForEach(FilePenDragAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            } header: {
                Text("Drag behavior")
            } footer: {
                Text("Move removes the file from its source and from the pen. Copy leaves both intact. macOS won't let move work without the proper modifier — if your destination refuses a `move`, try `copy` instead.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .navigationTitle("NotchNik Settings")
    }
}

private struct InsightsSettingsTab: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var activity: ActivityWatcher
    @EnvironmentObject private var commentator: InsightsCommentator

    @State private var pendingURL: String = ""
    @State private var connectionState: ConnectionState = .idle
    @State private var availableModels: [String] = []
    @State private var showingLog = false
    @State private var confirmingClearLog = false
    @State private var bulkBrowserResult: String?

    enum ConnectionState: Equatable {
        case idle
        case testing
        case connected
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Ollama endpoint", text: $pendingURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                HStack(spacing: 10) {
                    Button(connectionState == .testing ? "Connecting…" : "Connect") {
                        Task { await connect() }
                    }
                    .disabled(connectionState == .testing || pendingURL.trimmingCharacters(in: .whitespaces).isEmpty)

                    statusBadge
                    Spacer()
                }
            } footer: {
                Text("Address and port of an Ollama instance, e.g. http://localhost:11434. The app will list installed models once connected.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if !availableModels.isEmpty {
                Section {
                    Picker("Model", selection: $settings.ollamaModel) {
                        Text("None").tag("")
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            }

            Section {
                Picker("Personality", selection: $settings.insightsPersonality) {
                    ForEach(InsightsPersonality.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }

                Toggle("Periodic commentary", isOn: $settings.insightsCommentaryEnabled)
                    .disabled(!activity.hasAccessibilityPermission || settings.ollamaModel.isEmpty)
                    .help("Every few minutes, with a 60% chance, the AI will drop an in-personality remark on what you're doing and what's on your calendar.")

                HStack {
                    Button("Comment now") {
                        Task { await commentator.triggerNow() }
                    }
                    .disabled(settings.ollamaModel.isEmpty || !activity.hasAccessibilityPermission)
                    .help("Force a single commentary attempt, bypassing the timer and the AFK guard. Useful for verifying the model + prompt path.")
                    Spacer()
                }

                CommentatorDiagnostics()
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: activity.hasAccessibilityPermission ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, activity.hasAccessibilityPermission ? Color.green : Color.orange)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.hasAccessibilityPermission ? "Accessibility permission granted" : "Accessibility permission required")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Lets the app see which apps and windows you're using, so it can build productivity insights.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack {
                    if !activity.hasAccessibilityPermission {
                        Button("Request Access") {
                            activity.requestAccessibilityPermission()
                        }
                    }
                    Button("Open Privacy Settings") {
                        activity.openSystemAccessibilitySettings()
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("Refresh") {
                        activity.refreshPermissionStatus()
                    }
                    .buttonStyle(.borderless)
                }

                Toggle(isOn: $settings.activityWatchingEnabled) {
                    Text("Watch activity in the background")
                }
                .disabled(!activity.hasAccessibilityPermission)

                Picker("Keep activity for", selection: $settings.activityRetentionDays) {
                    Text("1 day").tag(1)
                    Text("3 days").tag(3)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }

                if activity.isWatching {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Watching — \(activity.events.count) event\(activity.events.count == 1 ? "" : "s") logged")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let last = activity.latestEvent {
                        Text("Latest: \(last.appName)" + (last.windowTitle.map { " — \($0)" } ?? ""))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                HStack {
                    Button("View Log…") { showingLog = true }
                        .disabled(activity.events.isEmpty)
                    Spacer()
                    Button("Clear Log…") { confirmingClearLog = true }
                        .disabled(activity.events.isEmpty)
                }

                UncategorizedItems()
                    .padding(.top, 4)

                CategoryEditorButtons()
                    .padding(.top, 8)

                HistoryMaintenance()
                    .padding(.top, 8)

                // Bulk authorization: pings every supported browser that's currently running. macOS
                // shows one prompt per browser the first time. After this, the activity watcher
                // can quietly read tab info from each authorized browser.
                HStack(alignment: .firstTextBaseline) {
                    Button("Authorize all running browsers") {
                        authorizeAllBrowsers()
                    }
                    if let msg = bulkBrowserResult {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            } footer: {
                Text("After granting access in System Settings, click Refresh. macOS may require quitting and relaunching the app the first time.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .navigationTitle("NotchNik Settings")
        .onAppear {
            pendingURL = settings.ollamaURL
            activity.refreshPermissionStatus()
            // If the user already has a saved URL + model, attempt a silent reconnect on appear.
            if !settings.ollamaURL.isEmpty {
                Task { await connect(silent: true) }
            }
        }
        .sheet(isPresented: $showingLog) {
            ActivityLogView()
                .environmentObject(activity)
        }
        .confirmationDialog(
            "Clear all logged activity?",
            isPresented: $confirmingClearLog,
            titleVisibility: .visible
        ) {
            Button("Clear Log", role: .destructive) {
                activity.clear()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removes every recorded event. Watching continues; new events will start being logged again.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch connectionState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .connected:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 11))
        }
    }

    /// Pings every supported browser that's currently running. macOS shows one Apple Events
    /// prompt per browser the first time we touch it; subsequent runs are silent. Reports a
    /// terse summary of which succeeded and which still need permission.
    private func authorizeAllBrowsers() {
        let supported = Set(BrowserContextFetcher.supportedBundleIDs)
        let running = NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier }
            .filter { supported.contains($0) }
        guard !running.isEmpty else {
            bulkBrowserResult = "No supported browsers running. Open the ones you use and try again."
            return
        }

        var ok: [String] = []
        var failed: [(String, String)] = []  // (label, reason)
        for bundleID in running {
            let result = BrowserContextFetcher.fetchDetailed(bundleID: bundleID)
            let label = result.appName ?? BrowserContextFetcher.displayName(for: bundleID) ?? bundleID
            if result.context != nil {
                ok.append(label)
            } else {
                failed.append((label, result.error ?? "no data"))
            }
        }

        var lines: [String] = []
        if !ok.isEmpty { lines.append("✓ Authorized: \(ok.joined(separator: ", "))") }
        for (label, reason) in failed {
            lines.append("✗ \(label): \(reason)")
        }
        bulkBrowserResult = lines.joined(separator: "\n")
    }

    @MainActor
    private func connect(silent: Bool = false) async {
        if !silent { connectionState = .testing }
        let trimmed = pendingURL.trimmingCharacters(in: .whitespaces)
        do {
            let models = try await OllamaClient.listModels(baseURL: trimmed)
            availableModels = models
            // Persist URL on successful connect.
            settings.ollamaURL = trimmed
            // If the previously chosen model isn't installed anymore, clear it.
            if !settings.ollamaModel.isEmpty && !models.contains(settings.ollamaModel) {
                settings.ollamaModel = ""
            }
            connectionState = .connected
        } catch {
            availableModels = []
            connectionState = .failed(error.localizedDescription)
        }
    }
}

/// Tiny diagnostic readout under the "Comment now" button. Shows when the commentator last
/// ticked, what happened, and when it last actually posted. Lets the user tell at a glance
/// whether the timer path is firing (and being silenced for a known reason) vs. silently broken.
private struct CommentatorDiagnostics: View {
    @EnvironmentObject private var commentator: InsightsCommentator

    var body: some View {
        // TimelineView ticks once a minute so the "5 min ago" readout stays accurate without
        // re-rendering the whole settings tab on a high-frequency timer.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 2) {
                if let last = commentator.lastTickAt {
                    Text("Last tick: \(relative(last, now: context.date))" + (commentator.lastTickResult.map { " — \($0.rawValue)" } ?? ""))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("No ticks yet.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let lastFire = commentator.lastCommentAt {
                    Text("Last comment posted: \(relative(lastFire, now: context.date))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func relative(_ then: Date, now: Date) -> String {
        let secs = Int(now.timeIntervalSince(then))
        if secs < 60 { return "just now" }
        let mins = secs / 60
        if mins < 60 { return "\(mins) min ago" }
        let hours = mins / 60
        let remaining = mins % 60
        return remaining == 0 ? "\(hours)h ago" : "\(hours)h \(remaining)m ago"
    }
}

/// Inline list of bundle ID → category mappings used by the focus-score engine. Search box for
/// quick filtering, scroll cap so the list doesn't run away on long histories, and an "Add
/// app" menu that lets the user pick from currently-running apps that aren't categorized yet.
private struct AppCategoriesEditor: View {
    @EnvironmentObject private var settings: AppSettingsStore

    @State private var search: String = ""
    @State private var pendingAddBundleID: String?
    @State private var pendingAddDisplayName: String?

    /// Hard cap on visible rows before scrolling kicks in. 15 is a balance: enough to scan
    /// without scroll, not so many the editor pushes the rest of Settings off-screen.
    private static let maxVisibleRows = 15
    private static let approxRowHeight: CGFloat = 28

    private var allRows: [(bundleID: String, category: String)] {
        settings.appCategories
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    private var filteredRows: [(bundleID: String, category: String)] {
        guard !search.isEmpty else { return allRows }
        let q = search.lowercased()
        return allRows.filter { $0.bundleID.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    /// Currently-running apps with a regular activation policy that don't already have a
    /// category and aren't on the hard-ignore list. Sorted by display name. Recomputed every
    /// time the menu opens so newly-launched apps appear without re-rendering the editor.
    private var addableRunningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let bid = app.bundleIdentifier, !bid.isEmpty else { return nil }
                if AppSettingsStore.isIgnoredBundleID(bid) { return nil }
                if settings.appCategories[bid] != nil { return nil }
                let name = app.localizedName ?? bid
                return (bid, name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("App Categories")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    let candidates = addableRunningApps
                    if candidates.isEmpty {
                        Text("No running apps left to categorize.")
                    } else {
                        ForEach(candidates, id: \.bundleID) { app in
                            Button("\(app.name)  —  \(app.bundleID)") {
                                pendingAddBundleID = app.bundleID
                                pendingAddDisplayName = app.name
                            }
                        }
                    }
                } label: {
                    Label("Add app", systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if !allRows.isEmpty {
                TextField("Search apps or categories", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            if let bundleID = pendingAddBundleID, let name = pendingAddDisplayName {
                NewCategoryDraftRow(label: name, sublabel: bundleID) { category in
                    settings.setAppCategory(bundleID: bundleID, category: category)
                    pendingAddBundleID = nil
                    pendingAddDisplayName = nil
                } onCancel: {
                    pendingAddBundleID = nil
                    pendingAddDisplayName = nil
                }
            }

            if filteredRows.isEmpty {
                Text(allRows.isEmpty
                     ? "No categories yet — pick from running apps with the Add menu, or let the assistant ask in chat as you go."
                     : "No matches.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.vertical, showsIndicators: filteredRows.count > Self.maxVisibleRows) {
                    VStack(spacing: 4) {
                        ForEach(filteredRows, id: \.bundleID) { row in
                            AppCategoryRow(bundleID: row.bundleID, category: row.category)
                        }
                    }
                }
                .frame(maxHeight: CGFloat(min(filteredRows.count, Self.maxVisibleRows)) * Self.approxRowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline form rendered above the list when the user has picked something to add (an app
/// from the running-apps menu, or a domain from the open-tabs menu) but hasn't yet typed a
/// category. Shared between AppCategoriesEditor and DomainCategoriesEditor.
private struct NewCategoryDraftRow: View {
    let label: String
    let sublabel: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = sublabel {
                    Text(sub)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField("category", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .focused($fieldFocused)
                .onSubmit(commit)

            Button("Save", action: commit).buttonStyle(.borderless)
            Button("Cancel", action: onCancel).buttonStyle(.borderless)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .onAppear { fieldFocused = true }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onCancel(); return }
        onSave(trimmed)
    }
}

private struct AppCategoryRow: View {
    @EnvironmentObject private var settings: AppSettingsStore
    let bundleID: String
    let category: String

    @State private var editing: String = ""
    @State private var isEditing: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(bundleID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isEditing {
                TextField("category", text: $editing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit { commit() }
                Button("Save", action: commit)
                    .buttonStyle(.borderless)
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.borderless)
            } else {
                Text(category)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                Button {
                    editing = category
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename category")
                Button(role: .destructive) {
                    settings.removeAppCategory(bundleID: bundleID)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
    }

    private func commit() {
        settings.setAppCategory(bundleID: bundleID, category: editing)
        isEditing = false
    }
}

/// Shows apps and domains that have racked up significant time recently but aren't
/// categorized yet — either because the user didn't reply to the conversational prompt, the
/// AI didn't recognize them, or the items pre-date categorization being wired up. Per-row
/// "Add" lets the user assign a category inline; an "AI guess" button takes another shot at
/// the whole list via `FocusScoreEngine.aiCategorizeUncategorized`.
private struct UncategorizedItems: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var focusEngine: FocusScoreEngine

    @State private var aiBusy = false
    @State private var aiResult: String?

    private var uncategorized: (apps: [(name: String, bundleID: String, minutes: Int)], domains: [(host: String, minutes: Int)]) {
        // Reading the engine's history revision keeps this view live as new scores land.
        _ = focusEngine.history.revision
        _ = settings.appCategoriesRevision
        return focusEngine.history.uncategorizedItems(daysBack: 14, settings: settings)
    }

    var body: some View {
        let items = uncategorized
        if items.apps.isEmpty && items.domains.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Uncategorized (last 14 days)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        guessWithAI()
                    } label: {
                        if aiBusy {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Asking…").font(.system(size: 11))
                            }
                        } else {
                            Label("AI guess", systemImage: "sparkles").font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(aiBusy || settings.ollamaModel.isEmpty)
                    .help("Ask the model to categorize the items below in one batch. Skips anything genuinely ambiguous.")
                }
                if let aiResult {
                    Text(aiResult)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                ForEach(items.apps, id: \.bundleID) { row in
                    UncategorizedRow(label: row.name, sublabel: row.bundleID, minutes: row.minutes) { category in
                        settings.setAppCategory(bundleID: row.bundleID, category: category)
                    }
                }
                ForEach(items.domains, id: \.host) { row in
                    UncategorizedRow(label: row.host, sublabel: nil, minutes: row.minutes) { category in
                        settings.setDomainCategory(host: row.host, category: category)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func guessWithAI() {
        aiBusy = true
        aiResult = nil
        Task { @MainActor in
            let count = await focusEngine.aiCategorizeUncategorized(daysBack: 14)
            aiBusy = false
            aiResult = count > 0
                ? "Applied \(count) AI-suggested categor\(count == 1 ? "y" : "ies"). Review or edit below."
                : "AI didn't have confident guesses — categorize manually below or wait for the conversational prompt."
        }
    }
}

private struct UncategorizedRow: View {
    let label: String
    let sublabel: String?
    let minutes: Int
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @State private var editing: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = sublabel {
                    Text(sub)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(minutes)m")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            if editing {
                TextField("category", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit { commit() }
                Button("Save", action: commit).buttonStyle(.borderless)
                Button("Cancel") { editing = false; draft = "" }.buttonStyle(.borderless)
            } else {
                Button("Add category…") {
                    draft = ""
                    editing = true
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { editing = false; return }
        onCommit(trimmed)
        editing = false
        draft = ""
    }
}

/// Three buttons that open category-management modal windows. Mirrors the activity-log
/// pattern — keeps the Settings tab scannable while putting full search + scroll editors
/// behind dedicated windows.
private struct CategoryEditorButtons: View {
    @State private var showingApps = false
    @State private var showingDomains = false
    @State private var showingCategories = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Categories")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("App categories…") { showingApps = true }
                Button("Domain categories…") { showingDomains = true }
                Button("Category counting…") { showingCategories = true }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingApps) { AppCategoriesWindow() }
        .sheet(isPresented: $showingDomains) { DomainCategoriesWindow() }
        .sheet(isPresented: $showingCategories) { CategoryCountingWindow() }
    }
}

/// Modal window listing app → category mappings. Mirrors `ActivityLogView`'s shape: header
/// with title + count, scrollable body with search, footer with Done.
private struct AppCategoriesWindow: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var search: String = ""
    @State private var pendingAddBundleID: String?
    @State private var pendingAddDisplayName: String?

    private var allRows: [(bundleID: String, category: String)] {
        settings.appCategories
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    private var filteredRows: [(bundleID: String, category: String)] {
        guard !search.isEmpty else { return allRows }
        let q = search.lowercased()
        return allRows.filter { $0.bundleID.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    private var addableRunningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let bid = app.bundleIdentifier, !bid.isEmpty else { return nil }
                if AppSettingsStore.isIgnoredBundleID(bid) { return nil }
                if settings.appCategories[bid] != nil { return nil }
                return (bid, app.localizedName ?? bid)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("App Categories").font(.headline)
                Spacer()
                Text("\(allRows.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Search apps or categories", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        let candidates = addableRunningApps
                        if candidates.isEmpty {
                            Text("No running apps left to add.")
                        } else {
                            ForEach(candidates, id: \.bundleID) { app in
                                Button("\(app.name)  —  \(app.bundleID)") {
                                    pendingAddBundleID = app.bundleID
                                    pendingAddDisplayName = app.name
                                }
                            }
                        }
                    } label: {
                        Label("Add app", systemImage: "plus.circle")
                    }
                    .fixedSize()
                }
                if let bundleID = pendingAddBundleID, let name = pendingAddDisplayName {
                    NewCategoryDraftRow(label: name, sublabel: bundleID) { category in
                        settings.setAppCategory(bundleID: bundleID, category: category)
                        pendingAddBundleID = nil; pendingAddDisplayName = nil
                    } onCancel: {
                        pendingAddBundleID = nil; pendingAddDisplayName = nil
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)

            if filteredRows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(allRows.isEmpty ? "No app categories yet." : "No matches.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredRows, id: \.bundleID) { row in
                        AppCategoryRow(bundleID: row.bundleID, category: row.category)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 600, height: 480)
    }
}

/// Modal window for domain → category mappings. Same pattern as AppCategoriesWindow.
private struct DomainCategoriesWindow: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var search: String = ""
    @State private var pendingAddHost: String?
    @State private var pendingAddTitle: String?

    private var allRows: [(host: String, category: String)] {
        settings.domainCategories
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    private var filteredRows: [(host: String, category: String)] {
        guard !search.isEmpty else { return allRows }
        let q = search.lowercased()
        return allRows.filter { $0.host.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    private var addableOpenTabs: [(host: String, title: String)] {
        let supported = Set(BrowserContextFetcher.supportedBundleIDs)
        let runningBrowsers = NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier }
            .filter { supported.contains($0) }
        var seen: Set<String> = []
        var results: [(host: String, title: String)] = []
        for bid in runningBrowsers {
            guard let context = BrowserContextFetcher.fetch(bundleID: bid),
                  let url = context.url,
                  let host = extractHost(from: url) else { continue }
            if settings.domainCategories[host] != nil { continue }
            if seen.contains(host) { continue }
            seen.insert(host)
            results.append((host: host, title: context.title ?? host))
        }
        return results.sorted { $0.host < $1.host }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Domain Categories").font(.headline)
                Spacer()
                Text("\(allRows.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Search domains or categories", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        let candidates = addableOpenTabs
                        if candidates.isEmpty {
                            Text("No open tabs left to add.")
                        } else {
                            ForEach(candidates, id: \.host) { tab in
                                Button("\(tab.host)  —  \(tab.title)") {
                                    pendingAddHost = tab.host
                                    pendingAddTitle = tab.title
                                }
                            }
                        }
                    } label: {
                        Label("Add from open tab", systemImage: "plus.circle")
                    }
                    .fixedSize()
                }
                if let host = pendingAddHost {
                    NewCategoryDraftRow(label: host, sublabel: pendingAddTitle) { category in
                        settings.setDomainCategory(host: host, category: category)
                        pendingAddHost = nil; pendingAddTitle = nil
                    } onCancel: {
                        pendingAddHost = nil; pendingAddTitle = nil
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)

            if filteredRows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(allRows.isEmpty ? "No domain categories yet." : "No matches.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredRows, id: \.host) { row in
                        DomainCategoryRow(host: row.host, category: row.category)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 600, height: 480)
    }
}

/// Modal window listing every recognized category plus any user-coined ones, with a toggle
/// per category for whether time in that category counts toward active time. Drives the
/// scoring threshold/presence/streak math via `AppSettingsStore.nonCountingCategories`.
private struct CategoryCountingWindow: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var search: String = ""

    private var allCategories: [String] {
        settings.allKnownCategories
    }

    private var filteredCategories: [String] {
        guard !search.isEmpty else { return allCategories }
        let q = search.lowercased()
        return allCategories.filter { $0.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Category Counting").font(.headline)
                Spacer()
                Text("\(allCategories.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Categories with the toggle ON count time toward the focus score's active total. Categories with the toggle OFF still appear in topApps and the activity log, but their time doesn't count toward the score.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Search categories", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)

            if filteredCategories.isEmpty {
                Text("No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredCategories, id: \.self) { cat in
                        CategoryCountingRow(category: cat)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 480, height: 480)
    }
}

private struct CategoryCountingRow: View {
    @EnvironmentObject private var settings: AppSettingsStore
    let category: String

    private var counts: Bool {
        settings.categoryCountsTowardActive(category)
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { counts },
            set: { settings.setCategoryCountsTowardActive(category, counts: $0) }
        )) {
            HStack(spacing: 6) {
                Text(category)
                    .font(.system(size: 12, weight: .medium))
                if AppSettingsStore.recognizedCategories.contains(category) {
                    Text("default")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                } else {
                    Text("custom")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
        }
        .toggleStyle(.switch)
    }
}

/// Heavy/destructive history operations. Lives in Settings rather than the focus-score panel
/// because it's admin work — batch operations that touch every entry, take minutes to run, and
/// shouldn't be a misclick away on a panel users open many times a day.
private struct HistoryMaintenance: View {
    @EnvironmentObject private var focusEngine: FocusScoreEngine

    @State private var confirmingRescore = false
    @State private var confirmingNuke = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History Maintenance")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Re-score history") {
                    confirmingRescore = true
                }
                .disabled(focusEngine.isBackfilling)

                Button(role: .destructive) {
                    confirmingNuke = true
                } label: {
                    Label("Wipe & rebuild", systemImage: "trash")
                }
                .disabled(focusEngine.isBackfilling)

                if focusEngine.isBackfilling {
                    ProgressView().controlSize(.small)
                    Text("Re-scoring in background…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Re-score every existing hour?",
            isPresented: $confirmingRescore,
            titleVisibility: .visible
        ) {
            Button("Re-score history") {
                focusEngine.autoRefreshOutdatedScores(daysBack: Int.max, force: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("""
            Updates the score and commentary of every persisted focus-score entry that the \
            activity log still covers. Existing entries get fresh numbers; nothing is deleted.

            • Entries whose hour the activity log NO LONGER covers (pruned by retention) keep \
            their old scores untouched.
            • Hours that have NEVER had an entry are NOT created — use Wipe & rebuild for that.

            One model call per eligible entry; can take several minutes on long histories.

            Do this when: you changed personality, added or edited categories, or otherwise \
            want existing scores refreshed across the full history. Also useful when the \
            activity log was cleaned up out-of-band (e.g., loginwindow filter) and the \
            pill-click's today+yesterday auto-refresh isn't reaching far enough back.
            """)
        }
        .confirmationDialog(
            "Wipe all focus scores and rebuild?",
            isPresented: $confirmingNuke,
            titleVisibility: .visible
        ) {
            Button("Wipe and rebuild", role: .destructive) {
                focusEngine.nukeAndRecomputeAllScores()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("""
            Deletes every persisted focus-score entry on disk, then rebuilds from the activity \
            log only.

            • Hours where the activity log still has data AND meets the 10-min threshold get \
            freshly scored — including hours that never had an entry before (e.g., from before \
            the engine existed).
            • Hours where the log has been pruned end up with NO entry at all — those scores \
            are gone, since the source data is gone.

            One model call per eligible hour; slow on long activity logs. The activity log \
            itself isn't touched. This can't be undone.

            Do this when: history feels wrong or corrupted, you want to backfill hours that \
            never got scored (e.g., from before the engine existed or when thresholds were \
            different), or you're OK losing scores for hours where the activity log has been \
            pruned. The most aggressive option — usually only needed once.
            """)
        }
    }
}

/// Mirrors AppCategoriesEditor — search, scroll cap, and an "Add domain" menu populated from
/// active tabs across running supported browsers (Safari, Chrome and forks, Arc, Dia).
private struct DomainCategoriesEditor: View {
    @EnvironmentObject private var settings: AppSettingsStore

    @State private var search: String = ""
    @State private var pendingAddHost: String?
    @State private var pendingAddTitle: String?

    private static let maxVisibleRows = 15
    private static let approxRowHeight: CGFloat = 28

    private var allRows: [(host: String, category: String)] {
        settings.domainCategories
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }

    private var filteredRows: [(host: String, category: String)] {
        guard !search.isEmpty else { return allRows }
        let q = search.lowercased()
        return allRows.filter { $0.host.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    /// One active tab per running supported browser, as long as the host isn't already
    /// categorized. Synchronous AppleScript per browser — short list, runs only when the menu
    /// is opened.
    private var addableOpenTabs: [(host: String, title: String)] {
        let supported = Set(BrowserContextFetcher.supportedBundleIDs)
        let runningBrowsers = NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier }
            .filter { supported.contains($0) }

        var seen: Set<String> = []
        var results: [(host: String, title: String)] = []
        for bid in runningBrowsers {
            guard let context = BrowserContextFetcher.fetch(bundleID: bid),
                  let url = context.url,
                  let host = extractHost(from: url) else { continue }
            if settings.domainCategories[host] != nil { continue }
            if seen.contains(host) { continue }
            seen.insert(host)
            results.append((host: host, title: context.title ?? host))
        }
        return results.sorted { $0.host < $1.host }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Domain Categories")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    let candidates = addableOpenTabs
                    if candidates.isEmpty {
                        Text("No open tabs left to categorize.")
                    } else {
                        ForEach(candidates, id: \.host) { tab in
                            Button("\(tab.host)  —  \(tab.title)") {
                                pendingAddHost = tab.host
                                pendingAddTitle = tab.title
                            }
                        }
                    }
                } label: {
                    Label("Add from open tab", systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if !allRows.isEmpty {
                TextField("Search domains or categories", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            if let host = pendingAddHost {
                NewCategoryDraftRow(label: host, sublabel: pendingAddTitle) { category in
                    settings.setDomainCategory(host: host, category: category)
                    pendingAddHost = nil
                    pendingAddTitle = nil
                } onCancel: {
                    pendingAddHost = nil
                    pendingAddTitle = nil
                }
            }

            if filteredRows.isEmpty {
                Text(allRows.isEmpty
                     ? "No domain categories yet — pick from open tabs with Add, or let the assistant ask in chat."
                     : "No matches.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.vertical, showsIndicators: filteredRows.count > Self.maxVisibleRows) {
                    VStack(spacing: 4) {
                        ForEach(filteredRows, id: \.host) { row in
                            DomainCategoryRow(host: row.host, category: row.category)
                        }
                    }
                }
                .frame(maxHeight: CGFloat(min(filteredRows.count, Self.maxVisibleRows)) * Self.approxRowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DomainCategoryRow: View {
    @EnvironmentObject private var settings: AppSettingsStore
    let host: String
    let category: String

    @State private var editing: String = ""
    @State private var isEditing: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(host)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isEditing {
                TextField("category", text: $editing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit { commit() }
                Button("Save", action: commit).buttonStyle(.borderless)
                Button("Cancel") { isEditing = false }.buttonStyle(.borderless)
            } else {
                Text(category)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                Button {
                    editing = category
                    isEditing = true
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename category")
                Button(role: .destructive) {
                    settings.removeDomainCategory(host: host)
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
        }
    }

    private func commit() {
        settings.setDomainCategory(host: host, category: editing)
        isEditing = false
    }
}

/// Modal log viewer for activity events. Newest-first, per-row delete, plus a "Clear all" button.
private struct ActivityLogView: View {
    @EnvironmentObject private var activity: ActivityWatcher
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingClearAll = false

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity Log")
                    .font(.headline)
                Spacer()
                Text("\(activity.events.count) event\(activity.events.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            if activity.events.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No events recorded yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(activity.events.reversed()) { event in
                        ActivityLogRow(event: event)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    activity.deleteEvent(id: event.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    activity.deleteEvent(id: event.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button(role: .destructive) {
                    confirmingClearAll = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(activity.events.isEmpty)

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 420)
        .confirmationDialog(
            "Clear all logged activity?",
            isPresented: $confirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                activity.clear()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removes every recorded event. Watching continues; new events will start being logged again.")
        }
    }
}

private struct ActivityLogRow: View {
    let event: ActivityWatcher.Event

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    private var durationLabel: String? {
        guard let end = event.endTimestamp else { return nil }
        let secs = end.timeIntervalSince(event.timestamp)
        guard secs >= 60 else { return nil }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        let remaining = mins % 60
        return remaining == 0 ? "\(hours)h" : "\(hours)h \(remaining)m"
    }

    /// Idle annotation. Only shown when ≥1 min — sub-minute idle is noise.
    private var idleLabel: String? {
        guard let idle = event.idleSecondsAtCapture, idle >= 60 else { return nil }
        let mins = Int(idle / 60)
        if mins < 60 { return "idle \(mins)m" }
        let hours = mins / 60
        let remaining = mins % 60
        return remaining == 0 ? "idle \(hours)h" : "idle \(hours)h \(remaining)m"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.timestampFormatter.string(from: event.timestamp))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let duration = durationLabel {
                    Text(duration)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let idle = idleLabel {
                    Text(idle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.85))
                }
            }
            .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.appName)
                    .font(.system(size: 12, weight: .semibold))
                if let tabTitle = event.tabTitle, !tabTitle.isEmpty {
                    Text(tabTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let url = event.tabURL, !url.isEmpty {
                        Text(url)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else if let title = event.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyTabPlaceholder: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("NotchNik Settings")
    }
}

#Preview {
    NotchNikSettingsView()
        .environmentObject(AppSettingsStore())
        .environmentObject(ClipboardHistoryStore(settings: AppSettingsStore()))
}
