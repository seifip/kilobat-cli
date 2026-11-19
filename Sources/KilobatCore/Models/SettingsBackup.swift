import Foundation

// A settings file: how the person set Kilobat up, readable as JSON, to keep a copy or set up another Mac. It wraps a
// complete rules file under `rules`, unchanged, and adds the other settings under readable names. It never holds
// history, the licence, passwords, the permissions macOS gave this Mac, or anything that only describes this Mac.
// Every setting it can carry is one row of `SettingsFile.entries`; export, import, the preview and the tests read that
// table, and `SettingsFile.classified` names every other stored key, so a new setting can't be forgotten.

// MARK: Values

/// A JSON value, as a settings file holds it.
public indirect enum SettingsValue: Codable, Equatable, Sendable {
    case bool(Bool), int(Int), double(Double), string(String), array([SettingsValue]), object([String: SettingsValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([SettingsValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: SettingsValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var number: Double? {
        switch self { case .int(let value): Double(value); case .double(let value): value.isFinite ? value : nil; default: nil }
    }
    /// A whole number, or a decimal one rounded.
    public var int: Int? { number.flatMap { abs($0) < 1e15 ? Int($0.rounded()) : nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [SettingsValue]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: SettingsValue]? { if case .object(let value) = self { value } else { nil } }
    public var strings: [String]? { array?.compactMap(\.string) }

    static func of<T: Encodable>(_ value: T) throws -> SettingsValue { try JSONDecoder().decode(SettingsValue.self, from: JSONEncoder().encode(value)) }
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }
}

/// A value as `UserDefaults` keeps it.
public enum SettingsStored: Equatable, Sendable {
    case bool(Bool), int(Int), double(Double), string(String), strings([String]), data(Data), numbers([String: Double])
    /// What to hand `UserDefaults.set(_:forKey:)`.
    public var object: Any {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .strings(let value): value
        case .data(let value): value
        case .numbers(let value): value
        }
    }
}

/// One change an import makes to `UserDefaults`: a new value, or the key removed so the setting follows its default.
public enum DefaultsChange: Equatable, Sendable {
    case set(SettingsStored), remove
    public func apply(_ key: String, to defaults: UserDefaults) {
        switch self { case .set(let value): defaults.set(value.object, forKey: key); case .remove: defaults.removeObject(forKey: key) }
    }
}

// MARK: The table

/// The parts of a settings file, as the export and import sheets list them.
public enum SettingsArea: String, CaseIterable, Identifiable, Sendable {
    case rules, budgets, filter, protection, dns, notifications, menuBar, calls, awake, checks, general, provider, networks, consent, webhook
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .rules: String(localized: "Rules", comment: "Settings file area")
        case .budgets: String(localized: "Budgets and limits", comment: "Settings file area")
        case .filter: String(localized: "Filter and kill switch", comment: "Settings file area")
        case .protection: String(localized: "Protection", comment: "Settings file area")
        case .dns: String(localized: "Fastest DNS", comment: "Settings file area")
        case .notifications: String(localized: "Notifications", comment: "Settings file area")
        case .menuBar: String(localized: "Menu bar", comment: "Settings file area")
        case .calls: String(localized: "Calls and streaming", comment: "Settings file area")
        case .awake: String(localized: "Awake", comment: "Settings file area")
        case .checks: String(localized: "Checks", comment: "Settings file area")
        case .general: String(localized: "History and apps", comment: "Settings file area: history length, traffic scope, helper grouping")
        case .provider: String(localized: "Provider and plan", comment: "Settings file area")
        case .networks: String(localized: "Settings for specific networks", comment: "Settings file area")
        case .consent: String(localized: "Settings that contact other services", comment: "Settings file area")
        case .webhook: String(localized: "Phone summary address", comment: "Settings file area: the Awake webhook")
        }
    }
    /// Ticked when exporting: everything but the networks' own settings and the phone address, which may hold a secret.
    public static let exportedByDefault: Set<SettingsArea> = Set(allCases).subtracting([.networks, .webhook])
    /// Never ticked on import until the person says so: they make Kilobat contact another service.
    public static let askedOnImport: Set<SettingsArea> = [.consent, .webhook]
}

/// How a value is shown in the preview.
public enum SettingsUnit: Sendable {
    case none, seconds, minutes, hours, days, percent, megabytes, gigabytes, mbps, weekday, hour
    public func format(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        switch self {
        case .none: return number
        case .seconds: return String(localized: "\(number) s", comment: "A number of seconds, short")
        case .minutes: return String(localized: "\(number) min", comment: "A number of minutes, short")
        case .hours: return String(localized: "\(number) h", comment: "A number of hours, short")
        case .days: return String(localized: "\(number) days", comment: "A number of days")
        case .percent: return String(localized: "\(number)%", comment: "A percentage")
        case .megabytes: return "\(number) MB"
        case .gigabytes: return "\(number) GB"
        case .mbps: return "\(number) Mbps"
        case .weekday:
            let index = Int(value) - 1
            return Calendar.current.weekdaySymbols.indices.contains(index) ? Calendar.current.weekdaySymbols[index] : number
        case .hour: return String(format: "%02d:00", Int(value))
        }
    }
}

/// What a setting holds, its default, and what a file may set it to.
public enum SettingsKind: Sendable {
    case bool(Bool)
    /// A whole number. Out of `range`, a magnitude (`clamp`) is brought into range; a choice leaves the current value.
    case int(Int, ClosedRange<Int>, clamp: Bool, unit: SettingsUnit)
    case intChoice(Int, [Int], unit: SettingsUnit)
    case double(Double, ClosedRange<Double>, unit: SettingsUnit)
    /// A word from a set: anything else leaves the current value. `name` shows it.
    case choice(String, valid: @Sendable (String) -> Bool, name: @Sendable (String) -> String)
    /// Text the person typed. `secret` is never shown in the preview.
    case text(String, maxLength: Int, secret: Bool, valid: @Sendable (String) -> Bool)
    /// A list merged by adding what's missing. `normalize` gives nil for an entry that makes the file invalid, and
    /// `reason` says why.
    case list(maxCount: Int, normalize: @Sendable (String) -> String?, reason: @Sendable (String) -> String)

    public var defaultValue: SettingsValue {
        switch self {
        case .bool(let value): .bool(value)
        case .int(let value, _, _, _), .intChoice(let value, _, _): .int(value)
        case .double(let value, _, _): .double(value)
        case .choice(let value, _, _), .text(let value, _, _, _): .string(value)
        case .list: .array([])
        }
    }
}

/// One setting a settings file can carry.
public struct SettingsFileEntry: Sendable {
    public enum Storage: Hashable, Sendable {
        /// A `UserDefaults` key in the app's domain.
        case defaults(String)
        /// A stored property of `SavedPreferences`.
        case preferences(String)
    }
    /// Where it sits in the file's `settings` object: "notifications.outages".
    public let path: String
    /// For the menu bar's items, which travel as one list at `path`: this entry's name in it.
    public let member: String?
    public let area: SettingsArea
    public let title: String
    public let storage: Storage
    public let kind: SettingsKind
    /// Whether the running app notices the change at once; otherwise it waits for Kilobat to be reopened.
    public let live: Bool
    /// Whether it only acts with Kilobat Pro (it is stored either way).
    public let pro: Bool
    /// Its name in `kilobat settings`, if it has one.
    public let cli: String?
    let read: (@Sendable (SavedPreferences) -> SettingsValue)?
    let write: (@Sendable (inout SavedPreferences, SettingsValue) -> Void)?
}

/// Where every stored setting belongs: in a settings file, or never.
public enum SettingsClass: String, Sendable {
    /// Carried by `SettingsFile.entries` or a part handled beside them (app limits, provider).
    case export
    /// In the embedded rules file.
    case rules
    /// Only with "Settings for specific networks".
    case perNetwork
    /// Written for the preview to mention, never applied.
    case informational
    case never
}

public enum SettingsFile {
    private typealias Entry = SettingsFileEntry

    // Constructors for the table.
    private static func defaults(_ path: String, _ area: SettingsArea, _ title: String, _ key: String, _ kind: SettingsKind,
                                 live: Bool = false, pro: Bool = false, cli: String? = nil, member: String? = nil) -> Entry {
        Entry(path: path, member: member, area: area, title: title, storage: .defaults(key), kind: kind, live: live, pro: pro, cli: cli, read: nil, write: nil)
    }
    private static func flag(_ path: String, _ area: SettingsArea, _ title: String, _ key: String, _ value: Bool, live: Bool = false, pro: Bool = false, cli: String? = nil) -> Entry {
        defaults(path, area, title, key, .bool(value), live: live, pro: pro, cli: cli)
    }
    /// A `SavedPreferences` Bool? whose nil means `value`; nil is written back when the file gives the default.
    private static func optionalFlag(_ path: String, _ area: SettingsArea, _ title: String, _ name: String,
                                     _ keyPath: WritableKeyPath<SavedPreferences, Bool?> & Sendable, _ value: Bool, pro: Bool = false, cli: String? = nil) -> Entry {
        Entry(path: path, member: nil, area: area, title: title, storage: .preferences(name), kind: .bool(value), live: true, pro: pro, cli: cli,
              read: { .bool($0[keyPath: keyPath] ?? value) },
              write: { preferences, new in let on = new.bool ?? value; preferences[keyPath: keyPath] = on == value ? nil : on })
    }
    private static func optionalChoice(_ path: String, _ area: SettingsArea, _ title: String, _ name: String,
                                       _ keyPath: WritableKeyPath<SavedPreferences, String?> & Sendable, _ value: String, choices: [String],
                                       title display: @escaping @Sendable (String) -> String = { $0 }, pro: Bool = false, cli: String? = nil) -> Entry {
        Entry(path: path, member: nil, area: area, title: title, storage: .preferences(name), kind: .choice(value, valid: { choices.contains($0) }, name: display),
              live: true, pro: pro, cli: cli,
              read: { .string($0[keyPath: keyPath] ?? value) },
              write: { preferences, new in let text = new.string ?? value; preferences[keyPath: keyPath] = text == value ? nil : text })
    }
    private static func onOff(_ on: Bool) -> String { on ? String(localized: "On", comment: "A setting's value") : String(localized: "Off", comment: "A setting's value") }

    static let menuItems: [(name: String, title: String)] = [
        ("download", String(localized: "Download speed")), ("upload", String(localized: "Upload speed")), ("latency", String(localized: "Internet latency")),
        ("speed", String(localized: "Last speed test")), ("vpn", String(localized: "VPN")), ("budget", String(localized: "Data left")), ("game", String(localized: "Game ping")),
    ]
    static let corners = ["topTrailing", "topLeading", "bottomTrailing", "bottomLeading"]

    /// Every setting a settings file can carry, in the order the preview lists them.
    public static let entries: [SettingsFileEntry] = {
        var list: [Entry] = []
        // Filter and kill switch.
        list.append(Entry(path: "budget.switchToEssentialsOnMetered", member: nil, area: .filter, title: String(localized: "Switch to Essentials on metered networks"),
                          storage: .preferences("autoHotspot"), kind: .bool(true), live: true, pro: true, cli: "auto-travel",
                          read: { .bool($0.autoHotspot) }, write: { $0.autoHotspot = $1.bool ?? true }))
        list.append(optionalFlag("updaters.pauseUpdaters", .filter, String(localized: "Pause updaters on metered networks"), "pauseUpdaters", \.pauseUpdaters, true, pro: true, cli: "pause-updaters"))
        list.append(optionalFlag("updaters.pauseCloudSync", .filter, String(localized: "Pause cloud sync on metered networks"), "pauseCloudSync", \.pauseCloudSync, true, pro: true, cli: "pause-cloud-sync"))
        list.append(optionalFlag("killSwitch.enabled", .filter, String(localized: "VPN kill switch"), "killSwitch", \.killSwitch, false, pro: true, cli: "kill-switch"))
        list.append(optionalFlag("killSwitch.allowLocalNetwork", .filter, String(localized: "Kill switch lets the local network through", comment: "Settings file preview: the kill switch's LAN option"),
                                 "killSwitchLAN", \.killSwitchLAN, true, cli: "kill-switch-lan"))
        // Protection.
        list.append(optionalFlag("protection.threats", .protection, String(localized: "Block threats"), "protectThreats", \.protectThreats, true, pro: true))
        list.append(optionalFlag("protection.trackers", .protection, String(localized: "Block trackers in apps"), "protectTrackers", \.protectTrackers, false))
        list.append(optionalChoice("protection.trackerList", .protection, String(localized: "Tracker list", comment: "Settings file preview"), "trackerList", \.trackerList,
                                   ProtectionLists.defaultTracker, choices: ProtectionLists.trackers.map(\.id), title: { ProtectionLists.tracker($0).name }))
        list.append(optionalFlag("protection.agentGuard", .protection, String(localized: "Agent guard"), "agentGuard", \.agentGuard, false, pro: true))
        list.append(Entry(path: "protection.agentGuardUploadMB", member: nil, area: .protection, title: String(localized: "Large upload limit"), storage: .preferences("agentGuardUploadMB"),
                          kind: .int(10, 1...10_000, clamp: true, unit: .megabytes), live: true, pro: false, cli: nil,
                          read: { .int($0.agentGuardUploadMB ?? 10) },
                          write: { preferences, new in let mb = new.int ?? 10; preferences.agentGuardUploadMB = mb == 10 ? nil : mb }))
        // Fastest DNS.
        list.append(optionalFlag("dns.fastest", .dns, String(localized: "Use the fastest DNS on every network", comment: "Settings: fastest DNS everywhere"), "fastestDNS", \.fastestDNS, false, pro: true))
        let presets = DNSResolverChoice.presets.map(\.id)
        list.append(Entry(path: "dns.excluded", member: nil, area: .dns, title: String(localized: "Fastest DNS leaves out", comment: "Settings file preview: a resolver never timed follows"),
                          storage: .preferences("dnsExcluded"),
                          kind: .list(maxCount: presets.count, normalize: { presets.contains($0.lowercased()) ? $0.lowercased() : nil },
                                      reason: { String(localized: "“\($0)” isn’t a resolver Kilobat offers.", comment: "Settings file error") }),
                          live: true, pro: false, cli: nil,
                          read: { .array(($0.dnsExcluded ?? []).map(SettingsValue.string)) },
                          write: { preferences, new in let ids = new.strings ?? []; preferences.dnsExcluded = ids.isEmpty ? nil : ids.sorted() }))
        list.append(Entry(path: "dns.extra", member: nil, area: .dns, title: String(localized: "Fastest DNS also times", comment: "Settings file preview: a resolver the person added follows"),
                          storage: .preferences("dnsExtra"),
                          kind: .list(maxCount: 20, normalize: { let address = $0.trimmingCharacters(in: .whitespaces); return DNSAddress.valid(address) ? address : nil },
                                      reason: { String(localized: "“\($0)” isn’t an IP address.", comment: "Settings file error") }),
                          live: true, pro: false, cli: nil,
                          read: { .array(($0.dnsExtra ?? []).map(SettingsValue.string)) },
                          write: { preferences, new in let list = new.strings ?? []; preferences.dnsExtra = list.isEmpty ? nil : list }))
        list.append(Entry(path: "dns.fallback", member: nil, area: .dns, title: String(localized: "Fallback DNS"), storage: .preferences("dnsFallback"),
                          kind: .choice("none", valid: { $0 == "none" || DNSResolverChoice.from(id: $0).map { !$0.isNetwork } == true },
                                        name: { $0 == "none" ? String(localized: "None", comment: "No fallback DNS") : DNSResolverChoice.from(id: $0)?.name ?? $0 }),
                          live: true, pro: false, cli: nil,
                          read: { .string($0.dnsFallbackChoice?.id ?? "none") },
                          write: { preferences, new in let id = new.string ?? "none"; preferences.dnsFallback = id == "none" ? nil : id }))
        // Notifications.
        let notify: SettingsArea = .notifications
        list.append(flag("notifications.outages", notify, String(localized: "Alert me about connection problems"), "networkAlerts", true, cli: "alerts"))
        list.append(flag("notifications.routerSlowdowns", notify, String(localized: "Tell me when the router slows down"), RouterWatch.alertsKey, true, live: true, pro: true, cli: "router-alerts"))
        list.append(flag("notifications.farWiFiNode", notify, String(localized: "Tell me when the Mac stays on a far Wi-Fi node"), NodeWatch.alertsKey, true, live: true, cli: "node-alerts"))
        list.append(flag("notifications.fasterDNS", notify, String(localized: "Tell me when a faster DNS is found"), FastestDNSWatch.offerAlertsKey, true, live: true))
        list.append(flag("notifications.serviceDown", notify, String(localized: "Tell me when a service I use is down"), "serviceAlerts", true))
        list.append(flag("notifications.serviceBlocked", notify, String(localized: "Tell me when a service looks blocked on this network"), "blockAlerts", true, cli: "block-alerts"))
        list.append(flag("notifications.bluetoothAudio", notify, String(localized: "Tell me when Wi-Fi may make Bluetooth audio crackle"), BluetoothAudioWatch.alertsKey, true, live: true, cli: "bluetooth-audio-alerts"))
        list.append(flag("notifications.outageCredit", notify, String(localized: "Tell me when an outage may qualify for a credit"), CreditAlert.enabledKey, true, pro: true))
        list.append(flag("notifications.signInPage", notify, String(localized: "Warn before Wi-Fi sign-ins run out"), "portalWarnings", true, pro: true))
        list.append(flag("notifications.callReports", notify, String(localized: "Report after each call"), "callReports", true))
        list.append(flag("notifications.remoteSessionReports", notify, String(localized: "Report after remote sessions"), "remoteSessionReports", true))
        list.append(flag("notifications.cloudGamingReports", notify, String(localized: "Cloud gaming reports"), "cloudGamingReports", true))
        list.append(flag("notifications.remoteSessionNotices", notify, String(localized: "Notify after a remote session that stuttered", comment: "Settings file preview"), "remoteSessionNotices", true))
        list.append(flag("notifications.cloudGamingNotices", notify, String(localized: "Notify after a session that stuttered"), "cloudGamingNotices", true))
        list.append(flag("notifications.cloudGamingInterruptions", notify, String(localized: "Alert when something gets in the way"), "cloudGamingAlerts", true))
        list.append(flag("notifications.streamNotices", notify, String(localized: "Notify after a stream that dropped frames"), "streamNotices", true))
        list.append(flag("notifications.awakeRuns", notify, String(localized: "Tell me when a run finishes"), "awake.notify", true))
        list.append(optionalFlag("notifications.unusualUploads", notify, String(localized: "Unusual uploads"), "uploadAlerts", \.uploadAlerts, true))
        list.append(flag("notifications.weeklyDigest.enabled", notify, String(localized: "Weekly digest", comment: "Settings file preview"), DigestSchedule.enabledKey, true, cli: "digest"))
        list.append(defaults("notifications.weeklyDigest.weekday", notify, String(localized: "Weekly digest day", comment: "Settings file preview"), DigestSchedule.weekdayKey,
                             .intChoice(2, Array(1...7), unit: .weekday)))
        list.append(defaults("notifications.weeklyDigest.hour", notify, String(localized: "Weekly digest time", comment: "Settings file preview"), DigestSchedule.hourKey,
                             .intChoice(9, Array(0...23), unit: .hour)))
        // Menu bar.
        list.append(flag("menuBar.statusItem", .menuBar, String(localized: "Kilobat status item"), "mainMenuVisible", true, live: true))
        list.append(flag("menuBar.wifiItem", .menuBar, String(localized: "Wi-Fi & Bluetooth"), "wifiMenuVisible", true, live: true))
        list.append(flag("menuBar.awakeItem", .menuBar, String(localized: "Awake menu bar item"), "awakeMenuVisible", false, live: true))
        list.append(flag("menuBar.keepInDock", .menuBar, String(localized: "Keep in the Dock"), "dockIconAlways", false, live: true))
        for item in menuItems {
            list.append(defaults("menuBar.show", .menuBar, String(localized: "Menu bar: \(item.title)", comment: "Settings file preview: an item the menu bar shows"),
                                 "menu." + item.name, .bool(false), live: true, cli: "menu-bar", member: item.name))
        }
        list.append(flag("menuBar.ratesInBits", .menuBar, String(localized: "Rates in bits per second"), TrafficFormat.bitsKey, false, live: true, cli: "units"))
        // Calls, streaming and gaming.
        list.append(flag("calls.callMode", .calls, String(localized: "Call mode"), "callMode", false, pro: true))
        list.append(flag("calls.pauseAirDrop", .calls, String(localized: "Call mode pauses AirDrop", comment: "Settings file preview"), "callModeAirDrop", false))
        list.append(defaults("calls.skipApps", .calls, String(localized: "Call mode leaves alone", comment: "Settings file preview: an app Call mode never holds follows"), "callModeSkipped",
                             .list(maxCount: 500, normalize: { let name = $0.trimmingCharacters(in: .whitespacesAndNewlines); return name.isEmpty || name.count > 200 ? nil : name },
                                   reason: { String(localized: "“\($0)” isn’t an app name.", comment: "Settings file error") })))
        list.append(flag("calls.meetingCheck", .calls, String(localized: "Check before meetings"), "meetingCheck", false))
        list.append(flag("calls.holdAppsWhileStreaming", .calls, String(localized: "Call mode for streams"), "streamCallMode", false))
        list.append(flag("streaming.obs", .calls, String(localized: "Stream reports from OBS"), "obs.enabled", false))
        list.append(defaults("streaming.obsPort", .calls, String(localized: "OBS WebSocket"), "obs.port", .int(Int(OBSProtocol.defaultPort), 1...65_535, clamp: false, unit: .none)))
        list.append(flag("streaming.overlay", .calls, String(localized: "Streaming overlay"), "overlay.enabled", false))
        list.append(defaults("streaming.overlayTarget", .calls, String(localized: "Overlay shows", comment: "Settings file preview: the streaming overlay's target"), "overlay.target",
                             .choice("internet", valid: { ["internet", "router", CurrentMatch.overlayTarget].contains($0) || GameServerTable.bundled.target($0) != nil }, name: { $0 })))
        list.append(flag("gaming.pingOverGame", .calls, String(localized: "Ping over your game"), "gamePill.enabled", false))
        list.append(defaults("gaming.corner", .calls, String(localized: "Game ping corner", comment: "Settings file preview"), "gamePill.corner",
                             .choice("topTrailing", valid: { corners.contains($0) }, name: { $0 })))
        // Awake.
        list.append(flag("awake.forAgents", .awake, String(localized: "Keep awake while AI agents work", comment: "Settings file preview"), "awake.agents", true))
        list.append(flag("awake.whileAgentWaits", .awake, String(localized: "Keep awake while an agent waits for you", comment: "Settings file preview"), "awake.waiting", false))
        list.append(flag("awake.keepScreenOn", .awake, String(localized: "Keep the screen on", comment: "Settings file preview"), "awake.display", false, cli: "keep-screen-on"))
        list.append(flag("awake.whilePluggedIn", .awake, String(localized: "Stay awake while plugged in", comment: "Settings file preview"), "awake.power", false, cli: "awake-on-power"))
        list.append(defaults("awake.quietMinutes", .awake, String(localized: "Quiet for"), "awake.quietMinutes", .int(3, 1...60, clamp: true, unit: .minutes)))
        list.append(defaults("awake.lidBatteryFloor", .awake, String(localized: "Let it sleep at"), "awake.lidFloor", .int(20, 5...100, clamp: true, unit: .percent)))
        list.append(defaults("awake.lidMaxHours", .awake, String(localized: "Longest with the lid closed"), "awake.lidHours", .int(4, 1...24, clamp: true, unit: .hours)))
        list.append(flag("awake.lidOnlyOnPower", .awake, String(localized: "Only on the power adapter"), "awake.lidAC", false))
        list.append(defaults("awakeWebhook", .webhook, String(localized: "Send summaries to your phone"), "awake.webhook",
                             .text("", maxLength: 2_000, secret: true, valid: { $0.isEmpty || $0.hasPrefix("https://") || $0.hasPrefix("ntfy+https://") })))
        // Checks.
        list.append(defaults("checks.interval", .checks, String(localized: "Check interval"), "diagnosticInterval", .int(12, 12...3_600, clamp: true, unit: .seconds), cli: "check-interval"))
        list.append(flag("checks.outageTrace", .checks, String(localized: "Trace the route when an outage starts"), "automaticOutageTrace", true, cli: "outage-trace"))
        list.append(defaults("checks.speedStreams", .checks, String(localized: "Speed test connections", comment: "Settings file preview: one or several at once"), "speedStreams",
                             .intChoice(1, [1, SpeedTest.parallelStreams], unit: .none), cli: "speed-streams"))
        list.append(defaults("checks.legacyPlanMbps", .checks, String(localized: "Plan speed for every network", comment: "Settings file preview: the older single plan speed"), PlanSpeeds.legacyKey,
                             .double(0, 0...100_000, unit: .mbps), live: true, cli: "plan-mbps"))
        list.append(optionalChoice("checks.blockCheckResolver", .checks, String(localized: "Resolver for block checks"), "blockCheckResolver", \.blockCheckResolver,
                                   TrustedResolver.cloudflare.rawValue, choices: TrustedResolver.allCases.map(\.rawValue),
                                   title: { TrustedResolver(rawValue: $0)?.name ?? $0 }, cli: "block-check-resolver"))
        // Settings that contact other services: exported, but never turned on by an import unless the person ticks them.
        list.append(defaults("consent.scheduledSpeedTests.everyHours", .consent, String(localized: "Scheduled speed tests"), "speedScheduleHours",
                             .int(0, 0...168, clamp: true, unit: .hours), cli: "speed-schedule"))
        list.append(flag("consent.planCheck", .consent, String(localized: "Plan check"), PlanCheck.enabledKey, false, pro: true, cli: "plan-check"))
        list.append(flag("consent.publicIPLookup", .consent, String(localized: "Look up public IP"), "publicIPLookup", false, cli: "public-ip"))
        list.append(flag("consent.chinaSignInCheck", .consent, String(localized: "Wi-Fi sign-in check for China"), "network.chinaPortalFallback", false, live: true))
        // History and apps.
        list.append(flag("overview.showWeeklyEcho", .general, String(localized: "Show Weekly Echo on Overview"), WeeklyDigest.showOnOverviewKey, true, live: true))
        list.append(Entry(path: "history.keepDays", member: nil, area: .general, title: String(localized: "Keep usage history for"), storage: .preferences("historyDays"),
                          kind: .intChoice(365, [30, 90, 365], unit: .days), live: true, pro: false, cli: nil,
                          read: { .int($0.historyDays ?? 365) }, write: { preferences, new in let days = new.int ?? 365; preferences.historyDays = days == 365 ? nil : days }))
        list.append(optionalChoice("trafficScope", .general, String(localized: "Process traffic scope", comment: "Settings file preview"), "trafficScope", \.trafficScope,
                                   "external", choices: ["external", "wifi", "wired"], pro: true, cli: "scope"))
        list.append(flag("appearance.groupHelpers", .general, String(localized: "Group helper processes under their app", comment: "Settings file preview"), "apps.groupHelpers", true, live: true, cli: "group-helpers"))
        return list
    }()

    public static func entry(_ path: String, member: String? = nil) -> SettingsFileEntry? { entries.first { $0.path == path && $0.member == member } }

    /// Paths beside the table's: app limits and the provider are read in code, the blocklist's name is only mentioned.
    static let compositePaths: Set<String> = ["appLimits", "provider", "protection.blocklistName"]
    static let providerFields = ["id", "country", "otherProvider", "monthlyPrice", "uploadMbps", "minimumMbps", "planWording"]

    /// `UserDefaults` keys outside the table, by class. Every key Kilobat's sources store must be in the table or here;
    /// `SettingsBackupTests` reads the sources and fails on one that isn't.
    public static let otherDefaults: [String: SettingsClass] = {
        var map: [String: SettingsClass] = [CreditSettings.key: .export, PlanSpeeds.key: .perNetwork, "uploadFastNetworks": .perNetwork, "share.places": .perNetwork]
        let never = [
            // Organization identity and managed policy must never travel in personal backups.
            "TeamToken", "TeamDeviceLabel", "TeamPolicyVersion", "TeamsBlockedBundleIDs", "teams.appliedPolicy", "teams.selectedPreset",
            // What a window last showed.
            "apps.sort", "bandwidth.range", "connections.map", "appPanel.firewallOpen", "games.game", "games.recent", "history.period", "history.network", "history.from", "history.to",
            "trace.method", "trace.maxHops", "trace.packetSize",
            // Keyed by MAC address or device, or a cache of this Mac's networks.
            "deviceNames", "destinationFavorites", "smartHomeNetworks", "bluetoothKinds", "personalHotspotNames",
            // Running with the lid shut needs the power helper approved on this Mac.
            "awake.lidClosed", "awake.lidForAwake",
            // No Settings row.
            "localReachOnJoin",
            // State and identity.
            "onboarding.done", "loginItemDefaulted", "hints.firstSeen", "hints.lastShown", "hints.menuOpens", "hints.seen", "blockAlertsSent", "serviceAlertsSent",
            CreditAlert.notifiedKey, CreditAlert.lastKey, "digest.last", "dns.offerDismissed", "bluetoothAudioLastAlert", "share.week.dismissed",
            "share.year.invited", "steam.warned", "killSwitch.armedBoot", "fixit.portalDNSHold", "radioCheck.bluetoothOff", "awake.powerOff", "awake.askedAlerts",
            // Product analytics: consent is a choice made on the Mac that sends it.
            "measurement.enabled", "measurement.token", "measurement.id", "measurement.primary", "measurement.secondary", "measurement.reason", "measurement.reasonAsked",
            "measurement.source", "measurement.campaign", "measurement.activated", "measurement.activationEventID", "measurement.firstValue", "measurement.invitationSeen",
            "measurement.useCaseAsked", "measurement.delete", "measurement.withdrawToken",
        ]
        for key in never { map[key] = .never }
        return map
    }()
    /// Names the source scan finds that aren't Kilobat's settings: Core Animation and Core Image keys, Apple's own
    /// AirDrop domain, and the Lite app's menu switch.
    public static let notADefault: Set<String> = ["breathe", "DiscoverableMode", "effect", "inputMessage", "inputCorrectionLevel", "drawsBackground", "other", "menuVisible"]

    /// `SavedPreferences` properties outside the table, by class.
    public static let otherPreferences: [String: SettingsClass] = [
        "rules": .rules, "connectionRules": .rules, "profileDefinitions": .rules, "profileSchedules": .rules, "blockedHosts": .rules, "allowedSites": .rules,
        "domainExceptions": .rules, "askNewApps": .rules, "defaultAllow": .rules, "allowApple": .rules, "alertNewApps": .rules, "askDestinations": .rules, "developerNames": .rules,
        // Subscriptions download from addresses the person chose, so a settings file never turns them on; the log is per session.
        "blocklistSubscriptions": .never, "connectionLog": .never, "connectionLogBrowsers": .never,
        "networkProfiles": .perNetwork, "limitGB": .perNetwork, "budgetCycle": .perNetwork, "networkLimits": .perNetwork, "networkCycles": .perNetwork,
        "networkBudgetModes": .perNetwork, "networkCost": .perNetwork, "networkFastestDNS": .perNetwork,
        "quotas": .export, "blocklistName": .informational,
        "temporaryRules": .never, "profile": .never, "customProfile": .never, "autoProfileFrom": .never, "profileScheduleState": .never, "dataPacks": .never,
        "focusPausesUpdaters": .never, "killSwitchAllowedUntil": .never, "blockedDomains": .never, "destinationHistory": .never, "schema": .never,
    ]

    /// The class of a stored key, or nil when nobody classified it.
    public static func classified(_ storage: SettingsFileEntry.Storage) -> SettingsClass? {
        if entries.contains(where: { $0.storage == storage }) { return .export }
        switch storage {
        case .defaults(let key): return otherDefaults[key]
        case .preferences(let name): return otherPreferences[name]
        }
    }
    /// Whether a name in a hand-written file is a key that never travels: it is then ignored and listed.
    static func isNever(_ path: String, last: String) -> Bool {
        for name in [path, last] {
            if otherDefaults[name] == .never || otherPreferences[name] == .never || name.hasPrefix("measurement.") { return true }
        }
        return path.hasPrefix("measurement.")
    }
    /// Every path the table and the parts beside it know, and the objects that hold them.
    static let knownPaths: Set<String> = Set(entries.map(\.path)).union(compositePaths)
    static let containerPaths: Set<String> = {
        var set = Set<String>()
        for path in knownPaths {
            let parts = path.split(separator: ".")
            for count in stride(from: 1, to: parts.count, by: 1) { set.insert(parts.prefix(count).joined(separator: ".")) }
        }
        return set
    }()
}

// MARK: The file

/// One network's own settings, keyed by the network's key and named as the person sees it.
public struct SettingsNetwork: Codable, Equatable, Sendable {
    public struct Budget: Codable, Equatable, Sendable {
        public var limitGB: Double?
        /// "off", "alert" or "block".
        public var mode: String?
        public var cycle: BudgetCycle?
        public init(limitGB: Double? = nil, mode: String? = nil, cycle: BudgetCycle? = nil) { self.limitGB = limitGB; self.mode = mode; self.cycle = cycle }
    }
    public var key: String
    public var name: String?
    public var budget: Budget?
    /// "metered", "unmetered" or "automatic".
    public var dataCost: String?
    /// A profile as the embedded rules file names it.
    public var profile: String?
    public var fastestDNS: Bool?
    public var planMbps: Double?
    public var sendLaterFastEnough: Bool?
    /// The name typed on the This place card.
    public var placeName: String?
    /// The provider set up under Provider and plan serves this network.
    public var providerHere: Bool?
    public var appLimits: [SettingsAppLimit]?
    public init(key: String, name: String? = nil) { self.key = key; self.name = name }
    static let fields: Set<String> = ["key", "name", "budget", "dataCost", "profile", "fastestDNS", "planMbps", "sendLaterFastEnough", "placeName", "providerHere", "appLimits"]
}

/// An app limit, without the id this Mac gave it.
public struct SettingsAppLimit: Codable, Equatable, Sendable {
    public var name: String
    public var apps: [String]
    public var bytes: UInt64
    public var uploadOnly: Bool?
    /// "off", "alert" or "block"; nil blocks, as limits always did.
    public var mode: String?
    public var cycle: BudgetCycle?
    public init(_ limit: AppLimit) {
        name = limit.name; apps = limit.apps; bytes = limit.bytes; uploadOnly = limit.uploadOnly ? true : nil; mode = limit.mode?.rawValue; cycle = limit.cycle
    }
    static let fields: Set<String> = ["name", "apps", "bytes", "uploadOnly", "mode", "cycle"]
}

public struct SettingsBackup: Equatable, Sendable {
    public static let formatName = "kilobat-settings"
    public static let currentVersion = 1
    /// The same limit as a rules file: the blocklist, the only large part, never travels.
    public static let maxBytes = RuleBackup.maxBytes

    public var version = SettingsBackup.currentVersion
    public var exported: Date?
    /// "Kilobat 1.42.0".
    public var writtenBy: String?
    /// The complete rules file, as `RuleBackup` writes and reads it.
    public var rules: RuleBackup?
    /// Readable names to values; see `SettingsFile.entries`.
    public var settings: [String: SettingsValue] = [:]
    public var networks: [SettingsNetwork]?
    /// The file was a rules file, not a settings file.
    public var rulesOnly = false
    /// What reading found and won't apply: paths this version doesn't know, and keys that never travel.
    public var unknown: [String] = []
    public var notImported: [String] = []

    public init() {}

    /// A value in `settings` at a dotted path.
    public func value(at path: String) -> SettingsValue? {
        var current: SettingsValue = .object(settings)
        for part in path.split(separator: ".") {
            guard let next = current.object?[String(part)] else { return nil }
            current = next
        }
        return current
    }
    mutating func set(_ value: SettingsValue, at path: String) {
        func put(_ parts: ArraySlice<Substring>, into object: [String: SettingsValue]) -> [String: SettingsValue] {
            var object = object
            guard let first = parts.first else { return object }
            let key = String(first)
            if parts.count == 1 { object[key] = value } else { object[key] = .object(put(parts.dropFirst(), into: object[key]?.object ?? [:])) }
            return object
        }
        settings = put(path.split(separator: ".")[...], into: settings)
    }

    /// The parts this file holds, in the order the sheets list them.
    public var areas: [SettingsArea] {
        var held = Set<SettingsArea>()
        if rules != nil { held.insert(.rules) }
        for entry in SettingsFile.entries where value(at: entry.path) != nil { held.insert(entry.area) }
        if value(at: "appLimits")?.array?.isEmpty == false { held.insert(.budgets) }
        if value(at: "provider") != nil { held.insert(.provider) }
        if value(at: "protection.blocklistName") != nil { held.insert(.protection) }
        if networks?.isEmpty == false { held.insert(.networks) }
        return SettingsArea.allCases.filter(held.contains)
    }

    // MARK: Export

    /// The settings in `preferences` and `defaults` (the app's `UserDefaults` domain), for the ticked `areas`.
    /// `knownNetworks` names network keys; `currentNetwork` is the one whose budget lives in `limitGB`.
    public init(preferences: SavedPreferences, defaults: [String: Any], areas: Set<SettingsArea> = SettingsArea.exportedByDefault,
                knownNetworks: [String: String] = [:], currentNetwork: String? = nil, now: Date = Date(), writtenBy: String? = nil) {
        exported = now; self.writtenBy = writtenBy
        if areas.contains(.rules) { rules = RuleBackup(preferences, now: now) }
        let reader = SettingsReader(preferences: preferences, defaults: defaults)
        var shown: [String: [SettingsValue]] = [:]
        for entry in SettingsFile.entries where areas.contains(entry.area) {
            let value = reader.current(entry)
            if let member = entry.member {
                if shown[entry.path] == nil { shown[entry.path] = [] }
                if value.bool == true { shown[entry.path]?.append(.string(member)) }
            } else { set(value, at: entry.path) }
        }
        for (path, members) in shown { set(.array(members), at: path) }
        if areas.contains(.budgets), let limits = try? SettingsValue.of((preferences.quotas ?? []).filter { $0.network == nil }.map(SettingsAppLimit.init)), limits.array?.isEmpty == false {
            set(limits, at: "appLimits")
        }
        if areas.contains(.protection), let name = preferences.blocklistName, !name.isEmpty { set(.string(name), at: "protection.blocklistName") }
        if areas.contains(.provider), let credit = reader.credit {
            var object: [String: SettingsValue] = [:]
            if let value = credit.provider { object["id"] = .string(value) }
            if let value = credit.country { object["country"] = .string(value) }
            if let value = credit.otherProvider { object["otherProvider"] = .string(value) }
            if let value = credit.monthlyPrice { object["monthlyPrice"] = .double(value) }
            if let value = credit.uploadMbps { object["uploadMbps"] = .double(value) }
            if let value = credit.minimumMbps { object["minimumMbps"] = .double(value) }
            if let value = credit.planWording { object["planWording"] = .string(value) }
            if !object.isEmpty { set(.object(object), at: "provider") }
        }
        if areas.contains(.networks) {
            let list = reader.networks(knownNetworks: knownNetworks, current: currentNetwork)
            networks = list.isEmpty ? nil : list
        }
    }

    public func data() throws -> Data {
        var root: [String: SettingsValue] = ["format": .string(Self.formatName), "version": .int(version)]
        if let exported { root["exported"] = .string(ISO8601DateFormatter().string(from: exported)) }
        if let writtenBy { root["writtenBy"] = .string(writtenBy) }
        if let rules { root["rules"] = try JSONDecoder().decode(SettingsValue.self, from: rules.data()) }
        if !settings.isEmpty { root["settings"] = .object(settings) }
        if let networks { root["networks"] = try SettingsValue.of(networks) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(SettingsValue.object(root))
    }

    /// "Kilobat settings 2026-11-11.json".
    public static func fileName(now: Date = Date(), calendar: Calendar = .current) -> String {
        "Kilobat settings \(DestinationHistory.day(now, calendar: calendar)).json"
    }

    // MARK: Import

    /// Reads and checks a settings file, or a rules file, naming the first thing wrong with it.
    public static func parse(_ data: Data) throws -> SettingsBackup {
        guard data.count <= maxBytes else { throw SettingsBackupError.tooLarge }
        guard let root = (try? JSONDecoder().decode(SettingsValue.self, from: data))?.object, let format = root["format"]?.string else { throw SettingsBackupError.notSettings }
        if format == RuleBackup.formatName {
            do {
                var backup = SettingsBackup()
                backup.rules = try RuleBackup.parse(data); backup.exported = backup.rules?.exported; backup.rulesOnly = true
                return backup
            } catch let error as RuleBackupError { throw SettingsBackupError.rules(error) }
        }
        guard format == formatName else { throw SettingsBackupError.notSettings }
        guard let version = root["version"]?.int, root["version"]?.number == Double(version) else { throw SettingsBackupError.unreadable }
        guard version <= currentVersion else { throw SettingsBackupError.newerVersion }
        guard version >= 1 else { throw SettingsBackupError.unreadable }
        var backup = SettingsBackup()
        backup.version = version
        if let text = root["exported"]?.string { backup.exported = ISO8601DateFormatter().date(from: text) }
        backup.writtenBy = root["writtenBy"]?.string
        backup.unknown = root.keys.filter { !["format", "version", "exported", "writtenBy", "rules", "settings", "networks"].contains($0) }.sorted()
        if let rules = root["rules"] {
            guard rules.object != nil else { throw SettingsBackupError.unreadable }
            do { backup.rules = try RuleBackup.parse(JSONEncoder().encode(rules)) }
            catch let error as RuleBackupError { throw SettingsBackupError.rules(error) }
        }
        if let settings = root["settings"] {
            guard let object = settings.object else { throw SettingsBackupError.unreadable }
            backup.settings = object
            try backup.check()
        }
        if let networks = root["networks"] {
            guard let list = networks.array else { throw SettingsBackupError.unreadable }
            guard list.count <= 100 else { throw SettingsBackupError.invalid(String(localized: "The file has too many networks.", comment: "Settings file error")) }
            var keys = Set<String>()
            var parsed: [SettingsNetwork] = []
            for (index, item) in list.enumerated() {
                guard let object = item.object else { throw SettingsBackupError.unreadable }
                for key in object.keys.sorted() where !SettingsNetwork.fields.contains(key) { backup.unknown.append("networks[\(index)].\(key)") }
                guard let network = try? item.decoded(SettingsNetwork.self) else {
                    throw SettingsBackupError.invalid(String(localized: "A network’s settings can’t be read.", comment: "Settings file error"))
                }
                let key = network.key.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, key.count <= 200, key != "unknown" else { throw SettingsBackupError.invalid(String(localized: "A network has no usable key.", comment: "Settings file error")) }
                guard keys.insert(key).inserted else { throw SettingsBackupError.invalid(String(localized: "Network “\(network.name ?? key)” appears twice.", comment: "Settings file error")) }
                if let name = network.name, name.count > 200 { throw SettingsBackupError.invalid(String(localized: "A network’s name is too long.", comment: "Settings file error")) }
                if let name = network.placeName, name.count > 200 { throw SettingsBackupError.invalid(String(localized: "A place name is too long.", comment: "Settings file error")) }
                if let limit = network.budget?.limitGB, !(limit.isFinite && limit >= 0) {
                    throw SettingsBackupError.invalid(String(localized: "The budget for \(network.name ?? key) isn’t a size.", comment: "Settings file error"))
                }
                if let plan = network.planMbps, !(plan.isFinite && plan >= 0) {
                    throw SettingsBackupError.invalid(String(localized: "The plan speed for \(network.name ?? key) isn’t a speed.", comment: "Settings file error"))
                }
                parsed.append(network)
            }
            backup.networks = parsed.isEmpty ? nil : parsed
        }
        // App limits, here and per network, are checked together: one name may limit once per network.
        var limitKeys = Set<String>(), count = 0
        for (network, limits) in [(String?.none, backup.appLimits)] + (backup.networks ?? []).map({ (Optional($0.key), $0.appLimits ?? []) }) {
            for limit in limits {
                count += 1
                guard !limit.name.trimmingCharacters(in: .whitespaces).isEmpty, limit.name.count <= 200, limit.apps.count <= 100, limit.apps.allSatisfy(RuleBackup.validApp) else {
                    throw SettingsBackupError.invalid(String(localized: "An app limit names no app Kilobat can use.", comment: "Settings file error"))
                }
                guard limit.bytes > 0 else { throw SettingsBackupError.invalid(String(localized: "The limit for \(limit.name) isn’t a size.", comment: "Settings file error")) }
                guard limitKeys.insert("\(limit.name)|\(network ?? "")|\(limit.uploadOnly == true)").inserted else {
                    throw SettingsBackupError.invalid(String(localized: "The file has two limits for \(limit.name).", comment: "Settings file error"))
                }
            }
        }
        guard count <= 200 else { throw SettingsBackupError.invalid(String(localized: "The file has too many app limits.", comment: "Settings file error")) }
        return backup
    }

    /// App limits for every network.
    var appLimits: [SettingsAppLimit] { (try? value(at: "appLimits")?.decoded([SettingsAppLimit].self)) ?? [] }

    /// Types and lists in `settings`; what this version doesn't know, or never imports, is listed rather than refused.
    private mutating func check() throws {
        func wrong(_ path: String) -> SettingsBackupError { .invalid(String(localized: "“\(path)” holds the wrong kind of value.", comment: "Settings file error")) }
        /// Unknown objects are searched too: a key that never travels is named as such wherever it sits.
        func walk(_ object: [String: SettingsValue], _ prefix: String) throws -> (unknown: [String], never: [String]) {
            var unknown: [String] = [], never: [String] = []
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                let path = prefix.isEmpty ? key : prefix + "." + key
                if SettingsFile.knownPaths.contains(path) { continue }
                if SettingsFile.isNever(path, last: key) { never.append(path); continue }
                if SettingsFile.containerPaths.contains(path) {
                    guard let inner = value.object else { throw wrong(path) }
                    let found = try walk(inner, path)
                    unknown += found.unknown; never += found.never
                    continue
                }
                if let inner = value.object {
                    let found = try walk(inner, path)
                    if !found.never.isEmpty { unknown += found.unknown; never += found.never; continue }
                }
                unknown.append(path)
            }
            return (unknown, never)
        }
        var (unknown, never) = try walk(settings, "")
        for entry in SettingsFile.entries {
            guard let value = self.value(at: entry.path) else { continue }
            if entry.member != nil {
                guard let names = value.array, names.allSatisfy({ $0.string != nil }) else { throw wrong(entry.path) }
                continue
            }
            switch entry.kind {
            case .bool: guard value.bool != nil else { throw wrong(entry.path) }
            case .int, .intChoice, .double: guard value.number != nil else { throw wrong(entry.path) }
            case .choice: guard value.string != nil else { throw wrong(entry.path) }
            case .text(_, let maxLength, _, _):
                guard let text = value.string else { throw wrong(entry.path) }
                guard text.count <= maxLength else { throw SettingsBackupError.invalid(String(localized: "“\(entry.path)” is too long.", comment: "Settings file error")) }
            case .list(let maxCount, let normalize, let reason):
                guard let items = value.array, items.allSatisfy({ $0.string != nil }) else { throw wrong(entry.path) }
                guard items.count <= maxCount else { throw SettingsBackupError.invalid(String(localized: "“\(entry.path)” has too many entries.", comment: "Settings file error")) }
                for item in items.compactMap(\.string) where normalize(item) == nil { throw SettingsBackupError.invalid(reason(item)) }
            }
        }
        let known = Set(SettingsFile.menuItems.map(\.name))
        for name in value(at: "menuBar.show")?.strings ?? [] where !known.contains(name) { unknown.append("menuBar.show: \(name)") }
        if let limits = value(at: "appLimits") {
            guard let list = limits.array, list.allSatisfy({ $0.object != nil }) else { throw wrong("appLimits") }
            for key in Set(list.flatMap { $0.object?.keys.map { $0 } ?? [] }).sorted() where !SettingsAppLimit.fields.contains(key) { unknown.append("appLimits[].\(key)") }
            guard (try? limits.decoded([SettingsAppLimit].self)) != nil else {
                throw SettingsBackupError.invalid(String(localized: "An app limit can’t be read.", comment: "Settings file error"))
            }
        }
        if let provider = value(at: "provider") {
            guard let object = provider.object else { throw wrong("provider") }
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                switch key {
                case "id", "country", "otherProvider", "planWording":
                    guard let text = value.string else { throw wrong("provider." + key) }
                    guard text.count <= (key == "planWording" ? 5_000 : 200) else { throw SettingsBackupError.invalid(String(localized: "“provider.\(key)” is too long.", comment: "Settings file error")) }
                case "monthlyPrice", "uploadMbps", "minimumMbps":
                    guard let number = value.number, number >= 0 else { throw wrong("provider." + key) }
                default: unknown.append("provider." + key)
                }
            }
        }
        if let name = value(at: "protection.blocklistName"), name.string == nil { throw wrong("protection.blocklistName") }
        self.unknown += unknown
        notImported += never
    }
}

public enum SettingsBackupError: Error, Equatable, LocalizedError {
    case tooLarge, notSettings, unreadable, newerVersion, invalid(String)
    /// The embedded rules file's own refusal, or a rules file's.
    case rules(RuleBackupError)
    public var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "This file is too large to be a Kilobat settings file.")
        case .notSettings: String(localized: "This isn’t a Kilobat settings file.")
        case .unreadable: String(localized: "This settings file is damaged or incomplete.")
        case .newerVersion: String(localized: "This settings file comes from a newer Kilobat. Update Kilobat to import it.")
        case .invalid(let reason): String(localized: "Nothing was imported. \(reason)", comment: "Rules file error; the reason follows")
        case .rules(let error): error.errorDescription
        }
    }
}

// MARK: Reading what's set now

/// The current, effective value of each setting: nil and missing keys read as the default.
struct SettingsReader {
    let preferences: SavedPreferences
    let defaults: [String: Any]

    func current(_ entry: SettingsFileEntry) -> SettingsValue {
        if let read = entry.read { return read(preferences) }
        guard case .defaults(let key) = entry.storage else { return entry.kind.defaultValue }
        let stored = defaults[key]
        switch entry.kind {
        case .bool(let value): return .bool(stored as? Bool ?? value)
        case .int(let value, let range, let clamp, _):
            guard let number = (stored as? NSNumber)?.intValue else { return .int(value) }
            // As the stores read them: an interval below 12 s runs at 12.
            return .int(clamp ? min(range.upperBound, max(range.lowerBound, number)) : number)
        case .intChoice(let value, _, _):
            guard let number = (stored as? NSNumber)?.intValue, number != 0 || key != "speedStreams" else { return .int(value) }
            return .int(number)
        case .double(let value, _, _): return .double((stored as? NSNumber)?.doubleValue ?? value)
        case .choice(let value, _, _), .text(let value, _, _, _): return .string(stored as? String ?? value)
        case .list: return .array(((stored as? [String]) ?? []).map(SettingsValue.string))
        }
    }

    var credit: CreditSettings? { (defaults[CreditSettings.key] as? Data).flatMap { try? JSONDecoder().decode(CreditSettings.self, from: $0) } }
    var plans: [String: Double] {
        ((defaults[PlanSpeeds.key] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }.filter { $0.value >= 0 && $0.value.isFinite }
    }
    var fastNetworks: [String] { defaults["uploadFastNetworks"] as? [String] ?? [] }
    var places: [String: Any] { (defaults["share.places"] as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
    func placeName(_ key: String) -> String? {
        ((places[key] as? [String: Any])?["name"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The working copy describes the network the Mac is on.
    func budget(_ key: String, current: String?) -> (limit: Double, cycle: BudgetCycle?, mode: NetworkBudgetMode) {
        if key == current { return (preferences.limitGB, preferences.budgetCycle, preferences.budgetMode(for: key)) }
        return (preferences.networkLimits?[key] ?? 5, preferences.networkCycles?[key], preferences.budgetMode(for: key))
    }

    func networks(knownNetworks: [String: String], current: String?) -> [SettingsNetwork] {
        let preferences = preferences, credit = credit, plans = plans, fast = fastNetworks
        var keys = Set<String>()
        for map in [preferences.networkProfiles?.keys.map { $0 }, preferences.networkLimits?.keys.map { $0 }, preferences.networkCycles?.keys.map { $0 },
                    preferences.networkBudgetModes?.keys.map { $0 }, preferences.networkCost?.keys.map { $0 }, preferences.networkFastestDNS?.keys.map { $0 }] {
            keys.formUnion(map ?? [])
        }
        keys.formUnion((preferences.quotas ?? []).compactMap(\.network))
        keys.formUnion(plans.keys); keys.formUnion(fast); keys.formUnion(places.keys)
        if let key = credit?.networkKey { keys.insert(key) }
        if let current, current != "unknown", preferences.limitGB != 5 || preferences.budgetCycle != nil { keys.insert(current) }
        keys.remove("unknown")
        return keys.sorted().prefix(100).map { key in
            var network = SettingsNetwork(key: key, name: knownNetworks[key] ?? (credit?.networkKey == key ? credit?.networkName : nil))
            let hasBudget = preferences.networkLimits?[key] != nil || preferences.networkCycles?[key] != nil || preferences.networkBudgetModes?[key] != nil || key == current
            if hasBudget {
                let budget = budget(key, current: current)
                network.budget = .init(limitGB: budget.limit, mode: budget.mode.rawValue, cycle: budget.cycle ?? BudgetCycle(period: .session))
            }
            network.dataCost = preferences.networkCost?[key]
            network.profile = preferences.networkProfiles?[key].map(RuleBackup.fileID)
            network.fastestDNS = preferences.networkFastestDNS?[key]
            network.planMbps = plans[key]
            network.sendLaterFastEnough = fast.contains(key) ? true : nil
            network.placeName = placeName(key)
            network.providerHere = credit?.networkKey == key ? true : nil
            let limits = (preferences.quotas ?? []).filter { $0.network == key }.map(SettingsAppLimit.init)
            network.appLimits = limits.isEmpty ? nil : limits
            return network
        }
    }
}

// MARK: Before an import

/// The copy of the settings written before each import, so importing it puts things back. The last five are kept.
public enum SettingsBackupFiles {
    public static let keep = 5
    static let prefix = "Kilobat settings before import "
    /// `support` is Kilobat's Application Support folder.
    public static func folder(_ support: URL) -> URL { support.appendingPathComponent("Backups", isDirectory: true) }
    public static func fileName(now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return prefix + formatter.string(from: now) + ".json"
    }
    /// Writes `data` readable by this user only, then removes all but the newest `keep` copies.
    @discardableResult
    public static func save(_ data: Data, in folder: URL, now: Date = Date(), calendar: Calendar = .current, keep: Int = keep) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = folder.appendingPathComponent(fileName(now: now, calendar: calendar))
        var suffix = 2
        while manager.fileExists(atPath: url.path) { url = folder.appendingPathComponent(fileName(now: now, calendar: calendar).replacingOccurrences(of: ".json", with: " \(suffix).json")); suffix += 1 }
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let copies = try manager.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted()
        for name in copies.dropLast(keep) { try? manager.removeItem(at: folder.appendingPathComponent(name)) }
        return url
    }
}
