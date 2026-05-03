//
//  CalendarFeedStore.swift
//  notch
//
//  Stores user-added .ics calendar subscriptions and the events parsed from them.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Codable RGBA so SwiftUI/NSColor instances survive a JSON round-trip.
struct ColorRGBA: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.systemBlue
        self.red = Double(ns.redComponent)
        self.green = Double(ns.greenComponent)
        self.blue = Double(ns.blueComponent)
        self.alpha = Double(ns.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

struct CalendarFeed: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var urlString: String
    var color: ColorRGBA
    var lastFetched: Date?
    var lastError: String?

    /// `webcal://` is the standard subscription scheme; URLSession won't fetch it directly. Map to https.
    var fetchURL: URL? {
        guard let url = URL(string: urlString) else { return nil }
        if url.scheme?.lowercased() == "webcal" {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            return comps?.url
        }
        return url
    }
}

struct CalendarEvent: Identifiable, Equatable {
    let id: String        // feedID + UID for deduplication across feeds
    let feedID: UUID
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
}

@MainActor
final class CalendarFeedStore: ObservableObject {
    @Published private(set) var feeds: [CalendarFeed] = []
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var isRefreshing: Bool = false

    private static let manifestFileName = "calendar_feeds.json"
    private static let storageFolderName = "NotchNik"
    private static let refreshIntervalSeconds: TimeInterval = 15 * 60

    private var refreshTimer: Timer?

    private var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Self.storageFolderName, isDirectory: true)
    }

    private var manifestURL: URL {
        storageDirectory.appendingPathComponent(Self.manifestFileName)
    }

    init() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        loadFeeds()
        scheduleAutoRefresh()
        Task { await refreshAll() }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - CRUD

    func addFeed(name: String, urlString: String, color: Color) {
        let feed = CalendarFeed(name: name, urlString: urlString, color: ColorRGBA(color))
        feeds.append(feed)
        saveFeeds()
        Task { await refresh(feed) }
    }

    func updateFeed(_ updated: CalendarFeed) {
        guard let i = feeds.firstIndex(where: { $0.id == updated.id }) else { return }
        feeds[i] = updated
        saveFeeds()
        Task { await refresh(updated) }
    }

    func removeFeed(id: UUID) {
        feeds.removeAll { $0.id == id }
        events.removeAll { $0.feedID == id }
        saveFeeds()
    }

    // MARK: - Refresh

    func refreshAll() async {
        guard !feeds.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for feed in feeds {
                group.addTask { [weak self] in
                    await self?.refresh(feed)
                }
            }
        }
    }

    func refresh(_ feed: CalendarFeed) async {
        guard let url = feed.fetchURL else {
            updateFeedStatus(id: feed.id, error: "Invalid URL")
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                updateFeedStatus(id: feed.id, error: "HTTP \(http.statusCode)")
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            // Expand recurring events into a finite window: a week back (for events still in progress
            // when the panel opens) through 90 days forward (the agenda only renders 60 days, but the
            // padding gives the user some lead time on what's coming up just past the visible horizon).
            let now = Date()
            let cal = Calendar.current
            let lower = cal.date(byAdding: .day, value: -7, to: now) ?? now
            let upper = cal.date(byAdding: .day, value: 90, to: now) ?? now
            let parsed = ICSParser.parseEvents(from: text, feedID: feed.id, window: lower...upper)
            // Replace events for this feed atomically.
            events.removeAll { $0.feedID == feed.id }
            events.append(contentsOf: parsed)
            updateFeedStatus(id: feed.id, error: nil)
        } catch {
            updateFeedStatus(id: feed.id, error: error.localizedDescription)
        }
    }

    private func updateFeedStatus(id: UUID, error: String?) {
        guard let i = feeds.firstIndex(where: { $0.id == id }) else { return }
        feeds[i].lastFetched = Date()
        feeds[i].lastError = error
        saveFeeds()
    }

    private func scheduleAutoRefresh() {
        let timer = Timer(timeInterval: Self.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refreshAll() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Persistence

    private func loadFeeds() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        feeds = (try? decoder.decode([CalendarFeed].self, from: data)) ?? []
    }

    private func saveFeeds() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(feeds) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}

// MARK: - RRULE supporting types

/// Subset of RFC 5545 weekdays. Raw value matches `Calendar.Component.weekday` (Sunday = 1).
enum ICSWeekday: Int {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    static func fromCode(_ code: String) -> ICSWeekday? {
        switch code {
        case "SU": return .sunday
        case "MO": return .monday
        case "TU": return .tuesday
        case "WE": return .wednesday
        case "TH": return .thursday
        case "FR": return .friday
        case "SA": return .saturday
        default: return nil
        }
    }
}

struct ByDay: Equatable {
    let day: ICSWeekday
    /// Nil = "every occurrence of this weekday in the period"; positive = Nth occurrence;
    /// negative = Nth-from-end (e.g. -1 = last).
    let ordinal: Int?
}

struct RecurrenceRule: Equatable {
    enum Frequency: String { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }

    let frequency: Frequency
    let interval: Int
    let until: Date?
    let count: Int?
    let byDay: [ByDay]
    let byMonthDay: [Int]
    let byMonth: [Int]
}

// MARK: - Lightweight ICS parser (RFC 5545 subset)

enum ICSParser {
    /// Parses VEVENT blocks from raw .ics text and expands recurrences within `window`.
    ///
    /// Supports:
    /// - One-off events (no RRULE).
    /// - DAILY / WEEKLY / MONTHLY / YEARLY RRULE with INTERVAL, COUNT, UNTIL.
    /// - WEEKLY with BYDAY (e.g. `MO,WE,FR`).
    /// - MONTHLY / YEARLY with BYMONTHDAY (e.g. 1st, 15th, -1 for last day).
    /// - MONTHLY / YEARLY with BYDAY + ordinal (e.g. `2TU` = 2nd Tuesday, `-1FR` = last Friday).
    /// - YEARLY with BYMONTH.
    /// - EXDATE: skip explicit cancelled dates.
    /// - RECURRENCE-ID: replace a generated occurrence with the explicit override VEVENT.
    ///
    /// Skips: BYHOUR/BYMINUTE/BYSECOND, BYWEEKNO, BYYEARDAY, BYSETPOS, RDATE, multiple RRULEs.
    static func parseEvents(from text: String, feedID: UUID, window: ClosedRange<Date>) -> [CalendarEvent] {
        let unfolded = unfoldLines(text)
        let lines = unfolded.split(whereSeparator: { $0 == "\n" || $0 == "\r" })

        var partials: [PartialEvent] = []
        var inEvent = false
        var current = PartialEvent()

        for raw in lines {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let upper = line.uppercased()

            if upper == "BEGIN:VEVENT" {
                inEvent = true
                current = PartialEvent()
                continue
            }
            if upper == "END:VEVENT" {
                if current.uid != nil || current.start != nil {
                    partials.append(current)
                }
                inEvent = false
                continue
            }
            guard inEvent else { continue }

            let (key, params, value) = parseLine(line)
            switch key.uppercased() {
            case "UID":
                current.uid = value
            case "SUMMARY":
                current.summary = unescape(value)
            case "LOCATION":
                current.location = unescape(value)
            case "DTSTART":
                if let parsed = parseDate(value, params: params) {
                    current.start = parsed.date
                    current.isAllDay = parsed.isDateOnly
                }
            case "DTEND":
                if let parsed = parseDate(value, params: params) {
                    current.end = parsed.date
                }
            case "RRULE":
                current.rrule = parseRRule(value)
            case "EXDATE":
                // EXDATE may carry a comma-separated list of dates.
                for chunk in value.split(separator: ",") {
                    if let parsed = parseDate(String(chunk), params: params) {
                        current.exdates.append(parsed.date)
                    }
                }
            case "RECURRENCE-ID":
                if let parsed = parseDate(value, params: params) {
                    current.recurrenceID = parsed.date
                }
            default:
                break
            }
        }

        return expandPartials(partials, feedID: feedID, window: window)
    }

    // MARK: - Expansion

    private static func expandPartials(_ partials: [PartialEvent], feedID: UUID, window: ClosedRange<Date>) -> [CalendarEvent] {
        // Split into base events and modified-instance overrides keyed by (UID, original-occurrence-start).
        var bases: [PartialEvent] = []
        var overrides: [String: PartialEvent] = [:]
        for p in partials {
            if let recurrenceID = p.recurrenceID, let uid = p.uid {
                overrides[overrideKey(uid: uid, occurrence: recurrenceID)] = p
            } else {
                bases.append(p)
            }
        }

        var results: [CalendarEvent] = []

        for base in bases {
            guard let baseStart = base.start, let summary = base.summary else { continue }
            let baseDuration = base.end?.timeIntervalSince(baseStart)
                ?? (base.isAllDay ? 86_400 : 3_600)
            let exdates = Set(base.exdates.map { $0.timeIntervalSince1970 })

            if let rule = base.rrule {
                let occurrences = expand(rule: rule, baseStart: baseStart, window: window, isAllDay: base.isAllDay)
                for start in occurrences {
                    if exdates.contains(start.timeIntervalSince1970) { continue }

                    if let uid = base.uid,
                       let override = overrides[overrideKey(uid: uid, occurrence: start)] {
                        // Modified-instance override replaces this occurrence's data wholesale.
                        if let oStart = override.start {
                            let oEnd = override.end ?? oStart.addingTimeInterval(baseDuration)
                            if oEnd >= window.lowerBound && oStart <= window.upperBound {
                                results.append(makeEvent(
                                    feedID: feedID,
                                    uid: uid,
                                    occurrenceKey: start,
                                    title: override.summary ?? summary,
                                    location: override.location ?? base.location,
                                    start: oStart,
                                    end: oEnd,
                                    isAllDay: override.isAllDay
                                ))
                            }
                        }
                        continue
                    }

                    let end = start.addingTimeInterval(baseDuration)
                    results.append(makeEvent(
                        feedID: feedID,
                        uid: base.uid,
                        occurrenceKey: start,
                        title: summary,
                        location: base.location,
                        start: start,
                        end: end,
                        isAllDay: base.isAllDay
                    ))
                }
            } else {
                // Single occurrence — emit if it intersects the window.
                let end = base.end ?? baseStart.addingTimeInterval(baseDuration)
                if end >= window.lowerBound && baseStart <= window.upperBound {
                    results.append(makeEvent(
                        feedID: feedID,
                        uid: base.uid,
                        occurrenceKey: baseStart,
                        title: summary,
                        location: base.location,
                        start: baseStart,
                        end: end,
                        isAllDay: base.isAllDay
                    ))
                }
            }
        }

        return results
    }

    private static func makeEvent(feedID: UUID, uid: String?, occurrenceKey: Date, title: String, location: String?, start: Date, end: Date, isAllDay: Bool) -> CalendarEvent {
        let uniqueID = "\(feedID.uuidString):\(uid ?? title):\(occurrenceKey.timeIntervalSince1970)"
        return CalendarEvent(
            id: uniqueID,
            feedID: feedID,
            title: title,
            start: start,
            end: end,
            isAllDay: isAllDay,
            location: location
        )
    }

    private static func overrideKey(uid: String, occurrence: Date) -> String {
        "\(uid):\(occurrence.timeIntervalSince1970)"
    }

    /// Generates RRULE-driven occurrence start times, clamped to `window` and to RRULE's COUNT / UNTIL.
    /// Iteration is bounded so a malformed feed can't lock us in an infinite loop.
    private static func expand(rule: RecurrenceRule, baseStart: Date, window: ClosedRange<Date>, isAllDay: Bool) -> [Date] {
        var results: [Date] = []
        let cal = Calendar.current
        let countLimit = rule.count ?? Int.max
        let untilLimit = rule.until ?? .distantFuture
        let safetyCap = 1_000  // hard stop on iterations regardless of frequency

        var generated = 0
        var iteration = 0

        while iteration < safetyCap && generated < countLimit {
            let candidates = candidatesAt(rule: rule, baseStart: baseStart, iteration: iteration, calendar: cal)
            // candidatesAt may return out-of-order candidates; sort so we hit COUNT/UNTIL deterministically.
            for candidate in candidates.sorted() {
                if candidate > untilLimit { return results }
                generated += 1
                if candidate >= window.lowerBound && candidate <= window.upperBound {
                    results.append(candidate)
                }
                // Past the window AND past the period-of-interest? Stop early.
                if candidate > window.upperBound { return results }
                if generated >= countLimit { return results }
            }
            iteration += 1

            // For frequencies that always emit one candidate per iteration, bail when the iteration's
            // base date is already past the window.
            if let probe = candidates.first, probe > window.upperBound { break }
        }
        return results
    }

    private static func candidatesAt(rule: RecurrenceRule, baseStart: Date, iteration: Int, calendar: Calendar) -> [Date] {
        switch rule.frequency {
        case .daily:
            guard let d = calendar.date(byAdding: .day, value: iteration * rule.interval, to: baseStart) else { return [] }
            return [d]

        case .weekly:
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: iteration * rule.interval, to: baseStart) else { return [] }
            if rule.byDay.isEmpty {
                return [weekStart]
            }
            // Anchor to the week containing `weekStart` and emit the named weekdays.
            let weekday = calendar.component(.weekday, from: weekStart)
            let baseStartOfWeek = calendar.date(byAdding: .day, value: -(weekday - calendar.firstWeekday + 7) % 7, to: weekStart) ?? weekStart
            var dates: [Date] = []
            for byDay in rule.byDay {
                let offset = (byDay.day.rawValue - calendar.firstWeekday + 7) % 7
                if let d = calendar.date(byAdding: .day, value: offset, to: baseStartOfWeek) {
                    let normalized = combine(date: d, time: baseStart, calendar: calendar)
                    dates.append(normalized)
                }
            }
            return dates

        case .monthly:
            guard let monthStart = calendar.date(byAdding: .month, value: iteration * rule.interval, to: baseStart) else { return [] }
            let year = calendar.component(.year, from: monthStart)
            let month = calendar.component(.month, from: monthStart)
            var dates: [Date] = []

            if !rule.byMonthDay.isEmpty {
                let dim = daysInMonth(year: year, month: month, calendar: calendar)
                for d in rule.byMonthDay {
                    let day = d > 0 ? d : (dim + d + 1)
                    if day < 1 || day > dim { continue }
                    if let candidate = makeDate(year: year, month: month, day: day, time: baseStart, calendar: calendar) {
                        dates.append(candidate)
                    }
                }
            } else if !rule.byDay.isEmpty {
                for byDay in rule.byDay {
                    if let candidate = nthWeekdayInMonth(year: year, month: month, weekday: byDay.day, ordinal: byDay.ordinal, time: baseStart, calendar: calendar) {
                        dates.append(candidate)
                    }
                }
            } else {
                // Default: same day-of-month as baseStart.
                let day = calendar.component(.day, from: baseStart)
                let dim = daysInMonth(year: year, month: month, calendar: calendar)
                if day <= dim, let candidate = makeDate(year: year, month: month, day: day, time: baseStart, calendar: calendar) {
                    dates.append(candidate)
                }
            }
            return dates

        case .yearly:
            guard let yearStart = calendar.date(byAdding: .year, value: iteration * rule.interval, to: baseStart) else { return [] }
            let year = calendar.component(.year, from: yearStart)
            let months = rule.byMonth.isEmpty ? [calendar.component(.month, from: baseStart)] : rule.byMonth
            var dates: [Date] = []
            for m in months {
                if !rule.byMonthDay.isEmpty {
                    let dim = daysInMonth(year: year, month: m, calendar: calendar)
                    for d in rule.byMonthDay {
                        let day = d > 0 ? d : (dim + d + 1)
                        if day < 1 || day > dim { continue }
                        if let cand = makeDate(year: year, month: m, day: day, time: baseStart, calendar: calendar) {
                            dates.append(cand)
                        }
                    }
                } else if !rule.byDay.isEmpty {
                    for byDay in rule.byDay {
                        if let cand = nthWeekdayInMonth(year: year, month: m, weekday: byDay.day, ordinal: byDay.ordinal, time: baseStart, calendar: calendar) {
                            dates.append(cand)
                        }
                    }
                } else {
                    let day = calendar.component(.day, from: baseStart)
                    if let cand = makeDate(year: year, month: m, day: day, time: baseStart, calendar: calendar) {
                        dates.append(cand)
                    }
                }
            }
            return dates
        }
    }

    private static func nthWeekdayInMonth(year: Int, month: Int, weekday: ICSWeekday, ordinal: Int?, time: Date, calendar: Calendar) -> Date? {
        let dim = daysInMonth(year: year, month: month, calendar: calendar)
        var matches: [Int] = []
        for day in 1...dim {
            if let d = makeDate(year: year, month: month, day: day, time: time, calendar: calendar),
               calendar.component(.weekday, from: d) == weekday.rawValue {
                matches.append(day)
            }
        }
        guard !matches.isEmpty else { return nil }
        if let ordinal {
            let idx = ordinal > 0 ? ordinal - 1 : matches.count + ordinal
            guard matches.indices.contains(idx) else { return nil }
            return makeDate(year: year, month: month, day: matches[idx], time: time, calendar: calendar)
        } else {
            // No ordinal — return the first match. (Multiple BYDAY entries cover the rest.)
            return makeDate(year: year, month: month, day: matches.first!, time: time, calendar: calendar)
        }
    }

    private static func daysInMonth(year: Int, month: Int, calendar: Calendar) -> Int {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let date = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: date) else { return 30 }
        return range.count
    }

    private static func makeDate(year: Int, month: Int, day: Int, time: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.hour, .minute, .second, .timeZone], from: time)
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    private static func combine(date dateComponentSource: Date, time: Date, calendar: Calendar) -> Date {
        let dateParts = calendar.dateComponents([.year, .month, .day], from: dateComponentSource)
        var combined = calendar.dateComponents([.hour, .minute, .second, .timeZone], from: time)
        combined.year = dateParts.year
        combined.month = dateParts.month
        combined.day = dateParts.day
        return calendar.date(from: combined) ?? dateComponentSource
    }

    // MARK: - RRULE parsing

    private static func parseRRule(_ value: String) -> RecurrenceRule? {
        var freq: RecurrenceRule.Frequency?
        var interval = 1
        var until: Date?
        var count: Int?
        var byDay: [ByDay] = []
        var byMonthDay: [Int] = []
        var byMonth: [Int] = []

        for part in value.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).uppercased()
            let val = String(kv[1])
            switch key {
            case "FREQ":
                freq = RecurrenceRule.Frequency(rawValue: val.uppercased())
            case "INTERVAL":
                interval = Int(val) ?? 1
            case "COUNT":
                count = Int(val)
            case "UNTIL":
                until = parseDate(val, params: [:])?.date
            case "BYDAY":
                byDay = val.split(separator: ",").compactMap { parseByDayToken(String($0)) }
            case "BYMONTHDAY":
                byMonthDay = val.split(separator: ",").compactMap { Int($0) }
            case "BYMONTH":
                byMonth = val.split(separator: ",").compactMap { Int($0) }
            default:
                break
            }
        }

        guard let freq else { return nil }
        return RecurrenceRule(
            frequency: freq,
            interval: interval,
            until: until,
            count: count,
            byDay: byDay,
            byMonthDay: byMonthDay,
            byMonth: byMonth
        )
    }

    /// Parses tokens like `MO`, `2TU`, `-1FR`. Returns nil for unrecognized weekday codes.
    private static func parseByDayToken(_ token: String) -> ByDay? {
        // Strip leading sign + digits.
        var ordinalString = ""
        var dayString = ""
        for ch in token {
            if ch == "+" || ch == "-" || ch.isNumber {
                ordinalString.append(ch)
            } else {
                dayString.append(ch)
            }
        }
        guard let weekday = ICSWeekday.fromCode(dayString.uppercased()) else { return nil }
        let ordinal = ordinalString.isEmpty ? nil : Int(ordinalString)
        return ByDay(day: weekday, ordinal: ordinal)
    }

    // MARK: - PartialEvent

    private struct PartialEvent {
        var uid: String?
        var summary: String?
        var location: String?
        var start: Date?
        var end: Date?
        var isAllDay: Bool = false
        var rrule: RecurrenceRule?
        var exdates: [Date] = []
        var recurrenceID: Date?
    }

    /// RFC 5545 line unfolding: continuation lines start with whitespace and join the previous line.
    private static func unfoldLines(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var result = ""
        for line in normalized.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t" {
                result.append(String(line.dropFirst()))
            } else {
                if !result.isEmpty { result.append("\n") }
                result.append(line)
            }
        }
        return result
    }

    /// Splits `KEY;PARAM1=foo;PARAM2=bar:VALUE` into its three pieces.
    private static func parseLine(_ line: String) -> (key: String, params: [String: String], value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, [:], "") }
        let lhs = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])

        let parts = lhs.split(separator: ";").map(String.init)
        let key = parts.first ?? lhs
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            if let eq = p.firstIndex(of: "=") {
                let k = String(p[..<eq]).uppercased()
                let v = String(p[p.index(after: eq)...])
                params[k] = v
            }
        }
        return (key, params, value)
    }

    private static func parseDate(_ value: String, params: [String: String]) -> (date: Date, isDateOnly: Bool)? {
        let isDateOnly = params["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T"))
        let tzID = params["TZID"]

        if isDateOnly {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = TimeZone(identifier: tzID ?? "") ?? TimeZone.current
            if let d = formatter.date(from: value) {
                return (d, true)
            }
            return nil
        }

        // Date-time: YYYYMMDDTHHMMSS or YYYYMMDDTHHMMSSZ.
        let isUTC = value.hasSuffix("Z")
        let stripped = isUTC ? String(value.dropLast()) : value
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = isUTC
            ? TimeZone(identifier: "UTC")
            : (TimeZone(identifier: tzID ?? "") ?? TimeZone.current)
        if let d = formatter.date(from: stripped) {
            return (d, false)
        }
        return nil
    }

    private static func unescape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
