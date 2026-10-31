import AppKit
import Foundation
import Observation
import UserNotifications

/// Big uploads and the ones held for later. Every two seconds it reads each app's Internet bytes sent from the traffic
/// list, finds the ones that keep uploading a lot (`UploadTracker`), and checks what each held upload waits for.
/// Holding reuses call mode: sync and backup apps are suspended through its ledger as the `upload` owner, and the
/// filter refuses their new connections with a temporary rule renewed while the hold lasts. Everything resumes when
/// the condition is met, when you send it or switch to the app, after `SendLater.limit`, when Kilobat quits, and, from
/// the ledger, at the next launch after a crash.
@MainActor @Observable public final class UploadStore {
    public static let shared = UploadStore()
    /// Big uploads now, the busiest first, then the held ones.
    public private(set) var uploads: [BigUpload] = []
    public private(set) var holds: [UploadHold] = []
    /// Bytes per second that count as a big upload on this network.
    public private(set) var threshold = SendLater.floorRate
    /// Whether holding may be used: the app answers with the license.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    @ObservationIgnored public var filterActive: () -> Bool = { false }
    @ObservationIgnored public var frontmost: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// The newest speed test's upload in Mbps on a network key.
    @ObservationIgnored public var uplink: (String) -> Double? = { _ in nil }
    @ObservationIgnored public var notify: (String, String) -> Void = UploadStore.post
    /// Reads how far a command-line uploader is through its file.
    @ObservationIgnored public var progress: (Int32, UInt64?) -> UploadProgress? = { SendLater.progress(pid: $0, sent: $1) }
    /// The processes of running apps with a bundle ID.
    @ObservationIgnored public var running: (String) -> [Int32] = { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) }
    @ObservationIgnored private weak var traffic: TrafficStore?
    @ObservationIgnored private var tracker = UploadTracker()
    @ObservationIgnored private var live: [UploadTracker.Live] = []
    @ObservationIgnored private var last: [String: (sent: UInt64, local: UInt64)] = [:]
    @ObservationIgnored private var lastTick: Date?
    /// App IDs whose temporary block is this store's, so only those are cleared.
    @ObservationIgnored private var blocked: [String: Set<String>] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    private let ledger: URL
    private let defaults: UserDefaults

    public init(ledger: URL = CallMode.ledgerURL, defaults: UserDefaults = .standard) {
        self.ledger = ledger; self.defaults = defaults
        // Whatever a previous run left suspended resumes before this one holds anything.
        CallMode.recoverAtLaunch(ledger: ledger)
    }

    /// Networks you said are fast enough, by key.
    public var fastNetworks: Set<String> { Set(defaults.stringArray(forKey: "uploadFastNetworks") ?? []) }

    /// Follows `traffic`, sampling every two seconds unless `polling` is false (tests call `tick` themselves).
    public func start(traffic: TrafficStore, polling: Bool = true) {
        self.traffic = traffic
        guard polling, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.tick()
            }
        }
    }

    /// The network the conditions are checked against.
    public var network: UploadNetwork? {
        guard let traffic else { return nil }
        return UploadNetwork(key: traffic.networkKey, name: traffic.networkName, connected: traffic.connected, metered: traffic.metered,
                             uploadMbps: uplink(traffic.networkKey), markedFast: fastNetworks.contains(traffic.networkKey))
    }

    public func tick(now: Date = Date()) {
        guard let traffic else { return }
        let elapsed = lastTick.map { max(0.5, now.timeIntervalSince($0)) } ?? 2
        lastTick = now
        threshold = SendLater.threshold(uplinkMbps: uplink(traffic.networkKey))
        var readings: [UploadTracker.Reading] = [], seen: Set<String> = []
        for app in traffic.apps where !app.carrier {
            seen.insert(app.id)
            let before = last[app.id]
            last[app.id] = (app.sent, app.local)
            guard let before, app.sent >= before.sent, app.local >= before.local else { continue }
            // Local-network bytes (a NAS, AirDrop) don't cost anything; the app's local bytes go both ways, so this
            // can only undercount an Internet upload, never invent one.
            let sent = app.sent - before.sent, local = app.local - before.local
            guard sent > local else { continue }
            let identity = SendLater.identity(id: app.id, name: app.name, pid: app.processIDs.first)
            readings.append(.init(key: identity.key, name: identity.name, bytes: sent - local))
        }
        last = last.filter { seen.contains($0.key) }
        live = tracker.observe(readings, elapsed: elapsed, threshold: threshold, now: now)
        checkHolds(traffic: traffic, now: now)
        publish()
    }

    /// The row's list from the last sample's big uploads and what's held.
    private func publish() {
        guard let traffic else { return }
        var next: [BigUpload] = []
        for item in live where !holds.contains(where: { $0.key == item.key }) {
            let members = apps(item.key, in: traffic)
            let first = members.first
            let plan = SendLater.plan(id: first?.id ?? item.key, bundlePath: first?.bundlePath, carrier: first?.carrier ?? false)
            var progress: UploadProgress?
            if members.contains(where: { SendLater.knowsTotal(id: $0.id) }) {
                for pid in members.flatMap(\.processIDs) { if let found = self.progress(pid, traffic.sentSinceStart(pid: pid)) { progress = found; break } }
            }
            next.append(BigUpload(key: item.key, name: item.name, apps: members.map(\.id), bundlePath: first?.bundlePath, rate: item.rate, sent: item.sent,
                                  since: item.since, progress: progress, method: plan.method, reason: plan.reason))
        }
        for hold in holds {
            let members = apps(hold.key, in: traffic)
            next.append(BigUpload(key: hold.key, name: hold.name, apps: members.map(\.id), bundlePath: members.first?.bundlePath, rate: 0, sent: hold.sent,
                                  since: hold.since, method: hold.method, reason: nil, hold: hold))
        }
        if next != uploads { uploads = next }
    }

    /// The processes of these apps now: what the traffic list saw, and every running app with one of their IDs.
    private func processes(_ members: [AppTraffic]) -> [Int32] {
        Array(Set(members.flatMap(\.processIDs) + members.flatMap { running($0.id) })).sorted()
    }

    /// Whether anything of a held app still runs.
    private func running(_ hold: UploadHold, members: [AppTraffic]) -> Bool {
        if hold.method == .suspend, CallMode.held(ledger: ledger).contains(where: { $0.app == hold.key && $0.holders.contains(SendLater.owner) && CallMode.startTime($0.pid) == $0.started }) { return true }
        return members.contains { !running($0.id).isEmpty || $0.processIDs.contains { CallMode.startTime($0) != nil } }
    }

    /// The traffic list's apps grouped under `key`.
    private func apps(_ key: String, in traffic: TrafficStore) -> [AppTraffic] {
        traffic.apps.filter { SendLater.identity(id: $0.id, name: $0.name, pid: $0.processIDs.first).key == key }
    }

    /// Holds the upload with `key` (a big upload's key, an app's ID or its name) until `condition`, or the one-click
    /// default for this network when nil.
    @discardableResult public func hold(_ key: String, until condition: UploadCondition? = nil, now: Date = Date()) throws -> UploadHold {
        guard let traffic, let network else { throw UploadError(String(localized: "Kilobat is still starting.", comment: "Send later: asked to hold before the traffic list is ready")) }
        guard allowed() else { throw UploadError(String(localized: "Send later is part of Kilobat Pro.", comment: "Send later: holding needs Pro")) }
        let wanted = key.lowercased()
        let target = uploads.first { $0.key.lowercased() == wanted || $0.name.lowercased() == wanted || $0.apps.contains { $0.lowercased() == wanted } }?.key
            ?? traffic.apps.first { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted || CallMode.name(of: $0.id)?.lowercased() == wanted }
                .map { SendLater.identity(id: $0.id, name: $0.name, pid: $0.processIDs.first).key }
        guard let target else { throw UploadError(String(localized: "No running app called \(key) is uploading.", comment: "Send later: the app to hold isn't running")) }
        if let held = holds.first(where: { $0.key == target }) { return held }
        let members = apps(target, in: traffic)
        guard let first = members.first else { throw UploadError(String(localized: "No running app called \(key) is uploading.", comment: "Send later: the app to hold isn't running")) }
        let name = SendLater.identity(id: first.id, name: first.name, pid: first.processIDs.first).name
        let plan = SendLater.plan(id: first.id, bundlePath: first.bundlePath, carrier: first.carrier)
        if let reason = plan.reason, plan.method == .none { throw UploadError(reason) }
        let condition = condition ?? .automatic(metered: network.metered)
        if condition.kind == .unmetered, !network.metered { throw UploadError(String(localized: "This network isn’t metered, so \(name) would go again at once. Hold it until a faster network or for a while instead.", comment: "Send later: --until unmetered on an unmetered network")) }
        if condition.met(on: network, now: now) { throw UploadError(String(localized: "This network already is what \(name) would wait for.", comment: "Send later: the condition is already met")) }
        switch plan.method {
        case .suspend:
            if let front = frontmost(), members.contains(where: { $0.id == front }) || CallMode.name(of: front) == target {
                throw UploadError(String(localized: "\(name) is in front. Switch to another app first: Kilobat never pauses the app you’re using.", comment: "Send later: never suspends the frontmost app"))
            }
            let held = CallMode.hold(processes(members), app: target, owner: SendLater.owner, ledger: ledger)
            guard !held.isEmpty || CallMode.held(ledger: ledger).contains(where: { $0.app == target && $0.holders.contains(SendLater.owner) }) else {
                throw UploadError(String(localized: "Kilobat couldn’t pause \(name).", comment: "Send later: suspending failed"))
            }
        case .block:
            guard filterActive(), traffic.preferences.profile != .unrestricted else {
                throw UploadError(String(localized: "Holding \(name) needs the network filter on, in a profile other than Unrestricted.", comment: "Send later: block-only apps need the filter"))
            }
        case .none: throw UploadError(plan.reason ?? "")
        }
        let sent = uploads.first { $0.key == target }?.sent ?? 0
        let hold = UploadHold(key: target, name: name, method: plan.method, condition: condition, since: now, network: network.name, sent: sent)
        holds.append(hold)
        refuse(hold, members: members, traffic: traffic)
        tracker.forget(target)
        live.removeAll { $0.key == target }
        publish()
        return hold
    }

    /// Lets a held upload go now. Returns false when nothing by that name is held.
    @discardableResult public func resume(_ key: String) -> Bool {
        let wanted = key.lowercased()
        guard let hold = holds.first(where: { $0.key.lowercased() == wanted || $0.name.lowercased() == wanted || (blocked[$0.key] ?? []).contains { $0.lowercased() == wanted } }) else { return false }
        release(hold, reason: .manual)
        publish()
        return true
    }

    /// This network is fast enough: uploads waiting for a faster one go now, and next time too.
    public func markFast() {
        guard let key = traffic?.networkKey, key != "unknown" else { return }
        defaults.set((fastNetworks.union([key])).sorted(), forKey: "uploadFastNetworks")
        if let traffic { checkHolds(traffic: traffic, now: lastTick ?? Date()) }
        publish()
    }

    /// Kilobat is quitting: everything goes again, and the ledger is empty for the next launch.
    public func quit() {
        for hold in holds { release(hold, reason: .quit) }
    }

    private func checkHolds(traffic: TrafficStore, now: Date) {
        guard let network else { return }
        let front = frontmost()
        for hold in holds {
            let members = apps(hold.key, in: traffic)
            if now >= hold.deadline { release(hold, reason: .limit); continue }
            if hold.condition.met(on: network, now: now) { release(hold, reason: .condition); continue }
            if hold.method == .suspend, let front, members.contains(where: { $0.id == front }) || CallMode.name(of: front) == hold.key { release(hold, reason: .opened); continue }
            if !running(hold, members: members) { release(hold, reason: .exited); continue }
            // Helpers started since are held too, and the filter's rule renewed before it lapses.
            if hold.method == .suspend { CallMode.hold(processes(members), app: hold.key, owner: SendLater.owner, ledger: ledger) }
            refuse(hold, members: members, traffic: traffic)
        }
    }

    /// The filter refuses the held app's new connections, for whatever a suspended app hands to a helper. The rule
    /// is temporary and renewed here, so after a crash it lapses on its own within `SendLater.blockMinutes`.
    private func refuse(_ hold: UploadHold, members: [AppTraffic], traffic: TrafficStore) {
        for app in members {
            let mine = blocked[hold.key, default: []].contains(app.id)
            if let rule = traffic.temporaryRule(app.id) {
                guard mine, !rule.allowed, rule.expires.timeIntervalSinceNow < Double(SendLater.blockMinutes * 60) / 3 else { continue }
            }
            traffic.setTemporary(app.id, allowed: false, minutes: SendLater.blockMinutes)
            blocked[hold.key, default: []].insert(app.id)
        }
    }

    private func release(_ hold: UploadHold, reason: UploadResume) {
        if hold.method == .suspend { CallMode.resume(app: hold.key, owner: SendLater.owner, ledger: ledger) }
        for id in blocked[hold.key] ?? [] { traffic?.clearTemporary(id) }
        blocked[hold.key] = nil
        holds.removeAll { $0.key == hold.key }
        uploads.removeAll { $0.key == hold.key }
        let place = network?.name ?? ""
        switch reason {
        case .condition: notify(String(localized: "Upload resumed", comment: "Notification title: a held upload went again"),
                                String(localized: "\(hold.name)’s upload resumed on \(place).", comment: "Notification: 'Dropbox’s upload resumed on Home Wi-Fi'"))
        case .limit: notify(String(localized: "Upload resumed", comment: "Notification title: a held upload went again"),
                            String(localized: "\(hold.name)’s upload resumed after 8 hours, the longest Kilobat holds one.", comment: "Notification: a held upload reached the limit"))
        case .manual, .opened, .exited, .quit: break
        }
    }

    /// The report for `kilobat uploads --json` and MCP.
    public func report() -> UploadsReport {
        let network = network
        return UploadsReport(appRunning: true, network: network?.name, metered: network?.metered, uplinkMbps: network?.uploadMbps, thresholdBytesPerSecond: threshold,
                             filterActive: filterActive(), pro: allowed(), uploads: uploads.map(UploadsReport.entry), limits: UploadsReport.limits)
    }

    /// The CLI's requests over the relay: `uploads`, `uploads|hold|<app>|<until>` and `uploads|resume|<app>`.
    /// Holding only ever stops an app, which anything on the Mac could do to its own processes anyway, so it acts at once.
    public func answer(_ action: String) -> Data? {
        let parts = action.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        func reply(_ value: [String: Any]) -> Data? {
            var value = value
            if let report = try? encoder.encode(report()), let object = try? JSONSerialization.jsonObject(with: report) { value["report"] = object }
            return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        switch parts.count > 1 ? parts[1] : "" {
        case "":
            return try? encoder.encode(report())
        case "hold" where parts.count == 4:
            do {
                let hold = try hold(parts[2], until: try UploadCondition.parse(parts[3]))
                return reply(["held": true, "app": hold.key, "name": hold.name, "method": hold.method.rawValue, "until": hold.condition.phrase])
            } catch { return reply(["held": false, "error": error.localizedDescription]) }
        case "resume" where parts.count >= 3:
            return reply(["resumed": resume(parts[2])])
        default: return nil
        }
    }

    #if DEBUG
    /// Made-up uploads for screenshots; debug builds only.
    public func preview(_ uploads: [BigUpload]) { loop?.cancel(); loop = nil; traffic = nil; self.uploads = uploads; holds = uploads.compactMap(\.hold) }
    #endif

    /// Notifications need an app bundle; macOS asks for permission once, the first time there is something to say.
    nonisolated static func post(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
}
