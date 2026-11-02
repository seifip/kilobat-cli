import Foundation

// MARK: The table

/// One regulator's or provider's published rule for a credit after an outage, as bundled in `OutageCreditData.swift`.
public struct CreditPolicy: Codable, Sendable, Equatable, Identifiable {
    public struct Threshold: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case continuous, cumulative }
        /// The provider's clock starts when you report the fault, or when the outage starts.
        public enum Clock: String, Codable, Sendable { case report, outage }
        public let kind: Kind
        /// Hours down: in a row (continuous) or added up over the month (cumulative). Nil when the rule counts days.
        public var hours: Double? = nil
        /// Days the provider has to fix a reported fault before the credit starts; 0 means from the first day.
        public var days: Int? = nil
        /// `days` are working days, Monday to Friday.
        public var workingDays: Bool? = nil
        public let clock: Clock
        /// Only time between these local hours counts toward a cumulative threshold (Spain: 8 to 22).
        public var fromHour: Int? = nil
        public var toHour: Int? = nil
    }
    public struct Tier: Codable, Sendable, Equatable {
        /// The day of the outage, counted from the report, the tier starts on.
        public let fromDay: Int
        public let amount: Double
        /// A share of the monthly price; the higher of the two applies.
        public let percent: Double
    }
    public struct Credit: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// A fixed amount for each day past the deadline.
            case daily
            /// A daily amount by tier: the higher of a fixed amount and a share of the monthly price.
            case tiered
            /// The monthly price for the share of the month the service was down.
            case proRata
            /// A day of service per qualifying outage, plus a day for each further 24 hours.
            case fullDay
        }
        public let kind: Kind
        public var amount: Double? = nil
        public let currency: String
        public var tiers: [Tier]? = nil
        /// The month's credits can't exceed the monthly price.
        public var capMonthly: Bool? = nil
    }
    public struct Claim: Codable, Sendable, Equatable {
        public var how: String? = nil
        public var url: String? = nil
        public var phone: String? = nil
        /// Days after the outage ends to ask, when the rule has a limit.
        public var windowDays: Int? = nil
    }

    public let id: String
    public let name: String
    public let country: String?
    /// A regulator's scheme or a law, not one provider's terms.
    public let national: Bool
    /// The law binds every provider in the country, not only the ones that signed up.
    public var appliesToAll: Bool? = nil
    public let threshold: Threshold
    public let credit: Credit
    public let automatic: Bool
    public let claim: Claim
    /// The rule in a sentence, as checked, in English. The app shows `terms`, which is translated.
    public let clause: String
    public let source: String
    public var sources: [String]? = nil
    public let checked: String
    public let confidence: String
    public var caveats: String? = nil
}

/// An internet provider Kilobat can recognize from the public address's network (ASN) or its registered name.
public struct CreditProvider: Codable, Sendable, Equatable, Identifiable {
    public struct Claim: Codable, Sendable, Equatable {
        public var url: String? = nil
        public var phone: String? = nil
    }
    public let id: String
    public let name: String
    public var country: String? = nil
    public let asns: [Int]
    /// Lowercased fragments of the network's registered name, such as "comcast".
    public let orgs: [String]
    /// The id of the policy that applies; nil when Kilobat found none it could verify.
    public var policy: String? = nil
    /// The provider stops paying a daily credit after this many days.
    public var capDays: Int? = nil
    public var claim: Claim? = nil
    /// What was found when there is no verified policy, or a detail the policy doesn't cover.
    public var note: String? = nil
    public var source: String? = nil
    public let checked: String
}

public struct OutageCreditTable: Codable, Sendable {
    public let updated: String
    public let policies: [CreditPolicy]
    public let providers: [CreditProvider]

    public static let bundled: OutageCreditTable = {
        do { return try JSONDecoder().decode(OutageCreditTable.self, from: Data(bundledJSON.utf8)) }
        catch { preconditionFailure("The bundled outage-credit table doesn't decode: \(error)") }
    }()

    public func provider(_ id: String?) -> CreditProvider? { id.flatMap { id in providers.first { $0.id == id } } }
    public func policy(id: String?) -> CreditPolicy? { id.flatMap { id in policies.first { $0.id == id } } }

    /// The provider's own policy, else a law that binds every provider in the country (Germany, Spain, Italy).
    /// Ofcom's scheme covers only the providers that signed up, so an unknown UK provider gets none.
    public func policy(for provider: CreditProvider?, country: String?) -> CreditPolicy? {
        if let provider {
            if let policy = policy(id: provider.policy) { return policy }
            if provider.note != nil { return nil }
        }
        let code = (provider?.country ?? country)?.uppercased()
        return policies.first { $0.national && $0.appliesToAll == true && $0.country == code }
    }

    /// The provider whose network the public address belongs to: by ASN first, then by the network's registered
    /// name, which must also match the country when both are known ("orange" names networks in many countries).
    public func match(asn: Int?, organization: String?, country: String?) -> CreditProvider? {
        if let asn, let provider = providers.first(where: { $0.asns.contains(asn) }) { return provider }
        guard let organization = organization.map(Self.normalized), !organization.isEmpty else { return nil }
        let code = country?.uppercased()
        return providers.first { provider in
            provider.orgs.contains { organization.contains($0) } && (code == nil || provider.country == nil || provider.country == code)
        }
    }

    /// Providers to pick from, the country's first.
    public func choices(country: String?) -> [CreditProvider] {
        let code = country?.uppercased()
        let local = providers.filter { $0.country == code || $0.country == nil }
        return local + providers.filter { !local.contains($0) }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

// MARK: The tally

/// One stretch of time the connection was down beyond the router, with the evidence for it.
public struct CreditOutage: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable { case kilobat, starlink }
    public let start: Date
    public let end: Date
    public let sources: [Source]
    /// Kilobat's checks during the outage and how many of them the router answered.
    public let routerChecks: Int
    public let routerAnswered: Int
    /// Starlink outages merged into this one that the dish put on Starlink's network.
    public let dishOutages: Int
    /// Still down when the tally was made.
    public let ongoing: Bool
    public var id: Date { start }
    public var seconds: TimeInterval { end.timeIntervalSince(start) }
}

/// The month's outages Kilobat can show were on the provider's side: the router answered while the internet didn't,
/// or a Starlink dish blamed Starlink's network. Outages at the router or Wi-Fi, ones without enough checks to tell,
/// and any time the Mac was asleep are left out and counted separately, so the claim only says what was measured.
public struct CreditTally: Codable, Sendable, Equatable {
    public let from: Date
    public let to: Date
    public let network: String?
    public let outages: [CreditOutage]
    /// Outages when the router or Wi-Fi didn't answer either.
    public let localSeconds: TimeInterval
    /// Outages without enough router checks to say which side they were on.
    public let unprovenSeconds: TimeInterval
    /// Time taken off outages because the Mac was asleep.
    public let asleepSeconds: TimeInterval
    /// Time the Wi-Fi's sign-in page held the connection: the network's own, never the provider's.
    public var portalSeconds: TimeInterval = 0
    public var totalSeconds: TimeInterval { outages.reduce(0) { $0 + $1.seconds } }
    public var longest: CreditOutage? { outages.max { $0.seconds < $1.seconds } }

    /// Share of Kilobat's checks the router must answer during an outage for it to count as beyond the router.
    public static let routerShare = 0.9
    public static let unreachable = "Unreachable"
    /// NetworkJournal's event when checks fail because a hotel or café sign-in page holds the connection.
    public static let signIn = "Wi-Fi sign-in"

    /// `samples` stand in for router counts on events recorded before Kilobat kept them; only a day's worth are kept.
    /// `network` is the network's name as the journal records it; nil counts every network.
    public static func make(events: [NetworkEvent], samples: [DiagnosticSnapshot] = [], starlink: [StarlinkOutage] = [], sleeps: [DateInterval] = [],
                            network: String?, from: Date, to: Date, now: Date = Date()) -> CreditTally {
        let end = min(to, now)
        var local = 0.0, unproven = 0.0, asleep = 0.0, portal = 0.0
        struct Piece { var start: Date; var end: Date; var sources: Set<CreditOutage.Source>; var checks: Int; var answered: Int; var dish: Int; var ongoing: Bool }
        var pieces: [Piece] = []
        func awake(_ interval: DateInterval) -> [DateInterval] {
            var parts = [interval]
            for sleep in sleeps {
                parts = parts.flatMap { part -> [DateInterval] in
                    guard let overlap = part.intersection(with: sleep), overlap.duration > 0 else { return [part] }
                    asleep += overlap.duration
                    return [DateInterval(start: part.start, end: overlap.start), DateInterval(start: overlap.end, end: part.end)].filter { $0.duration > 0 }
                }
            }
            return parts
        }
        // A sign-in page isn't the provider's outage: shown apart, never counted.
        for event in events where event.kind == signIn && (network == nil || event.network == network) {
            let stop = min(event.end ?? now, end), start = max(event.start, from)
            if stop > start { portal += awake(DateInterval(start: start, end: stop)).reduce(0) { $0 + $1.duration } }
        }
        for event in events where event.kind == unreachable && (network == nil || event.network == network) {
            let stop = min(event.end ?? now, end), start = max(event.start, from)
            guard stop > start else { continue }
            var checks = event.routerChecks ?? 0, answered = event.routerAnswered ?? 0
            if event.routerChecks == nil {
                let during = samples.filter { $0.date >= event.start && $0.date <= (event.end ?? now) && $0.networkName == event.network && $0.internet.average == nil }
                checks = during.count; answered = during.filter { $0.router?.average != nil }.count
            }
            let parts = awake(DateInterval(start: start, end: stop))
            let seconds = parts.reduce(0) { $0 + $1.duration }
            guard checks > 0 else { unproven += seconds; continue }
            guard Double(answered) >= Double(checks) * routerShare else {
                if Double(answered) < Double(checks) / 2 { local += seconds } else { unproven += seconds }
                continue
            }
            // A sleep splits the outage; each part gets its share of the checks, so none are counted twice.
            pieces += parts.map { part in
                let share = seconds > 0 ? part.duration / seconds : 1
                return Piece(start: part.start, end: part.end, sources: [.kilobat], checks: Int((Double(checks) * share).rounded()), answered: Int((Double(answered) * share).rounded()),
                             dish: 0, ongoing: event.end == nil && part.end >= stop && stop >= now)
            }
        }
        for outage in starlink where outage.side == .network {
            let start = max(outage.start, from), stop = min(outage.start.addingTimeInterval(outage.seconds), end)
            guard stop > start else { continue }
            pieces += awake(DateInterval(start: start, end: stop)).map { Piece(start: $0.start, end: $0.end, sources: [.starlink], checks: 0, answered: 0, dish: 1, ongoing: false) }
        }
        // Kilobat's outage and the dish's log of the same minutes count once.
        var merged: [Piece] = []
        for piece in pieces.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, piece.start <= last.end {
                last.end = max(last.end, piece.end); last.sources.formUnion(piece.sources)
                last.checks += piece.checks; last.answered += piece.answered; last.dish += piece.dish; last.ongoing = last.ongoing || piece.ongoing
                merged[merged.count - 1] = last
            } else { merged.append(piece) }
        }
        let outages = merged.map { CreditOutage(start: $0.start, end: $0.end, sources: [CreditOutage.Source.kilobat, .starlink].filter($0.sources.contains),
                                                routerChecks: $0.checks, routerAnswered: $0.answered, dishOutages: $0.dish, ongoing: $0.ongoing) }
        return CreditTally(from: from, to: to, network: network, outages: outages, localSeconds: local, unprovenSeconds: unproven, asleepSeconds: asleep, portalSeconds: portal)
    }

    /// The calendar month holding `date`, or the one `offset` months before it.
    public static func month(of date: Date, offset: Int = 0, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let shifted = calendar.date(byAdding: .month, value: -offset, to: start) ?? start
        return calendar.dateInterval(of: .month, for: shifted) ?? DateInterval(start: shifted, duration: 30 * 86_400)
    }
}

// MARK: The estimate

/// What the policy says about the tally: whether it may qualify, and roughly how much. Never a promise: the provider
/// counts from your report, decides what qualifies and may know of causes Kilobat can't see.
public struct CreditEstimate: Codable, Sendable, Equatable {
    public let policy: String?
    public let qualifies: Bool
    /// Nil without a policy, or when the price is needed and wasn't given.
    public let amount: Double?
    /// The amount is the least it could be: the price would add a share of it (Germany).
    public let atLeast: Bool
    public let currency: String?
    /// Credit days for a daily, tiered or full-day credit.
    public let days: Int?
    /// The outages that crossed the threshold, by start.
    public let qualifying: [Date]
    /// When each qualifying outage crossed it, for the notification.
    public let crossed: [Date]
    public let needsPrice: Bool
    /// The last day to ask about the earliest qualifying outage, when the rule limits it.
    public let askBy: Date?

    public static func make(policy: CreditPolicy?, tally: CreditTally, monthlyPrice: Double?, capDays: Int? = nil, calendar: Calendar = .current) -> CreditEstimate {
        guard let policy else {
            return CreditEstimate(policy: nil, qualifies: false, amount: nil, atLeast: false, currency: nil, days: nil, qualifying: [], crossed: [], needsPrice: false, askBy: nil)
        }
        let price = monthlyPrice.flatMap { $0 > 0 ? $0 : nil }
        let monthSeconds = tally.to.timeIntervalSince(tally.from)
        let daysInMonth = max(1, (monthSeconds / 86_400).rounded())
        let threshold = policy.threshold, credit = policy.credit
        var qualifying: [CreditOutage] = [], crossed: [Date] = [], days = 0, amount: Double? = 0, atLeast = false

        if threshold.kind == .cumulative {
            let limit = (threshold.hours ?? 0) * 3600
            let counted = tally.outages.reduce(0.0) { $0 + window(of: $1, from: threshold.fromHour, to: threshold.toHour, calendar: calendar) }
            if counted > limit {
                qualifying = tally.outages
                crossed = [crossing(tally.outages, limit: limit, from: threshold.fromHour, to: threshold.toHour, calendar: calendar) ?? tally.outages.last?.end ?? tally.to]
            }
        } else {
            for outage in tally.outages {
                let deadline = self.deadline(for: outage, threshold: threshold, calendar: calendar)
                let passed = if let hours = threshold.hours { outage.seconds >= hours * 3600 } else if (threshold.days ?? 0) == 0 { true } else { outage.end > deadline }
                if passed, outage.seconds > 0 { qualifying.append(outage); crossed.append(deadline) }
            }
        }

        switch credit.kind {
        case .daily, .tiered:
            for outage in qualifying {
                let deadline = self.deadline(for: outage, threshold: threshold, calendar: calendar)
                var count = Int(ceil(max(0, outage.end.timeIntervalSince(deadline)) / 86_400 - 1e-9))
                if let capDays { count = min(count, capDays) }
                let first = (threshold.days ?? 0) + 1
                for day in first..<(first + count) {
                    if credit.kind == .daily { amount = amount.map { $0 + (credit.amount ?? 0) } }
                    else if let tier = credit.tiers?.last(where: { $0.fromDay <= day }) {
                        let share = price.map { $0 * tier.percent / 100 }
                        if share == nil { atLeast = true }
                        amount = amount.map { $0 + max(tier.amount, share ?? 0) }
                    }
                }
                days += count
            }
        case .proRata:
            let down = qualifying.reduce(0.0) { $0 + $1.seconds }
            amount = price.map { min($0, $0 * down / monthSeconds) }
        case .fullDay:
            for outage in qualifying { days += 1 + Int(ceil(max(0, outage.seconds - 86_400) / 86_400 - 1e-9)) }
            amount = price.map { price in min(credit.capMonthly == true ? price : .infinity, price / daysInMonth * Double(days)) }
        }
        let needsPrice = price == nil && (credit.kind == .proRata || credit.kind == .fullDay)
        let qualifies = !qualifying.isEmpty && (amount ?? 1) > 0
        let askBy = policy.claim.windowDays.flatMap { window in qualifying.map(\.end).min().map { $0.addingTimeInterval(Double(window) * 86_400) } }
        return CreditEstimate(policy: policy.id, qualifies: qualifies, amount: qualifies ? amount.map { ($0 * 100).rounded() / 100 } : nil, atLeast: atLeast && qualifies,
                              currency: credit.currency, days: credit.kind == .proRata ? nil : days, qualifying: qualifying.map(\.start), crossed: crossed,
                              needsPrice: needsPrice && qualifies, askBy: qualifies ? askBy : nil)
    }

    /// When the provider's deadline passes for an outage, if it was reported as it started. A day rule ends at
    /// midnight after the last of its days, counted after the day of the report; working days skip weekends.
    public static func deadline(for outage: CreditOutage, threshold: CreditPolicy.Threshold, calendar: Calendar = .current) -> Date {
        if let hours = threshold.hours { return outage.start.addingTimeInterval(hours * 3600) }
        let days = threshold.days ?? 0
        guard days > 0 else { return outage.start }
        var day = calendar.startOfDay(for: outage.start), counted = 0
        while counted < days {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            if threshold.workingDays != true || !calendar.isDateInWeekend(day) { counted += 1 }
        }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }

    /// The part of an outage between two local hours of each day; all of it without them.
    static func window(of outage: CreditOutage, from: Int?, to: Int?, calendar: Calendar) -> TimeInterval {
        guard let from, let to else { return outage.seconds }
        var total = 0.0, day = calendar.startOfDay(for: outage.start)
        while day < outage.end {
            if let open = calendar.date(bySettingHour: from, minute: 0, second: 0, of: day),
               let close = calendar.date(bySettingHour: to == 24 ? 23 : to, minute: to == 24 ? 59 : 0, second: to == 24 ? 59 : 0, of: day),
               let overlap = DateInterval(start: outage.start, end: outage.end).intersection(with: DateInterval(start: open, end: max(open, close))) {
                total += overlap.duration
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? outage.end
        }
        return total
    }

    /// The moment the counted time first passes `limit`, to the minute.
    static func crossing(_ outages: [CreditOutage], limit: TimeInterval, from: Int?, to: Int?, calendar: Calendar) -> Date? {
        var total = 0.0
        for outage in outages {
            let counted = window(of: outage, from: from, to: to, calendar: calendar)
            if total + counted > limit {
                var minute = outage.start
                while minute < outage.end {
                    minute = min(outage.end, minute.addingTimeInterval(60))
                    let part = CreditOutage(start: outage.start, end: minute, sources: outage.sources, routerChecks: 0, routerAnswered: 0, dishOutages: 0, ongoing: false)
                    if total + window(of: part, from: from, to: to, calendar: calendar) > limit { return minute }
                }
                return outage.end
            }
            total += counted
        }
        return nil
    }
}

// MARK: Words

public enum CreditText {
    public static func money(_ amount: Double, _ currency: String) -> String { amount.formatted(.currency(code: currency)) }

    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(localized: "under a minute", comment: "How long an outage lasted") }
        return Duration.seconds((seconds / 60).rounded() * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "a fault you report isn't fixed within 2 full working days", translated, for the policy sentence.
    public static func threshold(_ threshold: CreditPolicy.Threshold) -> String {
        if threshold.kind == .cumulative, let hours = threshold.hours {
            let length = duration(hours * 3600)
            if let from = threshold.fromHour, let to = threshold.toHour {
                return String(localized: "when outages add up to more than \(length) in a billing period between \(from):00 and \(to):00", comment: "Outage credit threshold; a length such as 6 hr and two hours of the day")
            }
            return String(localized: "when outages add up to more than \(length) in a billing period", comment: "Outage credit threshold; a length such as 6 hr")
        }
        if let days = threshold.days, days > 0 {
            return threshold.workingDays == true
                ? String(localized: "when a fault you report isn’t fixed within \(days) full working days", comment: "Outage credit threshold; a number of days")
                : String(localized: "when a fault you report isn’t fixed within \(days) calendar days", comment: "Outage credit threshold; a number of days")
        }
        if let hours = threshold.hours, hours > 0 {
            return threshold.clock == .report
                ? String(localized: "for an outage of more than \(duration(hours * 3600)) in a row after you report it", comment: "Outage credit threshold; a length such as 24 hr")
                : String(localized: "for an outage of \(duration(hours * 3600)) or more", comment: "Outage credit threshold; a length such as 20 min")
        }
        return threshold.clock == .report
            ? String(localized: "for any outage you report, from the day you report it", comment: "Outage credit threshold with no minimum length")
            : String(localized: "for any outage", comment: "Outage credit threshold with no minimum length")
    }

    /// "£10.34 for each further day", translated.
    public static func credit(_ policy: CreditPolicy) -> String {
        let credit = policy.credit
        switch credit.kind {
        case .daily:
            let amount = money(credit.amount ?? 0, credit.currency)
            return (policy.threshold.days ?? 0) > 0
                ? String(localized: "\(amount) for each further day", comment: "Outage credit: a daily amount such as £10.34")
                : String(localized: "\(amount) for each day", comment: "Outage credit: a daily amount such as €6")
        case .tiered:
            let parts = (credit.tiers ?? []).map { tier in
                String(localized: "from day \(tier.fromDay), \(money(tier.amount, credit.currency)) or \(Int(tier.percent))% of the monthly price a day", comment: "One tier of an outage credit, such as “from day 3, €5 or 10% of the monthly price a day”")
            }
            return parts.formatted(.list(type: .and)) + String(localized: ", whichever is higher", comment: "Ends a list of outage credit tiers; keep the leading comma if your language uses one")
        case .proRata:
            return String(localized: "a refund of the monthly price for the time it was down", comment: "Outage credit: pro rata")
        case .fullDay:
            return String(localized: "a day of service per outage and a day more for each further day, up to the monthly price", comment: "Outage credit: AT&T-style full-day credits")
        }
    }

    /// The policy in one translated sentence.
    public static func terms(_ policy: CreditPolicy) -> String {
        let how = policy.automatic ? String(localized: "automatically", comment: "Outage credit: paid without asking, at the end of the policy sentence")
            : String(localized: "when you ask", comment: "Outage credit: paid on request, at the end of the policy sentence")
        return String(localized: "\(policy.name): \(credit(policy)), \(threshold(policy.threshold)), \(how).", comment: "Outage credit policy sentence: a policy’s name, what it pays, when, and whether you have to ask")
    }

    /// The card's and the CLI's verdict.
    public static func verdict(_ estimate: CreditEstimate, tally: CreditTally, provider: String, policy: CreditPolicy?) -> String {
        guard let policy else { return noPolicy }
        if tally.outages.isEmpty { return String(localized: "No outages beyond your router in this period.", comment: "Outage credit verdict") }
        guard estimate.qualifies else {
            return String(localized: "Not past the threshold yet. \(provider)’s credit starts \(threshold(policy.threshold)).", comment: "Outage credit verdict; a provider and a threshold such as “when a fault you report isn’t fixed within 2 full working days”")
        }
        if let amount = estimate.amount, let currency = estimate.currency {
            return estimate.atLeast
                ? String(localized: "This may qualify for a credit of at least \(money(amount, currency)) from \(provider).", comment: "Outage credit verdict")
                : String(localized: "This may qualify for a credit of about \(money(amount, currency)) from \(provider).", comment: "Outage credit verdict")
        }
        return String(localized: "This may qualify for a credit from \(provider). Enter what you pay a month to estimate it.", comment: "Outage credit verdict")
    }

    public static let noPolicy = String(localized: "Your provider doesn’t publish a credit policy Kilobat knows; you can still ask.", comment: "Outage credit verdict when no verified policy applies")

    /// What Kilobat measured, in a sentence or two for the claim.
    public static func evidence(_ tally: CreditTally) -> String {
        var lines: [String] = []
        let checks = tally.outages.reduce(0) { $0 + $1.routerChecks }, answered = tally.outages.reduce(0) { $0 + $1.routerAnswered }
        if checks > 0 {
            lines.append(String(localized: "During these outages my router kept answering (\(answered) of \(checks) checks) while two independent internet servers and an HTTPS check all failed, so the connection broke beyond my router.", comment: "Outage credit claim evidence; counts of checks"))
        }
        let dish = tally.outages.reduce(0) { $0 + $1.dishOutages }
        if dish > 0 {
            lines.append(String(localized: "The Starlink dish logged \(dish) outages with no satellite in view or no reply from Starlink’s network.", comment: "Outage credit claim evidence; a count"))
        }
        lines.append(String(localized: "Time my Mac was asleep and outages at my own router or Wi-Fi aren’t counted.", comment: "Outage credit claim evidence"))
        return lines.joined(separator: " ")
    }

    /// "Not counted: 42 min at your router or Wi-Fi, 3 hr while the Mac was asleep".
    public static func excluded(_ tally: CreditTally) -> String? {
        var parts: [String] = []
        if tally.localSeconds >= 60 { parts.append(String(localized: "\(duration(tally.localSeconds)) when your router or Wi-Fi didn’t answer either", comment: "Outage credit: time left out; a length")) }
        if tally.unprovenSeconds >= 60 { parts.append(String(localized: "\(duration(tally.unprovenSeconds)) without enough checks to tell", comment: "Outage credit: time left out; a length")) }
        if tally.asleepSeconds >= 60 { parts.append(String(localized: "\(duration(tally.asleepSeconds)) while the Mac was asleep", comment: "Outage credit: time left out; a length")) }
        if tally.portalSeconds >= 60 { parts.append(String(localized: "\(duration(tally.portalSeconds)) at the Wi-Fi’s sign-in page", comment: "Outage credit: time left out; a length")) }
        guard !parts.isEmpty else { return nil }
        return String(localized: "Not counted: \(parts.formatted(.list(type: .and))).", comment: "Outage credit: the time left out, as a list")
    }

    public static func span(_ outage: CreditOutage) -> String {
        let start = outage.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        let sameDay = Calendar.current.isDate(outage.start, inSameDayAs: outage.end)
        let end = outage.ongoing ? String(localized: "still down", comment: "Outage credit: the end of an outage that hasn’t ended")
            : sameDay ? outage.end.formatted(date: .omitted, time: .shortened) : outage.end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return "\(start) – \(end) (\(duration(outage.seconds)))"
    }
}

// MARK: The claim

/// A message to send the provider, drafted from the tally: never sent by Kilobat.
public struct CreditClaim: Codable, Sendable, Equatable {
    public let subject: String
    public let body: String

    public static let accountPlaceholder = String(localized: "[your account number]", comment: "Placeholder in the drafted outage credit claim")
    public static let namePlaceholder = String(localized: "[your name]", comment: "Placeholder in the drafted outage credit claim")
    /// Outages shorter than this are summed in one line instead of listed, so a dish's many short drops don't drown the long ones.
    static let listed: TimeInterval = 60
    static let shown = 25

    /// `provider` is nil for a provider Kilobat doesn't know.
    public static func draft(provider: String?, policy: CreditPolicy?, tally: CreditTally, estimate: CreditEstimate, monthlyPrice: Double?) -> CreditClaim {
        let month = tally.from.formatted(.dateTime.month(.wide).year())
        let subject = String(localized: "Credit request for internet outages in \(month)", comment: "Subject of the drafted outage credit claim; a month and year")
        let greeting = provider.map { String(localized: "Hello \($0),", comment: "Greeting of the drafted outage credit claim; a provider's name") }
            ?? String(localized: "Hello,", comment: "Greeting of the drafted outage credit claim")
        var lines = [greeting, "",
                     String(localized: "I’m writing about my internet service, account number \(accountPlaceholder). The connection was down at these times in \(month):", comment: "Drafted outage credit claim; an account placeholder and a month"), ""]
        if tally.outages.isEmpty { lines.append(String(localized: "Kilobat recorded no outages beyond my router this month.", comment: "Drafted outage credit claim")) }
        let long = tally.outages.filter { $0.seconds >= listed }
        for outage in long.prefix(shown) { lines.append("• " + CreditText.span(outage)) }
        let rest = tally.outages.count - min(long.count, shown)
        if rest > 0 {
            let seconds = tally.outages.filter { !long.prefix(shown).contains($0) }.reduce(0) { $0 + $1.seconds }
            lines.append("• " + String(localized: "\(rest) shorter outages, \(CreditText.duration(seconds)) in all", comment: "Drafted outage credit claim; a count and a length"))
        }
        if let longest = tally.longest {
            lines += ["", String(localized: "Longest outage: \(CreditText.duration(longest.seconds)). Total this month: \(CreditText.duration(tally.totalSeconds)).", comment: "Drafted outage credit claim; two lengths")]
        }
        lines += ["", CreditText.evidence(tally)]
        if let policy {
            lines += ["", String(localized: "Your terms say: \(CreditText.terms(policy))", comment: "Drafted outage credit claim; the policy sentence")]
            if estimate.qualifies, let amount = estimate.amount, let currency = estimate.currency {
                let price = monthlyPrice.map { String(localized: " (I pay \(CreditText.money($0, currency)) a month)", comment: "Drafted outage credit claim, mid-sentence; keep the leading space") } ?? ""
                lines.append(estimate.atLeast
                    ? String(localized: "By my count these outages may qualify for a credit of at least \(CreditText.money(amount, currency))\(price). Please apply it to my account, or tell me how you count it.", comment: "Drafted outage credit claim; an amount and an optional price")
                    : String(localized: "By my count these outages may qualify for a credit of about \(CreditText.money(amount, currency))\(price). Please apply it to my account, or tell me how you count it.", comment: "Drafted outage credit claim; an amount and an optional price"))
            } else if estimate.qualifies {
                lines.append(String(localized: "By my count these outages may qualify for a credit. Please apply it to my account, or tell me how you count it.", comment: "Drafted outage credit claim"))
            } else {
                lines.append(String(localized: "Please let me know whether a credit is available for this time.", comment: "Drafted outage credit claim"))
            }
        } else {
            lines += ["", String(localized: "Please let me know whether a credit is available for this time.", comment: "Drafted outage credit claim")]
        }
        lines += ["", String(localized: "I’ve attached the network report Kilobat made from these measurements.", comment: "Drafted outage credit claim; Kilobat is the app's name"),
                  "", String(localized: "Thank you,", comment: "Sign-off of the drafted outage credit claim"), namePlaceholder]
        return CreditClaim(subject: subject, body: lines.joined(separator: "\n"))
    }

    public var text: String { subject + "\n\n" + body }
}

// MARK: The notification

/// Whether to say "This outage may qualify for a credit": once per outage, at most once a day, for outages that
/// crossed the threshold in the last two days (an old one found later isn't news).
public enum CreditAlert {
    public static let enabledKey = "credit.alerts"
    public static let notifiedKey = "credit.notified"
    public static let lastKey = "credit.lastAlert"
    public static let spacing: TimeInterval = 86_400

    public static func due(_ estimate: CreditEstimate, notified: Set<String>, last: Date?, now: Date = Date()) -> String? {
        if let last, now.timeIntervalSince(last) < spacing { return nil }
        for (start, crossed) in zip(estimate.qualifying, estimate.crossed) where crossed <= now && now.timeIntervalSince(crossed) < 2 * 86_400 {
            let key = key(start)
            if !notified.contains(key) { return key }
        }
        return nil
    }

    public static func key(_ start: Date) -> String { String(Int(start.timeIntervalSince1970)) }
}

// MARK: Settings

/// The provider, monthly price and network the user confirmed, kept where the app and the CLI both read them.
public struct CreditSettings: Codable, Sendable, Equatable {
    public static let key = "credit.settings"
    /// A provider id from the table; nil for one Kilobat doesn't know.
    public var provider: String?
    /// The ISO country, for a provider Kilobat doesn't know.
    public var country: String?
    /// What the user pays a month for internet.
    public var monthlyPrice: Double?
    /// The network the provider serves, by the name the journal records and by key for the Starlink log.
    public var networkName: String?
    public var networkKey: String?
    public init(provider: String? = nil, country: String? = nil, monthlyPrice: Double? = nil, networkName: String? = nil, networkKey: String? = nil) {
        self.provider = provider; self.country = country; self.monthlyPrice = monthlyPrice; self.networkName = networkName; self.networkKey = networkKey
    }
    public static func load(_ defaults: UserDefaults = .standard) -> CreditSettings? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CreditSettings.self, from: $0) }
    }
    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Everything the card, the CLI and the MCP tool show, made in one place.
public struct CreditReport: Codable, Sendable {
    public let provider: CreditProvider?
    public let providerName: String
    public let country: String?
    public let policy: CreditPolicy?
    public let monthlyPrice: Double?
    public let tally: CreditTally
    public let estimate: CreditEstimate
    public let verdict: String
    public let terms: String?
    public let excluded: String?
    public let claim: CreditClaim

    /// The report for a month from what the app recorded: the journal's outages on the provider's network, the
    /// Starlink dish's log when the dish is on that network, and the times the Mac slept.
    public static func make(settings: CreditSettings?, events: [NetworkEvent], samples: [DiagnosticSnapshot], dish: StarlinkJournal, sleeps: [DateInterval],
                            interval: DateInterval, now: Date = Date()) -> CreditReport {
        let name = settings?.networkName ?? samples.last?.networkName
        let key = settings?.networkKey ?? samples.last?.networkKey
        let starlink = dish.network != nil && dish.network == key ? dish.outages : []
        let tally = CreditTally.make(events: events, samples: samples, starlink: starlink, sleeps: sleeps, network: name, from: interval.start, to: interval.end, now: now)
        return make(settings: settings, tally: tally)
    }

    /// The Mac's sleeps as the app keeps them (`sleeps.json`).
    public static func sleeps(directory: URL? = nil) -> [DateInterval] {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        return StoredJSON.read(folder.appendingPathComponent("sleeps.json")) ?? []
    }

    public static func make(settings: CreditSettings?, tally: CreditTally, table: OutageCreditTable = .bundled) -> CreditReport {
        let provider = table.provider(settings?.provider)
        let name = provider?.name ?? String(localized: "your provider", comment: "Outage credit: stands in for a provider Kilobat doesn't know")
        let policy = table.policy(for: provider, country: settings?.country)
        let estimate = CreditEstimate.make(policy: policy, tally: tally, monthlyPrice: settings?.monthlyPrice, capDays: provider?.capDays)
        return CreditReport(provider: provider, providerName: provider?.name ?? String(localized: "Your provider", comment: "Outage credit: a provider Kilobat doesn't know, at the start of a sentence"),
                            country: provider?.country ?? settings?.country, policy: policy, monthlyPrice: settings?.monthlyPrice, tally: tally, estimate: estimate,
                            verdict: CreditText.verdict(estimate, tally: tally, provider: name, policy: policy), terms: policy.map(CreditText.terms),
                            excluded: CreditText.excluded(tally),
                            claim: .draft(provider: provider?.name, policy: policy, tally: tally, estimate: estimate, monthlyPrice: settings?.monthlyPrice))
    }

    /// Where to ask: the provider's page, else the policy's.
    public var claimURL: URL? { (provider?.claim?.url ?? policy?.claim.url).flatMap(URL.init(string:)) }
    public var phone: String? { provider?.claim?.phone ?? policy?.claim.phone }
}

// MARK: Command line

/// `kilobat credit` options, parsed here so the tests reach them. Read-only: flags override the app's saved choices
/// for one run and never save.
public struct CreditOptions: Equatable, Sendable {
    public enum Month: Equatable, Sendable { case this, last, named(year: Int, month: Int) }
    public static let usage = "Use credit [--provider <id>] [--country <code>] [--price <monthly>] [--month this|last|YYYY-MM] [--draft] [--json], or credit providers [--country <code>] [--json]."
    public var provider: String?
    public var country: String?
    public var price: Double?
    public var month: Month = .this
    public var draft = false
    public var json = false
    /// `credit providers`: list the table, for one country when given.
    public var list = false
    public var listCountry: String?

    public static func parse(_ args: [String], table: OutageCreditTable = .bundled) throws -> CreditOptions {
        var options = CreditOptions(), index = 1
        if args.count > 1, args[1] == "providers" { options.list = true; index = 2 }
        func value() throws -> String {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw DiagnosticError(usage) }
            index += 1; return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--json": options.json = true
            case "--draft" where !options.list: options.draft = true
            case "--country":
                let code = try value().uppercased()
                guard code.count == 2, code.allSatisfy(\.isLetter) else { throw DiagnosticError("--country takes a two-letter code such as GB or US.") }
                if options.list { options.listCountry = code } else { options.country = code }
            case "--provider" where !options.list:
                let id = try value()
                guard table.provider(id) != nil else { throw DiagnosticError("Unknown provider '\(id)'. kilobat credit providers lists them.") }
                options.provider = id
            case "--price" where !options.list:
                guard let price = Double(try value().replacingOccurrences(of: ",", with: ".")), price > 0, price < 100_000 else { throw DiagnosticError("--price takes what you pay a month, such as 49.99.") }
                options.price = price
            case "--month" where !options.list:
                let text = try value()
                switch text {
                case "this": options.month = .this
                case "last": options.month = .last
                default:
                    let parts = text.split(separator: "-").compactMap { Int($0) }
                    guard parts.count == 2, (2000...2100).contains(parts[0]), (1...12).contains(parts[1]) else { throw DiagnosticError("--month takes this, last or a month such as 2026-09.") }
                    options.month = .named(year: parts[0], month: parts[1])
                }
            default: throw DiagnosticError(usage)
            }
            index += 1
        }
        return options
    }

    /// The month to tally.
    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        switch month {
        case .this: CreditTally.month(of: now, calendar: calendar)
        case .last: CreditTally.month(of: now, offset: 1, calendar: calendar)
        case .named(let year, let month):
            CreditTally.month(of: calendar.date(from: DateComponents(year: year, month: month, day: 15)) ?? now, calendar: calendar)
        }
    }
}
