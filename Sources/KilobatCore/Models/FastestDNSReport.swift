import Foundation

/// `kilobat dns fastest --json` and MCP get_fastest_dns: each network's verdict with the latest run, what Kilobat
/// has set now and the recent switches. Built from what the app saved; nothing is measured here.
public struct FastestDNSReport: Encodable, Sendable {
    public struct Resolver: Encodable, Sendable {
        public let id: String
        public let name: String
        public let server: String
        public let medianMs: Double?
        public let p90Ms: Double?
        public let repeatMedianMs: Double?
        public let queries: Int
        public let failures: Int
        public let rewritesMissing: Bool
        public let cdnExtraConnectMs: Double?
        public let cdnPenaltyMs: Double
        public let reliable: Bool
        public let note: String
    }
    public struct Network: Encodable, Sendable {
        public let key: String
        public let name: String
        public let current: Bool
        /// learning, network or faster.
        public let state: String
        public let choice: String
        public let choiceName: String
        public let choiceMs: Double?
        public let networkMs: Double?
        public let leader: String?
        public let days: Int
        public let daysNeeded: Int
        public let runs: Int
        public let lastRun: Date?
        public let penalized: [String]
        public let networkRewritesMissing: Bool
        /// Kilobat switches here (Pro): this network's own setting, else the global one.
        public let auto: Bool
        public let headline: String
        public let resolvers: [Resolver]
    }
    public struct Applied: Encodable, Sendable {
        public let network: String
        public let networkName: String
        public let service: String
        public let resolver: String
        public let servers: [String]
        public let since: Date
    }
    public struct Switch: Encodable, Sendable {
        public let date: Date
        public let network: String
        public let from: String
        public let to: String
        public let reason: String
    }
    public let networks: [Network]
    public let applied: Applied?
    public let switches: [Switch]
    public let autoEverywhere: Bool
    public let excluded: [String]
    public let added: [String]
    public let rule: String

    enum CodingKeys: String, CodingKey { case networks, applied, switches, autoEverywhere, excluded, added, rule }
    /// `applied` is null rather than missing when Kilobat has set nothing, so scripts can test it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(networks, forKey: .networks); try container.encode(applied, forKey: .applied)
        try container.encode(switches, forKey: .switches); try container.encode(autoEverywhere, forKey: .autoEverywhere)
        try container.encode(excluded, forKey: .excluded); try container.encode(added, forKey: .added); try container.encode(rule, forKey: .rule)
    }

    public static let ruleText = "A public resolver is picked only after it beat the network's own (or the current pick) by at least 20 ms at the median first lookup and had a lower p90 in each of its latest runs on 3 different days; a resolver whose CDN answers connect clearly slower is penalised 3x the extra connect time. It goes back to the network's own once it hasn't been ahead on 3 days, or at once when it fails."

    public init(saved: FastestDNSWatch.Saved, preferences: SavedPreferences, current: String?, all: Bool, now: Date = Date(), calendar: Calendar = .current) {
        let current = current ?? saved.current
        let shown = saved.networks.filter { all || $0.network == current }.sorted { $0.lastSeen > $1.lastSeen }
        networks = shown.map { record in
            let verdict = FastestDNS.decide(runs: record.runs, incumbent: record.choice, excluded: preferences.dnsExcludedSet, now: now, calendar: calendar)
            let resolvers = (verdict.latest?.resolvers ?? []).map { run -> Resolver in
                let choice = DNSResolverChoice.from(id: run.id)
                return Resolver(id: run.id, name: choice?.name ?? run.id, server: run.server, medianMs: run.median, p90Ms: run.p90, repeatMedianMs: run.repeatMedian,
                                queries: run.queries, failures: run.failures, rewritesMissing: run.rewritesMissing, cdnExtraConnectMs: run.cdnExcessMs,
                                cdnPenaltyMs: run.penaltyMs, reliable: run.reliable, note: choice?.note ?? "")
            }
            return Network(key: record.network, name: record.name, current: record.network == current, state: verdict.state.rawValue, choice: verdict.choice,
                           choiceName: DNSResolverChoice.from(id: verdict.choice)?.name ?? verdict.choice, choiceMs: verdict.choiceMs, networkMs: verdict.networkMs,
                           leader: verdict.leader, days: verdict.days, daysNeeded: FastestDNS.daysNeeded, runs: verdict.runs, lastRun: verdict.latest?.date,
                           penalized: verdict.penalized, networkRewritesMissing: verdict.networkRewrites, auto: preferences.fastestDNSEnabled(on: record.network),
                           headline: FastestDNS.headline(verdict) ?? "", resolvers: resolvers)
        }
        applied = saved.applied.map { Applied(network: $0.network, networkName: $0.networkName, service: $0.service, resolver: $0.resolver, servers: $0.servers, since: $0.date) }
        switches = saved.switches.suffix(10).reversed().map { Switch(date: $0.date, network: $0.networkName, from: $0.from, to: $0.to, reason: $0.reason.rawValue) }
        autoEverywhere = preferences.fastestDNS ?? false
        excluded = (preferences.dnsExcluded ?? []).sorted()
        added = preferences.dnsExtra ?? []
        rule = Self.ruleText
    }
}
