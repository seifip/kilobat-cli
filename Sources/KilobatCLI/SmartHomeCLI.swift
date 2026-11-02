import Foundation
import KilobatCore

/// `kilobat smarthome`: Thread networks and border routers, Matter and HomeKit devices, and whether the network is
/// ready for Matter. Read-only: it listens to Bonjour for a few seconds and reads this Mac's network state; it never
/// sets up, pairs or controls a device.
@MainActor enum SmartHomeCLI {
    static func run(_ args: [String]) async throws {
        guard case .report(let json) = try SmartHomeCommand.parse(args) else { return }
        let report = await self.report()
        if json { print(String(decoding: try DiagnosticsCLI.encode(report), as: UTF8.self)); return }
        print(text(report))
    }

    /// The Wi-Fi name and scan come from the running app when macOS hides them from the CLI.
    static func report() async -> SmartHomeReport {
        let radio = await DiagnosticProbe().radio()
        var ssid = radio.ssid
        if radio.interface != nil, ssid == nil { ssid = await WiFiCLI.appSSID() }
        // A scan only matters when the Mac isn't on 2.4 GHz already.
        let scanning = radio.interface != nil && radio.band != "2.4 GHz"
        return await SmartHomeProbe.run(wifiInterface: radio.interface, ssid: ssid, band: radio.band) {
            scanning ? try? await WiFiCLI.nearbyNetworks() : nil
        }
    }

    static func text(_ report: SmartHomeReport) -> String {
        var lines = ["Smart home · \(report.headline)"]
        if !report.threadNetworks.isEmpty || !report.idleBorderRouters.isEmpty {
            lines.append("Thread")
            for network in report.threadNetworks {
                let count = network.borderRouters.count
                lines.append("  \(network.name ?? "Unnamed network") · \(count) border router\(count == 1 ? "" : "s") · \(network.makers.joined(separator: ", "))"
                             + (network.credentialSharing ? " · Thread 1.4 credential sharing" : ""))
                for router in network.borderRouters {
                    let details = [router.maker, router.threadVersion.map { "Thread \($0)" }, router.state.map { $0.role.rawValue }].compactMap { $0 }
                    lines.append("    \(KilobatCLI.pad(router.label, 34))\(details.joined(separator: " · "))")
                }
            }
            for router in report.idleBorderRouters { lines.append("  \(router.label) · \(router.maker) · not on a Thread network now") }
        }
        let matter = report.matter
        if matter.devices > 0 || !matter.commissionable.isEmpty {
            var line = "Matter   \(matter.devices) device\(matter.devices == 1 ? "" : "s")"
            var links: [String] = []
            if matter.overThread > 0 { links.append("\(matter.overThread) over Thread") }
            if matter.overWiFi > 0 { links.append("\(matter.overWiFi) over Wi-Fi or Ethernet") }
            if !links.isEmpty { line += " (\(links.joined(separator: ", ")))" }
            if matter.fabrics > 0 { line += " in \(matter.fabrics) app\(matter.fabrics == 1 ? "" : "s") or hub\(matter.fabrics == 1 ? "" : "s") (fabrics)" }
            lines.append(line)
            if !matter.readyToSetUp.isEmpty {
                lines.append("  Ready to set up: " + matter.readyToSetUp.map { device in
                    device.deviceType.map { device.name == nil ? $0 : "\(device.label) (\($0))" } ?? device.label
                }.joined(separator: ", "))
            }
        }
        let homeKit = report.homeKit
        if homeKit.accessories > 0 {
            var parts = ["\(homeKit.accessories) accessor\(homeKit.accessories == 1 ? "y" : "ies")"]
            if homeKit.bridges > 0 { parts.append("\(homeKit.bridges) bridge\(homeKit.bridges == 1 ? "" : "s")") }
            if homeKit.unpaired > 0 { parts.append("\(homeKit.unpaired) not added to a home") }
            if homeKit.overThread > 0 { parts.append("\(homeKit.overThread) over Thread") }
            lines.append("HomeKit  " + parts.joined(separator: ", "))
        }
        lines.append("Network readiness")
        for check in report.checks {
            let mark = switch check.state { case .ok: "✓"; case .warning: "!"; case .problem: "✕"; case .unknown: "?" }
            lines.append("  \(mark) \(KilobatCLI.pad(check.title, 18))\(check.summary)")
            if check.state != .ok, let fix = check.fix { lines.append("      \(fix)") }
            if check.state != .ok, let guide = check.guide { lines.append("      Router guide: \(guide)") }
        }
        for finding in report.findings {
            lines.append("\(finding.state == .unknown ? "?" : "!") \(finding.title)")
            lines.append("  \(finding.detail)")
            lines.append("  \(finding.fix)")
            if !finding.sources.isEmpty { lines.append("  Sources: " + finding.sources.joined(separator: " ")) }
        }
        lines.append("Read-only: Kilobat listens to Bonjour and never sets up or controls a device.")
        return lines.joined(separator: "\n")
    }
}
