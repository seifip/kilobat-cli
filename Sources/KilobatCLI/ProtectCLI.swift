import Foundation
import KilobatCore

/// `kilobat protect`: Protection's switches, lists, a host check and allowed sites. The app enforces it with its
/// network filter and applies Pro; the CLI writes the same settings and can update the lists itself.
@MainActor enum ProtectCLI {
    static func run(_ args: [String]) async throws {
        let command: ProtectCommand
        do { command = try ProtectCommand.parse(args) } catch let failure as ProtectionUpdater.Failure { throw CLIError(failure.message) }
        let store = TrafficStore(startMonitoring: false)
        switch command {
        case .status(let json):
            let status = await status(store)
            if json { print(String(decoding: try encode(status), as: UTF8.self)); return }
            print(text(status))
        case .set(let on, let parts, _):
            command.apply(to: &store.preferences)
            let app = await appState()
            for part in parts {
                let name = part == .threats ? "Threat blocking" : part == .trackers ? "Tracker blocking in apps" : "The agent guard"
                print("\(name) \(on ? "on" : "off").")
            }
            if on, parts.contains(where: { $0 != .trackers }), app.pro == false { print("Threats and the agent guard are part of Kilobat Pro; the app enforces them once Pro is active.") }
            if on, app.filterActive != true { print("Kilobat's network filter enforces it: open Kilobat and turn the filter on.") }
        case .update(let json):
            let app = await appState()
            let lists = ProtectionPreferences.lists(store.preferences, pro: app.pro ?? true)
            guard !lists.isEmpty else { throw CLIError("Protection is off, so there's nothing to download. Turn it on with kilobat protect on.") }
            let updater = ProtectionUpdater()
            let state = await updater.update(lists, force: true)
            let index = updater.build(lists, known: knownHosts())
            let status = ProtectionStatus.make(store.preferences, pro: app.pro, filterActive: app.filterActive, state: state, index: index)
            if json { print(String(decoding: try encode(status), as: UTF8.self)); return }
            for list in status.lists {
                print("\(list.name): \(list.entries.formatted()) entries" + (list.error.map { " · kept the last good copy (\($0))" } ?? ""))
            }
            print("The app hands the new lists to its filter within a few minutes.")
        case .check(let host, let json):
            let result = try await check(host, store: store)
            if json { print(String(decoding: try encode(result), as: UTF8.self)) }
            else {
                print(result.listed ? "\(result.host) is listed\(result.entry.map { $0 == result.host ? "" : " (as \($0))" } ?? "") by \(result.lists.map(\.list).joined(separator: ", ")): \(result.category ?? "threat")." : "\(result.host) is not on Kilobat's lists.")
                print(result.note)
            }
            if result.wouldBlock { exit(1) }
        case .allow(let site):
            command.apply(to: &store.preferences)
            print("Allowed \(HostName.normalize(site.hasPrefix("*.") ? String(site.dropFirst(2)) : site) ?? site) and its subdomains: no Protection list or rule applies to it.")
        case .unallow(let site):
            print(command.apply(to: &store.preferences) ? "\(site) is no longer allowed; Protection's lists apply to it again." : "\(site) wasn't an allowed site.")
        }
    }

    /// Pro and the filter, as the running app reports them; nil when it isn't running.
    static func appState() async -> (pro: Bool?, filterActive: Bool?) {
        guard let data = await AppRelay.ask("connection", timeout: .seconds(2)),
              let app = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        return (app["pro"] as? Bool, app["filteringActive"] as? Bool)
    }

    static func knownHosts() -> [String] {
        guard let log = AgentLogFile.load() else { return [] }
        return AgentNetworkLogStore.knownHosts(log.sessions, pastHosts: Set(log.pastHosts))
    }

    static func status(_ store: TrafficStore) async -> ProtectionStatus {
        let app = await appState(), updater = ProtectionUpdater()
        return ProtectionStatus.make(store.preferences, pro: app.pro, filterActive: app.filterActive, state: updater.loadState(), index: updater.loadIndex())
    }

    static func check(_ host: String, store: TrafficStore) async throws -> ProtectionCheckResult {
        let app = await appState()
        let settings = ProtectionPreferences.settings(store.preferences, pro: app.pro ?? true)
        guard let result = ProtectionCheckResult.check(host, index: ProtectionUpdater().loadIndex(), settings: settings) else { throw CLIError("'\(host)' isn't a host name or IP address.") }
        return result
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func text(_ status: ProtectionStatus) -> String {
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        var lines = ["Threats \(onOff(status.threats)) · trackers in apps \(onOff(status.trackers)) · agent guard \(onOff(status.agentGuard))"]
        if status.threats || status.agentGuard {
            lines.append("\(status.threatEntries.formatted()) known threats" + (status.updated.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? " · not downloaded yet"))
        }
        if status.trackers { lines.append("\(status.trackerEntries.formatted()) tracker hosts from \(ProtectionLists.tracker(status.trackerList).name)") }
        if status.agentGuard { lines.append("Agent guard: no paste sites, file shares, tunnels, raw IP addresses, or more than \(status.uploadLimitMB) MB to a host no agent used before") }
        for list in status.lists where list.error != nil { lines.append("\(list.name): kept the last good copy (\(list.error ?? ""))") }
        if !status.allowedSites.isEmpty { lines.append("Allowed sites: " + status.allowedSites.joined(separator: ", ")) }
        if status.pro == false { lines.append("Threats and the agent guard are part of Kilobat Pro.") }
        if status.filterActive == false { lines.append("The network filter is off, so nothing is blocked.") }
        else if status.filterActive == nil { lines.append("The Kilobat app isn't running; it enforces Protection with its network filter.") }
        return lines.joined(separator: "\n")
    }
}
