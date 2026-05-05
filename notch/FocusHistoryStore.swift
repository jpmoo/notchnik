//
//  FocusHistoryStore.swift
//  notch
//
//  Per-day persistence of `FocusScore` entries. The engine writes into this on every successful
//  recompute; the UI reads by date or range. Sharded by local-timezone day so loading a month or
//  a year doesn't require pulling everything off disk into memory at once.
//
//  Storage layout: ~/Library/Application Support/NotchNik/focus_history/YYYY-MM-DD.json
//  Each file is a JSON array of `FocusScore`, sorted by `windowEnd`. Replace-by-hour-of-day is
//  enforced on write so a manual recompute overwrites the slot for that hour rather than
//  duplicating it.
//

import Combine
import Foundation

@MainActor
final class FocusHistoryStore: ObservableObject {
    /// Set of YYYY-MM-DD strings for which we have at least one entry. The Month view reads this
    /// to color-code days that have data vs. blank days. Stored as strings so `Set` membership
    /// checks don't depend on `DateComponents` equality semantics.
    @Published private(set) var availableDayKeys: Set<String> = []
    /// Bumps on every `record(_:)` call, regardless of whether the day key already existed.
    /// Views observing this store re-render when this changes; without it, second/third
    /// recomputes on the same day silently fail to refresh aggregations downstream.
    @Published private(set) var revision: Int = 0

    private let folderURL: URL
    private let calendar: Calendar
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        folderURL = base.appendingPathComponent("NotchNik", isDirectory: true)
            .appendingPathComponent("focus_history", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        rescanAvailableDates()
    }

    // MARK: - Public API

    /// Append-or-replace a score by its hour-of-day, keyed by `windowStart` hour. So an entry
    /// covering 6:00–7:00 PM has key 18 — matching the natural "this is the 6 PM hour" mental
    /// model. (Previously keyed by `windowEnd` hour, which put the 6–7 PM entry at key 19,
    /// causing a perceived off-by-one in the bar chart.) Two computes for the same clock hour
    /// collapse to the most recent.
    func record(_ score: FocusScore) {
        let key = dayKey(for: score.windowStart)
        var entries = loadEntries(forDayKey: key)
        let hour = calendar.component(.hour, from: score.windowStart)
        if let idx = entries.firstIndex(where: { calendar.component(.hour, from: $0.windowStart) == hour }) {
            entries[idx] = score
        } else {
            entries.append(score)
        }
        entries.sort { $0.windowEnd < $1.windowEnd }
        save(entries: entries, dayKey: key)
        // Bump the revision counter on EVERY record so observers re-render even when the day key
        // is already in the set (i.e., the second/third recompute on the same day). Without this
        // bump, `availableDayKeys` only mutates on first-of-day, so the Insights stats card
        // would render against stale data.
        revision &+= 1
        if !availableDayKeys.contains(key) {
            availableDayKeys.insert(key)
        }
    }

    /// All entries for a given local-day. Empty if we have nothing for that day.
    func entries(for date: Date) -> [FocusScore] {
        loadEntries(forDayKey: dayKey(for: date))
    }

    /// All entries whose `windowEnd` falls within [start, end). Used by the Month view and the
    /// AI insights range summary. Loads each intersecting day file in turn — cheap for ranges
    /// up to a year.
    func entries(in range: DateInterval) -> [FocusScore] {
        var result: [FocusScore] = []
        var cursor = calendar.startOfDay(for: range.start)
        let stop = range.end
        while cursor < stop {
            let dayEntries = loadEntries(forDayKey: dayKey(for: cursor))
            result.append(contentsOf: dayEntries.filter { range.contains($0.windowEnd) })
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Convenience wrapper for "the calendar month containing this date." Used by the Month view
    /// to populate per-day donut averages.
    func entries(forMonthContaining date: Date) -> [FocusScore] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        return entries(in: interval)
    }

    /// Most recent persisted entry across all day files, by `windowEnd`. Walks days from today
    /// backward until it finds one with entries. Used as the "catch up since here" anchor for
    /// the backfill / wake-from-sleep path.
    func mostRecentEntry() -> FocusScore? {
        var dayCursor = Date()
        // Walk back at most 60 days. If history is sparser than that, the user almost
        // certainly doesn't care about reconstruction here; backfill will fall back to
        // scanning from the earliest activity event.
        for _ in 0..<60 {
            let entries = self.entries(for: dayCursor)
            if let latest = entries.max(by: { $0.windowEnd < $1.windowEnd }) {
                return latest
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: dayCursor) else { return nil }
            dayCursor = prev
        }
        return nil
    }

    /// Scans the last `daysBack` days of history for top-app entries that have no category
    /// assigned. Returns two lists (apps, domains), each sorted desc by total minutes seen.
    /// Used by Settings → Insights to nudge the user about apps/domains that have shown up
    /// with significant time but the conversational categorizer hasn't filed yet (because the
    /// user didn't answer the prompt, or because the entries are from before categorization
    /// was wired up).
    ///
    /// Distinguishing apps from domains uses the heuristic that domain rows have a `bundleID`
    /// containing a dot but no app-style identifier — i.e., `topApps` substituted them in via
    /// `WindowSummary.topApps(in:)`. Apps' bundleIDs always contain a dot too; we lean on the
    /// fact that `appName` for a domain row equals its host (e.g., `gmail.com`), which we can
    /// detect because it matches the bundleID. Imperfect but correct in practice.
    func uncategorizedItems(daysBack: Int, settings: AppSettingsStore) -> (apps: [(name: String, bundleID: String, minutes: Int)], domains: [(host: String, minutes: Int)]) {
        let now = Date()
        let cal = calendar
        guard let earliest = cal.date(byAdding: .day, value: -daysBack, to: now) else {
            return (apps: [], domains: [])
        }
        let entries = self.entries(in: DateInterval(start: earliest, end: now))

        var appMinutes: [String: (name: String, minutes: Int)] = [:]   // keyed by bundleID
        var domainMinutes: [String: Int] = [:]                          // keyed by host

        for entry in entries {
            for app in entry.topApps {
                guard let key = app.bundleID, !key.isEmpty else { continue }
                // Domain rows have appName == bundleID == host. App rows have a normal name.
                let isDomainRow = (app.appName == key) && key.contains(".")
                if isDomainRow {
                    if settings.domainCategories[key] == nil {
                        domainMinutes[key, default: 0] += app.minutes
                    }
                } else {
                    // Skip hard-ignored bundle IDs (loginwindow et al.) — they should never be
                    // surfaced as "needs a category" or asked about.
                    if AppSettingsStore.isIgnoredBundleID(key) { continue }
                    if settings.appCategories[key] == nil {
                        let prev = appMinutes[key]?.minutes ?? 0
                        appMinutes[key] = (name: app.appName, minutes: prev + app.minutes)
                    }
                }
            }
        }

        let appList = appMinutes
            .map { (name: $0.value.name, bundleID: $0.key, minutes: $0.value.minutes) }
            .sorted { $0.minutes > $1.minutes }
        let domainList = domainMinutes
            .map { (host: $0.key, minutes: $0.value) }
            .sorted { $0.minutes > $1.minutes }

        return (apps: appList, domains: domainList)
    }

    /// Removes a single entry whose `windowEnd`'s hour-of-day matches `hour` from the day file
    /// for `date`. Used by the rescore path when the activity log no longer has anything to
    /// score for that hour (e.g., the only events were loginwindow and got filtered out).
    /// Silent no-op when no matching entry exists.
    func deleteEntry(forDate date: Date, hour: Int) {
        let key = dayKey(for: date)
        var entries = loadEntries(forDayKey: key)
        let originalCount = entries.count
        // Match by windowStart hour for consistency with `record(_:)` keying.
        entries.removeAll { calendar.component(.hour, from: $0.windowStart) == hour }
        guard entries.count != originalCount else { return }
        if entries.isEmpty {
            // Strip the now-empty day file rather than leaving a `[]` shell behind.
            try? FileManager.default.removeItem(at: fileURL(forDayKey: key))
            availableDayKeys.remove(key)
        } else {
            save(entries: entries, dayKey: key)
        }
        revision &+= 1
    }

    /// Wipes every persisted day file. Called by the "nuclear" rescore path before backfill
    /// re-creates entries from the activity log. Errors are swallowed — partial wipe still
    /// leads to a clean recompute since record() last-write-wins.
    func deleteAllEntries() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
        availableDayKeys.removeAll()
        revision &+= 1
    }

    // MARK: - Aggregations

    /// Mean of `value` across all entries for a day. Nil if the day has no entries — callers
    /// distinguish "0 score" from "no data" themselves.
    func dailyAverage(for date: Date) -> Double? {
        let entries = self.entries(for: date)
        guard !entries.isEmpty else { return nil }
        let sum = entries.reduce(0) { $0 + $1.value }
        return Double(sum) / Double(entries.count)
    }

    /// Per-day averages for the calendar week containing `date`, keyed by start-of-day Date.
    /// Used by the Week tab to populate its 7-bar chart and to compute the week-aggregate stats
    /// without re-scanning history multiple times.
    func dailyAverages(forWeekContaining date: Date) -> [Date: Int] {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [:] }
        let entries = self.entries(in: weekInterval)
        var byDay: [Date: [Int]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.windowEnd)
            byDay[day, default: []].append(entry.value)
        }
        return byDay.mapValues { vals in
            Int((Double(vals.reduce(0, +)) / Double(vals.count)).rounded())
        }
    }

    /// One-shot aggregation over a range. Returns nil when the range has zero entries — the
    /// caller can render a "no data" state instead of a blank stats card. Used by the Insights
    /// tab to populate the stats panel and to feed the AI summary prompt.
    ///
    /// Granularity for best/worst sub-unit is auto-picked from the range duration: ≤36h reports
    /// hourly best/worst; ≤14d reports daily; longer reports weekly. Callers can rely on the
    /// `granularity` field on the result to label the chips appropriately.
    func stats(in range: DateInterval) -> RangeStats? {
        let entries = self.entries(in: range)
        guard !entries.isEmpty else { return nil }
        let cal = calendar

        // Choose granularity by range duration.
        let granularity: RangeStats.Granularity = {
            let hours = range.duration / 3600
            if hours <= 36 { return .hour }
            if hours <= 14 * 24 { return .day }
            return .week
        }()

        // Per-day averages — used by `dayCount` and the .day case below.
        var byDay: [Date: [Int]] = [:]
        for e in entries {
            let day = cal.startOfDay(for: e.windowEnd)
            byDay[day, default: []].append(e.value)
        }
        let dayAvgs: [Date: Int] = byDay.mapValues { vals in
            Int((Double(vals.reduce(0, +)) / Double(vals.count)).rounded())
        }
        let avgScore = Int((Double(entries.reduce(0) { $0 + $1.value }) / Double(entries.count)).rounded())

        // Per-app and per-category totals; per-hour score lists; per-hour active/idle for the
        // mostly-idle classification.
        var activeTotal = 0
        var idleTotal = 0
        var byCategory: [String: Int] = [:]
        var byHourScores: [Int: [Int]] = [:]
        var byHourActiveMin: [Int: [Int]] = [:]
        var byHourIdleMin: [Int: [Int]] = [:]
        for entry in entries {
            var entryActive = 0
            for app in entry.topApps {
                activeTotal += app.minutes
                entryActive += app.minutes
                if let cat = app.category, !cat.isEmpty {
                    byCategory[cat, default: 0] += app.minutes
                }
            }
            let entryIdle = entry.idleMinutes ?? 0
            idleTotal += entryIdle
            // Hour-of-day for stats grouping uses windowStart, matching record/display.
            let h = cal.component(.hour, from: entry.windowStart)
            byHourScores[h, default: []].append(entry.value)
            byHourActiveMin[h, default: []].append(entryActive)
            byHourIdleMin[h, default: []].append(entryIdle)
        }
        let topCategories = byCategory
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { RangeStats.CategoryTotal(name: $0.key, minutes: $0.value) }

        let hourAvgs: [Int: Int] = byHourScores.mapValues { vals in
            Int((Double(vals.reduce(0, +)) / Double(vals.count)).rounded())
        }
        let peakHours = hourAvgs.filter { $0.value >= avgScore + 10 }.keys.sorted()
        let sleepHours = hourAvgs.filter { $0.value <= avgScore - 10 }.keys.sorted()

        // Mostly-idle hours: where avg idle minutes exceed avg active minutes for that hour.
        // Hours with no data don't appear here (they're in `emptyHours`).
        var mostlyIdleHours: [Int] = []
        for h in 0..<24 {
            guard let actives = byHourActiveMin[h], let idles = byHourIdleMin[h], !actives.isEmpty else { continue }
            let avgActive = Double(actives.reduce(0, +)) / Double(actives.count)
            let avgIdle = Double(idles.reduce(0, +)) / Double(idles.count)
            if avgIdle > avgActive {
                mostlyIdleHours.append(h)
            }
        }

        // Empty hours: only meaningful when the range covers an entire day. For shorter ranges
        // (e.g., "Today" mid-afternoon), hours-of-day after `now` aren't really "empty" — they
        // haven't happened yet. Clip the empty set to the actual covered range.
        let firstHour = cal.component(.hour, from: range.start)
        let lastHour = cal.component(.hour, from: min(range.end, Date()))
        let coveredHours: Set<Int>
        if range.duration >= 24 * 3600 {
            coveredHours = Set(0..<24)
        } else if firstHour <= lastHour {
            coveredHours = Set(firstHour...lastHour)
        } else {
            coveredHours = Set(firstHour..<24).union(0...lastHour)
        }
        let emptyHours = coveredHours.subtracting(byHourScores.keys).sorted()

        // Best / worst sub-unit at the granularity we picked.
        let bestUnit: RangeStats.UnitStat?
        let worstUnit: RangeStats.UnitStat?
        switch granularity {
        case .hour:
            // Each entry IS an hourly score. Best/worst = max/min by value.
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "h:mm a"
            let best = entries.max { $0.value < $1.value }
            let worst = entries.min { $0.value < $1.value }
            bestUnit = best.map {
                RangeStats.UnitStat(label: timeFmt.string(from: $0.windowStart), avg: $0.value, date: $0.windowEnd)
            }
            worstUnit = worst.map {
                RangeStats.UnitStat(label: timeFmt.string(from: $0.windowStart), avg: $0.value, date: $0.windowEnd)
            }

        case .day:
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "EEE, MMM d"
            let best = dayAvgs.max { $0.value < $1.value }
            let worst = dayAvgs.min { $0.value < $1.value }
            bestUnit = best.map {
                RangeStats.UnitStat(label: dayFmt.string(from: $0.key), avg: $0.value, date: $0.key)
            }
            worstUnit = worst.map {
                RangeStats.UnitStat(label: dayFmt.string(from: $0.key), avg: $0.value, date: $0.key)
            }

        case .week:
            // Group hourly entries by their containing local-week (Sun→Sat per the user's calendar).
            var byWeek: [Date: [Int]] = [:]
            for entry in entries {
                guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: entry.windowEnd) else { continue }
                byWeek[weekInterval.start, default: []].append(entry.value)
            }
            let weekAvgs: [Date: Int] = byWeek.mapValues { vals in
                Int((Double(vals.reduce(0, +)) / Double(vals.count)).rounded())
            }
            let weekFmt = DateFormatter()
            weekFmt.dateFormat = "MMM d"
            let best = weekAvgs.max { $0.value < $1.value }
            let worst = weekAvgs.min { $0.value < $1.value }
            bestUnit = best.map { (start, avg) in
                let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
                return RangeStats.UnitStat(
                    label: "\(weekFmt.string(from: start))–\(weekFmt.string(from: end))",
                    avg: avg,
                    date: start
                )
            }
            worstUnit = worst.map { (start, avg) in
                let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
                return RangeStats.UnitStat(
                    label: "\(weekFmt.string(from: start))–\(weekFmt.string(from: end))",
                    avg: avg,
                    date: start
                )
            }
        }

        return RangeStats(
            range: range,
            granularity: granularity,
            dayCount: dayAvgs.count,
            entryCount: entries.count,
            averageScore: avgScore,
            bestUnit: bestUnit,
            worstUnit: worstUnit,
            totalActiveMinutes: activeTotal,
            totalIdleMinutes: idleTotal,
            topCategories: topCategories,
            peakHours: peakHours,
            sleepHours: sleepHours,
            mostlyIdleHours: mostlyIdleHours,
            emptyHours: emptyHours
        )
    }

    // MARK: - Internals

    private func dayKey(for date: Date) -> String {
        Self.dayKeyFormatter.string(from: date)
    }

    private func fileURL(forDayKey key: String) -> URL {
        folderURL.appendingPathComponent("\(key).json")
    }

    private func loadEntries(forDayKey key: String) -> [FocusScore] {
        let url = fileURL(forDayKey: key)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([FocusScore].self, from: data) else { return [] }
        // Belt-and-suspenders cleanup: strip any persisted `topApps` rows that reference
        // loginwindow (which we now filter out at activity-capture time but old persisted
        // FocusScore entries may still mention). The score number itself stays as-is — it
        // was computed under the old rules — but the surfaced top-apps list won't show
        // garbage. A real re-score (manual button or staleness check) will recompute the
        // score too.
        let cleaned = stored.map { entry -> FocusScore in
            let filtered = entry.topApps.filter { row in
                let bundleMatches = row.bundleID?.lowercased().hasPrefix("com.apple.loginwindow") ?? false
                let nameMatches = row.appName.lowercased().contains("loginwindow")
                return !bundleMatches && !nameMatches
            }
            if filtered.count == entry.topApps.count { return entry }
            var copy = entry
            copy.topApps = filtered
            return copy
        }
        // Drop entries whose windowStart isn't on a clock-hour boundary — leftovers from the
        // rolling-60-minute-window era. The new live path always writes hour-aligned windows;
        // any unaligned entry is by definition stale and will get re-created on the next
        // backfill / pill click using the current alignment policy.
        let aligned = cleaned.filter { entry in
            let comps = calendar.dateComponents([.minute, .second], from: entry.windowStart)
            return comps.minute == 0 && comps.second == 0
        }
        if aligned.count != cleaned.count {
            // Resave the trimmed list so we don't reload the misaligned entries each launch.
            save(entries: aligned, dayKey: key)
        }
        return aligned
    }

    private func save(entries: [FocusScore], dayKey: String) {
        let url = fileURL(forDayKey: dayKey)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Walk the folder once at init so the Month view knows which days to highlight without
    /// having to load every file. Files are tiny so this is fast even with years of history.
    private func rescanAvailableDates() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        var keys: Set<String> = []
        for url in contents where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            // Validate format so a stray file doesn't bloat the set.
            if Self.dayKeyFormatter.date(from: stem) != nil {
                keys.insert(stem)
            }
        }
        availableDayKeys = keys
    }
}

/// Format a 0–23 hour-of-day as a 12-hour clock string ("9 AM", "12 PM", "11 PM"). Shared by
/// every place hours of day are rendered to the user — chips, tooltips, AI prompt digests —
/// so the convention is consistent.
func formatHour12(_ hour: Int) -> String {
    if hour == 0 { return "12 AM" }
    if hour < 12 { return "\(hour) AM" }
    if hour == 12 { return "12 PM" }
    return "\(hour - 12) PM"
}

/// Aggregations over a date range. `Equatable` because the Insights tab caches the AI summary
/// keyed by the stats it was computed from — re-asking with the same numbers is wasted tokens.
struct RangeStats: Equatable {
    /// What "best" and "worst" are measured at — chosen automatically from the range size.
    /// A single day uses `hour` (find the best/worst hour); a week uses `day` (best/worst daily
    /// average); anything longer uses `week`. Lets every tab show hierarchical low/high callouts
    /// against the appropriate sub-unit.
    enum Granularity: String, Equatable {
        case hour
        case day
        case week

        var label: String {
            switch self {
            case .hour: return "hour"
            case .day:  return "day"
            case .week: return "week"
            }
        }
    }

    /// One sub-unit's summary — used for both the best and worst slots.
    struct UnitStat: Equatable {
        /// Human-readable label, e.g. "9:00 AM", "Tue, May 5", or "May 5–11".
        let label: String
        /// Either an hourly score (granularity = .hour) or a unit average (.day / .week).
        let avg: Int
        /// Anchor date so callers can drill into the matching Day/Week view from a click.
        let date: Date
    }

    struct CategoryTotal: Equatable { let name: String; let minutes: Int }

    let range: DateInterval
    let granularity: Granularity
    let dayCount: Int
    let entryCount: Int
    let averageScore: Int
    let bestUnit: UnitStat?
    let worstUnit: UnitStat?
    let totalActiveMinutes: Int
    let totalIdleMinutes: Int
    let topCategories: [CategoryTotal]
    /// Hours of day (0-23, local) whose mean score is materially above the range mean.
    let peakHours: [Int]
    /// Hours of day whose mean score is materially below the range mean.
    let sleepHours: [Int]
    /// Hours of day where the average idle minutes exceeded the average active minutes —
    /// stretches the user was logged in but mostly AFK. Distinct from sleepHours (which is
    /// score-based and excludes empty hours).
    let mostlyIdleHours: [Int]
    /// Hours of day with NO scored entries anywhere in the range — the user wasn't at the
    /// computer (or activity didn't pass the 10-min threshold). Surfaced so commentary can
    /// note "you weren't around between 1 and 4 PM" instead of silently treating those hours
    /// as if they didn't exist.
    let emptyHours: [Int]
}
