import Foundation
import Observation

/// The app's latest smart-home check, for Devices › Smart home and Health's line. A check runs when Devices opens
/// (or the person asks); Health checks again on its own only on a network where one found smart-home devices, at most
/// every half hour, so a network without any never sees Bonjour browsing it didn't ask for.
@MainActor @Observable public final class SmartHomeWatch {
    public static let shared = SmartHomeWatch()
    public private(set) var report: SmartHomeReport?
    /// The network key the report belongs to.
    public private(set) var network: String?
    public private(set) var checking = false
    @ObservationIgnored private let defaults: UserDefaults
    static let rememberedKey = "smartHomeNetworks"
    static let stale: TimeInterval = 1800

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func check(network: String?, diagnostics: DiagnosticStore) async {
        // A new Devices task may arrive while the cancelled old-network browse is settling.
        // Wait for it so the new network still gets its own check.
        while checking {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled else { return }
        checking = true; defer { checking = false }
        let startingNetwork = diagnostics.snapshot?.networkKey
        let radio: RadioSample
        if let sample = diagnostics.radio { radio = sample } else { radio = await DiagnosticProbe().radio() }
        let cached = diagnostics.networks, allowed = diagnostics.locationAllowed
        let scanning = radio.interface != nil && radio.band != "2.4 GHz"
        let result = await SmartHomeProbe.run(wifiInterface: radio.interface, ssid: radio.ssid, band: radio.band) {
            guard scanning else { return nil }
            if !cached.isEmpty { return cached }
            return allowed ? try? await DiagnosticProbe().scan() : nil
        }
        // A task tied to Devices is cancelled when its network changes. Never publish its old report.
        guard !Task.isCancelled, diagnostics.snapshot?.networkKey == startingNetwork else { return }
        report = result; self.network = network
        remember(network, found: result.devicesFound)
    }

    /// Health: checks again on a network that had smart-home devices, when the last check is old or from elsewhere.
    public func refreshIfNeeded(network: String?, diagnostics: DiagnosticStore) async {
        guard let network, remembered.contains(network) else { return }
        if let report, self.network == network, Date().timeIntervalSince(report.date) < Self.stale { return }
        await check(network: network, diagnostics: diagnostics)
    }

    /// Health's line for `network`: only when something is wrong and there are smart-home devices.
    public func healthIssue(network: String?) -> (title: String, detail: String)? {
        guard let network, self.network == network else { return nil }
        return report?.healthIssue
    }

    /// For sample screenshots.
    public func preview(_ report: SmartHomeReport?, network: String?) { self.report = report; self.network = network }

    private var remembered: Set<String> { Set(defaults.stringArray(forKey: Self.rememberedKey) ?? []) }
    func remember(_ network: String?, found: Bool) {
        guard let network else { return }
        var set = remembered
        if found { set.insert(network) } else { set.remove(network) }
        defaults.set(Array(set.sorted().suffix(20)), forKey: Self.rememberedKey)
    }
}
