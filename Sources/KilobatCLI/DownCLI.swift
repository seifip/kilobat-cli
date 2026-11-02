import AppKit
import Foundation
import KilobatCore

/// `kilobat down [service…]`: is it them or me? What the public status pages of services say right now, and whether each
/// service's own host connects from here. When it doesn't, whether this network blocks it or the service refuses this region.
/// With no service, the services of the apps running on this Mac. Read-only.
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
        let all = flags.contains("--all")
        let services = try pick(Array(args.dropFirst().filter { !$0.hasPrefix("--") }), all: all)
        guard !services.isEmpty else {
            if json { print("[]") } else { print("None of the apps running now has a status page Kilobat knows. Name one, such as kilobat down slack, or see kilobat down --list.") }
            return
        }
        let statuses = await ServiceStatusChecker.shared.check(services)
        // Every service with --all would be dozens of connections; the status pages alone answer that.
        let reach = all ? [:] : await reachability(services, statuses: statuses)
        if json { print(String(decoding: try statusJSON(statuses, reach: reach), as: UTF8.self)); return }
        for status in statuses { print(line(status, reach: reach[status.id])) }
    }

    /// Named services, every one, or those of the apps running now.
    static func pick(_ names: [String], all: Bool) throws -> [StatusService] {
        do { return try ServiceCatalog.pick(names, all: all, running: names.isEmpty && !all ? runningApps() : []) }
        catch { throw CLIError(error.localizedDescription) }
    }

    static func runningApps() -> [String] { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) }

    typealias Reach = (reachable: Bool?, block: NetworkBlock?)

    /// One TLS connection to each service's own host, at most eight; for one that fails, the block check. A host that
    /// Kilobat's own rules stop is left out, since that block is Kilobat's, not the network's.
    static func reachability(_ services: [StatusService], statuses: [ServiceStatus]) async -> [String: Reach] {
        let policy = await AwakeCLI.policy()
        async let place = NetworkBlockCheck.place(networkKey: policy.networkKey)
        async let vpn = NetworkBlockCheck.vpn()
        let (where_, tunnel) = await (place, vpn), resolver = TrustedResolver.chosen(policy.preferences)
        let checked = services.prefix(8).filter { service in
            (service.endpoints.first ?? service.hosts.first).map { !ConnectionDoctor.kilobatBlocks($0, policy: policy) } ?? false
        }
        return await withTaskGroup(of: (String, Reach).self) { group in
            for service in checked {
                let status = statuses.first { $0.id == service.id }
                // Down for everyone already answers it.
                if status?.outage == true { continue }
                group.addTask { (service.id, await NetworkBlockCheck.reach(service, status: status, place: where_, vpn: tunnel, resolver: resolver)) }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
    }

    static func line(_ status: ServiceStatus, reach: Reach? = nil) -> String {
        if let block = reach?.block {
            var text = "\(Terminal.rose("⊘")) \(Terminal.bold(status.service))  \(block.title): \(block.summary)"
            for line in block.evidence { text += "\n    " + Terminal.dim(line) }
            return text + "\n    → " + block.next
        }
        let mark = status.outage ? Terminal.rose("✗") : status.problem ? Terminal.violet("!") : status.state == .unknown ? Terminal.dim("?") : Terminal.green("✓")
        var text = "\(mark) \(Terminal.bold(status.service))  \(status.sentence(notYou: false))"
        if let started = status.started, status.problem { text += Terminal.dim(" (since \(started.formatted(date: .abbreviated, time: .shortened)))") }
        if status.problem || status.state == .unknown { text += "\n    " + Terminal.dim(status.page.absoluteString) }
        if reach?.reachable == false { text += "\n    " + Terminal.dim("It doesn’t connect from here, and nothing Kilobat measured points at this network. Run kilobat why <host> for each layer.") }
        return text
    }

    /// Each status with `problem` and the sentence beside the stored fields; dates in ISO 8601. `reachable` says whether the
    /// service's own host connected from here (null when not checked) and `block` what blocks it, or null.
    static func statusJSON(_ statuses: [ServiceStatus], reach: [String: Reach] = [:]) throws -> Data {
        let rows: [[String: Any]] = try statuses.map { status in
            var row = try JSONSerialization.jsonObject(with: DiagnosticsCLI.encode(status)) as? [String: Any] ?? [:]
            row["problem"] = status.problem; row["outage"] = status.outage; row["summary"] = status.sentence(notYou: false)
            let reached = reach[status.id]
            row["reachable"] = reached?.reachable ?? NSNull()
            row["block"] = try reached?.block.map { try JSONSerialization.jsonObject(with: DiagnosticsCLI.encode($0)) } ?? NSNull()
            if let block = reached?.block { row["summary"] = block.summary }
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
        print(Terminal.dim("\nEndpoints checked \(ServiceCatalog.checked). Only these pages are contacted, plus one connection to each service you name to see whether it connects from here."))
    }
}
