import AppKit
import Darwin
import Observation

@MainActor @Observable
public final class TrafficStore {
    public var apps: [AppTraffic] = []
    public var download: Double = 0
    public var upload: Double = 0
    public var downloadHistory = Array(repeating: 0.0, count: 60)
    public var uploadHistory = Array(repeating: 0.0, count: 60)
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public var connected = false
    /// What macOS says about the current path; `metered` is what Kilobat acts on.
    public var osExpensive = false
    public var networkKind = String(localized: "Connecting")
    public var ready = false
    public var error: String?
    public var search = ""
    public var filter = "All apps"
    public var selectedApp: String?
    public var preferences: SavedPreferences {
        didSet {
            guard preferences != oldValue else { return }
            // The budget always describes the current network; keeping its copy current means a relaunch,
            // which starts on no network, can't lose a plan set since the last switch.
            if recordHistory, networkKey != "unknown", preferences.limitGB != oldValue.limitGB || preferences.budgetCycle != oldValue.budgetCycle {
                preferences.networkLimits = (preferences.networkLimits ?? [:]).merging([networkKey: preferences.limitGB]) { $1 }
                preferences.networkCycles = Self.cycles(preferences.networkCycles, preferences.budgetCycle, for: networkKey)
            }
            if !reloading { savePreferences() }
            if preferences.networkCost != oldValue.networkCost, lastMetered != nil { costChanged() }
        }
    }
    public var usage: [UsageEntry] = []
    public var networkKey = "unknown"
    public var networkName = "Current session"
    public var networkSessions: [String: NetworkSession] = [:]
    /// When the Mac slept, so a gap in the history can say so. A sleep that ends in a shutdown has no wake and isn't kept.
    public private(set) var sleeps: [DateInterval] = []
    private var sleptAt: Date?
    /// False while Kilobat can't tell this network from others behind the same router, such as Wi-Fi whose name macOS hides.
    public private(set) var networkIdentified = false
    public let startedAt = Date()
    /// This network's bytes to the local network, AirDrop and nearby devices, kept out of `received` and `sent`.
    public var local: UInt64 = 0
    /// Bytes Wi-Fi and Ethernet carried that no process accounts for, already in `received` and `sent`: packet headers and acknowledgments, processes
    /// that came and went between samples, Internet Sharing, a VPN macOS runs itself.
    public var unattributed: UInt64 = 0
    /// This session's bytes through VPN tunnels, counted once where the tunnel leaves the Mac.
    public private(set) var tunnel: UInt64 = 0
    private var previous: [Int32: SeenProcess] = [:]
    private var lastSample: Date?
    private var pendingReceived: UInt64 = 0
    private var pendingSent: UInt64 = 0
    private var pendingApps: [String: UInt64] = [:]
    private var pendingAppsSent: [String: UInt64] = [:]
    private var pendingLocal: UInt64 = 0
    private var pendingAppsLocal: [String: UInt64] = [:]
    /// Internet bytes processes account for since the last flush, to tell what the interfaces carried beyond them.
    private var pendingAttributed: UInt64 = 0
    /// Interface counters, nil to count only what processes account for, as the tests do. A reading of nil is a failure.
    var readCounters: (() -> [String: ByteCount]?)? = nil
    var startTime: (Int32) -> Date? = TrafficAttribution.startTime
    private var interfaces = InterfaceTally()
    private var counterFailures = 0
    /// Local bytes nettop reported before the interface counters showed them.
    private var localCarry = ByteCount()
    private var wifiNames: Set<String> = []
    private var executables: [Int32: String] = [:]
    /// The last five minutes of each app's rates, one sample a second, for sparklines and the bandwidth panel.
    public private(set) var liveSeries: [String: LiveSeries] = [:]
    private var lastFlush = Date()
    private var identities: [Int32: (String, String, String?)] = [:]
    private let monitor = NettopMonitor()
    private var sampleGeneration = UUID()
    private let network = NetworkStatus()
    private let recordHistory: Bool
    private var lastPreferencesData: Data?
    private var reloading = false
    private var lastMetered: Bool?
    private let directory: URL

    /// `recordHistory: false` makes a read-only sampling store: it never records usage or changes preferences.
    public init(directory: URL? = nil, startMonitoring: Bool = true, recordHistory: Bool = true) {
        self.recordHistory = recordHistory
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        preferences = StoredJSON.read(self.directory.appendingPathComponent("preferences.json")) ?? SavedPreferences()
        lastPreferencesData = try? Data(contentsOf: self.directory.appendingPathComponent("preferences.json"))
        usage = Self.compact(StoredJSON.read(self.directory.appendingPathComponent("usage.json")) ?? [])
        networkSessions = StoredJSON.read(self.directory.appendingPathComponent("network-sessions.json")) ?? [:]
        sleeps = StoredJSON.read(self.directory.appendingPathComponent("sleeps.json")) ?? []
        if startMonitoring {
            readCounters = InterfaceCounters.read
            wifiNames = InterfaceCounters.wifiInterfaces()
            // Counters can jump across sleep; start over rather than count what can't be told apart.
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebaseline(); self?.woke() }
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.slept() }
            }
            startCollector(scope: preferences.trafficScope ?? "external")
            network.start { [weak self] connected, expensive, kind in
                Task { @MainActor in self?.pathChanged(connected: connected, expensive: expensive, kind: kind) }
            }
        }
    }

    func slept(at now: Date = Date()) { sleptAt = now }
    func woke(at now: Date = Date()) {
        guard recordHistory, let start = sleptAt, now > start else { sleptAt = nil; return }
        sleptAt = nil
        let cutoff = now.addingTimeInterval(-Double(preferences.historyDays ?? 365) * 86_400)
        sleeps = (sleeps + [DateInterval(start: start, end: now)]).filter { $0.end >= cutoff }
        persist(sleeps, as: "sleeps.json")
    }
    public var cost: NetworkCost { preferences.cost(of: networkKey) }
    public var metered: Bool { cost.metered(os: osExpensive) }
    func pathChanged(connected: Bool, expensive: Bool, kind: String) {
        self.connected = connected; osExpensive = expensive; networkKind = kind
        costChanged()
    }
    /// With networks marked by hand, the cost waits until Kilobat knows which network this is.
    private func costChanged() {
        guard networkKey != "unknown" || preferences.networkCost == nil else { return }
        meteredChanged(metered)
    }
    /// Sets what the current network costs. Refused while Kilobat can't tell this network apart.
    @discardableResult public func setCost(_ cost: NetworkCost) -> Bool {
        guard networkKey != "unknown", networkIdentified else { return false }
        preferences.setCost(cost, for: networkKey)
        return true
    }
    /// Wi-Fi names marked as hotspots before network cost existed become metered networks once Kilobat has seen them.
    /// Returns the names still waiting; a cost already chosen stays.
    public func adoptHotspots(_ names: [String]) -> [String] {
        var sessions = networkSessions
        if networkKey != "unknown" { sessions[networkKey] = session }
        var next = preferences, waiting: [String] = []
        for name in names {
            let keys = sessions.filter { $0.value.name == name && $0.value.identified != false }.map(\.key)
            if keys.isEmpty { waiting.append(name) }
            for key in keys where next.networkCost?[key] == nil { next.setCost(.metered, for: key) }
        }
        preferences = next
        return waiting
    }

    /// Travel is applied when a metered network appears, not on every path update, and the
    /// previous profile returns afterwards unless the user picked another one meanwhile.
    /// A profile remembered for the network wins over Travel.
    func meteredChanged(_ expensive: Bool) {
        defer { lastMetered = expensive }
        guard recordHistory, expensive != lastMetered else { return }
        var next = preferences
        if expensive {
            guard next.autoHotspot, next.profile != .travel, next.networkProfiles?[networkKey] == nil else { return }
            next.autoProfileFrom = next.profile.rawValue; next.profile = .travel
        } else if let previous = next.autoProfileFrom {
            if next.profile == .travel, let profile = NetworkProfile(rawValue: previous) { next.profile = profile }
            next.autoProfileFrom = nil
        }
        preferences = next
    }

    public var total: UInt64 { received + sent }
    public var limit: UInt64 { UInt64(preferences.limitGB * 1_000_000_000) }
    public var limitFraction: Double { min(1, Double(budgetUsedBytes) / Double(max(1, limit))) }
    public var budgetCycle: BudgetCycle { preferences.budgetCycle ?? BudgetCycle() }
    /// The current cycle on this network; nil for a session budget.
    public var budgetInterval: DateInterval? { budgetCycle.interval(containing: Date()) }
    /// Bytes counted against this network's budget.
    public var budgetUsedBytes: UInt64 { budgetUsed(on: networkKey) }
    /// A session budget uses the session counter; a cycle adds up history on that network since it began,
    /// so a monthly plan survives restarts.
    public func budgetUsed(on network: String, cycle: BudgetCycle? = nil, now: Date = Date()) -> UInt64 {
        let current = network == networkKey
        guard let interval = (cycle ?? (current ? budgetCycle : preferences.networkCycles?[network] ?? BudgetCycle())).interval(containing: now) else {
            return current ? total : networkSessions[network].map { $0.received + $0.sent } ?? 0
        }
        return BudgetCycle.used(usage, in: interval, network: network) + (current ? pendingReceived + pendingSent : 0)
    }
    /// Quotas count within the budget cycle of their network; every-network quotas follow the current one.
    public func quotaCycle(_ quota: AppQuota) -> BudgetCycle {
        guard let network = quota.network, network != networkKey else { return budgetCycle }
        return preferences.networkCycles?[network] ?? BudgetCycle()
    }
    public func quotaUsed(_ quota: AppQuota, now: Date = Date()) -> UInt64 {
        let pending = quota.applies(to: networkKey) ? (quota.uploadOnly ? pendingAppsSent[quota.name] : pendingApps[quota.name]) ?? 0 : 0
        return quota.used(usage, cycle: quotaCycle(quota), now: now) + pending
    }
    /// Rule keys of apps whose quota for this network is used up, for the filter.
    public var quotaReached: [String] {
        Array(Set((preferences.quotas ?? []).filter { $0.applies(to: networkKey) && quotaUsed($0) >= $0.bytes }.flatMap(\.apps))).sorted()
    }
    /// Today's Internet bytes on every network, with what isn't saved yet, and the same by hour.
    public func today(now: Date = Date(), calendar: Calendar = .current) -> (received: UInt64, sent: UInt64, hours: [UInt64]) {
        let entries = usage.filter { $0.date >= calendar.startOfDay(for: now) && $0.date <= now }
        return (entries.reduce(pendingReceived) { $0 + $1.received }, entries.reduce(pendingSent) { $0 + $1.sent },
                WidgetSnapshot.hours(entries, pending: pendingReceived + pendingSent, now: now, calendar: calendar))
    }
    public func uploadAnomalies(now: Date = Date()) -> [UploadAnomaly] { UploadAnomaly.detect(usage, pending: pendingAppsSent, now: now) }
    public var allowedCount: Int { apps.filter { isAllowed($0.id) }.count }
    public var filteredApps: [AppTraffic] {
        apps.filter {
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) &&
            (filter != "Allowed" || isAllowed($0.id)) &&
            (filter != "Blocked" || !isAllowed($0.id)) &&
            (filter != "Active" || $0.rate > 0)
        }.sorted { $0.rate == $1.rate ? $0.total > $1.total : $0.rate > $1.rate }
    }

    public func isAllowed(_ id: String) -> Bool {
        if preferences.profile == .unrestricted { return true }
        let profile = preferences.profile.rawValue, keys = ProcessRuleKey.keys(id)
        if let temporary = keys.lazy.compactMap({ self.preferences.temporaryRules?[profile + "|" + $0] }).first(where: { $0.expires > Date() }) { return temporary.allowed }
        return keys.lazy.compactMap { self.preferences.rules[profile]?[$0] }.first ?? preferences.defaultAllow
    }
    public func setAllowed(_ id: String, _ allowed: Bool, in profile: NetworkProfile? = nil) {
        let profile = (profile ?? preferences.profile).rawValue
        preferences.temporaryRules?.removeValue(forKey: profile + "|" + id)
        preferences.rules[profile, default: [:]][id] = allowed
    }
    public func setTemporary(_ id: String, allowed: Bool, minutes: Int = 15, in profile: NetworkProfile? = nil) {
        if preferences.temporaryRules == nil { preferences.temporaryRules = [:] }
        let ruleKey = (profile ?? preferences.profile).rawValue + "|" + id
        preferences.temporaryRules?[ruleKey] = TemporaryRule(allowed: allowed, expires: Date().addingTimeInterval(Double(minutes) * 60))
    }
    /// Drops saved and temporary rules so the app falls back to the profile default. Returns false if there was none.
    @discardableResult public func removeRule(_ id: String, in profile: NetworkProfile? = nil) -> Bool {
        let profile = (profile ?? preferences.profile).rawValue
        var removed = false
        for key in ProcessRuleKey.keys(id) {
            if preferences.temporaryRules?.removeValue(forKey: profile + "|" + key) != nil { removed = true }
            if preferences.rules[profile]?.removeValue(forKey: key) != nil { removed = true }
        }
        return removed
    }
    public func switchNetwork(_ snapshot: DiagnosticSnapshot) {
        guard networkKey != snapshot.networkKey else { networkName = snapshot.networkName; return }
        flush()
        if networkKey != "unknown" {
            networkSessions[networkKey] = session
            let oldLimit = preferences.limitGB
            if preferences.networkLimits == nil { preferences.networkLimits = [:] }
            preferences.networkLimits?[networkKey] = oldLimit
            rememberCycle()
        } else if recordHistory, usage.last?.networkKey == snapshot.networkKey {
            // After a relaunch the saved budget still describes the network the Mac was last on.
            preferences.networkLimits = (preferences.networkLimits ?? [:]).merging([snapshot.networkKey: preferences.limitGB]) { $1 }
            preferences.networkCycles = Self.cycles(preferences.networkCycles, preferences.budgetCycle, for: snapshot.networkKey)
        }
        networkKey = snapshot.networkKey; networkName = snapshot.networkName; networkIdentified = snapshot.networkIdentified
        let saved = networkSessions[networkKey]
        received = saved?.received ?? 0; sent = saved?.sent ?? 0; local = saved?.local ?? 0; unattributed = saved?.unattributed ?? 0; tunnel = 0
        apps = []; if readCounters != nil { wifiNames = InterfaceCounters.wifiInterfaces() }
        rebaseline()
        // Both at once, or the copy kept per network would pick up the old cycle under the new key.
        var budget = preferences
        budget.limitGB = budget.networkLimits?[networkKey] ?? 5; budget.budgetCycle = budget.networkCycles?[networkKey]
        preferences = budget
        if let profile = preferences.networkProfiles?[networkKey], let value = NetworkProfile(rawValue: profile) { preferences.profile = value }
        persist(networkSessions, as: "network-sessions.json")
        costChanged()
    }
    private var session: NetworkSession {
        NetworkSession(name: networkName, received: received, sent: sent, identified: networkIdentified ? nil : false, local: local, unattributed: unattributed)
    }
    public func rememberNetwork() {
        if preferences.networkProfiles == nil { preferences.networkProfiles = [:] }
        if preferences.networkLimits == nil { preferences.networkLimits = [:] }
        let profile = preferences.profile.rawValue, limit = preferences.limitGB
        preferences.networkProfiles?[networkKey] = profile
        preferences.networkLimits?[networkKey] = limit
        rememberCycle()
    }
    private func rememberCycle() { preferences.networkCycles = Self.cycles(preferences.networkCycles, preferences.budgetCycle, for: networkKey) }
    /// A session budget leaves no entry, so networks without a cycle add nothing to the file.
    private static func cycles(_ cycles: [String: BudgetCycle]?, _ cycle: BudgetCycle?, for network: String) -> [String: BudgetCycle]? {
        var cycles = cycles
        if let cycle { cycles = (cycles ?? [:]).merging([network: cycle]) { $1 } } else { cycles?[network] = nil }
        return cycles
    }
    public func setScope(_ scope: String) {
        guard ["external", "wifi", "wired"].contains(scope) else { return }
        flush(); preferences.trafficScope = scope
        rebaseline(); download = 0; upload = 0
        startCollector(scope: scope)
    }
    /// The next sample only sets baselines: after a wake, a network change or a new scope.
    func rebaseline() { previous = [:]; lastSample = nil; interfaces.reset(); localCarry = ByteCount() }
    /// Whether totals come from Wi-Fi and Ethernet counters rather than only the processes nettop saw.
    public var countsInterfaces: Bool { readCounters != nil && counterFailures < 5 }
    private func startCollector(scope: String) {
        let generation = UUID(); sampleGeneration = generation
        monitor.start(scope: scope, onSample: { [weak self] snapshot in
            Task { @MainActor in guard let self, self.sampleGeneration == generation else { return }; self.consume(snapshot) }
        }, onError: { [weak self] error in
            Task { @MainActor in guard let self, self.sampleGeneration == generation else { return }; self.error = error }
        })
    }
    public func setAllAllowed(_ allowed: Bool) {
        for app in apps { setAllowed(app.id, allowed) }
    }
    public func resetSession() {
        flush()
        received = 0; sent = 0; local = 0; unattributed = 0; tunnel = 0
        networkSessions[networkKey] = NetworkSession(name: networkName, identified: networkIdentified ? nil : false)
        persist(networkSessions, as: "network-sessions.json")
        for index in apps.indices { apps[index].received = 0; apps[index].sent = 0; apps[index].local = 0; apps[index].tunnel = 0 }
    }
    public func identity(_ process: ProcessTraffic) -> (String, String, String?) {
        if let identity = identities[process.pid] { return identity }
        let app = NSRunningApplication(processIdentifier: process.pid)
        // nettop truncates names to 15 characters; the filter matches the full executable name.
        let executable = app?.bundleIdentifier == nil ? Self.executableName(pid: process.pid) ?? process.process : process.process
        let name = app?.bundleIdentifier != nil ? app?.localizedName ?? Self.executableName(pid: process.pid) ?? process.process : executable
        let id = app?.bundleIdentifier ?? "process:\(executable)"
        let value = (id, name, app?.bundleURL?.path)
        identities[process.pid] = value
        if app?.bundleIdentifier == nil, let path = Self.executablePath(pid: process.pid), CommandLineTools.unrecognized(path) { executables[process.pid] = path }
        return value
    }
    static func executablePath(pid: Int32) -> String? {
        var path = [UInt8](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(decoding: path.prefix { $0 != 0 }, as: UTF8.self)
    }
    static func executableName(pid: Int32) -> String? {
        guard let path = executablePath(pid: pid) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }
    public func consume(_ snapshot: TrafficSnapshot) {
        let generation = sampleGeneration
        reloadPreferences()
        guard generation == sampleGeneration else { return }
        let counters = readCounters?()
        let scope = preferences.trafficScope ?? "external", wifi = wifiNames
        let physical: (String) -> Bool = { InterfaceCounters.physical($0, scope: scope, wifi: wifi) }
        let starts = Dictionary(snapshot.processes.map { ($0.pid, startTime($0.pid)) }) { first, _ in first }
        defer {
            // A process missing from a sample keeps its place for half a minute, so it isn't counted again from scratch.
            var seen = previous.filter { snapshot.timestamp.timeIntervalSince($0.value.at) < 30 }
            for process in snapshot.processes { seen[process.pid] = SeenProcess(traffic: process, started: starts[process.pid] ?? nil, at: snapshot.timestamp) }
            previous = seen
            lastSample = snapshot.timestamp
            ready = true
        }
        guard let lastSample else {
            if let counters { _ = interfaces.advance(counters, elapsed: 1, include: physical) }
            return
        }
        let elapsed = max(0.1, snapshot.timestamp.timeIntervalSince(lastSample))
        var index = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        for key in index.keys { index[key]?.downloadRate = 0; index[key]?.uploadRate = 0; index[key]?.processIDs = []; index[key]?.rates = [:] }
        var all = ByteCount(), local = ByteCount(), physicalLocal = ByteCount(), tunnel = ByteCount(), internet = ByteCount()
        var owners: [String: Set<String>] = [:]
        let currentPIDs = Set(snapshot.processes.map(\.pid))
        let currentNames = Dictionary(snapshot.processes.map { ($0.pid, $0.process) }) { first, _ in first }
        // A pid with another name or start time is another process; one that has exited keeps its identity for its last rows.
        let kept = identities.filter { pid, _ in
            currentPIDs.contains(pid) && previous[pid]?.traffic.process == currentNames[pid] && (starts[pid] ?? nil).map { $0 == previous[pid]?.started } != false
        }
        identities = kept
        executables = executables.filter { kept[$0.key] != nil }
        for process in snapshot.processes {
            // First sighting establishes a baseline, never imports lifetime data.
            guard let flow = TrafficAttribution.flow(process, started: starts[process.pid] ?? nil, previous: previous[process.pid],
                                                     lastSample: lastSample, elapsed: elapsed, physical: physical) else { continue }
            let (id, name, path) = identity(process)
            var app = index[id] ?? AppTraffic(id: id, name: name, bundlePath: path)
            app.processIDs.append(process.pid)
            app.executablePath = executables[process.pid] ?? app.executablePath
            let owner = ProcessOwnership.applicationPath(pid: process.pid)
            owners[id, default: []].insert(owner ?? "")
            let rate = ProcessRate(down: Double(flow.total.received) / elapsed, up: Double(flow.total.sent) / elapsed)
            app.received += flow.total.received; app.sent += flow.total.sent
            app.local += flow.local.total; app.tunnel += flow.tunnel.total
            app.rates[process.pid] = rate
            app.downloadRate += rate.down
            app.uploadRate += rate.up
            index[id] = app
            // A proxy core or VPN tunnel forwards other apps' bytes, which those apps already count: it shows in the list
            // and the live rates, but adds nothing to the Internet total or history a second time.
            let carrier = ProxyRouting.shared.isCarrier(process.pid)
            if carrier { index[id]?.carrier = true }
            all += flow.total; local += flow.local; physicalLocal += flow.physicalLocal; tunnel += flow.tunnel
            if !carrier { internet += flow.internet }
            // History counts helpers and services under the app that owns them, as the app list does; local bytes apart.
            let historyName = owner.flatMap { $0 == path ? nil : AppTrafficGroup.displayName($0) } ?? name
            let counted = carrier ? ByteCount() : flow.total - flow.local
            pendingApps[historyName, default: 0] += counted.total
            pendingAppsSent[historyName, default: 0] += counted.sent
            if flow.local.total > 0 { pendingAppsLocal[historyName, default: 0] += flow.local.total }
        }
        for (id, paths) in owners {
            index[id]?.ownerPath = paths.count == 1 ? paths.first.flatMap { $0.isEmpty ? nil : $0 } : nil
        }
        apps = Array(index.values)
        var series = liveSeries
        for app in apps { series[app.id, default: LiveSeries()].append(down: app.downloadRate, up: app.uploadRate) }
        for id in series.keys where index[id]?.processIDs.isEmpty != false {
            series[id]?.append(down: 0, up: 0)
            if series[id]?.isIdle == true { series[id] = nil }
        }
        liveSeries = series
        let counted = macInternet(counters, elapsed: elapsed, attributed: internet, physicalLocal: physicalLocal, physical: physical)
        received += counted.received; sent += counted.sent
        pendingReceived += counted.received; pendingSent += counted.sent
        self.local += local.total; pendingLocal += local.total; self.tunnel += tunnel.total
        download = Double(all.received) / elapsed; upload = Double(all.sent) / elapsed
        downloadHistory = Array((downloadHistory + [download]).suffix(60))
        uploadHistory = Array((uploadHistory + [upload]).suffix(60))
        if snapshot.timestamp.timeIntervalSince(lastFlush) >= 30 { flush() }
    }
    /// What the Mac sent to and received from the Internet in a sample. Wi-Fi and Ethernet counters see everything
    /// the carrier bills, from processes nettop missed too, and a VPN's traffic once (its tunnel isn't counted); their
    /// local traffic is taken out. Without counters, the processes' own Internet bytes stand in.
    private func macInternet(_ counters: [String: ByteCount]?, elapsed: TimeInterval, attributed: ByteCount, physicalLocal: ByteCount, physical: (String) -> Bool) -> ByteCount {
        guard readCounters != nil else { return attributed }
        guard let counters else {
            // A missed reading is caught up by the next one; only several in a row mean the counters are gone.
            counterFailures += 1
            if counterFailures == 5 { interfaces.reset() }
            if counterFailures < 5 { pendingAttributed += attributed.total }
            return counterFailures < 5 ? ByteCount() : attributed
        }
        if counterFailures >= 5 { interfaces.reset() }
        counterFailures = 0
        pendingAttributed += attributed.total
        // Local bytes nettop reported before the counters moved are taken from the next sample instead.
        let local = physicalLocal + localCarry, link = interfaces.advance(counters, elapsed: elapsed, include: physical)
        localCarry = (local - link).capped(physicalLocal)
        return link - local
    }
    /// Bytes the interfaces carried since the last flush beyond what processes account for.
    private var pendingUnattributed: UInt64 {
        guard countsInterfaces else { return 0 }
        let counted = pendingReceived + pendingSent
        return counted > pendingAttributed ? counted - pendingAttributed : 0
    }
    /// This network's unattributed bytes so far, including those not yet saved.
    public var unattributedBytes: UInt64 { unattributed + pendingUnattributed }
    public func flush() {
        guard recordHistory, pendingReceived + pendingSent + pendingLocal > 0 else { return }
        let gap = pendingUnattributed
        unattributed += gap
        usage.append(UsageEntry(date: Date(), received: pendingReceived, sent: pendingSent, apps: pendingApps, networkKey: networkKey, appsSent: pendingAppsSent,
                                localBytes: pendingLocal, appsLocal: pendingAppsLocal.isEmpty ? nil : pendingAppsLocal, unattributed: countsInterfaces ? gap : nil))
        let cutoff = Date().addingTimeInterval(-Double(preferences.historyDays ?? 365) * 86_400)
        usage = Self.compact(usage.filter { $0.date >= cutoff })
        persist(usage, as: "usage.json")
        networkSessions[networkKey] = session
        persist(networkSessions, as: "network-sessions.json")
        pendingReceived = 0; pendingSent = 0; pendingApps = [:]; pendingAppsSent = [:]; lastFlush = Date()
        pendingLocal = 0; pendingAppsLocal = [:]; pendingAttributed = 0
    }
    public func reloadPreferences() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("preferences.json")),
              data != lastPreferencesData,
              let saved = try? JSONDecoder().decode(SavedPreferences.self, from: data) else { return }
        let scopeChanged = preferences.trafficScope != saved.trafficScope
        lastPreferencesData = data
        reloading = true; preferences = saved; reloading = false
        if preferences != saved { savePreferences() }
        if scopeChanged { setScope(saved.trafficScope ?? "external") }
    }
    public func savePreferences() {
        persist(preferences, as: "preferences.json")
        lastPreferencesData = try? Data(contentsOf: directory.appendingPathComponent("preferences.json"))
    }
    public func shutdown() { flush(); monitor.stop() }
    /// Samples older than a day merge into hourly buckets per network, and older than 30 days into daily ones,
    /// so a year of history stays small enough to rewrite on every flush. Entries keep the same shape for existing readers.
    static func compact(_ usage: [UsageEntry], now: Date = Date(), calendar: Calendar = .current) -> [UsageEntry] {
        let recent = now.addingTimeInterval(-86_400), old = now.addingTimeInterval(-30 * 86_400)
        var buckets: [String: [UsageEntry]] = [:]
        var kept: [UsageEntry] = []
        func bucket(_ date: Date) -> Date? { calendar.dateInterval(of: date < old ? .day : .hour, for: date)?.start }
        // Fields history from before 1.3 lacks stay missing rather than turning into zeros.
        func sum(_ values: [UInt64?]) -> UInt64? { values.contains { $0 != nil } ? values.reduce(0) { $0 + ($1 ?? 0) } : nil }
        for entry in usage {
            guard entry.date < recent, let start = bucket(entry.date) else { kept.append(entry); continue }
            buckets["\(start.timeIntervalSince1970)|\(entry.networkKey ?? "")", default: []].append(entry)
        }
        let merged = buckets.values.map { entries -> UsageEntry in
            let start = bucket(entries[0].date) ?? entries[0].date
            if entries.count == 1 && entries[0].date == start { return entries[0] }
            return UsageEntry(date: start, received: entries.reduce(0) { $0 + $1.received }, sent: entries.reduce(0) { $0 + $1.sent },
                              apps: entries.reduce(into: [:]) { apps, entry in apps.merge(entry.apps, uniquingKeysWith: +) }, networkKey: entries[0].networkKey,
                              appsSent: entries.reduce(into: [:]) { apps, entry in apps.merge(entry.estimatedSent, uniquingKeysWith: +) },
                              localBytes: sum(entries.map(\.localBytes)), appsLocal: entries.contains { $0.appsLocal != nil } ? entries.reduce(into: [:]) { apps, entry in apps.merge(entry.appsLocal ?? [:], uniquingKeysWith: +) } : nil,
                              unattributed: sum(entries.map(\.unattributed)))
        }
        return (merged + kept).sorted { $0.date < $1.date }
    }
    private func persist<T: Encodable>(_ value: T, as name: String) {
        do { try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic) }
        catch { self.error = String(localized: "Could not save local data: \(error.localizedDescription)") }
    }
    public func exportCSV() {
        flush()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kilobat-usage.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = ISO8601DateFormatter()
        let csv = "timestamp,download_bytes,upload_bytes\n" + usage.map { "\(formatter.string(from: $0.date)),\($0.received),\($0.sent)" }.joined(separator: "\n")
        do { try csv.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}

/// Unreadable files are moved aside as `<name>.corrupt` so the next save cannot destroy them.
enum StoredJSON {
    static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            let aside = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }
}
