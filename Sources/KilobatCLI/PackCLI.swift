import Foundation
import KilobatCore

/// `pack`: prepaid data packs such as a travel eSIM, with when each runs out at the recent pace. Packs are saved with
/// the preferences, so the running app picks them up; the network the Mac is on comes from the app when it runs.
@MainActor enum PackCLI {
    static func run(_ args: [String]) async throws {
        let parsed: (command: PackCommand, json: Bool)
        do { parsed = try PackCommand.parse(Array(args.dropFirst())) } catch let error as DataPackError { throw CLIError(error.message) }
        let store = TrafficStore(startMonitoring: false)
        let app = await WiFiCLI.connection()
        let result = try perform(parsed.command, store: store, app: app)
        if parsed.json { try WiFiCLI.printObject(result); return }
        print(lines(parsed.command, result: result, store: store).joined(separator: "\n"))
    }

    /// Shared by the CLI and MCP: carries out the command and returns its JSON.
    @discardableResult static func perform(_ command: PackCommand, store: TrafficStore, app: [String: Any]?, now: Date = Date()) throws -> [String: Any] {
        let network = QuotaCLI.currentNetwork(store, app: app)
        let name = network.flatMap { key in (app?["networkKey"] as? String) == key ? app?["network"] as? String : store.networkSessions[key]?.name }
        func target(_ text: String?) throws -> DataPack {
            if let text {
                guard let pack = DataPacks.find(text, in: store.dataPacks) else { throw CLIError("No data pack called \(text). Run kilobat pack to list them.") }
                return pack
            }
            guard let pack = DataPacks.current(store.dataPacks, network: network, name: name, now: now) else {
                throw CLIError(store.dataPacks.contains { $0.active(at: now) } ? "Several data packs are running. Pass --pack <name>." : "No data pack is running. Add one with kilobat pack add <GB> <days>.")
            }
            return pack
        }
        switch command {
        case .status:
            return report(store, network: network, name: name, now: now)
        case .add(let gb, let validity, let names, let label, let start):
            let networks = try choose(names, store: store, network: network, name: name)
            let begin = start ?? now
            let pack: DataPack
            do {
                switch validity {
                case .days(let days): pack = try DataPack.make(name: label, gb: gb, days: days, start: begin, networks: networks)
                case .until(let date):
                    // A date names the day the pack runs through, so it ends as that day does.
                    let end = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
                    pack = try DataPack.make(name: label, gb: gb, until: end, start: begin, networks: networks)
                }
            } catch let error as DataPackError { throw CLIError(error.message) }
            let ended = store.addPack(pack, now: now)
            var value = report(store, network: network, name: name, now: now)
            value["added"] = object(store.packStatus(store.dataPacks.first { $0.id == pack.id } ?? pack, now: now))
            value["ended"] = ended.map(\.name)
            return value
        case .correct(let leftGB, let text):
            let pack = try target(text)
            do { try store.correctPack(pack.id, leftBytes: UInt64((leftGB * 1_000_000_000).rounded()), now: now) }
            catch let error as DataPackError { throw CLIError(error.message) }
            var value = report(store, network: network, name: name, now: now)
            value["corrected"] = object(store.packStatus(store.dataPacks.first { $0.id == pack.id } ?? pack, now: now))
            return value
        case .end(let text):
            let pack = try target(text)
            store.endPack(pack.id, now: now)
            var value = report(store, network: network, name: name, now: now)
            value["endedPack"] = pack.name
            return value
        }
    }

    /// `--network` values as networks: a name or key Kilobat has seen picks that network; anything else counts every
    /// network whose name contains it. Without one, the network the Mac is on now.
    static func choose(_ names: [String], store: TrafficStore, network: String?, name: String?) throws -> DataPackNetworks {
        var known = store.knownNetworks
        if let network, let name { known[network] = name }
        guard !names.isEmpty else {
            guard let network, network != "unknown" else { throw CLIError("Kilobat doesn’t know which network this is. Open the Kilobat app, or pass --network <name>.") }
            return DataPackNetworks(keys: [network: name ?? known[network] ?? network])
        }
        var keys: [String: String] = [:], contains: [String] = []
        for text in names {
            let matches = known.filter { $0.key == text || $0.value.caseInsensitiveCompare(text) == .orderedSame }
            if matches.isEmpty { contains.append(text) } else { keys.merge(matches) { first, _ in first } }
        }
        guard contains.count <= 1 else { throw CLIError("Kilobat hasn’t seen \(contains.joined(separator: " or ")). Pass one text that their names contain, or join each network once first.") }
        return DataPackNetworks(keys: keys, nameContains: contains.first)
    }

    static func report(_ store: TrafficStore, network: String?, name: String?, now: Date) -> [String: Any] {
        let current = network.flatMap { DataPacks.owner(of: $0, name: name, at: now, in: store.dataPacks) }
        return ["packs": store.packStatuses(now: now).map(object), "current": current?.id.uuidString ?? NSNull(),
                "network": network ?? NSNull(), "networkName": name ?? NSNull(), "limits": DataPackStatus.limits]
    }

    static func object(_ status: DataPackStatus) -> [String: Any] {
        let iso = ISO8601DateFormatter(), pack = status.pack
        return ["id": pack.id.uuidString, "name": pack.name, "sizeBytes": pack.bytes, "usedBytes": status.used, "leftBytes": status.left,
                "macBytes": status.macBytes, "usedFraction": (status.fraction * 1000).rounded() / 1000, "state": status.state.rawValue,
                "start": iso.string(from: pack.start), "end": iso.string(from: pack.end), "endedAt": pack.ended.map { iso.string(from: $0) } ?? NSNull(),
                "days": pack.days(), "networks": ["keys": pack.networks.keys, "nameContains": pack.networks.nameContains ?? NSNull()] as [String: Any],
                "perDayBytes": status.perDay.map { UInt64($0.rounded()) } ?? NSNull(), "paceDays": (status.paceDays * 10).rounded() / 10,
                "settling": status.settling, "runsOut": status.runsOut.map { iso.string(from: $0) } ?? NSNull(), "daysEarly": status.daysEarly ?? NSNull(),
                "lastsWholePack": status.lastsWholePack,
                "correction": pack.correction.map { ["at": iso.string(from: $0.at), "leftBytes": $0.leftBytes] as [String: Any] } ?? NSNull(),
                "alerts": pack.thresholds, "holdUploads": pack.holdUploads == true, "summary": status.line()]
    }

    static func lines(_ command: PackCommand, result: [String: Any], store: TrafficStore) -> [String] {
        var lines: [String] = []
        switch command {
        case .add:
            let added = result["added"] as? [String: Any]
            lines.append("✓ Added \(added?["name"] as? String ?? "the pack"): \(TrafficFormat.bytes(added?["sizeBytes"] as? UInt64 ?? 0)) for \(added?["days"] as? Int ?? 0) days.")
            for name in result["ended"] as? [String] ?? [] { lines.append("  Ended \(name), which counted the same networks.") }
            lines.append("  The networks it counts are metered now. Set alerts and holding uploads in Kilobat Settings › Data packs (Pro).")
        case .correct: lines.append("✓ Corrected \((result["corrected"] as? [String: Any])?["name"] as? String ?? "the pack") to the carrier’s figure.")
        case .end: lines.append("✓ Ended \(result["endedPack"] as? String ?? "the pack"). It stays in the history.")
        case .status: break
        }
        let packs = store.packStatuses()
        if packs.isEmpty {
            lines.append("No data packs. Add one with kilobat pack add <GB> <days> [--network <name>], such as pack add 10 30.")
            return lines
        }
        if !lines.isEmpty { lines.append("") }
        lines.append("Kilobat · data packs")
        let current = result["current"] as? String
        for status in packs {
            let live = status.state == .active || status.state == .usedUp || status.state == .upcoming
            let marker = status.pack.id.uuidString == current ? Terminal.violet("●") : live ? "○" : Terminal.dim("·")
            let line = "\(marker) \(KilobatCLI.pad(status.pack.name, 20))\(status.line())"
            lines.append(status.early ? Terminal.rose(line) : live ? line : Terminal.dim(line))
            guard live else { continue }
            var detail = "\(TrafficFormat.bytes(status.used)) of \(TrafficFormat.bytes(status.pack.bytes)) used · \(status.pack.networks.summary)"
            if let perDay = status.perDay, perDay > 0 { detail += " · about \(TrafficFormat.bytes(UInt64(perDay))) a day" + (status.settling ? " so far" : "") }
            if let correction = status.pack.correction { detail += " · corrected \(correction.at.formatted(date: .abbreviated, time: .shortened))" }
            lines.append(Terminal.dim("  " + KilobatCLI.pad("", 20) + detail))
        }
        lines += ["", Terminal.dim("  " + DataPackStatus.limits + " Run kilobat pack correct <GB-left>.")]
        return lines
    }
}
