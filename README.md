# NotchNik

A macOS utility that lives in (and around) the hardware notch on MacBook Pros. Hover the notch and it swells; click it and a panel drops down with a clipboard history, a calendar agenda, a file-parking pen, and an AI chat that watches what you're doing and scores your focus.

> **This codebase is entirely vibe-coded.** Written interactively with an LLM doing most of the typing across many sessions, with the human steering, vetoing, and shaping intent. There's no architectural master plan; pieces accreted as ideas came up. Treat it as such — the code style is consistent within a session and drifts across sessions, comments explain *why* things landed where they did rather than what the code is doing, and a fair amount of design rationale lives in commit-style review rather than design docs.

## What it does

Four sections live in the panel, each toggleable in Settings:

- **Clipboard** — captures everything you copy (text, images, file references). Click to put back on the pasteboard, drag out to use, Quick Look previews for files. Configurable history depth.
- **Calendar** — subscribes to ICS feeds (Google Calendar links, iCloud shares, etc.). Two views: time-block grid or flat agenda. Color-coded per feed. RRULE expansion for recurring events.
- **File Pen** — drag any file in to park it. Drag back out (with optional ⌘ for move vs. copy). Survives launches via security-scoped bookmarks. Useful for "I need this in fifteen minutes when I'm in a different app."
- **Insights** — chat with a local [Ollama](https://ollama.com) model. The model gets context about what you're currently doing, what's on your calendar, and recent activity. Includes a focus-score system (per-hour 0–100, rolling history with day/week/month views, AI commentary in your chosen personality voice).

## Insights, in more detail

The Insights side is the largest and most opinionated piece, so a few notes:

- **Activity capture.** A polling watcher samples the frontmost app + window title + (for supported browsers) active tab every 30 seconds. Idle time comes from `CGEventSource.secondsSinceLastEventType` so locked screens and AFK stretches don't inflate "focus time."
- **Privacy.** Private/incognito browser windows are detected and the URL/title are dropped before the event lands in the activity log. The log itself can be pruned automatically (configurable retention) and viewed/cleared in Settings.
- **Focus scoring.** Each hour gets a 0–100 score. Deterministic baseline from streak length, context-switch rate, and distinct-context count. Optional AI refinement layered on top — the model sees the baseline, per-app/per-domain time, calendar events overlapping the hour, and category info, and returns an adjusted score plus a one-line commentary in your chosen personality voice.
- **Categories.** Apps and domains can be categorized (coding, comms, design, social, entertainment, etc.) so the AI knows that an uninterrupted hour of solitaire isn't a 90 even if the streak math says it is. Categories come from three sources: built-in seeds for common apps/domains, AI-batched guesses for unknowns, and conversational asking when something genuinely ambiguous shows up.
- **History.** Per-day JSON shards on disk. Browseable in the focus panel: Now, Day (24-hour bar chart), Week (7-day chart), Month (calendar grid of donuts), Insights (range stats + AI summary).
- **Personalities.** Off-the-shelf, Offbeat (Bob Dylan-esque wandering hippie philosopher), Off the rails (Heath Ledger Joker), Off-putting (sarcastic jaded roaster), Corner Office (corporate jargon turned to 11). Affects every assistant message and the focus-score commentary.

## Requirements

- macOS Sequoia 15+ (uses `Settings` scene + recent SwiftUI APIs).
- A MacBook Pro with a hardware notch, ideally — though the panel still works on non-notch Macs, it just sits against the menu bar instead of around a physical cutout.
- For Insights features: an [Ollama](https://ollama.com) instance running locally. Tested against Qwen 2.5 14B, Llama 3.1 8B, and Mistral Nemo 12B. Smaller models work but follow structural prompt directives less reliably.
- For browser tab/URL capture: macOS Automation permission per browser. The Settings → Insights tab has a one-click "Authorize all running browsers" helper.
- For activity capture: macOS Accessibility permission. Same tab.

## Building from source

1. Clone this repo.
2. Open `notch.xcodeproj` in Xcode.
3. Select the `notch` target. In Signing & Capabilities, choose your team. For local development, the personal team and "Apple Development" cert are fine.
4. **⌘R** to run.

For distribution-ready builds (notarized DMG):

1. Apple Developer Program membership ($99/year) for the `Developer ID Application` cert.
2. Product → Archive.
3. Organizer → Distribute App → Direct Distribution → upload to Apple's notary service.
4. After "Notarized" status, Export → ship the resulting `.app` (zipped or wrapped in a DMG).

The project ships with App Sandbox + Hardened Runtime enabled. Entitlements include `network.client` (for Ollama HTTP), `files.user-selected.read-write` (for File Pen), `files.bookmarks.app-scope` (security-scoped bookmarks), `automation.apple-events` (browser tab fetching), and a `temporary-exception.apple-events` array listing the supported browser bundle IDs.

## Privacy

- All AI processing is local via Ollama. Nothing leaves your Mac.
- Activity data lives in `~/Library/Application Support/NotchNik/`. Activity log, focus history, clipboard history, file pen, and chat transcript are stored as JSON in that directory.
- Private/incognito browser windows are redacted at capture time — the activity log records "you were in Chrome" but not which page.
- Calendar events come straight from your subscribed ICS feeds.
- Settings → Insights has a "Clear Log" and the Focus panel has a "Wipe & rebuild" if you want to reset state.

## Configuration

Open Settings (gear icon, or ⌘,):

- **General** — launch at login, tools visible/order, default-on-open section.
- **Clipboard** — max items kept.
- **Calendar** — add/edit/remove ICS feeds.
- **File Pen** — drag actions (default vs. ⌘ modifier).
- **Insights** — Ollama URL/model, personality voice, periodic commentary toggle, accessibility permission, activity log retention, app/domain categories, history maintenance.

## Architecture notes for the curious

- **Panel chrome.** A borderless `NSPanel` anchored to the screen's top-center, sized larger than the visible notch silhouette so the swell can extend left/right and the rounded "lip" can render past the menu bar. Hover swell and click expand are SwiftUI-driven; the AppKit window animates its frame in lockstep with the SwiftUI animation timing.
- **The notch silhouette.** Custom `Shape` that draws a flat top with rounded bottom corners (collapsed) or a swollen pill (hover) or a full rounded rectangle (expanded). Drop shadow rendered carefully so it doesn't get clipped by the menu bar.
- **Section carousel.** A `PanelSection` enum + user-customizable visibility/order. Horizontal swipes (trackpad or click-drag) move between sections. Each section is its own SwiftUI view.
- **Stores.** Each domain has a `*Store` ObservableObject — `ClipboardHistoryStore`, `CalendarFeedStore`, `FilePenStore`, `ActivityWatcher`, `InsightsChatStore`, `FocusScoreEngine`, `FocusHistoryStore`. AppDelegate constructs them lazily and injects via SwiftUI environment.
- **Persistence.** Per-domain JSON files in `~/Library/Application Support/NotchNik/`. `UserDefaults` for settings.
- **Browser tab fetching.** `NSAppleScript` per supported browser (Safari, Chrome and forks, Arc, Dia). Each browser asks for Automation permission the first time it's scripted. `loginwindow` and private windows get filtered or redacted before events land.

## Acknowledgments

NotchNik was built on top of:

- [Ollama](https://ollama.com) for local LLM inference.
- The Quick Look framework for clipboard and file previews.
- ICS / iCalendar parsing built from scratch (RFC 5545, with RRULE expansion).

## License

MIT.
