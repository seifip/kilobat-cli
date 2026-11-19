import Foundation
import CryptoKit
import CoreFoundation

public enum TeamsJSON {
    public static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    public static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; d.dateDecodingStrategy = .custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO8601 date"))
    }; return d }
    public static func base64url(_ string: String) -> Data? { let s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); return Data(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4)) }
}
public struct TeamsPolicy: Codable, Sendable, Equatable {
    public var revision: Int
    public var automaticUpdates: Bool?
    public var productAnalytics: Bool?
    public var reportEnabled: Bool
    public var telemetryEnabled: Bool
    public var retentionDays: Int
    public var presets: [TeamsPreset]?
    public var lockedSettings: TeamsLockedSettings?
}
public struct TeamsOrganization: Codable, Sendable { public var id: String; public var name: String; public var reportEmail: String? }
public struct TeamsEntitlement: Codable, Sendable {
    public var keyId: String; public var payload: String; public var signature: String
    public struct Claims: Codable, Sendable { public var schemaVersion: Int; public var organizationId: String; public var deviceId: String; public var issuedAt: Date; public var expiresAt: Date; public var epoch: Int; public var features: [String] }
    public func verified(keys: [String: Data], organization: String, device: String, now: Date, lastSeen: Date, minimumEpoch: Int = 0) -> Claims? {
        guard let key = keys[keyId], let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key), let bytes = TeamsJSON.base64url(payload), let signature = TeamsJSON.base64url(signature), publicKey.isValidSignature(signature, for: bytes), let claims = try? TeamsJSON.decoder().decode(Claims.self, from: bytes), claims.schemaVersion == 1, claims.organizationId == organization, claims.deviceId == device, claims.epoch >= minimumEpoch, claims.issuedAt <= now.addingTimeInterval(300), claims.expiresAt > max(now, lastSeen), claims.expiresAt.timeIntervalSince(claims.issuedAt) <= 7 * 86400 + 300, claims.features.contains("teams"), claims.features.contains("pro") else { return nil }
        return claims
    }
}
/// This is the complete upload allowlist. DiagnosticSnapshot itself must never be encoded for Teams.
public struct TeamsHealthSample: Codable, Sendable, Equatable {
    public var observedAt: Date
    public var intervalSeconds: Int
    public var connectionType: String
    public var wifiRssiDbm: Int?
    public var wifiNoiseDbm: Int?
    public var wifiBand: String?
    public var wifiChannel: Int?
    public var routerLatencyMs: Double?
    public var routerLossPercent: Double?
    public var internetLatencyMs: Double?
    public var internetLossPercent: Double?
    public var internetJitterMs: Double?
    public var dnsLatencyMs: Double?
    public var vpnState: String
    public var health: String
    public var reasonCodes: [String]
    public var coverage: String
    public init(snapshot: DiagnosticSnapshot, interval: Int, vpn: ExitPath.VPN?) {
        func number(_ n: Double?, _ maximum: Double = 60000) -> Double? { n.flatMap { $0.isFinite && $0 >= 0 && $0 <= maximum ? $0 : nil } }
        observedAt = snapshot.date; intervalSeconds = min(3600, max(1, interval))
        connectionType = snapshot.wiredInterface != nil ? "ethernet" : snapshot.radio.interface != nil ? "wifi" : "unknown"
        let wifi = connectionType == "wifi"
        wifiRssiDbm = wifi ? snapshot.radio.rssi.flatMap { (-127...0).contains($0) ? $0 : nil } : nil
        wifiNoiseDbm = wifi ? snapshot.radio.noise.flatMap { (-127...0).contains($0) ? $0 : nil } : nil
        wifiBand = wifi ? snapshot.radio.band.flatMap { let band = $0.replacingOccurrences(of: " GHz", with: ""); return ["2.4", "5", "6"].contains(band) ? band : nil } : nil
        wifiChannel = wifi ? snapshot.radio.channel.flatMap { (1...233).contains($0) ? $0 : nil } : nil
        routerLatencyMs = number(snapshot.router?.average); routerLossPercent = number(snapshot.router?.lossPercent, 100)
        internetLatencyMs = number(snapshot.measured.average); internetLossPercent = number(snapshot.measured.lossPercent, 100)
        internetJitterMs = number(snapshot.measured.jitter); dnsLatencyMs = number(snapshot.dnsMilliseconds)
        vpnState = vpn?.rawValue ?? "unknown"; health = snapshot.health.rawValue; coverage = "observed"
        reasonCodes = []
        if snapshot.captivePortal == true { reasonCodes.append("insufficient_evidence") }
        if let loss = internetLossPercent, loss > 0 { reasonCodes.append("upstream_loss") }
        if let latency = routerLatencyMs, latency > 20 { reasonCodes.append("router_latency") }
        if let latency = dnsLatencyMs, latency > 150 { reasonCodes.append("dns_slow") }
    }
}
public struct TeamsBatch: Codable, Sendable { public var schemaVersion = 1; public var batchId: String; public var samples: [TeamsHealthSample] }
/// Atomic on-disk queue. Only sanitized DTOs enter it. An acknowledgement removes exactly its immutable batch.
public struct TeamsSpool: Codable, Sendable {
    public private(set) var batches: [TeamsBatch] = []
    public private(set) var pending: [TeamsHealthSample] = []
    public private(set) var droppedSamples = 0
    public var sampleCount: Int { pending.count + batches.reduce(0) { $0 + $1.samples.count } }
    public init() {}
    public mutating func append(_ sample: TeamsHealthSample, now: Date = Date(), maxBytes: Int = 25_000_000) throws {
        pending.append(sample)
        sealDue(now: now)
        while let oldest = batches.first?.samples.first?.observedAt ?? pending.first?.observedAt {
            let oversized = try TeamsJSON.encoder().encode(self).count > maxBytes
            guard oldest < now.addingTimeInterval(-7 * 86400) || oversized else { break }
            if !batches.isEmpty { droppedSamples += batches.removeFirst().samples.count } else { pending.removeFirst(); droppedSamples += 1 }
        }
    }
    public mutating func sealPending() {
        guard !pending.isEmpty else { return }
        batches.append(TeamsBatch(batchId: UUID().uuidString, samples: pending)); pending = []
    }
    public mutating func sealDue(now: Date = Date()) {
        if pending.count >= 5 || pending.first.map({ now.timeIntervalSince($0.observedAt) >= 300 }) == true { sealPending() }
    }
    public mutating func acknowledge(_ batchID: String) { batches.removeAll { $0.batchId == batchID } }
    public func save(to url: URL) throws { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try TeamsJSON.encoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
}
/// Only genuinely forced configuration counts as MDM. Ordinary local defaults cannot enrol a Mac.
public enum TeamsManagedPreferences {
    public static func string(_ key: String, defaults: UserDefaults = .standard) -> String? { guard defaults.objectIsForced(forKey: key) else { return nil }; return defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }
    public static func bool(_ key: String, defaults: UserDefaults = .standard) -> Bool? { guard defaults.objectIsForced(forKey: key), let value = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue }
}

public struct TeamsBlockRule: Codable, Sendable, Equatable { public var kind: String; public var bundleId: String }
public struct TeamsPreset: Codable, Sendable, Equatable { public var id: String; public var name: String; public var rules: [TeamsBlockRule] }
public struct TeamsLockedSettings: Codable, Sendable, Equatable { public var blockRules: [TeamsBlockRule]? }
public enum TeamsRuleEnforcement {
    /// Shared by app, CLI and filter configuration generation. Unknown rule kinds never become arbitrary actions.
    public static func blockedApps(defaults: UserDefaults = .standard) -> [String] {
        guard TeamsManagedPreferences.string("TeamToken", defaults: defaults) != nil else { return [] }
        let forced = defaults.objectIsForced(forKey: "TeamsBlockedBundleIDs") ? defaults.stringArray(forKey: "TeamsBlockedBundleIDs") ?? [] : []
        // Server presets are an optional employee choice; only MDM forced preferences are a lock authority.
        let data = defaults.data(forKey: "teams.appliedPolicy")
        let policy = data.flatMap { try? TeamsJSON.decoder().decode(TeamsPolicy.self, from: $0) }
        let selected = defaults.string(forKey: "teams.selectedPreset")
        let presetRules = policy?.presets?.first(where: { $0.id == selected })?.rules ?? []
        return Array(Set(forced + presetRules.filter { $0.kind == "block_app" }.map(\.bundleId))).filter { $0.count <= 255 && $0.contains(".") }

    }
}
