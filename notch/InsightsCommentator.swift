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
        case modelEmpty = "Model returned empty"
        case modelSentinel = "Model said -"
        case modelError = "Model errored"
    }

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

        Comment on what is happening NOW — i.e., the "Currently in focus" block below. Do not riff \
        on items under "Earlier today" as if they were still on screen; those apps may be closed.

        Only return the single character "-" (and nothing else) if you would otherwise be exactly \
        repeating a previous turn. Otherwise, say something.

        \(context)
        """
        let systemPrompt = buildInsightsSystemPrompt(
            personality: personality,
            observationContext: observation
        )

        // Send the model only its last few turns. Sending the full transcript made the model
        // *more* repetitive, not less — it pattern-matches on its own dominant style across many
        // turns and reproduces it. A short tail is enough to anchor against immediate echoes
        // without giving it a self-trained voice template to riff on.
        let recentTail = Array(chat.messages.suffix(8))
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
            lastTickResult = .fired
        } catch {
            // Autonomous — never surface errors to the user, but record the result for the
            // diagnostic readout in Settings so silence isn't mysterious.
            lastTickResult = .modelError
        }
    }

}
