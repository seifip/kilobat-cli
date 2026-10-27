import Foundation

public struct ProcessTraffic: Identifiable, Sendable {
    public let pid: Int32
    public let process: String
    public let received: UInt64
    public let sent: UInt64
    public var id: Int32 { pid }
    public var total: UInt64 { received + sent }
}

public struct TrafficSnapshot: Sendable {
    public let timestamp: Date
    public let processes: [ProcessTraffic]
}

public struct AppTraffic: Identifiable {
    public let id: String
    public var name: String
    public var processIDs: [Int32] = []
    public var ownerPath: String? = nil
    public var bundlePath: String?
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public var downloadRate: Double = 0
    public var uploadRate: Double = 0
    public var total: UInt64 { received + sent }
    public var rate: Double { downloadRate + uploadRate }
}

public struct UsageEntry: Codable, Identifiable {
    public var id: UUID = UUID()
    public let date: Date
    public let received: UInt64
    public let sent: UInt64
    public let apps: [String: UInt64]
    public var networkKey: String? = nil
    public var total: UInt64 { received + sent }
}

public enum NetworkProfile: String, Codable, CaseIterable, Identifiable {
    case travel = "Travel", work = "Work", unrestricted = "Unrestricted"
    public var id: String { rawValue }
    public var symbol: String {
        switch self { case .travel: "suitcase.rolling"; case .work: "laptopcomputer"; case .unrestricted: "globe" }
    }
    public var subtitle: String {
        switch self {
        case .travel: "Only the essentials. Save your mobile data."
        case .work: "Keep your work flowing. Pause distractions."
        case .unrestricted: "Monitor every app. Allow every connection."
        }
    }
}

public struct TemporaryRule: Codable, Equatable, Sendable {
    public let allowed: Bool
    public let expires: Date
    public init(allowed: Bool, expires: Date) { self.allowed = allowed; self.expires = expires }
}
public struct NetworkSession: Codable, Sendable {
    public var name: String
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
}
public struct SavedPreferences: Codable, Equatable {
    public var connectionRules: [ConnectionRule]? = nil
    public var temporaryRules: [String: TemporaryRule]? = nil
    public var networkProfiles: [String: String]? = nil
    public var networkLimits: [String: Double]? = nil
    public var trafficScope: String? = nil
    public var blockedDomains: [String]? = nil
    public var blocklistName: String? = nil
    public var domainExceptions: [String: [String]]? = nil
    public var profile: NetworkProfile = .travel
    public var rules: [String: [String: Bool]] = [:]
    public var limitGB: Double = 5
    public var autoHotspot: Bool = true
    public var defaultAllow: Bool = false
}

public enum TrafficFormat {
    public static func bytes(_ value: UInt64) -> String {
        if value == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
    }
    public static func rate(_ value: Double) -> String { guard value.isFinite, value >= 0, value < Double(UInt64.max) else { return "—" }; return bytes(UInt64(value)) + "/s" }
}

/// Compact usage history for scripts and agents: raw samples can run to megabytes.
public struct UsageSummary: Codable, Equatable {
    public struct Day: Codable, Equatable { public let day: String; public let downloadBytes: UInt64; public let uploadBytes: UInt64 }
    public struct App: Codable, Equatable { public let name: String; public let bytes: UInt64 }
    public let days: Int
    public let samples: Int
    public let downloadBytes: UInt64
    public let uploadBytes: UInt64
    public let daily: [Day]
    public let topApps: [App]

    public init(_ usage: [UsageEntry], days: Int, now: Date = Date(), calendar: Calendar = .current) {
        let start = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: now)) ?? now
        let entries = usage.filter { $0.date >= start && $0.date <= now }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var perDay: [String: (UInt64, UInt64)] = [:], perApp: [String: UInt64] = [:]
        for entry in entries {
            let day = formatter.string(from: entry.date)
            perDay[day] = ((perDay[day]?.0 ?? 0) + entry.received, (perDay[day]?.1 ?? 0) + entry.sent)
            for (app, bytes) in entry.apps where bytes > 0 { perApp[app, default: 0] += bytes }
        }
        self.days = days
        samples = entries.count
        downloadBytes = entries.reduce(0) { $0 + $1.received }
        uploadBytes = entries.reduce(0) { $0 + $1.sent }
        daily = perDay.sorted { $0.key < $1.key }.map { Day(day: $0.key, downloadBytes: $0.value.0, uploadBytes: $0.value.1) }
        topApps = perApp.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(10).map { App(name: $0.key, bytes: $0.value) }
    }
}
