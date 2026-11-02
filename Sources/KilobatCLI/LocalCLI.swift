import Foundation
import KilobatCore

/// `kilobat local check`: can devices on this network see each other (casting, AirPlay, AirPrint), is the Mac on a
/// device's own Wi-Fi, and what may make a cast stutter.
@MainActor enum LocalCLI {
    static func run(_ args: [String]) async throws {
        let command: LocalCommand
        do { command = try LocalCommand.parse(args) } catch let error as DiagnosticError { throw CLIError(error.message) }
        switch command {
        case .check(let json, let quick):
            if !json { FileHandle.standardError.write(Data("Looking for TVs, speakers and printers on this network…\n".utf8)) }
            let summary = await summary(quick: quick)
            if json { print(String(decoding: try DiagnosticsCLI.encode(summary), as: UTF8.self)); return }
            print(text(summary))
        }
    }

    /// What `local check --json` and the MCP tool return. Missing values are written as null.
    struct Summary: Encodable {
        struct Device: Encodable { let name: String; let kind: String; let model: String? }
        struct Peers: Encodable { let neighbours: Int; let answered: Int; let pinged: Int; let routerAliases: Int; let swept: Bool; let subnetHosts: Int?; let bonjourDevices: Int }
        struct Setup: Encodable { let kind: String; let maker: String?; let headline: String; let detail: String; let previous: String? }
        struct Step: Encodable { let text: String; let action: String? }
        struct Casting: Encodable {
            let kind: String; let target: String?; let sender: String; let risks: [String]; let headline: String; let detail: String; let advice: [Step]; let basis: String
        }
        let source: String
        let date: Date
        let network: String?
        let verdict: String
        let headline: String
        let detail: String
        let advice: String?
        let evidence: String?
        let access: String
        let devices: [Device]
        let peers: Peers
        let setupNetwork: Setup?
        let casting: Casting?
        let basis: String

        private enum CodingKeys: String, CodingKey { case source, date, network, verdict, headline, detail, advice, evidence, access, devices, peers, setupNetwork, casting, basis }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(source, forKey: .source); try c.encode(date, forKey: .date); try c.encode(network, forKey: .network)
            try c.encode(verdict, forKey: .verdict); try c.encode(headline, forKey: .headline); try c.encode(detail, forKey: .detail)
            try c.encode(advice, forKey: .advice); try c.encode(evidence, forKey: .evidence); try c.encode(access, forKey: .access)
            try c.encode(devices, forKey: .devices); try c.encode(peers, forKey: .peers); try c.encode(setupNetwork, forKey: .setupNetwork)
            try c.encode(casting, forKey: .casting); try c.encode(basis, forKey: .basis)
        }
    }

    static let basis = "Bonjour records for Chromecast (_googlecast), AirPlay (_airplay, _raop) and printers (_ipp, _ipps, _printer), then, when none answer, whether other devices answer at all. Proxy ARP is reported as a possible sign of client isolation, not proof of blockage. Silence, subnet size and a sign-in page alone never establish isolation. Browser local traffic is only a possible cast, not confirmed Chromecast activity. Without an app answer, the CLI also runs standard internet-reachability and captive-portal checks for device-setup classification."

    /// The running app checks with its Local Network access and the Wi-Fi name; without it the CLI checks here.
    static func summary(quick: Bool) async -> Summary {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var casting: CastingCheck?
        // An app from before this check doesn't answer `casting`; then it won't answer the check either, so don't wait for it.
        let castingReply = await AppRelay.ask("casting", timeout: .seconds(3))
        if let data = castingReply, let relay = try? decoder.decode(CastingRelay.self, from: data) { casting = relay.check }
        if castingReply != nil, let data = await AppRelay.ask(quick ? "local-reach|quick" : "local-reach", timeout: .seconds(15)),
           let relay = try? decoder.decode(LocalReachRelay.self, from: data), let check = relay.check {
            return summary(check, setup: relay.setup, previous: relay.previous, casting: casting, source: "app")
        }
        let snapshot = await DiagnosticProbe().snapshot(checkPortal: true)
        let reachable = snapshot.internet.average != nil || snapshot.captivePortal != nil
        let setup = snapshot.wiredInterface == nil ? SetupNetworks.judge(ssid: snapshot.radio.ssid, gateway: snapshot.gateway, internetReachable: reachable) : nil
        let check = await LocalReachProbe.run(network: snapshot.networkName, gateway: snapshot.gateway, interface: snapshot.wiredInterface ?? snapshot.radio.interface,
                                              portal: snapshot.captivePortal == true, sweep: !quick)
        if casting == nil, let output = BluetoothAudioProbe.defaultOutput(), let activity = CastingActivity.detect(outputTransport: output.transport, outputName: output.name, local: [:]) {
            var conditions = CastingConditions()
            conditions.wifiBand = snapshot.radio.band; conditions.wifiName = snapshot.radio.ssid; conditions.rssi = snapshot.radio.rssi
            let awdl = await NearbyRadios.awdlStatus()
            conditions.airDropActive = awdl.up && awdl.active; conditions.airDropUsers = awdl.users
            casting = CastingCheck(activity: activity, conditions: conditions)
        }
        return summary(check, setup: setup, previous: nil, casting: casting, source: "cli")
    }

    static func summary(_ check: LocalReachCheck, setup: SetupNetworkMatch?, previous: String?, casting: CastingCheck?, source: String) -> Summary {
        let peers = check.peers
        return Summary(source: source, date: check.date, network: check.network, verdict: check.verdict.rawValue, headline: check.headline, detail: check.detail,
                       advice: check.advice, evidence: check.evidence?.rawValue, access: check.access.rawValue,
                       devices: check.targets.map { .init(name: $0.name, kind: $0.kind.rawValue, model: $0.model) },
                       peers: .init(neighbours: peers.neighbours, answered: peers.answered, pinged: peers.pinged, routerAliases: peers.routerAliases,
                                    swept: peers.swept, subnetHosts: peers.subnetHosts, bonjourDevices: peers.bonjourDevices),
                       setupNetwork: setup.map { .init(kind: $0.kind.rawValue, maker: $0.maker, headline: $0.headline, detail: $0.detail(previous: previous), previous: previous) },
                       casting: casting.map { cast in
                           .init(kind: cast.activity.kind.rawValue, target: cast.activity.target, sender: cast.activity.sender, risks: cast.risks.map(\.rawValue),
                                 headline: cast.headline, detail: cast.detail, advice: cast.advice.map { .init(text: $0.text, action: $0.action?.rawValue) }, basis: CastingCheck.basis)
                       },
                       basis: basis)
    }

    static func text(_ summary: Summary) -> String {
        var lines: [String] = []
        if let setup = summary.setupNetwork { lines += [Terminal.violet(setup.headline), setup.detail, ""] }
        switch summary.verdict {
        case "works": lines.append(Terminal.violet(summary.headline))
        case "isolated": lines.append(Terminal.rose(summary.headline))
        default: lines.append(summary.headline)
        }
        lines.append(summary.detail)
        if let advice = summary.advice { lines.append(advice) }
        if !summary.devices.isEmpty {
            lines.append("")
            for device in summary.devices { lines.append("  \(device.kind == "printer" ? "Printer" : device.kind == "cast" ? "Chromecast" : "AirPlay ")  \(device.name)\(device.model.map { Terminal.dim(" · " + $0) } ?? "")") }
        } else {
            let peers = summary.peers
            lines.append(Terminal.dim("Neighbours \(peers.neighbours) · answered ping \(peers.answered)/\(peers.pinged) · Bonjour devices \(peers.bonjourDevices)\(peers.routerAliases > 0 ? " · \(peers.routerAliases) answered as the router" : "")\(peers.swept ? "" : " · no sweep")"))
        }
        if let cast = summary.casting {
            lines += ["", cast.risks.isEmpty ? Terminal.dim(cast.headline) : Terminal.rose(cast.headline), cast.detail]
            for (index, step) in cast.advice.enumerated() { lines.append("  \(index + 1). \(step.text)") }
            lines.append(Terminal.dim(cast.basis))
        }
        return lines.joined(separator: "\n")
    }
}
