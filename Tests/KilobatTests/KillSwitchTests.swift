import Foundation
import Testing
@testable import KilobatCore

struct KillSwitchPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let down = KillSwitchPolicy(armed: true, vpnDown: true, vpnApps: ["com.example.CorpVPN"])
    private let up = KillSwitchPolicy(armed: true, vpnDown: false, tunnel: "utun4")

    private func filter(_ killSwitch: KillSwitchPolicy, profile: NetworkProfile = .work, allow: [String: Bool] = [:]) -> FilterPolicy {
        var preferences = SavedPreferences()
        preferences.profile = profile; preferences.defaultAllow = true
        preferences.rules[profile.rawValue] = allow
        return FilterPolicy(FilterController.policy(preferences, budgetReached: false, killSwitch: killSwitch))
    }
    private func flow(_ app: String?, process: String = "", host: String? = "example.com", address: String? = "93.184.216.34", port: String? = "443") -> FilterPolicy.Flow {
        .init(app: app, process: process, host: host, address: address, port: port)
    }

    @Test func blocksOrdinaryAppsOnlyWhileTheVPNIsDown() {
        #expect(filter(down).decide(flow("com.apple.Safari"), now: now).reason == .killSwitch)
        #expect(filter(down).decide(flow("com.apple.Safari"), now: now).verdict == .block)
        #expect(filter(up).decide(flow("com.apple.Safari"), now: now).verdict == .allow)
        #expect(filter(KillSwitchPolicy()).decide(flow("com.apple.Safari"), now: now).verdict == .allow)
        // Off unless armed, whatever the reading.
        #expect(filter(KillSwitchPolicy(armed: false, vpnDown: true)).decide(flow("com.apple.Safari"), now: now).verdict == .allow)
    }

    @Test func winsOverAllowRulesAndUnrestricted() {
        #expect(filter(down, allow: ["com.apple.Safari": true]).decide(flow("com.apple.Safari"), now: now).reason == .killSwitch)
        #expect(filter(down, profile: .unrestricted).decide(flow("com.apple.Safari"), now: now).reason == .killSwitch)
        #expect(filter(up, profile: .unrestricted).decide(flow("com.apple.Safari"), now: now).reason == .unrestricted)
        // A flow with no app identity gets no pass either.
        #expect(filter(down).decide(flow(nil), now: now).verdict == .block)
    }

    @Test func letsTheVPNReconnect() {
        let policy = filter(down, profile: .travel)
        for (app, process) in [("com.wireguard.macos.network-extension", "WireGuardNetworkExtension"), ("io.tailscale.ipn.macsys", "Tailscale"),
                               ("net.mullvad.vpn", "Mullvad VPN"), ("com.nordvpn.macos", "NordVPN"), ("ch.protonvpn.mac", "ProtonVPN"),
                               ("com.cisco.secureclient.vpnagentd", "vpnagentd"), ("com.paloaltonetworks.GlobalProtect.client", "GlobalProtect"),
                               ("net.tunnelblick.tunnelblick", "Tunnelblick"), ("com.example.CorpVPN.extension", "CorpVPN"), ("openvpn", "openvpn")] {
            let decision = policy.decide(flow(app, process: process), now: now)
            #expect(decision.verdict == .allow, "\(app)")
            if case .killSwitchExempt(.vpnApp) = decision.reason {} else { Issue.record("\(app): \(decision.reason)") }
        }
        // Executables VPNs run under their own names, whatever they're signed as.
        #expect(policy.decide(flow("wireguard-go-signed", process: "wireguard-go"), now: now).verdict == .allow)
        // A name that only resembles one doesn't count.
        #expect(policy.decide(flow("com.wireguardish.app"), now: now).verdict == .block)
    }

    @Test func appleNetworkingNeedsApplesSignature() {
        let policy = filter(down)
        for app in ["com.apple.CaptiveNetworkAssistant", "com.apple.captiveagent", "com.apple.configd", "com.apple.mDNSResponder", "com.apple.neagent", "com.apple.NetworkExtension.IKEv2Provider"] {
            #expect(policy.decide(flow(app), now: now, appleSigned: { true }).reason == .killSwitchExempt(.appleNetworking(app)), "\(app)")
            #expect(policy.decide(flow(app), now: now, appleSigned: { false }).reason == .killSwitch, "\(app)")
        }
        // Apple's other software waits like everything else.
        #expect(policy.decide(flow("com.apple.Safari"), now: now, appleSigned: { true }).reason == .killSwitch)
        #expect(policy.decide(flow("co.seifi.kilobat"), now: now).reason == .killSwitchExempt(.kilobat))
    }

    @Test func localNetworkFollowsItsSettingAndTheAppsRules() {
        let lan = flow("com.apple.Safari", host: "printer.local", address: "192.168.1.20", port: "631")
        #expect(filter(down).decide(lan, now: now).verdict == .allow)
        var blockLAN = down; blockLAN.allowLAN = false
        #expect(filter(blockLAN).decide(lan, now: now).reason == .killSwitch)
        // Allowed past the kill switch, the app's own rule still applies.
        #expect(filter(down, allow: ["com.apple.Safari": false]).decide(lan, now: now).verdict == .block)
        // A port number alone cannot prove the flow is DHCP.
        #expect(filter(blockLAN).decide(flow(nil, address: "255.255.255.255", port: "67"), now: now).verdict == .block)
        for address in ["10.0.0.1", "172.20.1.1", "192.168.0.10", "169.254.3.4", "224.0.0.251", "fe80::1", "fd00::5", "ff02::fb"] {
            #expect(KillSwitchPolicy.isLocal(host: nil, address: address), "\(address)")
        }
        for address in ["8.8.8.8", "100.101.102.103", "172.32.0.1", "2001:4860::8888"] { #expect(!KillSwitchPolicy.isLocal(host: nil, address: address), "\(address)") }
        #expect(KillSwitchPolicy.isLocal(host: "NAS.local.", address: nil))
        #expect(!KillSwitchPolicy.isLocal(host: "example.com", address: nil))
    }

    @Test func allowForFiveMinutesExpiresInTheFilter() {
        var paused = down; paused.allowedUntil = now.addingTimeInterval(300)
        #expect(filter(paused).decide(flow("com.apple.Safari"), now: now).verdict == .allow)
        #expect(filter(paused).decide(flow("com.apple.Safari"), now: now.addingTimeInterval(299)).verdict == .allow)
        #expect(filter(paused).decide(flow("com.apple.Safari"), now: now.addingTimeInterval(301)).reason == .killSwitch)
    }

    @Test func blocksWhenTheTunnelGoesAwayBeforeTheAppNotices() {
        let policy = filter(up)
        #expect(policy.decide(flow("com.apple.Safari"), now: now, tunnelUp: { $0 == "utun4" }).verdict == .allow)
        #expect(policy.decide(flow("com.apple.Safari"), now: now, tunnelUp: { _ in false }).reason == .killSwitch)
        // The doctor and tests trust the app's reading.
        #expect(policy.decide(flow("com.apple.Safari"), now: now).verdict == .allow)
        #expect(KillSwitchPolicy.interfaceUp("lo0"))
        #expect(!KillSwitchPolicy.interfaceUp("utun-not-there"))
    }

    @Test func configurationRoundTrips() throws {
        let original = KillSwitchPolicy(armed: true, vpnDown: false, tunnel: "utun7", allowedUntil: now, allowLAN: false, vpnApps: ["b.vpn", "a.vpn"])
        let data = try JSONSerialization.data(withJSONObject: original.configuration)
        let back = KillSwitchPolicy(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(back == KillSwitchPolicy(armed: true, vpnDown: false, tunnel: "utun7", allowedUntil: now, allowLAN: false, vpnApps: ["a.vpn", "b.vpn"]))
        #expect(KillSwitchPolicy(nil) == KillSwitchPolicy())
        #expect(KillSwitchPolicy().configuration.count == 1)
    }

    @Test func readsConfiguredVPNApps() {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   3B1F6C2A-0000 VPN (io.tailscale.ipn.macsys) "Tailscale"   [VPN:io.tailscale.ipn.macsys]
        * (Connected)      77AA0B1C-0000 VPN (com.wireguard.macos) "Office"        [VPN:com.wireguard.macos]
        * (Disconnected)   12345678-0000 IPSec               "Work IPSec"      [IPSec]
        * (Disconnected)   ABCDEF00-0000 VPN (com.apple.NetworkExtension.IKEv2) "Built-in" [VPN:com.apple.NetworkExtension.IKEv2]
        """
        #expect(KillSwitchPolicy.configuredApps(output) == ["io.tailscale.ipn.macsys", "com.wireguard.macos"])
        #expect(KillSwitchPolicy.configuredApps("No services") == [])
    }
}

struct KillSwitchStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let up = ExitPath(interface: "utun4", connected: ["Mullvad"])
    private let split = ExitPath(interface: "en0", connected: ["Tailscale"])
    private let off = ExitPath(interface: "en0")

    private func preferences(_ on: Bool = true, until: Date? = nil, lan: Bool? = nil) -> SavedPreferences {
        var preferences = SavedPreferences()
        preferences.killSwitch = on ? true : nil; preferences.killSwitchAllowedUntil = until; preferences.killSwitchLAN = lan
        return preferences
    }

    @Test func armsOnlyOnceTheVPNHasBeenUpThisBoot() {
        // Turning it on with no VPN never cuts the Mac off.
        #expect(KillSwitchState.arm(armedBoot: nil, boot: "A", enabled: true, vpnUp: false) == nil)
        #expect(KillSwitchState.arm(armedBoot: nil, boot: "A", enabled: true, vpnUp: true) == "A")
        // Once armed it stays armed through drops and network changes on the same boot.
        #expect(KillSwitchState.arm(armedBoot: "A", boot: "A", enabled: true, vpnUp: false) == "A")
        // A restart or turning it off forgets it.
        #expect(KillSwitchState.arm(armedBoot: "A", boot: "B", enabled: true, vpnUp: false) == nil)
        #expect(KillSwitchState.arm(armedBoot: "A", boot: "A", enabled: false, vpnUp: true) == nil)
        #expect(KillSwitchState.bootTime() > 0)
    }

    @Test func theRouteIsReadOnAnEventAndOtherwiseEveryThirtySeconds() {
        #expect(KillSwitchState.readDue(changed: true, hasReading: true, sinceLast: 0))
        #expect(KillSwitchState.readDue(changed: false, hasReading: false, sinceLast: 0))
        #expect(!KillSwitchState.readDue(changed: false, hasReading: true, sinceLast: 29))
        #expect(KillSwitchState.readDue(changed: false, hasReading: true, sinceLast: 30))
        // A clock set back doesn't hold the next reading off.
        #expect(KillSwitchState.readDue(changed: false, hasReading: true, sinceLast: -5))
        #expect(KillSwitchState.fallbackRead == 30)
    }

    @Test func armedStateSurvivesTheMoveToBootSessions() {
        // A session saved by this version is kept as it is; `arm` then decides whether it is this boot.
        #expect(KillSwitchState.armedSession(saved: "A", boot: "B", bootTime: 5) == "A")
        #expect(KillSwitchState.arm(armedBoot: KillSwitchState.armedSession(saved: "A", boot: "B", bootTime: 5), boot: "B", enabled: true, vpnUp: false) == nil)
        // A boot time saved by an older version carries over only when it is still this boot's.
        #expect(KillSwitchState.armedSession(saved: 100.0, boot: "A", bootTime: 100) == "A")
        #expect(KillSwitchState.armedSession(saved: 100.0, boot: "A", bootTime: 101) == nil)
        #expect(KillSwitchState.armedSession(saved: nil, boot: "A", bootTime: 100) == nil)
    }

    @Test func thisBootHasAnIdentity() {
        let session = KillSwitchState.bootSession()
        #expect(!session.isEmpty && session == KillSwitchState.bootSession())
        // The kernel's session identifier, not the boot-time fallback.
        #expect(UUID(uuidString: session) != nil)
    }

    @Test func aLapseIsOnlyProEndingOrTheFilterGoingOff() {
        func state(_ status: KillSwitchState.Status) -> KillSwitchState { KillSwitchState(status: status, enabled: status != .off) }
        #expect(KillSwitchState.lapse(wasArmed: true, next: state(.needsPro)) == .needsPro)
        #expect(KillSwitchState.lapse(wasArmed: true, next: state(.needsFilter)) == .needsFilter)
        #expect(KillSwitchState.lapse(wasArmed: false, next: state(.needsPro)) == nil)
        #expect(KillSwitchState.lapse(wasArmed: true, next: nil) == nil)
        for status in [KillSwitchState.Status.off, .waiting, .protected, .blocking, .allowed] {
            #expect(KillSwitchState.lapse(wasArmed: true, next: state(status)) == nil)
        }
        // What the monitor counts as armed: exactly the states that hand the filter an armed policy.
        for status in [KillSwitchState.Status.off, .needsPro, .needsFilter, .waiting, .protected, .blocking, .allowed] {
            #expect(state(status).enforcing == state(status).policy().armed)
        }
    }

    @Test func statusFollowsSettingProFilterArmingAndVPN() {
        func status(_ preferences: SavedPreferences, pro: Bool = true, filter: Bool = true, exit: ExitPath, armed: Bool = true) -> KillSwitchState.Status {
            KillSwitchState.evaluate(preferences, pro: pro, filterActive: filter, exit: exit, armed: armed, now: now).status
        }
        #expect(status(preferences(false), exit: off) == .off)
        #expect(status(preferences(), pro: false, exit: off) == .needsPro)
        #expect(status(preferences(), filter: false, exit: off) == .needsFilter)
        #expect(status(preferences(), exit: off, armed: false) == .waiting)
        #expect(status(preferences(), exit: up) == .protected)
        #expect(status(preferences(), exit: off) == .blocking)
        // A split VPN leaves the default route outside the tunnel: down, for the kill switch.
        #expect(status(preferences(), exit: split) == .blocking)
        #expect(status(preferences(), exit: ExitPath(interface: nil)) == .blocking)
        #expect(status(preferences(until: now.addingTimeInterval(120)), exit: off) == .allowed)
        #expect(status(preferences(until: now.addingTimeInterval(-1)), exit: off) == .blocking)
    }

    @Test func policyCarriesOnlyWhatTheFilterCanEnforce() {
        let blocking = KillSwitchState.evaluate(preferences(lan: false), pro: true, filterActive: true, exit: off, armed: true, now: now)
        #expect(blocking.policy(vpnApps: ["com.example.vpn"]) == KillSwitchPolicy(armed: true, vpnDown: true, allowLAN: false, vpnApps: ["com.example.vpn"]))
        let protected = KillSwitchState.evaluate(preferences(), pro: true, filterActive: true, exit: up, armed: true, now: now)
        #expect(protected.policy() == KillSwitchPolicy(armed: true, vpnDown: false, tunnel: "utun4"))
        #expect(protected.vpnName == "Mullvad" && protected.title.contains("Mullvad"))
        let until = now.addingTimeInterval(300)
        let allowed = KillSwitchState.evaluate(preferences(until: until), pro: true, filterActive: true, exit: off, armed: true, now: now)
        #expect(allowed.policy().allowedUntil == until && allowed.policy().blocks(now: now) == false && allowed.policy().blocks(now: until.addingTimeInterval(1)))
        for state in [KillSwitchState.evaluate(preferences(), pro: false, filterActive: true, exit: off, armed: true, now: now),
                      KillSwitchState.evaluate(preferences(), pro: true, filterActive: true, exit: off, armed: false, now: now)] {
            #expect(state.policy() == KillSwitchPolicy())
        }
    }

    @Test func wordsAndJSON() throws {
        let blocking = KillSwitchState.evaluate(preferences(), pro: true, filterActive: true, exit: off, armed: true, now: now)
        #expect(blocking.title == "Blocked: VPN is down" && blocking.detail.hasPrefix("Reconnect your VPN") && blocking.detail.contains("and the local network can connect"))
        let value = KillSwitchState.json(blocking, preferences: preferences())
        #expect(value["state"] as? String == "blocking" && value["armed"] as? Bool == true && value["vpnUp"] as? Bool == false && value["allowedUntil"] is NSNull)
        _ = try JSONSerialization.data(withJSONObject: value)
        #expect(KillSwitchState.line(value).hasPrefix("BLOCKING") && KillSwitchState.line(value).hasSuffix("local network allowed"))
        // Without the app only the saved settings are known.
        let saved = KillSwitchState.json(nil, preferences: preferences(lan: false))
        #expect(saved["enabled"] as? Bool == true && saved["allowLAN"] as? Bool == false && saved["state"] is NSNull)
        #expect(KillSwitchState.line(saved).contains("open the Kilobat app"))
        #expect(KillSwitchState.line(KillSwitchState.json(nil, preferences: nil)).hasPrefix("off"))
        let paused = KillSwitchState.evaluate(preferences(until: now.addingTimeInterval(300)), pro: true, filterActive: true, exit: off, armed: true, now: now)
        #expect(KillSwitchState.line(KillSwitchState.json(paused, preferences: nil)).hasPrefix("paused until"))
        #expect(KillSwitchState.limits.contains("new connections") && KillSwitchState.limits.contains("open Kilobat"))
    }

    @Test @MainActor func settingsRoundTripThroughPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStore(directory: directory, startMonitoring: false)
        #expect(!KillSwitchState.enabled(store.preferences) && KillSwitchState.allowLAN(store.preferences))
        store.preferences.killSwitch = true; store.preferences.killSwitchLAN = false
        store.preferences.killSwitchAllowedUntil = now
        let reloaded = TrafficStore(directory: directory, startMonitoring: false).preferences
        #expect(KillSwitchState.enabled(reloaded) && !KillSwitchState.allowLAN(reloaded) && reloaded.killSwitchAllowedUntil == now)
    }
}


@Test func ipv4KillSwitchRequiresBothHalvesOnItsTunnel() {
    let defaultPhysical: (UInt32, UInt32, UInt32) = (0, 0, 4)
    let lower: (UInt32, UInt32, UInt32) = (0, 0x8000_0000, 7)
    let upper: (UInt32, UInt32, UInt32) = (0x8000_0000, 0x8000_0000, 7)
    #expect(!KillSwitchPolicy.ipv4Covered(routes: [defaultPhysical], tunnel: 7))
    #expect(!KillSwitchPolicy.ipv4Covered(routes: [defaultPhysical, lower], tunnel: 7))
    #expect(KillSwitchPolicy.ipv4Covered(routes: [defaultPhysical, lower, upper], tunnel: 7))
    #expect(KillSwitchPolicy.ipv4Covered(routes: [(0, 0, 7)], tunnel: 7))
}

/// IPv4 route tables as `ipv4Routes()` returns them. Interface 4 is en0; 7 and 9 are tunnels.
private enum RouteTables {
    typealias Route = (destination: UInt32, mask: UInt32, interface: UInt32)
    static let half: UInt32 = 0x8000_0000
    static let lan: Route = (0xC0A8_0100, 0xFFFF_FF00, 4)            // 192.168.1.0/24 on Wi-Fi
    static let server: Route = (0xCB00_7105, 0xFFFF_FFFF, 4)         // the VPN server itself, outside the tunnel
    /// No VPN.
    static let plain: [Route] = [(0, 0, 4), lan]
    /// A VPN that replaces the default route.
    static let fullTunnel: [Route] = [(0, 0, 7), lan, server]
    /// OpenVPN `redirect-gateway def1` and wg-quick: the default stays, two halves go through the tunnel.
    static let twoHalves: [Route] = [(0, 0, 4), (0, half, 7), (half, half, 7), lan, server]
    /// A tunnel that lost one half.
    static let oneHalf: [Route] = [(0, 0, 4), (0, half, 7), lan]
    /// Each half on a different tunnel.
    static let twoTunnels: [Route] = [(0, 0, 4), (0, half, 7), (half, half, 9)]
    /// A TUN-mode proxy's eight routes (1/8, 2/7, 4/6, 8/5, 16/4, 32/3, 64/2, 128/1): not recognised, on purpose.
    static let eightRoutes: [Route] = [(0, 0, 4), (0x0100_0000, 0xFF00_0000, 7), (0x0200_0000, 0xFE00_0000, 7), (0x0400_0000, 0xFC00_0000, 7), (0x0800_0000, 0xF800_0000, 7),
                                       (0x1000_0000, 0xF000_0000, 7), (0x2000_0000, 0xE000_0000, 7), (0x4000_0000, 0xC000_0000, 7), (half, half, 7)]
    static let all: [[Route]] = [plain, fullTunnel, twoHalves, oneHalf, twoTunnels, eightRoutes, []]
}

struct IPv4CarrierTests {
    @Test func theFiltersRuleReadsTheFixturesAsDocumented() {
        #expect(KillSwitchPolicy.ipv4Covered(routes: RouteTables.twoHalves, tunnel: 7))
        #expect(KillSwitchPolicy.ipv4Covered(routes: RouteTables.fullTunnel, tunnel: 7))
        for table in [RouteTables.plain, RouteTables.oneHalf, RouteTables.twoTunnels, RouteTables.eightRoutes] {
            #expect(!KillSwitchPolicy.ipv4Covered(routes: table, tunnel: 7))
        }
    }

    @Test func theCarrierIsTheOneInterfaceCarryingAllOfIPv4() {
        #expect(KillSwitchPolicy.ipv4Carrier(routes: RouteTables.plain) == 4)
        #expect(KillSwitchPolicy.ipv4Carrier(routes: RouteTables.fullTunnel) == 7)
        #expect(KillSwitchPolicy.ipv4Carrier(routes: RouteTables.twoHalves) == 7)
        for table in [RouteTables.oneHalf, RouteTables.twoTunnels, RouteTables.eightRoutes, []] {
            #expect(KillSwitchPolicy.ipv4Carrier(routes: table) == nil)
        }
    }

    /// The app may never name a carrier the filter's rule would call uncovered, nor miss one it accepts.
    @Test func theCarrierAgreesWithTheFiltersRule() {
        for table in RouteTables.all {
            for index: UInt32 in [4, 7, 9] {
                #expect((KillSwitchPolicy.ipv4Carrier(routes: table) == index) == KillSwitchPolicy.ipv4Covered(routes: table, tunnel: index))
            }
        }
    }

    @Test func thisMacsRouteTableReads() {
        #expect(KillSwitchPolicy.ipv4Routes() != nil)
    }
}
