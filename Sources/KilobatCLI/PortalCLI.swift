import AppKit
import KilobatCore

/// `kilobat portal`: is a Wi-Fi sign-in page in the way, and how long sign-ins last on each network.
/// It checks now (two small HTTP requests) and reads what the app learned; `open` opens the sign-in page.
enum PortalCLI {
    static func run(_ args: [String]) async throws {
        let command: PortalReport.Command
        do { command = try PortalReport.parse(Array(args.dropFirst())) } catch { throw CLIError(error.localizedDescription) }
        let (check, network, networks) = await read()
        switch command {
        case .open:
            let url = check.state == .portal ? check.url ?? CaptivePortal.Endpoint.apple.url
                : network?.url.flatMap(URL.init(string:)) ?? CaptivePortal.Endpoint.apple.url
            NSWorkspace.shared.open(url)
            print("Opened \(check.state == .portal && check.url == nil ? "Apple's check page, which the sign-in page takes over" : "the sign-in page") in your browser.")
        case .status(let json):
            if json { print(String(decoding: try JSONSerialization.data(withJSONObject: PortalReport.json(check: check, network: network, networks: networks), options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)) }
            else { print(PortalReport.text(check: check, network: network, networks: networks)) }
        }
    }

    /// For the CLI and MCP: a check now, the network it's about and the stored history.
    static func read() async -> (PortalCheck, PortalNetwork?, [PortalNetwork]) {
        async let answer = AppRelay.ask("connection", timeout: .seconds(2))
        let check = await CaptivePortal.check()
        let networks = PortalWatch.load()
        let key = (await answer).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["networkKey"] as? String
        return (check, PortalReport.network(networks, appKey: key == "unknown" ? nil : key, check: check), networks)
    }

    static func json() async throws -> Data {
        let (check, network, networks) = await read()
        return try JSONSerialization.data(withJSONObject: PortalReport.json(check: check, network: network, networks: networks), options: [.sortedKeys])
    }
}
