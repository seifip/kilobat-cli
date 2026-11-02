import Foundation
import Observation

/// Explicit desktop opt-in only. The public CLI never creates this client.
/// No SDK, automatic properties, background checks, or network data enter a payload.
@MainActor @Observable public final class ProductMeasurement {
    public static let useCases = ["gaming", "vpn_proxy", "ai_coding", "study", "travel", "calls", "troubleshooting", "security", "agent_protection", "household", "router", "ssh", "other"]
    public static let reasons = ["blocking", "budgets", "profiles", "history", "radar", "diagnostics", "agent_visibility", "household", "other"]
    public static let sources = ["unknown", "direct", "search", "github", "homebrew", "reddit", "hacker_news", "product_hunt", "newsletter", "student", "referral", "social", "partner"]
    public static let campaigns = ["unknown", "launch", "students", "gamers", "agents", "travel", "proxy", "security"]
    public private(set) var enabled: Bool
    public private(set) var distinctID: String?
    public private(set) var primary: String
    public private(set) var secondary: [String]
    public private(set) var reason: String
    public private(set) var source: String
    public private(set) var campaign: String
    public private(set) var deletionPending: Bool
    public var access = "unknown"
    public var prompt: String?
    public var canOfferUseCase: Bool { enabled && !defaults.bool(forKey: "measurement.useCaseAsked") }
    public var canOfferReason: Bool { enabled && !defaults.bool(forKey: "measurement.reasonAsked") }
    private let defaults: UserDefaults
    private let endpoint: URL
    private let version: String
    private let language: String
    private let allowed: Bool
    private let transport: @MainActor (URLRequest) async throws -> (Data, URLResponse)
    private var token: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var activationFlight: UUID?
    private var sent: Set<String> = []
    private var day = ""
    private var count = 0

    public init(defaults: UserDefaults = .standard, endpoint: URL, version: String, language: String,
                allowed: Bool = true,
                transport: @escaping @MainActor (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults; self.endpoint = endpoint; self.version = version; self.language = language
        self.allowed = allowed; self.transport = transport
        let optedIn = allowed && defaults.bool(forKey: "measurement.enabled")
        enabled = optedIn
        token = optedIn ? defaults.string(forKey: "measurement.token") : nil
        distinctID = optedIn ? defaults.string(forKey: "measurement.id") : nil
        let storedPrimary = defaults.string(forKey: "measurement.primary") ?? "unanswered"
        primary = Self.useCases.contains(storedPrimary) ? storedPrimary : "unanswered"
        secondary = Array((defaults.stringArray(forKey: "measurement.secondary") ?? []).filter { Self.useCases.contains($0) && $0 != storedPrimary }.prefix(3))
        let storedReason = defaults.string(forKey: "measurement.reason") ?? "unanswered"
        reason = Self.reasons.contains(storedReason) ? storedReason : "unanswered"
        let storedSource = defaults.string(forKey: "measurement.source") ?? "unknown"
        source = Self.sources.contains(storedSource) ? storedSource : "unknown"
        let storedCampaign = defaults.string(forKey: "measurement.campaign") ?? "unknown"
        campaign = Self.campaigns.contains(storedCampaign) ? storedCampaign : "unknown"
        deletionPending = defaults.string(forKey: "measurement.withdrawToken") != nil
    }
    /// Invoked by the app, never by an automatic collector. Withdrawal retries also work while disabled.
    public func resume() {
        Task { await retryWithdrawal() }
        if enabled { register() }
    }
    public func setEnabled(_ value: Bool, delete: Bool = true) {
        // An explicit sharing choice also answers the one-time invitation. Never ask again after withdrawal.
        if allowed { defaults.set(true, forKey: "measurement.invitationSeen") }
        task?.cancel(); generation = UUID(); prompt = nil
        if value && allowed && !deletionPending {
            enabled = true; defaults.set(true, forKey: "measurement.enabled")
            if token == nil { token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
            defaults.set(token, forKey: "measurement.token"); register()
        } else {
            if let token {
                defaults.set(token, forKey: "measurement.withdrawToken")
                defaults.set(delete, forKey: "measurement.delete")
                deletionPending = true
            }
            enabled = false; token = nil; distinctID = nil; sent.removeAll()
            activationFlight = nil
            for key in ["enabled", "token", "id", "primary", "secondary", "reason", "source", "campaign", "activated", "activationEventID"] { defaults.removeObject(forKey: "measurement." + key) }
            primary = "unanswered"; secondary = []; reason = "unanswered"; source = "unknown"; campaign = "unknown"
            Task { await retryWithdrawal() }
        }
    }
    public func retryWithdrawal() async {
        guard allowed, let old = defaults.string(forKey: "measurement.withdrawToken") else { return }
        if await post("withdraw", ["token": old, "delete": defaults.bool(forKey: "measurement.delete")]) != nil,
           defaults.string(forKey: "measurement.withdrawToken") == old {
            defaults.removeObject(forKey: "measurement.withdrawToken"); defaults.removeObject(forKey: "measurement.delete"); deletionPending = false
        }
    }
    private func register() {
        guard enabled, let token else { return }
        let generation = generation
        task = Task { [weak self] in
            guard let self, let result = await self.post("consent", ["token": token]), !Task.isCancelled,
                  self.enabled, generation == self.generation, let id = result["distinct_id"] as? String, UUID(uuidString: id) != nil else { return }
            let first = self.distinctID == nil
            self.distinctID = id; self.defaults.set(id, forKey: "measurement.id")
            if first { self.event("measurement_started") }
            if self.defaults.bool(forKey: "measurement.firstValue"), self.canOfferUseCase { self.prompt = "use_case"; self.defaults.set(true, forKey: "measurement.useCaseAsked") }
        }
    }
    public func attribution(source: String, campaign: String) {
        guard enabled else { return }
        self.source = Self.sources.contains(source) ? source : "unknown"
        self.campaign = Self.campaigns.contains(campaign) ? campaign : "unknown"
        defaults.set(self.source, forKey: "measurement.source"); defaults.set(self.campaign, forKey: "measurement.campaign")
    }
    public func answerUseCase(_ values: [String]) {
        guard enabled else { return }
        let values = Array(values.filter { Self.useCases.contains($0) }.prefix(4))
        primary = values.first ?? "unanswered"; secondary = Array(values.dropFirst())
        defaults.set(primary, forKey: "measurement.primary"); defaults.set(secondary, forKey: "measurement.secondary")
        defaults.set(true, forKey: "measurement.useCaseAsked"); prompt = nil
        event(values.isEmpty ? "use_case_skipped" : "use_case_answered")
    }
    public func answerReason(_ value: String?) {
        guard enabled else { return }
        reason = value.flatMap { Self.reasons.contains($0) ? $0 : nil } ?? "unanswered"
        defaults.set(reason, forKey: "measurement.reason"); defaults.set(true, forKey: "measurement.reasonAsked"); prompt = nil
        event(reason == "unanswered" ? "purchase_reason_skipped" : "purchase_reason_answered")
    }
    public func offerPurchaseReason() {
        guard canOfferReason, distinctID != nil else { return }
        defaults.set(true, forKey: "measurement.reasonAsked"); prompt = "purchase_reason"
    }
    /// Call only from a completed explicit user action. Never scheduled jobs or relay/agent loops.
    public func meaningful(_ feature: String, result: String = "completed") {
        guard enabled, distinctID != nil else { return }
        event("feature_used", feature: feature, result: result)
        if !defaults.bool(forKey: "measurement.activated") {
            event("meaningful_activation", feature: feature, result: result)
        }
        event("meaningful_day", feature: feature, result: result, dedup: "meaningful_day")
        if canOfferUseCase { prompt = "use_case"; defaults.set(true, forKey: "measurement.useCaseAsked") }
    }
    public func event(_ name: String, feature: String? = nil, result: String = "completed", dedup: String? = nil) {
        guard allowed, enabled, let token, distinctID != nil else { return }
        let activation = name == "meaningful_activation"
        if activation && activationFlight == generation { return }
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        if today != day { day = today; sent.removeAll(); count = 0 }
        let key = dedup ?? name + ":" + (feature ?? "")
        guard count < 40, sent.insert(key).inserted else { return }; count += 1
        if activation { activationFlight = generation }
        var properties: [String: Any] = ["surface": "desktop", "version": version, "language": language, "access": access,
            "source": source, "campaign": campaign, "primary_use_case": primary, "secondary_use_cases": secondary, "purchase_reason": reason]
        if let feature { properties["feature"] = feature; properties["result"] = result }
        let id: String
        if activation {
            id = defaults.string(forKey: "measurement.activationEventID") ?? UUID().uuidString.lowercased()
            defaults.set(id, forKey: "measurement.activationEventID")
        } else { id = UUID().uuidString.lowercased() }
        let body: [String: Any] = ["token": token, "id": id, "event": name, "properties": properties]
        let generation = generation
        Task { [weak self] in
            guard let self else { return }
            defer { if activation && self.activationFlight == generation { self.activationFlight = nil } }
            guard self.enabled, self.generation == generation else { return }
            let accepted = await self.post("event", body)
            guard self.enabled, self.generation == generation else { return }
            if accepted == nil { self.sent.remove(key) }
            else if activation { self.defaults.set(true, forKey: "measurement.activated") }
        }
    }
    public func checkout(_ url: URL) -> URL {
        guard enabled, let distinctID, UUID(uuidString: distinctID) != nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var query = parts.queryItems ?? []
        for (key, value) in ["analytics_id": distinctID, "source": source, "campaign": campaign, "use_case": primary] {
            query.removeAll { $0.name == "metadata_" + key }; query.append(URLQueryItem(name: "metadata_" + key, value: value))
        }
        parts.queryItems = query; return parts.url ?? url
    }
    private func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard allowed, let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: endpoint.appendingPathComponent(path), timeoutInterval: 5)
        request.httpMethod = "POST"; request.httpBody = data; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }
}
