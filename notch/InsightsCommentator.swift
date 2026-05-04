//
//  InsightsCommentator.swift
//  notch
//
//  Periodic, opt-in autonomous commentary. Every few minutes the timer fires; with 60% probability
//  it asks the configured Ollama model to make a brief, in-personality remark about what the user
//  is currently doing and what's on their calendar. Comments are appended to the Insights chat
//  transcript as assistant messages.
//

import Combine
import Foundation

@MainActor
final class InsightsCommentator: ObservableObject {
    /// How often the timer ticks. Each tick is independent: 60% chance to fire, 40% to skip.
    private let tickInterval: TimeInterval = 5 * 60   // 5 minutes
    /// Probability of producing a comment on each tick.
    private let triggerProbability: Double = 0.60
    /// Idle threshold for "user is gone, don't comment." Was 5 min, which silenced the bot any
    /// time the user paused to read or think. 15 min is a more honest "they walked away" line.
    private let afkIdleThreshold: TimeInterval = 15 * 60

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
        case modelEmpty = "Model returned empty"
        case modelSentinel = "Model said -"
        case modelError = "Model errored"
    }

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
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
        // Forced ticks bypass the enable/AFK/probability gates; otherwise honor them.
        if !forceFire {
            guard settings.insightsCommentaryEnabled else {
                lastTickResult = .skippedDisabled
                return
            }
            // AFK guard: if the user hasn't touched mouse/keyboard in 15+ minutes, treat them as
            // walked-away. Lower thresholds silenced the bot during normal reading/thinking.
            if let idle = activity.latestEvent?.idleSecondsAtCapture, idle >= afkIdleThreshold {
                lastTickResult = .skippedAFK
                return
            }
            guard Double.random(in: 0..<1) < triggerProbability else {
                lastTickResult = .skippedDice
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
        You are observing the user's desktop activity and offering an unsolicited remark in your voice. \
        Don't greet, preface, introduce yourself, or mention that you're commenting automatically. \
        You should produce a remark on most ticks — silence is rarely the right call.

        SHAPE FOR THIS TURN: \(directive)

        Anti-pattern rules (these matter — read your previous assistant turns above and check):
        - Do NOT end with a rhetorical question if you've ended with one in your last 3 turns.
        - Do NOT use "X is a Y, the Y is a Z" metaphor scaffolds.
        - Do NOT reuse signature phrases from earlier turns ("the heat doin' to the beans", \
        "the screen's a hearth", named slides, named documents, etc.).
        - Vary sentence length and opening word from your previous turns.

        Self-coverage rule: scan your own previous assistant turns above. If you have already \
        commented (even once) on whatever is currently in focus — same app, same window, same \
        tab/URL — do NOT comment on it again, even with different phrasing. The user has \
        already read those comments; repeating yourself creatively is worse than silence. \
        Exceptions: a calendar event has just begun or ended (genuinely new context), or the \
        user has been at this so long that the duration itself is the new observation. \
        Otherwise, return "-" alone and stay silent.

        ABSOLUTE USER OVERRIDE — read carefully. Before composing this turn:

        1. Scan EVERY user message above (not just the most recent — ALL of them).
        2. For each calendar event listed in "Calendar context" below, and for each app/site \
        listed in the focus or earlier-today blocks, ask: has the user said anything about it?
        3. If the user has clarified, corrected, or contextualized any item — even casually \
        ("that's my kid's class", "she's home sick", "this isn't mine", "just helping a friend", \
        "ignore that meeting") — that clarification is BINDING and PERMANENT for the rest of \
        the conversation. The user is ground truth; the calendar and activity data are not.
        4. NEVER mention an item the user has already spoken about. Don't re-raise it, don't \
        reference it indirectly, don't ask about it. Move on to something the user has NOT \
        commented on, or stay silent.

        Concrete: if the user said "Anna's home sick, she didn't go to dance class" and the \
        calendar shows "Dance class IN PROGRESS," DO NOT mention dance class. The user has \
        already settled what's happening with that block.

        Comment on what is happening NOW. Three signals to integrate, in priority order:

        1. CALENDAR. When a calendar event is IN PROGRESS, the user is in that meeting / block, \
        and whatever app is frontmost is being used in service of it. Comment on the meeting and \
        how the activity fits its purpose, not on the literal app. ("Running point on the slides \
        for the council session" beats "you're staring at slide 4 again.")

        2. IDLE. The "Idle (no input): X min" line is real — the user hasn't touched the \
        keyboard or trackpad in X minutes. Interpret it like this:
           - 0–2 min idle: actively engaged with the surface app. Comment on the activity.
           - 3–8 min idle: reading, thinking, on a brief break, or in a meeting listening. \
           Don't assume active engagement. If a calendar event is in progress, comment on the \
           meeting; if not, the comment can acknowledge the pause ("standing back from X").
           - 9–15 min idle: user may have stepped away. Don't claim they're "doing" anything \
           on screen. If a calendar event is in progress, treat as in-meeting and not at the \
           keyboard. If not, the comment should reflect "stepped away" honestly, not project \
           activity onto the frozen screen.
           (You won't see >15 min idle here — the system suppresses commentary above that.)

        3. SURFACE APP. Use what's frontmost only after considering the above. The app is the \
        weakest of the three signals on its own.

        Do not riff on items under "Earlier today" as if they were still on screen; those apps \
        may be closed.

        FINAL CHECK before responding: re-read the user's most recent few messages one more \
        time. If anything you were about to say touches on a calendar event, app, or topic the \
        user has already addressed — drop it. Pick something fresh, or return "-" alone.

        Only return the single character "-" (and nothing else) if you would otherwise be exactly \
        repeating a previous turn. Otherwise, say something.

        \(context)
        """
        let systemPrompt = buildInsightsSystemPrompt(
            personality: personality,
            observationContext: observation
        )

        // History strategy: send a longer tail than before so user corrections and context
        // notes ("she's sick, not going to class") survive into the prompt. Truncation was
        // dropping those, leading to the commentator re-running canned riffs about already-
        // corrected calendar items. The anti-repetition pressure from echoing one's own
        // style is now handled in the prompt rules above (anti-pattern + self-coverage).
        let recentTail = Array(chat.messages.suffix(40))
        var payload: [OllamaClient.ChatMessage] = [
            OllamaClient.ChatMessage(role: .system, content: systemPrompt)
        ]
        payload.append(contentsOf: recentTail)
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
