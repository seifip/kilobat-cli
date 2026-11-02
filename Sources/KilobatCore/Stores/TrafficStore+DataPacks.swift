import Foundation

/// Data packs on the traffic store: which one counts here, each one's status from usage history, and the changes
/// the app, the CLI and MCP make. Packs live in preferences.json, so the CLI's changes reach the running app.
public extension TrafficStore {
    var dataPacks: [DataPack] { preferences.dataPacks ?? [] }

    /// The pack counting on the network the Mac is on now.
    var currentPack: DataPack? {
        guard networkKey != "unknown", let packs = preferences.dataPacks, !packs.isEmpty else { return nil }
        return DataPacks.owner(of: networkKey, name: networkName, at: Date(), in: packs)
    }

    /// A network's name as history knows it; the current network's from the live store.
    func networkName(of key: String) -> String? { key == networkKey ? networkName : networkSessions[key]?.name }

    /// Networks seen, by key, with their names: the current one first in a list, for choosing a pack's networks.
    var knownNetworks: [String: String] {
        var names = networkSessions.compactMapValues { $0.identified == false ? nil : $0.name }
        if networkKey != "unknown", networkIdentified { names[networkKey] = networkName }
        return names
    }

    func packStatus(_ pack: DataPack, now: Date = Date()) -> DataPackStatus {
        DataPacks.status(pack, packs: dataPacks, usage: usage, names: { self.networkName(of: $0) },
                         pending: networkKey == "unknown" ? nil : (networkKey, pendingBytes), now: now)
    }

    /// Every pack's status, running and upcoming first, then the newest finished ones.
    func packStatuses(now: Date = Date()) -> [DataPackStatus] {
        dataPacks.map { packStatus($0, now: now) }.sorted { a, b in
            let live: (DataPackStatus) -> Bool = { $0.state == .active || $0.state == .usedUp || $0.state == .upcoming }
            if live(a) != live(b) { return live(a) }
            return live(a) ? a.pack.start < b.pack.start : a.pack.finish > b.pack.finish
        }
    }

    /// Adds a pack, ending or shortening others on the same networks. Returns the ones it ended.
    @discardableResult func addPack(_ pack: DataPack, now: Date = Date()) -> [DataPack] {
        var packs = DataPacks.pruned(dataPacks, now: now)
        let ended = DataPacks.add(pack, to: &packs, known: knownNetworks)
        preferences.dataPacks = packs
        return ended
    }

    /// Replaces a pack after it was edited, keeping the others to one pack per network.
    func updatePack(_ pack: DataPack, now: Date = Date()) {
        var packs = dataPacks.filter { $0.id != pack.id }
        DataPacks.add(pack, to: &packs, known: knownNetworks)
        preferences.dataPacks = packs
    }

    /// The carrier's figure for what's left.
    func correctPack(_ id: UUID, leftBytes: UInt64, now: Date = Date()) throws {
        guard var pack = dataPacks.first(where: { $0.id == id }) else { throw DataPackError(String(localized: "That data pack is gone.", comment: "Data pack: it was removed meanwhile")) }
        let mac = DataPacks.macBytes(pack, packs: dataPacks, usage: usage, names: { self.networkName(of: $0) },
                                     pending: networkKey == "unknown" ? nil : (networkKey, pendingBytes), to: now)
        try DataPacks.correct(&pack, leftBytes: leftBytes, macBytes: mac, now: now)
        preferences.dataPacks = dataPacks.map { $0.id == id ? pack : $0 }
    }

    /// Ends a pack now; it stays in the history.
    func endPack(_ id: UUID, now: Date = Date()) {
        preferences.dataPacks = dataPacks.map { pack in
            guard pack.id == id else { return pack }
            var ended = pack
            // One that hasn't started is simply dropped.
            if now < pack.start { ended.ended = pack.start } else if now < pack.finish { ended.ended = now }
            return ended
        }.filter { $0.finish > $0.start }
    }

    /// Removes a pack from the history altogether.
    func removePack(_ id: UUID) {
        let packs = dataPacks.filter { $0.id != id }
        preferences.dataPacks = packs.isEmpty ? nil : packs
    }
}
