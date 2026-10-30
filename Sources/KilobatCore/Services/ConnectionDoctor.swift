import Foundation
import Darwin
import Network

/// One layer of a connection check.
public struct DoctorStep: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, warning, failed, skipped }
    public var id: String { layer }
    public let layer: String
    public let status: Status
    public let detail: String
}

/// One request of a redirect chain, as shown: no query values or password in `url`.
public struct DoctorHop: Codable, Sendable, Equatable {
    public let url: String
    public let host: String
    public let method: String
    public let status: Int?
    public let error: String?
}

/// The app whose request failed, as installed: its name and bundle version.
public struct DoctorClient: Codable, Sendable, Equatable {
    /// A bundle ID, or process:<name>.
    public let id: String
    public let name: String
    public let version: String?
}

/// The path this check's request took: the app's own proxy, the proxy in its environment, the system proxy, or direct.
/// `untested` names an app setting that changes the app's path but that Kilobat can't read or send a request through.
public struct DoctorPath: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case appProxy, environmentProxy, systemProxy, direct }
    public let kind: Kind
    /// host:port, never a password.
    public let proxy: String?
    public var untested: String? = nil
}

/// Why something can't connect: each layer from the Mac's own link to the server's answer, and the first that broke.
/// `target` and every detail leave out query values and passwords; the request itself keeps them.
/// `date` is when this check ran; `failedAt` is when the app failed, when the person says so.
public struct DoctorReport: Codable, Sendable {
    public let target: String
    public let host: String
    public let app: String?
    public let verdict: String
    public var next: String
    public var steps: [DoctorStep]
    public var hops: [DoctorHop] = []
    public let date: Date
    public var client: DoctorClient? = nil
    /// The method this check sent: HEAD, or a one-byte GET when the server refuses HEAD. Nil when no request was sent.
    public var method: String? = nil
    public var path: DoctorPath? = nil
    public var failedAt: Date? = nil
    public var ok: Bool { !steps.contains { $0.status == .failed } }
}

/// Walks the layers in order: local network and interface, proxies, DNS, Kilobat's own rules, TCP and TLS over IPv4
/// and IPv6 separately, then the exact request through the app's path and every redirect hop, and what the app has open now.
/// Every probe runs in this process, so a strict profile can't block it.
/// It checks from this Mac only; a container, VM, remote machine or a provider's servers have their own path, and `context` says so.
public enum ConnectionDoctor {
    public struct Policy: @unchecked Sendable {
        public let preferences: SavedPreferences
        public let filterActive: Bool
        public let budgetReached: Bool
        /// The current network's effective cost, which decides whether updaters are paused.
        public let metered: Bool
        public init(preferences: SavedPreferences, filterActive: Bool, budgetReached: Bool, metered: Bool = false) {
            self.preferences = preferences; self.filterActive = filterActive; self.budgetReached = budgetReached; self.metered = metered
        }
    }

    /// Where the failing code runs, when it isn't on this Mac. `provider` is a hosted service whose own servers make the request.
    public enum Context: String, CaseIterable, Sendable { case container, vm, remote, provider }

    /// A hosted service whose requests come from its own servers, not the Mac it's set up on.
    /// `claim` keeps to what `docs` said when read (`checked`); `route` is another option those docs list, when they list one.
    struct Provider: Sendable, Equatable {
        let name: String
        let apps: Set<String>
        let feature: String
        let claim: String
        let route: String?
        let docs: String
        let checked: String
        var servers: String { "\(name)’s servers" }
    }

    static let providers = [
        Provider(name: "Warp", apps: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"], feature: "custom inference endpoint",
                 claim: "requests to a custom inference endpoint go through Warp’s servers, so the endpoint needs a public URL",
                 route: "your own OpenAI, Anthropic or Google key, which Warp’s docs list as another option",
                 docs: "https://docs.warp.dev/agents/inference/custom-inference-endpoint/", checked: "Oct 2026"),
    ]

    static func provider(for app: String?) -> Provider? { app.flatMap { app in providers.first { $0.apps.contains(app) } } }

    /// An app's own setting that changes the path its requests take, which Kilobat can't read or send a request through.
    /// `reports` keeps to what the cited thread said, dated: user reports, not a confirmed cause or fix.
    struct AppSetting: Sendable, Equatable {
        let name: String
        let apps: Set<String>
        let domains: [String]
        let setting: String
        let reports: String
        let source: String
        let dated: String
        func covers(_ host: String) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
    }

    static let appSettings = [
        AppSetting(name: "LM Studio", apps: ["ai.elementlabs.lmstudio", "process:LM Studio"], domains: ["huggingface.co", "hf.co"],
                   setting: "Hugging Face proxy setting",
                   reports: "users reported large model downloads timing out until they turned that proxy off, some after restarting the app; one said the switch shows only with Developer mode on",
                   source: "lmstudio-bug-tracker#1031", dated: "Mar–Aug 2026"),
    ]

    /// The known setting of this app that covers any of these hosts (the target or a redirect, such as a CDN).
    static func appSetting(for app: String?, hosts: [String]) -> AppSetting? {
        guard let app, let setting = appSettings.first(where: { $0.apps.contains(app) }) else { return nil }
        return hosts.contains { setting.covers($0.lowercased()) } ? setting : nil
    }

    /// Where to look, citing the reports and their date; Kilobat never changes another app's settings.
    static func settingAdvice(_ setting: AppSetting) -> String {
        "Check \(setting.name)’s \(setting.setting). In \(setting.source) (\(setting.dated)), \(setting.reports). Those are user reports, not a confirmed fix, and Kilobat doesn’t change \(setting.name)’s settings."
    }

    static func appSettingStep(_ setting: AppSetting, path: DoctorPath?) -> DoctorStep {
        let went = switch path?.kind {
        case .appProxy?, .environmentProxy?: "through the proxy below"
        case .systemProxy?: "through the system proxy"
        default: "directly"
        }
        return DoctorStep(layer: "App setting", status: .skipped, detail: "\(setting.name) has its own \(setting.setting), which Kilobat can’t read or send a request through, so this check went \(went). "
                          + "In \(setting.source) (\(setting.dated)), \(setting.reports). Those are user reports, not a confirmed cause.")
    }

    /// The path in words, as verdicts and steps name it.
    public static func via(_ path: DoctorPath, app: String?) -> String {
        switch path.kind {
        case .appProxy: "\(app ?? "the app")’s own proxy (\(path.proxy ?? "?"))"
        case .environmentProxy: "\(app ?? "the app")’s proxy (\(path.proxy ?? "?"))"
        case .systemProxy: "the system proxy (\(path.proxy ?? "?"))"
        case .direct: "a direct connection"
        }
    }

    /// A time the person gives for the failure: ISO 8601, or HH:MM today (yesterday when that's still ahead). Nil for a future time.
    public static func failureTime(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: text)
        if date == nil { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; date = formatter.date(from: text) }
        if date == nil {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]),
                  let today = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) else { return nil }
            date = today > now ? calendar.date(byAdding: .day, value: -1, to: today) : today
        }
        return date.flatMap { $0 > now.addingTimeInterval(60) ? nil : $0 }
    }

    /// TCP, then TLS for https, over one IP version.
    struct FamilyProbe: Sendable, Equatable {
        var tcp: ConnectionProbe.Attempt
        var tls: ConnectionProbe.Attempt?
        var ok: Bool { tcp.outcome == .connected && (tls == nil || tls?.outcome == .connected) }
    }

    /// `proxy` is a proxy address the app uses by its own setting, which Kilobat can't read; the request goes through it.
    /// `failedAt` is when the app failed, as the person says; it's recorded, and a passing check made later says it can't see that moment.
    public static func run(_ target: String, app: String? = nil, proxy: String? = nil, context: Context? = nil, policy: Policy? = nil, failedAt: Date? = nil) async -> DoctorReport {
        let report = await checks(target, app: app, proxy: proxy, context: context, policy: policy, failedAt: failedAt)
        guard !report.steps.isEmpty else { return report }
        return await withProxyApp(report)
    }

    /// When a proxy app with a readable API runs, its mode and how its current nodes answer, as one more layer.
    /// A failed request with a node that doesn't answer points at the node, not the site.
    static func withProxyApp(_ report: DoctorReport) async -> DoctorReport {
        let environment = await ProxyEnvironment.current()
        guard let client = environment.running.first(where: { $0.controller != nil }), let api = ClashAPI(client),
              let groups = try? await api.groups() else { return report }
        let configs = try? await api.configs()
        let mode = configs?.mode ?? client.mode, tun = configs?.tun ?? client.tun
        var nodes: [(group: String, node: String, delay: Int?)] = []
        for group in groups.prefix(3) { if let node = group.now, node != "DIRECT" { nodes.append((group.name, node, await api.delay(node))) } }
        let dead = nodes.filter { $0.delay == nil }
        var detail = "\(client.name)" + [mode.map { " in \($0) mode" }, tun == true ? ", TUN on" : nil].compactMap { $0 }.joined()
        if nodes.isEmpty { detail += "; no proxy node is selected, so traffic goes direct." }
        else { detail += ". " + nodes.map { "\($0.group) uses \($0.node): " + ($0.delay.map { "\($0) ms" } ?? "no answer") }.joined(separator: "; ") + "." }
        var report = report
        report.steps.append(DoctorStep(layer: "Proxy app", status: dead.isEmpty ? .ok : .warning, detail: detail))
        if !report.ok, let node = dead.first {
            report.next = "\(node.node) in \(client.name) doesn’t answer, so requests sent through it fail. Pick another node in its \(node.group) group, or update the subscription. " + report.next
        }
        return report
    }

    static func checks(_ target: String, app: String? = nil, proxy: String? = nil, context: Context? = nil, policy: Policy? = nil, failedAt: Date? = nil) async -> DoctorReport {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = requestURL(trimmed), let host = url.host, ExpertTools.validHost(host) else {
            return DoctorReport(target: requestURL(trimmed).map(ConnectionProbe.redacted) ?? trimmed, host: trimmed, app: app, verdict: "That doesn’t look like a website or host.", next: "Enter a domain such as example.com or a full https:// address.", steps: [], date: Date())
        }
        let shown = ConnectionProbe.redacted(url)
        if let proxy, ConnectionProbe.endpoint(proxy) == nil {
            return DoctorReport(target: shown, host: host, app: app, verdict: "That proxy doesn’t look like an address.", next: "Enter it as the app shows it, such as http://127.0.0.1:7890 or socks5://127.0.0.1:1080.", steps: [], date: Date())
        }
        let port = url.port ?? (url.scheme == "http" ? 80 : 443), https = url.scheme == "https"
        let provider = provider(for: app), client = app.map(ConnectionProbe.client)
        var note = contextStep(context, host: host, url: shown, provider: provider)

        // The Mac's own link.
        let path = await ConnectionProbe.currentPath()
        let physical = path.availableInterfaces.filter { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
            .reduce(into: [NWInterface]()) { list, interface in if !list.contains(where: { $0.name == interface.name }) { list.append(interface) } }
        guard path.status == .satisfied, let primary = path.availableInterfaces.first else {
            return report(shown, host, app, [DoctorStep(layer: "Network", status: .failed, detail: "This Mac has no route to the internet.")] + [note].compactMap { $0 },
                          client: client, failedAt: failedAt)
        }
        let gateway = path.gateways.lazy.compactMap(ConnectionProbe.address).first
        async let router = answers(gateway)
        async let system = ConnectionProbe.systemProxy(for: url)
        async let resolvers = CommandRunner.run("/usr/sbin/scutil", ["--dns"], timeout: 3)
        async let environment = appEnvironment(app)
        async let named = answers(proxy: proxy)
        async let running = openConnections(app)

        let started = Date()
        let addresses = await resolve(host)
        let dnsMs = Int(Date().timeIntervalSince(started) * 1000)
        let resolver = ConnectionProbe.resolver(for: host.lowercased(), in: await resolvers.output)
        note = contextStep(context, host: host, url: shown, provider: provider, addresses: addresses, resolver: resolver)

        let network: DoctorStep = switch (await router, gateway) {
        case (true?, let gateway?): DoctorStep(layer: "Network", status: .ok, detail: "Online; the router at \(gateway) answers.")
        case (false?, let gateway?): DoctorStep(layer: "Network", status: .warning, detail: "Online, but the router at \(gateway) didn’t answer a ping. Some routers ignore pings.")
        default: DoctorStep(layer: "Network", status: .ok, detail: "Online.")
        }
        let systemProxy = await system
        var environmentProxy: Bool?
        let appEnvironment = await environment
        if case .found(_, let values)? = appEnvironment, let proxy = ConnectionProbe.environmentProxy(values, for: url), !proxy.bypassed,
           let endpoint = ConnectionProbe.endpoint(proxy.value) {
            environmentProxy = await ConnectionProbe.open(host: endpoint.host, port: endpoint.port, timeout: 3).outcome == .connected
        }
        let owner: String? = if let client { client.name } else if case .found(let name, _)? = appEnvironment { name } else { nil }
        let namedAnswers = await named
        let proxySteps = [proxyStep(systemProxy), proxy.map { namedProxyStep($0, app: owner, system: systemProxy.proxy, answers: namedAnswers) }
                          ?? appProxyStep(appEnvironment, app: app, url: url, system: systemProxy.proxy, answers: environmentProxy)].compactMap { $0 }
        // The path the app's own requests take: a proxy the person names, else the one in its environment, else the system's.
        // A proxy that needs a password only gets checked for an answer; Kilobat doesn't send passwords.
        let environmentRoute: String? = if proxy == nil, case .found(_, let values)? = appEnvironment, environmentProxy == true,
            let found = ConnectionProbe.environmentProxy(values, for: url), values[found.variable] == found.value { found.value } else { nil }
        let taken: DoctorPath = if let proxy, namedAnswers == true, ConnectionProbe.redacted(proxy) == proxy { DoctorPath(kind: .appProxy, proxy: at(proxy)) }
            else if let environmentRoute { DoctorPath(kind: .environmentProxy, proxy: at(environmentRoute)) }
            else if let system = systemProxy.proxy { DoctorPath(kind: .systemProxy, proxy: system) } else { DoctorPath(kind: .direct, proxy: nil) }
        let route: (via: String, proxy: String?)? = switch taken.kind {
        case .appProxy: (via(taken, app: owner), proxy)
        case .environmentProxy: (via(taken, app: owner), environmentRoute)
        case .systemProxy: (via(taken, app: owner), nil)
        case .direct: nil
        }
        let fallback = ConnectionProbe.Link(primary, expensive: path.isExpensive)
        let underlying = physical.first.map { ConnectionProbe.Link($0, expensive: path.isExpensive) }

        // DNS, and when it fails, whether a private resolver or the Mac's own DNS is at fault.
        guard !addresses.isEmpty else {
            let literal = AddressRange.parse(host) != nil
            async let open = literal ? nil : ConnectionProbe.directLookup(host)
            async let split = literal ? nil : privateLookup(host, resolver)
            let failure = dnsFailure(host, resolver: resolver, private: await split, public: await open)
            return report(shown, host, app, [network, interfaceStep(fallback, underlying: underlying)] + proxySteps + [failure, note].compactMap { $0 },
                          client: client, path: taken, failedAt: failedAt)
        }

        // TCP and TLS over IPv4 and IPv6 separately, and over each interface when there's more than one.
        let v4 = addresses.filter { !$0.contains(":") }, v6 = addresses.filter { $0.contains(":") }
        async let four = path.supportsIPv4 && !v4.isEmpty ? probe(host, port: port, version: .v4, tls: https) : nil
        async let six = path.supportsIPv6 && !v6.isEmpty ? probe(host, port: port, version: .v6, tls: https) : nil
        async let compared = physical.count > 1 ? compare(host, port: port, over: physical) : []
        // Through a VPN, the same connection pinned to the network port shows whether the tunnel or the network fails.
        async let bypass = pinned(host, port: port, to: fallback.vpn ? physical.first : nil)
        let (ipv4, ipv6) = await (four, six)
        let families = [ipv4, ipv6].compactMap { $0 }
        let reached = families.contains { $0.tcp.outcome == .connected }, direct = families.contains(where: \.ok)
        let used = families.lazy.compactMap(\.tcp.link).first ?? fallback

        let encrypted: String? = switch families.compactMap(\.tcp.dnsProtocol).first {
        case .https?: "DNS over HTTPS"
        case .tls?: "DNS over TLS"
        default: nil
        }
        let dns = DoctorStep(layer: "DNS", status: dnsMs > 300 ? .warning : .ok,
                             detail: "\(host) → \(addresses.prefix(3).joined(separator: ", ")) in \(dnsMs) ms" + (resolver.map { " from \($0.description)" } ?? "")
                                + (encrypted.map { " over \($0)" } ?? "") + (dnsMs > 300 ? ", which is slow." : "."))
        var steps = [network, interfaceStep(used, source: families.lazy.compactMap(\.tcp.source).first, underlying: underlying)] + proxySteps + [dns]
        if let policy { steps.append(rules(host: host, port: String(port), app: app, policy: policy)) }
        steps.append(familyStep("IPv4", ipv4, host: host, port: port, available: path.supportsIPv4))
        steps.append(familyStep("IPv6", ipv6, host: host, port: port, available: path.supportsIPv6))
        if let others = comparisonStep(await compared, reached: reached) { steps.append(others) }

        // TLS and HTTP, through the system's own path, proxy included.
        let secure = families.lazy.compactMap { probe -> String? in
            guard probe.tcp.outcome == .connected, let tls = probe.tls else { return nil }
            return switch tls.outcome {
            case .connected: nil
            case .tlsFailed(let message), .failed(let message): message
            default: "it didn’t finish within 5 seconds"
            }
        }.first
        // The exact request through the app's path, redirects followed one hop at a time.
        let web = ["http", "https"].contains(url.scheme ?? "")
        var hops: [ConnectionProbe.Hop] = []
        if !direct, route == nil, let secure {
            steps.append(DoctorStep(layer: "Secure connection", status: .failed, detail: "The secure connection failed: \(secure). A proxy, VPN or network filter may be intercepting it."))
        } else if web, direct || route != nil {
            hops = await ConnectionProbe.fetch(url, through: route?.proxy)
            steps += requestSteps(hops)
        }
        func answered(_ hop: ConnectionProbe.Hop?) -> Bool { if case .status? = hop?.answer { true } else { false } }

        // The host a redirect ends at gets its own IPv4 and IPv6 check: a download can start at one server and fail at its CDN.
        var final: (host: String, port: Int, addresses: [String])?
        if hops.count > 1, let last = hops.last, let name = last.url.host, name.lowercased() != host.lowercased() {
            let found = await resolve(name), finalPort = last.url.port ?? (last.url.scheme == "http" ? 80 : 443), secure = last.url.scheme == "https"
            final = (name, finalPort, found)
            async let f4 = path.supportsIPv4 && found.contains { !$0.contains(":") } ? probe(name, port: finalPort, version: .v4, tls: secure) : nil
            async let f6 = path.supportsIPv6 && found.contains { $0.contains(":") } ? probe(name, port: finalPort, version: .v6, tls: secure) : nil
            let (r4, r6) = await (f4, f6)
            if !found.isEmpty && path.supportsIPv4 { steps.append(familyStep("Redirect IPv4", r4, host: name, port: finalPort, available: true, named: true)) }
            if !found.isEmpty && path.supportsIPv6 { steps.append(familyStep("Redirect IPv6", r6, host: name, port: finalPort, available: true, named: true)) }
        }
        // Through a proxy that answers, a failing direct connection isn't the app's path.
        if route != nil {
            if answered(hops.first) { steps = viaProxy(steps, layers: ["IPv4", "IPv6"]) }
            if hops.count > 1, answered(hops.last) { steps = viaProxy(steps, layers: ["Redirect IPv4", "Redirect IPv6"]) }
        }

        // The direct path against the VPN or proxy path, which can keep using a network the Mac has left.
        var paths: [(via: String, direct: Bool?, through: Bool?)] = []
        if let route { paths.append((route.via, direct, hops.isEmpty ? nil : answered(hops.first))) }
        if used.vpn, let bypass = await bypass { paths.append(("the VPN (\(used.name))", bypass.outcome == ConnectionProbe.Attempt.Outcome.connected, reached)) }
        let leftovers = ConnectionProbe.leftovers(ConnectionProbe.interfaceAddresses(), active: Set(path.availableInterfaces.map(\.name)))
        let routes = paths.compactMap { pathStep(via: $0.via, over: underlying, direct: $0.direct, through: $0.through, leftovers: leftovers) }
        if let step = routes.first(where: { $0.status == .failed }) ?? routes.first { steps.append(step) }

        // An app setting that changes its path, which this check can't take.
        if let setting = appSetting(for: app, hosts: [host] + hops.compactMap(\.url.host)) {
            steps.insert(appSettingStep(setting, path: taken), at: min(steps.count, 2 + proxySteps.count))
        }

        // What the app has open to this host, or to the proxy it goes through, against the fresh connection this check makes;
        // a second look a few seconds after the first says whether bytes still arrive.
        if let running = await running {
            let wait = 3 - Date().timeIntervalSince(running.at)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let later = await OpenConnections.sample(pids: Set(running.pids)), seconds = Int(Date().timeIntervalSince(running.at).rounded())
            let relay: (host: String, port: Int, addresses: [String])? = if let proxy = route?.proxy, let endpoint = ConnectionProbe.endpoint(proxy) {
                (endpoint.host, endpoint.port, await resolve(endpoint.host))
            } else { nil }
            let targets: [(host: String, port: Int, addresses: [String])] = [final, (host, port, addresses), relay].compactMap { $0 }
            let matched = targets.lazy.map { target in (target, later.filter { target.addresses.contains($0.address.lowercased()) }) }.first { !$0.1.isEmpty }
            if case let (target, open)? = matched {
                let fresh = await ConnectionProbe.open(host: target.host, port: target.port).address
                steps.append(existingStep(running.name, host: target.host, open: open, fresh: fresh))
                let earlier = running.open.filter { target.addresses.contains($0.address.lowercased()) }
                if let transfer = transferStep(running.name, host: target.host, earlier: earlier, now: open, seconds: seconds) { steps.append(transfer) }
            } else {
                steps.append(existingStep(running.name, host: final?.host ?? host, open: [], fresh: nil))
            }
        }

        // Nothing shown keeps a query value or password, even in an error message that quotes the URL.
        let urls = [url] + hops.map(\.url)
        let shownSteps = (steps + [note].compactMap { $0 }).map { DoctorStep(layer: $0.layer, status: $0.status, detail: ConnectionProbe.scrubbed($0.detail, urls)) }
        let shownHops = hops.map { hop in
            let status: Int? = if case .status(let code) = hop.answer { code } else { nil }
            return DoctorHop(url: ConnectionProbe.redacted(hop.url), host: hop.url.host ?? "", method: hop.method, status: status,
                             error: status == nil ? ConnectionProbe.scrubbed(describe(hop.answer), urls) : nil)
        }
        let over = "over \(used.label)" + (route.map { " through \($0.via)" } ?? "")
        return report(shown, host, app, shownSteps, hops: shownHops, over: over, client: client, path: taken, failedAt: failedAt)
    }

    /// The URL to request, exactly as given, path and query included; a bare host becomes https://host.
    static func requestURL(_ target: String) -> URL? {
        URL(string: target.contains("://") ? target : "https://" + target)
    }

    /// "host:port" of a proxy URL, without its password.
    static func at(_ proxy: String) -> String {
        ConnectionProbe.endpoint(proxy).map { "\($0.host):\($0.port)" } ?? ConnectionProbe.redacted(proxy)
    }

    static func answers(proxy: String?) async -> Bool? {
        guard let proxy, let endpoint = ConnectionProbe.endpoint(proxy) else { return nil }
        return await ConnectionProbe.open(host: endpoint.host, port: endpoint.port, timeout: 3).outcome == .connected
    }

    /// The app's open connections, and when they were sampled, for a second look later.
    static func openConnections(_ app: String?) async -> (name: String, pids: [Int32], open: [OpenDestination], at: Date)? {
        guard let app else { return nil }
        let running = ConnectionProbe.processes(of: app)
        guard !running.pids.isEmpty else { return nil }
        let open = await OpenConnections.sample(pids: Set(running.pids))
        return (running.name, running.pids, open, Date())
    }

    /// Direct IPv4 or IPv6 failures kept as warnings, when the app goes through a proxy that works.
    static func viaProxy(_ steps: [DoctorStep], layers: Set<String>) -> [DoctorStep] {
        steps.map { step in
            guard layers.contains(step.layer), step.status == .failed else { return step }
            return DoctorStep(layer: step.layer, status: .warning, detail: step.detail + " Requests through the proxy don’t take this path.")
        }
    }

    static func pinned(_ host: String, port: Int, to interface: NWInterface?) async -> ConnectionProbe.Attempt? {
        guard let interface else { return nil }
        return await ConnectionProbe.open(host: host, port: port, interface: interface)
    }

    /// Asks a split-DNS resolver directly, to tell a silent private resolver from a name it doesn't know.
    static func privateLookup(_ host: String, _ resolver: ConnectionProbe.Resolver?) async -> [String]? {
        guard let resolver, resolver.domain != nil else { return nil }
        return await ConnectionProbe.directLookup(host, server: resolver.server)
    }

    static func answers(_ gateway: String?) async -> Bool? {
        guard let gateway else { return nil }
        return await CommandRunner.run("/sbin/ping", ["-c", "1", "-t", "2", gateway], timeout: 3).status == 0
    }

    static func probe(_ host: String, port: Int, version: NWProtocolIP.Options.Version, tls: Bool) async -> FamilyProbe {
        let tcp = await ConnectionProbe.open(host: host, port: port, version: version)
        guard tls, tcp.outcome == .connected else { return FamilyProbe(tcp: tcp) }
        return FamilyProbe(tcp: tcp, tls: await ConnectionProbe.open(host: host, port: port, version: version, tls: true))
    }

    static func compare(_ host: String, port: Int, over interfaces: [NWInterface]) async -> [(ConnectionProbe.Link, ConnectionProbe.Attempt)] {
        await withTaskGroup(of: (Int, ConnectionProbe.Link, ConnectionProbe.Attempt).self) { group in
            for (index, interface) in interfaces.enumerated() {
                group.addTask {
                    let attempt = await ConnectionProbe.open(host: host, port: port, interface: interface)
                    return (index, attempt.link ?? ConnectionProbe.Link(interface, expensive: false), attempt)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }

    /// The app's environment, or this process's own when no app is named and it sets a proxy (an agent's shell, say).
    static func appEnvironment(_ app: String?) -> ConnectionProbe.Environment? {
        if let app { return ConnectionProbe.environment(of: app) }
        let own = ProcessInfo.processInfo.environment
        return ConnectionProbe.proxyKeys.contains { own[$0] != nil } ? .found(name: "kilobat", values: own) : nil
    }

    // MARK: Steps

    static func interfaceStep(_ link: ConnectionProbe.Link, source: String? = nil, underlying: ConnectionProbe.Link?) -> DoctorStep {
        if link.vpn {
            return DoctorStep(layer: "Interface", status: .warning, detail: "Through a VPN (\(link.name))" + (underlying.map { " on \($0.label)" } ?? "") + ". It can block or reroute this connection.")
        }
        return DoctorStep(layer: "Interface", status: .ok, detail: "Connections leave through \(link.label)" + (source.map { " from \($0)" } ?? "") + "."
                          + (link.expensive ? " macOS marks it metered, as it does a phone hotspot; carrier networks sometimes break IPv6 or block ports." : ""))
    }

    static func proxyStep(_ system: ConnectionProbe.SystemProxy) -> DoctorStep {
        let pac = system.pac.map { $0 == "set as a script" ? "The PAC script" : "The PAC file at \($0)" }
        if system.pacFailed {
            return DoctorStep(layer: "Proxy", status: .warning, detail: "A PAC file is set (\(system.pac ?? "")), but it couldn’t be loaded. Apps may connect directly or fail.")
        }
        if let proxy = system.proxy {
            return DoctorStep(layer: "Proxy", status: .warning, detail: (pac.map { "\($0) sends this address through \(proxy)." } ?? "A system proxy is set (\(proxy)).") + " It can block or reroute this connection.")
        }
        return DoctorStep(layer: "Proxy", status: .ok, detail: pac.map { "\($0) sends this address direct." } ?? "No system proxy for this address.")
    }

    /// Whether the app's environment sets a different proxy from the system, as command-line tools read it.
    static func appProxyStep(_ environment: ConnectionProbe.Environment?, app: String?, url: URL, system: String?, answers: Bool?) -> DoctorStep? {
        let none = "the system uses " + (system ?? "none")
        switch environment {
        case nil, .unreadable?: return nil
        case .notRunning?:
            let name = app.map { $0.hasPrefix("process:") ? String($0.dropFirst(8)) : $0 } ?? "The app"
            return DoctorStep(layer: "App proxy", status: .skipped, detail: "\(name) isn’t running, so its proxy settings weren’t checked.")
        case .found(let name, let values)?:
            guard let proxy = ConnectionProbe.environmentProxy(values, for: url) else {
                return system == nil ? DoctorStep(layer: "App proxy", status: .ok, detail: "\(name) sets no proxy variables, and the system uses no proxy.")
                    : DoctorStep(layer: "App proxy", status: .warning, detail: "\(name) sets no proxy variables, but \(none). Tools that ignore the system proxy, as most command-line tools do, connect directly.")
            }
            if proxy.bypassed {
                return DoctorStep(layer: "App proxy", status: system == nil ? .ok : .warning, detail: "\(name) skips its proxy for this host (\(proxy.variable)); \(none).")
            }
            let setting = "\(name) uses \(proxy.variable)=\(proxy.value) from its environment", endpoint = ConnectionProbe.endpoint(proxy.value)
            let at = endpoint.map { "\($0.host):\($0.port)" } ?? proxy.value
            if answers == false { return DoctorStep(layer: "App proxy", status: .failed, detail: "\(setting), but nothing answers at \(at).") }
            if system?.lowercased() == at.lowercased() { return DoctorStep(layer: "App proxy", status: .ok, detail: "\(setting), the same proxy as the system.") }
            return DoctorStep(layer: "App proxy", status: .warning, detail: "\(setting); \(none).")
        }
    }

    /// A proxy the person says the app uses, from the app's own settings.
    static func namedProxyStep(_ proxy: String, app: String?, system: String?, answers: Bool?) -> DoctorStep {
        let address = at(proxy), setting = "\(app ?? "The app") uses its own proxy at \(address), as you said"
        if answers == false { return DoctorStep(layer: "App proxy", status: .failed, detail: "\(setting), but nothing answers there.") }
        let through = ConnectionProbe.redacted(proxy) == proxy ? " The request below goes through it." : " It needs a password, so Kilobat only checked that it answers."
        if system?.lowercased() == address.lowercased() { return DoctorStep(layer: "App proxy", status: .ok, detail: "\(setting), the same proxy as the system." + through) }
        return DoctorStep(layer: "App proxy", status: .warning, detail: "\(setting); the system uses \(system ?? "none"), so a browser or speed test takes another path." + through)
    }

    /// `named` puts the host before the address, for a host other than the one asked about.
    static func familyStep(_ layer: String, _ probe: FamilyProbe?, host: String, port: Int, available: Bool, named: Bool = false) -> DoctorStep {
        let family = layer.replacingOccurrences(of: "Redirect ", with: "")
        guard available else { return DoctorStep(layer: layer, status: .skipped, detail: "This network has no \(family).") }
        guard let probe, probe.tcp.outcome != .noAddress else { return DoctorStep(layer: layer, status: .skipped, detail: "\(host) has no \(family) address.") }
        let address = probe.tcp.address.map { named ? "\(host) at \($0)" : $0 } ?? host
        switch probe.tcp.outcome {
        case .connected: break
        case .refused: return DoctorStep(layer: layer, status: .failed, detail: "\(address) refused the connection on port \(port).")
        case .timedOut: return DoctorStep(layer: layer, status: .failed, detail: "No answer from \(address) on port \(port) within 5 seconds.")
        case .failed(let message), .tlsFailed(let message): return DoctorStep(layer: layer, status: .failed, detail: "Couldn’t connect to \(address): \(message).")
        case .noAddress: break
        }
        let connected = "\(address): connected in \(probe.tcp.ms) ms"
        switch probe.tls?.outcome {
        case nil: return DoctorStep(layer: layer, status: .ok, detail: connected + ".")
        case .connected?: return DoctorStep(layer: layer, status: .ok, detail: connected + ", secure connection in \(probe.tls?.ms ?? 0) ms.")
        case .tlsFailed(let message)?, .failed(let message)?: return DoctorStep(layer: layer, status: .failed, detail: connected + ", but the secure connection failed: \(message).")
        default: return DoctorStep(layer: layer, status: .failed, detail: connected + ", but the secure connection didn’t finish within 5 seconds.")
        }
    }

    /// The same connection pinned to each interface, when the Mac has more than one (Wi-Fi and a tethered iPhone, say).
    static func comparisonStep(_ results: [(ConnectionProbe.Link, ConnectionProbe.Attempt)], reached: Bool) -> DoctorStep? {
        guard results.count > 1 else { return nil }
        let works = results.filter { $0.1.outcome == .connected }.map(\.0.label), fails = results.filter { $0.1.outcome != .connected }.map(\.0.label)
        if !reached, !works.isEmpty {
            return DoctorStep(layer: "Other networks", status: .warning, detail: "It connects over \(works.joined(separator: " and "))"
                              + (fails.isEmpty ? " when it skips the VPN." : ", but not over \(fails.joined(separator: " or "))."))
        }
        return DoctorStep(layer: "Other networks", status: .ok, detail: results.map { link, attempt in
            attempt.outcome == .connected ? "\(link.label) connects in \(attempt.ms) ms" : "\(link.label) doesn’t connect"
        }.joined(separator: "; ") + ".")
    }

    /// A failed lookup, told apart: a private resolver that doesn't answer, the Mac's DNS against 1.1.1.1, or a name nobody knows.
    static func dnsFailure(_ host: String, resolver: ConnectionProbe.Resolver?, private answer: [String]?, public open: [String]?) -> DoctorStep {
        func failed(_ detail: String) -> DoctorStep { DoctorStep(layer: "DNS", status: .failed, detail: detail) }
        if let resolver, let domain = resolver.domain {
            let goes = "\(host) goes to \(resolver.server), the private resolver for \(domain)"
            switch answer {
            case nil: return failed(goes + ", and it doesn’t answer." + (open == nil ? "" : " Public DNS works."))
            case let found? where !found.isEmpty: return failed(goes + ", which knows it (\(found.prefix(2).joined(separator: ", "))), but macOS didn’t get the answer.")
            default: return failed(goes + ", which doesn’t know it.")
            }
        }
        let mine = resolver.map { " with your DNS (\($0.server))" } ?? " with your DNS"
        return switch open {
        case let found? where !found.isEmpty: failed("\(host) didn’t resolve\(mine), but 1.1.1.1 resolves it to \(found.prefix(2).joined(separator: ", ")).")
        case []?: failed("\(host) didn’t resolve\(mine) or at 1.1.1.1.")
        default: failed("\(host) didn’t resolve to an address.")
        }
    }

    /// The direct path against the VPN or proxy path. A tunnel that fails while the direct path works is the tunnel's
    /// problem; `leftovers` are addresses still held by network ports macOS no longer uses, which a tunnel may keep using.
    static func pathStep(via: String, over link: ConnectionProbe.Link?, direct: Bool?, through: Bool?, leftovers: [String]) -> DoctorStep? {
        guard let direct, let through else { return nil }
        let over = link.map { " over \($0.label)" } ?? ""
        switch (direct, through) {
        case (true, false):
            let left = leftovers.isEmpty ? "" : " \(leftovers.joined(separator: " and ")) still \(leftovers.count == 1 ? "has an address" : "have addresses") from a network that’s no longer in use."
            return DoctorStep(layer: "Direct path", status: .failed, detail: "Direct connections\(over) work; through \(via) they fail." + left)
        case (true, true): return DoctorStep(layer: "Direct path", status: .ok, detail: "Direct connections\(over) work, and so do connections through \(via).")
        case (false, true): return DoctorStep(layer: "Direct path", status: .ok, detail: "Through \(via) it works; direct connections\(over) don’t. Company networks often allow only their proxy.")
        case (false, false): return DoctorStep(layer: "Direct path", status: .warning, detail: "Connections fail both directly\(over) and through \(via).")
        }
    }

    static func serverStep(_ answer: ConnectionProbe.Answer) -> DoctorStep {
        switch answer {
        case .secureFailed(let message):
            return DoctorStep(layer: "Secure connection", status: .failed, detail: "The secure connection failed: \(message) A proxy, VPN or network filter may be intercepting it.")
        case .failed(let message), .closed(let message): return DoctorStep(layer: "Request", status: .failed, detail: message)
        case .status(let code):
            let (status, detail): (DoctorStep.Status, String) = switch code {
            case 200..<400: (.ok, "The server answered (HTTP \(code)).")
            case 401, 403: (.warning, "The server answered but refused access (HTTP \(code)). The network is fine; it wants a login, a key or permission.")
            case 407: (.failed, "A proxy wants credentials (HTTP 407).")
            case 429: (.warning, "The server is rate limiting you (HTTP 429). Wait before retrying.")
            case 500..<600: (.failed, "The server has a problem of its own (HTTP \(code)).")
            default: (.warning, "The server answered with HTTP \(code).")
            }
            return DoctorStep(layer: "Server", status: status, detail: detail)
        }
    }

    /// The final answer, and with redirects, each hop by host. A hop that fails is named: the first server can answer while the one it sends you to doesn't.
    static func requestSteps(_ hops: [ConnectionProbe.Hop]) -> [DoctorStep] {
        guard let last = hops.last else { return [] }
        var answer = serverStep(last.answer)
        if let head = last.head {
            if case .status(let code) = last.answer, (200..<400).contains(code) {
                answer = DoctorStep(layer: "Server", status: .ok, detail: "The server refuses HEAD requests but answers GET (HTTP \(code)).")
            } else {
                answer = DoctorStep(layer: answer.layer, status: answer.status, detail: "The server refuses HEAD requests (\(describe(head))), and GET fails too. " + answer.detail)
            }
        }
        guard hops.count > 1 else { return [answer] }
        let chain = hops.map { "\($0.url.host ?? "?") (\(describe($0.answer)))" }.joined(separator: " → "), target = last.url.host ?? "another host"
        if last.location != nil { return [DoctorStep(layer: "Redirects", status: .failed, detail: "More than \(hops.count - 1) redirects: \(chain).")] }
        if answer.status == .failed { return [DoctorStep(layer: "Redirects", status: .failed, detail: "This address redirects to \(target), which fails: \(chain)."), answer] }
        return [DoctorStep(layer: "Redirects", status: .ok, detail: chain + "."), answer]
    }

    static func describe(_ answer: ConnectionProbe.Answer) -> String {
        switch answer {
        case .status(let code): "HTTP \(code)"
        case .secureFailed(let message), .closed(let message), .failed(let message): message.hasSuffix(".") ? String(message.dropLast()) : message
        }
    }

    /// The app's open connections to the host against the fresh one this check made: one opened earlier can use the other IP version
    /// or another server, and a fresh check can't see how it's doing.
    static func existingStep(_ name: String, host: String, open: [OpenDestination], fresh: String?) -> DoctorStep {
        let watch = " A fresh check can’t see how an open connection is doing; watch it in \(name)’s bandwidth panel or with kilobat bandwidth \"\(name)\"."
        guard !open.isEmpty else { return DoctorStep(layer: "Open connections", status: .skipped, detail: "\(name) has no connection open to \(host)’s current addresses.") }
        func family(_ address: String) -> String { address.contains(":") ? "IPv6" : "IPv4" }
        let count = open.reduce(0) { $0 + $1.connections }, families = Set(open.map { family($0.address) }).sorted()
        var detail = "\(name) has \(count == 1 ? "a connection" : "\(count) connections") open to \(host): "
            + open.prefix(3).map { "\($0.address) (\(family($0.address)), ↓ \(TrafficFormat.bytes($0.received)))" }.joined(separator: ", ") + "."
        var status = DoctorStep.Status.ok
        if let fresh, !families.contains(family(fresh)) {
            status = .warning
            detail += " It uses \(families.joined(separator: " and ")); this check’s fresh connection chose \(family(fresh)) (\(fresh)), so the results here may not be what the app sees."
        } else if let fresh, !open.contains(where: { $0.address == fresh }) {
            detail += " This check’s fresh connection reached another server (\(fresh))."
        }
        return DoctorStep(layer: "Open connections", status: status, detail: detail + watch)
    }

    /// Whether bytes still arrive on the app's open connections to the host, from two samples `seconds` apart. Only connections
    /// open in both are compared. A quiet connection can be a stalled download or a finished one kept open, so quiet is never finished.
    static func transferStep(_ name: String, host: String, earlier: [OpenDestination], now: [OpenDestination], seconds: Int) -> DoctorStep? {
        let pairs = now.compactMap { after in earlier.first { $0.address == after.address && $0.connections == after.connections }.map { (before: $0, after: after) } }
        guard !pairs.isEmpty, seconds > 0 else { return nil }
        let arrived = pairs.reduce(UInt64(0)) { $0 + ($1.after.received > $1.before.received ? $1.after.received - $1.before.received : 0) }
        let total = pairs.reduce(UInt64(0)) { $0 + $1.after.received }
        // Under 1 KB/s is keep-alives and stragglers, not a download moving.
        if arrived >= UInt64(seconds) * 1024 {
            return DoctorStep(layer: "Transfer", status: .ok, detail: "\(name) is receiving from \(host): ↓ \(TrafficFormat.bytes(arrived)) in \(seconds) seconds.")
        }
        return DoctorStep(layer: "Transfer", status: .warning, detail: "\(name)’s open connection to \(host) received \(arrived == 0 ? "nothing" : "only " + TrafficFormat.bytes(arrived)) in \(seconds) seconds"
                          + " (↓ \(TrafficFormat.bytes(total)) since it opened), so the transfer went quiet. That can be a stalled download, or a finished one whose connection is still open; Kilobat can’t tell which, so this doesn’t mean the download finished.")
    }

    /// A note that these checks ran on the Mac, when the code that fails runs somewhere else or the name looks like it lives there.
    /// A known provider picked as the app gets its note without `context`, worded as an if: Warp also runs commands on the Mac.
    static func contextStep(_ context: Context?, host: String, url: String, provider: Provider? = nil, addresses: [String] = [],
                            resolver: ConnectionProbe.Resolver? = nil) -> DoctorStep? {
        let inside = looksInternal(host)
        guard let place = context ?? (provider != nil ? .provider : inside ? .container : nil) else { return nil }
        // Quoted so a shell doesn't read the query's ? and [redacted] as a pattern.
        let url = url.contains("?") ? "'\(url)'" : url
        let machine: String, command: String
        switch place {
        case .container: (machine, command) = ("A container", "docker run --rm " + (inside ? "--network <network> " : "") + "curlimages/curl -sv \(url)")
        case .vm: (machine, command) = ("A VM", "curl -sv \(url)")
        case .remote: (machine, command) = ("A remote machine", "ssh <host> curl -sv \(url)")
        case .provider: return providerStep(provider, declared: context == .provider, reach: privateReach(host, addresses: addresses, resolver: resolver))
        }
        var detail = (context == nil ? "\(host) looks like a name inside a container or cluster network. " : "") + "These checks ran on this Mac. \(machine) has its own network, DNS and proxy."
        if place == .container && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) {
            detail += " Inside a container, localhost is the container itself; use host.docker.internal to reach the Mac."
        }
        return DoctorStep(layer: "Context", status: .skipped, detail: detail + " Check from there: " + command)
    }

    /// The provider's servers make the request, so this Mac's success doesn't carry over; a private target is out of their reach.
    /// Nothing here is measured from the provider's side.
    static func providerStep(_ provider: Provider?, declared: Bool, reach: String?) -> DoctorStep {
        let servers = provider?.servers ?? "the provider’s servers"
        let claim = provider.map { (declared ? "" : "If this is \($0.name)’s \($0.feature): ") + "\($0.name)’s docs (\($0.checked)) say \($0.claim)." }
            ?? "The provider’s servers make this request, not this Mac."
        let unmeasured = " These checks ran on this Mac; Kilobat can’t test from \(servers)"
        guard let reach else { return DoctorStep(layer: "Provider", status: .skipped, detail: claim + unmeasured + ", so whether they reach it is unknown.") }
        return DoctorStep(layer: "Provider", status: declared ? .failed : .warning, detail: claim + " \(reach), so \(servers) can’t reach it." + unmeasured + ".")
    }

    /// Why only this Mac or its private networks can reach the host, in words; nil for a public name or address.
    static func privateReach(_ host: String, addresses: [String], resolver: ConnectionProbe.Resolver?) -> String? {
        let name = host.lowercased()
        func kind(_ address: String) -> String? {
            guard let bytes = AddressRange.parse(address), GeoIP.isPrivate(bytes) else { return nil }
            return bytes[0] == 127 || bytes == [UInt8](repeating: 0, count: 15) + [1] ? "this Mac itself" : "a private address"
        }
        if name == "localhost" || name.hasSuffix(".localhost") { return "\(host) is this Mac itself" }
        if AddressRange.parse(name) != nil { return kind(name).map { "\(host) is \($0)" } }
        if let (address, place) = addresses.lazy.compactMap({ address in kind(address).map { (address, $0) } }).first { return "\(host) resolves to \(address), \(place)" }
        if let resolver, resolver.domain != nil { return "\(host) resolves only through private DNS (\(resolver.server))" }
        if !name.contains(".") || [".local", ".lan", ".home.arpa", ".internal", ".ts.net"].contains(where: name.hasSuffix) { return "\(host) is a name only private networks know" }
        return nil
    }

    /// Single-label names and cluster or container suffixes, which resolve only inside their own network.
    static func looksInternal(_ host: String) -> Bool {
        let host = host.lowercased()
        guard AddressRange.parse(host) == nil, host != "localhost" else { return false }
        return !host.contains(".") || [".internal", ".cluster.local", ".svc", ".docker"].contains { host.hasSuffix($0) }
    }

    /// The same decision the filter makes for this host and app (`FilterPolicy`), in words.
    static func rules(host: String, port: String, app: String?, policy: Policy) -> DoctorStep {
        let preferences = policy.preferences, profile = preferences.profile.rawValue
        let enforced = policy.filterActive ? "" : " The network filter is off, so it isn’t enforced right now."
        let rules = FilterPolicy(FilterController.policy(preferences, budgetReached: policy.budgetReached, metered: policy.metered))
        // An address typed as the target is matched as the remote address, as the filter would see it.
        let address = AddressRange.parse(host) != nil ? host : nil
        let decision = rules.decide(.init(app: app, process: app?.replacingOccurrences(of: "process:", with: "") ?? "", host: host, address: address, port: port),
                                    appleSigned: { app?.hasPrefix("com.apple.") == true })
        let blocked: DoctorStep.Status = policy.filterActive ? .failed : .warning
        func step(_ status: DoctorStep.Status, _ detail: String) -> DoctorStep {
            DoctorStep(layer: "Kilobat rules", status: status, detail: detail + (status == .ok ? "" : enforced))
        }
        switch decision.reason {
        case .filterOff, .unrestricted: return step(.ok, "The Unrestricted profile allows everything.")
        case .connectionRule(let rule): return rule.allowed ? step(.ok, "A connection rule allows this.") : step(blocked, "A connection rule in \(profile) blocks this.")
        case .blocklist(let entry): return step(blocked, "\(host) matches \(entry) on your blocklist.")
        case .temporaryRule(let rule):
            let until = rule.expires.formatted(date: .omitted, time: .shortened)
            return rule.allowed ? step(.ok, "A temporary rule allows this app until \(until).") : step(blocked, "A temporary rule blocks this app until \(until).")
        case .budget: return step(blocked, "This network’s data budget is used up, which stops new connections.")
        case .quota: return step(blocked, "This app used up its data quota, which stops its new connections until the quota resets.")
        case .updaterPaused(let name):
            return step(blocked, "\(name) is an updater, and Kilobat pauses updaters while this network is metered. Allow it for a while, or turn off pausing updaters.")
        case .appRule(let allowed): return allowed ? step(.ok, "This app is allowed in the \(profile) profile.") : step(blocked, "This app is blocked in the \(profile) profile.")
        case .recentDecision(let allowed): return allowed ? step(.ok, "You allowed this app when asked.") : step(blocked, "You blocked this app when asked.")
        case .appleSoftware: return step(.ok, "Apple software is allowed in \(profile).")
        case .askNewApps: return step(.warning, "Kilobat asks before this app’s first connection. Answer in the approval window.")
        case .newAppDefault(let allowed):
            return allowed ? step(.ok, "Nothing in Kilobat blocks this app here.") : step(blocked, "New apps are blocked in \(profile), and this app has no rule.")
        case .noAppRule: return step(.ok, "Nothing in Kilobat blocks this.")
        }
    }

    /// The verdict covers this request from this Mac over the path tested (`over`, such as "over Wi-Fi (en0)"), nothing wider.
    /// When the app has a setting this check can't take, or its request went through its own proxy and failed, the verdict
    /// says whether the network works apart from whether the app's request does.
    static func report(_ target: String, _ host: String, _ app: String?, _ steps: [DoctorStep], hops: [DoctorHop] = [], over: String? = nil,
                       client: DoctorClient? = nil, path taken: DoctorPath? = nil, failedAt: Date? = nil, date: Date = Date()) -> DoctorReport {
        func step(_ layer: String) -> DoctorStep? { steps.first { $0.layer == layer } }
        // An app that isn't installed has only its bundle ID; a known one keeps its name.
        let setting = appSetting(for: app, hosts: [host] + hops.map(\.host)), known = client.flatMap { $0.name == $0.id ? nil : $0.name } ?? setting?.name
        let name = known ?? "the app"
        var taken = taken
        if let setting { taken?.untested = "\(setting.name)’s \(setting.setting)" }
        let ownRoute = taken.flatMap { [.appProxy, .environmentProxy].contains($0.kind) ? via($0, app: known) : nil }
        let failed = steps.first { $0.status == .failed }, routed = step("Provider")
        // A declared provider's note stands in for the Context note; a guessed one ("If this is …") doesn't.
        let context = step("Context") ?? routed.flatMap { $0.status == .skipped && !$0.detail.hasPrefix("If ") ? $0 : nil }
        let provider = provider(for: app), servers = provider?.servers ?? "the provider’s servers"
        // Options that work wherever the request comes from: never a tunnel or exposure made for the person, never SSH into the provider.
        let options = "Point it at an endpoint you control with a public address, behind HTTPS and a key, or use "
            + (provider?.route ?? "a route the provider supports for private endpoints, if it has one") + ". This Mac’s DNS, firewall or VPN settings won’t change it."
            + (provider.map { " Source: \($0.name)’s docs (\($0.checked)), \($0.docs)" } ?? "")
        let detour = step("Interface")?.status == .warning || step("Proxy")?.status == .warning
        let path = over.map { " " + $0 } ?? "", redirect = hops.count > 1 ? hops.last?.host ?? "another server" : "another server"
        // Whether the code may run somewhere these checks didn't reach.
        var elsewhere = false
        let (verdict, next): (String, String)
        let tunnel = step("Direct path").flatMap { $0.status == .failed ? $0 : nil }
        func broken(_ layer: String) -> String {
            layer == "IPv6"
                ? "Apps that prefer IPv6 can hang or keep reconnecting. In System Settings › Network, open this network’s Details › TCP/IP and set Configure IPv6 to Link-local only, or ask the network owner to fix IPv6."
                : "Apps that use IPv4 can hang or keep reconnecting. Reconnect to the network, or ask the network owner to fix IPv4."
        }
        let elsewhereNext = "The first server answers; the one it sends you to doesn’t. Try another network, or turn off a VPN or filter that may block it."
        switch failed?.layer {
        case "Network": (verdict, next) = ("Your Mac isn’t connected.", "Check Wi-Fi or the cable, then try again.")
        case "Provider": (verdict, next) = ("This works from this Mac\(path), but \(servers) can’t reach a private address.", options)
        case let layer? where tunnel != nil && !["DNS", "Kilobat rules"].contains(layer) && ownRoute != nil && !tunnel!.detail.contains("through the VPN ("):
            let own = "So \(name)’s own path stops it, not this Mac’s connection. "
            (verdict, next) = ("The network is fine: direct connections work. This request through \(ownRoute!) fails.", setting.map { own + settingAdvice($0) }
                ?? own + "Check that proxy, or \(name)’s proxy setting, then try again. Kilobat doesn’t change another app’s settings.")
        case let layer? where tunnel != nil && !["DNS", "Kilobat rules"].contains(layer):
            (verdict, next) = ("Direct connections work; traffic through the VPN or proxy fails.", tunnel!.detail.contains("no longer in use")
                ? "It may still be using the network you left. Restart its tunnel or the proxy app, then try again."
                : "Restart its tunnel or the proxy app, or check the app’s own proxy setting, then try again.")
        case "Redirects" where failed?.detail.hasPrefix("More than") == true:
            (verdict, next) = ("This address redirects too many times.", "The redirects loop or run too deep. Check the address, or get a fresh link if it expires.")
        case let layer? where ["Redirects", "Redirect IPv4", "Redirect IPv6"].contains(layer):
            if let family = ["IPv6", "IPv4"].first(where: { step("Redirect " + $0)?.status == .failed }) {
                let other = family == "IPv4" ? "IPv6" : "IPv4"
                (verdict, next) = step("Redirect " + other)?.status == .ok
                    ? ("This address redirects to \(redirect), which works over \(other) but not \(family).", broken(family))
                    : ("This address redirects to \(redirect), which can’t be reached from here.", elsewhereNext)
            } else if step("Server")?.status == .failed {
                (verdict, next) = ("This address redirects to \(redirect), which has a problem.", "The network gets there; that server answered with an error of its own. Try again later.")
            } else {
                (verdict, next) = ("This address redirects to \(redirect), which fails.", elsewhereNext)
            }
        case "DNS" where failed?.detail.contains("private resolver") == true:
            let answers = failed?.detail.contains("doesn’t answer") == true
            (verdict, next) = (answers ? "Private DNS isn’t answering." : "The private resolver can’t resolve it.", answers
                ? "Reconnect the VPN or tool that provides it (a company VPN, Tailscale or NetBird, say), then try again."
                : "Check the name, and that this Mac is allowed to see it on that private network.")
        case "App proxy": (verdict, next) = ("The app’s proxy isn’t answering.", failed?.detail.contains("as you said") == true
            ? "Start that proxy, or check the proxy setting in the app."
            : "Start the proxy it points to, or remove the variable from the app’s environment (often set in a shell profile), then restart the app.")
        case "DNS" where failed?.detail.contains("1.1.1.1 resolves") == true:
            (verdict, next) = ("Your DNS server can’t resolve it.", "Switch DNS to Cloudflare or Google in the Connection tab, or ask the network owner.")
        case "DNS":
            elsewhere = true
            (verdict, next) = (context == nil ? "The name doesn’t resolve." : "The name doesn’t resolve on this Mac.", "Check the spelling. If other sites work, switch DNS to Cloudflare or Google in the Connection tab and try again.")
        case "Kilobat rules": (verdict, next) = ("Kilobat is blocking it.", "Allow the app or remove the rule in Tools › Diagnostics & rules, or switch profile.")
        case let layer? where layer == "IPv4" || layer == "IPv6":
            let other = layer == "IPv4" ? "IPv6" : "IPv4"
            if step(other)?.status == .ok {
                (verdict, next) = ("\(other) works, but \(layer) is broken for this host.", broken(layer))
            } else if step("Secure connection")?.status == .failed {
                (verdict, next) = ("Something is interfering with the secure connection.", "Try with the VPN, proxy or other network filters off.")
            } else if let others = step("Other networks"), others.status == .warning {
                (verdict, next) = ("The server can’t be reached over this network.", others.detail + " Switch to it, or ask the owner of this network what blocks it.")
            } else {
                elsewhere = true
                (verdict, next) = ("The server can’t be reached.", detour ? "Try with the VPN or proxy off. If it still fails, the server or a firewall on the way is refusing it." : "The server may be down or a firewall on the way blocks it. Try another network to tell which.")
            }
        case "Secure connection": (verdict, next) = ("Something is interfering with the secure connection.", "Try with the VPN, proxy or other network filters off.")
        case "Server": (verdict, next) = ("The server is having problems.", "The network gets there; the server answered with an error of its own. Try again later.")
        case "Request":
            elsewhere = true
            (verdict, next) = ("The request failed.", "Try again; if it keeps failing, try another network.")
        case .some, .none:
            if routed?.status == .warning {
                (verdict, next) = ("This works from this Mac\(path), but if \(provider?.name ?? "the provider") makes the request from its servers, they can’t reach a private address.", options)
            } else if let server = steps.first(where: { $0.layer == "Server" && $0.status == .warning }) {
                let refused = server.detail.contains("refused access") || server.detail.contains("rate limiting")
                (verdict, next) = refused
                    ? ("This Mac reaches the server\(path), but it refuses this request.", "It wants a login, a key or a slower pace. Some servers limit by address or region, so another network can get another answer.")
                    : ("This Mac reaches the server\(path), but it answered with an error.", "Check the address, including its path and query, or try the site’s home page.")
            } else if let quiet = step("Transfer"), quiet.status == .warning {
                // A quiet transfer is never reported as finished.
                (verdict, next) = ((setting == nil ? "This request works from this Mac\(path)" : "The network reaches \(host) from this Mac\(path)") + " right now, but \(name)’s open transfer went quiet.",
                                   "Quiet isn’t finished: Kilobat can’t tell a stalled download from a completed one. Check the download in \(name); if it stopped, pause and resume it there."
                                   + (setting.map { " " + settingAdvice($0) } ?? ""))
            } else if let setting {
                (verdict, next) = ("The network reaches \(host) from this Mac\(path) right now, but this check didn’t go through \(name)’s \(setting.setting).",
                                   "So it doesn’t show the request works in \(name). " + settingAdvice(setting))
            } else if let direct = step("Direct path"), direct.status == .ok, direct.detail.hasPrefix("Through ") {
                (verdict, next) = ("This request works through the proxy, not directly.", "Apps that use that proxy reach it; apps that connect directly, as many command-line tools do, fail here. Point those at the proxy with HTTPS_PROXY, or ask the network owner.")
            } else if step("Open connections")?.status == .warning {
                (verdict, next) = ("This request works from this Mac\(path) right now, but the app’s open connection takes another path.", "A transfer that stays slow or stuck may do better on a new connection: pause and resume it, or restart it in the app.")
            } else if step("App proxy")?.status == .warning {
                (verdict, next) = ("This request works from this Mac\(path) right now.", "The app’s proxy differs from the system’s, so a browser or speed test doesn’t take the app’s path. If the app still can’t connect, check its proxy setting.")
            } else {
                elsewhere = true
                (verdict, next) = ("This request works from this Mac\(path) right now.", "That covers this request on this path only. If the app still fails, it may take another path: its own proxy setting (check it with kilobat why --proxy), a sandbox, or a container or remote machine.")
            }
        }
        var after = ""
        if let failedAt, !steps.contains(where: { $0.status == .failed }), date.timeIntervalSince(failedAt) > 60 {
            after = " This check ran after \(name) failed at \(failedAt.formatted(date: .omitted, time: .shortened)), so it can’t show what happened then."
        }
        return DoctorReport(target: target, host: host, app: app, verdict: verdict, next: (elsewhere ? context?.detail ?? next : next) + after, steps: steps, hops: hops, date: date,
                            client: client, method: hops.first?.method, path: taken, failedAt: failedAt)
    }

    static func resolve(_ host: String) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &info) == 0 else { return [] }
            defer { freeaddrinfo(info) }
            var addresses: [String] = [], cursor = info
            while let entry = cursor {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self); if !addresses.contains(address) { addresses.append(address) }
                }
                cursor = entry.pointee.ai_next
            }
            return addresses
        }.value
    }
}
