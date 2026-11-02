import Foundation
import Darwin

// The fastest DNS for each network: Kilobat times the network's own resolver against a few public ones, quietly and a
// few times a day, remembers per network which one is clearly faster, and (Pro, opt-in) switches to it on joining.
// Everything here is pure, so the decision rule, the CDN penalty, the guards and the watchdog are tested directly;
// FastestDNSWatch runs it against the Mac.

/// A resolver Kilobat may time and pick: the network's own (whatever DHCP hands out), a public one, or one the person added.
public struct DNSResolverChoice: Codable, Hashable, Sendable, Identifiable {
    /// "network", "cloudflare", "quad9", "google", or "custom:<address>".
    public let id: String
    public let name: String
    /// Empty for the network's own, which is read from DHCP on each network.
    public let servers: [String]

    public init(id: String, name: String, servers: [String]) { self.id = id; self.name = name; self.servers = servers }

    public static let network = DNSResolverChoice(id: "network", name: "Network DNS", servers: [])
    public static let cloudflare = DNSResolverChoice(id: "cloudflare", name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"])
    public static let quad9 = DNSResolverChoice(id: "quad9", name: "Quad9", servers: ["9.9.9.9", "149.112.112.112"])
    public static let google = DNSResolverChoice(id: "google", name: "Google", servers: ["8.8.8.8", "8.8.4.4"])
    /// The public resolvers Kilobat already offers as presets, in the order it offers them.
    public static let presets = [cloudflare, quad9, google]

    public var isNetwork: Bool { id == Self.network.id }

    /// A resolver the person added by address; nil for anything that isn't an IP address.
    public static func custom(_ address: String) -> DNSResolverChoice? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DNSAddress.valid(address) else { return nil }
        if let preset = presets.first(where: { $0.servers.contains(address) }) { return preset }
        return DNSResolverChoice(id: "custom:" + address, name: address, servers: [address])
    }

    /// What the person may type: a preset's name or address, network/automatic, or another resolver's IP address.
    public static func named(_ text: String) -> DNSResolverChoice? {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["network", "automatic", "auto", "dhcp"].contains(lowered) { return network }
        if let preset = presets.first(where: { $0.id == lowered }) { return preset }
        if lowered.hasPrefix("custom:") { return custom(String(lowered.dropFirst(7))) }
        return custom(lowered)
    }

    /// Find a resolver from an id kept in a record: presets, the network, or a custom address.
    public static func from(id: String) -> DNSResolverChoice? {
        if id == network.id { return network }
        if let preset = presets.first(where: { $0.id == id }) { return preset }
        return id.hasPrefix("custom:") ? custom(String(id.dropFirst(7))) : nil
    }

    /// What Kilobat times on a network: always the network's own, then the presets the person didn't exclude, then
    /// the resolvers they added. An excluded resolver is never timed, so it can never be picked.
    public static func candidates(excluded: Set<String>, extra: [String]) -> [DNSResolverChoice] {
        var list = [network] + presets.filter { !excluded.contains($0.id) }
        for address in extra { if let choice = custom(address), !list.contains(choice), !excluded.contains(choice.id) { list.append(choice) } }
        return list
    }

    /// One line on what the resolver does with lookups, so the choice is made knowingly. Every resolver sees the names
    /// you look up; these say what each keeps.
    public var note: String {
        switch id {
        case "network": String(localized: "Your network’s own DNS, from the router or provider. Needed for Wi-Fi sign-in pages and local names.", comment: "Fastest DNS: what the network's own resolver is")
        case "cloudflare": String(localized: "Cloudflare 1.1.1.1. Says it keeps no IP addresses beyond 25 hours, audited yearly. No client subnet sent to CDNs.", comment: "Fastest DNS: Cloudflare's privacy, in a line")
        case "quad9": String(localized: "Quad9, a Swiss non-profit. Blocks known malicious domains and keeps no IP addresses.", comment: "Fastest DNS: Quad9's privacy, in a line")
        case "google": String(localized: "Google Public DNS. Keeps your IP address for up to 48 hours and city-level data longer; shares part of your address with CDNs.", comment: "Fastest DNS: Google's privacy, honestly")
        default: String(localized: "A resolver you added. Kilobat can’t say what it keeps.", comment: "Fastest DNS: a resolver the person added by address")
        }
    }
}

/// One lookup as the prober saw it.
public struct DNSLookup: Sendable, Equatable {
    /// The resolver's answer time; nil when there was no answer.
    public var ms: Double?
    /// NOERROR, NXDOMAIN, SERVFAIL…; nil without an answer.
    public var status: String?
    /// The A records in the answer.
    public var addresses: [String]
    public init(ms: Double?, status: String?, addresses: [String] = []) { self.ms = ms; self.status = status; self.addresses = addresses }

    /// A name that resolved.
    public var answered: Bool { ms != nil && status == "NOERROR" && !addresses.isEmpty }

    /// `dig @server +tries=1 +time=2 name A`'s ordinary output.
    public static func parse(dig output: String, exitStatus: Int32 = 0) -> DNSLookup {
        guard exitStatus == 0, let status = DiagnosticProbe.matches(#"status: ([A-Z]+)"#, in: output).first else { return DNSLookup(ms: nil, status: nil) }
        let ms = DiagnosticProbe.matches(#"Query time: (\d+) msec"#, in: output).first.flatMap(Double.init)
        var addresses: [String] = [], inAnswer = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(";; ANSWER SECTION") { inAnswer = true; continue }
            if inAnswer {
                if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix(";;") { break }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count >= 5, fields[3] == "A", DNSAddress.valid(String(fields[4])) { addresses.append(String(fields[4])) }
            }
        }
        return DNSLookup(ms: ms, status: status, addresses: addresses)
    }
}

/// One resolver's part of one run.
public struct DNSResolverRun: Codable, Equatable, Sendable {
    public var id: String
    /// The address that was asked.
    public var server: String
    /// Each popular name's first lookup in the run, in ms: what browsing a site for the first time in a while waits for.
    public var firstMs: [Double]
    /// The same names asked again right away: the resolver's own round trip with its cache warm.
    public var repeatMs: [Double]
    public var queries: Int
    public var failures: Int
    /// It answered a name that can't exist with an address: NXDOMAIN rewriting, typically to an ad or search page.
    public var rewritesMissing: Bool
    /// How much longer connecting to the CDN addresses it handed out took than connecting to the network resolver's,
    /// the median over the CDN names; nil when not measured (the network's own, or no comparable answers).
    public var cdnExcessMs: Double?

    public init(id: String, server: String, firstMs: [Double], repeatMs: [Double], queries: Int, failures: Int, rewritesMissing: Bool = false, cdnExcessMs: Double? = nil) {
        self.id = id; self.server = server; self.firstMs = firstMs; self.repeatMs = repeatMs; self.queries = queries; self.failures = failures
        self.rewritesMissing = rewritesMissing; self.cdnExcessMs = cdnExcessMs
    }

    public var median: Double? { FastestDNS.percentile(firstMs, 0.5) }
    public var p90: Double? { FastestDNS.percentile(firstMs, 0.9) }
    public var repeatMedian: Double? { FastestDNS.percentile(repeatMs, 0.5) }
    /// The extra wait its CDN answers add to a connection.
    public var penaltyMs: Double { FastestDNS.cdnPenalty(excess: cdnExcessMs) }
    /// What ranks it: the median first lookup plus the CDN penalty.
    public var score: Double? { median.map { $0 + penaltyMs } }
    /// At most one lookup in ten failed, and it doesn't make up answers.
    public var reliable: Bool { median != nil && failures * 10 <= max(queries, 1) && !rewritesMissing }
}

/// One measurement on one network: every candidate timed side by side within a minute.
public struct DNSRun: Codable, Equatable, Sendable {
    public var date: Date
    public var resolvers: [DNSResolverRun]
    public init(date: Date, resolvers: [DNSResolverRun]) { self.date = date; self.resolvers = resolvers }
    public subscript(id: String) -> DNSResolverRun? { resolvers.first { $0.id == id } }
}

/// What Kilobat remembers about a network's resolvers, in fastest-dns.json.
public struct DNSNetworkRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { network }
    public var network: String
    public var name: String
    public var runs: [DNSRun] = []
    /// The resolver the decision rule settled on; "network" until another one wins clearly.
    public var choice: String = DNSResolverChoice.network.id
    public var choiceSince: Date?
    /// Resolvers the watchdog took away here, and until when they aren't used again.
    public var failedUntil: [String: Date] = [:]
    public var lastSeen: Date
    /// Each resolver's answered, failed and slow lookups per day, from the runs; kept longer than the runs themselves.
    /// Optional so records saved before it existed still read.
    public var tallies: [DNSTally]?

    public init(network: String, name: String, lastSeen: Date) { self.network = network; self.name = name; self.lastSeen = lastSeen }

    public func failed(at now: Date) -> Set<String> { Set(failedUntil.filter { $0.value > now }.keys) }
}

/// What Kilobat set on a network service, so it only ever undoes its own change.
public struct DNSApplied: Codable, Equatable, Sendable {
    public var network: String
    public var networkName: String
    public var service: String
    public var resolver: String
    public var servers: [String]
    /// The router's address when it was set, to notice a new network before the next health check names it.
    public var gateway: String?
    public var date: Date
    /// Set to the person's fallback because lookups failed through the fastest one. Nil rather than false otherwise,
    /// so files saved before it existed still read.
    public var fallback: Bool?
    public init(network: String, networkName: String, service: String, resolver: String, servers: [String], gateway: String?, date: Date, fallback: Bool = false) {
        self.network = network; self.networkName = networkName; self.service = service; self.resolver = resolver; self.servers = servers; self.gateway = gateway; self.date = date
        self.fallback = fallback ? true : nil
    }
    public var onFallback: Bool { fallback == true }
}

/// One switch, for the log and Undo.
public struct DNSSwitch: Codable, Equatable, Sendable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        /// Switched to the resolver that won here.
        case fastest
        /// Back to the network's own: it's as fast again, or the person turned the feature off.
        case networkFaster, off
        /// Back to the network's own because something else needs it.
        case vpn, profile, portal, leftNetwork, quit
        /// Lookups through the chosen resolver failed.
        case watchdog
        /// Lookups through the chosen resolver failed, so Kilobat moved to the person's fallback.
        case fallback
        /// The person pressed Undo.
        case undo
    }
    public var id = UUID()
    public var date: Date
    public var network: String
    public var networkName: String
    public var from: String
    public var to: String
    public var reason: Reason
    public init(date: Date, network: String, networkName: String, from: String, to: String, reason: Reason) {
        self.date = date; self.network = network; self.networkName = networkName; self.from = from; self.to = to; self.reason = reason
    }
}

public enum FastestDNS {
    /// A challenger has to be this much faster at the median first lookup…
    public static let marginMs = 20.0
    /// …in each of its latest runs, spanning this many different days.
    public static let daysNeeded = 3
    /// Runs older than this don't count, and at most this many are kept per network.
    public static let window: TimeInterval = 30 * 86_400
    public static let keptRuns = 12
    /// Measurements: at most this many a day per network, this far apart.
    public static let runsPerDay = 3
    public static let gap: TimeInterval = 4 * 3600
    /// A resolver the watchdog took away isn't used again on that network for this long.
    public static let failurePause: TimeInterval = 24 * 3600

    // MARK: Measuring

    /// Popular names, so the comparison is about sites people open rather than one lucky cache entry.
    public static let domains = ["google.com", "youtube.com", "facebook.com", "instagram.com", "wikipedia.org",
                                 "amazon.com", "apple.com", "microsoft.com", "netflix.com", "reddit.com"]
    /// Names served from CDNs that answer by where they think you are: Akamai, CloudFront, Azure Front Door.
    public static let cdnDomains = ["www.apple.com", "d1.awsstatic.com", "www.microsoft.com"]

    /// A name that can't exist; a resolver that answers it with an address rewrites "no such name".
    public static func missingName(_ random: () -> UInt64 = { UInt64.random(in: 0...UInt64.max) }) -> String {
        "kilobat-nx-" + String(random(), radix: 36) + String(random() % 1_000_000, radix: 36) + ".com"
    }

    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if fraction == 0.5 {
            let middle = sorted.count / 2
            return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// The median, over the CDN names both resolvers answered, of how much longer connecting to the candidate's
    /// address took than to the network resolver's. Same address, same time: 0.
    public static func cdnExcess(candidate: [String: Double], network: [String: Double]) -> Double? {
        let shared = candidate.keys.filter { network[$0] != nil }.sorted()
        guard !shared.isEmpty else { return nil }
        return percentile(shared.map { candidate[$0]! - network[$0]! }, 0.5)
    }

    /// Extra connect time below this is noise between two nodes of the same CDN.
    public static let cdnToleranceMs = 10.0
    /// A far CDN node costs every round trip of a connection: the TCP handshake, TLS and the first request.
    public static let cdnRoundTrips = 3.0
    /// What a resolver's CDN answers cost per connection, to add to its lookup time. Faster lookups that send you to a
    /// far CDN node make browsing slower, which is what this is for.
    public static func cdnPenalty(excess: Double?) -> Double {
        guard let excess, excess > cdnToleranceMs else { return 0 }
        return excess * cdnRoundTrips
    }

    // MARK: Deciding

    public struct Verdict: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            /// Fewer than three days of runs: the network's own stays.
            case learning
            /// The network's own is as fast, or nothing beat it clearly.
            case network
            /// A public resolver won clearly; `choice` names it.
            case faster
        }
        public var state: State
        /// The resolver to use now.
        public var choice: String
        /// Different days with a run, in the window.
        public var days: Int
        public var runs: Int
        /// Lowest score in the latest run among reliable resolvers, for "So far" while learning.
        public var leader: String?
        /// Typical scores across recent runs: the choice's (or leader's) and the network's own.
        public var choiceMs: Double?
        public var networkMs: Double?
        /// Resolvers whose CDN answers were clearly further in the latest run.
        public var penalized: [String]
        /// The network's own resolver rewrote a missing name in the latest run.
        public var networkRewrites: Bool
        /// The latest run, for showing every resolver.
        public var latest: DNSRun?
    }

    /// `incumbent` is the record's choice so far. A challenger replaces it when it beat the incumbent by at least
    /// `marginMs` at the median and had a lower p90 in each of its latest runs, on at least three different days.
    /// A public resolver gives way to the network's own sooner: once it hasn't been ahead at all in its latest runs
    /// on three different days (hysteresis: in at 20 ms, out at 0), or straight away when it fails, rewrites missing
    /// names, or the person excludes it. Ties and noise keep what's there, so it never flaps. A resolver the watchdog
    /// paused stays the choice; `plan` keeps it from being applied until the pause ends.
    public static func decide(runs all: [DNSRun], incumbent: String, excluded: Set<String> = [],
                              now: Date = Date(), calendar: Calendar = .current) -> Verdict {
        let runs = Array(all.filter { $0.date <= now && now.timeIntervalSince($0.date) <= window }.sorted { $0.date < $1.date }.suffix(keptRuns))
        let days = Set(runs.map { calendar.startOfDay(for: $0.date) }).count
        let latest = runs.last
        let network = DNSResolverChoice.network.id
        func usable(_ id: String) -> Bool { id != network && !excluded.contains(id) }

        var choice = incumbent
        if choice != network {
            if !usable(choice) || latest?[choice].map({ !$0.reliable }) ?? true { choice = network }
        }
        // Each candidate's streak: its latest runs, newest first, in which `holds` is true, counted in days.
        func streakDays(_ holds: (DNSRun) -> Bool?) -> (days: Int, runs: [DNSRun]) {
            var taken: [DNSRun] = []
            for run in runs.reversed() {
                guard let result = holds(run) else { continue }  // Not comparable in this run: skip it.
                guard result else { break }
                taken.append(run)
            }
            return (Set(taken.map { calendar.startOfDay(for: $0.date) }).count, taken)
        }
        func beats(_ challenger: String, _ holder: String) -> (DNSRun) -> Bool? {
            { run in
                guard let c = run[challenger] else { return nil }
                guard let h = run[holder], h.reliable else { return c.reliable }
                guard c.reliable, let cs = c.score, let hs = h.score, let cp = c.p90, let hp = h.p90 else { return false }
                return cs + marginMs <= hs && cp + c.penaltyMs < hp + h.penaltyMs
            }
        }
        if days >= daysNeeded {
            // A public resolver that has stopped being ahead of the network's own goes back to it.
            if choice != network {
                let behind = streakDays { run in
                    guard let c = run[choice], let n = run[network], n.reliable else { return nil }
                    guard c.reliable, let cs = c.score, let ns = n.score else { return true }
                    return cs >= ns
                }
                if behind.days >= daysNeeded { choice = network }
            }
            // A challenger takes over after winning clearly on three days in a row of its runs.
            let ids = Set(runs.flatMap { $0.resolvers.map(\.id) }).filter { usable($0) && $0 != choice }
            let winners = ids.compactMap { id -> (String, Double)? in
                let streak = streakDays(beats(id, choice))
                guard streak.days >= daysNeeded, latest?[id]?.reliable == true else { return nil }
                return (id, percentile(streak.runs.compactMap { $0[id]?.score }, 0.5) ?? .infinity)
            }
            if let best = winners.min(by: { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }) { choice = best.0 }
        }

        func typical(_ id: String) -> Double? { percentile(runs.suffix(6).compactMap { $0[id].flatMap { $0.reliable ? $0.score : nil } }, 0.5) }
        let leader = latest?.resolvers.filter(\.reliable).min { ($0.score ?? .infinity, $0.id) < ($1.score ?? .infinity, $1.id) }?.id
        let state: Verdict.State = days < daysNeeded && choice == network ? .learning : choice == network ? .network : .faster
        let shown = state == .learning ? leader : choice
        return Verdict(state: state, choice: choice, days: days, runs: runs.count, leader: leader,
                       choiceMs: shown.flatMap(typical), networkMs: typical(network),
                       penalized: latest?.resolvers.filter { $0.penaltyMs > 0 }.map(\.id).sorted() ?? [],
                       networkRewrites: latest?[network]?.rewritesMissing ?? false, latest: latest)
    }

    // MARK: When to measure

    /// What Kilobat knows about the moment: the network, its cost, the VPN, the sign-in page and how busy the Mac is.
    public struct Moment: Sendable, Equatable {
        public var network: String?
        public var identified: Bool
        public var connected: Bool
        public var metered: Bool
        public var vpn: Bool
        public var portal: Bool
        public var busy: Bool
        public var lowPower: Bool
        public init(network: String?, identified: Bool = true, connected: Bool = true, metered: Bool = false, vpn: Bool = false, portal: Bool = false, busy: Bool = false, lowPower: Bool = false) {
            self.network = network; self.identified = identified; self.connected = connected; self.metered = metered; self.vpn = vpn; self.portal = portal; self.busy = busy; self.lowPower = lowPower
        }
    }

    /// Why a quiet run isn't starting now.
    public enum Wait: String, Codable, Sendable {
        /// No network Kilobat can tell apart.
        case network
        /// Metered networks and phone hotspots are never measured: every lookup costs data there.
        case metered
        /// Through a VPN the times would be the VPN's, and its DNS isn't ours to change.
        case vpn
        /// A sign-in page is in the way; public resolvers are usually blocked until you sign in.
        case portal
        /// Three runs in the last 24 hours.
        case enough
        /// The last run was under four hours ago.
        case recent
        /// The Mac is moving data, so lookups would queue behind it.
        case busy
        case lowPower
    }

    public static func wait(_ moment: Moment, runs: [DNSRun], now: Date = Date()) -> Wait? {
        guard moment.connected, let network = moment.network, network != "unknown", moment.identified else { return .network }
        if moment.metered { return .metered }
        if moment.vpn { return .vpn }
        if moment.portal { return .portal }
        let dates = runs.map(\.date).filter { $0 <= now }
        if dates.filter({ now.timeIntervalSince($0) < 86_400 }).count >= runsPerDay { return .enough }
        if let last = dates.max(), now.timeIntervalSince(last) < gap { return .recent }
        if moment.busy { return .busy }
        if moment.lowPower { return .lowPower }
        return nil
    }

    // MARK: Switching

    /// Everything the switch depends on, read fresh each check.
    public struct Situation: Sendable, Equatable {
        /// The current network's key; nil while there's none Kilobat can tell apart.
        public var network: String?
        /// On for this network: its own setting, or the global one.
        public var enabled: Bool
        public var pro: Bool
        /// Kilobat's helper can change DNS without a password.
        public var helper: Bool
        public var vpn: Bool
        /// A configuration profile or an app's DNS settings (encrypted DNS, a DNS proxy) decide lookups.
        public var managed: Bool
        /// The Wi-Fi sign-in page is waiting.
        public var portal: Bool
        /// The service's manual DNS servers now; empty is automatic (the network's own).
        public var serviceServers: [String]
        public var applied: DNSApplied?
        public var verdict: Verdict?
        /// The resolvers the watchdog took away on this network.
        public var failed: Set<String>
        /// The person's second choice for when the fastest fails here, already checked by `FastestDNS.fallback`; nil
        /// goes straight back to the network's own.
        public var fallback: DNSResolverChoice?
        public init(network: String?, enabled: Bool, pro: Bool, helper: Bool, vpn: Bool = false, managed: Bool = false, portal: Bool = false,
                    serviceServers: [String] = [], applied: DNSApplied? = nil, verdict: Verdict? = nil, failed: Set<String> = [], fallback: DNSResolverChoice? = nil) {
            self.network = network; self.enabled = enabled; self.pro = pro; self.helper = helper; self.vpn = vpn; self.managed = managed; self.portal = portal
            self.serviceServers = serviceServers; self.applied = applied; self.verdict = verdict; self.failed = failed; self.fallback = fallback
        }
    }

    /// Why Kilobat leaves DNS as it is.
    public enum Hold: String, Codable, Sendable {
        case off, pro, noNetwork, vpn, profile, portal
        /// The person set DNS themselves; Kilobat never touches that.
        case ownDNS
        case learning
        /// The network's own DNS is fastest here (or nothing beat it clearly).
        case networkBest
        /// The watchdog took the faster resolver away for a day.
        case failedRecently
        /// The faster resolver failed here, so the person's fallback is in use until its pause ends.
        case onFallback
        /// Switching without a password needs Kilobat's helper.
        case needsHelper
        /// Already on the fastest.
        case applied
    }

    public enum Action: Equatable, Sendable {
        case hold(Hold)
        /// Set the service to this resolver.
        case apply(DNSResolverChoice)
        /// Set the service to the person's fallback, because the fastest failed here.
        case fallback(DNSResolverChoice)
        /// Put automatic DNS back, undoing Kilobat's own change.
        case revert(DNSSwitch.Reason)
        /// Someone else changed DNS since Kilobat did: forget Kilobat's change without touching theirs.
        case forget
    }

    /// The guards, in order: Kilobat's own change goes when the network changes or someone changed DNS since; a VPN,
    /// a profile or a sign-in page always gets the network's own DNS; DNS the person set is never touched; and only
    /// then does the remembered choice apply.
    public static func plan(_ s: Situation) -> Action {
        let servers = s.serviceServers.sorted()
        if let applied = s.applied {
            guard Set(applied.servers) == Set(servers) else { return .forget }
            guard applied.network == s.network else { return .revert(.leftNetwork) }
        }
        let mine = s.applied != nil
        if s.network == nil { return .hold(.noNetwork) }
        if s.vpn { return mine ? .revert(.vpn) : .hold(.vpn) }
        if s.managed { return mine ? .revert(.profile) : .hold(.profile) }
        if s.portal { return mine ? .revert(.portal) : .hold(.portal) }
        if !mine && !servers.isEmpty { return .hold(.ownDNS) }
        if !s.pro { return mine ? .revert(.off) : .hold(.pro) }
        if !s.enabled { return mine ? .revert(.off) : .hold(.off) }
        guard let verdict = s.verdict, verdict.state != .learning else { return mine ? .hold(.applied) : .hold(.learning) }
        guard verdict.choice != DNSResolverChoice.network.id, let choice = DNSResolverChoice.from(id: verdict.choice) else {
            return mine ? .revert(.networkFaster) : .hold(.networkBest)
        }
        if s.failed.contains(choice.id) {
            // The fallback, when there's one that hasn't failed here too; otherwise the network's own.
            guard let fallback = s.fallback, fallback.id != choice.id, !fallback.isNetwork, !s.failed.contains(fallback.id) else {
                return mine ? .revert(.watchdog) : .hold(.failedRecently)
            }
            if let applied = s.applied, applied.resolver == fallback.id { return .hold(.onFallback) }
            guard s.helper else { return mine ? .revert(.watchdog) : .hold(.needsHelper) }
            return .fallback(fallback)
        }
        if let applied = s.applied, applied.resolver == choice.id { return .hold(.applied) }
        guard s.helper else { return .hold(.needsHelper) }
        return .apply(choice)
    }

    /// Takes Kilobat's DNS change back when lookups stop working while the network itself still answers: two checks
    /// in a row where the name lookup failed but the router or the internet replied, or the chosen resolver didn't
    /// answer Kilobat's own query twice. A network that is simply down doesn't count against the resolver.
    public struct Watchdog: Sendable, Equatable {
        public var failures = 0
        public static let limit = 2
        public init() {}
        /// True when Kilobat should put automatic DNS back now.
        public mutating func observe(applied: Bool, lookupWorked: Bool, resolverAnswered: Bool?, networkUp: Bool) -> Bool {
            guard applied else { failures = 0; return false }
            guard networkUp else { return false }
            if lookupWorked && resolverAnswered != false { failures = 0; return false }
            failures += 1
            if failures >= Self.limit { failures = 0; return true }
            return false
        }
    }

    // MARK: Words

    /// "Quad9 (12 ms vs your network’s 48 ms)", or nil before there's anything to say.
    public static func headline(_ verdict: Verdict?) -> String? {
        guard let verdict else { return nil }
        let network = verdict.networkMs.map { String(format: "%.0f", locale: Locale.current, $0) }
        switch verdict.state {
        case .faster:
            let name = DNSResolverChoice.from(id: verdict.choice)?.name ?? verdict.choice
            guard let ms = verdict.choiceMs.map({ String(format: "%.0f", locale: Locale.current, $0) }), let network else { return String(localized: "Fastest here: \(name)", comment: "Fastest DNS; the argument is a resolver such as Quad9") }
            return String(localized: "Fastest here: \(name) (\(ms) ms vs your network’s \(network) ms)", comment: "Fastest DNS; resolver, its typical lookup time and the network's own")
        case .network:
            guard let network else { return String(localized: "Your network’s DNS is fastest here", comment: "Fastest DNS") }
            return String(localized: "Your network’s DNS is fastest here (\(network) ms)", comment: "Fastest DNS; the network's own typical lookup time")
        case .learning:
            let days = verdict.days, needed = daysNeeded
            guard let leader = verdict.leader.flatMap(DNSResolverChoice.from(id:)), let ms = verdict.choiceMs.map({ String(format: "%.0f", locale: Locale.current, $0) }) else {
                return String(localized: "Measuring: \(days) of \(needed) days", comment: "Fastest DNS: runs on different days so far, of those needed")
            }
            let name = leader.isNetwork ? String(localized: "your network’s DNS", comment: "Fastest DNS: the network's own resolver, mid-sentence") : leader.name
            return String(localized: "So far \(name) at \(ms) ms · \(days) of \(needed) days measured", comment: "Fastest DNS while learning; resolver, its lookup time, days so far and needed")
        }
    }

    /// Why Kilobat leaves DNS alone, for the panel.
    public static func explain(_ hold: Hold) -> String? {
        switch hold {
        case .vpn: String(localized: "Your VPN manages DNS, so Kilobat leaves it alone.", comment: "Fastest DNS guard")
        case .profile: String(localized: "A configuration profile or an app’s encrypted DNS decides lookups here, so Kilobat leaves it alone.", comment: "Fastest DNS guard")
        case .portal: String(localized: "The Wi-Fi sign-in page needs the network’s own DNS. Kilobat waits until you’re signed in.", comment: "Fastest DNS guard")
        case .ownDNS: String(localized: "You set DNS servers yourself, so Kilobat doesn’t change them. Choose Automatic to let it.", comment: "Fastest DNS guard")
        case .failedRecently: String(localized: "Lookups failed through the faster resolver here, so Kilobat went back to the network’s DNS for a day.", comment: "Fastest DNS watchdog")
        case .needsHelper: String(localized: "Switching without a password uses Kilobat’s helper.", comment: "Fastest DNS: needs the privileged helper")
        case .onFallback: String(localized: "Lookups failed through the faster resolver here, so Kilobat uses your fallback for a day. If that fails too, the network’s DNS comes back.", comment: "Fastest DNS: on the person's fallback resolver")
        case .off, .pro, .noNetwork, .learning, .networkBest, .applied: nil
        }
    }

    public static func describe(_ reason: DNSSwitch.Reason) -> String {
        switch reason {
        case .fastest: String(localized: "fastest here", comment: "Why Kilobat switched DNS")
        case .networkFaster: String(localized: "the network’s DNS caught up", comment: "Why Kilobat switched DNS back")
        case .off: String(localized: "turned off", comment: "Why Kilobat switched DNS back")
        case .vpn: String(localized: "a VPN connected", comment: "Why Kilobat switched DNS back")
        case .profile: String(localized: "a profile manages DNS", comment: "Why Kilobat switched DNS back")
        case .portal: String(localized: "Wi-Fi sign-in page", comment: "Why Kilobat switched DNS back")
        case .leftNetwork: String(localized: "left the network", comment: "Why Kilobat switched DNS back")
        case .quit: String(localized: "Kilobat quit", comment: "Why Kilobat switched DNS back")
        case .watchdog: String(localized: "lookups failed", comment: "Why Kilobat switched DNS back")
        case .fallback: String(localized: "your fallback, lookups failed through the fastest", comment: "Why Kilobat switched DNS to the person's fallback resolver")
        case .undo: String(localized: "undone", comment: "Why Kilobat switched DNS back")
        }
    }
}

// MARK: Who runs a resolver

/// Who runs a public resolver and under which country's law, for the well-known ones Kilobat offers or may see added,
/// each from the operator's own pages. Anything not
/// here, the network's own included, is "your provider's" or unknown: Kilobat never guesses from an address.
public struct DNSOperator: Equatable, Sendable {
    /// As shown: "Quad9".
    public let name: String
    /// The legal entity: "Quad9 Foundation".
    public let entity: String
    /// The ISO 3166 code of the country it's established in: "CH".
    public let country: String
    /// The operator's page that says so.
    public let source: String
    public let addresses: [String]

    public static let table: [DNSOperator] = [
        DNSOperator(name: "Cloudflare", entity: "Cloudflare, Inc.", country: "US", source: "https://www.cloudflare.com/privacypolicy/",
                    addresses: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]),
        DNSOperator(name: "Quad9", entity: "Quad9 Foundation", country: "CH", source: "https://www.quad9.net/privacy/policy/",
                    addresses: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]),
        DNSOperator(name: "Google", entity: "Google LLC", country: "US", source: "https://policies.google.com/terms",
                    addresses: ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]),
        DNSOperator(name: "AdGuard", entity: "Adguard Software Limited", country: "CY", source: "https://adguard-dns.io/en/privacy.html",
                    addresses: ["94.140.14.14", "94.140.15.15"]),
        DNSOperator(name: "OpenDNS", entity: "Cisco OpenDNS LLC", country: "US", source: "https://www.cisco.com/c/en/us/about/legal/privacy-full.html",
                    addresses: ["208.67.222.222", "208.67.220.220", "208.67.222.123", "208.67.220.123"]),
        DNSOperator(name: "DNS4EU", entity: "Whalebone, s.r.o.", country: "CZ", source: "https://www.joindns4.eu/for-public",
                    addresses: ["86.54.11.1", "86.54.11.201", "86.54.11.100", "86.54.11.200"]),
    ]

    /// The operator of the resolver at `address`, nil for any address not in the table.
    public static func lookup(_ address: String) -> DNSOperator? {
        let address = address.trimmingCharacters(in: .whitespaces).lowercased()
        return table.first { $0.addresses.contains(address) }
    }

    /// "Switzerland", in `locale`'s language.
    public func countryName(_ locale: Locale = .current) -> String { locale.localizedString(forRegionCode: country) ?? country }
    /// "Quad9 · Switzerland".
    public func label(_ locale: Locale = .current) -> String { name + " · " + countryName(locale) }
}

extension DNSResolverChoice {
    /// Who runs it. The network's own is whatever the router hands out, so it's named only when `server` (the address
    /// a run asked) is a known public resolver; an unknown address is nil.
    public func runBy(server: String? = nil) -> DNSOperator? {
        if isNetwork { return server.flatMap(DNSOperator.lookup) }
        return servers.lazy.compactMap(DNSOperator.lookup).first
    }

    /// "Quad9 · Switzerland", "Your provider’s" for the network's own, "Unknown" for an address not in the table.
    public func jurisdiction(server: String? = nil, locale: Locale = .current) -> String {
        if let known = runBy(server: server) { return known.label(locale) }
        return isNetwork ? String(localized: "Your provider’s", comment: "Fastest DNS: who runs the network's own resolver (the internet provider or the router), not known by name")
                         : String(localized: "Unknown operator", comment: "Fastest DNS: who runs a resolver the person added by address, not known")
    }
}

// MARK: Success over time

/// One resolver's lookups on one day, from the quiet runs: answered, failed (no answer, an error or no address) and
/// slow (answered, but after more than `FastestDNS.slowMs`).
public struct DNSTally: Codable, Equatable, Sendable {
    /// The start of the day.
    public var day: Date
    public var resolver: String
    public var answered: Int
    public var failed: Int
    public var slow: Int
    public init(day: Date, resolver: String, answered: Int = 0, failed: Int = 0, slow: Int = 0) {
        self.day = day; self.resolver = resolver; self.answered = answered; self.failed = failed; self.slow = slow
    }
    public var lookups: Int { answered + failed }
    /// Answered of all lookups, 0…1; nil without any.
    public var successRate: Double? { lookups > 0 ? Double(answered) / Double(lookups) : nil }
}

/// A resolver's recent days on one network, for the DNS panel, the report and the command line.
public struct DNSHistory: Equatable, Sendable {
    public var resolver: String
    /// One entry per day, oldest first, ending today; nil where it wasn't timed.
    public var days: [DNSTally?]
    public var answered: Int { days.reduce(0) { $0 + ($1?.answered ?? 0) } }
    public var failed: Int { days.reduce(0) { $0 + ($1?.failed ?? 0) } }
    public var slow: Int { days.reduce(0) { $0 + ($1?.slow ?? 0) } }
    public var lookups: Int { answered + failed }
    public var successRate: Double? { lookups > 0 ? Double(answered) / Double(lookups) : nil }
    public var slowRate: Double? { answered > 0 ? Double(slow) / Double(answered) : nil }
}

extension FastestDNS {
    /// An answer slower than this is slow: a page waits noticeably before it starts.
    public static let slowMs = 200.0
    /// Days of tallies kept per network, and shown.
    public static let talliesKept = 90
    public static let historyShown = 14

    /// `run` added to `tallies`, one entry per resolver per day; days older than `talliesKept` before the run go.
    public static func tally(_ run: DNSRun, into tallies: [DNSTally], calendar: Calendar = .current) -> [DNSTally] {
        let day = calendar.startOfDay(for: run.date)
        let oldest = calendar.date(byAdding: .day, value: -(talliesKept - 1), to: day) ?? day
        var list = tallies.filter { $0.day >= oldest }
        for resolver in run.resolvers {
            let times = resolver.firstMs + resolver.repeatMs
            let slow = times.filter { $0 > slowMs }.count
            if let index = list.firstIndex(where: { $0.day == day && $0.resolver == resolver.id }) {
                list[index].answered += times.count; list[index].failed += resolver.failures; list[index].slow += slow
            } else {
                list.append(DNSTally(day: day, resolver: resolver.id, answered: times.count, failed: resolver.failures, slow: slow))
            }
        }
        return list.sorted { ($0.day, $0.resolver) < ($1.day, $1.resolver) }
    }

    /// Tallies for a record saved before they existed, from the runs it kept.
    public static func tallies(from runs: [DNSRun], calendar: Calendar = .current) -> [DNSTally] {
        runs.sorted { $0.date < $1.date }.reduce([]) { tally($1, into: $0, calendar: calendar) }
    }

    /// Each resolver's last `days` days, ending on `now`'s day: the network's own first, then the presets, then the rest.
    public static func history(_ tallies: [DNSTally], days: Int = historyShown, now: Date = Date(), calendar: Calendar = .current) -> [DNSHistory] {
        let today = calendar.startOfDay(for: now)
        let span = (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let shown = tallies.filter { $0.day >= (span.first ?? today) && $0.day <= today }
        let order = [DNSResolverChoice.network.id] + DNSResolverChoice.presets.map(\.id)
        let ids = Set(shown.map(\.resolver)).sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
        return ids.map { id in DNSHistory(resolver: id, days: span.map { day in shown.first { $0.resolver == id && $0.day == day } }) }
    }

    /// The person's fallback when it can be used on this network: a public or added resolver they haven't left out,
    /// that isn't the network's own (that's where Kilobat goes anyway) and that didn't fail or rewrite missing names
    /// in the latest run here.
    public static func fallback(_ id: String?, excluded: Set<String>, latest: DNSRun?) -> DNSResolverChoice? {
        guard let id, let choice = DNSResolverChoice.from(id: id), !choice.isNetwork, !excluded.contains(choice.id) else { return nil }
        if let run = latest?[choice.id], !run.reliable { return nil }
        return choice
    }
}

// MARK: Configuration profiles and DNS apps

/// Whether something other than the network service decides lookups: an encrypted-DNS configuration profile, an app's
/// DNS settings (NEDNSSettingsManager) or a DNS proxy. macOS keeps those in /Library/Preferences/
/// com.apple.networkextension.plist, a keyed archive readable by everyone; an entry whose DNSSettings or DNSProxy
/// points at an object (not $null) is one. Service DNS changes have no effect then, and Kilobat leaves DNS alone.
public enum ManagedDNS {
    public static let file = URL(fileURLWithPath: "/Library/Preferences/com.apple.networkextension.plist")

    public static func present(file: URL = file) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return present(archive: data)
    }

    public static func present(archive data: Data) -> Bool {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = root["$objects"] as? [Any] else { return false }
        for case let object as [String: Any] in objects {
            // A configuration that is switched off doesn't count.
            if let enabled = object["Enabled"] as? Bool, !enabled { continue }
            for key in ["DNSSettings", "DNSProxy"] {
                guard let value = object[key] else { continue }
                if let index = uid(value), index > 0, index < objects.count, (objects[index] as? String) != "$null" { return true }
            }
        }
        return false
    }

    /// The index a CFKeyedArchiverUID points at. Foundation hands it over as an opaque object whose description ends
    /// in "{value = N}".
    static func uid(_ value: Any) -> Int? {
        if let dictionary = value as? [String: Any], let index = dictionary["CF$UID"] as? Int { return index }
        return DiagnosticProbe.matches(#"value = (\d+)\}"#, in: String(describing: value)).first.flatMap(Int.init)
    }
}

// MARK: The command line

/// `kilobat dns fastest [--all] [--json]`, `dns auto on|off [--network <name>]`, `dns exclude|include <resolver>`,
/// `dns fallback <resolver>|off`.
public enum FastestDNSCommand: Equatable, Sendable {
    case fastest(all: Bool, json: Bool)
    /// `network` nil is every network (the global setting).
    case auto(on: Bool, network: String?, json: Bool)
    case exclude(DNSResolverChoice)
    case include(DNSResolverChoice)
    /// The resolver to use when the fastest fails; nil is none (straight back to the network's own).
    case fallback(DNSResolverChoice?, json: Bool)

    public static let usage = "Use dns fastest [--all] [--json], dns auto on|off [--network <name>], dns exclude|include <cloudflare|quad9|google|IP address> or dns fallback <cloudflare|quad9|google|IP address|off>."

    /// Nil when `args` (after "dns") is another dns command; throws on a malformed one.
    public static func parse(_ args: [String]) throws -> FastestDNSCommand? {
        guard let verb = args.first, ["fastest", "auto", "exclude", "include", "fallback"].contains(verb) else { return nil }
        let json = args.contains("--json")
        var rest = Array(args.dropFirst()).filter { $0 != "--json" }
        switch verb {
        case "fastest":
            let all = rest.contains("--all"); rest.removeAll { $0 == "--all" }
            guard rest.isEmpty else { throw CommandError(usage) }
            return .fastest(all: all, json: json)
        case "auto":
            var network: String?
            if let index = rest.firstIndex(of: "--network") {
                guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--"), !rest[index + 1].trimmingCharacters(in: .whitespaces).isEmpty else { throw CommandError("--network takes a network's name or key from kilobat networks.") }
                network = rest[index + 1]; rest.removeSubrange(index...index + 1)
            }
            guard rest.count == 1, ["on", "off"].contains(rest[0]) else { throw CommandError(usage) }
            return .auto(on: rest[0] == "on", network: network, json: json)
        case "fallback":
            guard rest.count == 1 else { throw CommandError(usage) }
            // Off, or the network's own: no fallback, since automatic DNS is where Kilobat goes anyway.
            if ["off", "none"].contains(rest[0].lowercased()) { return .fallback(nil, json: json) }
            guard let choice = DNSResolverChoice.named(rest[0]) else { throw CommandError("Name cloudflare, quad9, google, a resolver's IP address, or off.") }
            return .fallback(choice.isNetwork ? nil : choice, json: json)
        default:
            guard rest.count == 1, let choice = DNSResolverChoice.named(rest[0]), !choice.isNetwork else {
                throw CommandError("Name cloudflare, quad9, google, or a resolver's IP address.")
            }
            return verb == "exclude" ? .exclude(choice) : .include(choice)
        }
    }

    public struct CommandError: Error, Equatable, LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}

extension SavedPreferences {
    /// Whether Kilobat switches to the fastest DNS on `network`: its own setting, else the global one.
    public func fastestDNSEnabled(on network: String) -> Bool { networkFastestDNS?[network] ?? fastestDNS ?? false }
    public var dnsExcludedSet: Set<String> { Set(dnsExcluded ?? []) }
    public func dnsCandidates() -> [DNSResolverChoice] { DNSResolverChoice.candidates(excluded: dnsExcludedSet, extra: dnsExtra ?? []) }
    public mutating func setFastestDNS(_ on: Bool, network: String?) {
        guard let network else { fastestDNS = on ? true : nil; networkFastestDNS = nil; return }
        var map = networkFastestDNS ?? [:]
        map[network] = on
        networkFastestDNS = map
    }
    /// The resolver to fall back to when the fastest fails, before the network's own; nil is none.
    public var dnsFallbackChoice: DNSResolverChoice? { dnsFallback.flatMap(DNSResolverChoice.from(id:)).flatMap { $0.isNetwork ? nil : $0 } }
    /// A resolver the person added becomes one Kilobat times too, so its record shows whether it works.
    public mutating func setDNSFallback(_ choice: DNSResolverChoice?) {
        guard let choice, !choice.isNetwork else { dnsFallback = nil; return }
        if dnsExcludedSet.contains(choice.id) || (choice.id.hasPrefix("custom:") && !(dnsExtra ?? []).contains(choice.servers[0])) { setDNSExcluded(choice, excluded: false) }
        dnsFallback = choice.id
    }
    /// Excluding a resolver the person added removes it; including an address adds it. Leaving out the fallback
    /// clears it, since Kilobat never uses a resolver the person left out.
    public mutating func setDNSExcluded(_ choice: DNSResolverChoice, excluded: Bool) {
        if excluded, dnsFallback == choice.id { dnsFallback = nil }
        var set = dnsExcludedSet, extra = dnsExtra ?? []
        if choice.id.hasPrefix("custom:") {
            let address = choice.servers[0]
            extra.removeAll { $0 == address }
            if !excluded { extra.append(address) }
            set.remove(choice.id)
        } else if excluded { set.insert(choice.id) } else { set.remove(choice.id) }
        dnsExcluded = set.isEmpty ? nil : set.sorted()
        dnsExtra = extra.isEmpty ? nil : extra
    }
}
