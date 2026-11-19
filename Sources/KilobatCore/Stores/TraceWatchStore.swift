import AppKit
import Foundation
import Observation

/// Something to watch the route to, with the name the person picked it by.
public struct RouteTarget: Hashable, Sendable, Identifiable {
    public var id: String { host }
    public let host: String
    public let label: String?
    public let kind: Kind
    public enum Kind: String, Sendable { case typed, router, internet, game, call }
    public init(host: String, label: String? = nil, kind: Kind = .typed) { self.host = host; self.label = label; self.kind = kind }

    /// Calls are watched to the service's own network (its web address), not to the media server a call lands on,
    /// which only the app in the call knows.
    public static let calls = [RouteTarget(host: "zoom.us", label: "Zoom", kind: .call),
                               RouteTarget(host: "meet.google.com", label: "Google Meet", kind: .call),
                               RouteTarget(host: "teams.microsoft.com", label: "Microsoft Teams", kind: .call)]
    public static let internet = [RouteTarget(host: "1.1.1.1", label: "Cloudflare DNS (1.1.1.1)", kind: .internet),
                                  RouteTarget(host: "8.8.8.8", label: "Google DNS (8.8.8.8)", kind: .internet)]

    /// What the app already knows: the router, two public resolvers, the person's games at their best region, call services.
    public static func presets(router: String?, games: [RouteTarget]) -> [RouteTarget] {
        let routerTarget = router.flatMap { ExpertTools.validHost($0) ? RouteTarget(host: $0, label: String(localized: "Your router (\($0))", comment: "Route watch preset"), kind: .router) : nil }
        var seen = Set<String>()
        return ([routerTarget].compactMap { $0 } + internet + games + calls).filter { seen.insert($0.host).inserted }
    }
}

/// Route watches the person starts in the app: up to four at once, each re-tracing its host on an interval for a set
/// time, stopped together when the Mac sleeps or the network changes (that's recorded on each watch), saved to the
/// survey journal as they go so route history and the CLI see them.
@MainActor @Observable public final class TraceWatchStore {
    public static let shared = TraceWatchStore()
    public static let maxRunning = 4
    /// Seconds between rounds the app offers; 5 is the default.
    public static let intervals: [Double] = [2, 5, 10, 30]
    /// How long a watch runs; nil is until stopped. 15 minutes is the default; four hours the longest set time.
    public static let durations: [Double?] = [300, 900, 1800, 3600, 7200, 14400, nil]
    /// Saved to disk at most this often while running, and always at the end.
    static let saveEvery: TimeInterval = 60

    public struct Session: Identifiable {
        public var id: UUID { watch.id }
        public var watch: WatchedRoute
        public var alerts: Bool
        public var rule: RouteAlertRule
        public var trouble: RouteAlertRule.Trouble?
        var latch = RouteAlertLatch()
        var savedAt = Date.distantPast
    }

    public private(set) var sessions: [Session] = []
    public var running: [Session] { sessions.filter { $0.watch.running } }
    public var canStart: Bool { running.count < Self.maxRunning }

    /// Where watches are saved; the app passes its survey journal.
    @ObservationIgnored public var survey: SurveyJournal?
    /// Sends an alert under the app's connection-alerts setting and its 15-minute limit.
    @ObservationIgnored public var alert: ((String, String) -> Void)?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var ending: [UUID: WatchedRoute.End] = [:]
    @ObservationIgnored private var fingerprint: NetworkFingerprint?
    @ObservationIgnored private var routes: RouteWatch?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var routeCheck: Task<Void, Never>?

    public init() {}

    /// Starts one watch per target (up to the free slots), spread across the first interval so their traceroutes don't
    /// all launch together. Returns how many started.
    @discardableResult
    public func start(_ targets: [RouteTarget], options: TraceOptions = .standard, interval: Double = 5, duration: Double? = 900,
                      alerts: Bool = false, rule: RouteAlertRule = .standard) -> Int {
        listen()
        let free = Self.maxRunning - running.count
        let chosen = Array(targets.filter { ExpertTools.validHost($0.host) }.prefix(max(0, free)))
        if running.isEmpty { fingerprint = NetworkFingerprint.current() }
        for (index, target) in chosen.enumerated() {
            let id = UUID()
            let placeholder = WatchedRoute(id: id, host: target.host, label: target.label, started: Date(), interval: interval, duration: duration, options: options)
            sessions.insert(Session(watch: placeholder, alerts: alerts, rule: rule), at: 0)
            let delay = interval * Double(index) / Double(max(1, chosen.count))
            tasks[id] = Task { [weak self] in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                let ended = try? await ExpertTools.watchRoute(host: target.host, label: target.label, options: options, interval: interval, duration: duration, id: id,
                                                              stop: { [weak self] in self?.ending[id] }, each: { [weak self] watch in self?.update(watch) })
                self?.finish(id, ended)
            }
        }
        return chosen.count
    }

    public func stop(_ id: UUID) { if sessions.contains(where: { $0.id == id && $0.watch.running }) { ending[id] = .stopped } }
    public func stopAll(_ end: WatchedRoute.End = .stopped) { for session in running { ending[session.id] = end } }
    /// Forgets a finished watch from this list; it stays in history.
    public func dismiss(_ id: UUID) { sessions.removeAll { $0.id == id && !$0.watch.running } }
    public func setAlerts(_ on: Bool, for id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].alerts = on
    }

    private func update(_ watch: WatchedRoute) {
        guard let index = sessions.firstIndex(where: { $0.id == watch.id }) else { return }
        sessions[index].watch = watch
        let trouble = sessions[index].rule.trouble(in: watch)
        sessions[index].trouble = trouble
        if let last = watch.rounds.last, sessions[index].latch.update(trouble, at: last.t, rule: sessions[index].rule),
           sessions[index].alerts, watch.running, let trouble {
            let message = RouteAlertRule.message(trouble, watch: watch, history: RouteHistory(watch: watch))
            alert?(message.title, message.body)
        }
        if !watch.running || Date().timeIntervalSince(sessions[index].savedAt) >= Self.saveEvery {
            sessions[index].savedAt = Date()
            survey?.saveWatch(watch)
        }
    }

    private func finish(_ id: UUID, _ watch: WatchedRoute?) {
        tasks[id] = nil; ending[id] = nil
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let watch { sessions[index].watch = watch; survey?.saveWatch(watch) }
        else {
            // Never got going (an invalid host); keep a record that it ended.
            sessions[index].watch.end = .failed; sessions[index].watch.ended = Date()
        }
    }

    /// Sleep and network changes end every running watch: a round across either describes no single path.
    private func listen() {
        guard observers.isEmpty else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopAll(.slept) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveRunning() }
        })
        let watch = RouteWatch { [weak self] in Task { @MainActor in self?.routeChanged() } }
        watch.start(); routes = watch
    }
    private func routeChanged() {
        routeCheck?.cancel()
        routeCheck = Task { [weak self] in
            // macOS writes the new route's keys one at a time; read them once they've settled.
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, !self.running.isEmpty else { return }
            let now = NetworkFingerprint.current()
            if let before = self.fingerprint, now != before { self.stopAll(.networkChanged) }
        }
    }
    /// On quit: what each running watch has so far, marked as cut off.
    private func saveRunning() {
        for session in running {
            var watch = session.watch; watch.end = .quit; watch.ended = Date()
            survey?.saveWatch(watch)
        }
    }

    #if DEBUG
    public func preview(_ watches: [WatchedRoute], alerts: Bool = false) {
        sessions = watches.map { Session(watch: $0, alerts: alerts, rule: .standard) }
    }
    #endif
}
