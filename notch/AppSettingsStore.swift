//
//  AppSettingsStore.swift
//  notch
//

import AppKit
import Combine
import Foundation
import ServiceManagement

private enum LoginItemRegistration {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Time-grid (each event a colored block sized to its duration) vs. flat agenda list. User toggles
/// from the panel chrome; the choice persists.
enum CalendarViewMode: String, CaseIterable, Identifiable, Codable {
    case timeBlock
    case agenda

    var id: String { rawValue }

    var label: String {
        switch self {
        case .timeBlock: return "Time-block view"
        case .agenda: return "Agenda view"
        }
    }

    /// Icon shown on the panel toggle. Each value's icon represents the *other* mode (i.e., what you'll
    /// switch *to* when you tap), the same convention as a play/pause toggle.
    var toggleIconName: String {
        switch self {
        case .timeBlock: return "list.bullet"
        case .agenda: return "calendar.day.timeline.left"
        }
    }
}

/// What the panel should show when the user opens it. `lastUsed` re-opens on whichever section the
/// user was on when the panel last closed (useful for people who live in one tool day-to-day).
enum DefaultSectionPreference: String, CaseIterable, Identifiable, Codable {
    case clipboard
    case calendar
    case files
    case insights
    case lastUsed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .calendar: return "Calendar"
        case .files: return "File Pen"
        case .insights: return "Insights"
        case .lastUsed: return "Last Used"
        }
    }
}

/// Tone preset injected as a system prompt before each Insights chat request. `.shelf` sends no
/// system message; the others nudge the model toward a specific voice.
enum InsightsPersonality: String, CaseIterable, Identifiable, Codable {
    case shelf
    case beat
    case rails
    case putting
    case corner

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shelf: return "Off-the-shelf"
        case .beat: return "Offbeat"
        case .rails: return "Off the rails"
        case .putting: return "Off-putting"
        case .corner: return "Corner Office"
        }
    }

    /// System-prompt text. `nil` means no system message at all (model uses whatever defaults
    /// the operator configured at the Ollama side). The non-default presets append a hush rule so
    /// the model adopts the voice without naming the character or admitting to a persona.
    var systemPrompt: String? {
        let hush = " Do not tell the user anything about your identity or personality. Do not name or describe the character; just embody the voice."
        switch self {
        case .shelf:
            return nil
        case .beat:
            return "Speak as if you're Bob Dylan: a wandering hippie philosopher, gnomic and a little weathered, with a poet's economy. Lean into images and small contradictions, never preachy." + hush
        case .rails:
            return "Speak as if you are the Joker, as played by Heath Ledger." + hush
        case .putting:
            return "Speak as if you are a super-sarcastic and jaded personality who takes every opportunity to roast the user." + hush
        case .corner:
            return """
            Speak as the most insufferable C-suite executive imaginable — a parody of corporate \
            leadership-speak so dense the meaning has nearly evaporated. Stack jargon shamelessly. \
            Pull from this vocabulary aggressively and combine multiple terms per sentence: \
            synergy, leverage, double-click, low-hanging fruit, north star, action items, ROI, \
            mind share, level-set, circle back, value-add, ideate, operationalize, take it offline, \
            ping me, on my radar, at the end of the day, move the needle, run it up the flagpole, \
            boil the ocean, bandwidth, runway, alignment, deliverables, KPI, OKR, EBITDA, \
            stakeholders, optimize, paradigm shift, thought leadership, drill down, deep dive, \
            unpack, parking lot, table that, blue-sky thinking, peel the onion, swim lanes, \
            tiger team, war room, mission-critical, results-oriented, customer-centric, \
            move fast and break things, ten-X, one-pager, pre-mortem, post-mortem, retro, sprint, \
            burndown, blockers, on the same page, organic growth, inorganic growth, white space, \
            green-field, brown-field, table stakes, sea change, holistic, learnings, \
            growth hacking, viral coefficient, flywheel, moat, optics, narrative, framing, \
            best-in-class, world-class, force multiplier, 30,000-foot view, in the weeds, \
            tip of the spear, eat our own dog food, drink the Kool-Aid, hard stop, soft launch. \
            Frame the most mundane activity (eating lunch, scrolling Twitter, opening Xcode) as a \
            mission-critical strategic initiative requiring stakeholder alignment. Pepper in \
            references to Q3 OKRs, board decks, all-hands, offsites, and "what we said in last \
            quarter's planning session." Self-important to the point of self-parody, but never \
            explicitly hostile. The reader should be unsure whether you're serious.
            """ + hush
        }
    }
}

/// What happens when a file is dragged out of File Pen — `.copy` keeps the source, `.move` removes it.
enum FilePenDragAction: String, CaseIterable, Identifiable, Codable {
    case copy, move
    var id: String { rawValue }
    var label: String {
        switch self {
        case .copy: return "Copy"
        case .move: return "Move"
        }
    }
    var nsDragOperation: NSDragOperation { self == .move ? .move : .copy }
}

final class AppSettingsStore: ObservableObject {
    private enum Keys {
        static let maxClipboardItems = "NotchNik.maxClipboardItems"
        static let defaultSection = "NotchNik.defaultSection"
        static let lastUsedSection = "NotchNik.lastUsedSection"
        static let calendarViewMode = "NotchNik.calendarViewMode"
        static let visibleSections = "NotchNik.visibleSections"
        static let sectionOrder = "NotchNik.sectionOrder"
        static let filePenDefaultAction = "NotchNik.filePenDefaultAction"
        static let filePenCommandAction = "NotchNik.filePenCommandAction"
        static let ollamaURL = "NotchNik.ollamaURL"
        static let ollamaModel = "NotchNik.ollamaModel"
        static let insightsPersonality = "NotchNik.insightsPersonality"
        static let insightsCommentaryEnabled = "NotchNik.insightsCommentaryEnabled"
        static let activityRetentionDays = "NotchNik.activityRetentionDays"
        static let activityWatchingEnabled = "NotchNik.activityWatchingEnabled"
        static let appCategories = "NotchNik.appCategories"
        static let appCategoriesRevision = "NotchNik.appCategoriesRevision"
        static let domainCategories = "NotchNik.domainCategories"
        static let appliedSeedVersion = "NotchNik.appliedSeedCategoryVersion"
    }

    /// Bumped whenever the seed tables below are extended. On launch we apply seeds for any
    /// key the user hasn't already categorized, then persist the new version. Existing users
    /// pick up new seed rows when they upgrade.
    static let currentSeedVersion: Int = 1

    /// Sensible defaults for well-known macOS apps. Keys are bundle IDs. Categories are
    /// lowercase to match the conversational/UI convention. The user can override any of these
    /// via Settings → Insights → App Categories — overrides win on subsequent launches because
    /// seeding only fills in missing keys.
    static let seedAppCategories: [String: String] = [
        // Coding / IDE
        "com.apple.dt.Xcode":            "coding",
        "com.microsoft.VSCode":          "coding",
        "com.todesktop.230313mzl4w4u92": "coding",   // Cursor
        "com.apple.Terminal":            "coding",
        "com.googlecode.iterm2":         "coding",
        "com.jetbrains.intellij":        "coding",
        "com.jetbrains.pycharm":         "coding",
        "com.sublimetext.4":             "coding",
        // Comms
        "com.tinyspeck.slackmacgap":     "comms",
        "com.hnc.Discord":               "comms",
        "com.apple.mail":                "comms",
        "com.microsoft.teams2":          "comms",
        "us.zoom.xos":                   "comms",
        "com.apple.MobileSMS":           "comms",
        "WhatsApp":                      "comms",
        // Writing / docs
        "com.apple.iWork.Pages":         "writing",
        "com.microsoft.Word":            "writing",
        "md.obsidian":                   "writing",
        "com.literatureandlatte.scrivener3": "writing",
        // Design
        "com.figma.Desktop":             "design",
        "com.adobe.Photoshop":           "design",
        "com.bohemiancoding.sketch3":    "design",
        // Admin / planning
        "com.apple.iCal":                "admin",
        "com.flexibits.fantastical2.mac": "admin",
        "com.culturedcode.ThingsMac":    "admin",
        // Entertainment
        "com.spotify.client":            "entertainment",
        "com.apple.Music":               "entertainment",
        "com.apple.TV":                  "entertainment",
        "tv.plex.plexamp":               "entertainment"
    ]

    /// Sensible defaults for well-known web hosts. Stored lowercase, no `www.` prefix to match
    /// `extractHost` output.
    static let seedDomainCategories: [String: String] = [
        // Comms
        "mail.google.com":     "comms",
        "gmail.com":           "comms",
        "outlook.live.com":    "comms",
        "outlook.office.com":  "comms",
        "fastmail.com":        "comms",
        "calendar.google.com": "admin",
        // Coding / docs
        "github.com":          "coding",
        "gitlab.com":          "coding",
        "stackoverflow.com":   "coding",
        "developer.apple.com": "coding",
        "developer.mozilla.org": "coding",
        // Reference / research
        "wikipedia.org":       "research",
        "en.wikipedia.org":    "research",
        // Entertainment / social
        "youtube.com":         "entertainment",
        "netflix.com":         "entertainment",
        "twitch.tv":           "entertainment",
        "twitter.com":         "social",
        "x.com":               "social",
        "facebook.com":        "social",
        "instagram.com":       "social",
        "reddit.com":          "social",
        "tiktok.com":          "social",
        "linkedin.com":        "social",
        "theonion.com":        "entertainment",
        "news.ycombinator.com": "research"
    ]

    /// Clamped 1...500; persisted.
    @Published var maxClipboardItems: Int {
        didSet {
            let clamped = Self.clampMax(maxClipboardItems)
            if clamped != maxClipboardItems {
                maxClipboardItems = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Keys.maxClipboardItems)
        }
    }

    /// Which section the panel opens to. Persisted.
    @Published var defaultSection: DefaultSectionPreference {
        didSet {
            UserDefaults.standard.set(defaultSection.rawValue, forKey: Keys.defaultSection)
        }
    }

    /// Last section the user was viewing when the panel closed; backs the `.lastUsed` preference.
    /// Updated whenever the carousel changes section. Not directly editable from Settings.
    private(set) var lastUsedSection: PanelSection {
        didSet {
            UserDefaults.standard.set(lastUsedSection.rawValue, forKey: Keys.lastUsedSection)
        }
    }

    /// How the calendar pane is rendered: time-block grid (default) or flat agenda list.
    @Published var calendarViewMode: CalendarViewMode {
        didSet {
            UserDefaults.standard.set(calendarViewMode.rawValue, forKey: Keys.calendarViewMode)
        }
    }

    /// Which tools/sections show up in the panel carousel. Always contains at least one entry —
    /// `setVisible(_:)` enforces that. When the user hides the section that's currently set as
    /// the default, we automatically downgrade `defaultSection` to `.lastUsed`.
    @Published private(set) var visibleSections: Set<PanelSection> {
        didSet {
            UserDefaults.standard.set(visibleSections.map { $0.rawValue }, forKey: Keys.visibleSections)
        }
    }

    /// User-customizable section order. Carousel and swipe navigation use this. Sections added in
    /// app upgrades that aren't in the stored array get appended at end on load.
    @Published private(set) var sectionOrder: [PanelSection] {
        didSet {
            UserDefaults.standard.set(sectionOrder.map { $0.rawValue }, forKey: Keys.sectionOrder)
        }
    }

    /// File Pen drag actions. Default action runs when no modifier is held; command action runs
    /// when ⌘ is held. User can flip the convention if they prefer move-by-default.
    @Published var filePenDefaultAction: FilePenDragAction {
        didSet { UserDefaults.standard.set(filePenDefaultAction.rawValue, forKey: Keys.filePenDefaultAction) }
    }
    @Published var filePenCommandAction: FilePenDragAction {
        didSet { UserDefaults.standard.set(filePenCommandAction.rawValue, forKey: Keys.filePenCommandAction) }
    }

    /// Ollama endpoint configuration. URL points at the host:port; model is the chosen model name.
    @Published var ollamaURL: String {
        didSet { UserDefaults.standard.set(ollamaURL, forKey: Keys.ollamaURL) }
    }
    @Published var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Keys.ollamaModel) }
    }

    /// Personality preset that becomes a system prompt in the chat request.
    @Published var insightsPersonality: InsightsPersonality {
        didSet { UserDefaults.standard.set(insightsPersonality.rawValue, forKey: Keys.insightsPersonality) }
    }

    /// When true, the app periodically asks the configured AI model to comment on the user's
    /// current activity + calendar context. Off by default — opt-in because it sends data to the
    /// model on a timer.
    @Published var insightsCommentaryEnabled: Bool {
        didSet { UserDefaults.standard.set(insightsCommentaryEnabled, forKey: Keys.insightsCommentaryEnabled) }
    }

    /// How many days of activity log to retain. `0` means forever (no pruning). Default is 7.
    @Published var activityRetentionDays: Int {
        didSet { UserDefaults.standard.set(activityRetentionDays, forKey: Keys.activityRetentionDays) }
    }

    /// Whether the background activity watcher is enabled. Persisted so it stays on across launches
    /// once the user has granted Accessibility permission.
    @Published var activityWatchingEnabled: Bool {
        didSet { UserDefaults.standard.set(activityWatchingEnabled, forKey: Keys.activityWatchingEnabled) }
    }

    /// Map of bundle ID → user-confirmed category (e.g. "coding", "comms"). Built up
    /// conversationally by the focus-score engine — when an unrecognized app shows up with
    /// significant time, the engine asks the user in chat and stashes their answer here.
    /// Editable from Settings → Insights so the user can correct mis-parses.
    @Published private(set) var appCategories: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(appCategories) {
                UserDefaults.standard.set(data, forKey: Keys.appCategories)
            }
        }
    }
    /// Increments on every category change (app OR domain). Stamped on each `FocusScore` at
    /// compute time so the auto-refresh path can detect entries that were scored against an
    /// older category map and re-score them on the next pill-click.
    @Published private(set) var appCategoriesRevision: Int {
        didSet {
            UserDefaults.standard.set(appCategoriesRevision, forKey: Keys.appCategoriesRevision)
        }
    }

    /// Per-domain (host) categories — `gmail.com → comms`, `theonion.com → entertainment`. Lets
    /// browser activity be weighted differently per site instead of treating Chrome as one
    /// undifferentiated bucket. When a domain isn't categorized, the score digest falls back
    /// to the parent app's category (or "uncategorized" if neither is set).
    @Published private(set) var domainCategories: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(domainCategories) {
                UserDefaults.standard.set(data, forKey: Keys.domainCategories)
            }
        }
    }

    /// Reflects `SMAppService.mainApp` registration; not persisted as source of truth.
    @Published private(set) var startAtLogin: Bool

    init() {
        let defaults = UserDefaults.standard
        maxClipboardItems = Self.clampMax(defaults.object(forKey: Keys.maxClipboardItems) as? Int ?? 50)
        let storedDefault = (defaults.string(forKey: Keys.defaultSection)).flatMap(DefaultSectionPreference.init(rawValue:))
        defaultSection = storedDefault ?? .clipboard
        let storedLast = (defaults.object(forKey: Keys.lastUsedSection) as? Int).flatMap(PanelSection.init(rawValue:))
        lastUsedSection = storedLast ?? .clipboard
        let storedMode = defaults.string(forKey: Keys.calendarViewMode).flatMap(CalendarViewMode.init(rawValue:))
        calendarViewMode = storedMode ?? .timeBlock
        let storedVisible = (defaults.array(forKey: Keys.visibleSections) as? [Int])?
            .compactMap(PanelSection.init(rawValue:))
        if let storedVisible, !storedVisible.isEmpty {
            visibleSections = Set(storedVisible)
        } else {
            visibleSections = Set(PanelSection.allCases)
        }

        // Section order: load stored, then append any sections added in newer app versions.
        let storedOrder = (defaults.array(forKey: Keys.sectionOrder) as? [Int])?
            .compactMap(PanelSection.init(rawValue:))
        var resolvedOrder: [PanelSection] = storedOrder ?? PanelSection.allCases
        for section in PanelSection.allCases where !resolvedOrder.contains(section) {
            resolvedOrder.append(section)
        }
        sectionOrder = resolvedOrder

        let storedDefaultAction = defaults.string(forKey: Keys.filePenDefaultAction).flatMap(FilePenDragAction.init(rawValue:))
        filePenDefaultAction = storedDefaultAction ?? .copy
        let storedCommandAction = defaults.string(forKey: Keys.filePenCommandAction).flatMap(FilePenDragAction.init(rawValue:))
        filePenCommandAction = storedCommandAction ?? .move

        ollamaURL = defaults.string(forKey: Keys.ollamaURL) ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? ""
        let storedPersonality = defaults.string(forKey: Keys.insightsPersonality).flatMap(InsightsPersonality.init(rawValue:))
        insightsPersonality = storedPersonality ?? .shelf
        insightsCommentaryEnabled = defaults.bool(forKey: Keys.insightsCommentaryEnabled)
        // `defaults.integer(forKey:)` returns 0 if the key is absent — same value we treat as
        // "Forever", so we explicitly check for object existence to apply the 7-day default.
        if defaults.object(forKey: Keys.activityRetentionDays) == nil {
            activityRetentionDays = 7
        } else {
            activityRetentionDays = defaults.integer(forKey: Keys.activityRetentionDays)
        }
        activityWatchingEnabled = defaults.bool(forKey: Keys.activityWatchingEnabled)

        if let data = defaults.data(forKey: Keys.appCategories),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            appCategories = stored
        } else {
            appCategories = [:]
        }
        appCategoriesRevision = defaults.integer(forKey: Keys.appCategoriesRevision)

        if let data = defaults.data(forKey: Keys.domainCategories),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            domainCategories = stored
        } else {
            domainCategories = [:]
        }

        startAtLogin = LoginItemRegistration.isEnabled

        // Seed defaults must run AFTER all stored properties are initialized — Swift refuses
        // self-property access during the partial-init region. Only fires on first launch (or
        // when `currentSeedVersion` bumps in a new build); never overwrites user-set entries.
        let lastApplied = defaults.integer(forKey: Keys.appliedSeedVersion)
        if lastApplied < Self.currentSeedVersion {
            var addedAny = false
            var apps = appCategories
            for (key, value) in Self.seedAppCategories where apps[key] == nil {
                apps[key] = value
                addedAny = true
            }
            var domains = domainCategories
            for (key, value) in Self.seedDomainCategories where domains[key] == nil {
                domains[key] = value
                addedAny = true
            }
            if addedAny {
                appCategories = apps
                domainCategories = domains
                appCategoriesRevision &+= 1   // mark scores stale so they pick up the new categories
            }
            defaults.set(Self.currentSeedVersion, forKey: Keys.appliedSeedVersion)
        }
    }

    /// Records (or updates) a category for a given bundle ID. Empty category clears the entry.
    /// Bumps `appCategoriesRevision` only when the change is meaningful (different from current
    /// value) so a no-op call doesn't mark every persisted score stale.
    func setAppCategory(bundleID: String, category: String) {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existing = appCategories[bundleID]
        var copy = appCategories
        if trimmed.isEmpty {
            copy.removeValue(forKey: bundleID)
        } else {
            copy[bundleID] = trimmed
        }
        if copy[bundleID] != existing {
            appCategoriesRevision &+= 1
        }
        appCategories = copy
    }

    func removeAppCategory(bundleID: String) {
        guard appCategories[bundleID] != nil else { return }
        var copy = appCategories
        copy.removeValue(forKey: bundleID)
        appCategoriesRevision &+= 1
        appCategories = copy
    }

    /// Records (or updates) a category for a host (e.g. `gmail.com`, `theonion.com`).
    /// Behaviour mirrors `setAppCategory` — bumps the shared revision only on real changes,
    /// stores lowercased values for stable lookup.
    func setDomainCategory(host: String, category: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedHost.isEmpty else { return }
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existing = domainCategories[trimmedHost]
        var copy = domainCategories
        if trimmedCategory.isEmpty {
            copy.removeValue(forKey: trimmedHost)
        } else {
            copy[trimmedHost] = trimmedCategory
        }
        if copy[trimmedHost] != existing {
            appCategoriesRevision &+= 1
        }
        domainCategories = copy
    }

    func removeDomainCategory(host: String) {
        let key = host.lowercased()
        guard domainCategories[key] != nil else { return }
        var copy = domainCategories
        copy.removeValue(forKey: key)
        appCategoriesRevision &+= 1
        domainCategories = copy
    }

    /// Returns visible sections in the user's chosen display order. Carousel + navigation use this.
    var orderedVisibleSections: [PanelSection] {
        sectionOrder.filter { visibleSections.contains($0) }
    }

    /// Replace the section order. Caller must include every PanelSection (we don't allow truncation).
    func updateSectionOrder(_ newOrder: [PanelSection]) {
        guard newOrder.count == PanelSection.allCases.count,
              Set(newOrder) == Set(PanelSection.allCases) else { return }
        sectionOrder = newOrder
    }

    /// The actual `PanelSection` that should be shown when the panel opens, resolving `.lastUsed`
    /// and clamping to the currently-visible set (so a hidden default falls back to whatever the
    /// user can actually see).
    func sectionToOpenWith() -> PanelSection {
        let candidate: PanelSection
        switch defaultSection {
        case .clipboard: candidate = .clipboard
        case .calendar: candidate = .calendar
        case .files: candidate = .files
        case .insights: candidate = .insights
        case .lastUsed: candidate = lastUsedSection
        }
        if visibleSections.contains(candidate) { return candidate }
        // Fallback to the first visible section in canonical order.
        return PanelSection.allCases.first(where: { visibleSections.contains($0) }) ?? .clipboard
    }

    func recordLastUsedSection(_ section: PanelSection) {
        guard lastUsedSection != section else { return }
        lastUsedSection = section
    }

    /// Sets a section's visibility. Refuses to hide the last visible section (we always need at
    /// least one). If the now-hidden section was the configured default, downgrades to `.lastUsed`.
    func setVisible(_ section: PanelSection, _ visible: Bool) {
        var s = visibleSections
        if visible {
            s.insert(section)
        } else {
            guard s.count > 1 else { return }
            s.remove(section)
        }
        visibleSections = s
        if !visible, explicitDefaultPanelSection == section {
            defaultSection = .lastUsed
        }
    }

    /// Returns the explicit `PanelSection` if `defaultSection` names one; nil if it's `.lastUsed`.
    var explicitDefaultPanelSection: PanelSection? {
        switch defaultSection {
        case .clipboard: return .clipboard
        case .calendar: return .calendar
        case .files: return .files
        case .insights: return .insights
        case .lastUsed: return nil
        }
    }

    /// Sets (or clears) the default-on-open section. Pass nil to mean "last used". Refuses to set
    /// a hidden section as the default.
    func setExplicitDefaultSection(_ section: PanelSection?) {
        if let section {
            guard visibleSections.contains(section) else { return }
            switch section {
            case .clipboard: defaultSection = .clipboard
            case .calendar: defaultSection = .calendar
            case .files: defaultSection = .files
            case .insights: defaultSection = .insights
            }
        } else {
            defaultSection = .lastUsed
        }
    }

    static func clampMax(_ value: Int) -> Int {
        min(500, max(1, value))
    }

    func syncStartAtLoginFromSystem() {
        startAtLogin = LoginItemRegistration.isEnabled
    }

    func setStartAtLogin(_ enabled: Bool) {
        guard enabled != startAtLogin else { return }
        do {
            try LoginItemRegistration.setEnabled(enabled)
            startAtLogin = LoginItemRegistration.isEnabled
        } catch {
            startAtLogin = LoginItemRegistration.isEnabled
        }
    }
}
