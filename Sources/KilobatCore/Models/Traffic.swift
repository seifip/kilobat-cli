import Foundation

public struct ProcessTraffic: Identifiable, Sendable {
    public let pid: Int32
    public let process: String
    public let received: UInt64
    public let sent: UInt64
    /// Its open connections, each with its bytes since it opened.
    public var connections: [ConnectionTraffic] = []
    public var id: Int32 { pid }
    public var total: UInt64 { received + sent }
    public init(pid: Int32, process: String, received: UInt64, sent: UInt64, connections: [ConnectionTraffic] = []) {
        self.pid = pid; self.process = process; self.received = received; self.sent = sent; self.connections = connections
    }
}

/// One socket from nettop's per-connection rows, keyed by protocol and endpoints.
public struct ConnectionTraffic: Sendable, Equatable {
    public let id: String
    public let route: TrafficRoute
    public let interface: String
    public let received: UInt64
    public let sent: UInt64
    public init(id: String, route: TrafficRoute, interface: String, received: UInt64, sent: UInt64) {
        self.id = id; self.route = route; self.interface = interface; self.received = received; self.sent = sent
    }
}

public struct TrafficSnapshot: Sendable {
    public let timestamp: Date
    public let processes: [ProcessTraffic]
}

/// One process's rates in the latest sample.
public struct ProcessRate: Sendable, Equatable {
    public var down: Double
    public var up: Double
    public init(down: Double, up: Double) { self.down = down; self.up = up }
}

public struct AppTraffic: Identifiable {
    public let id: String
    public var name: String
    public var processIDs: [Int32] = []
    public var ownerPath: String? = nil
    public var bundlePath: String?
    /// Everything the app moved, local network included; `local` and `tunnel` say how much of it was which.
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public var downloadRate: Double = 0
    public var uploadRate: Double = 0
    /// Bytes to this network, AirDrop and other nearby devices, which budgets don't count.
    public var local: UInt64 = 0
    /// Bytes through a VPN tunnel. A budget counts the tunnel where it leaves the Mac, on Wi-Fi or Ethernet.
    public var tunnel: UInt64 = 0
    /// The latest sample's rates by process.
    public var rates: [Int32: ProcessRate] = [:]
    /// Where the executable of a command-line tool Kilobat doesn't recognise lives.
    public var executablePath: String? = nil
    /// A proxy core or VPN tunnel: what it moves is other apps' traffic, counted for them.
    public var carrier = false
    public var total: UInt64 { received + sent }
    /// What a budget counts for the app: everything but the local network.
    public var internet: UInt64 { total > local ? total - local : 0 }
    public var rate: Double { downloadRate + uploadRate }

    /// The app counting only `pids`, so a run owns the helpers it started rather than every process with the
    /// same name. Byte totals are shared out by process count; rates come from each process's own.
    public func only(_ pids: Set<Int32>) -> AppTraffic {
        var copy = self
        copy.processIDs = processIDs.filter(pids.contains)
        guard copy.processIDs.count != processIDs.count else { return self }
        let share = Double(copy.processIDs.count) / Double(max(1, processIDs.count))
        copy.rates = rates.filter { pids.contains($0.key) }
        if rates.isEmpty { copy.downloadRate *= share; copy.uploadRate *= share }
        else { copy.downloadRate = copy.rates.values.reduce(0) { $0 + $1.down }; copy.uploadRate = copy.rates.values.reduce(0) { $0 + $1.up } }
        copy.received = UInt64(Double(received) * share); copy.sent = UInt64(Double(sent) * share)
        copy.local = UInt64(Double(local) * share); copy.tunnel = UInt64(Double(tunnel) * share)
        return copy
    }
}

public struct UsageEntry: Codable, Identifiable {
    public var id: UUID = UUID()
    public let date: Date
    public let received: UInt64
    public let sent: UInt64
    public let apps: [String: UInt64]
    public var networkKey: String? = nil
    /// Bytes each app sent; the rest of its total was received. Missing in history from before 1.2.
    public var appsSent: [String: UInt64]? = nil
    /// Bytes to this network, AirDrop and other nearby devices, kept out of `received`, `sent` and `apps`. Missing before 1.3.
    public var localBytes: UInt64? = nil
    public var appsLocal: [String: UInt64]? = nil
    /// Bytes the network interfaces carried that no process accounts for, packet headers included; already part of `received` and `sent`.
    public var unattributed: UInt64? = nil
    /// The network was metered while these bytes moved, by macOS or by hand; nil when it wasn't or before 1.22.
    public var metered: Bool? = nil
    /// Network totals kept solely to finish accounting for an active allowance.
    var allowanceOnly: Bool? = nil
    public var total: UInt64 { received + sent }
}

public struct NetworkSession: Codable, Sendable {
    public var name: String
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    /// False for a network Kilobat couldn't tell apart from others, such as Wi-Fi whose name macOS hid; nil when it could.
    public var identified: Bool? = nil
    public var local: UInt64? = nil
    public var unattributed: UInt64? = nil
    public var budgetSession: UUID? = nil
    public init(name: String, received: UInt64 = 0, sent: UInt64 = 0, identified: Bool? = nil, local: UInt64? = nil, unattributed: UInt64? = nil, budgetSession: UUID? = nil) {
        self.name = name; self.received = received; self.sent = sent; self.identified = identified; self.local = local; self.unattributed = unattributed; self.budgetSession = budgetSession
    }
}

/// What a network costs, set by hand for hotspots and tethering macOS doesn't flag. Automatic follows macOS.
public enum NetworkCost: String, CaseIterable, Identifiable, Sendable {
    case automatic, metered, unmetered
    public var id: String { rawValue }
    public var title: String {
        switch self { case .automatic: String(localized: "Automatic"); case .metered: String(localized: "Metered"); case .unmetered: String(localized: "Unmetered") }
    }
    public func metered(os: Bool) -> Bool { self == .automatic ? os : self == .metered }
    /// For JSON: `metered` is what Kilobat acts on, `osMetered` what macOS says and `meteredSource` which of the two decided.
    public func fields(os: Bool) -> [String: Any] { ["metered": metered(os: os), "osMetered": os, "meteredSource": self == .automatic ? "macOS" : "you"] }
}
public struct SavedPreferences: Codable, Equatable {
    public var connectionRules: [ConnectionRule]? = nil
    public var temporaryRules: [String: TemporaryRule]? = nil
    public var networkProfiles: [String: String]? = nil
    public var networkBudgetModes: [String: NetworkBudgetMode]? = nil
    public var networkLimits: [String: Double]? = nil
    public var trafficScope: String? = nil
    public var blockedDomains: [String]? = nil
    /// Domains, IPs and ranges blocked by hand for every app, kept apart from an imported list.
    public var blockedHosts: [String]? = nil
    public var blocklistName: String? = nil
    public var domainExceptions: [String: [String]]? = nil
    /// The profile to restore when the metered network that switched to Travel goes away.
    public var autoProfileFrom: String? = nil
    public var profile: NetworkProfile = .travel
    /// On disk only: the profile in use when it's one the person added. `profile` is then written as Work, so a copy of
    /// Kilobat or its command line from before profiles of your own still reads the file instead of starting over.
    public var customProfile: String? = nil
    /// Names and icons the person gave the built-in profiles, and profiles they added. See `ProfileDefinition`.
    public var profileDefinitions: [ProfileDefinition]? = nil
    /// Weekly times to switch profile (Pro). See `ProfileScheduler`.
    public var profileSchedules: [ProfileSchedule]? = nil
    /// The schedule that switched the profile, and the profile it switched from.
    public var profileScheduleState: ProfileScheduleState? = nil
    /// Where apps sent and received data, per site per day (Pro); nil is off. See `DestinationHistory`.
    public var destinationHistory: DestinationHistorySettings? = nil
    public var rules: [String: [String: Bool]] = [:]
    public var limitGB: Double = 5
    public var autoHotspot: Bool = true
    public var defaultAllow: Bool = false
    /// How long usage history is kept; nil means a year.
    public var historyDays: Int? = nil
    /// Hold connections from apps without a rule until the user allows or blocks them.
    public var askNewApps: Bool? = nil
    /// Apple-signed software connects without a rule when new apps are blocked or asked about.
    public var allowApple: Bool? = nil
    /// Alert mode: apps without a rule connect (`defaultAllow` is true), and the filter lists them quietly for review.
    /// Older copies of Kilobat that don't know it simply allow new apps.
    public var alertNewApps: Bool? = nil
    /// Apps (rule keys) that ask before reaching a destination their rules don't cover (Pro). Nil is none.
    public var askDestinations: [String]? = nil
    /// Developer names for developer rules, by Team ID ("Example Inc"), so the Rules list can name them. Nil is none.
    public var developerNames: [String: String]? = nil
    /// Blocklists subscribed to by URL; nil is none. See `BlocklistSubscription`.
    public var blocklistSubscriptions: [BlocklistSubscription]? = nil
    /// The connection log keeps the last hour in memory while Kilobat runs; false pauses it. Nil is on.
    public var connectionLog: Bool? = nil
    /// The connection log also lists browsers, whose destinations are browsing history; nil leaves them out.
    public var connectionLogBrowsers: Bool? = nil
    /// The current network's budget cycle, kept per network in `networkCycles` like `limitGB` in `networkLimits`. Nil is a total budget.
    public var budgetCycle: BudgetCycle? = nil
    public var networkCycles: [String: BudgetCycle]? = nil
    /// App limits, under the key they had as quotas so older files keep decoding.
    public var quotas: [AppLimit]? = nil
    /// Notify when an app uploads far more than usual in an hour.
    public var uploadAlerts: Bool? = nil
    /// "metered" or "unmetered" per network key; networks without an entry follow macOS.
    public var networkCost: [String: String]? = nil
    /// Block updater helpers while the network is metered; nil means on. See `UpdaterPause`.
    public var pauseUpdaters: Bool? = nil
    /// Block cloud storage clients (Dropbox, Google Drive, OneDrive…) while the network is metered; nil means on. See `CloudSyncPause`.
    public var pauseCloudSync: Bool? = nil
    /// A Focus filter pauses updaters on every network while its Focus is on; nil otherwise. See `FocusFilterStore`.
    public var focusPausesUpdaters: Bool? = nil
    /// The VPN kill switch (Pro): new connections wait while the VPN is down. Nil is off. See `KillSwitchState`.
    public var killSwitch: Bool? = nil
    /// While the kill switch blocks, the local network stays reachable; nil means it does.
    public var killSwitchLAN: Bool? = nil
    /// "Allow for 5 minutes": the kill switch lets traffic through until then, or until the VPN is back.
    public var killSwitchAllowedUntil: Date? = nil
    /// Protection: known malware, phishing and scam destinations (Pro). Nil is on.
    public var protectThreats: Bool? = nil
    /// Protection: tracker and ad hosts in apps. Nil is off.
    public var protectTrackers: Bool? = nil
    /// Which tracker list (`ProtectionLists.trackers`); nil is HaGeZi Multi Light.
    public var trackerList: String? = nil
    /// The stricter agent guard (Pro). Nil is off.
    public var agentGuard: Bool? = nil
    /// The agent guard's large-upload limit in MB; nil is 10.
    public var agentGuardUploadMB: Int? = nil
    /// Sites allowed with "Allow this site": no Protection list or rule applies to them.
    public var allowedSites: [String]? = nil
    /// Switch to the fastest DNS on every network (Pro). Nil is off. See `FastestDNS`.
    public var fastestDNS: Bool? = nil
    /// The same per network key, overriding `fastestDNS`.
    public var networkFastestDNS: [String: Bool]? = nil
    /// Resolvers never timed or picked: "cloudflare", "quad9", "google".
    public var dnsExcluded: [String]? = nil
    /// Resolvers the person added by IP address, timed alongside the presets.
    public var dnsExtra: [String]? = nil
    /// Prepaid data packs, such as a travel eSIM reached through a phone's hotspot: running, upcoming and a year of finished ones.
    public var dataPacks: [DataPack]? = nil
    /// The resolver asked over DNS-over-HTTPS for a control answer while a failure is diagnosed: "cloudflare" or "quad9". Nil is Cloudflare.
    public var blockCheckResolver: String? = nil
    /// The resolver fastest DNS falls back to when the one it picked fails, before the network's own; nil is none.
    public var dnsFallback: String? = nil
    /// On disk only: the layout version of the file. A command line older than the file's number doesn't save over it
    /// (`TrafficStore`); `settleProfiles()` clears it after a read. Bumped only for a change an older writer would damage.
    public var schema: Int? = nil
    public static let currentSchema = 1
    public func budgetMode(for network: String) -> NetworkBudgetMode {
        if let mode = networkBudgetModes?[network] { return mode }
        // Older versions saved 5 GB even on networks the user never configured.
        if networkCycles?[network] != nil || (networkLimits?[network] ?? 5) != 5 { return .block }
        return .off
    }

    public mutating func setBudgetMode(_ mode: NetworkBudgetMode, for network: String) {
        let previous = budgetMode(for: network)
        networkBudgetModes = (networkBudgetModes ?? [:]).merging([network: mode]) { _, new in new }
        if previous != .alert, mode == .alert, (networkCycles?[network] ?? BudgetCycle()).thresholds.isEmpty {
            var cycle = networkCycles?[network] ?? BudgetCycle()
            cycle.alerts = BudgetCycle.defaultAlerts
            networkCycles = (networkCycles ?? [:]).merging([network: cycle]) { _, new in new }
        }
    }

    public func cost(of network: String) -> NetworkCost { networkCost?[network].flatMap(NetworkCost.init) ?? .automatic }
    public mutating func setCost(_ cost: NetworkCost, for network: String) {
        var costs = networkCost ?? [:]
        costs[network] = cost == .automatic ? nil : cost.rawValue
        networkCost = costs.isEmpty ? nil : costs
    }
}

public enum TrafficFormat {
    public static func bytes(_ value: UInt64) -> String {
        if value < 1000 { return value.formatted() + " B" } // ByteCountFormatter spells these out as "617 bytes"
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
    }
    public static func rate(_ value: Double) -> String { guard value.isFinite, value >= 0, value < Double(UInt64.max) else { return "—" }; return String(localized: "\(bytes(UInt64(value)))/s", comment: "A data rate, e.g. 3.2 MB/s") }

    /// The preference behind Settings › General › "Rates in bits per second" and `kilobat settings units`.
    public static let bitsKey = "menu.bits"

    /// Bytes per second written in bits, as plans and speed tests are: "640 bps", "850 kbps", "3.2 Mbps", "1.25 Gbps".
    public static func bitRate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0, bytesPerSecond < Double(UInt64.max) else { return "—" }
        let bits = bytesPerSecond * 8
        // The same steps and decimals ByteCountFormatter uses for bytes: none for k, one for M, two for G.
        let number: Double, digits: Int, unit: String
        if bits < 1_000 { (number, digits, unit) = (bits, 0, "bps") }
        else if bits < 999_500 { (number, digits, unit) = (bits / 1_000, 0, "kbps") }
        else if bits < 999_950_000 { (number, digits, unit) = (bits / 1_000_000, 1, "Mbps") }
        else { (number, digits, unit) = (bits / 1_000_000_000, 2, "Gbps") }
        return number.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " " + unit
    }

    /// A live rate as the app shows it: bits when the person chose "Rates in bits per second", else bytes.
    /// The CLI keeps `rate(_:)`.
    public static func shownRate(_ bytesPerSecond: Double, defaults: UserDefaults = .standard) -> String {
        defaults.bool(forKey: bitsKey) ? bitRate(bytesPerSecond) : rate(bytesPerSecond)
    }

    /// The menu bar's short form, whole numbers only: "24 Mbps" or "3 MB/s".
    public static func compactRate(_ bytesPerSecond: Double, bits: Bool) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let units = bits ? ["bps", "kbps", "Mbps", "Gbps"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        var number = bytesPerSecond * (bits ? 8 : 1)
        var index = 0
        while number >= 999.5 && index < units.count - 1 { number /= 1000; index += 1 }
        return min(999, number).formatted(.number.precision(.fractionLength(0))) + " " + units[index]
    }
}

/// Compact usage history for scripts and agents: raw samples can run to megabytes. Totals and top apps count
/// Internet bytes; `localBytes` is the local network and AirDrop traffic left out (recorded since 1.3).
public struct UsageSummary: Codable, Equatable {
    public struct Day: Codable, Equatable { public let day: String; public let downloadBytes: UInt64; public let uploadBytes: UInt64 }
    public struct App: Codable, Equatable { public let name: String; public let bytes: UInt64 }
    public let days: Int
    public let samples: Int
    public let downloadBytes: UInt64
    public let uploadBytes: UInt64
    public let localBytes: UInt64
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
        localBytes = entries.reduce(0) { $0 + ($1.localBytes ?? 0) }
        daily = perDay.sorted { $0.key < $1.key }.map { Day(day: $0.key, downloadBytes: $0.value.0, uploadBytes: $0.value.1) }
        topApps = perApp.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(10).map { App(name: $0.key, bytes: $0.value) }
    }
}
