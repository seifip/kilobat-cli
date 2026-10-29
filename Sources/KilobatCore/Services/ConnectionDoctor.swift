import Foundation
import Darwin

/// One layer of a connection check.
public struct DoctorStep: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, warning, failed, skipped }
    public var id: String { layer }
    public let layer: String
    public let status: Status
    public let detail: String
}

/// Why something can't connect: each layer from the Mac's own link to the server's answer, and the first that broke.
public struct DoctorReport: Codable, Sendable {
    public let target: String
    public let host: String
    public let app: String?
    public let verdict: String
    public let next: String
    public let steps: [DoctorStep]
    public let date: Date
    public var ok: Bool { !steps.contains { $0.status == .failed } }
}

/// Walks the layers in order: local network, VPN and proxy, DNS, Kilobat's own rules, TCP, then TLS and HTTP.
/// It checks from this Mac only; a sandbox, VM or remote machine needs its own check.
public enum ConnectionDoctor {
    public struct Policy: @unchecked Sendable {
        public let preferences: SavedPreferences
        public let filterActive: Bool
        public let budgetReached: Bool
        public init(preferences: SavedPreferences, filterActive: Bool, budgetReached: Bool) {
            self.preferences = preferences; self.filterActive = filterActive; self.budgetReached = budgetReached
        }
    }

    public static func run(_ target: String, app: String? = nil, policy: Policy? = nil) async -> DoctorReport {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
        guard let url, let host = url.host, ExpertTools.validHost(host) else {
            return DoctorReport(target: trimmed, host: trimmed, app: app, verdict: "That doesn’t look like a website or host.", next: "Enter a domain such as example.com or a full https:// address.", steps: [], date: Date())
        }
        let port = url.port ?? (url.scheme == "http" ? 80 : 443)
        var steps: [DoctorStep] = []

        // 1. The Mac's own link.
        let route = await CommandRunner.run("/sbin/route", ["-n", "get", "default"], timeout: 3).output
        let gateway = DiagnosticProbe.matches(#"gateway:\s+(\S+)"#, in: route).first
        let interface = DiagnosticProbe.matches(#"interface:\s+(\S+)"#, in: route).first
        if interface == nil {
            steps.append(DoctorStep(layer: "Network", status: .failed, detail: "This Mac has no route to the internet."))
            return report(trimmed, host, app, steps)
        }
        if let gateway {
            let ping = await CommandRunner.run("/sbin/ping", ["-c", "1", "-t", "2", gateway], timeout: 3)
            steps.append(DoctorStep(layer: "Network", status: ping.status == 0 ? .ok : .warning,
                                    detail: ping.status == 0 ? "Connected through \(interface ?? "the network"); the router answers." : "Connected, but the router at \(gateway) didn’t answer a ping. Some routers ignore pings."))
        } else {
            steps.append(DoctorStep(layer: "Network", status: .ok, detail: "Connected through \(interface ?? "the network")."))
        }

        // 2. VPN and proxy, which change the path without changing anything else.
        var path: [String] = []
        if let interface, interface.hasPrefix("utun") || interface.hasPrefix("ipsec") || interface.hasPrefix("ppp") { path.append("traffic goes through a VPN (\(interface))") }
        if let proxy = systemProxy() { path.append("a system proxy is set (\(proxy))") }
        steps.append(DoctorStep(layer: "VPN & proxy", status: path.isEmpty ? .ok : .warning,
                                detail: path.isEmpty ? "No VPN or proxy in the way." : path.joined(separator: " and ").prefix(1).uppercased() + path.joined(separator: " and ").dropFirst() + ". It can block or reroute this connection."))

        // 3. DNS.
        let started = Date()
        let addresses = await resolve(host)
        let dnsMs = Date().timeIntervalSince(started) * 1000
        if addresses.isEmpty {
            steps.append(DoctorStep(layer: "DNS", status: .failed, detail: "\(host) didn’t resolve to an address."))
            return report(trimmed, host, app, steps)
        }
        steps.append(DoctorStep(layer: "DNS", status: dnsMs > 300 ? .warning : .ok,
                                detail: "\(host) → \(addresses.prefix(2).joined(separator: ", ")) in \(Int(dnsMs)) ms" + (dnsMs > 300 ? ", which is slow." : ".")))

        // 4. Kilobat's own rules.
        if let policy { steps.append(rules(host: host, port: String(port), app: app, policy: policy)) }

        // 5. TCP.
        let connectStart = Date()
        let tcp = await CommandRunner.run("/usr/bin/nc", ["-z", "-v", "-G", "5", host, String(port)], timeout: 7)
        let connectMs = Int(Date().timeIntervalSince(connectStart) * 1000)
        if tcp.status != 0 {
            let refused = tcp.output.lowercased().contains("refused")
            steps.append(DoctorStep(layer: "Connection", status: .failed,
                                    detail: refused ? "\(host) refused a connection on port \(port)." : "No answer from \(host) on port \(port) within 5 seconds."))
            return report(trimmed, host, app, steps)
        }
        steps.append(DoctorStep(layer: "Connection", status: .ok, detail: "Port \(port) is open; connected in \(connectMs) ms."))

        // 6. TLS and HTTP.
        guard ["http", "https"].contains(url.scheme ?? "") else { return report(trimmed, host, app, steps) }
        let address = url.scheme! + "://" + host + (url.port.map { ":\($0)" } ?? "") + (url.path.isEmpty ? "/" : url.path)
        let curl = await CommandRunner.run("/usr/bin/curl", ["--head", "--silent", "--show-error", "--max-time", "10", "--output", "/dev/null", "--write-out", "%{http_code}", "--", address], timeout: 12)
        if curl.status != 0 {
            let message = curl.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let tls = message.lowercased().contains("ssl") || message.lowercased().contains("certificate")
            steps.append(DoctorStep(layer: tls ? "Secure connection" : "Request", status: .failed,
                                    detail: tls ? "The secure connection failed: \(message.components(separatedBy: ": ").last ?? message). A proxy, VPN or network filter may be intercepting it." : message))
            return report(trimmed, host, app, steps)
        }
        let code = Int(curl.output.suffix(3)) ?? 0
        let (status, detail): (DoctorStep.Status, String) = switch code {
        case 200..<400: (.ok, "The server answered (HTTP \(code)).")
        case 401, 403: (.warning, "The server answered but refused access (HTTP \(code)). The network is fine; it wants a login, a key or permission.")
        case 407: (.failed, "A proxy wants credentials (HTTP 407).")
        case 429: (.warning, "The server is rate limiting you (HTTP 429). Wait before retrying.")
        case 500..<600: (.failed, "The server has a problem of its own (HTTP \(code)).")
        default: (.warning, "The server answered with HTTP \(code).")
        }
        steps.append(DoctorStep(layer: "Server", status: status, detail: detail))
        return report(trimmed, host, app, steps)
    }

    /// The same decision the filter makes for this host and app (`FilterPolicy`), in words.
    static func rules(host: String, port: String, app: String?, policy: Policy) -> DoctorStep {
        let preferences = policy.preferences, profile = preferences.profile.rawValue
        let enforced = policy.filterActive ? "" : " The network filter is off, so it isn’t enforced right now."
        let rules = FilterPolicy(FilterController.policy(preferences, budgetReached: policy.budgetReached))
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
        case .appRule(let allowed): return allowed ? step(.ok, "This app is allowed in the \(profile) profile.") : step(blocked, "This app is blocked in the \(profile) profile.")
        case .recentDecision(let allowed): return allowed ? step(.ok, "You allowed this app when asked.") : step(blocked, "You blocked this app when asked.")
        case .appleSoftware: return step(.ok, "Apple software is allowed in \(profile).")
        case .askNewApps: return step(.warning, "Kilobat asks before this app’s first connection. Answer in the approval window.")
        case .newAppDefault(let allowed):
            return allowed ? step(.ok, "Nothing in Kilobat blocks this app here.") : step(blocked, "New apps are blocked in \(profile), and this app has no rule.")
        case .noAppRule: return step(.ok, "Nothing in Kilobat blocks this.")
        }
    }

    static func report(_ target: String, _ host: String, _ app: String?, _ steps: [DoctorStep]) -> DoctorReport {
        let failed = steps.first { $0.status == .failed }
        let (verdict, next): (String, String)
        switch failed?.layer {
        case "Network": (verdict, next) = ("Your Mac isn’t connected.", "Check Wi-Fi or the cable, then try again.")
        case "DNS": (verdict, next) = ("The name doesn’t resolve.", "Check the spelling. If other sites work, switch DNS to Cloudflare or Google in the Connection tab and try again.")
        case "Kilobat rules": (verdict, next) = ("Kilobat is blocking it.", "Allow the app or remove the rule in Tools › Diagnostics & rules, or switch profile.")
        case "Connection": (verdict, next) = ("The server can’t be reached.", steps.contains { $0.layer == "VPN & proxy" && $0.status == .warning } ? "Try with the VPN or proxy off. If it still fails, the server or a firewall on the way is refusing it." : "The server may be down or a firewall on the way blocks it. Try another network to tell which.")
        case "Secure connection": (verdict, next) = ("Something is interfering with the secure connection.", "Try with the VPN, proxy or other network filters off.")
        case "Server": (verdict, next) = ("The server is having problems.", "It isn’t your network. Try again later.")
        case "Request": (verdict, next) = ("The request failed.", "Try again; if it keeps failing, try another network.")
        case .some, .none:
            if let server = steps.first(where: { $0.layer == "Server" && $0.status == .warning }) {
                let refused = server.detail.contains("refused access") || server.detail.contains("rate limiting")
                (verdict, next) = ("Your Mac reaches it fine.", refused ? "The server answered but wants a login, a key or a slower pace. Changing your network won’t help." : "The network works; the server answered with an error for this address. Check the address, or try the site’s home page.")
            } else {
                (verdict, next) = ("Your Mac reaches it fine.", "If an app still can’t connect, it’s inside the app: its own proxy, sandbox or a remote machine. Run this check there with kilobat why.")
            }
        }
        return DoctorReport(target: target, host: host, app: app, verdict: verdict, next: next, steps: steps, date: Date())
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
                    let address = String(cString: name); if !addresses.contains(address) { addresses.append(address) }
                }
                cursor = entry.pointee.ai_next
            }
            return addresses
        }.value
    }

    static func systemProxy() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        if (settings["HTTPSEnable"] as? Int) == 1, let host = settings["HTTPSProxy"] as? String { return host + ((settings["HTTPSPort"] as? Int).map { ":\($0)" } ?? "") }
        if (settings["ProxyAutoConfigEnable"] as? Int) == 1 { return "automatic configuration" }
        return nil
    }
}
