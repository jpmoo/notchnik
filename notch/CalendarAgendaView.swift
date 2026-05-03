//
//  CalendarAgendaView.swift
//  notch
//
//  Day-by-day time-grid agenda. Each day is a 24-hour timeline; events render as colored blocks
//  whose vertical extent equals their duration. Overlapping events split into side-by-side columns.
//  Today gets a red "now" rule positioned at the current time's y-coordinate.
//

import Combine
import SwiftUI

struct CalendarAgendaView: View {
    @EnvironmentObject private var calendar: CalendarFeedStore
    @EnvironmentObject private var settings: AppSettingsStore

    @State private var now: Date = Date()
    private let nowTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Vertical pixels per hour. 40 keeps 24h ≈ 960pt — plenty scrollable, but each 30-min meeting
    /// is still 20pt tall (one short word fits).
    private let hourHeight: CGFloat = 40
    private let timeColumnWidth: CGFloat = 44
    private let timeColumnSpacing: CGFloat = 8

    var body: some View {
        Group {
            if calendar.feeds.isEmpty {
                SectionPlaceholderView(
                    icon: PanelSection.calendar.iconName,
                    title: "Calendar",
                    detail: "Add a calendar feed in Settings → Calendar to see your agenda here."
                )
            } else if calendar.events.isEmpty {
                SectionPlaceholderView(
                    icon: PanelSection.calendar.iconName,
                    title: "Calendar",
                    detail: calendar.isRefreshing
                        ? "Loading events…"
                        : "No upcoming events from your subscribed calendars."
                )
            } else {
                switch settings.calendarViewMode {
                case .timeBlock:
                    timelineScroll
                case .agenda:
                    agendaListScroll
                }
            }
        }
        .onReceive(nowTimer) { now = $0 }
    }

    // MARK: Time-block view

    private var timelineScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedDays, id: \.day) { group in
                        Section {
                            TimelineDayView(
                                day: group.day,
                                events: group.events,
                                now: now,
                                isToday: isToday(group.day),
                                hourHeight: hourHeight,
                                timeColumnWidth: timeColumnWidth,
                                timeColumnSpacing: timeColumnSpacing,
                                feedColor: feedColor(for:)
                            )
                            .id("day-\(group.day.timeIntervalSince1970)")
                        } header: {
                            DayHeader(day: group.day, isToday: isToday(group.day))
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }
            .clipped()
            .onAppear {
                // Multiple shots: SwiftUI sometimes hasn't finished measuring the inner content
                // (especially the now-anchor inside the lazy day section) by the first attempt, and
                // the calendar fetch may arrive late. Each retry is cheap; the proxy just no-ops if
                // the target view isn't in the tree yet.
                for delay in [0.1, 0.4, 0.9, 1.5] as [TimeInterval] {
                    scrollToCurrentTime(proxy: proxy, animated: delay >= 0.4, delay: delay)
                }
            }
            .onChange(of: calendar.events.count) { _, _ in
                scrollToCurrentTime(proxy: proxy, animated: true, delay: 0.1)
            }
        }
    }

    /// Scrolls the time-block view so today's *current hour* is roughly centered. Falls back to the
    /// top of today's section when today isn't in `groupedDays` (rare — happens at midnight rollover).
    private func scrollToCurrentTime(proxy: ScrollViewProxy, animated: Bool, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let action = {
                if isToday(now), groupedDays.contains(where: { isToday($0.day) }) {
                    proxy.scrollTo("now-anchor", anchor: .center)
                } else if let todayKey = groupedDays.first?.day {
                    proxy.scrollTo("day-\(todayKey.timeIntervalSince1970)", anchor: .top)
                }
            }
            if animated {
                withAnimation(.easeOut(duration: 0.25), action)
            } else {
                action()
            }
        }
    }

    // MARK: Agenda list view (the older flat-list style)

    private var agendaListScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedDays, id: \.day) { group in
                        Section {
                            VStack(spacing: 0) {
                                ForEach(agendaRows(for: group)) { row in
                                    AgendaRow(row: row, feedColor: feedColor(for: feedID(of: row)))
                                        .id(scrollID(for: row))
                                }
                            }
                        } header: {
                            DayHeader(day: group.day, isToday: isToday(group.day))
                                .id("agenda-day-\(group.day.timeIntervalSince1970)")
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }
            .clipped()
            .onAppear {
                for delay in [0.1, 0.4, 0.9, 1.5] as [TimeInterval] {
                    scrollToTodayAgenda(proxy: proxy, animated: delay >= 0.4, delay: delay)
                }
            }
            .onChange(of: calendar.events.count) { _, _ in
                scrollToTodayAgenda(proxy: proxy, animated: true, delay: 0.1)
            }
        }
    }

    private func scrollToTodayAgenda(proxy: ScrollViewProxy, animated: Bool, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let action = {
                if isToday(now), groupedDays.contains(where: { isToday($0.day) }) {
                    proxy.scrollTo("agenda-now", anchor: .center)
                } else if let todayKey = groupedDays.first(where: { isToday($0.day) })?.day {
                    proxy.scrollTo("agenda-day-\(todayKey.timeIntervalSince1970)", anchor: .top)
                }
            }
            if animated {
                withAnimation(.easeOut(duration: 0.25), action)
            } else {
                action()
            }
        }
    }

    private func scrollID(for row: AgendaRow.Row) -> String {
        if case .nowMarker = row.kind { return "agenda-now" }
        return "agenda-row-\(row.id)"
    }

    private func agendaRows(for group: DayGroup) -> [AgendaRow.Row] {
        var kinds: [AgendaRow.Kind] = group.events.map { .event($0) }
        if isToday(group.day) {
            // Insert before the first event whose START is in the future. Events that have already
            // started — even if they're still ongoing — sit above the line.
            let insertion = kinds.firstIndex { kind in
                if case .event(let e) = kind { return e.start > now }
                return false
            } ?? kinds.endIndex
            kinds.insert(.nowMarker(now), at: insertion)
        }
        return kinds.enumerated().map { AgendaRow.Row(index: $0.offset, kind: $0.element) }
    }

    private func feedID(of row: AgendaRow.Row) -> UUID? {
        if case .event(let e) = row.kind { return e.feedID }
        return nil
    }

    // MARK: - Grouping

    private struct DayGroup: Equatable {
        let day: Date
        let events: [CalendarEvent]
    }

    private var groupedDays: [DayGroup] {
        let cal = Calendar.current
        let horizon = cal.date(byAdding: .day, value: 60, to: now) ?? now
        let startOfToday = cal.startOfDay(for: now)

        let upcoming = calendar.events.filter { $0.end >= startOfToday && $0.start <= horizon }

        var bucket: [Date: [CalendarEvent]] = [:]
        // Always include today so the timeline + now-anchor render even on a day with no events;
        // otherwise ScrollViewReader has no target to scroll to and the panel opens at the top.
        bucket[startOfToday] = []

        for event in upcoming {
            let firstDay = cal.startOfDay(for: max(event.start, startOfToday))
            let lastDay = cal.startOfDay(for: min(event.end.addingTimeInterval(-1), horizon))
            var cursor = firstDay
            while cursor <= lastDay {
                bucket[cursor, default: []].append(event)
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        return bucket
            .map { DayGroup(day: $0.key, events: $0.value.sorted { $0.start < $1.start }) }
            .sorted { $0.day < $1.day }
    }

    private func isToday(_ day: Date) -> Bool {
        Calendar.current.isDate(day, inSameDayAs: now)
    }

    private func feedColor(for feedID: UUID?) -> Color {
        guard let feedID, let feed = calendar.feeds.first(where: { $0.id == feedID }) else {
            return .accentColor
        }
        return feed.color.color
    }
}

// MARK: - Section header

private struct DayHeader: View {
    let day: Date
    let isToday: Bool

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.weekdayFormatter.string(from: day))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isToday ? Color.accentColor : .white.opacity(0.85))
            Text(Self.monthDayFormatter.string(from: day))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            if isToday {
                Text("Today")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.85))
    }
}

// MARK: - Per-day timeline

private struct TimelineDayView: View {
    let day: Date
    let events: [CalendarEvent]
    let now: Date
    let isToday: Bool
    let hourHeight: CGFloat
    let timeColumnWidth: CGFloat
    let timeColumnSpacing: CGFloat
    let feedColor: (UUID?) -> Color

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f
    }()

    var body: some View {
        let allDay = events.filter { $0.isAllDay }
        let timed = events.filter { !$0.isAllDay }

        VStack(alignment: .leading, spacing: 4) {
            ForEach(allDay) { event in
                AllDayBanner(event: event, color: feedColor(event.feedID))
            }

            ZStack(alignment: .topLeading) {
                // Hour grid as a flat VStack — `.id` on the current-hour row is what ScrollViewReader
                // targets. Putting the id on a real laid-out row (instead of a deeply-nested marker
                // inside GeometryReader) is what finally makes scrollTo land reliably.
                let nowHour = isToday ? Calendar.current.component(.hour, from: now) : -1
                let dayKey = day.timeIntervalSince1970
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        HStack(alignment: .top, spacing: timeColumnSpacing) {
                            Text(hourLabel(hour))
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: timeColumnWidth, alignment: .trailing)
                                .offset(y: -4)
                            Rectangle()
                                .fill(Color.white.opacity(0.07))
                                .frame(height: 1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: hourHeight, alignment: .top)
                        .id(hour == nowHour ? "now-anchor" : "hour-\(dayKey)-\(hour)")
                    }
                }

                // Event blocks need the available width to compute column spans, so this sub-layer
                // uses GeometryReader. It's purely visual — no `.id` here, no hit-testing impact.
                GeometryReader { geo in
                    let trackOriginX = timeColumnWidth + timeColumnSpacing
                    let trackWidth = max(40, geo.size.width - trackOriginX)
                    ZStack(alignment: .topLeading) {
                        ForEach(layoutBlocks(for: timed)) { block in
                            EventBlock(
                                event: block.event,
                                color: feedColor(block.event.feedID),
                                visibleStart: block.visibleStart,
                                visibleEnd: block.visibleEnd
                            )
                            .frame(
                                width: max(20, (trackWidth / CGFloat(block.totalColumns)) - 2),
                                height: max(18, blockHeight(start: block.visibleStart, end: block.visibleEnd) - 2)
                            )
                            .offset(
                                x: trackOriginX
                                    + (CGFloat(block.column) * (trackWidth / CGFloat(block.totalColumns))),
                                y: yForTime(block.visibleStart) + 1
                            )
                        }

                        if isToday, let nowY = yForTimeIfWithinDay(now) {
                            NowLine(width: geo.size.width)
                                .offset(y: nowY)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(height: hourHeight * 24)
        }
        .padding(.bottom, 16)
    }

    // MARK: Layout helpers

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let d = Calendar.current.date(from: components) ?? Date()
        return Self.hourFormatter.string(from: d)
    }

    private func yForTime(_ date: Date) -> CGFloat {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let seconds = max(0, date.timeIntervalSince(dayStart))
        let hours = CGFloat(seconds) / 3600
        return min(24 * hourHeight, hours * hourHeight)
    }

    private func yForTimeIfWithinDay(_ date: Date) -> CGFloat? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        guard date >= dayStart && date < dayEnd else { return nil }
        return yForTime(date)
    }

    private func blockHeight(start: Date, end: Date) -> CGFloat {
        let span = max(0, end.timeIntervalSince(start))
        return CGFloat(span) / 3600 * hourHeight
    }

    /// Sweep-line column assignment. Events that overlap in time share an "overlap group" and split
    /// the track into N equal columns where N is the maximum simultaneous overlap.
    private func layoutBlocks(for events: [CalendarEvent]) -> [LaidOutBlock] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        // Clip events to this day.
        let clipped: [(event: CalendarEvent, start: Date, end: Date)] = events.compactMap { e in
            let s = max(e.start, dayStart)
            let en = min(e.end, dayEnd)
            guard en > s else { return nil }
            return (e, s, en)
        }
        let sorted = clipped.sorted { $0.start < $1.start }

        var output: [LaidOutBlock] = []
        var pending: [(event: CalendarEvent, start: Date, end: Date, column: Int)] = []
        var active: [(event: CalendarEvent, end: Date, column: Int)] = []
        var groupMaxColumns = 0

        func flush() {
            for item in pending {
                output.append(LaidOutBlock(
                    event: item.event,
                    visibleStart: item.start,
                    visibleEnd: item.end,
                    column: item.column,
                    totalColumns: max(1, groupMaxColumns)
                ))
            }
            pending.removeAll()
            groupMaxColumns = 0
        }

        for item in sorted {
            // Drop active entries that have ended before this item begins.
            active.removeAll { $0.end <= item.start }
            if active.isEmpty {
                flush()
            }
            // Pick the lowest column index not occupied by active overlaps.
            let used = Set(active.map { $0.column })
            var col = 0
            while used.contains(col) { col += 1 }
            active.append((item.event, item.end, col))
            pending.append((item.event, item.start, item.end, col))
            groupMaxColumns = max(groupMaxColumns, col + 1)
        }
        flush()
        return output
    }
}

private struct LaidOutBlock: Identifiable {
    let event: CalendarEvent
    let visibleStart: Date
    let visibleEnd: Date
    let column: Int
    let totalColumns: Int
    var id: String { "\(event.id)-\(visibleStart.timeIntervalSince1970)" }
}

// MARK: - Event block

private struct EventBlock: View {
    let event: CalendarEvent
    let color: Color
    let visibleStart: Date
    let visibleEnd: Date

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "a"
        f.pmSymbol = "p"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(timeRange)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
            if let location = event.location, !location.isEmpty {
                Text(location)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(0.85))
        )
        // `strokeBorder` keeps the stroke INSIDE the frame so adjoining blocks don't visually overlap
        // (default `stroke` paints centered on the edge, half outside the frame).
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(color, lineWidth: 1)
        )
    }

    private var timeRange: String {
        Self.timeFormatter.string(from: event.start) + " – " + Self.timeFormatter.string(from: event.end)
    }
}

// MARK: - All-day banner

private struct AllDayBanner: View {
    let event: CalendarEvent
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.85))
            Text(event.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Text("All day")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(0.7))
        )
    }
}

// MARK: - Agenda flat-list row

private struct AgendaRow: View {
    let row: Row
    let feedColor: Color

    struct Row: Identifiable {
        let index: Int
        let kind: Kind
        var id: String {
            switch kind {
            case .event(let e): return "\(index)-\(e.id)"
            case .nowMarker(let d): return "\(index)-now-\(d.timeIntervalSince1970)"
            }
        }
    }

    enum Kind {
        case event(CalendarEvent)
        case nowMarker(Date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        switch row.kind {
        case .event(let event):
            eventRow(event)
        case .nowMarker(let date):
            nowMarker(date)
        }
    }

    @ViewBuilder
    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(feedColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(timeLabel(for: event))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    private func timeLabel(for event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        return Self.timeFormatter.string(from: event.start)
    }

    private func nowMarker(_ date: Date) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 1)
            Text(Self.timeFormatter.string(from: date))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.red)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }
}

// MARK: - Now line

private struct NowLine: View {
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .offset(x: -4, y: -4)
            Rectangle()
                .fill(Color.red)
                .frame(width: width, height: 1)
        }
        .allowsHitTesting(false)
    }
}
