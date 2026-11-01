import Foundation

/// What a service's public status page says right now, read into one shape whatever the page's format.
/// Kilobat only repeats the page: it never calls something down unless the page says so.
public struct ServiceStatus: Codable, Sendable, Equatable, Identifiable {
    /// Worst last, so states compare by how bad they are. `unknown`: the page couldn't be read.
    public enum State: String, Codable, Sendable, CaseIterable, Comparable {
        case unknown, operational, maintenance, degraded, partialOutage, majorOutage
        private var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: State, b: State) -> Bool { a.rank < b.rank }
        public var title: String {
            switch self {
            case .unknown: String(localized: "Status unknown", comment: "A service's status page couldn't be read")
            case .operational: String(localized: "No problems reported", comment: "A service's status page shows everything working")
            case .maintenance: String(localized: "Maintenance", comment: "A service's status page shows maintenance in progress")
            case .degraded: String(localized: "Degraded", comment: "A service's status page shows it working, but worse than usual")
            case .partialOutage: String(localized: "Partial outage", comment: "A service's status page shows part of it down")
            case .majorOutage: String(localized: "Major outage", comment: "A service's status page shows it down")
            }
        }
    }
    /// The catalog's id, such as slack.
    public let id: String
    public let service: String
    public let state: State
    /// The headline incident or maintenance, as the page titles it.
    public var incident: String?
    public var started: Date?
    /// The incident's own page when it has one, else the status page.
    public let page: URL
    public let checked: Date
    /// Whose status page it is, when that isn't the service: Apple for iCloud, Google for Gmail.
    public var owner: String?

    public init(id: String, service: String, state: State, incident: String? = nil, started: Date? = nil, page: URL, checked: Date, owner: String? = nil) {
        self.id = id; self.service = service; self.state = state; self.incident = incident; self.started = started; self.page = page; self.checked = checked; self.owner = owner
    }

    /// The page reports something wrong right now, maintenance included.
    public var problem: Bool { state > .operational }
    public var outage: Bool { state >= .partialOutage }

    /// One line that answers "is it them or me?" in the present: "Slack is down for everyone, not you — Messaging disruption".
    /// `notYou` only when this Mac's own line checked out, so the sentence never clears the person without a measurement.
    public func sentence(notYou: Bool) -> String {
        let head: String
        switch state {
        case .majorOutage: head = notYou ? String(localized: "\(service) is down for everyone, not you", comment: "Status pages; the argument is a service such as Slack")
                                         : String(localized: "\(service) is down for everyone", comment: "Status pages; the argument is a service such as Slack")
        case .partialOutage: head = notYou ? String(localized: "Part of \(service) is down for everyone, not you", comment: "Status pages; the argument is a service such as Slack")
                                           : String(localized: "Part of \(service) is down for everyone", comment: "Status pages; the argument is a service such as Slack")
        case .degraded: head = String(localized: "\(service) reports problems on its side", comment: "Status pages; the argument is a service such as Slack")
        case .maintenance: head = String(localized: "\(service) is under maintenance", comment: "Status pages; the argument is a service such as Slack")
        case .operational: return owner.map { String(localized: "\($0)’s status page reports no problems with \(service).", comment: "Status pages; the arguments are a company such as Apple and its service such as iCloud") }
            ?? String(localized: "\(service)’s status page reports no problems.", comment: "Status pages; the argument is a service such as Slack")
        case .unknown: return owner.map { String(localized: "Kilobat couldn’t read \($0)’s status page for \(service).", comment: "Status pages; the arguments are a company such as Apple and its service such as iCloud") }
            ?? String(localized: "Kilobat couldn’t read \(service)’s status page.", comment: "Status pages; the argument is a service such as Slack")
        }
        return Self.sentence(head, incident)
    }

    /// "Slack is down for everyone — Degraded performance" or "Slack is down for everyone.", punctuated for the language.
    static func sentence(_ head: String, _ incident: String?) -> String {
        guard let incident else { return String(localized: "\(head).", comment: "Status pages: a sentence ending; the argument is a whole sentence without its full stop") }
        return String(localized: "\(head) — \(incident)", comment: "Status pages: a sentence and the incident's title from the status page")
    }

    /// A notification's title. With the app or agent that kept failing, when it isn't the service itself:
    /// "Claude Code: Anthropic reports an outage — not your connection". The watch only alerts on a line that checked out.
    public func alertTitle(app: String? = nil) -> String {
        guard let app, app != service || owner != nil else {
            return outage ? String(localized: "\(service) is having an outage", comment: "Notification title; the argument is a service such as Slack")
                          : String(localized: "\(service) is having problems", comment: "Notification title; the argument is a service such as Slack")
        }
        let who = owner ?? service
        let kind = switch state {
        case .majorOutage: String(localized: "an outage", comment: "Notification title part: what a status page reports")
        case .partialOutage: String(localized: "a partial outage", comment: "Notification title part: what a status page reports")
        default: String(localized: "problems", comment: "Notification title part: what a status page reports")
        }
        // "Claude Code: Anthropic reports an outage" when the app is the service; "Zed: Anthropic reports an outage on Claude API" otherwise.
        return app == service
            ? String(localized: "\(app): \(who) reports \(kind) — not your connection", comment: "Notification title; the arguments are an app such as Claude Code, a company such as Anthropic and a kind such as “an outage”")
            : String(localized: "\(app): \(who) reports \(kind) on \(service) — not your connection", comment: "Notification title; the arguments are an app such as Zed, a company such as Anthropic, a kind such as “an outage” and a service such as Claude API")
    }

    /// The same in the past tense, for a call report written when the call ended.
    public var reported: String {
        let page = owner.map { String(localized: "\($0)’s status page", comment: "Status pages; the argument is a company such as Apple") }
            ?? String(localized: "\(service)’s status page", comment: "Status pages; the argument is a service such as Zoom")
        let head: String
        switch state {
        case .majorOutage, .partialOutage: head = String(localized: "\(page) reported an outage at the time", comment: "Call report; the argument is like “Zoom’s status page”")
        case .degraded: head = String(localized: "\(page) reported problems at the time", comment: "Call report; the argument is like “Zoom’s status page”")
        case .maintenance: head = String(localized: "\(page) reported maintenance at the time", comment: "Call report; the argument is like “Zoom’s status page”")
        case .operational: return String(localized: "\(page) reported no problems at the time, so the freezes weren’t a known outage.", comment: "Call report; the argument is like “Zoom’s status page”")
        case .unknown: return String(localized: "Kilobat couldn’t read \(page) after the call.", comment: "Call report; the argument is like “Zoom’s status page”")
        }
        return Self.sentence(head, incident)
    }
}

/// Reads each status page format into a `ServiceStatus`. Formats checked against the live pages on 31 October 2026.
public enum ServiceStatusParser {
    public struct Failure: LocalizedError { public let message: String; public var errorDescription: String? { message } }

    public static func parse(_ data: Data, for service: StatusService, now: Date = Date()) throws -> ServiceStatus {
        try parse([data], for: service, now: now)
    }

    /// `pages` are the answers of `service.feed.urls`, in order.
    public static func parse(_ pages: [Data], for service: StatusService, now: Date = Date()) throws -> ServiceStatus {
        guard let data = pages.first else { throw Failure(message: "No page.") }
        let reading: Reading
        switch service.feed {
        case .statuspage(_, let incidentsOnly, _): reading = try statuspage(pages, incidentsOnly: incidentsOnly, components: service.components)
        case .slack: reading = try slack(data)
        case .google(let products): reading = try google(data, products: products, now: now)
        case .googleCloud(let products): reading = try google(data, products: products, now: now, base: "https://status.cloud.google.com/")
        case .apple(let names): reading = try apple(data, names: names, now: now)
        case .microsoft(let workloads): reading = try microsoft(data, workloads: workloads)
        case .statusIO: reading = try statusIO(data)
        case .betterStack: reading = try betterStack(data)
        case .instatus: reading = try instatus(data)
        }
        return ServiceStatus(id: service.id, service: service.name, state: reading.state, incident: reading.state > .operational ? reading.incident.map(clean) : nil,
                             started: reading.state > .operational ? reading.started : nil,
                             page: reading.state > .operational ? reading.link ?? service.page : service.page, checked: now, owner: service.owner)
    }

    struct Reading { var state: ServiceStatus.State; var incident: String? = nil; var started: Date? = nil; var link: URL? = nil }

    // MARK: Atlassian Statuspage, and incident.io's compatible /api/v2/summary.json

    private struct Summary: Decodable {
        struct Indicator: Decodable { let indicator: String }
        struct Named: Decodable { let name: String }
        struct Incident: Decodable {
            let name: String; let status: String?; let impact: String?; let shortlink: String?; let started_at: String?; let created_at: String?
            /// The components an incident affects; incident.io's copy of the format leaves it out.
            let components: [Named]?
        }
        struct Maintenance: Decodable { let name: String; let status: String?; let shortlink: String?; let scheduled_for: String? }
        let status: Indicator
        let incidents: [Incident]?
        let scheduled_maintenances: [Maintenance]?
        let components: [Component]?
    }
    private struct Component: Decodable { let name: String; let status: String? }
    private struct ComponentList: Decodable { let components: [Component] }

    /// The page's own indicator decides the state; an incident still being worked on can raise it. `incidentsOnly` is for pages
    /// whose indicator is never green, such as Cloudflare's, where a few of hundreds of data centers are always rerouted.
    /// With `components`, only those components count when the page has them: their own status, and the incidents that name them.
    static func statuspage(_ pages: [Data], incidentsOnly: Bool, components wanted: [String] = []) throws -> Reading {
        let summary = try JSONDecoder().decode(Summary.self, from: pages[0])
        let all = pages.count > 1 ? (try? JSONDecoder().decode(ComponentList.self, from: pages[1]).components) ?? summary.components ?? [] : summary.components ?? []
        func impact(_ value: String?) -> ServiceStatus.State {
            switch value { case "critical": .majorOutage; case "major": .partialOutage; case "minor": .degraded; default: .operational }
        }
        let open = (summary.incidents ?? []).filter { !["resolved", "postmortem", "completed"].contains($0.status ?? "") }
        // An incident being monitored has a fix in place; it explains a state, it doesn't raise one.
        let working = open.filter { ["investigating", "identified"].contains($0.status ?? "") }
        func ours(_ name: String) -> Bool { wanted.contains { name == $0 || name.hasPrefix($0 + " ") } }
        let mine = all.filter { ours($0.name) }
        if !wanted.isEmpty, !mine.isEmpty {
            return component(mine, open: open, working: working, maintenances: summary.scheduled_maintenances ?? [], ours: ours, impact: impact)
        }
        var state: ServiceStatus.State
        if incidentsOnly {
            state = open.map { impact($0.impact) }.max() ?? .operational
        } else {
            switch summary.status.indicator {
            case "critical": state = .majorOutage
            case "major": state = .partialOutage
            case "minor": state = .degraded
            case "maintenance": state = .maintenance
            default: state = .operational
            }
            state = max(state, working.map { impact($0.impact) }.max() ?? .operational)
        }
        // The headline: the worst incident, one still being worked on before one being monitored.
        func weight(_ incident: Summary.Incident) -> Int {
            ServiceStatus.State.allCases.firstIndex(of: impact(incident.impact))! * 2 + (["investigating", "identified"].contains(incident.status ?? "") ? 1 : 0)
        }
        if state > .maintenance, let lead = open.max(by: { weight($0) < weight($1) }) {
            return Reading(state: state, incident: lead.name, started: date(lead.started_at ?? lead.created_at), link: lead.shortlink.flatMap(URL.init(string:)))
        }
        // Only when the page itself says maintenance: Zoom keeps weeks-long windows "in progress" with "No Operational Impact" on a green page.
        if state == .maintenance, let maintenance = (summary.scheduled_maintenances ?? []).first(where: { $0.status == "in_progress" }) {
            return Reading(state: .maintenance, incident: maintenance.name, started: date(maintenance.scheduled_for), link: maintenance.shortlink.flatMap(URL.init(string:)))
        }
        return Reading(state: state)
    }

    /// One component's (or a few's) reading: the worst of their own statuses, raised by an incident being worked on that
    /// names one of them. An incident that names only other components doesn't count. Pages whose incidents carry no
    /// component list (incident.io's copy) lend their worst open incident's title once a component of ours is down.
    private static func component(_ mine: [Component], open: [Summary.Incident], working: [Summary.Incident], maintenances: [Summary.Maintenance],
                                  ours: (String) -> Bool, impact: (String?) -> ServiceStatus.State) -> Reading {
        func status(_ value: String?) -> ServiceStatus.State {
            switch value {
            case "major_outage": .majorOutage
            case "partial_outage": .partialOutage
            case "degraded_performance": .degraded
            case "under_maintenance": .maintenance
            default: .operational
            }
        }
        let naming = open.filter { ($0.components ?? []).contains { ours($0.name) } }
        var state = mine.map { status($0.status) }.max() ?? .operational
        state = max(state, working.filter { naming.map(\.name).contains($0.name) }.map { impact($0.impact) }.max() ?? .operational)
        if state == .maintenance {
            let window = maintenances.first { $0.status == "in_progress" }
            return Reading(state: .maintenance, incident: window?.name, started: date(window?.scheduled_for), link: window?.shortlink.flatMap(URL.init(string:)))
        }
        guard state > .maintenance else { return Reading(state: state) }
        let listed = open.contains { $0.components != nil }
        let candidates = naming.isEmpty && !listed ? open : naming
        guard let lead = candidates.max(by: { impact($0.impact) < impact($1.impact) }) else { return Reading(state: state) }
        return Reading(state: state, incident: lead.name, started: date(lead.started_at ?? lead.created_at), link: lead.shortlink.flatMap(URL.init(string:)))
    }

    // MARK: Better Stack: <page>/index.json

    private struct BetterStack: Decodable {
        struct Page: Decodable { struct Attributes: Decodable { let aggregate_state: String? }; let attributes: Attributes }
        struct Included: Decodable {
            struct Attributes: Decodable { let title: String?; let starts_at: String?; let aggregate_state: String?; let report_type: String? }
            let type: String; let attributes: Attributes
        }
        let data: Page
        let included: [Included]?
    }

    static func betterStack(_ data: Data) throws -> Reading {
        let page = try JSONDecoder().decode(BetterStack.self, from: data)
        let state: ServiceStatus.State = switch page.data.attributes.aggregate_state {
        case "downtime": .partialOutage
        case "degraded": .degraded
        case "maintenance": .maintenance
        case "operational": .operational
        default: throw Failure(message: "Unknown Better Stack state.")
        }
        guard state > .operational else { return Reading(state: state) }
        let reports = (page.included ?? []).filter { $0.type == "status_report" && $0.attributes.aggregate_state != "resolved" }
        let lead = reports.first { (state == .maintenance) == ($0.attributes.report_type == "maintenance") } ?? reports.first
        return Reading(state: state, incident: lead?.attributes.title, started: date(lead?.attributes.starts_at))
    }

    // MARK: Instatus: <page>/summary.json

    private struct Instatus: Decodable {
        struct Page: Decodable { let status: String }
        struct Event: Decodable { let name: String; let started: String?; let url: String? }
        let page: Page
        let activeIncidents: [Event]?
        let activeMaintenances: [Event]?
    }

    /// Instatus's states: UP, HASISSUES, UNDERMAINTENANCE.
    static func instatus(_ data: Data) throws -> Reading {
        let summary = try JSONDecoder().decode(Instatus.self, from: data)
        switch summary.page.status {
        case "UP": return Reading(state: .operational)
        case "UNDERMAINTENANCE":
            let window = summary.activeMaintenances?.first
            return Reading(state: .maintenance, incident: window?.name, started: date(window?.started), link: window?.url.flatMap(URL.init(string:)))
        case "HASISSUES":
            let incident = summary.activeIncidents?.first
            return Reading(state: .degraded, incident: incident?.name, started: date(incident?.started), link: incident?.url.flatMap(URL.init(string:)))
        default: throw Failure(message: "Unknown Instatus state.")
        }
    }

    // MARK: Slack: slack-status.com/api/v2.0.0/current

    private struct SlackCurrent: Decodable {
        struct Incident: Decodable { let title: String; let type: String?; let status: String?; let url: String?; let date_created: String? }
        let status: String
        let active_incidents: [Incident]?
    }

    static func slack(_ data: Data) throws -> Reading {
        let current = try JSONDecoder().decode(SlackCurrent.self, from: data)
        func state(_ type: String?) -> ServiceStatus.State {
            switch type { case "outage": .majorOutage; case "incident": .partialOutage; case "maintenance": .maintenance; default: .degraded }
        }
        let open = (current.active_incidents ?? []).filter { !["resolved", "completed"].contains($0.status ?? "") }
        guard let lead = open.max(by: { state($0.type) < state($1.type) }) else {
            // "broken" is Slack's own word for an outage; it comes with an incident, so alone it reads as degraded.
            return Reading(state: current.status == "broken" ? .degraded : .operational)
        }
        let overall = max(state(lead.type), current.status == "broken" ? .majorOutage : .unknown)
        return Reading(state: overall, incident: lead.title, started: date(lead.date_created), link: lead.url.flatMap(URL.init(string:)))
    }

    // MARK: Google Workspace: google.com/appsstatus/dashboard/incidents.json

    private struct GoogleIncident: Decodable {
        struct Product: Decodable { let title: String }
        struct Update: Decodable { let text: String? }
        let begin: String?
        let end: String?
        let external_desc: String?
        let most_recent_update: Update?
        let status_impact: String?
        let affected_products: [Product]?
        let service_name: String?
        let uri: String?
    }

    /// Google Workspace and Google Cloud share this format; `base` is the dashboard their incident links are relative to.
    static func google(_ data: Data, products: [String], now: Date, base: String = "https://www.google.com/appsstatus/dashboard/") throws -> Reading {
        let incidents = try JSONDecoder().decode([GoogleIncident].self, from: data)
        func state(_ impact: String?) -> ServiceStatus.State {
            switch impact { case "SERVICE_OUTAGE": .majorOutage; case "SERVICE_DISRUPTION": .partialOutage; default: .degraded }
        }
        let open = incidents.filter { incident in
            let names = (incident.affected_products ?? []).map(\.title) + [incident.service_name].compactMap { $0 }
            let ended = incident.end.flatMap(date).map { $0 <= now } ?? false
            return !ended && names.contains { products.contains($0) }
        }
        guard let lead = open.max(by: { state($0.status_impact) < state($1.status_impact) }) else { return Reading(state: .operational) }
        let summary = summaryLine(lead.most_recent_update?.text) ?? summaryLine(lead.external_desc)
        return Reading(state: state(lead.status_impact), incident: summary, started: date(lead.begin),
                       link: lead.uri.flatMap { URL(string: base + $0) })
    }

    /// Google heads its text "**Summary:**", "**Summary**" or "## Summary", then the line that says it; otherwise the first line with words.
    static func summaryLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let marks = CharacterSet(charactersIn: "#*").union(.whitespaces)
        let lines = text.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: marks) }
        if let index = lines.firstIndex(where: { $0.lowercased().hasPrefix("summary") }) {
            let rest = lines[index].dropFirst("summary".count).trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespaces))
            if !rest.isEmpty { return rest }
            if let next = lines.dropFirst(index + 1).first(where: { !$0.isEmpty }) { return next }
        }
        return lines.first { !$0.isEmpty && !$0.hasSuffix(":") && $0.lowercased() != "incident report" }
    }

    // MARK: Apple System Status: apple.com/support/systemstatus/data/system_status_en_US.js

    private struct AppleStatus: Decodable {
        struct Service: Decodable { let serviceName: String; let events: [Event]? }
        struct Event: Decodable {
            let statusType: String?
            let message: String?
            let usersAffected: String?
            let eventStatus: String?
            let epochStartDate: Double?
            let epochEndDate: Double?
        }
        let services: [Service]
    }

    /// `names` match a service exactly, or by prefix when they end in "*", such as "iCloud*".
    static func apple(_ data: Data, names: [String], now: Date) throws -> Reading {
        // The file has been served both as plain JSON and wrapped in a callback; read what's between the outer braces.
        guard let text = String(data: data, encoding: .utf8), let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}") else {
            throw Failure(message: "Apple’s status file isn’t JSON.")
        }
        let status = try JSONDecoder().decode(AppleStatus.self, from: Data(text[open...close].utf8))
        func covered(_ name: String) -> Bool { names.contains { $0.hasSuffix("*") ? name.hasPrefix($0.dropLast()) : name == $0 } }
        func state(_ event: AppleStatus.Event) -> ServiceStatus.State {
            switch event.statusType?.lowercased() {
            case "outage": (event.usersAffected ?? "").lowercased().hasPrefix("all users") ? .majorOutage : .partialOutage
            case "maintenance": .maintenance
            default: .degraded
            }
        }
        let events = status.services.filter { covered($0.serviceName) }.flatMap { service in (service.events ?? []).map { (service.serviceName, $0) } }.filter { _, event in
            let phase = event.eventStatus?.lowercased() ?? ""
            if phase == "ongoing" { return true }
            if ["resolved", "completed", "upcoming", "scheduled"].contains(phase) { return false }
            let start = event.epochStartDate.map { Date(timeIntervalSince1970: $0 / 1000) }, end = event.epochEndDate.map { Date(timeIntervalSince1970: $0 / 1000) }
            return (start.map { $0 <= now } ?? false) && (end.map { $0 > now } ?? true)
        }
        guard let (name, lead) = events.max(by: { state($0.1) < state($1.1) }) else { return Reading(state: .operational) }
        let message = lead.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Reading(state: state(lead), incident: message.map { names.count > 1 ? name + ": " + $0 : $0 } ?? name,
                       started: lead.epochStartDate.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    // MARK: Microsoft's consumer services: status.cloud.microsoft/api/posts/m365Consumer

    private struct MicrosoftPost: Decodable {
        let ServiceDisplayName: String?
        let ServiceWorkloadName: String?
        let Status: String?
        let Title: String?
        let AuthoredDateTime: String?
    }

    static func microsoft(_ data: Data, workloads: [String]) throws -> Reading {
        let posts = try JSONDecoder().decode([MicrosoftPost].self, from: data).filter { workloads.contains($0.ServiceWorkloadName ?? "") }
        guard !posts.isEmpty else { throw Failure(message: "Microsoft’s status page no longer lists this service.") }
        func state(_ status: String?) -> ServiceStatus.State {
            let word = (status ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            if word.isEmpty || ["operational", "serviceoperational", "servicerestored", "resolved", "resolvedexternal", "mitigated", "mitigatedexternal",
                                "falsepositive", "postincidentreviewpublished", "postincidentreportpublished"].contains(word) { return .operational }
            if word.contains("interruption") { return .majorOutage }
            return .degraded
        }
        guard let lead = posts.max(by: { state($0.Status) < state($1.Status) }), state(lead.Status) > .operational else { return Reading(state: .operational) }
        let title = lead.Title?.trimmingCharacters(in: .whitespaces)
        let authored = date(lead.AuthoredDateTime).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        return Reading(state: state(lead.Status), incident: title?.isEmpty == false ? title : lead.Status, started: authored)
    }

    // MARK: Status.io, as GitLab uses: /1.0/status/<page id>

    private struct StatusIO: Decodable {
        struct Result: Decodable {
            struct Overall: Decodable { let status_code: Int }
            struct Incident: Decodable { let name: String; let datetime_open: String? }
            struct Maintenance: Decodable { let active: [Planned]? }
            struct Planned: Decodable { let name: String; let datetime_planned_start: String? }
            let status_overall: Overall
            let incidents: [Incident]?
            let maintenance: Maintenance?
        }
        let result: Result
    }

    static func statusIO(_ data: Data) throws -> Reading {
        let result = try JSONDecoder().decode(StatusIO.self, from: data).result
        let state: ServiceStatus.State = switch result.status_overall.status_code {
        case 500...599: .majorOutage
        case 400...499: .partialOutage
        case 300...399, 600...: .degraded
        case 200...299: .maintenance
        default: .operational
        }
        if state > .maintenance, let incident = result.incidents?.first { return Reading(state: state, incident: incident.name, started: date(incident.datetime_open)) }
        if let planned = result.maintenance?.active?.first, state >= .maintenance {
            return Reading(state: state, incident: planned.name, started: date(planned.datetime_planned_start))
        }
        return Reading(state: state)
    }

    // MARK: Helpers

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        // Microsoft writes seven fractional digits, which ISO8601DateFormatter refuses.
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return formatter.date(from: String(text[..<dot]) + String(text[zone...]))
        }
        return nil
    }

    /// Titles arrive with stray whitespace and the odd HTML entity.
    static func clean(_ title: String) -> String {
        var text = title.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "’").replacingOccurrences(of: "&quot;", with: "\"")
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return text.count > 160 ? String(text.prefix(157)) + "…" : text
    }
}

/// Fetches status pages with a short timeout and keeps each page's answer for a few minutes, so a burst of checks
/// (a diagnosis, the CLI, a notification) asks each page once. Requests carry no cookies, no cache and nothing about this Mac.
public actor ServiceStatusChecker {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public static let shared = ServiceStatusChecker()
    /// How long one page's answer stands.
    public static let freshFor: TimeInterval = 180
    private let fetch: Fetch
    private var pages: [URL: (data: Data, date: Date)] = [:]
    private var inFlight: [URL: Task<Data, Error>] = [:]

    public init(fetch: Fetch? = nil) { self.fetch = fetch ?? Self.download }

    /// Every service's status, in the order asked; a page that doesn't answer reads as `unknown`, never as an outage.
    public func check(_ services: [StatusService], now: Date = Date()) async -> [ServiceStatus] {
        var results: [ServiceStatus] = []
        await withTaskGroup(of: (Int, ServiceStatus).self) { group in
            for (index, service) in services.enumerated() {
                let tasks = service.feed.urls.map { page($0, now: now) }
                group.addTask {
                    do {
                        // The first page is the state; a missing extra page (a full component list) only loses detail.
                        var pages = [try await tasks[0].value]
                        for task in tasks.dropFirst() { if let data = try? await task.value { pages.append(data) } else { break } }
                        return (index, try ServiceStatusParser.parse(pages, for: service, now: now))
                    }
                    catch { return (index, ServiceStatus(id: service.id, service: service.name, state: .unknown, page: service.page, checked: now, owner: service.owner)) }
                }
            }
            var ordered: [(Int, ServiceStatus)] = []
            for await result in group { ordered.append(result) }
            results = ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return results
    }

    public func check(_ service: StatusService, now: Date = Date()) async -> ServiceStatus { await check([service], now: now)[0] }

    /// One request per page however many services share it (Google's, Apple's and Microsoft's pages cover several).
    private func page(_ url: URL, now: Date) -> Task<Data, Error> {
        if let cached = pages[url], now.timeIntervalSince(cached.date) < Self.freshFor { return Task { cached.data } }
        if let running = inFlight[url] { return running }
        let fetch = fetch
        // The answer is kept before anyone waiting on the task hears it, so the next check finds it.
        let task = Task { [self] () throws -> Data in
            do { let data = try await fetch(url); finish(url, data: data, date: now); return data }
            catch { finish(url, data: nil, date: now); throw error }
        }
        inFlight[url] = task
        return task
    }

    private func finish(_ url: URL, data: Data?, date: Date) {
        inFlight[url] = nil
        if let data { pages[url] = (data, date) }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 8
        configuration.httpAdditionalHeaders = ["User-Agent": "Kilobat (+https://kilobat.app)", "Accept": "application/json"]
        return URLSession(configuration: configuration)
    }()

    static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceStatusParser.Failure(message: "The status page answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }
}
