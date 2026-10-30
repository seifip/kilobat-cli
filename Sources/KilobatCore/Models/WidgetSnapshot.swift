import Foundation

/// What the desktop and Notification Center widgets show. The app writes it to the shared App Group container and the
/// widgets only read it. It never carries a network's name or an address: widgets sit on screen, and in screenshots.
/// The widget extension compiles this file on its own, so it uses Foundation alone.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case healthy, unstable, poor, offline, checking, login }
    public enum Link: String, Codable, Sendable { case wifi, ethernet, cellular, other }
    public struct Budget: Codable, Equatable, Sendable {
        public var usedBytes: UInt64
        public var limitBytes: UInt64
        /// session, daily, weekly or monthly, as `BudgetPeriod`.
        public var period: String
        public init(usedBytes: UInt64, limitBytes: UInt64, period: String) { self.usedBytes = usedBytes; self.limitBytes = limitBytes; self.period = period }
        public var fraction: Double { min(1, Double(usedBytes) / Double(max(1, limitBytes))) }
    }
    public struct Speed: Codable, Equatable, Sendable {
        public var date: Date
        public var downMbps: Double
        public var upMbps: Double
        public init(date: Date, downMbps: Double, upMbps: Double) { self.date = date; self.downMbps = downMbps; self.upMbps = upMbps }
    }

    public var date: Date
    /// False once the app quits, so the widgets say to open it instead of showing old figures as current.
    public var running = true
    public var status: Status
    public var link: Link?
    public var metered = false
    public var internetMs: Double?
    public var routerMs: Double?
    public var jitterMs: Double?
    public var lossPercent: Double?
    /// Recent internet latency, oldest first, about one a minute.
    public var latency: [Double] = []
    public var todayReceived: UInt64 = 0
    public var todaySent: UInt64 = 0
    /// Today's Internet bytes by hour, 24 values from midnight.
    public var todayHours: [UInt64] = []
    /// The current network's budget; only with Pro, as budgets are.
    public var budget: Budget?
    public var speed: Speed?
    public var pro = false

    public init(date: Date, status: Status) { self.date = date; self.status = status }

    public var todayBytes: UInt64 { todayReceived + todaySent }
    public func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(date)) }
    public func stale(at now: Date) -> Bool { age(at: now) > Self.staleAfter }

    public static let staleAfter: TimeInterval = 15 * 60
    /// Team-prefixed, so macOS ties it to the signing team and doesn't ask the person for access.
    public static let appGroup = "HAR874R67J.co.seifi.kilobat"
    public static let fileName = "widget.json"
    public enum Kind {
        public static let status = "co.seifi.kilobat.widget.status"
        public static let data = "co.seifi.kilobat.widget.data"
        public static let speed = "co.seifi.kilobat.widget.speed"
        public static let all = [status, data, speed]
    }
    public static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    public static func read() -> WidgetSnapshot? { url.flatMap { try? Data(contentsOf: $0) }.flatMap(decode) }
}
