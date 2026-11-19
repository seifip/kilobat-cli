import Foundation

/// The CLI, network filter and free desktop features never depend on commercial access state.
public struct AppLicense: Codable, Sendable, Equatable {
    public let key: String
    public let instanceID: String
    public let businessID: String
    public let productID: String
    public let activatedAt: Date
    public var lastValidatedAt: Date
    public var revoked: Bool
    /// Dodo's lic_ id for the key, saved from 1.4 on. It saves the referral server a search; it grants nothing.
    public let keyID: String?
    /// True when the person deactivated this Mac themselves. Such a license is never checked again; one the license
    /// service called invalid is, so it can come back. Nil on records saved before this was kept.
    public var deactivatedHere: Bool? = nil

    public init(key: String, instanceID: String, businessID: String, productID: String, keyID: String? = nil, now: Date = Date()) {
        self.key = key; self.instanceID = instanceID; self.businessID = businessID
        self.productID = productID; self.keyID = keyID; activatedAt = now; lastValidatedAt = now; revoked = false
    }
    public func matches(business: String, products: Set<String>) -> Bool {
        !revoked && businessID == business && products.contains(productID)
    }
}

public struct AppTrial: Codable, Sendable, Equatable {
    public static let duration: TimeInterval = 7 * 24 * 60 * 60
    /// A friend's referral link makes the trial a month.
    public static let referralDuration: TimeInterval = 30 * 24 * 60 * 60
    /// Trials saved without a length were started under 1.0, which offered 14 days.
    static let legacyDuration: TimeInterval = 14 * 24 * 60 * 60
    public let startedAt: Date
    public private(set) var lastSeenAt: Date
    private let length: TimeInterval?
    /// The referral code that made this a month-long trial. It is saved with the trial, so a Mac claims one only once.
    public let referral: String?
    public init(now: Date = Date()) { startedAt = now; lastSeenAt = now; length = Self.duration; referral = nil }
    private init(startedAt: Date, referral: String) {
        self.startedAt = startedAt; lastSeenAt = startedAt; length = Self.referralDuration; self.referral = referral
    }
    /// A month from now, or from the latest time this Mac has seen if its clock was turned back.
    /// Nil once this Mac claimed any referral: a code can't restart or stretch a trial a second time.
    public static func referred(_ code: String, replacing trial: AppTrial?, now: Date = Date()) -> AppTrial? {
        guard trial?.referral == nil else { return nil }
        return AppTrial(startedAt: max(now, trial?.lastSeenAt ?? now), referral: code)
    }
    public var days: Int { Int(((length ?? Self.legacyDuration) / 86400).rounded()) }
    public mutating func observe(_ now: Date) { lastSeenAt = max(lastSeenAt, now) }
    public func remaining(at now: Date) -> TimeInterval {
        max(0, (length ?? Self.legacyDuration) - max(now, lastSeenAt).timeIntervalSince(startedAt))
    }
    public func fraction(at now: Date) -> Double { remaining(at: now) / (length ?? Self.legacyDuration) }
    public func daysRemaining(at now: Date) -> Int { Int(ceil(remaining(at: now) / 86400)) }
}

/// The short code in a Pro owner's kilobat.app/r/<code> link. The license server derives it from the
/// license with a keyed hash, so it never reveals the key and nobody can work it out from one.
public enum ReferralCode {
    static let alphabet = Set("0123456789abcdefghjkmnpqrstvwxyz")
    public static let length = 10
    /// Lowercased and checked against the server's alphabet; anything else is not a code.
    public static func parse(_ value: String) -> String? {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return code.count == length && code.allSatisfy(alphabet.contains) ? code : nil
    }
    /// The checkout link carrying the code as metadata, so the license server credits whoever shared it.
    public static func checkout(_ url: URL, code: String?) -> URL {
        guard let code, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "metadata_referral" } + [URLQueryItem(name: "metadata_referral", value: code)]
        return components.url ?? url
    }
}

/// Pro unlocks individual desktop features; the free app and the CLI never ask.
public enum ProAccess {
    public static func unlocked(license: AppLicense?, trial: AppTrial?, business: String, products: Set<String>, configured: Bool, now: Date) -> Bool {
        license?.matches(business: business, products: products) == true || (configured && (trial?.remaining(at: now) ?? 0) > 0)
    }
}

/// How a locked Pro control presents itself, wherever it is.
public enum ProLock {
    /// What a Pro switch shows: off without Pro, whatever is stored. The stored value is never changed. A setting that
    /// `stillActs` without Pro (the filter keeps enforcing it) shows what is stored, so the switch never under-reports it.
    public static func shown(_ stored: Bool, pro: Bool, stillActs: Bool = false) -> Bool { (pro || stillActs) && stored }
    /// Whether turning a Pro switch `on` or off goes through: always with Pro; without it, only turning off a setting
    /// that still acts, since that only lets more through.
    public static func permits(_ on: Bool, pro: Bool, stillActs: Bool = false) -> Bool { pro || (stillActs && !on) }
    /// A menu or button title, marked while locked. "Pro" is never translated.
    public static func title(_ title: String, pro: Bool) -> String { pro ? title : title + " · Pro" }
    /// Files of the person's own (rules, settings, usage): writing one out is part of Pro.
    public static func permitsExport(pro: Bool) -> Bool { pro }
    /// Reading one of those files back never is: putting your own things back is never gated, and it unlocks nothing,
    /// since settings that need Pro stay stored and inert without it.
    public static func permitsImport(pro: Bool) -> Bool { true }
}

/// When to ask the license service whether a saved license still stands.
public enum LicenseCheck {
    public static let interval: TimeInterval = 86_400
    /// After a check that couldn't reach the service, wait this long before the next.
    public static let retry: TimeInterval = 3_600
    /// Due once a day for this product's license, revoked or not, unless the person deactivated it here.
    public static func due(_ license: AppLicense?, business: String, products: Set<String>, lastAttempt: Date?, now: Date) -> Bool {
        guard let license, license.deactivatedHere != true, license.businessID == business, products.contains(license.productID) else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retry { return false }
        return now.timeIntervalSince(license.lastValidatedAt) >= interval
    }
}
