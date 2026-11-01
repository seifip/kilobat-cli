import AppKit
import Foundation
import KilobatCore

/// `kilobat down [service…]`: is it them or me? What the public status pages of services say right now.
/// With no service, the services of the apps running on this Mac. Read-only; only the status pages are contacted.
enum DownCLI {
    static let usage = "Use down [service|host…] [--all] [--list] [--json]."

    static func run(_ args: [String]) async throws {
        let flags = Set(args.dropFirst().filter { $0.hasPrefix("--") })
        guard flags.isSubset(of: ["--all", "--list", "--json"]) else { throw CLIError(usage) }
        let json = flags.contains("--json")
        if flags.contains("--list") {
            guard args.count == (json ? 3 : 2) else { throw CLIError(usage) }
            if json { print(String(decoding: try listJSON(), as: UTF8.self)) } else { printList() }
            return
        }
        let services = try pick(Array(args.dropFirst().filter { !$0.hasPrefix("--") }), all: flags.contains("--all"))
        guard !services.isEmpty else {
            if json { print("[]") } else { print("None of the apps running now has a status page Kilobat knows. Name one, such as kilobat down slack, or see kilobat down --list.") }
            return
        }
        let statuses = await ServiceStatusChecker.shared.check(services)
        if json { print(String(decoding: try statusJSON(statuses), as: UTF8.self)); return }
        for status in statuses { print(line(status)) }
    }

    /// Named services, every one, or those of the apps running now.
    static func pick(_ names: [String], all: Bool) throws -> [StatusService] {
        do { return try ServiceCatalog.pick(names, all: all, running: names.isEmpty && !all ? runningApps() : []) }
        catch { throw CLIError(error.localizedDescription) }
    }

    static func runningApps() -> [String] { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) }

    static func line(_ status: ServiceStatus) -> String {
        let mark = status.outage ? Terminal.rose("✗") : status.problem ? Terminal.violet("!") : status.state == .unknown ? Terminal.dim("?") : Terminal.green("✓")
        var text = "\(mark) \(Terminal.bold(status.service))  \(status.sentence(notYou: false))"
        if let started = status.started, status.problem { text += Terminal.dim(" (since \(started.formatted(date: .abbreviated, time: .shortened)))") }
        if status.problem || status.state == .unknown { text += "\n    " + Terminal.dim(status.page.absoluteString) }
        return text
    }

    /// Each status with `problem` and the sentence beside the stored fields; dates in ISO 8601.
    static func statusJSON(_ statuses: [ServiceStatus]) throws -> Data {
        let rows: [[String: Any]] = try statuses.map { status in
            var row = try JSONSerialization.jsonObject(with: DiagnosticsCLI.encode(status)) as? [String: Any] ?? [:]
            row["problem"] = status.problem; row["outage"] = status.outage; row["summary"] = status.sentence(notYou: false)
            return row
        }
        return try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func listJSON() throws -> Data {
        let rows: [[String: Any]] = ServiceCatalog.services.map { service in
            ["id": service.id, "name": service.name, "page": service.page.absoluteString, "endpoint": service.feed.url.absoluteString, "format": service.feed.format,
             "apps": service.apps, "hosts": service.hosts, "checked": ServiceCatalog.checked]
        }
        return try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func printList() {
        let width = ServiceCatalog.services.map(\.id.count).max() ?? 10
        for service in ServiceCatalog.services {
            print(service.id.padding(toLength: width + 2, withPad: " ", startingAt: 0) + service.name + Terminal.dim("  " + service.page.absoluteString))
        }
        print(Terminal.dim("\nEndpoints checked \(ServiceCatalog.checked). Only these pages are contacted, and only when you ask or an app’s connections fail."))
    }
}
