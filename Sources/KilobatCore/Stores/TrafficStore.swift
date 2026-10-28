import AppKit
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
    public var preferences: SavedPreferences { didSet { savePreferences() } }
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
    private let directory: URL

    public init(directory: URL? = nil, startMonitoring: Bool = true, recordHistory: Bool = true) {
        self.recordHistory = recordHistory
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        preferences = (try? JSONDecoder().decode(SavedPreferences.self, from: Data(contentsOf: self.directory.appendingPathComponent("preferences.json")))) ?? SavedPreferences()
        lastPreferencesData = try? Data(contentsOf: self.directory.appendingPathComponent("preferences.json"))
        usage = (try? JSONDecoder().decode([UsageEntry].self, from: Data(contentsOf: self.directory.appendingPathComponent("usage.json")))) ?? []
        networkSessions = (try? JSONDecoder().decode([String: NetworkSession].self, from: Data(contentsOf: self.directory.appendingPathComponent("network-sessions.json")))) ?? [:]
        if startMonitoring {
            startCollector(scope: preferences.trafficScope ?? "external")
            network.start { [weak self] connected, expensive, kind in
                Task { @MainActor in
                    guard let self else { return }
                    self.connected = connected
                    self.expensive = expensive
                    self.networkKind = kind
                    if expensive && self.preferences.autoHotspot { self.preferences.profile = .travel }
                }
            }
        }
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
        if let temporary = preferences.temporaryRules?[preferences.profile.rawValue + "|" + id], temporary.expires > Date() { return temporary.allowed }
        return preferences.rules[preferences.profile.rawValue]?[id] ?? preferences.defaultAllow
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
        let temporary = preferences.temporaryRules?.removeValue(forKey: profile + "|" + id) != nil
        let saved = preferences.rules[profile]?.removeValue(forKey: id) != nil
        return temporary || saved
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
        let name = app?.bundleIdentifier != nil ? app?.localizedName ?? process.process : process.process
        let id = app?.bundleIdentifier ?? "process:\(process.process)"
        let value = (id, name, app?.bundleURL?.path)
        identities[process.pid] = value
        return value
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
            owners[id, default: []].insert(ProcessOwnership.applicationPath(pid: process.pid) ?? "")
            app.received += down; app.sent += up
            app.downloadRate += Double(down) / elapsed
            app.uploadRate += Double(up) / elapsed
            index[id] = app
            incoming += down; outgoing += up
            pendingApps[name, default: 0] += down + up
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
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        usage = usage.filter { $0.date >= cutoff }
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
        preferences = saved
        if scopeChanged { setScope(saved.trafficScope ?? "external") }
    }
    public func savePreferences() {
        persist(preferences, as: "preferences.json")
        lastPreferencesData = try? Data(contentsOf: directory.appendingPathComponent("preferences.json"))
    }
    public func shutdown() { flush(); monitor.stop() }
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
