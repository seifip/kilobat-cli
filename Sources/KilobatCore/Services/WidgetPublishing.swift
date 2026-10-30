import Foundation

extension WidgetSnapshot.Status {
    /// The menu bar bat's reading: a check older than three minutes says nothing about now.
    public init(connected: Bool, snapshot: DiagnosticSnapshot?, now: Date = Date()) {
        guard connected else { self = .offline; return }
        guard let snapshot, now.timeIntervalSince(snapshot.date) < 180 else { self = .checking; return }
        if snapshot.captivePortal == true { self = .login; return }
        switch snapshot.health {
        case .good: self = .healthy
        case .degraded: self = .unstable
        case .poor: self = .poor
        case .unknown: self = .checking
        }
    }
}

extension WidgetSnapshot {
    /// `kind` is the path's kind as `NetworkStatus` names it; `samples` the health journal, for the latency line.
    public init(now: Date = Date(), connected: Bool, kind: String, metered: Bool, diagnostic: DiagnosticSnapshot?, samples: [DiagnosticSnapshot],
                today: (received: UInt64, sent: UInt64, hours: [UInt64]), budget: Budget?, speed: SpeedTestResult?, pro: Bool) {
        self.init(date: now, status: Status(connected: connected, snapshot: diagnostic, now: now))
        link = !connected ? nil : kind == String(localized: "Wi-Fi") ? .wifi : kind == String(localized: "Ethernet") ? .ethernet : kind == String(localized: "Cellular") ? .cellular : .other
        self.metered = connected && metered
        if connected, let diagnostic, now.timeIntervalSince(diagnostic.date) < 180 {
            internetMs = diagnostic.internet.average; routerMs = diagnostic.router?.average
            jitterMs = diagnostic.internet.jitter; lossPercent = diagnostic.internet.lossPercent
        }
        latency = samples.filter { now.timeIntervalSince($0.date) < 3600 }.suffix(30).compactMap(\.internet.average)
        todayReceived = today.received; todaySent = today.sent; todayHours = today.hours
        self.budget = pro ? budget : nil
        self.speed = speed.map { Speed(date: $0.date, downMbps: $0.downloadMbps, upMbps: $0.uploadMbps) }
        self.pro = pro
    }

    /// Internet bytes by hour since midnight, with what isn't saved yet in the current hour.
    public static func hours(_ usage: [UsageEntry], pending: UInt64, now: Date = Date(), calendar: Calendar = .current) -> [UInt64] {
        let midnight = calendar.startOfDay(for: now)
        var hours = [UInt64](repeating: 0, count: 24)
        for entry in usage where entry.date >= midnight && entry.date <= now {
            hours[min(23, max(0, calendar.component(.hour, from: entry.date)))] += entry.received + entry.sent
        }
        hours[min(23, calendar.component(.hour, from: now))] += pending
        return hours
    }
}

/// When to ask WidgetKit to redraw, which it allows only a few dozen times a day. At once (a minute apart at most) for
/// what changes the picture: the status, the connection, a new speed test, Pro, a budget step, a new day. Otherwise
/// every five minutes at most and only when a figure moved visibly, with one redraw before the widgets would call the
/// figures stale.
public struct WidgetReloadPlan: Sendable {
    public static let interval: TimeInterval = 300
    public static let spacing: TimeInterval = 60
    public static let keepAlive: TimeInterval = WidgetSnapshot.staleAfter - 180
    private var shown: [String: WidgetSnapshot] = [:]
    private var reloaded: [String: Date] = [:]
    public init() {}

    public mutating func due(_ snapshot: WidgetSnapshot, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        var kinds: [String] = []
        for kind in WidgetSnapshot.Kind.all {
            let elapsed = now.timeIntervalSince(reloaded[kind] ?? .distantPast)
            if let before = shown[kind] {
                let urgent = Self.urgent(kind, before, snapshot, calendar: calendar), moved = Self.moved(kind, before, snapshot)
                // The speed widget shows no age of its own, so it needs no redraw to stay current.
                let alive = kind != WidgetSnapshot.Kind.speed && elapsed >= Self.keepAlive
                guard (urgent && elapsed >= Self.spacing) || (moved && elapsed >= Self.interval) || alive else { continue }
            }
            shown[kind] = snapshot; reloaded[kind] = now; kinds.append(kind)
        }
        return kinds
    }

    static func urgent(_ kind: String, _ before: WidgetSnapshot, _ after: WidgetSnapshot, calendar: Calendar) -> Bool {
        if before.running != after.running || before.pro != after.pro { return true }
        switch kind {
        case WidgetSnapshot.Kind.status:
            return before.status != after.status || before.link != after.link || before.metered != after.metered || before.speed?.date != after.speed?.date
        case WidgetSnapshot.Kind.data:
            let step: (WidgetSnapshot) -> Int? = { $0.budget.map { Int($0.fraction * 20) } }
            return step(before) != step(after) || before.budget?.limitBytes != after.budget?.limitBytes || !calendar.isDate(before.date, inSameDayAs: after.date)
        default:
            return before.speed != after.speed
        }
    }

    static func moved(_ kind: String, _ before: WidgetSnapshot, _ after: WidgetSnapshot) -> Bool {
        func apart(_ a: Double?, _ b: Double?, by floor: Double, share: Double) -> Bool {
            guard let a, let b else { return (a == nil) != (b == nil) }
            return abs(a - b) >= max(floor, share * max(a, b))
        }
        switch kind {
        case WidgetSnapshot.Kind.status:
            return apart(before.internetMs, after.internetMs, by: 10, share: 0.25) || apart(before.routerMs, after.routerMs, by: 5, share: 0.5)
        case WidgetSnapshot.Kind.data:
            return apart(Double(before.todayBytes), Double(after.todayBytes), by: 1_000_000, share: 0.02)
                || apart(before.budget.map { Double($0.usedBytes) }, after.budget.map { Double($0.usedBytes) }, by: 1_000_000, share: 0.02)
        default: return false
        }
    }
}
