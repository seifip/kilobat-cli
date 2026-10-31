import Foundation

/// A quick look at the line before a call: the same causes a call report names, checked in about ten seconds.
public struct Preflight: Codable, Sendable, Equatable {
    public struct Issue: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case app, wifi, unstable, airDrop, mac }
        public let kind: Kind
        public var app: String? = nil
        public var uploading: Bool? = nil
        public init(kind: Kind, app: String? = nil, uploading: Bool? = nil) { self.kind = kind; self.app = app; self.uploading = uploading }
        /// "Dropbox is uploading", "Wi-Fi is weak".
        public var phrase: String {
            switch kind {
            case .app: uploading == true ? String(localized: "\(app ?? "an app") is uploading", comment: "Before a call; the argument is an app")
                                         : String(localized: "\(app ?? "an app") is downloading", comment: "Before a call; the argument is an app")
            case .wifi: String(localized: "Wi-Fi is weak", comment: "Before a call")
            case .unstable: String(localized: "the connection is dropping pings", comment: "Before a call")
            case .airDrop: String(localized: "AirDrop is scanning", comment: "Before a call")
            case .mac: app.map { String(localized: "\($0) is maxing out the CPU", comment: "Before a call; the argument is a process") } ?? String(localized: "the Mac is overloaded", comment: "Before a call")
            }
        }
    }
    public let date: Date
    public let issues: [Issue]
    public var clear: Bool { issues.isEmpty }
    /// "Dropbox is uploading and Wi-Fi is weak", with the first letter capitalized.
    public var summary: String {
        guard !issues.isEmpty else { return String(localized: "The line looks good.", comment: "Before a call: nothing to fix") }
        let text = issues.map(\.phrase).formatted(.list(type: .and))
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    /// The busy apps call mode can hold until the call ends.
    public var holdable: [String] { issues.compactMap { $0.kind == .app ? $0.app.flatMap { CallMode.known.map(\.name).contains($0) ? $0 : nil } : nil } }
}

public enum PreflightCheck {
    /// The calling service a meeting's link, location or notes point to.
    public static func meeting(in text: String) -> String? {
        let lower = text.lowercased()
        let services: [(String, String)] = [("zoom.us/", "Zoom"), ("zoomgov.com/", "Zoom"), ("meet.google.com/", "Google Meet"), ("teams.microsoft.com/", "Microsoft Teams"),
                                            ("teams.live.com/", "Microsoft Teams"), ("facetime.apple.com/", "FaceTime"), ("webex.com/", "Webex"), ("whereby.com/", "Whereby"),
                                            ("discord.gg/", "Discord"), ("app.slack.com/huddle", "Slack"), ("around.co/", "Around"), ("gotomeeting.com/", "GoTo Meeting"), ("chime.aws/", "Amazon Chime")]
        return services.first { lower.contains($0.0) }?.1
    }

    /// Ten seconds of checks: other apps' traffic three times, the Wi-Fi, 100 quick pings to the internet, AirDrop and the Mac's load.
    @MainActor public static func run(traffic: TrafficStore, diagnostics: DiagnosticStore) async -> Preflight {
        let ticks = MacLoad.ticks()
        async let pings = try? StutterTest.run(target: "internet", seconds: 5)
        async let airDrop = NearbyRadios.awdlStatus()
        var busy: [String: (hits: Int, up: Double, down: Double)] = [:]
        for round in 0..<3 {
            if round > 0 { try? await Task.sleep(for: .seconds(2)) }
            for app in traffic.apps where !app.carrier && (app.uploadRate >= CallAnalysis.uploadLoad || app.downloadRate >= CallAnalysis.downloadLoad) {
                let entry = busy[app.name] ?? (0, 0, 0)
                busy[app.name] = (entry.hits + 1, max(entry.up, app.uploadRate), max(entry.down, app.downloadRate))
            }
        }
        var issues = busy.filter { $0.value.hits >= 2 }.sorted { $0.value.up + $0.value.down > $1.value.up + $1.value.down }.prefix(2)
            .map { Preflight.Issue(kind: .app, app: $0.key, uploading: $0.value.up / CallAnalysis.uploadLoad >= $0.value.down / CallAnalysis.downloadLoad) }
        if diagnostics.snapshot?.radio.health == .poor { issues.append(.init(kind: .wifi)) }
        if let result = await pings, result.lossPercent >= 5 || (result.p95 ?? 0) > (result.p50 ?? 0) + 150 { issues.append(.init(kind: .unstable)) }
        if await airDrop.active { issues.append(.init(kind: .airDrop)) }
        if let ticks, let (load, _) = await MacLoad.sample(since: ticks), load.cpuMaxed || load.memoryOut || load.throttled {
            issues.append(.init(kind: .mac, app: load.cpuMaxed ? load.top : nil))
        }
        return Preflight(date: Date(), issues: issues)
    }
}
