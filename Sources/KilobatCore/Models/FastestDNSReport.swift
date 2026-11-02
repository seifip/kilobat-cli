import Foundation

/// `kilobat dns fastest --json` and MCP get_fastest_dns: each network's verdict with the latest run, who runs each
/// resolver and where, each resolver's lookups over the last two weeks, what Kilobat has set now, the fallback and the
/// recent switches. Built from what the app saved; nothing is measured here.
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
        /// Who runs it and where; null when Kilobat doesn't know (the network's own, an address not in its table).
        public let runBy: String?
        public let entity: String?
        public let jurisdiction: String?
        public let jurisdictionCode: String?
        /// "Quad9 · Switzerland", "Your provider’s" or "Unknown operator".
        public let label: String

        enum CodingKeys: String, CodingKey {
            case id, name, server, medianMs, p90Ms, repeatMedianMs, queries, failures, rewritesMissing, cdnExtraConnectMs, cdnPenaltyMs, reliable, note
            case runBy, entity, jurisdiction, jurisdictionCode, label
        }
        /// Who runs it is null rather than missing when Kilobat doesn't know, so an agent sees it wasn't left out by accident.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(server, forKey: .server)
            try c.encodeIfPresent(medianMs, forKey: .medianMs); try c.encodeIfPresent(p90Ms, forKey: .p90Ms); try c.encodeIfPresent(repeatMedianMs, forKey: .repeatMedianMs)
            try c.encode(queries, forKey: .queries); try c.encode(failures, forKey: .failures); try c.encode(rewritesMissing, forKey: .rewritesMissing)
            try c.encodeIfPresent(cdnExtraConnectMs, forKey: .cdnExtraConnectMs); try c.encode(cdnPenaltyMs, forKey: .cdnPenaltyMs)
            try c.encode(reliable, forKey: .reliable); try c.encode(note, forKey: .note)
            try c.encode(runBy, forKey: .runBy); try c.encode(entity, forKey: .entity); try c.encode(jurisdiction, forKey: .jurisdiction)
            try c.encode(jurisdictionCode, forKey: .jurisdictionCode); try c.encode(label, forKey: .label)
        }
    }
    /// One resolver's lookups in the quiet runs, per day.
    public struct History: Encodable, Sendable {
        public struct Day: Encodable, Sendable {
            public let date: Date
            public let answered: Int
            public let failed: Int
            public let slow: Int
        }
        public let id: String
        public let name: String
        public let label: String
        public let answered: Int
        public let failed: Int
        /// Answered, but slower than `slowMs`.
        public let slow: Int
        /// Answered of all lookups, 0…1.
        public let successRate: Double?
        /// Slow of the answered ones, 0…1.
        public let slowRate: Double?
        /// The days it was timed, oldest first.
        public let days: [Day]
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
        /// The last `historyDays` days, the network's own first.
        public let history: [History]
        public let historyDays: Int
        /// Resolvers paused here after lookups failed through them, and until when.
        public let pausedUntil: [String: Date]
    }
    public struct Applied: Encodable, Sendable {
        public let network: String
        public let networkName: String
        public let service: String
        public let resolver: String
        public let servers: [String]
        public let since: Date
        /// It's the fallback, because the fastest failed.
        public let fallback: Bool
    }
    public struct Fallback: Encodable, Sendable {
        public let id: String
        public let name: String
        public let servers: [String]
        public let label: String
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
    public let fallback: Fallback?
    public let switches: [Switch]
    public let autoEverywhere: Bool
    public let excluded: [String]
    public let added: [String]
    public let slowMs: Double
    public let rule: String

    enum CodingKeys: String, CodingKey { case networks, applied, fallback, switches, autoEverywhere, excluded, added, slowMs, rule }
    /// `applied` and `fallback` are null rather than missing when there's none, so scripts can test them.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(networks, forKey: .networks); try container.encode(applied, forKey: .applied); try container.encode(fallback, forKey: .fallback)
        try container.encode(switches, forKey: .switches); try container.encode(autoEverywhere, forKey: .autoEverywhere)
        try container.encode(excluded, forKey: .excluded); try container.encode(added, forKey: .added)
        try container.encode(slowMs, forKey: .slowMs); try container.encode(rule, forKey: .rule)
    }

    public static let ruleText = "A public resolver is picked only after it beat the network's own (or the current pick) by at least 20 ms at the median first lookup and had a lower p90 in each of its latest runs on 3 different days; a resolver whose CDN answers connect clearly slower is penalised 3x the extra connect time. It goes back to the network's own once it hasn't been ahead on 3 days, or at once when it fails. When lookups fail through it, Kilobat moves to the fallback if one is set and answers, else to the network's own, and pauses the failed one on that network for 24 hours."

    /// Countries in English, as the rest of the command line's output.
    public static let english = Locale(identifier: "en_US")

    public init(saved: FastestDNSWatch.Saved, preferences: SavedPreferences, current: String?, all: Bool, now: Date = Date(), calendar: Calendar = .current) {
        let current = current ?? saved.current
        let shown = saved.networks.filter { all || $0.network == current }.sorted { $0.lastSeen > $1.lastSeen }
        func label(_ id: String, server: String?) -> String {
            DNSResolverChoice.from(id: id)?.jurisdiction(server: server, locale: Self.english)
                ?? String(localized: "Unknown operator", comment: "Fastest DNS: who runs a resolver the person added by address, not known")
        }
        networks = shown.map { record in
            let verdict = FastestDNS.decide(runs: record.runs, incumbent: record.choice, excluded: preferences.dnsExcludedSet, now: now, calendar: calendar)
            let resolvers = (verdict.latest?.resolvers ?? []).map { run -> Resolver in
                let choice = DNSResolverChoice.from(id: run.id)
                let known = choice?.runBy(server: run.server)
                return Resolver(id: run.id, name: choice?.name ?? run.id, server: run.server, medianMs: run.median, p90Ms: run.p90, repeatMedianMs: run.repeatMedian,
                                queries: run.queries, failures: run.failures, rewritesMissing: run.rewritesMissing, cdnExtraConnectMs: run.cdnExcessMs,
                                cdnPenaltyMs: run.penaltyMs, reliable: run.reliable, note: choice?.note ?? "",
                                runBy: known?.name, entity: known?.entity, jurisdiction: known?.countryName(Self.english), jurisdictionCode: known?.country,
                                label: label(run.id, server: run.server))
            }
            // The network's own is named by the address it was asked at; the latest run that timed it has that.
            let servers = Dictionary(record.runs.flatMap { $0.resolvers.map { ($0.id, $0.server) } }, uniquingKeysWith: { _, latest in latest })
            let tallies = record.tallies ?? FastestDNS.tallies(from: record.runs, calendar: calendar)
            let history = FastestDNS.history(tallies, now: now, calendar: calendar).map { item in
                History(id: item.resolver, name: DNSResolverChoice.from(id: item.resolver)?.name ?? item.resolver, label: label(item.resolver, server: servers[item.resolver]),
                        answered: item.answered, failed: item.failed, slow: item.slow, successRate: item.successRate, slowRate: item.slowRate,
                        days: item.days.compactMap { $0.map { History.Day(date: $0.day, answered: $0.answered, failed: $0.failed, slow: $0.slow) } })
            }
            return Network(key: record.network, name: record.name, current: record.network == current, state: verdict.state.rawValue, choice: verdict.choice,
                           choiceName: DNSResolverChoice.from(id: verdict.choice)?.name ?? verdict.choice, choiceMs: verdict.choiceMs, networkMs: verdict.networkMs,
                           leader: verdict.leader, days: verdict.days, daysNeeded: FastestDNS.daysNeeded, runs: verdict.runs, lastRun: verdict.latest?.date,
                           penalized: verdict.penalized, networkRewritesMissing: verdict.networkRewrites, auto: preferences.fastestDNSEnabled(on: record.network),
                           headline: FastestDNS.headline(verdict) ?? "", resolvers: resolvers, history: history, historyDays: FastestDNS.historyShown,
                           pausedUntil: record.failedUntil.filter { $0.value > now })
        }
        applied = saved.applied.map { Applied(network: $0.network, networkName: $0.networkName, service: $0.service, resolver: $0.resolver, servers: $0.servers,
                                              since: $0.date, fallback: $0.onFallback) }
        fallback = preferences.dnsFallbackChoice.map { Fallback(id: $0.id, name: $0.name, servers: $0.servers, label: $0.jurisdiction(locale: Self.english)) }
        switches = saved.switches.suffix(10).reversed().map { Switch(date: $0.date, network: $0.networkName, from: $0.from, to: $0.to, reason: $0.reason.rawValue) }
        autoEverywhere = preferences.fastestDNS ?? false
        excluded = (preferences.dnsExcluded ?? []).sorted()
        added = preferences.dnsExtra ?? []
        slowMs = FastestDNS.slowMs
        rule = Self.ruleText
    }
}
