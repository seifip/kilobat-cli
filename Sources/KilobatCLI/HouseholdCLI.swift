import Foundation
import KilobatCore

/// `kilobat household`: the Macs this one is paired with and what each is doing now, asked through the running app,
/// which holds the pair keys. Read-only; pairing, sharing and unpairing stay in the app, where both Macs show the code.
enum HouseholdCLI {
    static func run(_ args: [String]) async throws {
        guard case .list(let json) = try HouseholdCommand.parse(args) else { return }
        let report = await self.report()
        if json { print(String(decoding: try DiagnosticsCLI.encode(report), as: UTF8.self)); return }
        print(text(report))
    }

    /// The app's answer, which asks each paired Mac once; without the app, the paired Macs from household.json.
    static func report() async -> HouseholdReport {
        if let data = await AppRelay.ask("household", timeout: .seconds(8)) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if var report = try? decoder.decode(HouseholdReport.self, from: data) { report.appRunning = true; return report }
        }
        let book = HouseholdStore.load() ?? HouseholdBook(me: "")
        return HouseholdReport(name: book.name ?? HouseholdStore.computerName, sharing: book.sharing, appRunning: false,
                               peers: book.peers.map { .init(id: $0.id, name: $0.name, network: $0.networkName, pairedAt: $0.paired, onThisNetwork: false) })
    }

    static func text(_ report: HouseholdReport) -> String {
        var lines = ["Household Macs · this Mac is “\(report.name)” · sharing \(report.sharing ? (report.answering == false ? "on, but not on a home network now" : "on") : "off")"]
        if report.localNetwork == LocalNetworkAccess.denied.rawValue { lines.append("✕ Local Network access is off for Kilobat: System Settings › Privacy & Security › Local Network.") }
        if report.peers.isEmpty { lines.append("No paired Macs yet.") }
        for peer in report.peers {
            let status: String
            if !peer.onThisNetwork { status = report.appRunning ? "paired on \(peer.network)" : "paired on \(peer.network) · open the app to see what it’s doing" }
            else if report.pro == false { status = "live usage needs Kilobat Pro in the app" }
            else if let live = peer.live {
                var parts = ["↓ \(TrafficFormat.rate(live.down))  ↑ \(TrafficFormat.rate(live.up))"]
                if !live.apps.isEmpty { parts.append(live.apps.joined(separator: ", ")) }
                if live.call { parts.append("on a call") }
                if peer.busy == true { parts.append("busy") }
                status = parts.joined(separator: " · ")
            } else if let refused = peer.refused { status = refused == "notPaired" ? "doesn’t know this Mac any more; pair again in the app" : "sharing is off on that Mac" }
            else if peer.reachable == false { status = "not reachable" }
            else { status = "no answer yet" }
            lines.append("  \(KilobatCLI.pad(peer.name, 28))\(status)")
        }
        lines.append("Pairing, sharing and names are in the app: Kilobat › Settings › Household Macs.")
        return lines.joined(separator: "\n")
    }
}
