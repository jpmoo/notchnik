//
//  ActivityWatcher.swift
//  notch
//
//  Polls the foreground app + focused window title via the Accessibility (AX) API. Permission to
//  use AX is granted by the user in System Settings → Privacy & Security → Accessibility; we expose
//  a request button that triggers the standard prompt.
//
//  This is the scaffolding layer — capture and ring-buffer the events. Higher-level features
//  (productivity summaries via Ollama, longer-term persistence, browser-tab introspection) build on
//  top of `events` and the `Event` model.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
final class ActivityWatcher: ObservableObject {
    struct Event: Identifiable, Codable, Equatable {
        let id: UUID
        /// First time we observed this app/window/tab combination.
        let timestamp: Date
        /// Last time the *same* combination was still on screen. Updated each capture tick while
        /// the streak continues, so `endTimestamp - timestamp` is the streak's duration. Nil for
        /// rows decoded from older manifest versions; treat as equal to `timestamp` in that case.
        var endTimestamp: Date?
        let appName: String
        let bundleID: String?
        let windowTitle: String?
        /// URL of the active tab when the front app is a supported browser. Nil otherwise.
        var tabURL: String?
        /// Title of the active tab when the front app is a supported browser. Nil otherwise.
        var tabTitle: String?
        /// Seconds since the last user input (mouse/keyboard/trackpad anywhere on the system) at
        /// the moment we last sampled this streak. Updated on every tick that extends the streak,
        /// so by the time the streak closes this represents the idle gap at its trailing edge.
        /// Used downstream to back out AFK time from focus calculations. Nil for rows decoded
        /// from older manifests; treat as 0 in that case.
        var idleSecondsAtCapture: TimeInterval?
    }

    /// Most recent first, capped at `maxEvents` so a long-running session doesn't grow without bound.
    @Published private(set) var events: [Event] = []
    @Published private(set) var isWatching: Bool = false
    @Published private(set) var hasAccessibilityPermission: Bool = false
    /// Most recently captured snapshot — separately surfaced for UI status displays even if events
    /// haven't yet been deduplicated into the buffer.
    @Published private(set) var latestEvent: Event?

    /// Sample interval. 30s is a sensible default — frequent enough to catch context switches,
    /// sparse enough that polling cost is negligible.
    var pollInterval: TimeInterval = 30

    /// Bound on the in-memory event ring. Events older than this get evicted from the head.
    private static let maxEvents = 2000

    /// Days of history to retain on disk. `0` means forever. Set by `AppDelegate` from
    /// `settings.activityRetentionDays`; pruning happens after each capture and on init.
    var retentionDays: Int = 0 {
        didSet { pruneByRetention() }
    }

    private static let storageFolderName = "NotchNik"
    private static let manifestFileName = "activity_log.json"

    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Self.storageFolderName, isDirectory: true)
    }

    private var manifestURL: URL {
        storageDirectory.appendingPathComponent(Self.manifestFileName)
    }

    private var timer: Timer?

    init() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        loadFromDisk()
        refreshPermissionStatus()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Permission

    /// Reads the current AX trust status without prompting the user. Call this on settings appear
    /// and after returning from System Settings, so the toggle/badge reflect reality.
    func refreshPermissionStatus() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    /// Triggers the macOS Accessibility prompt dialog if the app isn't yet trusted. The system
    /// only shows the dialog once per bundle ID — if the app has already been requested before
    /// (or is in the AX list but toggled off), the call returns false with no UI. Falls through
    /// to opening System Settings → Privacy → Accessibility so the click always produces a result.
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = granted
        if !granted {
            // Prompt was suppressed — bring the user to the right pane manually so they can
            // add/enable the app there.
            openSystemAccessibilitySettings()
        }
        return granted
    }

    /// Shortcut so a settings UI button can jump the user straight to the right pane.
    func openSystemAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Watching

    func start() {
        guard !isWatching else { return }
        isWatching = true
        captureSnapshot()
        // Unwrap `self` strongly inside the Timer closure before the Task hop. Swift 6 strict
        // concurrency rejects passing the captured weak optional through the @MainActor Task —
        // unwrapping first gives a Sendable-safe strong reference for the duration of the tick.
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.captureSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isWatching = false
    }

    func clear() {
        events.removeAll()
        latestEvent = nil
        saveToDisk()
    }

    /// Removes a single logged event by id.
    func deleteEvent(id: UUID) {
        events.removeAll { $0.id == id }
        if latestEvent?.id == id { latestEvent = nil }
        saveToDisk()
    }

    // MARK: - Persistence + retention

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let stored = try? decoder.decode([Event].self, from: data) {
            // Drop any persisted `loginwindow` entries from prior versions of the watcher.
            // Same broadened match as captureSnapshot — bundleID prefix + name contains.
            let cleaned = stored.filter { event in
                let bundleMatches = event.bundleID?.lowercased().hasPrefix("com.apple.loginwindow") ?? false
                let nameMatches = event.appName.lowercased().contains("loginwindow")
                return !bundleMatches && !nameMatches
            }
            events = cleaned
            latestEvent = cleaned.last
            if cleaned.count != stored.count {
                saveToDisk()
            }
        }
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Drops events older than `retentionDays`. No-op when retention is 0 (forever) or no events.
    func pruneByRetention() {
        guard retentionDays > 0, !events.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let originalCount = events.count
        events.removeAll { $0.timestamp < cutoff }
        if events.count != originalCount {
            saveToDisk()
        }
    }

    // MARK: - Capture

    /// Forces an immediate snapshot, bypassing the timer cadence. Returns synchronously after
    /// updating `events` and `latestEvent`. Used by the commentator (and other ad-hoc callers)
    /// when they need the very latest frontmost app, not whatever the 30s tick last saw.
    func captureNow() {
        captureSnapshot()
    }

    private func captureSnapshot() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier
        // Ignore the lock screen / login screen entirely. Match by bundleID prefix and by
        // localized name so sub-bundle variants and unusual casing don't slip past.
        if let id = bundleID?.lowercased(), id.hasPrefix("com.apple.loginwindow") { return }
        if appName.lowercased().contains("loginwindow") { return }
        var windowTitle: String?

        if hasAccessibilityPermission {
            windowTitle = focusedWindowTitle(forPID: frontApp.processIdentifier)
        }

        // For supported browsers, ask via AppleScript for the active tab's URL + title. Sandbox
        // permission for this is requested separately (com.apple.security.automation.apple-events
        // entitlement + NSAppleEventsUsageDescription); the user grants per-app authorization the
        // first time the script runs.
        //
        // Privacy: when the active window is private/incognito we still log the *event* (so the
        // app's "you spent N min in Chrome" stats stay accurate), but we drop the URL and tab
        // title and replace the window title with a generic "(private window)" sentinel. The
        // raw page identity never reaches the activity log, focus prompt, or chat context.
        var tabURL: String?
        var tabTitle: String?
        if let bundleID, let context = BrowserContextFetcher.fetch(bundleID: bundleID) {
            if context.isPrivate {
                tabURL = nil
                tabTitle = nil
                windowTitle = "(private window)"
            } else {
                tabURL = context.url
                tabTitle = context.title
            }
        }

        let now = Date()
        // System-wide idle time: seconds since the last input event of any kind (mouse, key,
        // scroll, trackpad). Doesn't require AX or any new entitlement; works while sandboxed.
        // `kCGAnyInputEventType` (0xFFFFFFFF) isn't bridged as a Swift enum case on CGEventType,
        // so construct it from the raw value. Returns seconds since the most recent input of
        // any kind across the whole session.
        let anyEventType = CGEventType(rawValue: ~0) ?? .null
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEventType)
        let event = Event(
            id: UUID(),
            timestamp: now,
            endTimestamp: now,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            tabURL: tabURL,
            tabTitle: tabTitle,
            idleSecondsAtCapture: idleSeconds
        )

        // Streak handling: if the previous event matches the current observation AND the time
        // gap since its last sample is small (within a few poll intervals), extend its
        // `endTimestamp` instead of appending a duplicate. Without the gap check, locked-screen
        // / loginwindow stretches (which we filter out at capture, so no new events accrue
        // during them) silently extend whichever app was frontmost before the lock — making a
        // 9:05–10:00 AM gap look like one continuous hour of Xcode. Beyond the threshold we
        // treat it as a fresh session even when the same app is in front.
        let maxStreakGap = pollInterval * 4   // ~2 min by default
        if var last = events.last,
           last.appName == event.appName,
           last.bundleID == event.bundleID,
           last.windowTitle == event.windowTitle,
           last.tabURL == event.tabURL,
           last.tabTitle == event.tabTitle,
           now.timeIntervalSince(last.endTimestamp ?? last.timestamp) <= maxStreakGap {
            last.endTimestamp = now
            last.idleSecondsAtCapture = idleSeconds
            events[events.count - 1] = last
            latestEvent = last
            saveToDisk()
            return
        }

        events.append(event)
        latestEvent = event
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        pruneByRetention()
        saveToDisk()
    }

    /// Reads the focused window title for the app with the given process ID via AX. Returns nil
    /// when the app isn't AX-readable (some apps refuse to expose a focused window) or permission
    /// has been revoked between checks.
    private func focusedWindowTitle(forPID pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedRef
        )
        guard focusedResult == .success, let focusedRef else { return nil }

        // The runtime type is opaque to Swift's `as?` until forced; check the AX type ID.
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let window = focusedRef as! AXUIElement

        var titleRef: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleRef
        )
        guard titleResult == .success, let titleRef else { return nil }
        return titleRef as? String
    }
}

// MARK: - Browser tab fetching via AppleScript

/// Extracts the active tab's URL and title from a supported front browser. Uses AppleScript via
/// `NSAppleScript`; requires the host app to have the `com.apple.security.automation.apple-events`
/// entitlement and `NSAppleEventsUsageDescription` in Info.plist. Each browser asks the user for
/// permission the first time it's scripted (Privacy & Security → Automation).
enum BrowserContextFetcher {
    struct Context {
        let url: String?
        let title: String?
        /// True when the active tab is in a private/incognito window. Callers (currently the
        /// activity watcher) redact URL+title and label the window generically when this is set,
        /// so private browsing doesn't leak into the activity log or AI prompts.
        let isPrivate: Bool
    }

    private enum ScriptStyle { case safari, chromium }

    private struct BrowserInfo {
        let appName: String
        let bundleID: String
        let style: ScriptStyle
    }

    /// Bundle ID → AppleScript target metadata. We address apps by `application id "..."` instead
    /// of `application "Name"` because the bundle-ID form is more reliable for sandboxed clients
    /// (the name lookup can fail with -600 even when the target is running). Firefox is omitted —
    /// its AppleScript support doesn't expose the active tab.
    private static let browsers: [String: BrowserInfo] = [
        "com.apple.Safari":            BrowserInfo(appName: "Safari",              bundleID: "com.apple.Safari",          style: .safari),
        "com.google.Chrome":           BrowserInfo(appName: "Google Chrome",       bundleID: "com.google.Chrome",         style: .chromium),
        "com.google.Chrome.canary":    BrowserInfo(appName: "Google Chrome Canary",bundleID: "com.google.Chrome.canary",  style: .chromium),
        "com.brave.Browser":           BrowserInfo(appName: "Brave Browser",       bundleID: "com.brave.Browser",         style: .chromium),
        "com.microsoft.edgemac":       BrowserInfo(appName: "Microsoft Edge",      bundleID: "com.microsoft.edgemac",     style: .chromium),
        "company.thebrowser.Browser":  BrowserInfo(appName: "Arc",                 bundleID: "company.thebrowser.Browser",style: .chromium),
        "company.thebrowser.dia":      BrowserInfo(appName: "Dia",                 bundleID: "company.thebrowser.dia",    style: .chromium),
        "com.operasoftware.Opera":     BrowserInfo(appName: "Opera",               bundleID: "com.operasoftware.Opera",   style: .chromium),
        "com.vivaldi.Vivaldi":         BrowserInfo(appName: "Vivaldi",             bundleID: "com.vivaldi.Vivaldi",       style: .chromium)
    ]

    /// Result type for the diagnostic path. Lets the settings UI distinguish "this isn't a
    /// supported browser" from "the target refused / sandbox blocked" from "no data returned."
    struct DiagnosticResult {
        let appName: String?
        let context: Context?
        let error: String?
    }

    static func fetch(bundleID: String) -> Context? {
        fetchDetailed(bundleID: bundleID).context
    }

    /// Bundle IDs of all browsers we know how to script. Settings UI uses this to find a running
    /// browser to test against, since clicking "Test" pulls the Settings window in front.
    static var supportedBundleIDs: [String] {
        Array(browsers.keys)
    }

    /// Display name for a known bundle ID (or nil if unsupported).
    static func displayName(for bundleID: String) -> String? {
        browsers[bundleID]?.appName
    }

    static func fetchDetailed(bundleID: String) -> DiagnosticResult {
        guard let info = browsers[bundleID] else {
            return DiagnosticResult(appName: nil, context: nil, error: "Not a supported browser (\(bundleID))")
        }
        let source = script(for: info)
        guard let appleScript = NSAppleScript(source: source) else {
            return DiagnosticResult(appName: info.appName, context: nil, error: "Couldn't compile AppleScript")
        }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)

        if let errorDict {
            let message = (errorDict[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            let number = errorDict[NSAppleScript.errorNumber] as? Int
            // -1743 = errAEEventNotPermitted (user hasn't granted Automation permission yet).
            // -600  = process not found / not running.
            let combined = number.map { "\(message) (\($0))" } ?? message
            #if DEBUG
            NSLog("[NotchNik] AppleScript error for %@: %@", info.appName, combined)
            #endif
            return DiagnosticResult(appName: info.appName, context: nil, error: combined)
        }

        let combined = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // The script's `on error` branches now return "ERR:<message>" so we can distinguish "ran
        // fine but couldn't read a tab" from "we got real data".
        if combined.hasPrefix("ERR:") {
            return DiagnosticResult(appName: info.appName, context: nil, error: String(combined.dropFirst(4)))
        }

        let parts = combined.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        let url = parts.indices.contains(0) ? String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let title = parts.indices.contains(1) ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // Mode line: "incognito" (Chromium), "private" (Safari sentinel), or "normal" (default).
        // Anything other than "normal" means redact.
        let mode = parts.indices.contains(2) ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : "normal"
        let isPrivate = !mode.isEmpty && mode != "normal"

        if url.isEmpty && title.isEmpty {
            return DiagnosticResult(appName: info.appName, context: nil, error: "Empty response — front window may not have a readable tab")
        }

        return DiagnosticResult(
            appName: info.appName,
            context: Context(
                url: url.isEmpty ? nil : url,
                title: title.isEmpty ? nil : title,
                isPrivate: isPrivate
            ),
            error: nil
        )
    }

    private static func script(for info: BrowserInfo) -> String {
        switch info.style {
        case .safari:
            // Safari has no `mode` AppleScript property, so we sniff the window name for the
            // localized "Private Browsing" string macOS adds to private windows. This is fragile
            // outside English locales — the worst case is we treat a private window as normal,
            // which is the same exposure level we had before adding detection at all.
            return """
            tell application id "\(info.bundleID)"
                try
                    if (count of windows) is 0 then return "ERR:no windows open"
                    repeat with w in windows
                        try
                            set t to current tab of w
                            set u to URL of t
                            set ti to name of t
                            set wn to name of w
                            set modeStr to "normal"
                            if wn contains "Private Browsing" then set modeStr to "private"
                            if u is not missing value and u is not "" then
                                return (u as string) & linefeed & (ti as string) & linefeed & modeStr
                            end if
                        end try
                    end repeat
                    return "ERR:no readable tab in any window"
                on error errMsg number errNum
                    return "ERR:" & errMsg & " (" & errNum & ")"
                end try
            end tell
            """
        case .chromium:
            // Try the simple `front window` path first — it matches what works from osascript and
            // is the most-supported syntax across Chromium-based browsers (some, like Dia, don't
            // surface the active tab through iteration even though they support `front window`).
            // Fall back to iterating all windows if the front one isn't readable, which handles
            // Chrome's case where DevTools / Downloads can sit in front of the actual browser.
            //
            // `mode of window` returns "incognito" or "normal" on Chrome and most forks. Wrapped
            // in its own try/catch in case a future Chromium build drops the property — we'd
            // rather assume "normal" than have the whole script error out.
            return """
            tell application id "\(info.bundleID)"
                try
                    try
                        set u to URL of active tab of front window
                        set ti to title of active tab of front window
                        set modeStr to "normal"
                        try
                            set modeStr to (mode of front window as string)
                        end try
                        if u is not missing value and u is not "" then
                            return (u as string) & linefeed & (ti as string) & linefeed & modeStr
                        end if
                    end try
                    if (count of windows) is 0 then return "ERR:no windows open"
                    repeat with w in windows
                        try
                            set t to active tab of w
                            set u to URL of t
                            set ti to title of t
                            set modeStr to "normal"
                            try
                                set modeStr to (mode of w as string)
                            end try
                            if u is not missing value and u is not "" then
                                return (u as string) & linefeed & (ti as string) & linefeed & modeStr
                            end if
                        end try
                    end repeat
                    return "ERR:no readable tab in any window"
                on error errMsg number errNum
                    return "ERR:" & errMsg & " (" & errNum & ")"
                end try
            end tell
            """
        }
    }
}
