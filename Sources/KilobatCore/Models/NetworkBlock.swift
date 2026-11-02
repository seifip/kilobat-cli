import Foundation

/// The resolver Kilobat asks over DNS-over-HTTPS for a control answer, only while a failure is being diagnosed.
/// Asked by address, so the lookup doesn't lean on the network's own DNS, the thing under test.
public enum TrustedResolver: String, Codable, CaseIterable, Sendable, Identifiable {
    case cloudflare, quad9
    public var id: String { rawValue }
    public var url: URL {
        switch self {
        case .cloudflare: URL(string: "https://1.1.1.1/dns-query")!
        case .quad9: URL(string: "https://9.9.9.9/dns-query")!
        }
    }
    /// "Cloudflare (1.1.1.1)": a company and an address, the same in every language.
    public var name: String {
        switch self { case .cloudflare: "Cloudflare (1.1.1.1)"; case .quad9: "Quad9 (9.9.9.9)" }
    }
    public var company: String {
        switch self { case .cloudflare: "Cloudflare"; case .quad9: "Quad9" }
    }
    /// The person's choice, Cloudflare when they made none.
    public static func chosen(_ preferences: SavedPreferences?) -> TrustedResolver {
        preferences?.blockCheckResolver.flatMap(TrustedResolver.init(rawValue:)) ?? .cloudflare
    }
}

/// One DNS answer as a check needs it: addresses, a name that doesn't exist, or no usable answer.
public struct DNSAnswer: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case addresses, nxdomain, noAnswer }
    public var kind: Kind
    public var addresses: [String]
    public init(_ kind: Kind, _ addresses: [String] = []) { self.kind = kind; self.addresses = kind == .addresses ? addresses : [] }
    public static func addresses(_ list: [String]) -> DNSAnswer { list.isEmpty ? DNSAnswer(.noAnswer) : DNSAnswer(.addresses, list) }

    /// Answers that can't be the public service: loopback, unspecified, private, link-local or carrier-grade NAT space.
    public var unroutable: [String] { addresses.filter(NetworkBlockRules.unroutable) }
    public var routable: [String] { addresses.filter { !NetworkBlockRules.unroutable($0) } }
}

/// How a TLS handshake to one address went, with the name it was sent with.
public enum Handshake: String, Codable, Sendable, Equatable {
    /// Finished, and the certificate is valid for the name.
    case verified
    /// Finished, but the certificate isn't valid for the name: someone else's server answered.
    case untrusted
    /// The server answered with a TLS alert: it speaks TLS and turned the name down, which is an answer.
    case alert
    /// TCP connected, then the connection was reset during the handshake.
    case reset
    /// TCP connected, then nothing came back for the handshake.
    case timedOut
    /// TCP didn't connect at all.
    case noConnect

    /// The server spoke TLS back, whatever it said.
    public var answered: Bool { [.verified, .untrusted, .alert].contains(self) }
    /// TCP connected and the handshake died there.
    public var cut: Bool { self == .reset || self == .timedOut }
}

/// The kind of network a block was measured on, from what Kilobat knows about it; never guessed from its name.
public enum NetworkPlace: String, Codable, Sendable, Equatable, CaseIterable {
    /// Marked as home in Devices.
    case home
    /// A cellular link, or a link macOS marks metered (a phone's hotspot).
    case mobile
    /// A Wi-Fi network that showed a sign-in page, as hotel, café and airport networks do.
    case `public`
    case wifi, wired, unknown

    /// What's measured, most specific first: mobile data, a sign-in page seen, home, then the link.
    public static func of(cellular: Bool, metered: Bool, signInSeen: Bool, home: Bool, wifi: Bool, wired: Bool) -> NetworkPlace {
        if cellular || metered { return .mobile }
        if signInSeen { return .public }
        if home { return .home }
        return wifi ? .wifi : wired ? .wired : .unknown
    }

    /// "on this network", as the verdict says it.
    public var on: String {
        switch self {
        case .home: String(localized: "on your home network", comment: "Network block verdict: where it was measured")
        case .mobile: String(localized: "on this mobile data connection", comment: "Network block verdict: where it was measured, a phone's data or hotspot")
        case .public: String(localized: "on this public Wi-Fi", comment: "Network block verdict: where it was measured, a network with a sign-in page such as a hotel's")
        case .wifi: String(localized: "on this Wi-Fi network", comment: "Network block verdict: where it was measured")
        case .wired, .unknown: String(localized: "on this network", comment: "Network block verdict: where it was measured")
        }
    }

    /// The network kind in a few words, for the evidence list.
    public var title: String {
        switch self {
        case .home: String(localized: "your home network (marked as home in Devices)", comment: "Network block: the kind of network")
        case .mobile: String(localized: "mobile data (a cellular link or a phone’s hotspot)", comment: "Network block: the kind of network")
        case .public: String(localized: "public Wi-Fi (it showed a sign-in page, as hotel and café networks do)", comment: "Network block: the kind of network")
        case .wifi: String(localized: "Wi-Fi", comment: "Network block: the kind of network")
        case .wired: String(localized: "a wired network", comment: "Network block: the kind of network")
        case .unknown: String(localized: "an unknown kind of network", comment: "Network block: the kind of network")
        }
    }

    /// Neutral options only: another network, or the people who run this one. Never a way around the block.
    public var options: String {
        switch self {
        case .mobile: String(localized: "Try another network, such as Wi-Fi, or ask your mobile operator.", comment: "Network block: what to do on mobile data")
        case .home: String(localized: "Try another network, such as mobile data, or ask your internet provider.", comment: "Network block: what to do at home")
        case .public: String(localized: "Try another network, such as mobile data or roaming, or ask the venue or whoever runs this Wi-Fi.", comment: "Network block: what to do on a hotel or café Wi-Fi")
        case .wifi, .wired, .unknown: String(localized: "Try another network, such as mobile data or roaming, or ask whoever runs this network.", comment: "Network block: what to do")
        }
    }
}

/// What Kilobat measured while a failure was diagnosed, for one host. Pure input to `NetworkBlockRules.classify`.
public struct BlockMeasurements: Sendable, Equatable {
    public var host: String
    /// The Mac's own resolver, as apps get it.
    public var system: DNSAnswer
    /// The trusted resolver over DNS-over-HTTPS; nil when it wasn't asked or didn't answer.
    public var trusted: DNSAnswer?
    public var resolver: TrustedResolver = .cloudflare
    /// The Mac's resolver for a made-up name under example.com, which has none: addresses here are invented by the resolver.
    public var invented: [String] = []
    /// The Mac's resolver answers an ordinary name (example.com); false means DNS is broken, not picking on one name.
    public var systemResolves = true
    /// A handshake to the first address the Mac's resolver gave, sent with the host's name.
    public var systemHandshake: Handshake?
    /// The same with the trusted resolver's first address, when it differs.
    public var trustedHandshake: Handshake?
    /// The same address as `systemHandshake`, sent with another name: does the server answer when the name changes?
    public var controlHandshake: Handshake?
    /// A second try with the host's name, so one dropped packet doesn't read as a cut.
    public var repeatHandshake: Handshake?
    /// A plain-HTTP request to the host: what came back, before any redirect is followed.
    public var plainStatus: Int?
    public var plainLocation: String?
    public var https = true
    public init(host: String, system: DNSAnswer, trusted: DNSAnswer? = nil, resolver: TrustedResolver = .cloudflare) {
        self.host = host; self.system = system; self.trusted = trusted; self.resolver = resolver
    }
}

/// What else is known while the check runs, so a block is never claimed where something else explains the failure.
public struct BlockContext: Sendable, Equatable {
    public var serviceID: String?
    /// The service's name, such as Slack; nil for a host Kilobat has no status page for.
    public var service: String?
    /// What its status page says; nil when there's no page.
    public var status: ServiceStatus.State?
    public var statusSentence: String?
    /// A Wi-Fi sign-in page is in the way.
    public var portal = false
    /// Kilobat's own rules, Protection or kill switch stop this connection.
    public var kilobatBlocks = false
    /// The name goes to a split-DNS resolver for its domain, as a company VPN or Tailscale sets up.
    public var scopedResolver = false
    /// The VPN the checks went through: its name or interface.
    public var vpn: String?
    public var place: NetworkPlace = .unknown
    public init(serviceID: String? = nil, service: String? = nil, status: ServiceStatus.State? = nil, statusSentence: String? = nil, portal: Bool = false, kilobatBlocks: Bool = false,
                scopedResolver: Bool = false, vpn: String? = nil, place: NetworkPlace = .unknown) {
        self.serviceID = serviceID; self.service = service; self.status = status; self.statusSentence = statusSentence; self.portal = portal
        self.kilobatBlocks = kilobatBlocks; self.scopedResolver = scopedResolver; self.vpn = vpn; self.place = place
    }
}

/// "Blocked here, not down", or "not available in your region": what was measured, said only as far as it goes.
public struct NetworkBlock: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// The network in between stops it: DNS, the secure connection or a block page.
        case blocked
        /// The service itself refuses, by where the connection appears to be.
        case regionUnavailable
    }
    public enum Signal: String, Codable, Sendable, CaseIterable {
        /// The Mac's DNS says the name doesn't exist; the trusted resolver has its address.
        case nameMissing
        /// The Mac's DNS gives no answer; the trusted resolver has its address.
        case nameSilent
        /// The Mac's DNS answers with a loopback, private or unspecified address for a public name.
        case privateAnswer
        /// The Mac's DNS gives the same address it gives a made-up name.
        case inventedAnswer
        /// The Mac's DNS gives an address that can't prove it's the service, while the trusted resolver's can.
        case wrongServer
        /// TCP connects, then the handshake is reset once the name is sent; the same server answers another name.
        case tlsReset
        /// The same, but the handshake goes silent instead of being reset.
        case tlsSilent
        /// None of its addresses connect, while the internet works and its status page reports no problems.
        case unreachable
        /// A plain-HTTP request gets HTTP 451 or a redirect off the service's own domain.
        case blockPage
        /// The service itself answered HTTP 451 over a verified connection.
        case legal451
        /// The service's own error says it isn't offered where the connection appears to be.
        case regionError
    }
    public var state: State
    public var host: String
    public var serviceID: String?
    public var service: String?
    public var signals: [Signal]
    /// Each measurement in words, in the order taken.
    public var evidence: [String]
    public var summary: String
    public var next: String
    public var place: NetworkPlace
    /// The VPN the checks went through, when they did.
    public var vpn: String?
    /// The trusted resolver asked, as shown: "Cloudflare (1.1.1.1)".
    public var resolver: String?
    public var status: ServiceStatus.State?
    /// The ISO country the connection appears to be in (registry data), for a regional refusal.
    public var exitCountry: String?
    /// The ISO country of this Mac's time zone, when it differs from `exitCountry`.
    public var timeZoneCountry: String?
    public var date: Date

    public init(state: State, host: String, serviceID: String? = nil, service: String? = nil, signals: [Signal], evidence: [String], summary: String, next: String,
                place: NetworkPlace, vpn: String? = nil, resolver: String? = nil, status: ServiceStatus.State? = nil, exitCountry: String? = nil,
                timeZoneCountry: String? = nil, date: Date = Date()) {
        self.state = state; self.host = host; self.serviceID = serviceID; self.service = service; self.signals = signals; self.evidence = evidence
        self.summary = summary; self.next = next; self.place = place; self.vpn = vpn; self.resolver = resolver; self.status = status
        self.exitCountry = exitCountry; self.timeZoneCountry = timeZoneCountry; self.date = date
    }

    /// A notification's title: "Slack looks blocked on this Wi-Fi network", or "Claude isn’t available in your region".
    public var alertTitle: String {
        let name = service ?? host
        return switch state {
        case .blocked: String(localized: "\(name) looks blocked \(place.on)", comment: "Notification title; the arguments are a service such as Slack and where, such as “on this Wi-Fi network”")
        case .regionUnavailable: String(localized: "\(name) isn’t available in your region", comment: "Notification title; the argument is a service such as Claude")
        }
    }

    /// The row's short state, beside "down" and "degraded".
    public var title: String {
        switch state {
        case .blocked: String(localized: "Blocked here", comment: "A service's state: the network the Mac is on stops it, though the service itself works")
        case .regionUnavailable: String(localized: "Not available in your region", comment: "A service's state: the service refuses by where the connection appears to be")
        }
    }
}

/// The rules that turn measurements into a verdict. Each signal needs a control that worked, and anything that explains
/// the failure otherwise (a sign-in page, Kilobat's own rules, an outage the status page reports, split DNS) wins.
public enum NetworkBlockRules {
    /// Loopback, unspecified, private, link-local, carrier-grade NAT and multicast space: no public service lives there.
    public static func unroutable(_ address: String) -> Bool {
        guard let bytes = AddressRange.parse(address) else { return false }
        return GeoIP.isPrivate(bytes)
    }

    /// Two addresses in the same /24 (IPv4) or /48 (IPv6): the same operator's block, as a CDN's geo-DNS answers usually are.
    public static func samePrefix(_ a: String, _ b: String) -> Bool {
        guard let x = AddressRange.parse(a), let y = AddressRange.parse(b), x.count == y.count else { return false }
        return x.prefix(x.count == 4 ? 3 : 6) == y.prefix(x.count == 4 ? 3 : 6)
    }

    /// Single-label names and private suffixes resolve only inside their own network, so a private answer for them is right.
    public static func internalName(_ host: String) -> Bool {
        let host = host.lowercased()
        return !host.contains(".") || [".local", ".lan", ".home.arpa", ".internal", ".corp", ".intranet", ".ts.net", ".localhost"].contains(where: host.hasSuffix)
    }

    /// The signals the measurements support, strongest first; empty when nothing points at the network.
    public static func signals(_ m: BlockMeasurements, _ context: BlockContext) -> [NetworkBlock.Signal] {
        // Something else explains it: the sign-in page, Kilobat itself, or an outage the service reports.
        guard !context.portal, !context.kilobatBlocks, (context.status ?? .operational) < .partialOutage else { return [] }
        var found: [NetworkBlock.Signal] = []
        let trustedPublic = m.trusted.map { $0.kind == .addresses && !$0.routable.isEmpty } ?? false
        // DNS: only against a trusted answer with a public address, never for split DNS or an internal name.
        if trustedPublic, !context.scopedResolver, !internalName(m.host) {
            switch m.system.kind {
            case .nxdomain where m.systemResolves: found.append(.nameMissing)
            case .noAnswer where m.systemResolves: found.append(.nameSilent)
            case .addresses:
                let trusted = m.trusted?.routable ?? []
                // An address that proves it's the service, or sits in the trusted answer's block, is a CDN's choice, not tampering.
                let proven = m.systemHandshake == .verified || m.system.addresses.contains { address in trusted.contains { $0 == address || samePrefix($0, address) } }
                if !proven {
                    if !Set(m.system.addresses).isDisjoint(with: m.invented) { found.append(.inventedAnswer) }
                    else if !m.system.unroutable.isEmpty, m.system.routable.isEmpty, m.https ? m.systemHandshake != .verified : true { found.append(.privateAnswer) }
                    // A server that answers with someone else's certificate, or cuts the handshake, while the trusted address proves itself.
                    // One that doesn't connect at all may just be a CDN edge that's down, so it isn't counted.
                    else if m.https, let own = m.systemHandshake, [.untrusted, .alert, .reset, .timedOut].contains(own), m.trustedHandshake == .verified { found.append(.wrongServer) }
                }
            default: break
            }
        }
        // The secure connection cut once the name is sent, twice, while the same server answers another name.
        if m.https, let own = m.systemHandshake, own.cut, m.repeatHandshake?.cut == true, m.controlHandshake?.answered == true,
           !found.contains(.wrongServer), !found.contains(.inventedAnswer), !found.contains(.privateAnswer) {
            found.append(own == .reset ? .tlsReset : .tlsSilent)
        }
        // Nothing connects at all: only with a green status page and a working internet (the trusted resolver answered).
        if found.isEmpty, context.status == .operational, trustedPublic, m.system.kind == .addresses,
           m.systemHandshake == .noConnect, m.trustedHandshake == nil || m.trustedHandshake == .noConnect {
            found.append(.unreachable)
        }
        // A block page backs up a finding; on its own a redirect proves too little.
        if !found.isEmpty, let status = m.plainStatus {
            let away = m.plainLocation.flatMap { URL(string: $0)?.host?.lowercased() }.map { !sameSite($0, m.host) } ?? false
            if status == 451 || ((300..<400).contains(status) && away) { found.append(.blockPage) }
        }
        return found
    }

    /// The same registrable-looking domain: slack.com and app.slack.com, not slack.com and warning.example.net.
    static func sameSite(_ a: String, _ b: String) -> Bool {
        func base(_ host: String) -> String { host.lowercased().split(separator: ".").suffix(2).joined(separator: ".") }
        return base(a) == base(b)
    }

    /// The verdict for a network block, or nil when the measurements don't support one.
    public static func classify(_ m: BlockMeasurements, _ context: BlockContext, date: Date = Date()) -> NetworkBlock? {
        let signals = signals(m, context)
        guard let lead = signals.first else { return nil }
        let name = context.service ?? m.host, place = context.place.on, resolver = m.resolver.name
        let system = m.system.addresses.prefix(2).joined(separator: ", "), trusted = (m.trusted?.routable ?? []).prefix(2).joined(separator: ", ")
        let notDown = context.status == .operational
        let reason: String
        switch lead {
        case .nameMissing: reason = String(localized: "its name doesn’t resolve here, while a secure resolver returns its real address", comment: "Network block verdict: the reason")
        case .nameSilent: reason = String(localized: "this network’s DNS doesn’t answer for its name, while a secure resolver returns its real address", comment: "Network block verdict: the reason")
        case .privateAnswer: reason = String(localized: "this network’s DNS answers with \(system), which isn’t a public address, while a secure resolver returns its real address", comment: "Network block verdict: the reason; the argument is an address such as 0.0.0.0")
        case .inventedAnswer: reason = String(localized: "this network’s DNS answers with the same address it gives a made-up name, while a secure resolver returns its real address", comment: "Network block verdict: the reason")
        case .wrongServer: reason = String(localized: "this network’s DNS sends it to \(system), which can’t prove it’s \(name), while the address a secure resolver returns can", comment: "Network block verdict: the reason; the arguments are an address and a service such as Slack")
        case .tlsReset: reason = String(localized: "the secure connection to \(m.host) is cut right after it starts, while the same server answers for another name", comment: "Network block verdict: the reason; the argument is a host")
        case .tlsSilent: reason = String(localized: "the secure connection to \(m.host) stalls right after it starts, while the same server answers for another name", comment: "Network block verdict: the reason; the argument is a host")
        case .unreachable, .blockPage, .legal451, .regionError: reason = ""
        }
        let summary: String
        if lead == .unreachable {
            summary = String(localized: "\(name) can’t be reached \(place), though other sites can and its status page reports no problems. That looks like a block on this network; a problem the status page hasn’t reported yet would look the same.", comment: "Network block verdict; the arguments are a service such as Slack and where, such as “on this Wi-Fi network”")
        } else if notDown {
            summary = String(localized: "\(name) looks blocked \(place), not down: \(reason).", comment: "Network block verdict; the arguments are a service such as Slack, where, such as “on this Wi-Fi network”, and the reason")
        } else {
            summary = String(localized: "\(name) looks blocked \(place): \(reason).", comment: "Network block verdict; the arguments are a service such as Slack, where, such as “on this Wi-Fi network”, and the reason")
        }

        var evidence: [String] = []
        for signal in signals {
            switch signal {
            case .nameMissing: evidence.append(String(localized: "This Mac’s DNS says \(m.host) doesn’t exist; \(resolver), asked over DNS-over-HTTPS, returns \(trusted).", comment: "Network block evidence; the arguments are a host, a resolver such as Cloudflare (1.1.1.1) and addresses"))
            case .nameSilent: evidence.append(String(localized: "This Mac’s DNS gives no answer for \(m.host), though it answers for other names; \(resolver), asked over DNS-over-HTTPS, returns \(trusted).", comment: "Network block evidence; the arguments are a host, a resolver and addresses"))
            case .privateAnswer: evidence.append(String(localized: "This Mac’s DNS answers \(m.host) with \(system), an address no public service uses; \(resolver), asked over DNS-over-HTTPS, returns \(trusted).", comment: "Network block evidence; the arguments are a host, addresses, a resolver and addresses"))
            case .inventedAnswer: evidence.append(String(localized: "This Mac’s DNS answers \(m.host) with \(system), the same address it gives a name that doesn’t exist; \(resolver), asked over DNS-over-HTTPS, returns \(trusted).", comment: "Network block evidence; the arguments are a host, addresses, a resolver and addresses"))
            case .wrongServer: evidence.append(String(localized: "This Mac’s DNS answers \(m.host) with \(system), and the server there can’t show a valid certificate for \(m.host). \(resolver), asked over DNS-over-HTTPS, returns \(trusted), which can.", comment: "Network block evidence; the arguments are a host, addresses, a host, a resolver and addresses"))
            case .tlsReset: evidence.append(String(localized: "TLS to \(m.host) is cut right after the handshake starts: the connection opens, then is reset once \(m.host) is named, twice. Named as another site, the same server answers.", comment: "Network block evidence; the arguments are a host"))
            case .tlsSilent: evidence.append(String(localized: "TLS to \(m.host) stalls right after the handshake starts: the connection opens, then nothing comes back once \(m.host) is named, twice. Named as another site, the same server answers.", comment: "Network block evidence; the arguments are a host"))
            case .unreachable: evidence.append(String(localized: "No address of \(m.host) connects, neither \(system) from this Mac’s DNS nor what \(resolver) returns, while \(resolver) itself answers.", comment: "Network block evidence; the arguments are a host, addresses and a resolver"))
            case .blockPage:
                let page = m.plainStatus == 451 ? String(localized: "HTTP 451, unavailable for legal reasons", comment: "Network block evidence: a block page's answer")
                    : String(localized: "a redirect to \(m.plainLocation.flatMap { URL(string: $0)?.host } ?? "another site")", comment: "Network block evidence: a block page's answer; the argument is a host")
                evidence.append(String(localized: "A plain-HTTP request to \(m.host) gets \(page), the way block pages answer.", comment: "Network block evidence; the arguments are a host and the answer"))
            case .legal451, .regionError: break
            }
        }
        if let sentence = context.statusSentence { evidence.append(sentence) }
        evidence.append(String(localized: "Network: \(context.place.title).", comment: "Network block evidence: the kind of network"))
        var next = context.place.options
        if let vpn = context.vpn {
            evidence.append(String(localized: "These checks went through your VPN (\(vpn)), so the block is on the VPN’s path, not necessarily on this network.", comment: "Network block evidence; the argument is a VPN's name"))
            next = String(localized: "Try without the VPN or on another network, or ask your VPN provider.", comment: "Network block: what to do when the checks went through a VPN")
        }
        next += " " + String(localized: "Kilobat measures blocks; it doesn’t get around them.", comment: "Network block: after the options")
        return NetworkBlock(state: .blocked, host: m.host, serviceID: context.serviceID, service: context.service, signals: signals, evidence: evidence, summary: summary, next: next,
                            place: context.place, vpn: context.vpn, resolver: m.trusted == nil ? nil : resolver, status: context.status, date: date)
    }
}

/// A service saying itself that it isn't offered where the connection appears to be. Only its own answers count: a verified
/// HTTPS response from its host, or the error text an app got from it. Each pattern was seen in the service's own answers.
public enum RegionRefusal {
    public struct Pattern: Sendable, Equatable {
        public let company: String
        public let text: String
        /// Where the wording was seen, dated.
        public let source: String
    }

    /// Checked 1 November 2026 against reports quoting the services' own answers (see RESEARCH-DECISIONS).
    public static let patterns = [
        Pattern(company: "OpenAI", text: "unsupported_country_region_territory",
                source: "OpenAI API HTTP 403 error code, “Country, region, or territory not supported” (openai/codex#14215; OpenAI developer forum)"),
        Pattern(company: "OpenAI", text: "error=unsupported_country", source: "OpenAI sign-in, “OpenAI's services are not available in your country” (OpenAI developer forum)"),
        Pattern(company: "Anthropic", text: "app-unavailable-in-region", source: "claude.ai’s own page for unsupported regions (claude.ai/app-unavailable-in-region)"),
        Pattern(company: "Anthropic", text: "not allowed from unsupported countries, regions, or territories",
                source: "Anthropic API HTTP 400 error (anthropics/claude-code#2656)"),
        Pattern(company: "Google", text: "User location is not supported for the API use", source: "Gemini API HTTP 400 FAILED_PRECONDITION (Google AI developer forum)"),
    ]

    /// The pattern a response or an app's error text matches.
    public static func match(_ text: String) -> Pattern? {
        patterns.first { text.range(of: $0.text, options: .caseInsensitive) != nil }
    }

    /// The signal a service's own answer carries: HTTP 451 over a verified connection, or a known regional error.
    /// `verified` is false for plain HTTP, where the network could have written the answer.
    public static func signal(status: Int?, body: String, location: String?, verified: Bool) -> (NetworkBlock.Signal, Pattern?)? {
        guard verified else { return nil }
        if let pattern = match(body) ?? location.flatMap(match) { return (.regionError, pattern) }
        if status == 451 { return (.legal451, nil) }
        return nil
    }

    /// "OpenAI says its service isn’t available in your region. Your connection currently appears to be in Germany."
    /// `exit` is the registry country of the public address; `zone` the country of this Mac's time zone.
    public static func finding(host: String, who: String, signal: NetworkBlock.Signal, pattern: Pattern?, context: BlockContext, exit: String?, zone: String?,
                               fromApp: Bool = false, date: Date = Date()) -> NetworkBlock {
        func country(_ code: String) -> String { GeoIP.Country(code: code).name }
        var summary = signal == .legal451
            ? String(localized: "\(who) refuses this request for legal reasons (HTTP 451), which services use when they aren’t offered in a region.", comment: "Region verdict; the argument is a company such as OpenAI")
            : String(localized: "\(who) says its service isn’t available in your region.", comment: "Region verdict; the argument is a company such as OpenAI")
        summary += " " + (exit.map { String(localized: "Your connection currently appears to be in \(country($0)).", comment: "Region verdict; the argument is a country") }
            ?? String(localized: "Kilobat couldn’t tell which country your connection appears to be in.", comment: "Region verdict"))
        var evidence: [String] = []
        if let pattern, fromApp { evidence.append(String(localized: "The error the app got says “\(pattern.text)”, \(who)’s own wording for a region it doesn’t serve.", comment: "Region evidence; the arguments are the error's wording and a company")) }
        else if let pattern { evidence.append(String(localized: "\(host) answered with “\(pattern.text)”, \(who)’s own wording for a region it doesn’t serve.", comment: "Region evidence; the arguments are a host, the error's wording and a company")) }
        else { evidence.append(String(localized: "\(host) answered HTTP 451 over a verified secure connection, so the answer is \(who)’s own, not this network’s.", comment: "Region evidence; the arguments are a host and a company")) }
        if let exit { evidence.append(String(localized: "Your public address is registered in \(country(exit)) (DB-IP data, looked up on this Mac). Services place you by it, not by where you are.", comment: "Region evidence; the argument is a country")) }
        if let vpn = context.vpn {
            evidence.append(String(localized: "Traffic leaves through a VPN (\(vpn)), so that’s the VPN’s exit country, which may not be where you are.", comment: "Region evidence; the argument is a VPN's name"))
        } else if context.place == .mobile {
            evidence.append(String(localized: "This is mobile data: with a roaming eSIM the connection often appears to be in the eSIM provider’s country, not where you are.", comment: "Region evidence"))
        }
        if let zone, zone != exit { evidence.append(String(localized: "This Mac’s time zone is set to \(country(zone)), so the connection appears to be somewhere other than where the clock says you are.", comment: "Region evidence; the argument is a country")) }
        let next = String(localized: "That’s \(who)’s own decision, based on where your connection appears to be; this network isn’t blocking it. \(who)’s list of supported countries says where it’s offered, and if you’re in one of them, \(who)’s support can check how your address is placed.", comment: "Region: what to do; the argument is a company such as OpenAI")
        return NetworkBlock(state: .regionUnavailable, host: host, serviceID: context.serviceID, service: context.service, signals: [signal], evidence: evidence, summary: summary, next: next,
                            place: context.place, vpn: context.vpn, status: context.status, exitCountry: exit, timeZoneCountry: zone == exit ? nil : zone, date: date)
    }

    /// The ISO country of a time zone, from macOS's own zone.tab ("DE  +5230+01322  Europe/Berlin").
    public static func country(ofTimeZone identifier: String, table: String) -> String? {
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t")
            if columns.count >= 3, columns[2] == identifier { return String(columns[0]) }
        }
        return nil
    }
}

/// At most one notification per service per network per day, kept in preferences so a restart doesn't repeat one.
public struct BlockAlertPolicy: Codable, Sendable, Equatable {
    var sent: [String: Date] = [:]
    public init() {}
    public static func key(_ block: NetworkBlock, network: String, day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return [block.serviceID ?? block.host, network, block.state.rawValue, "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"].joined(separator: "|")
    }
    public mutating func shouldAlert(_ block: NetworkBlock, network: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        sent = sent.filter { now.timeIntervalSince($0.value) < 2 * 86_400 }
        let key = Self.key(block, network: network, day: now, calendar: calendar)
        guard sent[key] == nil else { return false }
        sent[key] = now
        return true
    }
}
