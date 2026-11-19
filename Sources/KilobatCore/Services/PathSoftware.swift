import Foundation
import AppKit

/// One product's piece of this Mac's network path: a content filter, DNS proxy, app or transparent proxy, VPN,
/// encrypted DNS setting, endpoint security agent, or a network extension macOS lists with no readable configuration.
/// Read from what macOS shows any user: never a guess about what it does to a connection.
public struct PathItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case contentFilter, dnsProxy, appProxy, urlFilter, relay, vpn, encryptedDNS, networkExtension, securityAgent
    }
    /// Where macOS showed it: a NetworkExtension configuration, `systemextensionsctl list`, or a running process.
    public enum Source: String, Codable, Sendable { case configuration, systemExtension, process }
    public let kind: Kind
    /// The product, as its app names itself (TripMode, Little Snitch), else its extension's name.
    public let name: String
    /// The app's bundle ID for a configuration, the extension's for a system extension, nil for a process.
    public let bundleID: String?
    /// On as macOS has it: the configuration's switch, a VPN connected, an extension active, an agent running. Nil when unknown.
    public let on: Bool?
    /// Kilobat's own filter, named in the same list.
    public let kilobat: Bool
    public let source: Source
    /// The DNS server an encrypted DNS setting points at, when it says.
    public var server: String? = nil
    public var id: String { "\(kind.rawValue):\(bundleID ?? name)" }

    public init(kind: Kind, name: String, bundleID: String?, on: Bool?, kilobat: Bool = false, source: Source, server: String? = nil) {
        self.kind = kind; self.name = name; self.bundleID = bundleID; self.on = on; self.kilobat = kilobat; self.source = source; self.server = server
    }

    /// Whether every connection can pass through it now: on, and a kind that sits in the path. A VPN only when connected.
    public var inPath: Bool { on == true && kind != .encryptedDNS }

    /// What it is, in a few words.
    public var kindTitle: String {
        switch kind {
        case .contentFilter: String(localized: "Network filter", comment: "Other software in the network path: an app's content filter")
        case .dnsProxy: String(localized: "DNS proxy", comment: "Other software in the network path")
        case .appProxy: String(localized: "Proxy", comment: "Other software in the network path: an app or transparent proxy")
        case .urlFilter: String(localized: "Web filter", comment: "Other software in the network path: macOS's URL filter")
        case .relay: String(localized: "Relay", comment: "Other software in the network path: a company relay set by a profile")
        case .vpn: String(localized: "VPN", comment: "Other software in the network path")
        case .encryptedDNS: String(localized: "Encrypted DNS", comment: "Other software in the network path: a DNS-over-HTTPS or TLS setting")
        case .networkExtension: String(localized: "Network extension", comment: "Other software in the network path")
        case .securityAgent: String(localized: "Security software", comment: "Other software in the network path: an endpoint security agent")
        }
    }
}

/// Everything besides the router and the line that sits between an app and the network on this Mac, read-only:
/// other products' network extensions and their configurations, VPNs, the system proxy and known security agents,
/// with Kilobat's own filter named among them. Kilobat can't see inside any of them, so this is a list of suspects
/// and a test the person runs, never a verdict.
public struct PathSoftware: Codable, Sendable, Equatable {
    public var items: [PathItem]
    /// The system proxy, host:port or a PAC URL, when one is set.
    public var systemProxy: String?
    /// The latest macOS install this Mac recorded, from /Library/Receipts/InstallHistory.plist.
    public var macOSVersion: String?
    public var macOSUpdated: Date?
    public var date: Date

    public init(items: [PathItem], systemProxy: String? = nil, macOSVersion: String? = nil, macOSUpdated: Date? = nil, date: Date = Date()) {
        self.items = items; self.systemProxy = systemProxy; self.macOSVersion = macOSVersion; self.macOSUpdated = macOSUpdated; self.date = date
    }

    /// A macOS update within this many days is "soon after": when a filter or VPN that worked before is most likely to break.
    public static let recentUpdateDays = 14

    /// Other products in the path now, Kilobat's own filter last.
    public var suspects: [PathItem] {
        let order: [PathItem.Kind] = [.contentFilter, .dnsProxy, .appProxy, .urlFilter, .networkExtension, .securityAgent, .relay, .vpn]
        return items.filter(\.inPath).sorted { lhs, rhs in
            if lhs.kilobat != rhs.kilobat { return !lhs.kilobat }
            return (order.firstIndex(of: lhs.kind) ?? 99) < (order.firstIndex(of: rhs.kind) ?? 99)
        }
    }
    /// Suspects for a connection that fails: VPNs are left out, as the check tests the tunnel itself.
    public var filterSuspects: [PathItem] { suspects.filter { $0.kind != .vpn } }
    /// Another product's filter, proxy or agent: what makes Kilobat's filter not the only one.
    public var others: [PathItem] { filterSuspects.filter { !$0.kilobat } }
    public var encryptedDNS: [PathItem] { items.filter { $0.kind == .encryptedDNS } }
    public var dnsProxies: [PathItem] { items.filter { $0.kind == .dnsProxy } }

    public func updatedRecently(now: Date = Date()) -> Bool {
        guard let macOSUpdated else { return false }
        return now.timeIntervalSince(macOSUpdated) < Double(Self.recentUpdateDays) * 86400 && macOSUpdated <= now.addingTimeInterval(3600)
    }

    // MARK: Words

    /// "TripMode’s filter and Kilobat’s filter", the names as one list.
    public static func names(_ items: [PathItem]) -> String {
        items.map { item in
            switch item.kind {
            case .contentFilter: String(localized: "\(item.name)’s filter", comment: "Other software in the network path; the argument is a product such as TripMode")
            case .dnsProxy: String(localized: "\(item.name)’s DNS proxy", comment: "Other software in the network path; the argument is a product")
            case .appProxy: String(localized: "\(item.name)’s proxy", comment: "Other software in the network path; the argument is a product")
            case .urlFilter: String(localized: "\(item.name)’s web filter", comment: "Other software in the network path; the argument is a product")
            case .relay: String(localized: "\(item.name)’s relay", comment: "Other software in the network path; the argument is a company or profile")
            case .vpn: String(localized: "\(item.name)’s VPN", comment: "Other software in the network path; the argument is a product")
            case .encryptedDNS: String(localized: "\(item.name)’s encrypted DNS", comment: "Other software in the network path; the argument is a product")
            case .networkExtension: String(localized: "\(item.name)’s network extension", comment: "Other software in the network path; the argument is a product")
            case .securityAgent: item.name
            }
        }.spokenList()
    }

    /// Where macOS keeps the switch for filters, DNS proxies and transparent proxies: Network › Filters from macOS 15.
    public static func filtersPane(major: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        major >= 15 ? String(localized: "System Settings › Network › Filters", comment: "Where macOS 15 and later list network filters")
                    : String(localized: "System Settings › Network › VPN & Filters", comment: "Where macOS 14 lists network filters")
    }

    /// The test for one suspect: turn it off, check again, turn it back on. Kilobat never switches another product off.
    public static func test(for item: PathItem, major: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        if item.kilobat {
            return String(localized: "To rule out Kilobat, turn off Network filter in Kilobat’s Settings › Filter & rules, check again, then turn it back on.", comment: "Test for Kilobat's own filter")
        }
        switch item.kind {
        case .contentFilter, .dnsProxy, .appProxy, .urlFilter, .networkExtension:
            return String(localized: "To test it, turn off \(item.name) in \(filtersPane(major: major)), check again, then turn it back on.", comment: "Test for another product's filter; the arguments are a product and a System Settings path")
        case .vpn:
            return String(localized: "To test it, disconnect \(item.name), check again, then reconnect.", comment: "Test for a VPN; the argument is a product")
        case .encryptedDNS:
            return String(localized: "To test it, switch off \(item.name)’s encrypted DNS in its app or in \(filtersPane(major: major)), check again, then switch it back on.", comment: "Test for an encrypted DNS setting")
        case .relay:
            return String(localized: "It comes from a profile, often your employer’s. Ask whoever manages this Mac before changing it.", comment: "Test for a company relay")
        case .securityAgent:
            return String(localized: "\(item.name) is security software, often set up by an employer. Ask whoever manages it before pausing it.", comment: "Test for an endpoint security agent; the argument is a product")
        }
    }

    /// "macOS was updated to 27.2 on 25 Oct." when that was recent.
    public func updateNote(now: Date = Date()) -> String? {
        guard updatedRecently(now: now), let date = macOSUpdated else { return nil }
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        let updated = macOSVersion.map { String(localized: "macOS was updated to \($0) on \(day).", comment: "Network software; the arguments are a version such as 27.2 and a date") }
            ?? String(localized: "macOS was updated on \(day).", comment: "Network software; the argument is a date")
        return updated + " " + String(localized: "After an update, a filter or VPN can stop passing traffic until its maker updates it.", comment: "Network software, after a recent macOS update")
    }

    /// The suspects for a connection that fails, as one sentence, and the test for the first; nil when there are none.
    public func failureAdvice(now: Date = Date(), major: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> (detail: String, test: String)? {
        let suspects = filterSuspects
        guard let first = suspects.first else { return nil }
        let listed = Self.names(suspects)
        var detail = suspects.count == 1
            ? String(localized: "\(listed) also handles this Mac’s traffic. Kilobat can’t see inside it, so it can’t tell whether it’s the cause.", comment: "Network software; the argument is like “TripMode’s filter”")
            : String(localized: "\(listed) also handle this Mac’s traffic. Kilobat can’t see inside them, so it can’t tell whether one is the cause.", comment: "Network software; the argument lists products such as “TripMode’s filter and Kilobat’s filter”")
        if let note = updateNote(now: now) { detail += " " + note }
        var test = Self.test(for: first, major: major)
        if !first.kilobat, let own = suspects.first(where: \.kilobat) { test += " " + Self.test(for: own, major: major) }
        return (detail, test)
    }

    /// Health's finding: other software named as suspects, with the test, when the Mac is connected but the internet or
    /// DNS doesn't answer, or when the line is struggling soon after a macOS update. Nil otherwise: no nagging on a good line.
    public func healthFinding(_ snapshot: DiagnosticSnapshot?, now: Date = Date(),
                              major: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> (title: String, detail: String, advice: String, problem: Bool)? {
        guard let snapshot, snapshot.captivePortal != true, snapshot.setupNetwork == nil, let advice = failureAdvice(now: now, major: major) else { return nil }
        let linked = snapshot.router?.average != nil || FixPlanner.usableGateway(snapshot.gateway)
        let noInternet = linked && (snapshot.reachability != .up || snapshot.dnsMilliseconds == nil)
        let struggling = snapshot.health == .poor || snapshot.health == .degraded
        guard noInternet || (struggling && updatedRecently(now: now)) else { return nil }
        let title = String(localized: "Check other network software", comment: "Health finding: other products' filters or agents may be the cause")
        // The row says when macOS changed and the first test; the tooltip has all of it.
        let updated = updatedRecently(now: now) ? macOSUpdated.map { date in
            let day = date.formatted(.dateTime.day().month(.abbreviated))
            return macOSVersion.map { String(localized: "macOS was updated to \($0) on \(day).", comment: "Network software; the arguments are a version such as 27.2 and a date") + " " }
                ?? String(localized: "macOS was updated on \(day).", comment: "Network software; the argument is a date") + " "
        } ?? "" : ""
        let detail = updated + Self.alsoHandles(filterSuspects) + " " + Self.test(for: filterSuspects[0], major: major)
        return (title, detail, advice.detail + " " + advice.test, noInternet)
    }

    /// The note under a Fix it result that ends with someone else to blame: before they're called, the other software on
    /// this Mac gets its test. Nil when nothing else is in the path or the cause can't be one it explains.
    public func fixItNote(_ cause: FixCause, major: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String? {
        switch cause {
        case .provider, .router, .dnsFailing, .dnsSlow, .wifiStuck, .vpnBroken: break
        default: return nil
        }
        guard let first = others.first else { return nil }
        return String(localized: "Before calling anyone:", comment: "Fix it note, before other software on this Mac is named") + " " + Self.alsoHandles(others)
            + " " + Self.test(for: first, major: major)
    }

    /// "TripMode’s filter also handles this Mac’s traffic.", singular or plural.
    static func alsoHandles(_ items: [PathItem]) -> String {
        let names = Self.names(items)
        return items.count == 1 ? String(localized: "\(names) also handles this Mac’s traffic.", comment: "Other software in the network path; the argument is like “TripMode’s filter”")
            : String(localized: "\(names) also handle this Mac’s traffic.", comment: "Other software in the network path; the argument lists products such as “TripMode’s filter and Kilobat’s filter”")
    }

    /// A list of everything readable, for a step or a row: "TripMode’s filter, Tailscale’s VPN (not connected)".
    public var inventoryLine: String {
        let parts = (items.filter { !$0.kilobat } + items.filter(\.kilobat)).map { item -> String in
            let name = Self.names([item])
            switch item.on {
            case false?: return item.kind == .vpn ? String(localized: "\(name) (not connected)", comment: "Network software inventory") : String(localized: "\(name) (off)", comment: "Network software inventory")
            default: return name
            }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Reading

    /// Reads it all from this Mac: about half a second. Nothing is changed and nothing leaves the Mac.
    public static func current(now: Date = Date()) async -> PathSoftware {
        async let extensions = CommandRunner.run("/usr/bin/systemextensionsctl", ["list"], timeout: 4)
        async let services = CommandRunner.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 3)
        async let proxy = CommandRunner.run("/usr/sbin/scutil", ["--proxy"], timeout: 3)
        async let processes = CommandRunner.run("/bin/ps", ["-axco", "comm="], timeout: 3)
        let configurations = (try? Data(contentsOf: configurationFile)).map(Self.configurations) ?? []
        let history = (try? Data(contentsOf: URL(fileURLWithPath: "/Library/Receipts/InstallHistory.plist"))).flatMap(Self.lastMacOSInstall)
        let system = ProxyEnvironment.systemProxy(await proxy.output)
        let items = merge(configurations: configurations, extensions: systemExtensions(await extensions.output),
                          connected: Set(ExitPath.connectedVPNs(await services.output)), processes: await processes.output, name: appName)
        return PathSoftware(items: items, systemProxy: [system.https, system.http, system.socks, system.pac].compactMap { $0 }.first,
                            macOSVersion: history?.version, macOSUpdated: history?.date, date: now)
    }

    /// Readable by every user; macOS keeps every NetworkExtension configuration here.
    static let configurationFile = URL(fileURLWithPath: "/Library/Preferences/com.apple.networkextension.plist")

    /// One row of `systemextensionsctl list`.
    struct SystemExtension: Equatable, Sendable {
        enum Category: String, Sendable { case network = "network_extension", endpointSecurity = "endpoint_security", other }
        let category: Category
        let teamID: String
        let bundleID: String
        let name: String
        let enabled: Bool
        let active: Bool
    }

    /// `systemextensionsctl list`: a `--- com.apple.system_extension.<category>` header, then tab-separated rows of
    /// enabled and active stars, team ID, `bundle (version/build)`, name and `[state]`. Only activated extensions count.
    static func systemExtensions(_ output: String) -> [SystemExtension] {
        var category = SystemExtension.Category.other, found: [SystemExtension] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("---") {
                let name = line.split(separator: " ").dropFirst().first.map { String($0.replacingOccurrences(of: "com.apple.system_extension.", with: "")) } ?? ""
                category = SystemExtension.Category(rawValue: name) ?? .other
                continue
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 6, let state = columns.last, state.hasPrefix("["), state.contains("activated"), !state.contains("terminated") else { continue }
            let bundle = columns[3].components(separatedBy: " (").first ?? columns[3]
            guard bundle.contains(".") else { continue }
            found.append(SystemExtension(category: category, teamID: columns[2], bundleID: bundle, name: columns[4], enabled: columns[0] == "*", active: columns[1] == "*"))
        }
        return found
    }

    /// One NetworkExtension configuration, as much as says what it is: never its rules, account or password.
    struct Configuration: Equatable, Sendable {
        let name: String
        let application: String?
        let applicationName: String?
        let kind: PathItem.Kind
        let enabled: Bool?
        var server: String?
    }

    /// The configurations in com.apple.networkextension.plist, a keyed archive of NEConfiguration objects. Read as a
    /// plain property list, so no NetworkExtension class is ever instantiated. Apple's own (the application firewall,
    /// the Local Network privacy rules) are left out.
    static func configurations(_ data: Data) -> [Configuration] {
        guard let root = archive(data), let objects = root["$objects"] as? [Any], let top = root["$top"] as? [String: Any] else { return [] }
        func resolve(_ value: Any?) -> Any? {
            guard let reference = value as? String, reference.hasPrefix(uidPrefix), let index = Int(reference.dropFirst(uidPrefix.count)) else { return value }
            return index > 0 && index < objects.count ? objects[index] : nil
        }
        func className(_ object: [String: Any]) -> String? { (resolve(object["$class"]) as? [String: Any])?["$classname"] as? String }
        func text(_ value: Any?) -> String? { (resolve(value) as? String).flatMap { $0 == "$null" || $0.isEmpty ? nil : $0 } }
        let payloads: [(String, PathItem.Kind)] = [("ContentFilter", .contentFilter), ("DNSProxy", .dnsProxy), ("AppVPN", .appProxy), ("URLFilter", .urlFilter),
                                                   ("Relay", .relay), ("VPN", .vpn), ("AlwaysOnVPN", .vpn), ("DNSSettings", .encryptedDNS)]
        var found: [Configuration] = []
        for key in top.keys.sorted() {
            guard let object = resolve(top[key]) as? [String: Any], className(object) == "NEConfiguration" else { continue }
            let name = text(object["Name"]) ?? "", application = text(object["Application"])
            if application?.hasPrefix("com.apple.") == true || name.hasPrefix("com.apple.preferences.") { continue }
            for (payloadKey, kind) in payloads {
                guard let payload = resolve(object[payloadKey]) as? [String: Any] else { continue }
                let enabled = payload["Enabled"] as? Bool
                var server: String?
                if kind == .encryptedDNS, let settings = resolve(payload["Settings"]) as? [String: Any] {
                    server = text(settings["ServerURL"]) ?? text(settings["ServerName"])
                    if server == nil, let url = resolve(settings["ServerURL"]) as? [String: Any] { server = text(url["NS.relative"]) }
                }
                found.append(Configuration(name: name, application: application, applicationName: text(object["ApplicationName"]), kind: kind, enabled: enabled, server: server))
                break
            }
        }
        return found
    }

    static let uidPrefix = "kilobat-uid:"

    /// The keyed archive with every UID reference turned into "kilobat-uid:<index>". Property lists keep UIDs as an
    /// opaque type; in XML they're `<dict><key>CF$UID</key><integer>n</integer></dict>`, so one pass rewrites them.
    static func archive(_ data: Data) -> [String: Any]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        guard let xml = try? PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0) else { return nil }
        let pattern = #"<dict>\s*<key>CF\$UID</key>\s*<integer>(\d+)</integer>\s*</dict>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = String(decoding: xml, as: UTF8.self)
        let rewritten = expression.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "<string>\(uidPrefix)$1</string>")
        return try? PropertyListSerialization.propertyList(from: Data(rewritten.utf8), format: nil) as? [String: Any]
    }

    /// Agents that run as plain processes, without a system extension of their own, by the name `ps` shows.
    static let agentProcesses: [String: String] = [
        "falcond": "CrowdStrike Falcon", "sentineld": "SentinelOne", "SentinelAgent": "SentinelOne", "wdavdaemon": "Microsoft Defender",
        "JamfProtect": "Jamf Protect", "ZscalerTunnel": "Zscaler", "vpnagentd": "Cisco Secure Client", "PanGPS": "GlobalProtect",
        "CloudflareWARP": "Cloudflare WARP", "nsAuxiliarySvc": "Netskope", "stAgentSvc": "Netskope",
    ]

    /// Products named by their extension's bundle ID prefix, when no configuration or installed app gives a name.
    static let knownVendors: [(prefix: String, name: String)] = [
        ("at.obdev.littlesnitch", "Little Snitch"), ("com.objective-see.lulu", "LuLu"), ("ch.tripmode", "TripMode"), ("io.tailscale", "Tailscale"),
        ("net.mullvad", "Mullvad VPN"), ("com.nordvpn", "NordVPN"), ("ch.protonvpn", "Proton VPN"), ("ch.protonmail.vpn", "Proton VPN"), ("com.cloudflare", "Cloudflare WARP"),
        ("com.crowdstrike", "CrowdStrike Falcon"), ("com.sentinelone", "SentinelOne"), ("com.microsoft.wdav", "Microsoft Defender"), ("com.jamf.protect", "Jamf Protect"),
        ("com.zscaler", "Zscaler"), ("com.cisco", "Cisco Secure Client"), ("com.paloaltonetworks", "GlobalProtect"), ("com.netskope", "Netskope"),
        ("com.radiosilenceapp", "Radio Silence"), ("com.adguard", "AdGuard"), ("io.nextdns", "NextDNS"), ("com.surfshark", "Surfshark"), ("com.expressvpn", "ExpressVPN"),
        ("com.wireguard", "WireGuard"), ("com.privateinternetaccess", "Private Internet Access"), ("com.sophos", "Sophos"), ("com.eset", "ESET"),
    ]

    /// The name an installed app gives itself, from the extension's bundle ID with its last parts dropped.
    static func appName(_ bundleID: String) -> String? {
        var parts = bundleID.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate), let info = Bundle(url: url)?.infoDictionary {
                return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            }
            parts.removeLast()
        }
        return nil
    }

    /// One list from the three readings: a configuration names a product's kind and switch; an active system extension
    /// with no configuration of its own is listed as a network extension; endpoint security extensions and known agent
    /// processes as security software, once per product.
    static func merge(configurations: [Configuration], extensions: [SystemExtension], connected: Set<String>, processes: String,
                      name: (String) -> String? = { _ in nil }) -> [PathItem] {
        func isKilobat(_ id: String?) -> Bool { id?.hasPrefix("co.seifi.kilobat") == true }
        func vendor(_ id: String) -> String? { knownVendors.first { id.hasPrefix($0.prefix) }?.name }
        var items: [PathItem] = []
        for configuration in configurations {
            let product = isKilobat(configuration.application) ? "Kilobat"
                : configuration.applicationName ?? configuration.application.flatMap { name($0) ?? vendor($0) } ?? configuration.name
            let on: Bool? = configuration.kind == .vpn ? connected.contains(configuration.name) : configuration.enabled
            let item = PathItem(kind: configuration.kind, name: product, bundleID: configuration.application, on: on, kilobat: isKilobat(configuration.application),
                                source: .configuration, server: configuration.server)
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
        }
        for system in extensions where system.active && system.enabled {
            let covered = items.contains { item in item.bundleID.map { system.bundleID.hasPrefix($0) } == true }
            guard !covered else { continue }
            let product = isKilobat(system.bundleID) ? "Kilobat" : vendor(system.bundleID) ?? name(system.bundleID) ?? system.name
            let kind: PathItem.Kind
            switch system.category {
            case .network: kind = .networkExtension
            case .endpointSecurity: kind = .securityAgent
            case .other: continue
            }
            if kind == .securityAgent, items.contains(where: { $0.kind == .securityAgent && $0.name == product }) { continue }
            items.append(PathItem(kind: kind, name: product, bundleID: system.bundleID, on: true, kilobat: isKilobat(system.bundleID), source: .systemExtension))
        }
        let running = Set(processes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        for (process, product) in agentProcesses.sorted(by: { $0.key < $1.key }) where running.contains(process) {
            guard !items.contains(where: { $0.name == product }) else { continue }
            items.append(PathItem(kind: .securityAgent, name: product, bundleID: nil, on: true, source: .process))
        }
        return items
    }

    /// The newest macOS entry in InstallHistory.plist: "macOS 27.2", its version and when it was installed.
    static func lastMacOSInstall(_ data: Data) -> (version: String, date: Date)? {
        guard let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return nil }
        return entries.compactMap { entry -> (String, Date)? in
            guard let name = entry["displayName"] as? String, name.hasPrefix("macOS "), let date = entry["date"] as? Date else { return nil }
            return (entry["displayVersion"] as? String ?? String(name.dropFirst(6)), date)
        }.max { $0.1 < $1.1 }
    }
}
