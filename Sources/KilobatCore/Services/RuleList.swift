import Foundation

/// One saved rule as the Rules list shows it, wherever preferences keep it: an app rule (saved or timed),
/// a destination rule, or a domain rule (a host blocked for every app, a blocklist exception, an allowed site).
/// Budgets and app limits are not rules here; they have their own editors.
public struct ListedRule: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case app, destination, domain }
    /// Where preferences keep it, so removing it removes exactly that entry.
    public enum Origin: Hashable, Sendable {
        case app(profile: String, key: String)
        case timedApp(key: String)
        case destination(UUID)
        case blockedHost(String)
        case exception(app: String, domain: String)
        case allowedSite(String)
    }
    public let origin: Origin
    public let allowed: Bool
    /// The app's rule key (a bundle ID or process:name); nil for every app.
    public let app: String?
    /// A domain, address or range; nil for any destination.
    public let host: String?
    public var port: String? = nil
    /// "incoming" or "outgoing"; nil for either.
    public var direction: String? = nil
    /// The profile's raw value; nil where the rule holds in every profile that filters.
    public let profile: String?
    /// When a timed rule ends; nil until it is removed.
    public var expires: Date? = nil
    /// An "until quit" answer: it ends when the app's process exits; `expires` is then only a backstop.
    public var untilQuit = false
    /// A destination rule's "tcp" or "udp"; nil for either.
    public var transport: String? = nil
    /// A destination rule for this exact host only, not its subdomains.
    public var exact = false

    public var id: Origin { origin }
    public var kind: Kind {
        switch origin {
        case .app, .timedApp: .app
        case .destination: .destination
        case .blockedHost, .exception, .allowedSite: .domain
        }
    }
}

extension SavedPreferences {
    /// Every rule in force: timed ones first, soonest to end at the top, then saved app rules, destination rules
    /// newest first (the filter takes the newest match), and domain rules. Rules that ran out are left out.
    public func listedRules(now: Date = Date()) -> [ListedRule] {
        var timed: [ListedRule] = [], saved: [ListedRule] = []
        for (key, rule) in temporaryRules ?? [:] where rule.expires > now {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            timed.append(ListedRule(origin: .timedApp(key: key), allowed: rule.allowed, app: parts[1], host: nil, profile: parts[0], expires: rule.expires, untilQuit: rule.pid != nil))
        }
        for profile in rules.keys.sorted() {
            for (app, allowed) in (rules[profile] ?? [:]).sorted(by: { $0.key < $1.key }) {
                saved.append(ListedRule(origin: .app(profile: profile, key: app), allowed: allowed, app: app, host: nil, profile: profile))
            }
        }
        for rule in (connectionRules ?? []).reversed() {
            if let expires = rule.expires, expires <= now { continue }
            let entry = ListedRule(origin: .destination(rule.id), allowed: rule.allowed, app: rule.app, host: rule.host, port: rule.port.isEmpty ? nil : rule.port,
                                   direction: rule.direction == "any" ? nil : rule.direction, profile: rule.profile, expires: rule.expires,
                                   transport: rule.transport, exact: rule.exact == true)
            if rule.expires == nil { saved.append(entry) } else { timed.append(entry) }
        }
        for host in (blockedHosts ?? []).sorted() {
            saved.append(ListedRule(origin: .blockedHost(host), allowed: false, app: nil, host: host, profile: nil))
        }
        for app in (domainExceptions ?? [:]).keys.sorted() {
            for domain in (domainExceptions?[app] ?? []).sorted() {
                saved.append(ListedRule(origin: .exception(app: app, domain: domain), allowed: true, app: app, host: domain, profile: nil))
            }
        }
        for site in (allowedSites ?? []).sorted() {
            saved.append(ListedRule(origin: .allowedSite(site), allowed: true, app: nil, host: site, profile: nil))
        }
        return timed.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) } + saved
    }

    /// Ends one rule now; the app or destination falls back to whatever applies without it.
    public mutating func remove(_ rule: ListedRule) {
        switch rule.origin {
        case .app(let profile, let key):
            rules[profile]?.removeValue(forKey: key)
            if rules[profile]?.isEmpty == true { rules.removeValue(forKey: profile) }
        case .timedApp(let key):
            temporaryRules?.removeValue(forKey: key)
        case .destination(let id):
            connectionRules?.removeAll { $0.id == id }
        case .blockedHost(let host):
            blockedHosts?.removeAll { $0 == host }
            if blockedHosts?.isEmpty == true { blockedHosts = nil }
        case .exception(let app, let domain):
            domainExceptions?[app]?.removeAll { $0 == domain }
            if domainExceptions?[app]?.isEmpty == true { domainExceptions?.removeValue(forKey: app) }
            if domainExceptions?.isEmpty == true { domainExceptions = nil }
        case .allowedSite(let site):
            allowedSites?.removeAll { $0 == site }
            if allowedSites?.isEmpty == true { allowedSites = nil }
        }
    }
}
