import Foundation

/// A weekly time to be in a profile, such as Work on weekdays from 9:00 to 18:00. A window that ends before it starts
/// runs overnight, from its days into the next morning.
public struct ProfileSchedule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The profile's `rawValue`.
    public var profile: String
    /// Weekdays as `Calendar` numbers them: 1 is Sunday, 7 is Saturday.
    public var days: [Int]
    /// Minutes after midnight.
    public var start: Int
    public var end: Int
    public var enabled: Bool

    public init(id: UUID = UUID(), profile: String, days: [Int], start: Int, end: Int, enabled: Bool = true) {
        self.id = id; self.profile = profile; self.days = days; self.start = start; self.end = end; self.enabled = enabled
    }

    public static let weekdays = [2, 3, 4, 5, 6]
    public static let everyDay = [1, 2, 3, 4, 5, 6, 7]

    public var valid: Bool {
        !days.isEmpty && days.allSatisfy { (1...7).contains($0) } && (0..<1_440).contains(start) && (0..<1_440).contains(end) && start != end
    }
    public var overnight: Bool { end < start }

    /// When the window that `date` falls in began, or nil when it falls in none.
    public func windowStart(containing date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, valid else { return nil }
        let day = calendar.startOfDay(for: date)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let weekday = calendar.component(.weekday, from: date)
        if overnight {
            if days.contains(weekday), minute >= start { return calendar.date(byAdding: .minute, value: start, to: day) }
            let yesterday = weekday == 1 ? 7 : weekday - 1
            if days.contains(yesterday), minute < end, let previous = calendar.date(byAdding: .day, value: -1, to: day) {
                return calendar.date(byAdding: .minute, value: start, to: previous)
            }
            return nil
        }
        guard days.contains(weekday), minute >= start, minute < end else { return nil }
        return calendar.date(byAdding: .minute, value: start, to: day)
    }

    /// "Weekdays, 09:00–18:00", in the person's own time format.
    public func summary(calendar: Calendar = .current, locale: Locale = .current) -> String {
        String(localized: "\(Self.daysSummary(days, calendar: calendar, locale: locale)), \(Self.time(start, locale: locale))–\(Self.time(end, locale: locale))",
               comment: "A profile schedule: days, then start and end times")
    }
    public static func daysSummary(_ days: [Int], calendar: Calendar = .current, locale: Locale = .current) -> String {
        let set = Set(days)
        if set == Set(everyDay) { return String(localized: "Every day", comment: "Profile schedule days") }
        if set == Set(weekdays) { return String(localized: "Weekdays", comment: "Profile schedule days") }
        if set == [1, 7] { return String(localized: "Weekends", comment: "Profile schedule days") }
        var calendar = calendar; calendar.locale = locale
        let names = calendar.shortWeekdaySymbols
        // In the order the person's week starts.
        let ordered = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }.filter(set.contains)
        return ordered.map { names[$0 - 1] }.formatted(.list(type: .and).locale(locale))
    }
    public static func time(_ minutes: Int, locale: Locale = .current) -> String {
        var components = DateComponents(year: 2001, month: 1, day: 1); components.hour = minutes / 60; components.minute = minutes % 60
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }
}

/// Which schedule switched the profile, and from what, so its end can put the profile back.
public struct ProfileScheduleState: Codable, Equatable, Sendable {
    public var applied: UUID?
    /// The profile from before the first window, by `rawValue`.
    public var previous: String?
    public init(applied: UUID? = nil, previous: String? = nil) { self.applied = applied; self.previous = previous }
}

/// Switches profile at the start of each scheduled window and back at its end. Only the moments of change act, so a
/// profile picked by hand in the middle of a window stays until the next start or end; the end puts the old profile
/// back only if the scheduled one is still in use. While Kilobat has switched to Essentials on a metered network,
/// a schedule changes the profile to return to afterwards instead, so the data saving stays on.
public enum ProfileScheduler {
    /// The schedule in force at `now`: of the windows `now` falls in, the one that began last.
    public static func active(_ schedules: [ProfileSchedule], now: Date, calendar: Calendar = .current) -> ProfileSchedule? {
        schedules.compactMap { schedule in schedule.windowStart(containing: now, calendar: calendar).map { (schedule, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// What to do at `now`; changes `preferences` and returns true if anything changed. `held` is true while a Focus
    /// has switched the profile, which wins until it ends.
    @discardableResult public static func step(_ preferences: inout SavedPreferences, now: Date, held: Bool = false, calendar: Calendar = .current) -> Bool {
        let schedules = (preferences.profileSchedules ?? []).filter { preferences.knownProfile($0.profile) != nil }
        let state = preferences.profileScheduleState ?? ProfileScheduleState()
        let current = active(schedules, now: now, calendar: calendar)
        guard current?.id != state.applied, !held else { return false }
        let before = preferences
        if let current, let target = preferences.knownProfile(current.profile) {
            // Entering a window, or one window giving way to another: the profile from before the first is what comes back.
            let previous = state.applied == nil ? (preferences.autoProfileFrom ?? preferences.profile.rawValue) : state.previous
            if preferences.autoProfileFrom != nil { preferences.autoProfileFrom = target.rawValue } else { preferences.profile = target }
            preferences.profileScheduleState = ProfileScheduleState(applied: current.id, previous: previous)
        } else {
            let scheduled = (preferences.profileSchedules ?? []).first { $0.id == state.applied }?.profile
            if let scheduled, let previous = state.previous.flatMap(preferences.knownProfile) {
                if preferences.autoProfileFrom != nil { if preferences.autoProfileFrom == scheduled { preferences.autoProfileFrom = previous.rawValue } }
                else if preferences.profile.rawValue == scheduled { preferences.profile = previous }
            }
            preferences.profileScheduleState = nil
        }
        return preferences != before
    }

    /// The next moment the schedules switch profile, within a week and a day, with the profile it switches to (nil: back
    /// to the one from before).
    public static func nextChange(_ schedules: [ProfileSchedule], after now: Date, calendar: Calendar = .current) -> (date: Date, schedule: ProfileSchedule?)? {
        let usable = schedules.filter { $0.enabled && $0.valid }
        guard !usable.isEmpty else { return nil }
        let day = calendar.startOfDay(for: now)
        var moments: [Date] = []
        for offset in -1...8 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: day) else { continue }
            for schedule in usable {
                for minute in [schedule.start, schedule.end] {
                    if let moment = calendar.date(byAdding: .minute, value: minute, to: date), moment > now { moments.append(moment) }
                }
            }
        }
        let now = active(usable, now: now, calendar: calendar)?.id
        for moment in moments.sorted() {
            let then = active(usable, now: moment, calendar: calendar)
            if then?.id != now { return (moment, then) }
        }
        return nil
    }
}
