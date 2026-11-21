import AppKit
import Darwin
import Observation
import os

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
    private var actionError: String?
    private(set) var preferencesSaveError: String?
    private(set) var monitoringError: String?
    func monitoringFailed(_ message: String) { monitoringError = message }
    public var error: String? {
        get { preferencesSaveError ?? actionError ?? monitoringError }
        set { actionError = newValue; if newValue == nil { monitoringError = nil } }
    }
    public var search = ""
    public var filter = "All apps"
    public var selectedApp: String?
    public var preferences: SavedPreferences {
        didSet {
            guard preferences != oldValue else {
                if !reloading, preferencesSaveError != nil { savePreferences() }
                return
            }
            // Names and the list of profiles follow the definitions; nothing may point at a profile that's gone.
            ProfileCatalog.update(preferences.profileDefinitions)
            preferences.settleProfiles()
            // The budget always describes the current network; keeping its copy current means a relaunch,
            // which starts on no network, can't lose a plan set since the last switch.
            if !applyingImport, recordHistory, networkKey != "unknown", preferences.limitGB != oldValue.limitGB || preferences.budgetCycle != oldValue.budgetCycle {
                preferences.networkLimits = (preferences.networkLimits ?? [:]).merging([networkKey: preferences.limitGB]) { $1 }
                preferences.networkCycles = Self.cycles(preferences.networkCycles, preferences.budgetCycle, for: networkKey)
            }
            if !reloading { savePreferences() }
            if preferences.networkCost != oldValue.networkCost || preferences.dataPacks != oldValue.dataPacks, lastMetered != nil { costChanged() }
        }
    }
    public var usage: [UsageEntry] = []
    private var allowanceHistory: [UsageEntry] = []
    var allowanceUsage: [UsageEntry] { allowanceHistory.isEmpty ? usage : allowanceHistory + usage }
    @ObservationIgnored private(set) var networkRevision = 0
    public var networkKey = "unknown" {
        didSet { if networkKey != oldValue { networkRevision &+= 1 } }
    }
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
    /// The app a process belongs to, by its ancestors; replaced in tests.
    var ownerPath: (Int32) -> String? = ProcessOwnership.applicationPath
    private var interfaces = InterfaceTally()
    private var counterFailures = 0
    /// Local bytes nettop reported before the interface counters showed them.
    private var localCarry = ByteCount()
    private var wifiNames: Set<String> = []
    private var executables: [Int32: String] = [:]
    /// The app each process belongs to ("" for none), looked up when the process is first seen and dropped with its identity.
    @ObservationIgnored private var owningApps: [Int32: String] = [:]
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
    private var applyingImport = false
    private var lastMetered: Bool?
    /// Whether Kilobat may tighten on its own: the switch to Essentials on a metered network. The app says no without
    /// Pro, so a lapsed trial is never moved into a stricter profile. The way back out always runs.
    @ObservationIgnored public var tightensAutomatically: @MainActor () -> Bool = { true }
    private(set) var budgetSession: UUID?
    private let directory: URL
    private let ownsFiles: Bool
    /// True when preferences.json exists but this copy could not read it and left it in place: it never saves over it.
    public private(set) var preferencesUnreadable = false

    /// `recordHistory: false` makes a read-only sampling store: it never records usage or changes preferences.
    public init(directory: URL? = nil, startMonitoring: Bool = true, recordHistory: Bool = true, ownsFiles: Bool = LocalFiles.movesUnreadableAside) {
        self.recordHistory = recordHistory
        self.ownsFiles = ownsFiles
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var loaded = SavedPreferences()
        switch StoredJSON.load(self.directory.appendingPathComponent("preferences.json"), quarantine: ownsFiles) as StoredJSON.Loaded<SavedPreferences> {
        case .value(let value): loaded = value; preferencesUnreadable = !ownsFiles && (value.schema ?? 0) > SavedPreferences.currentSchema
        case .missing: break
        case .unreadable: preferencesUnreadable = !ownsFiles
        }
        loaded.settleProfiles()
        preferences = loaded
        ProfileCatalog.update(preferences.profileDefinitions)
        lastPreferencesData = try? Data(contentsOf: self.directory.appendingPathComponent("preferences.json"))
        Self.writer.sync {}
        networkSessions = StoredJSON.read(self.directory.appendingPathComponent("network-sessions.json"), quarantine: ownsFiles) ?? [:]
        let savedUsage = UsageFile.read(self.directory, includesAllowances: true)
        usage = Self.compact(savedUsage.filter { $0.allowanceOnly != true }, packs: preferences.dataPacks ?? [])
        allowanceHistory = savedUsage.filter { $0.allowanceOnly == true }
        sleeps = StoredJSON.read(self.directory.appendingPathComponent("sleeps.json"), quarantine: ownsFiles) ?? []
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
    /// A network on a running data pack is metered unless it was marked unmetered by hand.
    public var metered: Bool { cost == .automatic && currentPack != nil ? true : cost.metered(os: osExpensive) }
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
            guard next.autoHotspot, tightensAutomatically(), next.profile != .travel, next.networkProfiles?[networkKey] == nil else { return }
            next.autoProfileFrom = next.profile.rawValue; next.profile = .travel
        } else if let previous = next.autoProfileFrom {
            if next.profile == .travel, let profile = next.knownProfile(previous) { next.profile = profile }
            next.autoProfileFrom = nil
        }
        preferences = next
    }

    public var total: UInt64 { received + sent }
    // The budget in force here: the prepaid pack running on this network, or else the network's own repeating budget
    // (`preferences.limitGB`, `budgetCycle`, `budgetUsed(on:)`).
    public var limit: UInt64 { currentPack?.bytes ?? UInt64(preferences.limitGB * 1_000_000_000) }
    public var budgetMode: NetworkBudgetMode { currentPack?.budgetMode ?? preferences.budgetMode(for: networkKey) }
    /// True when this network has a budget the person set: what the menu shows as "Set a budget…" has none, whatever
    /// `limitGB` still holds from before.
    public var hasBudget: Bool { budgetMode != .off && limit > 0 }
    public var budgetBlocksNewConnections: Bool { budgetMode == .block && limitFraction >= 1 }
    public var activeAllowance: WidgetSnapshot.Budget? {
        if let pack = currentPack {
            guard pack.budgetMode != .off, pack.bytes > 0 else { return nil }
            return WidgetSnapshot.Budget(usedBytes: packStatus(pack).used, limitBytes: pack.bytes,
                                         period: "pack", packEnds: pack.finish)
        }
        guard hasBudget else { return nil }
        return WidgetSnapshot.Budget(usedBytes: budgetUsed(on: networkKey), limitBytes: limit, period: budgetCycle.period.rawValue)
    }
    public var displayedUsage: UInt64 { budgetMode == .off ? total : budgetUsedBytes }
    public var budgetLeft: UInt64 { limit - min(limit, budgetUsedBytes) }

    public func setBudgetMode(_ mode: NetworkBudgetMode) {
        guard networkKey != "unknown" else { return }
        var next = preferences
        next.setBudgetMode(mode, for: networkKey)
        next.budgetCycle = next.networkCycles?[networkKey]
        preferences = next
    }

    public var limitFraction: Double { min(1, Double(budgetUsedBytes) / Double(max(1, limit))) }
    public var budgetCycle: BudgetCycle { preferences.budgetCycle ?? BudgetCycle() }
    /// The current cycle on this network; nil for a total budget.
    public var budgetInterval: DateInterval? { budgetCycle.interval(containing: Date()) }
    /// Bytes counted against the budget in force: the running pack's use, or this network's in the current cycle.
    public var budgetUsedBytes: UInt64 { currentPack.map { packStatus($0).used } ?? budgetUsed(on: networkKey) }
    /// A network's repeating budget: a total uses the network's counter; a cycle adds up history on that network
    /// since it began, so a monthly plan survives restarts.
    public func budgetUsed(on network: String, cycle: BudgetCycle? = nil, now: Date = Date()) -> UInt64 {
        let current = network == networkKey
        guard let interval = (cycle ?? (current ? budgetCycle : preferences.networkCycles?[network] ?? BudgetCycle())).interval(containing: now) else {
            return current ? total : networkSessions[network].map { $0.received + $0.sent } ?? 0
        }
        return BudgetCycle.used(allowanceUsage, in: interval, network: network) + (current ? pendingReceived + pendingSent : 0)
    }
    /// The budget cycle of the network an app limit counts on; every-network limits follow the current network's.
    public func budgetCycle(counting limit: AppLimit) -> BudgetCycle {
        guard let network = limit.network, network != networkKey else { return budgetCycle }
        return preferences.networkCycles?[network] ?? BudgetCycle()
    }
    /// The cycle an app limit counts in.
    public func limitCycle(_ limit: AppLimit) -> BudgetCycle { limit.resolvedCycle(budget: budgetCycle(counting: limit)) }
    public func limitUsed(_ limit: AppLimit, now: Date = Date(), budget: BudgetCycle? = nil) -> UInt64 {
        let pending = limit.applies(to: networkKey) ? (limit.uploadOnly ? pendingAppsSent[limit.name] : pendingApps[limit.name]) ?? 0 : 0
        return limit.used(allowanceUsage, budget: budget ?? budgetCycle(counting: limit), now: now) + pending
    }
    /// The app limit that counts for an app here: one for this network before one for every network.
    public func appLimit(named name: String) -> AppLimit? {
        let limits = (preferences.quotas ?? []).filter { $0.name == name && $0.applies(to: networkKey) }
        return limits.first { $0.network != nil } ?? limits.first
    }
    /// Rule keys of apps whose blocking limit for this network is used up, for the filter.
    public var quotaReached: [String] {
        Array(Set((preferences.quotas ?? []).filter { $0.blocks && $0.applies(to: networkKey) && limitUsed($0) >= $0.bytes }.flatMap(\.apps))).sorted()
    }
    /// Today's Internet bytes on every network, with what isn't saved yet, and the same by hour.
    public func today(now: Date = Date(), calendar: Calendar = .current) -> (received: UInt64, sent: UInt64, hours: [UInt64]) {
        let entries = usage.filter { $0.date >= calendar.startOfDay(for: now) && $0.date <= now }
        return (entries.reduce(pendingReceived) { $0 + $1.received }, entries.reduce(pendingSent) { $0 + $1.sent },
                WidgetSnapshot.hours(entries, pending: pendingReceived + pendingSent, now: now, calendar: calendar))
    }
    public func uploadAnomalies(now: Date = Date()) -> [UploadAnomaly] { UploadAnomaly.detect(usage, pending: pendingAppsSent, now: now) }
    /// Everything a process has sent since it started, as nettop last counted it; for Send later's time left.
    public func sentSinceStart(pid: Int32) -> UInt64? { previous[pid]?.traffic.sent }
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
        if TeamsRuleEnforcement.blockedApps().contains(id) { return false }
        if preferences.profile == .unrestricted { return true }
        let profile = preferences.profile.rawValue, keys = ProcessRuleKey.keys(id)
        if let temporary = keys.lazy.compactMap({ self.preferences.temporaryRules?[profile + "|" + $0] }).first(where: { $0.expires > Date() }) { return temporary.allowed }
        return keys.lazy.compactMap { self.preferences.rules[profile]?[$0] }.first ?? preferences.defaultAllow
    }
    public func setAllowed(_ id: String, _ allowed: Bool, in profile: NetworkProfile? = nil) {
        guard !allowed || !TeamsRuleEnforcement.blockedApps().contains(id) else { return }
        let profile = (profile ?? preferences.profile).rawValue
        preferences.temporaryRules?.removeValue(forKey: profile + "|" + id)
        preferences.rules[profile, default: [:]][id] = allowed
    }
    public func setTemporary(_ id: String, allowed: Bool, minutes: Int = 15, in profile: NetworkProfile? = nil) {
        writeTemporary(id, allowed: allowed, minutes: minutes, profile: profile ?? preferences.profile)
    }
    /// "Until quit": the rule covers the process `pid` only, and ends when it exits (a day at most).
    public func setUntilQuit(_ id: String, allowed: Bool, pid: Int32, in profile: NetworkProfile? = nil) {
        guard pid > 0, !allowed || !TeamsRuleEnforcement.blockedApps().contains(id) else { return }
        let ruleKey = (profile ?? preferences.profile).rawValue + "|" + id
        if preferences.temporaryRules == nil { preferences.temporaryRules = [:] }
        preferences.temporaryRules?[ruleKey] = TemporaryRule(allowed: allowed, expires: Date().addingTimeInterval(TemporaryRule.untilQuitBackstop), pid: pid)
    }
    private func writeTemporary(_ id: String, allowed: Bool, minutes: Int, profile: NetworkProfile, ownership: UUID? = nil) {
        guard !allowed || !TeamsRuleEnforcement.blockedApps().contains(id) else { return }
        let ruleKey = profile.rawValue + "|" + id
        if preferences.temporaryRules == nil { preferences.temporaryRules = [:] }
        preferences.temporaryRules?[ruleKey] = TemporaryRule(allowed: allowed, expires: Date().addingTimeInterval(Double(minutes) * 60), ownership: ownership)
    }
    struct OwnedTemporary {
        let id: String
        let profile: NetworkProfile
        let ownership: UUID
    }
    func holdTemporary(_ id: String, minutes: Int) -> OwnedTemporary {
        let hold = OwnedTemporary(id: id, profile: preferences.profile, ownership: UUID())
        writeTemporary(id, allowed: false, minutes: minutes, profile: hold.profile, ownership: hold.ownership)
        return hold
    }
    func clearTemporary(_ hold: OwnedTemporary) {
        let key = hold.profile.rawValue + "|" + hold.id
        if preferences.temporaryRules?[key]?.ownership == hold.ownership { preferences.temporaryRules?.removeValue(forKey: key) }
    }
    /// The app's temporary rule in the current profile, while it lasts.
    public func temporaryRule(_ id: String) -> TemporaryRule? {
        preferences.temporaryRules?[preferences.profile.rawValue + "|" + id].flatMap { $0.expires > Date() ? $0 : nil }
    }
    /// Drops only a temporary rule, in every profile, leaving saved rules alone.
    public func clearTemporary(_ id: String) {
        for key in preferences.temporaryRules?.keys.filter({ $0.hasSuffix("|" + id) }) ?? [] { preferences.temporaryRules?.removeValue(forKey: key) }
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
    /// Switches profile as the schedules say (see `ProfileScheduler`); `held` while a Focus has switched it. Returns
    /// whether the profile or what comes back after the schedule changed.
    @discardableResult public func applySchedules(now: Date = Date(), held: Bool = false, calendar: Calendar = .current) -> Bool {
        guard recordHistory else { return false }
        var next = preferences
        guard ProfileScheduler.step(&next, now: now, held: held, calendar: calendar) else { return false }
        preferences = next
        return true
    }
    public func switchNetwork(_ snapshot: DiagnosticSnapshot) {
        guard networkKey != snapshot.networkKey else {
            networkName = snapshot.networkName; networkIdentified = snapshot.networkIdentified
            costChanged()
            return
        }
        flush()
        if networkKey != "unknown" {
            networkSessions[networkKey] = session
            let oldLimit = preferences.limitGB
            if preferences.networkLimits == nil { preferences.networkLimits = [:] }
            preferences.networkLimits?[networkKey] = oldLimit
            rememberCycle()
        } else if recordHistory, snapshot.networkIdentified, usage.last?.networkKey == snapshot.networkKey {
            // After a relaunch the saved budget still describes the network the Mac was last on.
            preferences.networkLimits = (preferences.networkLimits ?? [:]).merging([snapshot.networkKey: preferences.limitGB]) { $1 }
            preferences.networkCycles = Self.cycles(preferences.networkCycles, preferences.budgetCycle, for: snapshot.networkKey)
        }
        networkKey = snapshot.networkKey; networkName = snapshot.networkName; networkIdentified = snapshot.networkIdentified
        let saved = networkIdentified ? networkSessions[networkKey] : nil
        budgetSession = saved?.budgetSession
        received = saved?.received ?? 0; sent = saved?.sent ?? 0; local = saved?.local ?? 0; unattributed = saved?.unattributed ?? 0; tunnel = 0
        apps = []; if readCounters != nil { wifiNames = InterfaceCounters.wifiInterfaces() }
        rebaseline()
        // Both at once, or the copy kept per network would pick up the old cycle under the new key.
        var budget = preferences
        budget.limitGB = networkIdentified ? budget.networkLimits?[networkKey] ?? 5 : 5
        budget.budgetCycle = networkIdentified ? budget.networkCycles?[networkKey] : nil
        preferences = budget
        if networkIdentified, let profile = preferences.networkProfiles?[networkKey], let value = preferences.knownProfile(profile) { preferences.profile = value }
        persist(networkSessions, as: "network-sessions.json")
        costChanged()
    }
    private var session: NetworkSession {
        NetworkSession(name: networkName, received: received, sent: sent, identified: networkIdentified ? nil : false, local: local, unattributed: unattributed, budgetSession: budgetSession)
    }
    public func rememberNetwork() {
        guard networkIdentified else { return }
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
    /// Apply the whole import in one write, restarting the live collector when its scope changes.
    public func applyImportedPreferences(_ next: SavedPreferences) throws {
        let previous = preferences
        let scope = next.trafficScope ?? "external"
        let scopeChanged = scope != (previous.trafficScope ?? "external")
        if scopeChanged { flush() }
        applyingImport = true
        defer { applyingImport = false }
        preferences = next
        if let error = preferencesSaveError {
            reloading = true
            preferences = previous
            reloading = false
            throw DiagnosticError(error)
        }
        if scopeChanged {
            rebaseline(); download = 0; upload = 0
            if readCounters != nil { startCollector(scope: scope) }
        }
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
            Task { @MainActor in guard let self, self.sampleGeneration == generation else { return }; self.monitoringFailed(error) }
        })
    }
    public func setAllAllowed(_ allowed: Bool) {
        for app in apps { setAllowed(app.id, allowed) }
    }
    public func resetSession() {
        flush()
        received = 0; sent = 0; local = 0; unattributed = 0; tunnel = 0
        budgetSession = UUID()
        networkSessions[networkKey] = session
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
    /// Every nettop sample as it arrives, with its per-connection rows: the agent network log and service speed read these.
    @ObservationIgnored private var snapshotObservers: [(TrafficSnapshot) -> Void] = []
    public func observeSnapshots(_ observer: @escaping (TrafficSnapshot) -> Void) { snapshotObservers.append(observer) }
    /// Nothing on screen reads the per-sample figures. They keep updating for everything else; views just aren't told,
    /// because SwiftUI keeps closed windows' views alive and would redraw them every second.
    @ObservationIgnored public var viewsAreHidden: () -> Bool = { false }
    @ObservationIgnored private var heldBack = false
    public func consume(_ snapshot: TrafficSnapshot) {
        monitoringError = nil
        let generation = sampleGeneration
        reloadPreferences()
        if metered != lastMetered { costChanged() }
        guard generation == sampleGeneration else { return }
        for observer in snapshotObservers { observer(snapshot) }
        let counters = readCounters?()
        let scope = preferences.trafficScope ?? "external", wifi = wifiNames
        let physical: (String) -> Bool = { InterfaceCounters.physical($0, scope: scope, wifi: wifi) }
        let starts = Dictionary(snapshot.processes.map { ($0.pid, startTime($0.pid)) }) { first, _ in first }
        // The first sample is only a baseline: apps and rates exist from the second on, so that's when the store is ready.
        let hadBaseline = lastSample != nil
        defer {
            // A process missing from a sample keeps its place for half a minute, so it isn't counted again from scratch.
            var seen = previous.filter { snapshot.timestamp.timeIntervalSince($0.value.at) < 30 }
            for process in snapshot.processes { seen[process.pid] = SeenProcess(traffic: process, started: starts[process.pid] ?? nil, at: snapshot.timestamp) }
            previous = seen
            lastSample = snapshot.timestamp
            if hadBaseline { ready = true }
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
        owningApps = owningApps.filter { kept[$0.key] != nil }
        for process in snapshot.processes {
            // First sighting establishes a baseline, never imports lifetime data.
            guard let flow = TrafficAttribution.flow(process, started: starts[process.pid] ?? nil, previous: previous[process.pid],
                                                     lastSample: lastSample, elapsed: elapsed, physical: physical) else { continue }
            let (id, name, path) = identity(process)
            var app = index[id] ?? AppTraffic(id: id, name: name, bundlePath: path)
            app.processIDs.append(process.pid)
            app.executablePath = executables[process.pid] ?? app.executablePath
            let owner: String?
            if let known = owningApps[process.pid] { owner = known.isEmpty ? nil : known }
            else { owner = ownerPath(process.pid); owningApps[process.pid] = owner ?? "" }
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
            if !carrier { all += flow.total; local += flow.local; tunnel += flow.tunnel }
            physicalLocal += flow.physicalLocal
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
        let quiet = viewsAreHidden()
        if quiet { _apps = Array(index.values) } else { apps = Array(index.values) }
        // Taken out while it's added to, so a second's sample doesn't copy every app's history.
        var series = _liveSeries
        _liveSeries = [:]
        for app in apps { series[app.id, default: LiveSeries()].append(down: app.downloadRate, up: app.uploadRate) }
        for id in series.keys where index[id]?.processIDs.isEmpty != false {
            series[id]?.append(down: 0, up: 0)
            if series[id]?.isIdle == true { series[id] = nil }
        }
        if quiet { _liveSeries = series } else { liveSeries = series }
        let counted = macInternet(counters, elapsed: elapsed, attributed: internet, physicalLocal: physicalLocal, physical: physical)
        if quiet { _received += counted.received; _sent += counted.sent } else { received += counted.received; sent += counted.sent }
        pendingReceived += counted.received; pendingSent += counted.sent
        pendingLocal += local.total
        if quiet { _local += local.total; _tunnel += tunnel.total } else { self.local += local.total; self.tunnel += tunnel.total }
        if quiet {
            _download = Double(all.received) / elapsed; _upload = Double(all.sent) / elapsed
            _downloadHistory = Array((_downloadHistory + [_download]).suffix(60))
            _uploadHistory = Array((_uploadHistory + [_upload]).suffix(60))
            heldBack = true
        } else {
            download = Double(all.received) / elapsed; upload = Double(all.sent) / elapsed
            downloadHistory = Array((downloadHistory + [download]).suffix(60))
            uploadHistory = Array((uploadHistory + [upload]).suffix(60))
            // A figure that stopped moving wouldn't notify on its own, so views catch up on what they missed.
            if heldBack { heldBack = false; announceHeldBack() }
        }
        if snapshot.timestamp.timeIntervalSince(lastFlush) >= 30 { flush() }
    }
    private func announceHeldBack() {
        withMutation(keyPath: \.apps) {}; withMutation(keyPath: \.liveSeries) {}
        withMutation(keyPath: \.received) {}; withMutation(keyPath: \.sent) {}; withMutation(keyPath: \.local) {}; withMutation(keyPath: \.tunnel) {}
    }
    /// What the Mac sent to and received from the Internet in a sample. Wi-Fi and Ethernet counters see everything
    /// the carrier bills, from processes nettop missed too, and a VPN's traffic once (its tunnel isn't counted); their
    /// local traffic is taken out. Without counters, the processes' own Internet bytes stand in.
    private func macInternet(_ counters: [String: ByteCount]?, elapsed: TimeInterval, attributed: ByteCount, physicalLocal: ByteCount, physical: (String) -> Bool) -> ByteCount {
        guard readCounters != nil else { return attributed }
        guard let counters else {
            // A missed reading is caught up by the next one; only several in a row mean the counters are gone.
            counterFailures += 1
            if counterFailures < 5 { localCarry += physicalLocal }
            if counterFailures == 5 { interfaces.reset(); localCarry = ByteCount() }
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
    /// Internet bytes on this network not saved to history yet.
    var pendingBytes: UInt64 { pendingReceived + pendingSent }
    public func flush() { flush(at: Date()) }

    func flush(at date: Date) {
        guard recordHistory, pendingReceived + pendingSent + pendingLocal > 0 else { return }
        let gap = pendingUnattributed
        unattributed += gap
        let row = UsageEntry(date: date, received: pendingReceived, sent: pendingSent, apps: pendingApps, networkKey: networkKey, appsSent: pendingAppsSent,
                                localBytes: pendingLocal, appsLocal: pendingAppsLocal.isEmpty ? nil : pendingAppsLocal, unattributed: countsInterfaces ? gap : nil,
                                metered: metered ? true : nil)
        usage.append(row)
        let prunedUsage = retainUsage(at: date)
        // The new row is all that's new: the whole file only about once an hour, not every 30 seconds.
        if prunedUsage || abs(date.timeIntervalSince(usageRewritten)) >= Self.usageRewriteEvery || usageTailRows >= Self.usageTailLimit {
            persistUsage(); usageRewritten = date; usageTailRows = 0
        } else { appendUsage(row); usageTailRows += 1 }
        networkSessions[networkKey] = session
        persist(networkSessions, as: "network-sessions.json")
        pendingReceived = 0; pendingSent = 0; pendingApps = [:]; pendingAppsSent = [:]; lastFlush = Date()
        pendingLocal = 0; pendingAppsLocal = [:]; pendingAttributed = 0
    }
    public func reloadPreferences() {
        // Asked twice a second: the file's stamp says whether reading it is worth it.
        let path = directory.appendingPathComponent("preferences.json").path
        var info = stat()
        if stat(path, &info) == 0 {
            let stamp = [Int(info.st_mtimespec.tv_sec), info.st_mtimespec.tv_nsec, Int(info.st_size), Int(info.st_ino)]
            guard stamp != preferencesStamp else { return }
            preferencesStamp = stamp
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("preferences.json")),
              data != lastPreferencesData,
              let saved = try? JSONDecoder().decode(SavedPreferences.self, from: data) else { return }
        let scopeChanged = preferences.trafficScope != saved.trafficScope
        lastPreferencesData = data
        preferencesSaveError = nil
        preferencesUnreadable = !ownsFiles && (saved.schema ?? 0) > SavedPreferences.currentSchema
        reloading = true; preferences = saved; reloading = false
        if preferences != saved { savePreferences() }
        if scopeChanged { setScope(saved.trafficScope ?? "external") }
    }
    public func savePreferences() {
        guard !preferencesUnreadable else {
            LocalFiles.noteRefusedWrite()
            preferencesSaveError = "preferences.json couldn’t be read by this version of Kilobat, so it was left unchanged. It was probably saved by a newer version: update this copy."
            return
        }
        do {
            let url = directory.appendingPathComponent("preferences.json")
            let data = try preferences.dataForDisk(over: try? Data(contentsOf: url))
            try data.write(to: url, options: .atomic)
            lastPreferencesData = data
            preferencesSaveError = nil
        } catch {
            preferencesSaveError = String(localized: "Could not save local data: \(error.localizedDescription)")
        }
    }
    public func shutdown() { flush(); Self.writer.sync {}; monitor.stop() }
    /// Detail expires on the selected schedule. Only per-network byte totals needed by an active
    /// allowance survive that cutoff, and they share the usage file's atomic rewrite.
    @discardableResult func retainUsage(at date: Date) -> Bool {
        let cutoff = date.addingTimeInterval(-Double(preferences.historyDays ?? 365) * 86_400)
        let packs = dataPacks
        let active = packs.filter { $0.start <= date && date < $0.finish }
        let expiredDetail = usage.contains { $0.date < cutoff }
        let quotas = (preferences.quotas ?? []).filter { $0.effectiveMode != .off }
        let networkCycles = preferences.networkCycles ?? [:]
        let workingCycle = budgetCycle
        func contains(_ interval: DateInterval?, _ sample: Date) -> Bool {
            interval.map { $0.start <= sample && sample < $0.end } ?? false
        }
        let quotaWindows = quotas.map { quota in
            // An all-network legacy quota follows whichever network is selected. Keep enough for any saved cycle.
            let cycles = quota.network == nil && quota.cycle == nil ? Array(networkCycles.values) + [workingCycle] : [budgetCycle(counting: quota)]
            return (quota, cycles.map { quota.resolvedCycle(budget: $0).limitInterval(containing: date) })
        }
        var reducedAllowance = false
        var carried: [UsageEntry] = []
        for row in allowanceHistory + usage where row.allowanceOnly == true || row.date < cutoff {
            var keepsNetworkTotals = false
            if let key = row.networkKey, key != "unknown" {
                let cycle = key == networkKey ? workingCycle : networkCycles[key]
                keepsNetworkTotals = contains(cycle?.interval(containing: date), row.date) || active.contains {
                    $0.counts(at: row.date) && $0.networks.matches(key: key, name: networkName(of: key))
                }
            }
            let names = Set(quotaWindows.compactMap { quota, intervals in
                (quota.network == nil || quota.network == row.networkKey) && intervals.contains { contains($0, row.date) }
                    ? quota.name : nil
            })
            let apps = row.apps.filter { names.contains($0.key) }
            if row.allowanceOnly == true, apps != row.apps || (!keepsNetworkTotals && row.total > 0) { reducedAllowance = true }
            guard keepsNetworkTotals || !apps.isEmpty else { continue }
            carried.append(UsageEntry(date: row.date, received: keepsNetworkTotals ? row.received : 0,
                                      sent: keepsNetworkTotals ? row.sent : 0, apps: apps, networkKey: row.networkKey,
                                      appsSent: row.estimatedSent.filter { apps[$0.key] != nil }, allowanceOnly: true))
        }
        let discardedAllowance = carried.count < allowanceHistory.count
        allowanceHistory = Self.compact(carried, now: date, packs: packs)
        usage = Self.compact(usage.filter { $0.date >= cutoff }, now: date, packs: packs)
        return expiredDetail || discardedAllowance || reducedAllowance
    }

    /// Samples older than a day merge into hourly buckets per network, and older than 30 days into daily ones,
    /// so a year of history stays small enough to rewrite on every flush. Entries keep the same shape for existing readers.
    static func compact(_ usage: [UsageEntry], now: Date = Date(), calendar: Calendar = .current, packs: [DataPack] = []) -> [UsageEntry] {
        let recent = now.addingTimeInterval(-86_400), old = now.addingTimeInterval(-30 * 86_400)
        var buckets: [String: [UsageEntry]] = [:]
        var kept: [UsageEntry] = []
        // Keep pack accounting boundaries when folding hour and day rows.
        let boundaries = Set(packs.flatMap { pack in
            [pack.countsFrom(calendar: calendar), pack.finish] + (pack.correction.map { [$0.after] } ?? [])
        }).sorted()
        func bucket(_ date: Date) -> Date? {
            guard let start = calendar.dateInterval(of: date < old ? .day : .hour, for: date)?.start else { return nil }
            return boundaries.last { start < $0 && $0 <= date } ?? start
        }
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
                              unattributed: sum(entries.map(\.unattributed)), metered: entries.contains { $0.metered == true } ? true : nil,
                              allowanceOnly: entries[0].allowanceOnly)
        }
        return (merged + kept).sorted { $0.date < $1.date }
    }
    /// A year of usage takes real time to encode, so it's done off the main thread, in order. `shutdown` waits for it.
    private func appendUsage(_ row: UsageEntry) {
        let folder = directory
        Self.writer.async { [weak self] in
            do { try UsageFile.append(row, directory: folder) }
            catch { let message = error.localizedDescription; Task { @MainActor [weak self] in self?.error = String(localized: "Could not save local data: \(message)") } }
        }
    }
    private static let usageRewriteEvery: TimeInterval = 3600, usageTailLimit = 240
    @ObservationIgnored private var usageRewritten = Date()
    @ObservationIgnored private lazy var usageTailRows = UsageFile.tailRows(directory).count
    private func persistUsage() {
        let value = allowanceUsage, file = directory.appendingPathComponent(UsageFile.name), folder = directory
        Self.writer.async { [weak self] in
            do { try JSONEncoder().encode(value).write(to: file, options: .atomic); UsageFile.removeTail(directory: folder) }
            catch { let message = error.localizedDescription; Task { @MainActor [weak self] in self?.error = String(localized: "Could not save local data: \(message)") } }
        }
    }
    private nonisolated static let writer = DispatchQueue(label: "co.seifi.kilobat.usage-write", qos: .utility)
    @ObservationIgnored private var preferencesStamp: [Int] = []
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
/// Usage history on disk: the whole of it in usage.json, rewritten about once an hour, and each row since then appended to a
/// small tail, so history doesn't rewrite megabytes every 30 seconds. Readers go through `read`, which puts the two together.
enum UsageFile {
    static let name = "usage.json", tail = "usage-tail.jsonl"
    static func read(_ directory: URL, includesAllowances: Bool = false) -> [UsageEntry] {
        var rows: [UsageEntry] = StoredJSON.read(directory.appendingPathComponent(name)) ?? []
        // A crash between saving the whole file and clearing the tail leaves rows in both; the whole file wins.
        let newest = rows.map(\.date).max() ?? .distantPast
        rows += tailRows(directory).filter { $0.date > newest }
        return includesAllowances ? rows : rows.filter { $0.allowanceOnly != true }
    }
    /// One JSON object per line. A line cut short by a crash is skipped; the rows before it are good.
    static func tailRows(_ directory: URL) -> [UsageEntry] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(tail)) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(UsageEntry.self, from: Data($0)) }
    }
    static func append(_ row: UsageEntry, directory: URL) throws {
        let file = directory.appendingPathComponent(tail)
        var line = try JSONEncoder().encode(row)
        line.append(0x0A)
        guard FileManager.default.fileExists(atPath: file.path) else { try line.write(to: file, options: .atomic); return }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
    static func removeTail(directory: URL) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(tail)) }
}

/// Who may move an unreadable file aside. The app owns the files in Application Support/Kilobat and does (the
/// default). The command line and the MCP server only visit: a file they can't read may simply be newer than they
/// are, so they leave it exactly where it is.
public enum LocalFiles {
    private struct State { var moves = true; var refused = 0 }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    public static var movesUnreadableAside: Bool {
        get { state.withLock { $0.moves } }
        set { state.withLock { $0.moves = newValue } }
    }
    /// Saves a visiting process declined because it couldn't read the file it would have replaced.
    public static var refusedWrites: Int { state.withLock { $0.refused } }
    public static func noteRefusedWrite() { state.withLock { $0.refused += 1 } }
}

enum StoredJSON {
    enum Loaded<T> { case missing, value(T), unreadable }
    static func load<T: Decodable>(_ url: URL, quarantine: Bool = LocalFiles.movesUnreadableAside) -> Loaded<T> {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        do { return .value(try JSONDecoder().decode(T.self, from: data)) } catch {
            if quarantine {
                let aside = url.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: url, to: aside)
            }
            return .unreadable
        }
    }
    static func read<T: Decodable>(_ url: URL, quarantine: Bool = LocalFiles.movesUnreadableAside) -> T? {
        if case .value(let value) = load(url, quarantine: quarantine) as Loaded<T> { return value }
        return nil
    }
}
