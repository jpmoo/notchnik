//
//  FocusScoreEngine.swift
//  notch
//
//  Hourly "focus score" computation. Each hour we look at the prior hour's activity events,
//  derive a deterministic baseline from streak length / context-switch rate / app diversity,
//  then ask the configured Ollama model to massage that into a 0-100 score plus a one-line
//  commentary in the user's chosen personality voice.
//
//  The engine also drives conversational app categorization: when an unrecognized bundle ID
//  shows up with significant time in a window, the engine posts a personality-voiced question
//  into the Insights chat ("hey, what bucket should I file Linear under?"). The user replies
//  in the same chat; on the next user turn the engine asks the model to extract a category
//  from the reply and stores it on `AppSettingsStore.appCategories`.
//

import Combine
import Foundation

/// Snapshot of one hour-long focus measurement. Persisted so the pill survives launches.
struct FocusScore: Codable, Equatable {
    var value: Int             // 0...100
    var windowStart: Date
    var windowEnd: Date
    var commentary: String     // AI-generated 1-2 line summary in personality voice
    var topApps: [TopApp]      // sorted desc by minutes; cap 6
    /// Estimated AFK minutes inside this window. Optional so older persisted entries decode
    /// cleanly; UI treats nil as "unknown — don't render the idle underlay."
    var idleMinutes: Int? = nil
    /// Version of the scoring rules that produced this entry. Bumped whenever we change what
    /// counts (loginwindow filter, idle subtraction, threshold, etc.) — entries with a stamp
    /// older than `FocusScoreEngine.currentScoringVersion` get auto-recomputed at launch.
    /// Optional for back-compat with pre-versioning persisted entries (treated as version 0).
    var scoringVersion: Int? = nil
    /// Snapshot of `AppSettingsStore.appCategoriesRevision` at scoring time. The auto-refresh
    /// path treats a mismatch as "this entry was scored against an older category map" and
    /// re-scores it. Lets newly-added category mappings retroactively improve old hours.
    var categoriesRevision: Int? = nil

    struct TopApp: Codable, Equatable, Hashable {
        let appName: String
        let bundleID: String?
        let minutes: Int
        /// Resolved from `settings.appCategories` at compute time. Nil = uncategorized.
        let category: String?
    }
}

@MainActor
final class FocusScoreEngine: ObservableObject {
    @Published private(set) var current: FocusScore?
    @Published private(set) var isComputing: Bool = false
    /// In-memory cache of AI-generated range summaries, keyed by `rangeKey + personality`. Lives
    /// only for the session — re-launching the app drops the cache and the user can re-generate
    /// if they care. Avoids spending tokens on a tab switch.
    @Published private(set) var rangeInsights: [String: String] = [:]
    /// While a range insight is generating, this holds the key being computed. UI uses it to show
    /// a spinner on just that tab/range without globally locking.
    @Published private(set) var generatingInsightKey: String?
    /// What's currently waiting on a categorization reply from the user. The engine asks about
    /// either an app (bundle ID) or a domain (host); on the next user turn it parses the
    /// response and stores via the matching settings setter.
    enum PendingCategorization: Equatable {
        case app(bundleID: String, displayName: String)
        case domain(host: String)

        var displayName: String {
            switch self {
            case .app(_, let name): return name
            case .domain(let host): return host
            }
        }
    }
    @Published private(set) var pendingCategorization: PendingCategorization?

    private weak var chat: InsightsChatStore?
    private weak var activity: ActivityWatcher?
    private weak var calendar: CalendarFeedStore?
    private weak var settings: AppSettingsStore?
    /// Persistent journal of every successful score. Strong reference because no one else owns it.
    let history: FocusHistoryStore

    /// Hourly recompute. Each tick examines the last `windowDuration` of activity.
    private let tickInterval: TimeInterval = 60 * 60
    private let windowDuration: TimeInterval = 60 * 60
    /// Bump whenever scoring rules change in a way that should invalidate older entries
    /// (loginwindow filtering, idle accounting, the 10-min threshold, the presence-multiplier
    /// baseline, calendar-as-primary-context prompt, host/app-level streaks, etc.). Entries
    /// persisted with a lower stamp get auto-recomputed at launch by `autoRefreshOutdatedScores`.
    static let currentScoringVersion: Int = 8
    /// Apps with at least this much time in the window are eligible to be queried for a category.
    private let categorizationMinSeconds: TimeInterval = 5 * 60
    /// Minimum ACTIVE time (idle subtracted) required for an hour to be scored. Switching from
    /// wall-clock to active-only matters: an hour with 2 min of typing and 55 min of an
    /// unlocked-but-AFK screen previously cleared a wall-clock gate but produced a wildly
    /// inflated score. Now the gate matches the metric — only hours with meaningful actual
    /// engagement get scored at all.
    private let minScoredActiveSeconds: TimeInterval = 10 * 60

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Index of the last user message we processed. Lets us spot new user turns without
    /// re-parsing the whole transcript on every chat-store change notification.
    private var lastProcessedUserMessageCount: Int = 0

    private static let storageFolderName = "NotchNik"
    private static let manifestFileName = "focus_score.json"

    private var manifestURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Self.storageFolderName, isDirectory: true)
            .appendingPathComponent(Self.manifestFileName)
    }

    init(chat: InsightsChatStore, activity: ActivityWatcher, calendar: CalendarFeedStore, settings: AppSettingsStore, history: FocusHistoryStore? = nil) {
        self.chat = chat
        self.activity = activity
        self.calendar = calendar
        self.settings = settings
        // Constructed inside the (MainActor-isolated) init so we don't trigger Swift 6's
        // "default argument evaluates in nonisolated context" diagnostic.
        self.history = history ?? FocusHistoryStore()
        loadFromDisk()
        // Initialize the chat-watermark to current count so we don't treat existing user turns
        // (loaded from disk) as fresh categorization replies.
        lastProcessedUserMessageCount = chat.messages.filter { $0.role == .user }.count
        startTimer()

        // Watch chat for new user turns to handle pending categorization replies.
        chat.$messages
            .sink { [weak self] msgs in
                Task { @MainActor in self?.handleChatMessagesChanged(msgs) }
            }
            .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Timer

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.recomputeNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // If we have no current score, or the last one is stale (older than a tick), kick off
        // a compute now so the UI has something to show right after launch.
        let stale = current.map { Date().timeIntervalSince($0.windowEnd) > tickInterval } ?? true
        if stale {
            Task { @MainActor in
                await self.recomputeNow()
                // After the live compute, fill in any historic hours that have activity but
                // never got a score (machine was asleep when the timer would have fired, app
                // was quit, etc.).
                self.backfillMissingHours()
            }
        } else {
            Task { @MainActor in self.backfillMissingHours() }
        }
        // `autoRefreshOutdatedScores` is NOT called on launch — NotchNik is meant to stay
        // running, so launch happens rarely and a startup refresh would either rarely fire
        // (most users) or do nothing (always-running users). Instead it's triggered when the
        // user opens the focus-score panel; see `FocusScoreDetailPresenter.toggle`.
    }

    // MARK: - Recompute

    /// Scores both the just-completed clock hour AND the in-progress hour. The completed-hour
    /// entry is final; the in-progress entry is a partial-window score that gets overwritten
    /// each time recompute fires (and finalized into a complete-hour entry when the next clock
    /// hour rolls around). Backfill, categorization, and the cached-insight invalidation run
    /// once after both writes.
    func recomputeNow() async {
        guard let activity, let settings else { return }
        guard !isComputing else { return }
        isComputing = true
        defer { isComputing = false }

        let cal = Calendar.current
        let now = Date()
        guard let currentHourStart = cal.date(bySettingHour: cal.component(.hour, from: now), minute: 0, second: 0, of: now),
              let prevHourStart = cal.date(byAdding: .hour, value: -1, to: currentHourStart) else { return }

        // Score the just-completed clock hour first. Re-scoring the same hour on subsequent
        // calls is fine — record() last-write-wins keys by windowStart hour.
        await scoreWindow(start: prevHourStart, end: currentHourStart, settings: settings, activity: activity)

        // Then the in-progress hour, if there's anything to score yet. The window grows as
        // the hour proceeds; each recompute yields a fresher partial score.
        if now > currentHourStart {
            await scoreWindow(start: currentHourStart, end: now, settings: settings, activity: activity)
        }

        // Now sync `current` once, after both windows have been written. Pulling from the
        // persisted history's mostRecentEntry guarantees we land on the in-progress entry
        // (which has the later windowEnd) when one was eligible — and gracefully falls back
        // to the just-completed entry when in-progress was below threshold.
        refreshCurrentFromHistory()

        backfillMissingHours()
        rangeInsights.removeAll()
    }

    /// Builds + persists a focus score for an arbitrary window. Same 10-min active-time
    /// threshold for both completed and in-progress hours — keeps the bar for "meaningful
    /// enough to score" consistent so the pill, Day chart, and AI commentary all agree on
    /// what counts. The pill stays blank until 10 min of activity has accrued in the new
    /// hour, then updates each recompute as the hour fills in.
    private func scoreWindow(start windowStart: Date, end windowEnd: Date, settings: AppSettingsStore, activity: ActivityWatcher) async {
        let summary = WindowSummary.build(events: activity.events, start: windowStart, end: windowEnd, settings: settings, calendarEvents: calendar?.events ?? [])
        guard summary.totalSeconds >= minScoredActiveSeconds else { return }

        let baseline = baselineScore(from: summary)
        var finalScore = baseline
        var commentary = defaultCommentary(for: summary, score: baseline)

        let calendarContext = calendar.map { CalendarSummaryFormatter.describe(events: $0.events, windowStart: windowStart, windowEnd: windowEnd) } ?? ""

        if !settings.ollamaModel.isEmpty {
            if let modelResult = await askModelForScore(summary: summary, baseline: baseline, calendarContext: calendarContext, settings: settings) {
                finalScore = modelResult.score
                commentary = modelResult.commentary
            }
        }

        let score = FocusScore(
            value: finalScore,
            windowStart: windowStart,
            windowEnd: windowEnd,
            commentary: commentary,
            topApps: summary.topApps(in: settings),
            idleMinutes: Int(summary.idleSeconds / 60),
            scoringVersion: Self.currentScoringVersion,
            categoriesRevision: settings.appCategoriesRevision
        )
        // Persist the score to history but DON'T touch `current` here. recomputeNow scores
        // two windows (completed + in-progress) back-to-back; if each scoreWindow updated
        // `current` mid-flight, the UI would briefly flash the completed-hour value before
        // settling on the in-progress one. recomputeNow itself sets `current` once at the
        // end via refreshCurrentFromHistory() so observers see exactly one transition.
        history.record(score)

        // Categorization opportunity (asks once per recompute pass; the function self-throttles
        // when there's already a pending question).
        await maybeAskAboutUncategorizedApp(summary: summary, settings: settings)
    }

    // MARK: - Baseline scoring

    /// Cheap, deterministic score from streak/switch/diversity stats, multiplied by a presence
    /// factor so idle-heavy hours can't score as high as fully-engaged ones. Range 0-100. The
    /// model usually nudges this; if Ollama is unavailable we ship the baseline as-is.
    ///
    /// Why presence is needed: streakFraction divides longest streak by ACTIVE total, so a
    /// 2-min uninterrupted streak inside a 2-min active window calculates as "100% deep
    /// focus." Without correcting for the wall-clock context (60 min total, 58 min idle), an
    /// almost-AFK hour scored a perfect 100. The presence factor scales the score down for
    /// hours where the user was barely there.
    private func baselineScore(from summary: WindowSummary) -> Int {
        guard summary.totalSeconds > 0 else { return 0 }
        let streakFraction = min(1.0, summary.longestStreakSeconds / max(60, summary.totalSeconds))
        let switchesPerMin = Double(summary.switches) / max(1, summary.totalSeconds / 60)
        let switchPenalty = min(1.0, switchesPerMin / 6.0)
        let diversityPenalty = min(1.0, max(0, Double(summary.distinctContexts - 2)) / 6.0)

        let depthScore = 0.6 * streakFraction + 0.4 * (1 - 0.6 * switchPenalty - 0.4 * diversityPenalty)

        // Presence multiplier: a soft ramp. Below 50% active vs. the FULL WALL-CLOCK window
        // (NOT the sum of captured event durations — those two diverge when the user walked
        // away and no events were logged), the score is dragged down. At 0% presence the
        // multiplier bottoms out at 0.4 (not 0 — the AI nudge can rescue genuinely meeting-
        // occupied hours from this floor when calendar context warrants).
        //
        // Earlier the denominator was `totalSeconds + idleSeconds`, which made a user who
        // was at the machine 12 min then walked away for 48 min look like 100% present —
        // because the 48-min absence didn't appear in any event so it didn't accrue to wall
        // time. Honest fix is to compare against the actual window length.
        let activityRatio = summary.totalSeconds / max(60, summary.windowSeconds)
        let presenceMultiplier: Double
        if activityRatio >= 0.5 {
            presenceMultiplier = 1.0
        } else {
            presenceMultiplier = 0.4 + 0.6 * (activityRatio / 0.5)
        }

        let raw = depthScore * presenceMultiplier
        return Int((max(0, min(1, raw)) * 100).rounded())
    }

    private func defaultCommentary(for summary: WindowSummary, score: Int) -> String {
        if summary.totalSeconds < 60 {
            return "Not much logged in the last hour."
        }
        let top = summary.appTotals.first
        if let top {
            let mins = Int(top.seconds / 60)
            return "Mostly \(top.appName) (\(mins) min) with \(summary.switches) context switches."
        }
        return "\(summary.switches) switches across \(summary.distinctContexts) contexts."
    }

    // MARK: - Ollama refinement

    private struct ModelResult { let score: Int; let commentary: String }

    private func askModelForScore(summary: WindowSummary, baseline: Int, calendarContext: String, settings: AppSettingsStore) async -> ModelResult? {
        // Use the post-substitution top-entries list so browser time appears as per-domain
        // rows (gmail.com, theonion.com, etc.) instead of one undifferentiated Chrome bucket.
        // Each row already has its category resolved (host → app fallback → uncategorized).
        let appsBlock = summary.topApps(in: settings).map { row -> String in
            let cat = row.category ?? "uncategorized"
            return "- \(row.appName) (\(row.minutes) min, \(cat))"
        }.joined(separator: "\n")

        let activeMin = Int(summary.totalSeconds / 60)
        let nonCountingMin = Int(summary.nonCountingActiveSeconds / 60)
        let idleMin = Int(summary.idleSeconds / 60)
        let userPrompt = """
        Compute a focus score for the last hour of the user's desktop activity.

        Stats:
        - Longest unbroken active streak on one app or website: \(Int(summary.longestStreakSeconds / 60)) min
        - Total context switches: \(summary.switches)
        - Distinct contexts (app+window+tab): \(summary.distinctContexts)
        - Active time (idle subtracted, counting categories only): \(activeMin) min
        - Active time on NON-counting categories (social/entertainment/games, by user setting): \(nonCountingMin) min
        - Idle time (AFK — no input): \(idleMin) min
        - Heuristic baseline score (0-100): \(baseline)

        Top apps used:
        \(appsBlock.isEmpty ? "(none)" : appsBlock)

        Calendar during this window:
        \(calendarContext.isEmpty ? "(no events on calendar)" : calendarContext)

        Calendar takes priority over app categories when interpreting this hour. When a calendar \
        event is IN PROGRESS during this window, the user's activity is most likely in service of \
        that event — whatever app is frontmost (Slides, Zoom, browser, Slack, Notes, IDE) is being \
        used to participate in, run, or take notes during the meeting. Score the hour as engaged \
        work in that case, regardless of whether the apps themselves are categorized as productive. \
        The only time to override this is when dominant apps are clearly off-task in a way that \
        wouldn't plausibly serve the meeting (e.g., heavy time on social/entertainment with no \
        meeting connection).

        Important: the deterministic baseline ALREADY credits idle minutes inside a meeting block \
        as active. So if you see "Active time" looking strong despite a meeting in progress, that's \
        because the math has already done the meeting accounting — don't add a second upward boost \
        on top of it. Use the calendar context to interpret the activity, not to inflate the score \
        a second time.

        When NO calendar event is in progress, weight the KIND of time. The streak/switch numbers \
        can look pristine for activities that aren't focused work — an uninterrupted hour of \
        solitaire, doomscrolling, or YouTube watch parties is not a 90. Hours dominated by social, \
        entertainment, or games should score lower than hours dominated by coding, writing, \
        design, research, comms, or admin — even when behavioral metrics are similar. Hours with \
        mostly uncategorized apps fall back to the baseline; don't guess wildly.

        Respond with ONLY a JSON object on a single line, no prose, no code fences:
        {"score": <0-100 integer>, "commentary": "<one or two short sentences in your voice>"}

        The commentary must be under 240 characters, in the personality voice you've been given, \
        and grounded in the stats above. Don't invent activities not listed. Don't recycle phrasing \
        from your previous turns.

        Numbers are literal. If active time is 5 minutes, do NOT say "an hour" or "all morning" \
        or any duration not implied by the actual numbers. If the user spent 1 minute on Gmail, \
        the commentary cannot say they spent "an hour" on it. Anchor any time references to the \
        active-time and longest-streak numbers above; if you can't be specific, be brief instead \
        of inventing scale.
        """

        // .minimal — JSON-extraction / question-phrasing paths don't want conversational
        // rules layered on top.
        let system = buildInsightsSystemPrompt(personality: settings.insightsPersonality, mode: .minimal)
        let payload: [OllamaClient.ChatMessage] = [
            OllamaClient.ChatMessage(role: .system, content: system),
            OllamaClient.ChatMessage(role: .user, content: userPrompt)
        ]

        do {
            let reply = try await OllamaClient.chat(
                baseURL: settings.ollamaURL,
                model: settings.ollamaModel,
                history: payload,
                options: .deterministicJSON()
            )
            return parseScoreJSON(reply)
        } catch {
            return nil
        }
    }

    /// Lenient JSON extractor — tolerates surrounding prose by scanning for the first `{...}`.
    private func parseScoreJSON(_ raw: String) -> ModelResult? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        struct Wire: Decodable { let score: Int; let commentary: String }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        let clamped = max(0, min(100, wire.score))
        let cleaned = wire.commentary.strippingSurroundingQuotes()
        return ModelResult(score: clamped, commentary: cleaned.isEmpty ? "—" : cleaned)
    }

    // MARK: - Conversational categorization

    /// Find the biggest uncategorized app or domain in the window and ask the user about it
    /// (in personality voice) via a chat assistant message. Apps and domains compete on time;
    /// whichever has the most uncategorized minutes wins. The user's next turn gets parsed by
    /// `handleChatMessagesChanged`.
    private func maybeAskAboutUncategorizedApp(summary: WindowSummary, settings: AppSettingsStore) async {
        guard pendingCategorization == nil, let chat else { return }

        // Build the union of candidates: uncategorized apps + uncategorized domains, all
        // above the time threshold. Whichever has the most time wins the slot.
        struct Candidate { let kind: PendingCategorization; let seconds: TimeInterval; let label: String }
        var candidates: [Candidate] = []

        for app in summary.appTotals {
            guard let id = app.bundleID, !id.isEmpty else { continue }
            // Hard-ignored bundle IDs (loginwindow et al.) never get asked about.
            if AppSettingsStore.isIgnoredBundleID(id) { continue }
            guard app.seconds >= categorizationMinSeconds else { continue }
            guard settings.appCategories[id] == nil else { continue }
            candidates.append(Candidate(
                kind: .app(bundleID: id, displayName: app.appName),
                seconds: app.seconds,
                label: app.appName
            ))
        }
        for host in summary.hostTotals {
            guard host.seconds >= categorizationMinSeconds else { continue }
            guard settings.domainCategories[host.host] == nil else { continue }
            candidates.append(Candidate(
                kind: .domain(host: host.host),
                seconds: host.seconds,
                label: host.host
            ))
        }
        guard let pick = candidates.max(by: { $0.seconds < $1.seconds }) else { return }

        // Ask the model to phrase the question in personality voice. Fall back to a plain
        // phrasing if the call fails so we still seed the conversation.
        let phrased = await phraseCategorizationQuestion(label: pick.label, kind: pick.kind, settings: settings)
            ?? defaultCategorizationQuestion(label: pick.label, kind: pick.kind)

        pendingCategorization = pick.kind
        // Mark the watermark as the *current* user-message count so this assistant message
        // doesn't get matched against a stale previous user reply.
        lastProcessedUserMessageCount = chat.messages.filter { $0.role == .user }.count
        chat.appendAssistant(phrased)
    }

    private func defaultCategorizationQuestion(label: String, kind: PendingCategorization) -> String {
        switch kind {
        case .app:
            return "What category should I put \(label) under? (e.g. coding, comms, research, social…)"
        case .domain:
            return "What category should I put \(label) under? (e.g. comms, research, social, entertainment…)"
        }
    }

    private func phraseCategorizationQuestion(label: String, kind: PendingCategorization, settings: AppSettingsStore) async -> String? {
        guard !settings.ollamaModel.isEmpty else { return nil }
        // .minimal — JSON-extraction / question-phrasing paths don't want conversational
        // rules layered on top.
        let system = buildInsightsSystemPrompt(personality: settings.insightsPersonality, mode: .minimal)
        let kindDescription: String
        switch kind {
        case .app: kindDescription = "the app"
        case .domain: kindDescription = "the website / domain"
        }
        let userPrompt = """
        Ask the user, in one short sentence in your voice, what category they'd file \(kindDescription) \
        "\(label)" under. Mention a couple example buckets like coding, comms, research, design, \
        social, entertainment, admin, writing. No greeting, no preface. Just the question.
        """
        let payload: [OllamaClient.ChatMessage] = [
            OllamaClient.ChatMessage(role: .system, content: system),
            OllamaClient.ChatMessage(role: .user, content: userPrompt)
        ]
        let reply = try? await OllamaClient.chat(
            baseURL: settings.ollamaURL,
            model: settings.ollamaModel,
            history: payload
        )
        guard let reply else { return nil }
        let cleaned = reply.strippingSurroundingQuotes()
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Watches the chat transcript. When a new user message arrives and we have a pending
    /// categorization, ask the model to extract a category from the user's reply and store
    /// it via the right setter (app vs. domain).
    private func handleChatMessagesChanged(_ messages: [OllamaClient.ChatMessage]) {
        let userTurns = messages.filter { $0.role == .user }
        guard userTurns.count > lastProcessedUserMessageCount else { return }
        defer { lastProcessedUserMessageCount = userTurns.count }
        guard let pending = pendingCategorization,
              let settings,
              let latest = userTurns.last else { return }

        Task { @MainActor in
            if let category = await extractCategory(fromReply: latest.content, label: pending.displayName, settings: settings) {
                switch pending {
                case .app(let bundleID, _):
                    settings.setAppCategory(bundleID: bundleID, category: category)
                case .domain(let host):
                    settings.setDomainCategory(host: host, category: category)
                }
            }
            // Whether or not we extracted a category, drop the pending state. The user can
            // always edit categories in Settings if our parse missed.
            pendingCategorization = nil
        }
    }

    private func extractCategory(fromReply reply: String, label: String, settings: AppSettingsStore) async -> String? {
        guard !settings.ollamaModel.isEmpty else { return nil }
        let userPrompt = """
        I asked the user what category to file "\(label)" under. They replied:

        "\(reply)"

        Extract just the category they're assigning. Respond with ONLY the category name as 1-3 \
        lowercase words (e.g. "coding", "comms", "personal admin"), or the single character "?" if \
        their reply doesn't actually pick a category. No quotes, no punctuation, no explanation.
        """
        let payload: [OllamaClient.ChatMessage] = [
            // Use a neutral system prompt for the parse — we want a clean extraction, not a
            // personality-voiced reply.
            OllamaClient.ChatMessage(role: .system, content: "You are a precise text extractor. Follow the user's format instructions exactly."),
            OllamaClient.ChatMessage(role: .user, content: userPrompt)
        ]
        let raw = try? await OllamaClient.chat(
            baseURL: settings.ollamaURL,
            model: settings.ollamaModel,
            history: payload,
            options: .deterministicJSON()
        )
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\".,!?"))
            .lowercased()
        if cleaned.isEmpty || cleaned == "?" { return nil }
        // Sanity bound: refuse anything longer than 4 words — likely the model rambled.
        let words = cleaned.split(separator: " ")
        if words.count > 4 { return nil }
        return cleaned
    }

    // MARK: - Range insights

    /// Build a cache key for a (rangeLabel, personality) pair.
    ///
    /// We deliberately do NOT include the range's start/end dates in the key. Rolling ranges like
    /// "Today" or "This week" recompute their `end` from `Date()` on every SwiftUI re-render, so
    /// including the exact instants meant the writer's key (set at click time) never matched the
    /// reader's key (computed milliseconds later) — `cachedSummary` always returned nil and the
    /// "Generate insight" button appeared to do nothing. The label + personality uniquely
    /// identifies the cache slot within a session.
    private static func rangeKey(rangeLabel: String, personality: InsightsPersonality) -> String {
        "\(rangeLabel)|\(personality.rawValue)"
    }

    /// Returns a cached AI summary for a range if one exists; otherwise nil.
    func cachedInsight(rangeLabel: String, range: DateInterval) -> String? {
        guard let settings else { return nil }
        let key = Self.rangeKey(rangeLabel: rangeLabel, personality: settings.insightsPersonality)
        return rangeInsights[key]
    }

    /// Generates a personality-voiced summary of the supplied stats and caches it. Caller
    /// supplies the human-readable range label ("This week", "Last month", etc.) which we both
    /// fold into the prompt and use as part of the cache key. Returns the generated text on
    /// success, nil on any error or empty model.
    @discardableResult
    func generateRangeInsight(rangeLabel: String, stats: RangeStats) async -> String? {
        guard let settings, !settings.ollamaModel.isEmpty else { return nil }
        let key = Self.rangeKey(rangeLabel: rangeLabel, personality: settings.insightsPersonality)
        if let cached = rangeInsights[key] { return cached }
        if generatingInsightKey == key { return nil }   // already in flight

        generatingInsightKey = key
        defer { generatingInsightKey = nil }

        let digest = Self.formatDigest(rangeLabel: rangeLabel, stats: stats)
        let userPrompt = """
        You are summarizing the user's focus-score history for a range. Below is an aggregated \
        digest — these numbers are the only ground truth; do not invent activities not listed.

        \(digest)

        Write a short summary (3–5 sentences, under 320 characters) in your personality voice. \
        Cover: overall trend (high / mixed / low), one observation about peaks (when they focus \
        best), one about troughs (when they don't), and at most one suggestion. If a category \
        dominates time, mention it. Don't list raw numbers verbatim — interpret them. Don't open \
        with a greeting. Don't recycle phrases from your previous turns.
        """

        // .minimal — JSON-extraction / question-phrasing paths don't want conversational
        // rules layered on top.
        let system = buildInsightsSystemPrompt(personality: settings.insightsPersonality, mode: .minimal)
        let payload: [OllamaClient.ChatMessage] = [
            OllamaClient.ChatMessage(role: .system, content: system),
            OllamaClient.ChatMessage(role: .user, content: userPrompt)
        ]

        do {
            let reply = try await OllamaClient.chat(
                baseURL: settings.ollamaURL,
                model: settings.ollamaModel,
                history: payload
            )
            let cleaned = reply.strippingSurroundingQuotes()
            guard !cleaned.isEmpty else { return nil }
            rangeInsights[key] = cleaned
            return cleaned
        } catch {
            return nil
        }
    }

    /// Invalidate any cached insight for a particular range (e.g. when the user clicks Refresh).
    func invalidateInsight(rangeLabel: String, range: DateInterval) {
        guard let settings else { return }
        let key = Self.rangeKey(rangeLabel: rangeLabel, personality: settings.insightsPersonality)
        rangeInsights.removeValue(forKey: key)
    }

    // MARK: - Backfill

    /// True while a backfill pass is in flight. Used to suppress redundant calls when the user
    /// triggers another recompute in the middle of an already-running backfill.
    @Published private(set) var isBackfilling: Bool = false

    /// "Catch me up since the last time we scored." Anchors on the most recent persisted score
    /// and scores every hour from that hour forward to (but not including) the current one.
    /// Existing entries within the scan range get OVERWRITTEN — the user's intent is to
    /// re-score even a previously-scored hour, since the data informing that score may have
    /// been incomplete (e.g., the timer fired mid-hour, or a sleep stretch was missing events
    /// when the original score was written).
    ///
    /// When there's no scored history yet, falls back to scanning from the earliest event in
    /// the activity log — that's the natural bound; the log's retention setting handles the
    /// upper limit.
    ///
    /// Each backfilled hour gets the same AI-refined commentary as the live compute. Throttled
    /// to one model call at a time and run as an unstructured Task so it doesn't block the UI.
    func backfillMissingHours() {
        guard !isBackfilling else { return }
        guard let activity, settings != nil else { return }
        let events = activity.events
        guard !events.isEmpty else { return }
        let cal = Calendar.current
        let now = Date()

        // Anchor: most recent scored hour's start, or earliest activity event if no history.
        // Walking forward from this anchor, we re-score / fill every hour up to (but not
        // including) the current hour.
        let scanStart: Date
        if let latest = history.mostRecentEntry() {
            scanStart = latest.windowStart
        } else if let earliestEvent = events.first {
            scanStart = earliestEvent.timestamp
        } else {
            return
        }

        var cursor = cal.date(bySettingHour: cal.component(.hour, from: scanStart), minute: 0, second: 0, of: scanStart) ?? scanStart
        let currentHourStart = cal.date(bySettingHour: cal.component(.hour, from: now), minute: 0, second: 0, of: now) ?? now

        var hoursToBackfill: [(start: Date, end: Date)] = []
        while cursor < currentHourStart {
            guard let nextHour = cal.date(byAdding: .hour, value: 1, to: cursor) else { break }
            // No "alreadyScored" check — the user explicitly wants existing entries within
            // the scan range to be re-scored. Hours with no eligible activity are the only
            // ones we skip.
            let intersects = events.contains { event in
                let eventEnd = event.endTimestamp ?? event.timestamp
                return event.timestamp < nextHour && eventEnd > cursor
            }
            if intersects {
                hoursToBackfill.append((start: cursor, end: nextHour))
            }
            cursor = nextHour
        }
        guard !hoursToBackfill.isEmpty else { return }

        isBackfilling = true
        // Newest-first so the user sees recent gaps fill in quickly when they open the chart.
        hoursToBackfill.reverse()

        Task { @MainActor [weak self] in
            // Hoist the strong-ref unwrap to the top of the task so it's valid for the whole
            // body — including the post-loop `rangeInsights.removeAll()` and the defer.
            guard let self else { return }
            defer { self.isBackfilling = false }
            for window in hoursToBackfill {
                guard let activity = self.activity, let settings = self.settings else { return }
                let summary = WindowSummary.build(events: activity.events, start: window.start, end: window.end, settings: settings, calendarEvents: self.calendar?.events ?? [])
                // Same threshold the live path uses; see `minScoredActiveSeconds` declaration.
                guard summary.totalSeconds >= self.minScoredActiveSeconds else { continue }
                let baseline = self.baselineScore(from: summary)
                var finalScore = baseline
                var commentary = self.defaultCommentary(for: summary, score: baseline)

                // Use AI just like the live path. If the model errors or is unconfigured we
                // still record the deterministic baseline — partial backfill beats nothing.
                if !settings.ollamaModel.isEmpty {
                    if let result = await self.askModelForScore(summary: summary, baseline: baseline, calendarContext: self.calendarContextSnippet(for: window), settings: settings) {
                        finalScore = result.score
                        commentary = result.commentary
                    }
                }

                let score = FocusScore(
                    value: finalScore,
                    windowStart: window.start,
                    windowEnd: window.end,
                    commentary: commentary,
                    topApps: summary.topApps(in: settings),
                    idleMinutes: Int(summary.idleSeconds / 60),
                    scoringVersion: Self.currentScoringVersion
                )
                self.history.record(score)
            }
            // Sync engine.current with whatever is now the most recent persisted entry so
            // the pill / Now tab match the Day view. Without this, recompute and rescore
            // could update history while leaving `current` stuck on its previous value.
            self.refreshCurrentFromHistory()
            // Cached range insights computed mid-backfill are now stale.
            self.rangeInsights.removeAll()
        }
    }

    /// Re-reads the most recent persisted entry from history and assigns it to `current` if
    /// it differs. Persists on change. Called at the end of any path that mutates history
    /// outside of `recomputeNow` (backfill, auto-refresh).
    private func refreshCurrentFromHistory() {
        guard let latest = history.mostRecentEntry() else { return }
        if current != latest {
            current = latest
            saveToDisk()
        }
    }

    /// Plain-language readout of what the engine sees for a given hour. Used by the Day view's
    /// diagnostic button so the user can answer "why doesn't this hour have a score?" without
    /// shipping log files. Pure read — doesn't write anything.
    struct HourDiagnostic {
        let windowStart: Date
        let windowEnd: Date
        let activeMinutes: Int
        let nonCountingActiveMinutes: Int
        let idleMinutes: Int
        let wallMinutes: Int
        let longestStreakMinutes: Int
        let switches: Int
        let distinctContexts: Int
        /// Same `FocusScore.TopApp` shape used by scored entries — apps + domains, with
        /// category resolved against current settings — so the Day view can render them
        /// horizontally via the same `FlowApps` component on both scored and skipped hours.
        let topApps: [FocusScore.TopApp]
        let baselinePresenceMultiplier: Double  // 0.4 ... 1.0
        let baseline: Int                       // 0 ... 100
        let thresholdMinActiveMinutes: Int
        let willScore: Bool
        let summary: String                     // human-readable headline
    }

    func diagnose(date: Date, hour: Int) -> HourDiagnostic {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let windowStart = cal.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) ?? dayStart
        let windowEnd = cal.date(byAdding: .hour, value: 1, to: windowStart) ?? windowStart
        return diagnose(windowStart: windowStart, windowEnd: windowEnd)
    }

    private func diagnose(windowStart: Date, windowEnd: Date) -> HourDiagnostic {
        let events = activity?.events ?? []
        let settings = settings
        let summary = settings.map {
            WindowSummary.build(events: events, start: windowStart, end: windowEnd, settings: $0, calendarEvents: calendar?.events ?? [])
        } ?? WindowSummary(
            totalSeconds: 0, nonCountingActiveSeconds: 0, idleSeconds: 0,
            windowSeconds: windowEnd.timeIntervalSince(windowStart),
            longestStreakSeconds: 0,
            switches: 0, distinctContexts: 0, appTotals: [], hostTotals: []
        )
        // Reuse the same topApps resolution as scored entries so apps + domains + categories
        // come out consistently. Empty when settings is nil.
        let topApps: [FocusScore.TopApp] = settings.map { summary.topApps(in: $0) } ?? []
        // Display totals come from the SUM of per-row rounded-up minutes, not raw seconds —
        // so two apps shown as "1 min" each total to "2 min" rather than the raw 60s
        // rounding back to 1. Score math (threshold, presence) still uses the raw seconds
        // via `summary.totalSeconds`; these values are display-only.
        var activeMin = 0
        var nonCountingMin = 0
        if let s = settings {
            for row in topApps {
                if s.categoryCountsTowardActive(row.category) {
                    activeMin += row.minutes
                } else {
                    nonCountingMin += row.minutes
                }
            }
        } else {
            activeMin = Int(summary.totalSeconds / 60)
            nonCountingMin = Int(summary.nonCountingActiveSeconds / 60)
        }
        let idleMin = Int(summary.idleSeconds / 60)
        let wallMin = activeMin + nonCountingMin + idleMin
        let thresholdMin = Int(minScoredActiveSeconds / 60)
        let willScore = summary.totalSeconds >= minScoredActiveSeconds

        // Compute baseline + presence the same way the live path does, so the user sees what
        // the score would have been (or what a previously-scored value was derived from).
        let baseline = baselineScore(from: summary)
        let activityRatio = summary.totalSeconds / max(60, summary.totalSeconds + summary.idleSeconds)
        let presence: Double = activityRatio >= 0.5 ? 1.0 : 0.4 + 0.6 * (activityRatio / 0.5)

        let summaryText: String
        if events.isEmpty {
            summaryText = "Activity log is empty — the watcher hasn't captured anything yet."
        } else if activeMin == 0 && wallMin == 0 {
            summaryText = "No activity events overlap this hour. Either the user wasn't at the machine or the watcher wasn't running."
        } else if activeMin == 0 {
            summaryText = "Wall-clock presence (\(wallMin) min) but zero active engagement — the user was at the machine but never touching keyboard / mouse / trackpad."
        } else if !willScore {
            summaryText = "Active time (\(activeMin) min) is below the \(thresholdMin)-min minimum. This hour gets skipped — the engine treats it as too sparse to score honestly."
        } else if presence < 1.0 {
            let multStr = String(format: "%.0f", presence * 100)
            summaryText = "Above threshold but presence multiplier (\(multStr)%) drags the score down — \(activeMin) of \(wallMin) wall-clock minutes were active. Baseline = \(baseline)."
        } else {
            summaryText = "Eligible. Baseline = \(baseline) before any AI nudge. Presence multiplier 100% (active for half or more of the wall window)."
        }

        return HourDiagnostic(
            windowStart: windowStart,
            windowEnd: windowEnd,
            activeMinutes: activeMin,
            nonCountingActiveMinutes: nonCountingMin,
            idleMinutes: idleMin,
            wallMinutes: wallMin,
            longestStreakMinutes: Int(summary.longestStreakSeconds / 60),
            switches: summary.switches,
            distinctContexts: summary.distinctContexts,
            topApps: topApps,
            baselinePresenceMultiplier: presence,
            baseline: baseline,
            thresholdMinActiveMinutes: thresholdMin,
            willScore: willScore,
            summary: summaryText
        )
    }

    /// Calendar events overlapping a single hour, formatted the same way `recomputeNow` does
    /// so backfill prompts share a shape with live ones.
    private func calendarContextSnippet(for window: (start: Date, end: Date)) -> String {
        guard let calendar else { return "" }
        return CalendarSummaryFormatter.describe(events: calendar.events, windowStart: window.start, windowEnd: window.end)
    }

    /// Ask the model to take a guess at categorizing apps/domains that have shown up with
    /// significant time but aren't categorized yet. One batched JSON call covers everything,
    /// keeping token cost low. Skipped silently when no model is configured. Applied entries
    /// are stored just like any user-set category — the user can correct in Settings if a
    /// guess is wrong, and the score auto-refresh will re-rate affected hours.
    ///
    /// This sits between the seed table (hardcoded common apps) and the conversational asker
    /// (stops the bot from quizzing the user about every long-tail app). After this runs,
    /// only genuinely ambiguous apps should remain uncategorized.
    @discardableResult
    func aiCategorizeUncategorized(daysBack: Int = 14) async -> Int {
        guard let settings, !settings.ollamaModel.isEmpty else { return 0 }
        let uncategorized = history.uncategorizedItems(daysBack: daysBack, settings: settings)
        let appCount = uncategorized.apps.count
        let domainCount = uncategorized.domains.count
        guard appCount + domainCount > 0 else { return 0 }

        // Build a single prompt listing both apps and domains so the model can answer in one
        // shot. Cap to top 20 of each to keep the prompt bounded.
        let appLines = uncategorized.apps.prefix(20).map { "- app: \"\($0.name)\" (bundle: \($0.bundleID))" }
        let domainLines = uncategorized.domains.prefix(20).map { "- domain: \"\($0.host)\"" }
        let listing = (appLines + domainLines).joined(separator: "\n")

        let userPrompt = """
        Categorize these apps and websites. Use these category buckets ONLY:
        coding, writing, design, comms, research, admin, social, entertainment, games

        For each item, decide which bucket fits its primary use. If you genuinely don't recognize \
        something or it's too ambiguous to guess, OMIT it from the response (don't guess wildly).

        Items to categorize:
        \(listing)

        Respond with ONLY a JSON object on a single line, no prose, no code fences:
        {"apps": {"<bundle-id>": "<category>", ...}, "domains": {"<host>": "<category>", ...}}

        Use the bundle IDs and hosts EXACTLY as provided as JSON keys. Categories must be one \
        of the buckets listed above, lowercase, no extra punctuation.
        """

        let payload: [OllamaClient.ChatMessage] = [
            OllamaClient.ChatMessage(role: .system, content: "You are a precise text extractor and classifier. Follow the user's format instructions exactly."),
            OllamaClient.ChatMessage(role: .user, content: userPrompt)
        ]

        let raw: String
        do {
            raw = try await OllamaClient.chat(
                baseURL: settings.ollamaURL,
                model: settings.ollamaModel,
                history: payload,
                options: .deterministicJSON()
            )
        } catch {
            return 0
        }

        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return 0 }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8) else { return 0 }
        struct Wire: Decodable { let apps: [String: String]?; let domains: [String: String]? }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return 0 }

        // Whitelist categories we accept; the prompt asks for these but we sanitize defensively
        // so a model that improvises ("productivity") doesn't pollute the store.
        let allowed: Set<String> = ["coding", "writing", "design", "comms", "research", "admin", "social", "entertainment", "games"]

        var applied = 0
        for (bundleID, category) in wire.apps ?? [:] {
            let cat = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard allowed.contains(cat) else { continue }
            // Don't overwrite a category the user (or seed) has already set.
            guard settings.appCategories[bundleID] == nil else { continue }
            settings.setAppCategory(bundleID: bundleID, category: cat)
            applied += 1
        }
        for (host, category) in wire.domains ?? [:] {
            let cat = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard allowed.contains(cat) else { continue }
            guard settings.domainCategories[host.lowercased()] == nil else { continue }
            settings.setDomainCategory(host: host, category: cat)
            applied += 1
        }

        return applied
    }

    /// Nuclear option: wipe every persisted score, then recreate everything the activity log
    /// can still cover via the backfill path. Useful when scoring rules have shifted enough
    /// that incremental refresh feels inadequate, or as a manual reset. Slow on large logs —
    /// every hour with ≥10 min of activity will trigger a model call. Background-Task'd; UI
    /// stays responsive.
    func nukeAndRecomputeAllScores() {
        guard !isBackfilling else { return }
        history.deleteAllEntries()
        current = nil
        rangeInsights.removeAll()
        // Backfill walks the activity log and recreates every eligible hour. With history now
        // empty, every hour is "missing" and gets scored fresh under the current rules and
        // category map.
        // After wiping, the most-recent-entry anchor returns nil, so backfill falls through
        // to "scan from earliest activity event" — which is what we want here.
        backfillMissingHours()
    }

    /// Re-score persisted entries within the recent past (default: today + yesterday). When
    /// `force` is false (the auto-on-pill-click path), only entries with stale stamps get
    /// re-scored; otherwise all eligible entries get the full treatment regardless. The
    /// manual "Re-score history" button passes `force: true` so it actually does work even
    /// when stamps look current — useful when the activity log has been cleaned up
    /// out-of-band (e.g., loginwindow filtering after the fact).
    ///
    /// Sequential, background-Task'd, AI-refined just like backfill. Skips hours where the
    /// activity log no longer covers them (pruned by retention) — those entries stay as-is
    /// rather than getting wiped to zero.
    func autoRefreshOutdatedScores(daysBack: Int = 2, force: Bool = false) {
        guard !isBackfilling else { return }
        guard let activity, let settings else { return }
        let currentCategoriesRevision = settings.appCategoriesRevision
        let events = activity.events
        guard !events.isEmpty else { return }
        let cal = Calendar.current

        let now = Date()
        let lastDay = cal.startOfDay(for: now)
        // Window the scan to the last `daysBack` days. Default 2 = today + yesterday. Pass a
        // very large value (e.g. `Int.max`) to mean "as far back as the activity log covers" —
        // we clamp to the earliest event so `cal.date(byAdding:)` doesn't overflow.
        let earliestDay: Date = {
            if daysBack >= 365, let earliestEvent = events.first?.timestamp {
                return cal.startOfDay(for: earliestEvent)
            }
            return cal.date(byAdding: .day, value: -(max(0, daysBack) - 1), to: lastDay) ?? lastDay
        }()

        // The earliest event in the (already-filtered) log defines coverage. Hours whose
        // `windowEnd` is older than this haven't been pruned to garbage by the rescore — they
        // genuinely predate the current log and should be left alone. Hours within coverage
        // that have NO intersecting events are entries we should DELETE — usually because the
        // events that produced them got filtered out (loginwindow), so the score was bogus.
        let coverageStart = events.first?.timestamp ?? Date.distantFuture

        var hoursToRecompute: [(start: Date, end: Date)] = []
        var hoursToDelete: [(date: Date, hour: Int)] = []
        var dayCursor = earliestDay
        while dayCursor <= lastDay {
            for entry in history.entries(for: dayCursor) {
                // An entry is stale if EITHER the scoring rules have changed (loginwindow filter,
                // threshold tweak, etc.) OR the user has updated the category map since this
                // entry was scored. Forced re-scores bypass the staleness check so the manual
                // button always does work even when stamps look current.
                if !force {
                    let entryVersion = entry.scoringVersion ?? 0
                    let entryCatRev = entry.categoriesRevision ?? 0
                    let stale = entryVersion < Self.currentScoringVersion
                        || entryCatRev < currentCategoriesRevision
                    if !stale { continue }
                }
                let intersects = events.contains { event in
                    let eventEnd = event.endTimestamp ?? event.timestamp
                    return event.timestamp < entry.windowEnd && eventEnd > entry.windowStart
                }
                if intersects {
                    hoursToRecompute.append((start: entry.windowStart, end: entry.windowEnd))
                } else if entry.windowEnd >= coverageStart {
                    // Within current log coverage but no events overlap — the events that
                    // produced this entry got filtered out (loginwindow) or otherwise removed.
                    // Delete it. Predates-coverage entries fall through unchanged.
                    hoursToDelete.append((date: entry.windowStart, hour: cal.component(.hour, from: entry.windowStart)))
                }
            }
            guard let nextDay = cal.date(byAdding: .day, value: 1, to: dayCursor) else { break }
            dayCursor = nextDay
        }

        // Process deletes immediately (they're synchronous + cheap). The async Task below only
        // runs if there's at least something to recompute.
        for hour in hoursToDelete {
            history.deleteEntry(forDate: hour.date, hour: hour.hour)
        }
        if !hoursToDelete.isEmpty {
            rangeInsights.removeAll()
            // If we just deleted the entry behind engine.current, the pill would otherwise
            // keep showing the deleted hour. Pull the now-most-recent entry forward.
            refreshCurrentFromHistory()
        }

        guard !hoursToRecompute.isEmpty else { return }

        isBackfilling = true
        // Newest-first so the user sees the most recent corrections land first.
        hoursToRecompute.reverse()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isBackfilling = false }
            for window in hoursToRecompute {
                guard let activity = self.activity, let settings = self.settings else { return }
                let summary = WindowSummary.build(events: activity.events, start: window.start, end: window.end, settings: settings, calendarEvents: self.calendar?.events ?? [])
                // If the rescore now finds less active time than the live path requires for a
                // new score, the entry is no longer meaningful under current rules — delete it
                // rather than rewriting it to a token-heavy near-zero. Same threshold as the
                // live `recomputeNow` path uses, so live and rescore agree on what counts.
                guard summary.totalSeconds >= self.minScoredActiveSeconds else {
                    let hour = cal.component(.hour, from: window.start)
                    self.history.deleteEntry(forDate: window.start, hour: hour)
                    continue
                }
                let baseline = self.baselineScore(from: summary)
                var finalScore = baseline
                var commentary = self.defaultCommentary(for: summary, score: baseline)
                if !settings.ollamaModel.isEmpty {
                    if let result = await self.askModelForScore(summary: summary, baseline: baseline, calendarContext: self.calendarContextSnippet(for: window), settings: settings) {
                        finalScore = result.score
                        commentary = result.commentary
                    }
                }
                let score = FocusScore(
                    value: finalScore,
                    windowStart: window.start,
                    windowEnd: window.end,
                    commentary: commentary,
                    topApps: summary.topApps(in: settings),
                    idleMinutes: Int(summary.idleSeconds / 60),
                    scoringVersion: Self.currentScoringVersion
                )
                self.history.record(score)
            }
            // See comment in `backfillMissingHours` — keep `current` aligned with the latest
            // persisted entry so pill / Now tab agree with Day view.
            self.refreshCurrentFromHistory()
            self.rangeInsights.removeAll()
        }
    }

    /// Renders the stats payload as a compact text block the model can read. Uses local-time
    /// formatting and clamps lists so the prompt stays well under any reasonable token budget.
    private static func formatDigest(rangeLabel: String, stats: RangeStats) -> String {
        var lines: [String] = []
        lines.append("Range: \(rangeLabel) (\(stats.dayCount) day\(stats.dayCount == 1 ? "" : "s"), \(stats.entryCount) hourly score\(stats.entryCount == 1 ? "" : "s"))")
        lines.append("Average focus score: \(stats.averageScore)/100")
        lines.append("Active time: \(stats.totalActiveMinutes) min  |  Idle time: \(stats.totalIdleMinutes) min")
        if let best = stats.bestUnit {
            lines.append("Best \(stats.granularity.label): \(best.label) (\(best.avg))")
        }
        if let worst = stats.worstUnit {
            lines.append("Worst \(stats.granularity.label): \(worst.label) (\(worst.avg))")
        }
        if !stats.peakHours.isEmpty {
            lines.append("Peak hours (≥+10 above mean): " + stats.peakHours.map(formatHour12).joined(separator: ", "))
        }
        if !stats.sleepHours.isEmpty {
            lines.append("Trough hours (≤-10 below mean): " + stats.sleepHours.map(formatHour12).joined(separator: ", "))
        }
        if !stats.mostlyIdleHours.isEmpty {
            lines.append("Mostly idle hours (more AFK than active): " + stats.mostlyIdleHours.map(formatHour12).joined(separator: ", "))
        }
        if !stats.emptyHours.isEmpty {
            lines.append("Empty hours (no activity logged at all): " + stats.emptyHours.map(formatHour12).joined(separator: ", "))
        }
        if !stats.topCategories.isEmpty {
            let cats = stats.topCategories.map { "\($0.name) (\($0.minutes) min)" }.joined(separator: ", ")
            lines.append("Top categories: \(cats)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var stored = try? decoder.decode(FocusScore.self, from: data) else { return }
        // Cosmetic strip: pre-filter-era persisted entries may have loginwindow rows in their
        // topApps. Match the same defensive predicate used by the summary builder.
        stored.topApps = stored.topApps.filter { row in
            let bundleMatches = row.bundleID?.lowercased().hasPrefix("com.apple.loginwindow") ?? false
            let nameMatches = row.appName.lowercased().contains("loginwindow")
            return !bundleMatches && !nameMatches
        }
        current = stored
    }

    private func saveToDisk() {
        let dir = manifestURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}

// MARK: - Calendar summary

/// Formats calendar events that overlap a focus-score window into a short bulleted list. Lives
/// here (not on `CalendarFeedStore`) because the framing — "during this window" — is specific
/// to the focus engine; chat-side context is built differently in `InsightsContextBuilder`.
enum CalendarSummaryFormatter {
    static func describe(events: [CalendarEvent], windowStart: Date, windowEnd: Date) -> String {
        let overlapping = events.filter { $0.end > windowStart && $0.start < windowEnd }
        guard !overlapping.isEmpty else { return "" }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        return overlapping.sorted { $0.start < $1.start }.map { event in
            "- \"\(event.title)\" \(timeFormatter.string(from: event.start))–\(timeFormatter.string(from: event.end))"
        }.joined(separator: "\n")
    }
}

// MARK: - Host extraction

/// Pulls a stable hostname from a tab URL: lowercased, with leading `www.` stripped. Returns
/// nil for URLs that don't have a parseable host (chrome://, file://, blank, etc.). Used by
/// the per-domain time aggregation so e.g. `mail.google.com` and `news.google.com` end up as
/// distinct buckets.
func extractHost(from urlString: String) -> String? {
    guard !urlString.isEmpty,
          let url = URL(string: urlString),
          let host = url.host?.lowercased() else { return nil }
    if host.hasPrefix("www.") {
        return String(host.dropFirst(4))
    }
    return host
}

// MARK: - Window summary

/// Derived stats over a time window. All seconds-valued so callers can format minutes themselves.
struct WindowSummary {
    struct AppTotal { let appName: String; let bundleID: String?; let seconds: TimeInterval }
    /// Per-host bucket for browser activity. Each contributing event has a tabURL; this struct
    /// remembers which app the host was visited under so we can fall back to the parent's
    /// category when the host itself is uncategorized.
    struct HostTotal {
        let host: String
        let parentAppName: String
        let parentBundleID: String?
        let seconds: TimeInterval
    }

    /// Active time in COUNTING categories only — idle subtracted, and time spent in non-
    /// counting categories (social, entertainment, games by default) excluded entirely.
    /// This is the value used for the threshold check, presence multiplier, and baseline
    /// streak math. Per the user's settings — they can flip any recognized category.
    let totalSeconds: TimeInterval
    /// Active time in non-counting categories — tracked separately so the diagnostic readout
    /// can show "you spent 30 min on entertainment, but the score doesn't credit it."
    let nonCountingActiveSeconds: TimeInterval
    /// Estimated AFK seconds inside the window. Surfaced separately so the prompt can mention it
    /// (so the model can correlate it with calendar context — e.g. idle during a meeting block).
    let idleSeconds: TimeInterval
    /// Wall-clock duration of the scoring window (always 3600s for an hourly score). Stored
    /// because the `totalSeconds + idleSeconds` sum is NOT the window length — it's the sum of
    /// *captured event durations*, which can be much smaller when the user walked away from
    /// the machine and no events were logged. The presence multiplier needs the real window.
    let windowSeconds: TimeInterval
    let longestStreakSeconds: TimeInterval
    let switches: Int
    let distinctContexts: Int
    /// Per-app totals sorted desc by seconds. Multiple windows of the same app get folded together.
    let appTotals: [AppTotal]
    /// Per-host totals (browsers only). When present, `topApps(in:)` substitutes domain rows
    /// for the parent browser app in the digest the AI sees, so e.g. Chrome time gets split
    /// into `gmail.com (25m)` and `theonion.com (12m)` with their own categories.
    let hostTotals: [HostTotal]

    /// Build from the activity event ring, keeping only events whose interval intersects the window.
    /// Each event's contribution is reduced by the idle time recorded at its trailing edge so AFK
    /// stretches don't pad streaks or app totals. The wall-clock total stays available too for any
    /// caller that wants to know how much real time the window covers.
    /// Returns true for events that should never count toward focus — currently any flavor of
    /// `loginwindow` (lock screen, login screen, fast-user-switching).
    static func isIgnoredEvent(_ event: ActivityWatcher.Event) -> Bool {
        if let id = event.bundleID?.lowercased(), id.hasPrefix("com.apple.loginwindow") {
            return true
        }
        if event.appName.lowercased().contains("loginwindow") {
            return true
        }
        return false
    }

    /// Single source of truth for "what category does this event belong to?" Host wins for
    /// browser events; falls back to the app's bundleID-based category. Lowercased.
    static func resolvedCategory(forEvent event: ActivityWatcher.Event, settings: AppSettingsStore) -> String? {
        if let url = event.tabURL, let host = extractHost(from: url),
           let cat = settings.domainCategories[host], !cat.isEmpty {
            return cat.lowercased()
        }
        if let bid = event.bundleID, let cat = settings.appCategories[bid], !cat.isEmpty {
            return cat.lowercased()
        }
        return nil
    }

    static func build(events: [ActivityWatcher.Event], start: Date, end: Date, settings: AppSettingsStore, calendarEvents: [CalendarEvent] = []) -> WindowSummary {
        let events = events.filter { !isIgnoredEvent($0) }
        let overlappingMeetings = calendarEvents.filter { $0.start < end && $0.end > start }
        var activeSeconds: TimeInterval = 0
        var nonCountingActiveSeconds: TimeInterval = 0
        var idleSeconds: TimeInterval = 0
        var longestStreak: TimeInterval = 0
        var switches = 0
        var contextKeys: Set<String> = []
        var appBuckets: [String: AppTotal] = [:]    // keyed by appName for visual stability
        var hostBuckets: [String: HostTotal] = [:]  // keyed by host

        // Streak tracking is at the host/app level, NOT per-URL. A user clicking from inbox
        // to a single email inside Gmail used to break the streak (URL changes); now it
        // doesn't. The streak ends only when the host or non-browser app changes, OR when
        // there's a meaningful time gap between events (sleep, AFK, switching out and back).
        // Activity-log events stay URL-granular for log fidelity; this is just a per-call
        // re-aggregation.
        var lastContextKey: String?
        var currentStreakKey: String?
        var currentStreakSeconds: TimeInterval = 0
        var currentStreakEnd: Date?
        let maxStreakGap: TimeInterval = 5 * 60   // > 5 min gap breaks the streak

        func closeStreak() {
            if currentStreakSeconds > longestStreak {
                longestStreak = currentStreakSeconds
            }
            currentStreakKey = nil
            currentStreakSeconds = 0
            currentStreakEnd = nil
        }

        for event in events {
            let evStart = event.timestamp
            let evEnd = event.endTimestamp ?? event.timestamp
            let clippedStart = max(evStart, start)
            let clippedEnd = min(evEnd, end)
            guard clippedEnd > clippedStart else { continue }
            let wallDuration = clippedEnd.timeIntervalSince(clippedStart)

            let evWallDuration = max(0.0001, evEnd.timeIntervalSince(evStart))
            let idleAtEnd = event.idleSecondsAtCapture ?? 0
            let idleInWindow = min(wallDuration, idleAtEnd * (wallDuration / evWallDuration))

            // Calendar-aware idle credit: when the activity event overlaps a meeting on the
            // calendar, idle minutes inside it count as ACTIVE. The user is in the meeting
            // (Zoom listening, in-person presenting, taking notes) — the keyboard not moving
            // doesn't mean unfocused.
            let inMeeting = overlappingMeetings.contains { $0.start < clippedEnd && $0.end > clippedStart }
            let activeDuration: TimeInterval = inMeeting
                ? wallDuration
                : max(0, wallDuration - idleInWindow)

            // Resolve this event's category — host preferred for browsers, then app — and
            // route active time to either the counting or non-counting bucket. Time on a
            // non-counting category (default: social/entertainment/games) is excluded from
            // the score's "active" total even though it's still tracked for display in
            // topApps and the diagnostic readout. Calendar-credit overrides this: time during
            // a meeting block always counts, regardless of app/host category.
            let category = Self.resolvedCategory(forEvent: event, settings: settings)
            let counts = inMeeting || settings.categoryCountsTowardActive(category)
            if counts {
                activeSeconds += activeDuration
            } else {
                nonCountingActiveSeconds += activeDuration
            }
            idleSeconds += (wallDuration - activeDuration)

            // Streak key: host for browser-with-URL events, app for everything else. Same
            // host (e.g., mail.google.com across multiple emails) keeps the streak alive.
            let streakKey: String = {
                if let url = event.tabURL, !url.isEmpty, let host = extractHost(from: url) {
                    return "host:\(host)"
                }
                return "app:\(event.bundleID ?? event.appName)"
            }()

            // Time gap from the previous streak's end to this event's clipped start. A long
            // gap means the user was away or doing something else even if the key matches.
            let gap: TimeInterval
            if let lastEnd = currentStreakEnd {
                gap = clippedStart.timeIntervalSince(lastEnd)
            } else {
                gap = .infinity
            }

            // Non-counting events (social/entertainment/games etc.) break any active streak.
            // A streak is "continuous focused work"; switching to Twitter for 5 minutes ends
            // the streak even on the same browser host.
            if !counts {
                closeStreak()
                currentStreakKey = nil
                currentStreakEnd = clippedEnd
            } else if streakKey == currentStreakKey, gap <= maxStreakGap {
                currentStreakSeconds += activeDuration
                currentStreakEnd = clippedEnd
            } else {
                closeStreak()
                currentStreakKey = streakKey
                currentStreakSeconds = activeDuration
                currentStreakEnd = clippedEnd
            }

            if activeDuration > 0 {
                let contextKey = "\(event.appName)|\(event.windowTitle ?? "")|\(event.tabURL ?? "")"
                contextKeys.insert(contextKey)
                if let last = lastContextKey, last != contextKey { switches += 1 }
                lastContextKey = contextKey

                let key = event.appName
                if let prev = appBuckets[key] {
                    appBuckets[key] = AppTotal(appName: prev.appName, bundleID: prev.bundleID ?? event.bundleID, seconds: prev.seconds + activeDuration)
                } else {
                    appBuckets[key] = AppTotal(appName: event.appName, bundleID: event.bundleID, seconds: activeDuration)
                }

                // Per-host bucketing: only when the event is in a recognized browser AND the
                // tab URL parses to a usable host. `extractHost` handles `www.` stripping and
                // junk URLs; redacted private-window events have nil tabURL so they bypass.
                if let urlString = event.tabURL, let host = extractHost(from: urlString) {
                    if let prev = hostBuckets[host] {
                        hostBuckets[host] = HostTotal(
                            host: prev.host,
                            parentAppName: prev.parentAppName,
                            parentBundleID: prev.parentBundleID ?? event.bundleID,
                            seconds: prev.seconds + activeDuration
                        )
                    } else {
                        hostBuckets[host] = HostTotal(
                            host: host,
                            parentAppName: event.appName,
                            parentBundleID: event.bundleID,
                            seconds: activeDuration
                        )
                    }
                }
            }
        }
        // Close the final running streak before returning.
        closeStreak()

        let totals = appBuckets.values.sorted { $0.seconds > $1.seconds }
        let hosts = hostBuckets.values.sorted { $0.seconds > $1.seconds }
        return WindowSummary(
            totalSeconds: activeSeconds,
            nonCountingActiveSeconds: nonCountingActiveSeconds,
            idleSeconds: idleSeconds,
            windowSeconds: end.timeIntervalSince(start),
            longestStreakSeconds: longestStreak,
            switches: switches,
            distinctContexts: contextKeys.count,
            appTotals: totals,
            hostTotals: hosts
        )
    }

    /// Top entries as `FocusScore.TopApp` rows. For browser apps that produced any host data,
    /// the parent app row is replaced by per-host rows so the AI sees `gmail.com (25m)` and
    /// `theonion.com (12m)` separately rather than one undifferentiated `Chrome` lump.
    ///
    /// Any nonzero contribution rounds UP to 1 minute — entries that would otherwise display
    /// as "0 min" are surfaced as "1 min" so the user sees they happened. Truly-zero entries
    /// (no seconds at all) don't make it in.
    func topApps(in settings: AppSettingsStore) -> [FocusScore.TopApp] {
        let appsWithHosts = Set(hostTotals.map { $0.parentAppName })

        var rows: [FocusScore.TopApp] = []

        for app in appTotals where !appsWithHosts.contains(app.appName) {
            guard app.seconds > 0 else { continue }
            rows.append(FocusScore.TopApp(
                appName: app.appName,
                bundleID: app.bundleID,
                minutes: max(1, Int(app.seconds / 60)),
                category: app.bundleID.flatMap { settings.appCategories[$0] }
            ))
        }

        for host in hostTotals {
            guard host.seconds > 0 else { continue }
            let resolvedCategory = settings.domainCategories[host.host]
                ?? host.parentBundleID.flatMap { settings.appCategories[$0] }
            rows.append(FocusScore.TopApp(
                appName: host.host,
                bundleID: host.host,                          // reused as category-lookup key on display side
                minutes: max(1, Int(host.seconds / 60)),
                category: resolvedCategory
            ))
        }

        return rows
            .sorted { $0.minutes > $1.minutes }
            .prefix(8)
            .map { $0 }
    }
}
