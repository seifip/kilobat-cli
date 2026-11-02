import Foundation

/// kilobat.app answers 503 until its referral server is set up, so the app hides referrals rather than show an error.
public struct ReferralsNotOffered: Error, Sendable {}

public struct LicenseServiceError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Only public licensing endpoints are used. No merchant API secret belongs in the app.
public struct LicenseClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let baseURL: URL
    private let businessID: String
    private let productIDs: Set<String>
    private let transport: Transport

    public init(testMode: Bool = false, businessID: String, productIDs: Set<String>, transport: Transport? = nil) {
        baseURL = URL(string: testMode ? "https://test.dodopayments.com" : "https://live.dodopayments.com")!
        self.businessID = businessID; self.productIDs = productIDs
        self.transport = transport ?? { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw LicenseServiceError(String(localized: "The license service returned an unexpected response. Try again later.")) }
            return (data, response.statusCode)
        }
    }

    public func activate(_ input: String, installation: String) async throws -> AppLicense {
        guard !businessID.isEmpty, !productIDs.isEmpty else { throw LicenseServiceError(String(localized: "License activation is not configured for this build.")) }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 512 else { throw LicenseServiceError(String(localized: "Paste the license key from your purchase email.")) }
        struct Activation: Decodable {
            struct Product: Decodable { let product_id: String }
            let id: String
            let license_key_id: String?
            let business_id: String
            let product: Product?
        }
        let data = try await request("activate", ["license_key": key, "name": "Kilobat Mac " + installation])
        let response = try JSONDecoder().decode(Activation.self, from: data)
        guard response.business_id == businessID, let product = response.product,
              productIDs.contains(product.product_id), !response.id.isEmpty else {
            // A valid key for a different product must never unlock Kilobat or consume a seat.
            _ = try? await request("deactivate", ["license_key": key, "license_key_instance_id": response.id])
            throw LicenseServiceError(String(localized: "This license is for a different product. Use your Kilobat license key."))
        }
        return AppLicense(key: key, instanceID: response.id, businessID: response.business_id, productID: product.product_id, keyID: response.license_key_id)
    }

    public func validate(_ license: AppLicense) async throws -> Bool {
        struct Validation: Decodable { let valid: Bool }
        let data = try await request("validate", ["license_key": license.key, "license_key_instance_id": license.instanceID])
        return try JSONDecoder().decode(Validation.self, from: data).valid
    }

    public func deactivate(_ license: AppLicense) async throws {
        _ = try await request("deactivate", ["license_key": license.key, "license_key_instance_id": license.instanceID])
    }

    private func request(_ action: String, _ body: [String: String]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("licenses/" + action))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, status) = try await transport(request)
        guard (200..<300).contains(status) else {
            switch status {
            case 403, 404: throw LicenseServiceError(String(localized: "This license is unavailable. Check the key or contact support."))
            case 422: throw LicenseServiceError(String(localized: "The license could not be activated. If both Mac slots are used, deactivate Kilobat on an old Mac or contact support to free a slot."))
            case 429: throw LicenseServiceError(String(localized: "Too many requests. Wait a moment and try again."))
            default: throw LicenseServiceError(String(localized: "The license service is temporarily unavailable. An already activated Mac keeps working offline."))
            }
        }
        guard data.count <= 1_048_576 else { throw LicenseServiceError(String(localized: "Unexpected license response. Try again later.")) }
        return data
    }
}

/// What the license server knows about a Pro owner's referrals. Purchases count once their refund window has passed.
public struct ReferralStatus: Codable, Sendable, Equatable {
    public let code: String
    public let url: URL
    /// Friends whose purchase has cleared the refund window.
    public let friends: Int
    /// Purchases still inside the refund window.
    public let pending: Int
    /// Mac slots added to the license, one for each friend.
    public let extraMacs: Int
    /// Single-use checkout codes for a free license, one for every third friend.
    public let gifts: [String]
    public static let friendsPerGift = 3
    public var friendsToNextGift: Int { Self.friendsPerGift - friends % Self.friendsPerGift }
    /// The link without its scheme, for posts and the app's link field: kilobat.app/r/<code>.
    public var shortURL: String { url.host().map { $0 + url.path() } ?? url.absoluteString }
    public init(code: String, url: URL, friends: Int, pending: Int, extraMacs: Int, gifts: [String]) {
        self.code = code; self.url = url; self.friends = friends; self.pending = pending; self.extraMacs = extraMacs; self.gifts = gifts
    }
}

/// Kilobat's own referral endpoints on kilobat.app. The app sends the license it already holds to fetch its link;
/// the server keeps the signing secret and the payment provider's key.
public struct ReferralClient: Sendable {
    public typealias Transport = LicenseClient.Transport
    private let baseURL: URL
    private let transport: Transport

    public init(website: URL, transport: Transport? = nil) {
        baseURL = website.appendingPathComponent("api/referral")
        self.transport = transport ?? { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw LicenseServiceError(String(localized: "Kilobat’s referral service returned an unexpected response. Try again later.")) }
            return (data, response.statusCode)
        }
    }

    /// The owner's link and rewards. The server checks the license with the payment provider before answering.
    public func status(_ license: AppLicense) async throws -> ReferralStatus {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["license_key": license.key, "license_key_instance_id": license.instanceID]
        body["license_key_id"] = license.keyID
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await send(request)
        let status = try JSONDecoder().decode(ReferralStatus.self, from: data)
        guard ReferralCode.parse(status.code) == status.code else { throw LicenseServiceError(String(localized: "Unexpected referral response. Try again later.")) }
        return status
    }

    /// Whether a code belongs to a Pro owner, before this Mac spends its one referral on it.
    public func exists(_ code: String) async throws -> Bool {
        guard let code = ReferralCode.parse(code) else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent(code))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Answer: Decodable { let valid: Bool }
        return try await JSONDecoder().decode(Answer.self, from: send(request, missing: Data(#"{"valid":false}"#.utf8))).valid
    }

    /// `missing` answers a 404, for lookups where an unknown code is an answer rather than an error.
    private func send(_ request: URLRequest, missing: Data? = nil) async throws -> Data {
        let (data, status) = try await transport(request)
        if status == 404, let missing { return missing }
        guard (200..<300).contains(status) else {
            switch status {
            case 403: throw LicenseServiceError(String(localized: "Your license couldn’t be confirmed. Check that Pro is still active on this Mac."))
            case 429: throw LicenseServiceError(String(localized: "Too many requests. Wait a moment and try again."))
            case 503: throw ReferralsNotOffered()
            default: throw LicenseServiceError(String(localized: "Kilobat’s referral service is temporarily unavailable. Try again later."))
            }
        }
        guard data.count <= 65_536 else { throw LicenseServiceError(String(localized: "Unexpected referral response. Try again later.")) }
        return data
    }
}
