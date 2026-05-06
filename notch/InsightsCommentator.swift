//
//  InsightsCommentator.swift
//  notch
//
//  Periodic, opt-in autonomous commentary. Every few minutes the timer fires; with 60% probability
//  it asks the configured Ollama model to make a brief, in-personality remark about what the user
//  is currently doing and what's on their calendar. Comments are appended to the Insights chat
//  transcript as assistant messages.
//

import AppKit
import Combine
import Foundation

@MainActor
final class InsightsCommentator: ObservableObject {
    /// Period for the long-dwell check. Doesn't fire commentary on its own — only triggers
    /// `tick()` when the user has been on the same context for >= `longDwellThreshold`
    /// without a recent comment, OR when a calendar event boundary just crossed. The 60%
    /// random-gate from the old timer-driven design is gone; firing is now deterministic.
    private let timerCheckInterval: TimeInterval = 5 * 60
    /// How long the user must be on the same context before the long-dwell check considers a
    /// "you've been at this a while" remark. Combined with the existing 2-hour same-context
    /// suppression, this means at most one such remark per long stretch.
    private let longDwellThreshold: TimeInterval = 30 * 60
    /// Idle threshold for "user is gone, don't comment."
    private let afkIdleThreshold: TimeInterval = 15 * 60
    /// Hard minimum between commentary fires, regardless of trigger source. Two triggers
    /// (context change settle + calendar boundary, etc.) can land within seconds of each
    /// other — same-context guard only catches matching app/window/tab, so a meeting that
    /// also coincides with a context switch could double-fire. This cooldown ensures at
    /// most one comment in any rolling 5-minute window. Forced "Comment now" bypasses.
    private let minTimeBetweenComments: TimeInterval = 5 * 60

    /// Structural directives, one chosen at random per tick. Forces the model out of any single
    /// scaffold (rhetorical-question close, "X is a Y, Y is a Z" metaphor stacks, etc.) by
    /// pre-committing it to a different shape each time. Repeat-penalty alone doesn't catch
    /// multi-word patterns; this does.
    private let structuralDirectives: [String] = [
        "Make it ONE declarative sentence. No rhetorical question. No metaphor stack.",
        "Open with a verb in the imperative. Under 18 words. No questions.",
        "A single image, plain English. No 'X is a Y' constructions.",
        "Address the user directly with 'you'. No metaphors. Under 20 words.",
        "Two short sentences. No questions. No imagery — say what's literally happening.",
        "Drop a single line of dialogue, like overheard speech. Not aimed at anyone.",
        "Compare the situation to something concrete and specific (not 'a hearth', not 'a psalm').",
        "Just an observation. Past tense. No second person.",
        "One sentence, ending in a noun, not a question mark.",
        "Bluntly state what you see. No imagery. No figurative language at all this turn.",
    ]

    /// Reason the most recent tick produced (or didn't produce) a comment. Surfaced in Settings
    /// as a small diagnostic so the user can tell whether the path is alive vs. silently broken.
    enum LastTickResult: String {
        case fired = "Fired"
        case skippedAFK = "Skipped — AFK"
        case skippedDice = "Skipped — random gate"
        case skippedNoModel = "Skipped — no model configured"
        case skippedNoAX = "Skipped — no Accessibility permission"
        case skippedDisabled = "Skipped — toggle off"
        case skippedBusy = "Skipped — chat in progress"
        case skippedNoContext = "Skipped — no useful context"
        case skippedTransient = "Skipped — transient frontmost app"
        case skippedSameContext = "Skipped — same context as recent comment"
        case skippedSleeping = "Skipped — system asleep / lid closed"
        case skippedCooldown = "Skipped — within cooldown after last comment"
        case modelEmpty = "Model returned empty"
        case modelSentinel = "Model said -"
        case modelError = "Model errored"
    }

    /// Tracks whether macOS reported a sleep event since launch. Flipped by NSWorkspace's
    /// `willSleep` / `didWake` notifications. The lid closing (or any sleep trigger) sets
    /// this true; wake clears it. Commentator skips while asleep so a forced timer tick
    /// while the user is away from the machine doesn't fire — and so the AI can't write a
    /// comment about whatever app was frontmost when they walked off.
    private var isSleeping: Bool = false

    /// What was in focus when the commentator last produced a comment. Used to suppress
    /// repeat-observation comments when the user has been parked on the same thing for a
    /// while ("you're still on slide 4" * 6).
    private struct LastCommentContext: Equatable {
        let appName: String
        let windowTitle: String?
        let tabURL: String?
        let at: Date
    }
    private var lastCommentContext: LastCommentContext?

    /// How long the same-context guard suppresses. After this stretch the commentator gets
    /// another shot — same activity over hours is itself worth remarking on, just not at
    /// every 5-min tick.
    private let sameContextSuppressionWindow: TimeInterval = 2 * 60 * 60

    /// Last (app, window, tab) we saw on the activity watcher's latestEvent. Used to detect
    /// genuine context transitions for the event-driven tick.
    private struct ContextFingerprint: Equatable {
        let appName: String
        let windowTitle: String?
        let tabURL: String?
    }
    private var lastSeenContext: ContextFingerprint?
    private var contextChangeDebounce: Task<Void, Never>?
    /// How long we wait after a context change before firing. Filters incidental clicking
    /// around (alt-tab through several apps to find one); only fires once the user has
    /// settled.
    private let contextChangeSettleDelay: TimeInterval = 90

    /// Bundle IDs the commentator refuses to riff on when they're frontmost. These are
    /// "transit apps" — the user is moving between things, not doing focused work, so any
    /// remark would either feel random or accidentally drag down the conversation. Distinct
    /// from `AppSettingsStore.isIgnoredBundleID` (which is the harder "never even count this
    /// as activity" predicate) — Finder time still counts as activity, just shouldn't trigger
    /// commentary.
    private let transientBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.systempreferences"
    ]

    @Published private(set) var lastTickAt: Date?
    @Published private(set) var lastTickResult: LastTickResult?
    @Published private(set) var lastCommentAt: Date?

    private weak var chat: InsightsChatStore?
    private weak var activity: ActivityWatcher?
    private weak var calendar: CalendarFeedStore?
    private weak var settings: AppSettingsStore?

    private var timer: Timer?
    private var settingsCancellable: AnyCancellable?

    init(chat: InsightsChatStore, activity: ActivityWatcher, calendar: CalendarFeedStore, settings: AppSettingsStore) {
        self.chat = chat
        self.activity = activity
        self.calendar = calendar
        self.settings = settings

        // Start/stop the timer based on the toggle. Reactive subscription so flipping the setting
        // takes effect immediately.
        settingsCancellable = settings.$insightsCommentaryEnabled
            .sink { [weak self] enabled in
                Task { @MainActor in
                    if enabled { self?.start() } else { self?.stop() }
                }
            }

        // Event-driven trigger: subscribe to context changes on the activity watcher. A real
        // transition (different app / window / tab) schedules a tick after a settle delay so
        // we don't fire on incidental cmd-tab flicker. Combined with the existing same-context
        // guard (which suppresses repeats), this makes most commentary land on transitions
        // rather than fixed timer ticks. The 5-min timer stays as a baseline.
        activity.$latestEvent
            .sink { [weak self] event in
                Task { @MainActor in self?.handleContextChange(event) }
            }
            .store(in: &cancellables)

        // Sleep / wake notifications. Lid close → willSleep → suppress ticks until didWake.
        // Catches lid-close, system sleep timer, manually triggered sleep, etc.
        // Inner Task re-captures self weakly to avoid the "captured var in concurrently-
        // executing code" warning under Swift 6 strict concurrency.
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isSleeping = true }
        }
        wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isSleeping = false }
        }
    }

    private var cancellables: Set<AnyCancellable> = []

    private func handleContextChange(_ event: ActivityWatcher.Event?) {
        guard let event else { return }
        let current = ContextFingerprint(
            appName: event.appName,
            windowTitle: event.windowTitle,
            tabURL: event.tabURL
        )
        if lastSeenContext == current { return }
        lastSeenContext = current

        // Cancel any pending settle and start a fresh one. If the user keeps flipping
        // contexts, only the final settled context produces a tick.
        contextChangeDebounce?.cancel()
        contextChangeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.contextChangeSettleDelay ?? 90) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.tick()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func start() {
        guard timer == nil else { return }
        // Periodic check (not auto-fire). Every `timerCheckInterval`, evaluate whether the
        // user has been on the same context long enough to warrant a remark, OR whether a
        // calendar boundary just crossed. Most ticks do nothing; the same-context guard
        // ensures we don't double-fire when conditions haven't changed.
        let timer = Timer(timeInterval: timerCheckInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.periodicCheck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Periodic check (5-min cadence). Conditions to fire:
    /// - User has been on same context for >= longDwellThreshold AND we haven't commented on
    ///   that context recently (same-context guard handles the recency).
    /// - A calendar event has started or ended in the last `timerCheckInterval`.
    /// Otherwise no-op.
    private func periodicCheck() async {
        guard let activity, let calendar = self.calendar else { return }

        // Long-dwell condition: latest event's streak duration is past threshold.
        if let latest = activity.latestEvent {
            let streakDuration = (latest.endTimestamp ?? latest.timestamp).timeIntervalSince(latest.timestamp)
            if streakDuration >= longDwellThreshold {
                await tick()
                return
            }
        }

        // Calendar boundary: did any event start or end within the last check window?
        let now = Date()
        let lookback = now.addingTimeInterval(-timerCheckInterval)
        let crossedBoundary = calendar.events.contains { event in
            (event.start > lookback && event.start <= now) ||
            (event.end > lookback && event.end <= now)
        }
        if crossedBoundary {
            await tick()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Force a commentary attempt right now, bypassing the random gate and AFK guard. Used by a
    /// debug button in Settings → Insights so the user can verify the model + prompt path is
    /// working without waiting on the timer roll.
    func triggerNow() async {
        await tick(forceFire: true)
    }

    /// Single dice roll + commentary attempt. Bails early on any precondition that would either
    /// produce a no-op or look weird (mid-conversation, no model, no AX, etc.).
    private func tick(forceFire: Bool = false) async {
        lastTickAt = Date()
        guard let chat, let settings, let activity, let calendar else { return }
        // Sleeping / lid-closed: never fire commentary. The user isn't there to read it,
        // and the AI would otherwise riff on whatever app happened to be frontmost when
        // they walked away. Forced ticks (Settings → Comment now) bypass — the user is
        // explicitly testing.
        if isSleeping && !forceFire {
            lastTickResult = .skippedSleeping
            return
        }
        guard !settings.ollamaModel.isEmpty else {
            lastTickResult = .skippedNoModel
            return
        }
        guard !chat.isLoading else {
            lastTickResult = .skippedBusy
            return
        }
        guard activity.hasAccessibilityPermission else {
            lastTickResult = .skippedNoAX
            return
        }
        // Forced ticks bypass the enable / AFK / cooldown gates; otherwise honor them. The
        // random-gate dice is gone — firing is now deterministic, driven by context changes,
        // calendar boundaries, or long-dwell. The same-context + cooldown guards below
        // handle "don't repeat" / "don't double-fire" without needing probabilistic skipping.
        if !forceFire {
            guard settings.insightsCommentaryEnabled else {
                lastTickResult = .skippedDisabled
                return
            }
            if let idle = activity.latestEvent?.idleSecondsAtCapture, idle >= afkIdleThreshold {
                lastTickResult = .skippedAFK
                return
            }
            // Hard cooldown across all trigger sources. Multiple triggers (context-change
            // settle + calendar boundary + long-dwell) can land within seconds of each
            // other, especially when a meeting starts and the user simultaneously switches
            // apps. The same-context guard only catches matching app/window/tab pairs;
            // this covers the cross-context double-fire case.
            if let last = lastCommentAt, Date().timeIntervalSince(last) < minTimeBetweenComments {
                lastTickResult = .skippedCooldown
                return
            }
        }

        // Force a fresh activity snapshot before composing context. Without this, the context
        // we send describes whatever the watcher's last 30s tick saw — which can easily be a
        // since-quit app or a since-switched window. The commentator then riffs on something
        // the user is no longer doing.
        activity.captureNow()

        // Skip commentary when the user is parked in a transient app (Finder, System Settings).
        // These are transit between things; commenting on them produces awkward riffs about
        // file management or settings changes that the user isn't focused on.
        if let id = activity.latestEvent?.bundleID, transientBundleIDs.contains(id) {
            lastTickResult = .skippedTransient
            return
        }

        // Same-context guard: if the user is still on the exact same app + window + URL we
        // commented on within the last couple of hours, skip. Saves the user from a stream of
        // "you're still on slide 4" / "still looking at slide 4" / "now seeing slide 4 for the
        // sixth time" observations that the model produces because the situation hasn't
        // changed but it's been told to comment. The suppression window expires so we'll
        // eventually fire again on a stretch that genuinely has lasted hours — that itself is
        // worth a remark.
        if let last = lastCommentContext,
           let current = activity.latestEvent,
           !forceFire,
           Date().timeIntervalSince(last.at) < sameContextSuppressionWindow,
           last.appName == current.appName,
           last.windowTitle == current.windowTitle,
           last.tabURL == current.tabURL {
            lastTickResult = .skippedSameContext
            return
        }

        let context = InsightsContextBuilder.build(activity: activity, calendar: calendar)
        // Skip if we have no useful context — a "??" comment would feel random.
        guard !context.isEmpty else {
            lastTickResult = .skippedNoContext
            return
        }

        let personality = settings.insightsPersonality
        // Pick a structural directive at random so the model can't lock into one scaffold across
        // turns. Without this the personality voice tends to find a comfortable shape (e.g., "X
        // is a Y, Y is a Z. What's the W doin' to the Z?") and mass-produce variants of it.
        let directive = structuralDirectives.randomElement() ?? structuralDirectives[0]
        let observation = """
        You are observing the user's desktop activity and offering an unsolicited remark in \
        your voice. Don't greet, preface, or introduce yourself. The universal + commentary \
        rules above govern when to speak vs. stay silent ("-").

        SHAPE FOR THIS TURN: \(directive)

        \(context)
        """
        // Autonomous remark path — apply commentary rules (short, varied, may be silent) on
        // top of the universal rules.
        let systemPrompt = buildInsightsSystemPrompt(
            personality: personality,
            mode: .commentary,
            observationContext: observation
        )

        // History strategy: send a longer tail than before so user corrections and context
        // notes ("she's sick, not going to class") survive into the prompt. Truncation was
        // dropping those, leading to the commentator re-running canned riffs about already-
        // corrected calendar items. The anti-repetition pressure from echoing one's own
        // style is now handled in the prompt rules above (anti-pattern + self-coverage).
        // Commentator only looks at TODAY'S history — autonomous remarks shouldn't reference
        // older threads. Each message gets a timestamp prefix so the model can ground its
        // reasoning ("you said X earlier this morning") in real times. Conversational chat
        // path uses the full transcript instead.
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let todayMessages = chat.messages.filter { msg in
            guard let ts = msg.timestamp else { return false }
            return ts >= startOfDay
        }
        var payload: [OllamaClient.ChatMessage] = [
            OllamaClient.ChatMessage(role: .system, content: systemPrompt)
        ]
        payload.append(contentsOf: todayMessages.map { $0.withTimestampPrefix() })
        payload.append(OllamaClient.ChatMessage(role: .user, content: "Say something."))

        do {
            let reply = try await OllamaClient.chat(
                baseURL: settings.ollamaURL,
                model: settings.ollamaModel,
                history: payload
            )
            // The observation prompt asks the model to emit a lone "-" only when it would
            // otherwise be exactly repeating itself. Drop that sentinel; everything else lands —
            // including very short or oddly-formatted replies, since silently swallowing those
            // is what made the commentator look broken.
            let cleaned = reply.strippingSurroundingQuotes()
            if cleaned == "-" {
                lastTickResult = .modelSentinel
                return
            }
            guard !cleaned.isEmpty else {
                lastTickResult = .modelEmpty
                return
            }
            chat.appendAssistant(cleaned)
            lastCommentAt = Date()
            // Snapshot the context so the same-context guard above can recognize "still on
            // the same thing" on the next tick.
            if let current = activity.latestEvent {
                lastCommentContext = LastCommentContext(
                    appName: current.appName,
                    windowTitle: current.windowTitle,
                    tabURL: current.tabURL,
                    at: Date()
                )
            }
            lastTickResult = .fired
        } catch {
            // Autonomous — never surface errors to the user, but record the result for the
            // diagnostic readout in Settings so silence isn't mysterious.
            lastTickResult = .modelError
        }
    }

}
