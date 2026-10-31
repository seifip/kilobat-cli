import Foundation
import Observation
import UserNotifications

/// One sign-in on a network with a sign-in page: from the check that first went through to the last one that did.
public struct PortalSession: Codable, Sendable, Equatable {
    public var start: Date
    /// The last check that went through before the sign-in page came back, the earliest it could have ended.
    /// Warnings come from it, so they're early rather than late.
    public var end: Date?
    /// Seen from start to end without a break: no sleep, no other network, no reconnect. Only these teach the length.
    public var measured: Bool?
    /// The five-minute warning went out for this sign-in.
    public var warned: Bool?
    public init(start: Date, end: Date? = nil, measured: Bool? = nil, warned: Bool? = nil) {
        self.start = start; self.end = end; self.measured = measured; self.warned = warned
    }
    public var seconds: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

/// A network that showed a sign-in page, and the sign-ins seen on it. Kept on this Mac only.
public struct PortalNetwork: Codable, Sendable, Identifiable, Equatable {
    /// The network's key, as DiagnosticSnapshot.networkKey.
    public let id: String
    public var name: String
    /// The name typed on the This place card, when there is one.
    public var place: String?
    public var host: String?
    /// The sign-in page as it was last seen, to open again before the sign-in runs out.
    public var url: String?
    /// A length the sign-in page stated, in minutes.
    public var hintMinutes: Int?
    public var sessions: [PortalSession] = []
    public var firstSeen: Date
    public var lastSeen: Date
    /// The last check that went through while signed in.
    public var lastPassed: Date?
    public init(id: String, name: String, place: String? = nil, host: String? = nil, url: String? = nil, hintMinutes: Int? = nil,
                sessions: [PortalSession] = [], firstSeen: Date, lastSeen: Date, lastPassed: Date? = nil) {
        self.id = id; self.name = name; self.place = place; self.host = host; self.url = url; self.hintMinutes = hintMinutes
        self.sessions = sessions; self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.lastPassed = lastPassed
    }
    /// Sign-ins seen whole, five minutes or longer, the newest ten.
    public var measured: [TimeInterval] {
        Array(sessions.filter { $0.measured == true }.compactMap(\.seconds).filter { $0 >= 300 }.suffix(10))
    }
    /// How long a sign-in lasts here: the median of at least two seen whole, or one seen whole beside a length the
    /// page stated, whichever is shorter. Nil until then.
    public var typicalSeconds: TimeInterval? {
        let seen = measured
        if seen.count >= 2 { return PortalWatch.median(seen) }
        if let one = seen.first, let hintMinutes { return min(one, Double(hintMinutes) * 60) }
        return nil
    }
    public var openSession: PortalSession? { sessions.last.flatMap { $0.end == nil ? $0 : nil } }
}

/// Watches for the network's sign-in page, learns how long a sign-in lasts at each place, and warns before it runs out.
/// It never opens a browser itself and doesn't notify on joining a network, when macOS shows its own sign-in sheet.
@MainActor @Observable public final class PortalWatch {
    public enum Status: Equatable, Sendable {
        case none
        /// A sign-in page is in the way on a network that hasn't been signed in to lately.
        case signInNeeded
        /// The sign-in page came back on a network that was signed in to: it logged you out. `since` is the last check that went through.
        case loggedOut(since: Date)
        /// Signed in through the sign-in page, since `since`.
        case signedIn(since: Date)
    }
    public struct Notice: Equatable, Sendable {
        public enum Kind: String, Sendable { case warning, loggedOut }
        public let kind: Kind
        public let title: String
        public let body: String
        public let url: URL
    }
    public nonisolated static let category = "kilobat.portal"
    public nonisolated static let openAction = "open-sign-in"
    /// How long before the usual end the warning goes out, and the least time between two of them.
    public nonisolated static let lead: TimeInterval = 300, spacing: TimeInterval = 1200

    public private(set) var status: Status = .none
    public private(set) var networks: [PortalNetwork] = []
    /// The network the latest check was on.
    public private(set) var current: String?
    public private(set) var lastCheck: PortalCheck?
    public var warnings: Bool { didSet { UserDefaults.standard.set(warnings, forKey: "portalWarnings") } }
    /// Whether warnings and the time left may show: Kilobat Pro. Set by the app.
    @ObservationIgnored public var allowed: (@MainActor () -> Bool)?
    /// The This place name for a network key. Set by the app.
    @ObservationIgnored public var placeName: (@MainActor (String) -> String?)?
    @ObservationIgnored private var joinedAt: Date?
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var lastAlert = Date.distantPast
    @ObservationIgnored private var savedAt = Date.distantPast
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let notifies: Bool

    public init(directory: URL? = nil, notifies: Bool = true) {
        file = (directory ?? Self.directory).appendingPathComponent("captive-portals.json")
        self.notifies = notifies
        warnings = UserDefaults.standard.object(forKey: "portalWarnings") as? Bool ?? true
        networks = StoredJSON.read(file) ?? []
    }
    nonisolated static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat") }
    /// The networks the app learned, for the CLI.
    public nonisolated static func load(directory: URL? = nil) -> [PortalNetwork] {
        StoredJSON.read((directory ?? Self.directory).appendingPathComponent("captive-portals.json")) ?? []
    }

    public var record: PortalNetwork? { current.flatMap { key in networks.first { $0.id == key } } }
    /// For the diagnosis: true while a sign-in page is in the way on this network, false once a check went through.
    public var intercepting: Bool? { lastCheck.map { $0.state == .portal ? true : $0.state == .open ? false : nil } ?? nil }
    public var loggedOut: Bool { if case .loggedOut = status { true } else { false } }
    /// The place's name when it has one, otherwise the Wi-Fi's.
    public var placeOrNetwork: (place: String?, network: String?) { (record?.place, record?.name) }
    /// When the sign-in usually runs out, once the length is learned.
    public var expectedEnd: Date? {
        guard case .signedIn(let since) = status, let typical = record?.typicalSeconds else { return nil }
        return since.addingTimeInterval(typical)
    }
    public func remaining(now: Date = Date()) -> TimeInterval? { expectedEnd.map { $0.timeIntervalSince(now) } }
    /// The page to open: the one a check just found, the one seen on this network before, or Apple's check page,
    /// which a sign-in page in the way redirects to itself.
    public var signInURL: URL {
        if lastCheck?.state == .portal, let url = lastCheck?.url { return url }
        if let url = record?.url.flatMap(URL.init(string:)) { return url }
        return CaptivePortal.Endpoint.apple.url
    }

    /// Whether to look for a sign-in page on this check: on joining a network, when the internet check failed,
    /// on every check while one is in the way, around when a sign-in usually ends, and otherwise every 5 to 15 minutes.
    public func due(network key: String, internetFailed: Bool, now: Date = Date()) -> Bool {
        guard key == current, let checkedAt else { return true }
        let since = now.timeIntervalSince(checkedAt)
        if internetFailed { return since >= 10 }
        switch status {
        case .signInNeeded, .loggedOut: return true
        case .signedIn:
            if let end = expectedEnd, abs(end.timeIntervalSince(now)) <= 180 { return true }
            return since >= 300
        case .none: return since >= (record == nil ? 900 : 300)
        }
    }

    /// Takes one check on the network `key`. `identified` is false for Wi-Fi whose name macOS hides, which looks the
    /// same as any network behind the same router address, so nothing is learned there.
    @discardableResult
    public func observe(_ check: PortalCheck, network key: String, name: String, identified: Bool = true, now: Date = Date()) -> Notice? {
        if key != current { current = key; joinedAt = now; status = .none; lastCheck = nil }
        checkedAt = now
        guard check.state != .offline else { return nil }
        let wasIntercepted = lastCheck?.state == .portal
        lastCheck = check
        let place = placeName?(key)
        var notice: Notice?
        if check.state == .portal {
            guard identified else { status = .signInNeeded; return nil }
            var network = networks.first { $0.id == key } ?? PortalNetwork(id: key, name: name, firstSeen: now, lastSeen: now)
            let sameHost = network.host == nil || check.host == nil || network.host == check.host
            network.name = name; network.lastSeen = now
            if let place { network.place = place }
            if let host = check.host { network.host = host }
            if let url = check.url { network.url = url.absoluteString }
            if let hint = check.hintMinutes { network.hintMinutes = hint }
            if let index = network.sessions.indices.last, network.sessions[index].end == nil {
                let passed = max(network.sessions[index].start, network.lastPassed ?? network.sessions[index].start)
                // Seen whole: on this network since before that last good check, and no long gap since it.
                let whole = sameHost && (joinedAt ?? now) <= passed && now.timeIntervalSince(passed) <= 600
                network.sessions[index].end = passed; network.sessions[index].measured = whole
                status = .loggedOut(since: passed)
                if whole { notice = alert(.loggedOut, network: network, now: now) }
            } else if case .loggedOut = status {
            } else if let ended = network.sessions.last?.end, now.timeIntervalSince(ended) < 12 * 3600, sameHost {
                status = .loggedOut(since: ended)
            } else { status = .signInNeeded }
            network.sessions = Array(network.sessions.suffix(20))
            put(network); save()
        } else if let index = networks.firstIndex(where: { $0.id == key }) {
            var network = networks[index]
            if let place { network.place = place }
            if wasIntercepted || status == .signInNeeded || loggedOut {
                // The sign-in went through between the last check and this one.
                if let open = network.sessions.indices.last, network.sessions[open].end == nil { network.sessions[open].end = network.lastPassed ?? network.sessions[open].start }
                network.sessions.append(PortalSession(start: now))
                network.sessions = Array(network.sessions.suffix(20))
                network.lastPassed = now; network.lastSeen = now
                status = .signedIn(since: now)
                networks[index] = network; save()
            } else if let open = network.sessions.indices.last, network.sessions[open].end == nil {
                if now.timeIntervalSince(network.sessions[open].start) > 48 * 3600 {
                    network.sessions[open].end = network.lastPassed ?? network.sessions[open].start; network.sessions[open].measured = false
                    status = .none; networks[index] = network; save()
                } else {
                    network.lastPassed = now; network.lastSeen = now
                    status = .signedIn(since: network.sessions[open].start)
                    networks[index] = network
                    if now.timeIntervalSince(savedAt) > 300 { save() }
                }
            } else { status = .none }
        } else { status = .none }
        if let notice { post(notice, now: now) }
        return notice
    }

    /// The five-minute warning, when it's due. Call after each check.
    @discardableResult
    public func tick(now: Date = Date()) -> Notice? {
        guard allowed?() == true, warnings, let remaining = remaining(now: now), let key = current,
              let index = networks.firstIndex(where: { $0.id == key }), let open = networks[index].sessions.indices.last,
              networks[index].sessions[open].end == nil,
              let minutes = Self.warning(remaining: remaining, warned: networks[index].sessions[open].warned == true, lastAlert: lastAlert, now: now)
        else { return nil }
        networks[index].sessions[open].warned = true; save()
        let notice = alert(.warning, network: networks[index], minutes: minutes, now: now)
        if let notice { post(notice, now: now) }
        return notice
    }

    /// Minutes left to say in the warning, or nil when it isn't due: once per sign-in, within the last five minutes
    /// (and more than half a minute), and twenty minutes after the last one.
    public nonisolated static func warning(remaining: TimeInterval, warned: Bool, lastAlert: Date, now: Date) -> Int? {
        guard !warned, remaining > 30, remaining <= lead + 30, now.timeIntervalSince(lastAlert) >= spacing else { return nil }
        return min(Int(lead / 60), max(1, Int((remaining / 60).rounded())))
    }

    private func alert(_ kind: Notice.Kind, network: PortalNetwork, minutes: Int = 0, now: Date) -> Notice? {
        guard allowed?() == true, warnings, kind == .warning || now.timeIntervalSince(lastAlert) >= Self.spacing else { return nil }
        let place = network.place, name = network.name
        let url = network.url.flatMap(URL.init(string:)) ?? CaptivePortal.Endpoint.apple.url
        switch kind {
        case .warning:
            let title = place.map { String(localized: "The Wi-Fi at \($0) will log you out in \(minutes) min", comment: "Notification: a hotel or café Wi-Fi's sign-in is about to run out; the arguments are the place's name and minutes") }
                ?? String(localized: "\(name) will log you out in \(minutes) min", comment: "Notification: a hotel or café Wi-Fi's sign-in is about to run out; the arguments are the Wi-Fi's name and minutes")
            let length = network.typicalSeconds.map(Self.length) ?? ""
            return Notice(kind: kind, title: title, body: String(localized: "Sign-ins here usually last about \(length). Open the sign-in page to sign in again before it runs out.", comment: "Notification body before a Wi-Fi sign-in runs out; the argument is a length such as 1 h"), url: url)
        case .loggedOut:
            let title = place.map { String(localized: "Logged out by the Wi-Fi at \($0)", comment: "Notification: a hotel or café Wi-Fi's sign-in page logged the Mac out; the argument is the place's name") }
                ?? String(localized: "Logged out by \(name)", comment: "Notification: a hotel or café Wi-Fi's sign-in page logged the Mac out; the argument is the Wi-Fi's name")
            return Notice(kind: kind, title: title, body: String(localized: "Its sign-in page wants you to sign in again. Your internet isn’t down.", comment: "Notification body when a Wi-Fi sign-in ran out"), url: url)
        }
    }

    private func post(_ notice: Notice, now: Date) {
        lastAlert = now
        guard notifies else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title; content.body = notice.body
        content.categoryIdentifier = Self.category
        content.userInfo = ["portalURL": notice.url.absoluteString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "portal-" + notice.kind.rawValue, content: content, trigger: nil))
    }

    private func put(_ network: PortalNetwork) {
        if let index = networks.firstIndex(where: { $0.id == network.id }) { networks[index] = network } else { networks.append(network) }
        networks = Array(networks.sorted { $0.lastSeen < $1.lastSeen }.suffix(100))
    }
    private func save() {
        savedAt = Date()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(networks).write(to: file, options: .atomic)
    }

    /// The status from the stored history and one check, for the CLI, which has no memory of earlier checks.
    public nonisolated static func status(of network: PortalNetwork?, check: PortalCheck, now: Date = Date()) -> Status {
        switch check.state {
        case .offline: return .none
        case .open: return network?.openSession.map { .signedIn(since: $0.start) } ?? .none
        case .portal:
            guard let network else { return .signInNeeded }
            let sameHost = network.host == nil || check.host == nil || network.host == check.host
            if let open = network.openSession { return .loggedOut(since: max(open.start, network.lastPassed ?? open.start)) }
            if let ended = network.sessions.last?.end, now.timeIntervalSince(ended) < 12 * 3600, sameHost { return .loggedOut(since: ended) }
            return .signInNeeded
        }
    }

    public nonisolated static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    /// "45 min", "1 h", "1 h 30 min": to the minute under an hour, to five minutes above.
    public nonisolated static func length(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return String(localized: "\(minutes) min", comment: "A length of time in minutes") }
        let rounded = Int((Double(minutes) / 5).rounded()) * 5, hours = rounded / 60, rest = rounded % 60
        return rest == 0 ? String(localized: "\(hours) h", comment: "A length of time in hours")
            : String(localized: "\(hours) h \(rest) min", comment: "A length of time in hours and minutes")
    }

    #if DEBUG
    /// Made-up state for screenshots; debug builds only. Nothing is saved.
    public func preview(_ network: PortalNetwork, status: Status, check: PortalCheck?) {
        networks = [network]; current = network.id; self.status = status; lastCheck = check
    }
    #endif
}
