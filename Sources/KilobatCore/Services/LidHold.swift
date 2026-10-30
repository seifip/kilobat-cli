import Foundation

/// A hold on sleep with the lid closed. Only Kilobat's power helper, running as root, can place one.
public struct LidLease: Codable, Equatable, Sendable {
    public var until: Date
    public var reason: String
    /// On battery, the hold ends at this percentage.
    public var batteryFloor: Int
    public var onlyOnAC: Bool
    public init(until: Date, reason: String, batteryFloor: Int = 20, onlyOnAC: Bool = false) {
        self.until = until; self.reason = reason; self.batteryFloor = batteryFloor; self.onlyOnAC = onlyOnAC
    }
    /// "until 18:30 · releases at 20% battery".
    public var summary: String {
        let time = until.formatted(date: .omitted, time: .shortened)
        return onlyOnAC ? String(localized: "until \(time) · on power only") : String(localized: "until \(time) · releases at \(batteryFloor)% battery")
    }
}

/// Why a hold ended, for "Let the Mac sleep: battery at 20%".
public struct LidRelease: Codable, Equatable, Sendable {
    public var reason: String
    public var date: Date
    public init(reason: String, date: Date) { self.reason = reason; self.date = date }
}

/// What the helper holds, since when, and how the last hold ended.
public struct LidHoldStatus: Codable, Equatable, Sendable {
    public var lease: LidLease?
    public var since: Date?
    public var released: LidRelease?
    public init(lease: LidLease? = nil, since: Date? = nil, released: LidRelease? = nil) { self.lease = lease; self.since = since; self.released = released }
}

/// Places the lid holds SessionStore asks for: in the app, the power helper's client. Nil lifts the hold.
@MainActor public protocol LidHolding: AnyObject {
    func request(_ lease: LidLease?)
}

/// The helper's one XPC service. Leases and statuses travel as JSON.
@objc(KilobatLidService) public protocol LidService {
    func hold(_ lease: Data, reply: @escaping (Data) -> Void)
    func release(_ reason: String, reply: @escaping (Data) -> Void)
    func status(reply: @escaping (Data) -> Void)
}

/// The rules every lid hold follows, in the helper and the app alike.
public enum LidPolicy {
    /// The helper's launchd label and Mach service; its plist is this plus .plist.
    public static let label = "co.seifi.kilobat.power"
    /// However long a hold asks for, the Mac sleeps after 8 hours of holding.
    public static let longest: TimeInterval = 8 * 3600
    /// The app may restart or reconnect within this; after it, its hold ends.
    public static let grace: TimeInterval = 60
    /// An agent waiting for an answer keeps the lid hold at most this long.
    public static let waiting: TimeInterval = 30 * 60
    public static let floors = 5...90

    /// Why a hold has to end now, or nil while it may go on. Heat and low battery always win.
    public static func stop(_ lease: LidLease, since: Date, power: PowerState, now: Date, disconnected: Date? = nil) -> String? {
        if let disconnected, now.timeIntervalSince(disconnected) >= grace { return "Kilobat quit" }
        if PowerState.heat(power.thermal) >= PowerState.heat("serious") { return "running hot" }
        if lease.onlyOnAC && !power.onAC { return "unplugged" }
        if !power.onAC, let percent = power.batteryPercent, percent <= lease.batteryFloor { return "battery at \(percent)%" }
        if now >= min(lease.until, since + longest) { return "time limit reached" }
        return nil
    }

    /// A request as the helper takes it: a short reason, a floor in range, and no later than 8 hours after holding began.
    public static func clamp(_ lease: LidLease, since: Date) -> LidLease {
        var lease = lease
        lease.until = min(lease.until, since + longest)
        lease.reason = String(lease.reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if lease.reason.isEmpty { lease.reason = "Kilobat" }
        lease.batteryFloor = min(floors.upperBound, max(floors.lowerBound, lease.batteryFloor))
        return lease
    }

    /// SleepDisabled from `pmset -g`, nil when it isn't listed.
    public static func sleepDisabled(_ pmset: String) -> Bool? {
        for line in pmset.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[0] == "SleepDisabled" { return fields[1] == "1" }
        }
        return nil
    }
}

/// The helper's state: one lease, the failsafes that end it, and a marker that undoes SleepDisabled after a crash or a reboot.
/// Not thread-safe; the helper calls it from one queue.
public final class LidKeeper: @unchecked Sendable {
    /// What the keeper does to the Mac, swapped out in tests and dry runs.
    public struct System: Sendable {
        public var sleepDisabled: @Sendable () -> Bool?
        public var setSleepDisabled: @Sendable (Bool) -> Bool
        public var power: @Sendable () -> PowerState
        public init(sleepDisabled: @escaping @Sendable () -> Bool?, setSleepDisabled: @escaping @Sendable (Bool) -> Bool, power: @escaping @Sendable () -> PowerState) {
            self.sleepDisabled = sleepDisabled; self.setSleepDisabled = setSleepDisabled; self.power = power
        }
    }
    /// Written before SleepDisabled changes: what it was, so it can be put back.
    struct Marker: Codable, Equatable { var previous: Bool; var since: Date }

    public private(set) var lease: LidLease?
    public private(set) var since: Date?
    public private(set) var released: LidRelease?
    /// When the app holding the lease disconnected; nil while it is connected.
    public private(set) var disconnected: Date?
    private let system: System
    private let directory: URL
    private var markerURL: URL { directory.appendingPathComponent("marker.json") }
    private var releasedURL: URL { directory.appendingPathComponent("released.json") }

    public init(directory: URL, system: System) {
        self.directory = directory; self.system = system
        released = (try? Data(contentsOf: releasedURL)).flatMap { try? JSONDecoder().decode(LidRelease.self, from: $0) }
    }

    public var status: LidHoldStatus { LidHoldStatus(lease: lease, since: since, released: released) }
    var marker: Marker? { (try? Data(contentsOf: markerURL)).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) } }

    /// At launch no lease is live, so a marker means the helper stopped while holding: put SleepDisabled back.
    public func start(now: Date = Date()) {
        guard let marker else { return }
        restore(marker, reason: "Kilobat’s helper restarted", now: now)
    }

    public func hold(_ request: LidLease, now: Date = Date()) -> LidHoldStatus {
        disconnected = nil
        let start = since ?? now, lease = LidPolicy.clamp(request, since: start)
        // A hold that would end at once never starts.
        if let reason = LidPolicy.stop(lease, since: start, power: system.power(), now: now) {
            return self.lease == nil ? record(reason, now: now) : release(reason, now: now)
        }
        if self.lease == nil {
            guard let previous = system.sleepDisabled() else { return record("couldn’t read the power settings", now: now) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(Marker(previous: previous, since: now)).write(to: markerURL, options: .atomic)
            } catch { return record("couldn’t save its state", now: now) }
            // Already on (another tool, or by hand): leave it, and leave it on afterwards.
            if !previous && !system.setSleepDisabled(true) {
                try? FileManager.default.removeItem(at: markerURL)
                return record("macOS refused", now: now)
            }
            since = now
        }
        self.lease = lease
        return status
    }

    @discardableResult public func release(_ reason: String, now: Date = Date()) -> LidHoldStatus {
        lease = nil; since = nil; disconnected = nil
        if let marker { restore(marker, reason: reason, now: now) } else { _ = record(reason, now: now) }
        return status
    }

    /// The app holding the lease went away; its hold ends after the grace period unless it comes back.
    public func disconnect(now: Date = Date()) { if lease != nil { disconnected = now } }

    /// Runs the failsafes. The helper calls this every few seconds.
    @discardableResult public func check(now: Date = Date()) -> LidHoldStatus {
        guard let lease, let since else { return status }
        if let reason = LidPolicy.stop(lease, since: since, power: system.power(), now: now, disconnected: disconnected) { return release(reason, now: now) }
        return status
    }

    private func restore(_ marker: Marker, reason: String, now: Date) {
        // If putting it back fails, the marker stays and the next launch tries again.
        if marker.previous || system.setSleepDisabled(false) { try? FileManager.default.removeItem(at: markerURL) }
        _ = record(reason, now: now)
    }

    private func record(_ reason: String, now: Date) -> LidHoldStatus {
        released = LidRelease(reason: reason, date: now)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(released).write(to: releasedURL, options: .atomic)
        return status
    }
}

/// How the CLI and the MCP server ask the app for a lid hold over the relay. The owner is the asking process;
/// its hold ends when that process exits.
public enum LidRelayRequest: Equatable, Sendable {
    case hold(until: Date, owner: Int32, reason: String)
    case release(owner: Int32)

    /// lid|hold|<until, Unix seconds>|<pid>|<reason>, or lid|release|<pid>.
    public var action: String {
        switch self {
        case .hold(let until, let owner, let reason): "lid|hold|\(Int(until.timeIntervalSince1970))|\(owner)|" + reason.replacingOccurrences(of: "\n", with: " ").prefix(80)
        case .release(let owner): "lid|release|\(owner)"
        }
    }

    public init?(_ action: String) {
        let parts = action.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "lid" else { return nil }
        switch parts[1] {
        case "hold":
            guard parts.count == 5, let seconds = Int(parts[2]), let owner = Int32(parts[3]), owner > 0, parts[4].count <= 80 else { return nil }
            self = .hold(until: Date(timeIntervalSince1970: TimeInterval(seconds)), owner: owner, reason: parts[4].isEmpty ? "Command line" : parts[4])
        case "release":
            guard parts.count == 3, let owner = Int32(parts[2]), owner > 0 else { return nil }
            self = .release(owner: owner)
        default: return nil
        }
    }
}
