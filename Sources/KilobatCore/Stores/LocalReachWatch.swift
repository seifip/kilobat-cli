import Foundation
import Observation

/// "Can I cast or print here?" for the network the Mac is on: checked a few seconds after joining a network and when
/// asked, kept per network for the session. Also remembers the Wi-Fi the Mac was on before a device's own network
/// (a printer's Wi-Fi Direct, a camera's), so it can go back.
@MainActor @Observable public final class LocalReachWatch {
    nonisolated public static let onJoinKey = "localReachOnJoin"
    nonisolated public static func onJoinEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: onJoinKey) as? Bool ?? true }
    /// A check this old is run again when the Mac comes back to the network.
    public static let fresh: TimeInterval = 3600
    /// The wait after joining, so DHCP, the sign-in page check and Bonjour have settled.
    public static let settle: Duration = .seconds(6)

    /// The latest check on the network the Mac is on now.
    public private(set) var check: LocalReachCheck?
    public private(set) var checking = false
    /// The Mac is on a device's own Wi-Fi.
    public private(set) var setup: SetupNetworkMatch?
    /// The ordinary Wi-Fi before the device's own one, to go back to.
    public private(set) var previous: String?
    public private(set) var returning = false
    public var error: String?
    /// Hook for device types: each check's TVs, AirPlay receivers and printers by name and model, with the network's
    /// key, so the device registry can label the matching devices (a Chromecast as a TV, an IPP record as a printer).
    @ObservationIgnored public var onServices: ((_ network: String, _ services: [LocalService]) -> Void)?

    /// Injectable for tests; production uses Bonjour and local peer probes.
    @ObservationIgnored var runProbe: (String?, String?, String?, Bool, Bool) async -> LocalReachCheck = { network, gateway, interface, portal, sweep in
        await LocalReachProbe.run(network: network, gateway: gateway, interface: interface, portal: portal, sweep: sweep)
    }
    @ObservationIgnored private var current: String?
    @ObservationIgnored private var lastOrdinary: String?
    @ObservationIgnored private var results: [String: LocalReachCheck] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var sample: DiagnosticSnapshot?
    @ObservationIgnored private var portal = false

    public init() {}

    #if DEBUG
    /// Made-up state for screenshots; debug builds only.
    public func preview(_ check: LocalReachCheck?, setup: SetupNetworkMatch? = nil, previous: String? = nil) {
        pending?.cancel(); self.check = check; self.setup = setup; self.previous = previous
    }
    #endif

    /// Takes one health check. A new network gets its check after `settle`, unless one from the last hour is kept.
    public func observe(_ sample: DiagnosticSnapshot, portal: Bool, automatic: Bool = LocalReachWatch.onJoinEnabled()) {
        self.sample = sample; self.portal = portal
        setup = sample.setupNetwork
        let ssid = sample.wiredInterface == nil ? sample.radio.ssid : nil
        if setup == nil {
            if let ssid { lastOrdinary = ssid }
            previous = nil
        } else if let lastOrdinary, lastOrdinary != ssid { previous = lastOrdinary }
        let key = sample.networkKey
        guard key != current else { return }
        current = key
        pending?.cancel(); checking = false
        check = results[key].flatMap { Date().timeIntervalSince($0.date) < Self.fresh ? $0 : nil }
        guard check == nil, automatic, sample.networkIdentified || sample.setupNetwork != nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    /// Checks now (the button, the CLI through the relay).
    @discardableResult public func run(sweep: Bool = true) async -> LocalReachCheck? {
        guard !checking, let sample else { return nil }
        checking = true; defer { checking = false }
        let key = sample.networkKey
        let interface = sample.wiredInterface ?? sample.radio.interface
        let result = await runProbe(sample.networkName, sample.gateway, interface, portal, sweep)
        results[key] = result
        if !result.services.isEmpty { onServices?(key, result.services) }
        if key == current { check = result }
        return key == current ? result : nil
    }

    /// Joins the Wi-Fi the Mac was on before the device's own, with the password macOS saved.
    public func goBack(then diagnose: @escaping @MainActor () async -> Void) async {
        guard let previous, !returning else { return }
        returning = true; error = nil
        defer { returning = false }
        do { try await WiFiConnection().join(name: previous); await diagnose() }
        catch { self.error = String(localized: "Couldn’t rejoin \(previous): \(error.localizedDescription)", comment: "Device Wi-Fi; the arguments are a Wi-Fi name and an error") }
    }
}
