//
//  InsightsView.swift
//  notch
//
//  Basic chat panel that talks to the configured Ollama model. Conversation history is in-memory
//  and per-session — the panel-chrome trash icon clears it.
//

import Combine
import SwiftUI

/// Identity prompt prepended to every Insights chat request — both interactive and autonomous —
/// so the model treats NotchNik features as part of itself instead of as external products.
let notchnikIdentityPrompt = """
You are integrated into NotchNik, a macOS notch utility. Do not introduce yourself, describe \
yourself, or volunteer information about NotchNik or its features. Do not pitch the app, list \
capabilities, or use marketing language. If the user mentions clipboard, calendar, or file-pen \
behavior, treat those as your own actions — never refer to them as a separate product or tool. \
Otherwise stay out of meta-conversation about the app and just answer what the user actually asked.

When you receive an activity context block, treat ONLY the "Currently in focus" section as \
present-tense reality. Items under "Earlier today" are historical — those apps, tabs, and \
documents may already be closed. Refer to them in past tense ("you were Googling…", "you had a \
slide titled…") and never assume they are still on screen. If "Currently in focus" is empty or \
missing, the user is between apps; don't fabricate what they're doing.
"""

/// Builds the layered system prompt: identity → personality → optional observation context. The
/// commentary engine passes a context string; interactive chat passes nil.
func buildInsightsSystemPrompt(personality: InsightsPersonality, observationContext: String? = nil) -> String {
    var parts: [String] = [notchnikIdentityPrompt]
    if let p = personality.systemPrompt {
        parts.append(p)
    }
    if let observationContext {
        parts.append(observationContext)
    }
    return parts.joined(separator: "\n\n")
}

/// Single source of truth for "what is the user doing right now + what's on their calendar +
/// what have they been doing recently." Used by both the interactive chat and the autonomous
/// commentator so they share grounding.
@MainActor
enum InsightsContextBuilder {
    static func build(activity: ActivityWatcher, calendar: CalendarFeedStore) -> String {
        var parts: [String] = []
        let act = describeActivity(activity)
        // Always emit the focus block so the model can see when nothing is in focus, rather than
        // silently dropping the section and letting the model assume the historical block is current.
        parts.append("Currently in focus:\n" + (act.isEmpty ? "(nothing — user is between apps)" : act))
        let cal = describeCalendar(calendar)
        if !cal.isEmpty { parts.append("Calendar context:\n" + cal) }
        let usage = describeRecentUsage(activity)
        if !usage.isEmpty {
            parts.append("""
            Earlier today (HISTORICAL — newest first; aggregated by contiguous app session, NOT \
            per-tab. Each row is one stretch of attention. Format: <start>–<end> [<wall> (<active>)] \
            <app> — <N distinct tabs/windows> (e.g. <a few representative subjects>). Rows in past \
            tense; those tabs/windows may be closed now. USE THIS to spot streaks ("you've been in \
            X for an hour"), shifts ("you bounced from Slack to Chrome to Slack"), and depth vs. \
            scatter — don't enumerate the rows themselves.

            \(usage)
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    static func describeActivity(_ activity: ActivityWatcher) -> String {
        guard let last = activity.latestEvent else { return "" }
        var lines: [String] = ["App: \(last.appName)"]
        if let title = last.windowTitle, !title.isEmpty {
            lines.append("Window: \(title)")
        }
        if let tabTitle = last.tabTitle, !tabTitle.isEmpty {
            lines.append("Tab: \(tabTitle)")
        }
        if let url = last.tabURL, !url.isEmpty {
            lines.append("URL: \(url)")
        }
        // Idle annotation: only surface when nontrivial. Lets the model say "looks like you stepped
        // away" or correlate with a meeting on the calendar instead of riffing on whatever app
        // happens to still be frontmost.
        if let idle = last.idleSecondsAtCapture, idle >= 60 {
            let mins = Int(idle / 60)
            lines.append("Idle (no input): \(mins) min")
        }
        return lines.joined(separator: "\n")
    }

    static func describeCalendar(_ calendar: CalendarFeedStore) -> String {
        let now = Date()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return "" }

        // Anything that overlaps today, sorted by start. This is what the model needs to answer
        // "what's going on today?" — previously we only sent next-hour events, which made the
        // bot useless for any forward-looking calendar question.
        let todayEvents = calendar.events
            .filter { $0.start < endOfDay && $0.end > startOfDay }
            .sorted { $0.start < $1.start }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        var lines: [String] = ["Now: \(timeFormatter.string(from: now))"]
        if todayEvents.isEmpty {
            lines.append("No events on calendar today.")
            return lines.joined(separator: "\n")
        }

        lines.append("Today's events (across all subscribed feeds):")
        for event in todayEvents {
            let startStr = timeFormatter.string(from: event.start)
            let endStr = timeFormatter.string(from: event.end)
            var marker = ""
            if event.start <= now && event.end > now {
                let remaining = max(0, Int(event.end.timeIntervalSince(now) / 60))
                marker = " — IN PROGRESS, \(remaining) min left"
            } else if event.end <= now {
                marker = " — past"
            } else {
                let untilStart = max(0, Int(event.start.timeIntervalSince(now) / 60))
                if untilStart < 60 {
                    marker = " — starting in \(untilStart) min"
                } else if untilStart < 24 * 60 {
                    let h = untilStart / 60
                    let m = untilStart % 60
                    marker = m == 0 ? " — in \(h)h" : " — in \(h)h \(m)m"
                }
            }
            lines.append("- \"\(event.title)\" \(startStr)–\(endStr)\(marker)")
        }
        return lines.joined(separator: "\n")
    }

    /// Activity from the start of the current day, **aggregated by contiguous app session**,
    /// newest-first. Each row is one stretch of being in the same app, with total time, idle
    /// time, distinct subject count (tabs / window titles), and a short list of representative
    /// subjects.
    ///
    /// Why aggregation: a flat per-tab list reads like noise — 80 separate Chrome rows for an
    /// afternoon of research bury the signal "you spent two hours in the browser." Sessions let
    /// the model see "Chrome 2h (12 distinct pages)" and reason about the *shape* of the user's
    /// time, not the individual identities of every tab they touched.
    static func describeRecentUsage(_ activity: ActivityWatcher) -> String {
        let cutoff = Calendar.current.startOfDay(for: Date())
        let dayEvents = activity.events.filter { $0.timestamp >= cutoff }
        guard !dayEvents.isEmpty else { return "" }

        let sessions = aggregateAppSessions(events: dayEvents)
        guard !sessions.isEmpty else { return "" }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        // Newest-first, cap at 40 sessions — far more than a typical day produces.
        let recent = sessions.reversed().prefix(40)
        return recent.map { session -> String in
            let durMin = Int(session.totalSeconds / 60)
            let activeMin = Int(session.activeSeconds / 60)
            let durStr = durMin <= 0 ? "<1m" : "\(durMin)m"
            let activeStr = activeMin < durMin ? " (\(activeMin)m active)" : ""
            var line = "\(timeFormatter.string(from: session.startTime))–\(timeFormatter.string(from: session.endTime)) [\(durStr)\(activeStr)] \(session.appName)"
            if session.distinctSubjects > 1 {
                line += " — \(session.distinctSubjects) distinct \(session.subjectLabel)"
                let preview = Array(session.subjectsInOrder.prefix(4))
                if !preview.isEmpty {
                    line += " (e.g. " + preview.joined(separator: " | ") + ")"
                }
            } else if let only = session.subjectsInOrder.first, !only.isEmpty {
                line += " — \(only)"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Compresses contiguous events of the same app into one session. Switching apps closes the
    /// current session and opens a new one. Bouncing back to a previously-seen app starts a fresh
    /// session — we don't merge non-contiguous time, since "Chrome 9–10am, Slack 10–10:15, Chrome
    /// 10:15–11" is genuinely three different stretches of attention, not "Chrome 1h45m."
    private static func aggregateAppSessions(events: [ActivityWatcher.Event]) -> [AppSession] {
        var sessions: [AppSession] = []
        var current: AppSession?
        for event in events {
            let start = event.timestamp
            let end = event.endTimestamp ?? start
            let wallSeconds = max(0, end.timeIntervalSince(start))
            let idleAtEnd = event.idleSecondsAtCapture ?? 0
            // Active = wall − clamped idle.
            let activeSeconds = max(0, wallSeconds - min(idleAtEnd, wallSeconds))
            // Subject = tab title for browsers, window title otherwise. Empty subjects don't
            // count toward the distinct list (would just inflate counts with blanks).
            let subject: String
            if let tab = event.tabTitle, !tab.isEmpty {
                subject = tab
            } else if let win = event.windowTitle, !win.isEmpty {
                subject = win
            } else {
                subject = ""
            }
            // Browser apps get a "tabs" label; everything else is "windows."
            let isBrowserish = event.tabTitle != nil

            if var session = current, session.bundleID == event.bundleID, session.appName == event.appName {
                session.endTime = end
                session.totalSeconds += wallSeconds
                session.activeSeconds += activeSeconds
                if !subject.isEmpty, !session.subjectSet.contains(subject) {
                    session.subjectSet.insert(subject)
                    session.subjectsInOrder.append(subject)
                }
                current = session
            } else {
                if let prev = current { sessions.append(prev) }
                current = AppSession(
                    appName: event.appName,
                    bundleID: event.bundleID,
                    startTime: start,
                    endTime: end,
                    totalSeconds: wallSeconds,
                    activeSeconds: activeSeconds,
                    subjectSet: subject.isEmpty ? [] : [subject],
                    subjectsInOrder: subject.isEmpty ? [] : [subject],
                    subjectLabel: isBrowserish ? "tabs" : "windows"
                )
            }
        }
        if let last = current { sessions.append(last) }
        return sessions
    }
}

/// One contiguous stretch of being in the same app. `subjectsInOrder` preserves first-seen order
/// for display while `subjectSet` keeps insertion lookups O(1). `distinctSubjects` count is
/// `subjectsInOrder.count`.
private struct AppSession {
    let appName: String
    let bundleID: String?
    var startTime: Date
    var endTime: Date
    var totalSeconds: TimeInterval
    var activeSeconds: TimeInterval
    var subjectSet: Set<String>
    var subjectsInOrder: [String]
    let subjectLabel: String
    var distinctSubjects: Int { subjectsInOrder.count }
}

@MainActor
final class InsightsChatStore: ObservableObject {
    @Published private(set) var messages: [OllamaClient.ChatMessage] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private static let storageFolderName = "NotchNik"
    private static let manifestFileName = "insights_chat.json"
    /// Hard cap on transcript size. Older messages get evicted from the head when we exceed this.
    /// Keeps both the on-disk JSON and the rendered LazyVStack from growing without bound.
    private static let maxStoredMessages = 200

    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Self.storageFolderName, isDirectory: true)
    }

    private var manifestURL: URL {
        storageDirectory.appendingPathComponent(Self.manifestFileName)
    }

    init() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    func clear() {
        messages.removeAll()
        lastError = nil
        saveToDisk()
    }

    /// Appends an assistant message that didn't come from a user prompt — used by the autonomous
    /// commentary engine. Shows up in the transcript like any other reply.
    func appendAssistant(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(OllamaClient.ChatMessage(role: .assistant, content: trimmed))
        trimToCap()
        saveToDisk()
    }

    /// Drops the oldest messages when the transcript exceeds `maxStoredMessages`. Cheap O(n) — n
    /// is small. Called after every mutation that grows the array.
    private func trimToCap() {
        let overage = messages.count - Self.maxStoredMessages
        if overage > 0 {
            messages.removeFirst(overage)
        }
    }

    // MARK: - Persistence

    /// JSON-roundtrips the transcript to `~/Library/Application Support/NotchNik/insights_chat.json`
    /// so a session continues across app launches. Errors are silent — a failed write or corrupt
    /// manifest just means the next launch starts with an empty transcript.
    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        if let stored = try? decoder.decode([OllamaClient.ChatMessage].self, from: data) {
            // If the existing on-disk transcript was saved before the cap existed, trim now so
            // first launch after upgrade doesn't render hundreds of bubbles.
            if stored.count > Self.maxStoredMessages {
                messages = Array(stored.suffix(Self.maxStoredMessages))
                saveToDisk()
            } else {
                messages = stored
            }
        }
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(messages) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Append the user's text and request a completion. Cancels silently if the message is empty
    /// or no model is configured. The personality's system prompt (if any) is injected at the
    /// start of the request payload but NOT into the visible transcript — switching personalities
    /// affects future replies without rewriting history.
    func send(_ text: String, baseURL: String, model: String, personality: InsightsPersonality, observationContext: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !model.isEmpty else {
            lastError = "Pick a model in Settings → Insights first."
            return
        }
        let userMsg = OllamaClient.ChatMessage(role: .user, content: trimmed)
        messages.append(userMsg)
        trimToCap()
        saveToDisk()  // persist the user turn even if the model errors out

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let system = buildInsightsSystemPrompt(personality: personality, observationContext: observationContext)
        var payload: [OllamaClient.ChatMessage] = [
            OllamaClient.ChatMessage(role: .system, content: system)
        ]
        payload.append(contentsOf: messages)

        do {
            let reply = try await OllamaClient.chat(
                baseURL: baseURL,
                model: model,
                history: payload
            )
            messages.append(OllamaClient.ChatMessage(role: .assistant, content: reply.strippingSurroundingQuotes()))
            trimToCap()
            saveToDisk()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct InsightsView: View {
    @EnvironmentObject private var store: InsightsChatStore
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var activity: ActivityWatcher
    @EnvironmentObject private var calendar: CalendarFeedStore
    @EnvironmentObject private var focusEngine: FocusScoreEngine

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if store.messages.isEmpty && store.lastError == nil {
                emptyState
            } else {
                transcript
            }

            Divider()
                .opacity(0.25)

            inputBar
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    // MARK: Empty + transcript

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: PanelSection.insights.iconName)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
            Text("Insights")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(settings.ollamaModel.isEmpty
                 ? "Configure an Ollama model in Settings → Insights, then start a conversation below."
                 : "Connected to \(settings.ollamaModel). Ask anything below.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.messages) { msg in
                        ChatBubble(message: msg)
                            .id(msg.id)
                    }
                    if store.isLoading {
                        ChatThinkingRow()
                            .id("thinking")
                    }
                    if let err = store.lastError {
                        ChatErrorRow(message: err)
                            .id("error")
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: store.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: store.isLoading) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: store.lastError) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear { scrollToBottom(proxy: proxy) }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.18)) {
                if store.lastError != nil {
                    proxy.scrollTo("error", anchor: .bottom)
                } else if store.isLoading {
                    proxy.scrollTo("thinking", anchor: .bottom)
                } else if let last = store.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            FocusScorePill(score: focusEngine.current, isComputing: focusEngine.isComputing) {
                FocusScoreDetailPresenter.shared.toggle(engine: focusEngine, settings: settings)
            }

            TextField("Ask the model…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .foregroundStyle(.white)
                .focused($inputFocused)
                .onSubmit { submit() }
                .disabled(store.isLoading)

            Button(action: submit) {
                Image(systemName: store.isLoading ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? Color.accentColor : Color.white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.top, 8)
    }

    private var canSend: Bool {
        !store.isLoading && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        let observation = InsightsContextBuilder.build(activity: activity, calendar: calendar)
        Task {
            await store.send(
                text,
                baseURL: settings.ollamaURL,
                model: settings.ollamaModel,
                personality: settings.insightsPersonality,
                observationContext: observation.isEmpty ? nil : observation
            )
        }
    }
}

// MARK: - Bubbles

private struct ChatBubble: View {
    let message: OllamaClient.ChatMessage

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var background: Color {
        message.role == .user ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.08)
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: alignment, spacing: 2) {
                HStack(spacing: 6) {
                    if message.role != .user {
                        Text("Assistant")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    if let stamp = message.timestamp {
                        Text(Self.formatTimestamp(stamp))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    if message.role == .user {
                        Text("You")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                bubbleBody
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(background)
                    )
            }
            if message.role != .user { Spacer(minLength: 32) }
        }
    }

    /// Renders the message content. User turns stay as literal `Text` (no surprise interpretation
    /// of accidental markdown in their typing). Assistant turns get parsed as markdown with both
    /// inline (bold/italic/code/links) and block-level (bullet lists, numbered lists, headings)
    /// support — bullets in particular were a request because the model had been emitting `- foo`
    /// lines that rendered as literal hyphens.
    @ViewBuilder
    private var bubbleBody: some View {
        if message.role == .user {
            Text(message.content)
        } else {
            MarkdownText(text: message.content)
        }
    }

    /// Compact stamp: just "h:mm a" for messages from today, "MMM d · h:mm a" for older ones.
    /// Keeps the active conversation uncluttered while still anchoring transcript scrollback.
    private static func formatTimestamp(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return todayFormatter.string(from: date)
        }
        return fullFormatter.string(from: date)
    }
    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · h:mm a"
        return f
    }()
}

/// Renders a string as markdown — paragraphs, bullet lists (`- foo`, `* foo`), and numbered
/// lists (`1. foo`). Inline bold/italic/code/links are parsed via `AttributedString(markdown:)`
/// per line. We don't reach for a full Markdown library because the chat bubble doesn't need
/// blockquotes, code fences, or tables.
private struct MarkdownText: View {
    let text: String

    private struct Line: Identifiable {
        enum Kind { case paragraph, bullet, numbered(Int) }
        let id = UUID()
        let kind: Kind
        let attributed: AttributedString
    }

    private var lines: [Line] {
        // Split on newlines so each list item / paragraph gets its own row. Trailing empty lines
        // are dropped so a stray "\n" at the end of a model reply doesn't create blank rows.
        let raw = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return raw.map { rawLine -> Line in
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // Bullet list: lines starting with "- " or "* "
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let body = String(trimmed.dropFirst(2))
                return Line(kind: .bullet, attributed: parseInline(body))
            }
            // Numbered list: lines starting with "<digits>. " — capture the number for display.
            if let dotIndex = trimmed.firstIndex(of: "."),
               trimmed[..<dotIndex].allSatisfy({ $0.isNumber }),
               trimmed.index(after: dotIndex) < trimmed.endIndex,
               trimmed[trimmed.index(after: dotIndex)] == " ",
               let n = Int(trimmed[..<dotIndex]) {
                let body = String(trimmed[trimmed.index(dotIndex, offsetBy: 2)...])
                return Line(kind: .numbered(n), attributed: parseInline(body))
            }
            return Line(kind: .paragraph, attributed: parseInline(trimmed))
        }
    }

    /// Inline markdown parse with a fallback so a malformed pattern doesn't break rendering.
    private func parseInline(_ raw: String) -> AttributedString {
        if let parsed = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return parsed
        }
        return AttributedString(raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                switch line.kind {
                case .paragraph:
                    Text(line.attributed)
                case .bullet:
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.white.opacity(0.7))
                        Text(line.attributed)
                    }
                case .numbered(let n):
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(n).")
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                        Text(line.attributed)
                    }
                }
            }
        }
    }
}

private struct ChatThinkingRow: View {
    var body: some View {
        // `TimelineView` ticks at the requested cadence and is cleaned up automatically when the
        // view leaves the hierarchy — no Combine subscription to leak across re-renders, which
        // can pile up and contribute to runaway CPU when the parent re-renders frequently.
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            HStack {
                Text("Thinking" + String(repeating: ".", count: dotCount(at: context.date)))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                Spacer()
            }
        }
    }

    private func dotCount(at date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 0.4) % 4
    }
}

// MARK: - Focus score pill + detail

/// Compact button shown at the lower-left of the input bar. Color tracks the score (red→amber→
/// green); clicking opens the detail sheet.
private struct FocusScorePill: View {
    let score: FocusScore?
    let isComputing: Bool
    let action: () -> Void

    /// True when the persisted "current" score covers the user's current hour. If it does not
    /// (e.g., the live tick skipped this hour because active time was below threshold, or the
    /// app was asleep), the pill renders blank. The Now tab can still show the previous
    /// score's content; we just don't pretend the pill represents *right now* when it doesn't.
    private var isCurrentHour: Bool {
        guard let score else { return false }
        let cal = Calendar.current
        let nowHourStart = cal.date(bySettingHour: cal.component(.hour, from: Date()), minute: 0, second: 0, of: Date()) ?? Date()
        // The score's windowEnd is the end of the hour it scored (e.g., 14:00 for the 13:00–14:00
        // hour). If windowEnd >= the current hour's start, the score is fresh enough to display.
        return score.windowEnd >= nowHourStart
    }

    private var displayValue: String {
        guard let score, isCurrentHour else { return "—" }
        return "\(score.value)"
    }

    private var tint: Color {
        guard let score, isCurrentHour else { return Color.white.opacity(0.25) }
        switch score.value {
        case ..<25: return Color.red.opacity(0.75)
        case ..<50: return Color.orange.opacity(0.75)
        case ..<75: return Color.yellow.opacity(0.75)
        default:    return Color.green.opacity(0.75)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 10, weight: .semibold))
                Text(displayValue)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if isComputing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                        .frame(width: 10, height: 10)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(score.map { "Focus score for \(formatTimeframe(start: $0.windowStart, end: $0.windowEnd))" } ?? "Focus score not yet computed")
    }
}

/// Tabbed detail view shown when the pill is clicked. "Now" reproduces the current-hour summary;
/// "Day" charts the selected day's hourly scores and lets the user step backward through history.
/// Future tabs (Month, Insights) will slot in here. Hosted by `FocusScoreDetailPresenter` in its
/// own borderless NSPanel so it doesn't perturb the notch overlay's geometry.
struct FocusScoreDetailView: View {
    let score: FocusScore?
    let onClose: () -> Void

    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var focusEngine: FocusScoreEngine

    @State private var confirmingRecomputeNow = false

    enum Tab: String, CaseIterable, Identifiable {
        case now = "Now"
        case day = "Day"
        case week = "Week"
        case month = "Month"
        case insights = "Insights"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .now
    /// Lifted out of `DaySection` so the Month/Week grids can drill into a specific day by
    /// setting this and switching tabs.
    @State private var selectedDate: Date = Date()
    /// Anchor date for the Week tab. Lifted to enable Month → Week drilldown later.
    @State private var weekAnchorDate: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row — keep the picker on its own row below so segmented sizing can't be
            // crushed by neighboring siblings on `firstTextBaseline` alignment.
            HStack(alignment: .firstTextBaseline) {
                Text("Focus Score")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .now:
                    NowSection(score: score)
                case .day:
                    DaySection(history: focusEngine.history, selectedDate: $selectedDate)
                case .week:
                    WeekSection(history: focusEngine.history, anchorDate: $weekAnchorDate, onPickDay: { date in
                        selectedDate = date
                        tab = .day
                    })
                case .month:
                    MonthSection(history: focusEngine.history, onPickDay: { date in
                        selectedDate = date
                        tab = .day
                    }, onPickWeek: { weekStart in
                        weekAnchorDate = weekStart
                        tab = .week
                    })
                case .insights:
                    InsightsSection(engine: focusEngine, settings: settings, history: focusEngine.history)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Button("Recompute now") {
                    confirmingRecomputeNow = true
                }
                .disabled(focusEngine.isComputing)

                if focusEngine.isBackfilling {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Re-scoring…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 480)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 22, y: 8)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .confirmationDialog(
            "Recompute the current hour's score?",
            isPresented: $confirmingRecomputeNow,
            titleVisibility: .visible
        ) {
            Button("Recompute now") {
                Task { await focusEngine.recomputeNow() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("""
            Recomputes the focus score for the past 60 minutes using the current activity log, \
            scoring rules, and category map. Replaces the current hour's existing entry if \
            there is one. Triggers one model call. Doesn't touch any other hour or the \
            activity log itself.

            Do this when: you just changed something (personality voice, a category, a setting) \
            and want the current hour's score regenerated immediately, before the next automatic \
            hourly tick.
            """)
        }
    }
}

/// "Now" tab content — the existing current-hour card.
private struct NowSection: View {
    let score: FocusScore?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let score {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: CGFloat(score.value) / 100)
                            .stroke(scoreColor(score.value), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(score.value)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 78, height: 78)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatTimeframe(start: score.windowStart, end: score.windowEnd))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(score.commentary)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                Divider()

                if score.topApps.isEmpty {
                    Text("No tracked activity in this window.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Top apps")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(score.topApps, id: \.self) { row in
                            HStack {
                                Text(row.appName)
                                    .font(.system(size: 12))
                                if let cat = row.category, !cat.isEmpty {
                                    Text(cat)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule().fill(Color.secondary.opacity(0.18))
                                        )
                                }
                                Spacer()
                                Text("\(row.minutes) min")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            } else {
                Text("Focus score will appear once enough activity has been logged.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Day" tab content — date navigator + 24-bar chart + per-hour detail.
private struct DaySection: View {
    @ObservedObject var history: FocusHistoryStore
    @EnvironmentObject private var focusEngine: FocusScoreEngine
    @Binding var selectedDate: Date
    @State private var selectedHour: Int? = nil

    private var entries: [FocusScore] {
        history.entries(for: selectedDate)
    }

    private var entriesByHour: [Int: FocusScore] {
        var map: [Int: FocusScore] = [:]
        for entry in entries {
            let h = Calendar.current.component(.hour, from: entry.windowEnd)
            map[h] = entry
        }
        return map
    }

    private var selectedEntry: FocusScore? {
        guard let h = selectedHour else { return nil }
        return entriesByHour[h]
    }

    private var avgScore: Int? {
        guard !entries.isEmpty else { return nil }
        let sum = entries.reduce(0) { $0 + $1.value }
        return Int((Double(sum) / Double(entries.count)).rounded())
    }

    /// Best/worst hour for the day so far. Returns nil when zero entries.
    private var bestEntry: FocusScore? { entries.max { $0.value < $1.value } }
    private var worstEntry: FocusScore? { entries.min { $0.value < $1.value } }

    private static let hourLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dateLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Date navigator
            HStack(spacing: 10) {
                Button { stepDay(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("Previous day")

                Text(Self.dateLabelFormatter.string(from: selectedDate))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 180, alignment: .leading)

                Button { stepDay(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(Calendar.current.isDateInToday(selectedDate))
                .help("Next day")

                if !Calendar.current.isDateInToday(selectedDate) {
                    Button("Today") { selectedDate = Date() }
                        .buttonStyle(.borderless)
                }

                Spacer()

                if let avg = avgScore {
                    Text("Daily avg")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(avg)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(scoreColor(avg))
                }
            }

            // Best/worst hour callouts. Only render when distinct entries exist; with one entry
            // the values would be identical and the row would be visual noise.
            if let best = bestEntry, let worst = worstEntry, best.windowEnd != worst.windowEnd {
                HStack(spacing: 8) {
                    bestWorstHourChip(label: "Best hour", time: best.windowStart, score: best.value, color: .green)
                    bestWorstHourChip(label: "Worst hour", time: worst.windowStart, score: worst.value, color: .red)
                    Spacer()
                }
            }

            DayBarChart(entriesByHour: entriesByHour, selectedHour: $selectedHour)
                .frame(height: 130)

            Divider()

            // Per-hour detail panel. Wrapped in a ScrollView so longer diagnostic readouts
            // (which can exceed the panel's fixed height) remain reachable.
            // - Hour with score → HourDetail.
            // - Hour without score (selected) → HourDiagnosticView (explains why).
            // - No hour selected → prompt to click a bar.
            ScrollView(.vertical, showsIndicators: false) {
                if let entry = selectedEntry {
                    HourDetail(entry: entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let hour = selectedHour {
                    HourDiagnosticView(diagnostic: focusEngine.diagnose(date: selectedDate, hour: hour))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if entries.isEmpty {
                    Text("No focus scores recorded for this day. Click any bar to diagnose what the engine sees for that hour.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    Text("Click a bar to see that hour's commentary or, for empty bars, a diagnostic readout.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { defaultSelectionForCurrentDate() }
        .onChange(of: selectedDate) { _, _ in defaultSelectionForCurrentDate() }
    }

    private func stepDay(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate) else { return }
        // Don't step into the future.
        if Calendar.current.startOfDay(for: next) > Calendar.current.startOfDay(for: Date()) { return }
        selectedDate = next
    }

    /// On date change (or first appear), pre-select the most recent hour with data so the
    /// detail panel isn't empty. Defaults to nil if the day has nothing.
    private func defaultSelectionForCurrentDate() {
        if let last = entries.last {
            selectedHour = Calendar.current.component(.hour, from: last.windowEnd)
        } else {
            selectedHour = nil
        }
    }

    @ViewBuilder
    private func bestWorstHourChip(label: String, time: Date, score: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(Self.hourLabel.string(from: time))
                .font(.system(size: 11, weight: .semibold))
            Text("\(score)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Plain-language readout of why a particular hour has no score, or what the engine sees for
/// it more generally. Shown in place of `HourDetail` when the user selects an empty bar.
private struct HourDiagnosticView: View {
    let diagnostic: FocusScoreEngine.HourDiagnostic

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: diagnostic.willScore ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(diagnostic.willScore ? .green : .orange)
                Text("\(Self.timeFmt.string(from: diagnostic.windowStart))–\(Self.timeFmt.string(from: diagnostic.windowEnd))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(diagnostic.summary)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            HourStatsGrid(diagnostic: diagnostic)
                .padding(.top, 2)

            // Match the scored-hour layout: horizontal scrolling FlowApps row, not a
            // vertical list. Skipped hours and scored hours read the same way.
            if !diagnostic.topApps.isEmpty {
                FlowApps(apps: diagnostic.topApps)
            }
        }
    }
}

/// Shared stats grid used by both `HourDetail` (scored hours) and `HourDiagnosticView`
/// (skipped/empty hours). Surfaces the underlying numbers — active/idle/wall, longest
/// streak, switches, distinct contexts, baseline, presence multiplier, threshold.
private struct HourStatsGrid: View {
    let diagnostic: FocusScoreEngine.HourDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            statRow(label: "Active time",       value: "\(diagnostic.activeMinutes) min", muted: false)
            statRow(label: "Idle time",         value: "\(diagnostic.idleMinutes) min",   muted: false)
            statRow(label: "Wall time",         value: "\(diagnostic.wallMinutes) min",   muted: true)
            statRow(label: "Threshold",         value: "≥ \(diagnostic.thresholdMinActiveMinutes) min active", muted: true)
            statRow(label: "Longest streak",    value: "\(diagnostic.longestStreakMinutes) min", muted: true)
            statRow(label: "Context switches",  value: "\(diagnostic.switches)",          muted: true)
            statRow(label: "Distinct contexts", value: "\(diagnostic.distinctContexts)",  muted: true)
            if diagnostic.willScore {
                statRow(label: "Baseline score", value: "\(diagnostic.baseline)/100", muted: false)
                let multStr = String(format: "%.0f%%", diagnostic.baselinePresenceMultiplier * 100)
                statRow(label: "Presence multiplier", value: multStr, muted: true)
            }
        }
    }

    @ViewBuilder
    private func statRow(label: String, value: String, muted: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(muted ? .tertiary : .secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(muted ? .tertiary : .primary)
        }
    }
}

/// Per-hour detail row shown below the bar chart when a bar is selected. Shows the score +
/// commentary + top apps the user already wrote, plus the same diagnostic stats grid the
/// no-score path renders — so a scored hour and a skipped hour both surface the underlying
/// numbers (active/idle/wall, longest streak, switches, distinct contexts, baseline,
/// presence multiplier, threshold).
private struct HourDetail: View {
    let entry: FocusScore
    @EnvironmentObject private var focusEngine: FocusScoreEngine

    private var diagnostic: FocusScoreEngine.HourDiagnostic {
        focusEngine.diagnose(date: entry.windowStart, hour: Calendar.current.component(.hour, from: entry.windowEnd))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(entry.value)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(scoreColor(entry.value))
                Text(formatTimeframe(start: entry.windowStart, end: entry.windowEnd))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if let idle = entry.idleMinutes, idle > 0 {
                    Text("idle \(idle)m")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                }
                Spacer()
            }

            Text(entry.commentary)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            // Stats grid: parity with the no-score diagnostic view so users always see the
            // underlying numbers, not just the headline score + commentary.
            HourStatsGrid(diagnostic: diagnostic)
                .padding(.top, 2)

            if !entry.topApps.isEmpty {
                FlowApps(apps: entry.topApps)
            }
        }
    }
}

/// Compact horizontal app list for the hour detail. Wraps to a second line when needed.
private struct FlowApps: View {
    let apps: [FocusScore.TopApp]

    var body: some View {
        // Use a simple HStack with explicit ScrollView for wide rows; keeps layout predictable.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(apps, id: \.self) { row in
                    HStack(spacing: 4) {
                        Text(row.appName)
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(row.minutes)m")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let cat = row.category, !cat.isEmpty {
                            Text(cat)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                }
            }
        }
    }
}

/// 24-bar focus chart for one day. Empty hours render as a light track; entries fill from the
/// bottom proportional to score. Bars are tappable when they have data; tooltips show the score
/// and the hour even on empty bars.
private struct DayBarChart: View {
    let entriesByHour: [Int: FocusScore]
    @Binding var selectedHour: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { hour in
                        bar(hour: hour, totalHeight: geo.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? formatHour12(hour) : "")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func bar(hour: Int, totalHeight: CGFloat) -> some View {
        let entry = entriesByHour[hour]
        let isSelected = selectedHour == hour
        let fillHeight: CGFloat = entry.map { max(2, CGFloat($0.value) / 100 * totalHeight) } ?? 0
        // Idle ratio: minutes / 60 of the hour. Capped to [0, 1] in case clock skew or a slow
        // tick produces a slightly-over-an-hour idle reading.
        let idleRatio: CGFloat = entry.flatMap { $0.idleMinutes }.map { min(1, max(0, CGFloat($0) / 60)) } ?? 0
        let idleHeight: CGFloat = idleRatio * totalHeight

        ZStack(alignment: .bottom) {
            // Background track — visible for empty hours so the chart reads as 24 slots, not gaps.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white.opacity(0.05))
            // Idle underlay: a faint gray fill from the bottom proportional to AFK ratio.
            // Shown behind the score fill so the visible "active" portion stands out cleanly.
            if idleHeight > 0 {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.15))
                    .frame(height: idleHeight)
            }
            if let entry, fillHeight > 0 {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(scoreColor(entry.value).opacity(isSelected ? 1.0 : 0.8))
                    .frame(height: fillHeight)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(isSelected ? Color.white.opacity(0.85) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Empty bars are now selectable too — selection of an empty hour shows a
            // diagnostic readout instead of HourDetail. Lets the user investigate "why is
            // there no score for this hour?"
            selectedHour = hour
        }
        .help(barTooltip(hour: hour, entry: entry))
    }

    private func barTooltip(hour: Int, entry: FocusScore?) -> String {
        let label = formatHour12(hour)
        guard let entry else { return "\(label) — no data" }
        let stem = "\(label) — focus \(entry.value)"
        if let idle = entry.idleMinutes, idle > 0 {
            return stem + " (idle \(idle)m)"
        }
        return stem
    }
}

/// "Month" tab content — calendar grid where each cell shows a tiny donut whose color reflects
/// that day's average score. Click a cell with data to drill into the Day tab.
/// "Week" tab — Sunday→Saturday view of daily averages with click-to-drill-into-Day. Idle
/// underlay isn't rendered here; per-day idle would require a roll-up that doesn't yet exist on
/// `FocusScore`. Easy to add later if it becomes useful.
private struct WeekSection: View {
    @ObservedObject var history: FocusHistoryStore
    @Binding var anchorDate: Date
    let onPickDay: (Date) -> Void

    private let calendar = Calendar.current

    private var weekInterval: DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: anchorDate) ?? DateInterval(start: anchorDate, duration: 0)
    }

    private var dailyAvgs: [Date: Int] {
        // Read history.revision implicitly by referencing it inside computed property — keeps
        // this view in sync as new scores land in the current week.
        _ = history.revision
        return history.dailyAverages(forWeekContaining: anchorDate)
    }

    private var weekAvg: Int? {
        let vals = dailyAvgs.values
        guard !vals.isEmpty else { return nil }
        return Int((Double(vals.reduce(0, +)) / Double(vals.count)).rounded())
    }

    /// Best/worst day pair for the week. Returns nil when only one day has data — a single-day
    /// "best vs. worst" is meaningless. Single optional-tuple read keeps the ViewBuilder body
    /// type-checkable without let-let-predicate chains.
    private struct DayStat { let date: Date; let avg: Int }
    private var bestWorstDays: (best: DayStat, worst: DayStat)? {
        guard dailyAvgs.count >= 2,
              let best = dailyAvgs.max(by: { $0.value < $1.value }),
              let worst = dailyAvgs.min(by: { $0.value < $1.value }),
              calendar.startOfDay(for: best.key) != calendar.startOfDay(for: worst.key) else { return nil }
        return (DayStat(date: best.key, avg: best.value), DayStat(date: worst.key, avg: worst.value))
    }

    private static let weekRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    private static let dayChipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private var weekRangeLabel: String {
        let start = weekInterval.start
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return "\(Self.weekRangeFormatter.string(from: start))–\(Self.weekRangeFormatter.string(from: end)), \(calendar.component(.year, from: start))"
    }

    private var isCurrentWeek: Bool {
        guard let nowWeek = calendar.dateInterval(of: .weekOfYear, for: Date()) else { return false }
        return weekInterval.start == nowWeek.start
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Week navigator
            HStack(spacing: 10) {
                Button { stepWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .help("Previous week")
                Text(weekRangeLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 200, alignment: .leading)
                Button { stepWeek(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .disabled(isCurrentWeek)
                    .help("Next week")
                if !isCurrentWeek {
                    Button("This week") { anchorDate = Date() }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if let avg = weekAvg {
                    Text("Weekly avg")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(avg)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(scoreColor(avg))
                }
            }

            // Best / worst day chips. Both clickable to drill into Day tab.
            if let pair = bestWorstDays {
                HStack(spacing: 8) {
                    bestWorstDayChip(label: "Best day", date: pair.best.date, score: pair.best.avg, color: .green)
                    bestWorstDayChip(label: "Worst day", date: pair.worst.date, score: pair.worst.avg, color: .red)
                    Spacer()
                }
            }

            WeekBarChart(weekStart: weekInterval.start, dailyAvgs: dailyAvgs, onTapDay: onPickDay)
                .frame(height: 160)

            Spacer(minLength: 0)
        }
    }

    private func stepWeek(_ delta: Int) {
        guard let next = calendar.date(byAdding: .weekOfYear, value: delta, to: anchorDate) else { return }
        // Don't step into a future week.
        guard let nextInterval = calendar.dateInterval(of: .weekOfYear, for: next),
              let currentInterval = calendar.dateInterval(of: .weekOfYear, for: Date()) else { return }
        if nextInterval.start > currentInterval.start { return }
        anchorDate = next
    }

    private static let dayChipFullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    @ViewBuilder
    private func bestWorstDayChip(label: String, date: Date, score: Int, color: Color) -> some View {
        Button {
            onPickDay(date)
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text(Self.dayChipFullFormatter.string(from: date))
                    .font(.system(size: 11, weight: .semibold))
                Text("\(score)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Jump to this day in the Day tab")
    }
}

/// 7-bar chart for one calendar week. Each bar = daily average score; height is proportional
/// (0–100). Empty days render as faint tracks; future days dimmed and disabled. Bars are
/// clickable to drill into the Day tab for that date.
private struct WeekBarChart: View {
    let weekStart: Date
    let dailyAvgs: [Date: Int]
    let onTapDay: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<7, id: \.self) { offset in
                        bar(offset: offset, totalHeight: geo.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { offset in
                    Text(weekdayLabel(offset: offset))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        // Use a uniform Color on both branches; mixing Color and a hierarchical
                        // ShapeStyle (`.tertiary`) makes the conditional un-typeable.
                        .foregroundStyle(isToday(offset: offset) ? Color.accentColor : Color.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func bar(offset: Int, totalHeight: CGFloat) -> some View {
        let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
        let dayKey = calendar.startOfDay(for: day)
        let avg = dailyAvgs[dayKey]
        let isFuture = dayKey > Date()
        let fillHeight: CGFloat = avg.map { max(2, CGFloat($0) / 100 * totalHeight) } ?? 0

        Button {
            if avg != nil { onTapDay(day) }
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(isFuture ? 0.02 : 0.05))
                if let avg, fillHeight > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(scoreColor(avg).opacity(0.85))
                        .frame(height: fillHeight)
                    Text("\(avg)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(avg == nil || isFuture)
        .help(tooltip(day: day, avg: avg))
    }

    private func weekdayLabel(offset: Int) -> String {
        let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return fmt.string(from: day)
    }

    private func isToday(offset: Int) -> Bool {
        let day = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
        return calendar.isDateInToday(day)
    }

    private func tooltip(day: Date, avg: Int?) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE, MMM d"
        let stem = fmt.string(from: day)
        if let avg { return "\(stem) — daily avg \(avg)" }
        return "\(stem) — no data"
    }
}

private struct MonthSection: View {
    @ObservedObject var history: FocusHistoryStore
    let onPickDay: (Date) -> Void
    /// Callback fired when the user clicks a best/worst week chip. Pass back the week's start
    /// (Sunday) so the Week tab can anchor on it.
    let onPickWeek: (Date) -> Void

    @State private var anchorDate: Date = Date()

    private let calendar = Calendar.current
    private static let monthLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    /// Cells the grid renders. nil = leading/trailing pad (so the first day lands on its weekday
    /// column). Computed once per anchor change.
    private var gridCells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: anchorDate) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)  // 1...7, Sun=1
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        var cursor = interval.start
        while cursor < interval.end {
            cells.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        // Pad to a full 6-row grid so the layout doesn't shift between 5- and 6-row months.
        while cells.count < 42 {
            cells.append(nil)
        }
        return cells
    }

    private var monthEntries: [FocusScore] {
        history.entries(forMonthContaining: anchorDate)
    }

    /// Daily averages keyed by start-of-day Date. Pre-bucketed once per anchor change so each
    /// cell doesn't re-scan the month's entries on render.
    private var averagesByDay: [Date: Int] {
        var byDay: [Date: [Int]] = [:]
        for entry in monthEntries {
            let day = calendar.startOfDay(for: entry.windowEnd)
            byDay[day, default: []].append(entry.value)
        }
        var avgs: [Date: Int] = [:]
        for (day, values) in byDay where !values.isEmpty {
            avgs[day] = Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        }
        return avgs
    }

    private var weekdaySymbols: [String] {
        // Match the user's first-day-of-week. `veryShortStandaloneWeekdaySymbols` is "S M T W T F S".
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    var body: some View {
        let avgs = averagesByDay
        VStack(alignment: .leading, spacing: 12) {
            // Month navigator
            HStack(spacing: 10) {
                Button { stepMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .help("Previous month")
                Text(Self.monthLabel.string(from: anchorDate))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 140, alignment: .leading)
                Button { stepMonth(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .disabled(isCurrentMonth)
                    .help("Next month")
                if !isCurrentMonth {
                    Button("This month") { anchorDate = Date() }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if !avgs.isEmpty {
                    let monthlyAvg = Int((Double(avgs.values.reduce(0, +)) / Double(avgs.count)).rounded())
                    Text("Monthly avg")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(monthlyAvg)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(scoreColor(monthlyAvg))
                }
            }

            // Best / worst week of the month — clickable to jump into the Week tab. The
            // weekly bucketing lives on `bestWorstWeeks` so the ViewBuilder body sees a simple
            // optional-tuple, not a chain of let-bindings the type checker dislikes.
            if let pair = bestWorstWeeks {
                HStack(spacing: 8) {
                    bestWorstWeekChip(label: "Best week", weekStart: pair.best.start, score: pair.best.avg, color: .green)
                    bestWorstWeekChip(label: "Worst week", weekStart: pair.worst.start, score: pair.worst.avg, color: .red)
                    Spacer()
                }
            }

            // Weekday header row
            HStack(spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { sym in
                    Text(sym)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            // 6 rows of 7 cells. Fixed-size grid so the layout is stable across months.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(gridCells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        DayCell(
                            date: date,
                            average: avgs[calendar.startOfDay(for: date)],
                            isToday: calendar.isDateInToday(date),
                            isFuture: date > Date(),
                            onTap: {
                                if avgs[calendar.startOfDay(for: date)] != nil {
                                    onPickDay(date)
                                }
                            }
                        )
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var isCurrentMonth: Bool {
        calendar.component(.month, from: anchorDate) == calendar.component(.month, from: Date())
            && calendar.component(.year, from: anchorDate) == calendar.component(.year, from: Date())
    }

    private func stepMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: anchorDate) else { return }
        // Don't step into a future month.
        if next > Date(), !calendar.isDate(next, equalTo: Date(), toGranularity: .month) {
            return
        }
        anchorDate = next
    }

    /// Bucket the per-day averages into per-week averages keyed by week-start (Sunday). Used to
    /// surface the month's best/worst week chip without re-loading entries.
    private func weeklyAverages(in dailyAvgs: [Date: Int]) -> [Date: Int] {
        var byWeek: [Date: [Int]] = [:]
        for (day, avg) in dailyAvgs {
            guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: day) else { continue }
            byWeek[weekInterval.start, default: []].append(avg)
        }
        return byWeek.mapValues { vals in
            Int((Double(vals.reduce(0, +)) / Double(vals.count)).rounded())
        }
    }

    /// Best/worst week pair for the visible month. Returns nil when fewer than two weeks of
    /// data exist (i.e., one week or none — no meaningful comparison). The ViewBuilder body
    /// reads this as a single optional, which the type checker handles cleanly.
    private struct WeekStat { let start: Date; let avg: Int }
    private var bestWorstWeeks: (best: WeekStat, worst: WeekStat)? {
        let weeklyAvgs = weeklyAverages(in: averagesByDay)
        guard weeklyAvgs.count >= 2,
              let best = weeklyAvgs.max(by: { $0.value < $1.value }),
              let worst = weeklyAvgs.min(by: { $0.value < $1.value }),
              best.key != worst.key else { return nil }
        return (WeekStat(start: best.key, avg: best.value), WeekStat(start: worst.key, avg: worst.value))
    }

    private static let weekChipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    @ViewBuilder
    private func bestWorstWeekChip(label: String, weekStart: Date, score: Int, color: Color) -> some View {
        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let text = "\(Self.weekChipFormatter.string(from: weekStart))–\(Self.weekChipFormatter.string(from: weekEnd))"
        Button {
            onPickWeek(weekStart)
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                Text("\(score)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Jump to this week in the Week tab")
    }
}

/// One cell in the month grid: a small donut whose stroke is colored by the day's average score,
/// with the day number centered. Days without data render as a faint outline. Today gets a thin
/// accent ring.
private struct DayCell: View {
    let date: Date
    let average: Int?
    let isToday: Bool
    let isFuture: Bool
    let onTap: () -> Void

    private var dayNumber: String {
        "\(Calendar.current.component(.day, from: date))"
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(average == nil ? 0.08 : 0.15), lineWidth: 2)
                if let avg = average {
                    Circle()
                        .trim(from: 0, to: CGFloat(avg) / 100)
                        .stroke(scoreColor(avg), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(dayNumber)
                    .font(.system(size: 11, weight: isToday ? .bold : .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isFuture ? Color.white.opacity(0.25)
                                     : (average == nil ? Color.white.opacity(0.5) : .white))
                if isToday {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                        .padding(-2)
                }
            }
            .frame(height: 36)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(average == nil || isFuture)
        .help(tooltip)
    }

    private var tooltip: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        let prefix = formatter.string(from: date)
        if let avg = average {
            return "\(prefix) — daily avg \(avg)"
        }
        return "\(prefix) — no data"
    }
}

/// "Insights" tab content — pick a range, see aggregated stats, and (optionally) ask the AI to
/// summarize. The AI summary is cached on the engine keyed by (range, personality) so flipping
/// tabs doesn't re-spend tokens; flipping personality forces a fresh generation.
private struct InsightsSection: View {
    @ObservedObject var engine: FocusScoreEngine
    @ObservedObject var settings: AppSettingsStore
    /// Observed separately from `engine` because the history store is a child of the engine and
    /// changes (new scores landing) emit on its own `objectWillChange`, not the engine's.
    @ObservedObject var history: FocusHistoryStore

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today"
        case yesterday = "Yesterday"
        case thisWeek = "This week"
        case lastWeek = "Last week"
        case thisMonth = "This month"
        case lastMonth = "Last month"
        var id: String { rawValue }

        /// Returns the absolute interval for this preset, anchored to "now."
        func interval(now: Date = Date()) -> DateInterval {
            let cal = Calendar.current
            switch self {
            case .today:
                return DateInterval(start: cal.startOfDay(for: now), end: now)
            case .yesterday:
                let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
                let end = cal.startOfDay(for: now)
                return DateInterval(start: start, end: end)
            case .thisWeek:
                let weekInterval = cal.dateInterval(of: .weekOfYear, for: now)!
                return DateInterval(start: weekInterval.start, end: now)
            case .lastWeek:
                let lastWeekAnchor = cal.date(byAdding: .weekOfYear, value: -1, to: now)!
                return cal.dateInterval(of: .weekOfYear, for: lastWeekAnchor)!
            case .thisMonth:
                let monthInterval = cal.dateInterval(of: .month, for: now)!
                return DateInterval(start: monthInterval.start, end: now)
            case .lastMonth:
                let lastMonthAnchor = cal.date(byAdding: .month, value: -1, to: now)!
                return cal.dateInterval(of: .month, for: lastMonthAnchor)!
            }
        }
    }

    @State private var range: Range = .thisWeek

    private var interval: DateInterval { range.interval() }
    private var stats: RangeStats? {
        // Reading `history.revision` here keeps the computed property dependent on the @Published
        // revision counter, so SwiftUI invalidates and re-runs `stats` after each record.
        _ = history.revision
        return history.stats(in: interval)
    }

    private var cacheKey: String {
        // Mirrors `FocusScoreEngine.rangeKey` shape just enough for the binding's identity. We
        // don't need it to actually match the engine's internal key — that's used only inside
        // the engine.
        "\(range.rawValue)|\(settings.insightsPersonality.rawValue)"
    }

    private var cachedSummary: String? {
        engine.cachedInsight(rangeLabel: range.rawValue, range: interval)
    }

    private var isGenerating: Bool {
        // The engine sets `generatingInsightKey` while a call is in flight. We can't read its
        // private key composer, so we just check whether something is generating AND whether we
        // don't already have a cached entry — close enough for the spinner state.
        engine.generatingInsightKey != nil && cachedSummary == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $range) {
                ForEach(Range.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let stats {
                        StatsCard(stats: stats)
                        SummaryCard(
                            summary: cachedSummary,
                            isGenerating: isGenerating,
                            modelConfigured: !settings.ollamaModel.isEmpty,
                            onGenerate: {
                                Task {
                                    await engine.generateRangeInsight(rangeLabel: range.rawValue, stats: stats)
                                }
                            },
                            onRefresh: {
                                engine.invalidateInsight(rangeLabel: range.rawValue, range: interval)
                                Task {
                                    await engine.generateRangeInsight(rangeLabel: range.rawValue, stats: stats)
                                }
                            }
                        )
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("No focus scores recorded for this range yet.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
                    }
                }
            }
        }
        .id(cacheKey)   // resetting the ScrollView when range/personality changes
    }
}

/// Aggregated stats panel — facts only, no AI text. Always visible above the AI summary so the
/// user has the numbers even if they never ask for an interpretation.
private struct StatsCard: View {
    let stats: RangeStats

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Average + active/idle headline
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: CGFloat(stats.averageScore) / 100)
                        .stroke(scoreColor(stats.averageScore), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(stats.averageScore)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Average focus")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(stats.dayCount) day\(stats.dayCount == 1 ? "" : "s") · \(stats.entryCount) hourly score\(stats.entryCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Label("\(formatMinutes(stats.totalActiveMinutes)) active", systemImage: "bolt.fill")
                            .foregroundStyle(.green)
                        Label("\(formatMinutes(stats.totalIdleMinutes)) idle", systemImage: "moon.fill")
                            .foregroundStyle(.orange.opacity(0.85))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.top, 2)
                }
                Spacer()
            }

            // Best / worst sub-unit chips. Granularity comes from `stats.granularity` so the
            // label adapts: "best hour" for a single day, "best day" for a week, "best week" for
            // a month. Keeps the UI honest about what's actually being compared.
            if stats.bestUnit != nil || stats.worstUnit != nil {
                HStack(spacing: 8) {
                    if let best = stats.bestUnit {
                        bestWorstPill(label: "Best \(stats.granularity.label)", text: best.label, avg: best.avg, color: .green)
                    }
                    if let worst = stats.worstUnit {
                        bestWorstPill(label: "Worst \(stats.granularity.label)", text: worst.label, avg: worst.avg, color: .red)
                    }
                    Spacer()
                }
            }

            // Peak / sleep / idle / empty hour callouts.
            if !stats.peakHours.isEmpty || !stats.sleepHours.isEmpty || !stats.mostlyIdleHours.isEmpty || !stats.emptyHours.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !stats.peakHours.isEmpty {
                        hourBlock(title: "Peak hours", hours: stats.peakHours, color: .green)
                    }
                    if !stats.sleepHours.isEmpty {
                        hourBlock(title: "Trough hours", hours: stats.sleepHours, color: .red)
                    }
                    if !stats.mostlyIdleHours.isEmpty {
                        hourBlock(title: "Mostly idle", hours: stats.mostlyIdleHours, color: .orange)
                    }
                    if !stats.emptyHours.isEmpty {
                        hourBlock(title: "No activity", hours: stats.emptyHours, color: .gray)
                    }
                }
            }

            // Top categories
            if !stats.topCategories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top categories")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        ForEach(stats.topCategories, id: \.name) { cat in
                            HStack(spacing: 4) {
                                Text(cat.name)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(formatMinutes(cat.minutes))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func hourBlock(title: String, hours: [Int], color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .leading)
            Text(hours.map(formatHour12).joined(separator: ", "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer()
        }
    }

    @ViewBuilder
    private func bestWorstPill(label: String, text: String, avg: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
            Text("\(avg)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func formatMinutes(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

/// AI summary card. Shows the cached summary if any; otherwise a "Generate" button. Refresh
/// invalidates the cache and re-asks. Disabled when no model is configured.
private struct SummaryCard: View {
    let summary: String?
    let isGenerating: Bool
    let modelConfigured: Bool
    let onGenerate: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("AI insight", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if summary != nil {
                    Button {
                        onRefresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .disabled(isGenerating || !modelConfigured)
                }
            }

            if !modelConfigured {
                Text("Configure an Ollama model in Settings → Insights to generate summaries.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking the model…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if let summary {
                Text(summary)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                HStack {
                    Button(action: onGenerate) {
                        Label("Generate insight", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
    }
}

/// Shared score-color ramp. Used by both the Now circle and the Day bars/avg readout.
/// Four-band score color ramp shared by every score visualization. Tighter at the bottom and
/// top so a 24 reads as clearly bad and a 75 reads as clearly good, with two intermediate
/// bands for the "okay" / "decent" middle ground.
private func scoreColor(_ value: Int) -> Color {
    switch value {
    case ..<25: return .red
    case ..<50: return .orange
    case ..<75: return .yellow
    default:    return .green
    }
}

/// Shared by the pill tooltip and the detail card.
private func formatTimeframe(start: Date, end: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return "\(formatter.string(from: start))–\(formatter.string(from: end))"
}

// MARK: - Standalone presenter window

/// Presents the focus-score detail card in its own borderless `NSPanel`, the same way the
/// clipboard's QuickLook preview gets its own window. This keeps the notch overlay's geometry
/// completely untouched — no sheet reshaping, no overlay-layout interference. The panel is
/// sized to fit the card (480×400 with shadow padding) and centered on the active screen.
@MainActor
final class FocusScoreDetailPresenter: NSObject, NSWindowDelegate {
    @MainActor static let shared = FocusScoreDetailPresenter()

    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(engine: FocusScoreEngine, settings: AppSettingsStore) {
        if panel?.isVisible == true {
            close()
        } else {
            // Background passes that prep what the user is about to see. None of these block
            // the panel from appearing — it opens immediately, contents fill in async.
            Task { @MainActor in
                // 1. Recompute the current hour. Catches the common case where the user
                //    woke from sleep and the hourly Timer hasn't fired yet, so the pill is
                //    stale. Cheap (one model call) but eliminates the "score is hours old"
                //    surprise when opening after a long break.
                await engine.recomputeNow()
                // 2. Backfill any hours the activity log covers but never got scored —
                //    typically the result of system sleep suspending the engine's timer.
                engine.backfillMissingHours()
                // 3. AI guess at categories for any uncategorized apps/domains.
                let applied = await engine.aiCategorizeUncategorized(daysBack: 14)
                // 4. Refresh today+yesterday's scores so they reflect any new categories
                //    and the latest rules. The applied count from step 3 doesn't change
                //    behavior here — we always run the refresh.
                _ = applied
                engine.autoRefreshOutdatedScores(daysBack: 2)
            }
            present(engine: engine, settings: settings)
        }
    }

    func present(engine: FocusScoreEngine, settings: AppSettingsStore) {
        // Tear down any prior instance so the SwiftUI host always sees fresh observed objects.
        close()

        let view = FocusScoreDetailView(score: engine.current, onClose: { [weak self] in
            self?.close()
        }, settings: settings, focusEngine: engine)
            // Inject the engine as an environment object too — DaySection (and any descendant)
            // reads it via `@EnvironmentObject` for the diagnostic readout.
            .environmentObject(engine)
            .environmentObject(settings)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 480)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false   // the SwiftUI card draws its own shadow
        panel.contentView = hosting
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = true

        // Center on the screen that hosts the notch overlay.
        if let screen = NSScreen.main {
            let frame = panel.frame
            let x = screen.frame.midX - frame.width / 2
            let y = screen.frame.midY - frame.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ChatErrorRow: View {
    let message: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}
