import Foundation
import KilobatCore

/// This Mac's own side of a connection: `wired` (Ethernet ports and adapters), `shares` (mounted network shares and
/// whether their servers answer) and `macos` (before and after the last macOS upgrade). All read-only.
@MainActor enum MacCLI {
    static func run(_ args: [String]) async throws {
        try KilobatCLI.allow(args, ["--json"])
        let json = args.contains("--json")
        switch args[0] {
        case "wired": try await wired(json: json)
        case "shares": try await shares(json: json)
        default: try macOS(json: json)
        }
    }

    // MARK: wired

    static func wired(json: Bool) async throws {
        let report = await WiredProbe.read()
        if json { print(String(decoding: try DiagnosticsCLI.encode(report), as: UTF8.self)); return }
        print(wiredText(report))
    }

    static func wiredText(_ report: WiredReport) -> String {
        var lines: [String] = []
        if report.adapters.isEmpty && report.missingDrivers.isEmpty { return "No Ethernet port or adapter on this Mac." }
        for adapter in report.adapters {
            lines.append("\(adapter.name) (\(adapter.interface))")
            lines.append("  Link        \(adapter.linkLine)" + (adapter.belowBest ? " · can do \(adapter.bestMbps.map(WiredLink.speed) ?? "")" : ""))
            if let best = adapter.bestMbps, !adapter.belowBest { lines.append("  Fastest     \(WiredLink.speed(best))") }
            if let label = adapter.identity.label { lines.append("  Adapter     \(label)") }
            if let chip = adapter.identity.chip { lines.append("  Chip        \(chip)") }
            if let ids = ids(adapter.identity) { lines.append("  USB id      \(ids)") }
            if let usb = adapter.identity.usbMbps { lines.append("  USB link    \(usbName(usb))") }
            if let driver = adapter.identity.driver { lines.append("  Driver      \(driver)" + (adapter.identity.appleDriver.map { $0 ? " (Apple)" : " (maker's)" } ?? "")) }
            if let attachment = adapter.identity.attachment { lines.append("  Attached    \(attachment == .usb ? "USB" : attachment == .thunderbolt ? "Thunderbolt" : "Built in")") }
            lines.append("  Service     " + (adapter.service.map { $0 + (adapter.serviceEnabled == false ? " (inactive)" : "") } ?? "none"))
            lines.append("")
        }
        for driver in report.missingDrivers {
            lines.append("\(driver.product ?? driver.chip) (no network interface)")
            lines.append("  Chip        \(driver.chip)")
            lines.append("  USB id      \(String(format: "%04x:%04x", driver.vendorID, driver.productID))")
            lines.append("")
        }
        if report.findings.isEmpty { lines.append("✓ No problem found with the wired link.") }
        for finding in report.findings {
            lines.append("\(finding.level == .problem ? "✗" : "!") \(finding.title)")
            lines.append("  \(finding.detail)")
        }
        return lines.joined(separator: "\n")
    }

    private static func ids(_ identity: WiredIdentity) -> String? {
        guard let vendor = identity.vendorID, let product = identity.productID else { return nil }
        return String(format: "%04x:%04x", vendor, product)
    }
    private static func usbName(_ mbps: Double) -> String {
        switch mbps {
        case ..<13: "USB 1 (\(WiredLink.speed(mbps)))"
        case ..<481: "USB 2 (480 Mbps)"
        default: "USB 3 or later (\(WiredLink.speed(mbps)))"
        }
    }

    // MARK: shares

    static func shares(json: Bool) async throws {
        let shares = ShareProbe.mounted()
        if !json, !shares.isEmpty { FileHandle.standardError.write(Data("Knocking on \(shares.count == 1 ? "the share's server" : "\(shares.count) shares' servers")…\n".utf8)) }
        let checks = await ShareProbe.checkAll(shares)
        if json {
            struct Row: Encodable {
                let volume: String; let mountPoint: String; let kind: String; let server: String; let share: String
                let state: String; let ms: Double?; let finding: String?; let advice: String?; let eject: String?
            }
            let rows = checks.map { check in
                Row(volume: check.share.volume, mountPoint: check.share.mountPoint, kind: check.share.kind.rawValue, server: check.share.server, share: check.share.share,
                    state: check.state.rawValue, ms: check.milliseconds.map { ($0 * 10).rounded() / 10 }, finding: check.finding?.title, advice: check.finding?.detail,
                    eject: check.finding == nil ? nil : check.ejectCommand)
            }
            print(String(decoding: try DiagnosticsCLI.encode(rows), as: UTF8.self))
            return
        }
        print(sharesText(checks))
    }

    static func sharesText(_ checks: [ShareCheck]) -> String {
        guard !checks.isEmpty else { return "No network share is mounted." }
        var lines = checks.map { "\($0.finding == nil ? ($0.state == .unknown ? "?" : "✓") : $0.finding!.problem ? "✗" : "!") \($0.share.volume)  \($0.share.kind.title) · \($0.share.server) · \($0.status)" }
        for check in checks {
            guard let finding = check.finding else { continue }
            lines += ["", finding.title, "  " + finding.detail, "  From Terminal, when Finder won't let go: \(check.ejectCommand)"]
        }
        if checks.contains(where: { $0.state == .unknown }) {
            lines += ["", "? means the check couldn't run, often because the terminal lacks Local Network access (System Settings › Privacy & Security › Local Network)."]
        }
        lines += ["", "Only the server's port was tried; nothing on the shares was opened."]
        return lines.joined(separator: "\n")
    }

    // MARK: macos

    static func macOS(json: Bool) throws {
        let journal = NetworkJournal()
        let timeline = journal.macOSTimeline
        let comparison = journal.macOSComparison(network: journal.samples.last?.networkKey)
        if json {
            struct Output: Encodable {
                let current: String
                let versions: [MacOSRelease]
                let comparison: MacOSUpgradeComparison?
                let summary: String?
            }
            print(String(decoding: try DiagnosticsCLI.encode(Output(current: MacOSVersion.current, versions: Array(timeline.suffix(10)), comparison: comparison?.withoutNetwork, summary: comparison?.summary)), as: UTF8.self))
            return
        }
        var lines = ["macOS \(MacOSVersion.current) now."]
        if !timeline.isEmpty {
            lines.append("Recent versions: " + timeline.suffix(5).map { "\($0.version) (\($0.date.formatted(date: .abbreviated, time: .omitted)))" }.joined(separator: " → "))
        }
        guard let comparison else {
            lines.append("No macOS upgrade in the last 30 days to compare.")
            return print(lines.joined(separator: "\n"))
        }
        lines += ["", comparison.title + " · " + comparison.upgraded.formatted(date: .abbreviated, time: .shortened), comparison.summary]
        if comparison.comparable {
            let width = max(18, comparison.changes.map { MacOSUpgradeComparison.label($0.metric).count }.max() ?? 0) + 2
            lines.append("")
            lines.append("".padding(toLength: width, withPad: " ", startingAt: 0) + "macOS \(comparison.from)".padding(toLength: 16, withPad: " ", startingAt: 0) + "macOS \(comparison.to)")
            for change in comparison.changes {
                lines.append(MacOSUpgradeComparison.label(change.metric).padding(toLength: width, withPad: " ", startingAt: 0)
                             + MacOSUpgradeComparison.value(change.metric, change.before).padding(toLength: 16, withPad: " ", startingAt: 0)
                             + MacOSUpgradeComparison.value(change.metric, change.after) + (change.worse ? "  worse" : change.better ? "  better" : ""))
            }
            let before = comparison.before, after = comparison.after
            lines += ["", "Based on \(before.hours) hours of checks and \(before.speedTests) speed tests before, \(after.hours) and \(after.speedTests) after, on one network.",
                      "It shows what changed, not why. Health checks are recorded while the Kilobat app runs."]
        }
        print(lines.joined(separator: "\n"))
    }
}
