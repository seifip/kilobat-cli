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
    public var expensive = false
    public var networkKind = "Connecting"
    public var ready = false
    public var error: String?
    public var search = ""
    public var filter = "All apps"
    public var selectedApp: String?
    public var preferences: SavedPreferences { didSet { if preferences != oldValue && !reloading { savePreferences() } } }
    public var usage: [UsageEntry] = []
    public var networkKey = "unknown"
    public var networkName = "Current session"
    public var networkSessions: [String: NetworkSession] = [:]
    public let startedAt = Date()
    private var previous: [Int32: ProcessTraffic] = [:]
    private var lastSample: Date?
    private var pendingReceived: UInt64 = 0
    private var pendingSent: UInt64 = 0
    private var pendingApps: [String: UInt64] = [:]
    private var lastFlush = Date()
    private var identities: [Int32: (String, String, String?)] = [:]
    private let monitor = NettopMonitor()
    private var sampleGeneration = UUID()
    private let network = NetworkStatus()
    private let recordHistory: Bool
    private var lastPreferencesData: Data?
    private var reloading = false
    private var metered: Bool?
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
        if startMonitoring {
            startCollector(scope: preferences.trafficScope ?? "external")
            network.start { [weak self] connected, expensive, kind in
                Task { @MainActor in
                    guard let self else { return }
                    self.connected = connected
                    self.expensive = expensive
                    self.networkKind = kind
                    self.meteredChanged(expensive)
                }
            }
        }
    }

    /// Travel is applied when a metered network appears, not on every path update, and the
    /// previous profile returns afterwards unless the user picked another one meanwhile.
    func meteredChanged(_ expensive: Bool) {
        defer { metered = expensive }
        guard recordHistory, expensive != metered else { return }
        var next = preferences
        if expensive {
            guard next.autoHotspot, next.profile != .travel else { return }
            next.autoProfileFrom = next.profile.rawValue; next.profile = .travel
        } else if let previous = next.autoProfileFrom {
            if next.profile == .travel, let profile = NetworkProfile(rawValue: previous) { next.profile = profile }
            next.autoProfileFrom = nil
        }
        preferences = next
    }

    public var total: UInt64 { received + sent }
    public var limit: UInt64 { UInt64(preferences.limitGB * 1_000_000_000) }
    public var limitFraction: Double { min(1, Double(total) / Double(max(1, limit))) }
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
            networkSessions[networkKey] = NetworkSession(name: networkName, received: received, sent: sent)
            let oldLimit = preferences.limitGB
            if preferences.networkLimits == nil { preferences.networkLimits = [:] }
            preferences.networkLimits?[networkKey] = oldLimit
        }
        networkKey = snapshot.networkKey; networkName = snapshot.networkName
        let saved = networkSessions[networkKey]
        received = saved?.received ?? 0; sent = saved?.sent ?? 0
        apps = []; previous = [:]; lastSample = nil
        preferences.limitGB = preferences.networkLimits?[networkKey] ?? 5
        if let profile = preferences.networkProfiles?[networkKey], let value = NetworkProfile(rawValue: profile) { preferences.profile = value }
        persist(networkSessions, as: "network-sessions.json")
    }
    public func rememberNetwork() {
        if preferences.networkProfiles == nil { preferences.networkProfiles = [:] }
        if preferences.networkLimits == nil { preferences.networkLimits = [:] }
        let profile = preferences.profile.rawValue, limit = preferences.limitGB
        preferences.networkProfiles?[networkKey] = profile
        preferences.networkLimits?[networkKey] = limit
    }
    public func setScope(_ scope: String) {
        guard ["external", "wifi", "wired"].contains(scope) else { return }
        flush(); preferences.trafficScope = scope
        previous = [:]; lastSample = nil; download = 0; upload = 0
        startCollector(scope: scope)
    }
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
        received = 0; sent = 0
        networkSessions[networkKey] = NetworkSession(name: networkName)
        persist(networkSessions, as: "network-sessions.json")
        for index in apps.indices { apps[index].received = 0; apps[index].sent = 0 }
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
        return value
    }
    static func executableName(pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
        return name.isEmpty ? nil : name
    }
    public func consume(_ snapshot: TrafficSnapshot) {
        let generation = sampleGeneration
        reloadPreferences()
        guard generation == sampleGeneration else { return }
        defer {
            previous = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0) })
            lastSample = snapshot.timestamp
            ready = true
        }
        guard let lastSample else { return }
        let elapsed = max(0.1, snapshot.timestamp.timeIntervalSince(lastSample))
        var index = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        for key in index.keys { index[key]?.downloadRate = 0; index[key]?.uploadRate = 0; index[key]?.processIDs = [] }
        var incoming: UInt64 = 0, outgoing: UInt64 = 0
        var owners: [String: Set<String>] = [:]
        let currentPIDs = Set(snapshot.processes.map(\.pid))
        let currentNames = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.pid, $0.process) })
        identities = identities.filter { currentPIDs.contains($0.key) && previous[$0.key]?.process == currentNames[$0.key] }
        for process in snapshot.processes {
            // First sighting establishes a baseline, never imports lifetime data.
            guard let old = previous[process.pid], old.process == process.process else { continue }
            let down = process.received >= old.received ? process.received - old.received : 0
            let up = process.sent >= old.sent ? process.sent - old.sent : 0
            let (id, name, path) = identity(process)
            var app = index[id] ?? AppTraffic(id: id, name: name, bundlePath: path)
            app.processIDs.append(process.pid)
            let owner = ProcessOwnership.applicationPath(pid: process.pid)
            owners[id, default: []].insert(owner ?? "")
            app.received += down; app.sent += up
            app.downloadRate += Double(down) / elapsed
            app.uploadRate += Double(up) / elapsed
            index[id] = app
            incoming += down; outgoing += up
            // History counts helpers and services under the app that owns them, as the app list does.
            pendingApps[owner.flatMap { $0 == path ? nil : AppTrafficGroup.displayName($0) } ?? name, default: 0] += down + up
        }
        for (id, paths) in owners {
            index[id]?.ownerPath = paths.count == 1 ? paths.first.flatMap { $0.isEmpty ? nil : $0 } : nil
        }
        apps = Array(index.values)
        received += incoming; sent += outgoing
        pendingReceived += incoming; pendingSent += outgoing
        download = Double(incoming) / elapsed; upload = Double(outgoing) / elapsed
        downloadHistory = Array((downloadHistory + [download]).suffix(60))
        uploadHistory = Array((uploadHistory + [upload]).suffix(60))
        if snapshot.timestamp.timeIntervalSince(lastFlush) >= 30 { flush() }
    }
    public func flush() {
        guard recordHistory, pendingReceived + pendingSent > 0 else { return }
        usage.append(UsageEntry(date: Date(), received: pendingReceived, sent: pendingSent, apps: pendingApps, networkKey: networkKey))
        let cutoff = Date().addingTimeInterval(-Double(preferences.historyDays ?? 365) * 86_400)
        usage = Self.compact(usage.filter { $0.date >= cutoff })
        persist(usage, as: "usage.json")
        networkSessions[networkKey] = NetworkSession(name: networkName, received: received, sent: sent)
        persist(networkSessions, as: "network-sessions.json")
        pendingReceived = 0; pendingSent = 0; pendingApps = [:]; lastFlush = Date()
    }
    public func reloadPreferences() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("preferences.json")),
              data != lastPreferencesData,
              let saved = try? JSONDecoder().decode(SavedPreferences.self, from: data) else { return }
        let scopeChanged = preferences.trafficScope != saved.trafficScope
        lastPreferencesData = data
        reloading = true; preferences = saved; reloading = false
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
        for entry in usage {
            guard entry.date < recent, let start = bucket(entry.date) else { kept.append(entry); continue }
            buckets["\(start.timeIntervalSince1970)|\(entry.networkKey ?? "")", default: []].append(entry)
        }
        let merged = buckets.values.map { entries -> UsageEntry in
            let start = bucket(entries[0].date) ?? entries[0].date
            if entries.count == 1 && entries[0].date == start { return entries[0] }
            return UsageEntry(date: start, received: entries.reduce(0) { $0 + $1.received }, sent: entries.reduce(0) { $0 + $1.sent },
                              apps: entries.reduce(into: [:]) { apps, entry in apps.merge(entry.apps, uniquingKeysWith: +) }, networkKey: entries[0].networkKey)
        }
        return (merged + kept).sorted { $0.date < $1.date }
    }
    private func persist<T: Encodable>(_ value: T, as name: String) {
        do { try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic) }
        catch { self.error = "Could not save local data: \(error.localizedDescription)" }
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
