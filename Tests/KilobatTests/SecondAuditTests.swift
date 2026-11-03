import Foundation
import Testing
@testable import KilobatCore

@MainActor struct SecondAuditTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Kilobat-audit-2-\(UUID())")
    }

    @Test func dishOutagesStayWithTheirSourceAcrossReloadAndAreClipped() throws {
        let folder = temporaryDirectory(), now = Date()
        defer { try? FileManager.default.removeItem(at: folder) }
        var journal = StarlinkJournal()
        journal.network = "B"; journal.lastSeen = now
        journal.merge([.init(cause: .noPings, start: now - 900, seconds: 30)], now: now)
        #expect(journal.evidence(network: "B", hours: 1, now: now) == nil)
        journal.select(network: "A", dishID: "first", now: now)
        journal.merge([.init(cause: .noPings, start: now - 7200, seconds: 7300)], now: now)
        journal.select(network: "B", dishID: "second", now: now)
        journal.save(directory: folder)
        journal = StarlinkJournal.load(directory: folder)
        #expect(journal.evidence(network: "B", hours: 1, now: now)?.outages.isEmpty == true)
        let first = try #require(journal.evidence(network: "A", hours: 1, now: now))
        #expect(first.totalSeconds == 3600 && first.outages.first?.start == now - 3600)
        journal.select(network: "A", dishID: "replacement", now: now)
        #expect(journal.outages.isEmpty)
        journal.select(network: "A", dishID: "first", now: now)
        #expect(journal.outages.count == 1)
    }

    @Test func liveDishReplacementClearsBothCachesAndRefreshes() async throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StarlinkStore(directory: folder)
        func message(_ base64: String) throws -> ProtoMessage {
            try #require(ProtoMessage(Data(base64Encoded: base64)!))
        }
        var first = try #require(StarlinkStatus(response: try message(StarlinkFixtures.statusOnline)))
        first.id = "dish-A"
        let history = try #require(StarlinkHistory(response: try message(StarlinkFixtures.history)))
        let map = StarlinkSkyMap(rows: 21, columns: 21, snr: Array(repeating: 1, count: 441))
        await store.tick(fast: false, network: "A", currentNetwork: { "A" }, readStatus: { _ in first },
                         readHistory: { history }, readMap: { map })
        #expect(store.history != nil && store.map != nil)
        var second = first
        second.id = "dish-B"
        var refreshes = 0
        await store.tick(fast: false, network: "A", currentNetwork: { "A" }, readStatus: { _ in second },
                         readHistory: { refreshes += 1; return nil }, readMap: { refreshes += 1; return nil })
        #expect(store.status?.id == "dish-B" && store.history == nil && store.map == nil && refreshes == 2)
    }

    @Test func parallelDrainAndAppendDoNotLoseEvents() async throws {
        let folder = temporaryDirectory(), file = folder.appendingPathComponent("events.jsonl"), now = Date()
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = try await withThrowingTaskGroup(of: [AgentEvent].self) { group in
            for i in 0..<100 {
                group.addTask {
                    try AgentEventSpool.append(AgentEvent(kind: .working, agent: "codex", session: "\(i)", time: now), to: file)
                    return []
                }
                group.addTask { AgentEventSpool.drain(file, now: now) }
            }
            var read: [AgentEvent] = []
            for try await batch in group { read += batch }
            return read + AgentEventSpool.drain(file, now: now)
        }
        #expect(found.compactMap(\.session).sorted() == (0..<100).map { String($0) }.sorted())
    }

    @Test func aDoneHookWaitsForFreshChildActivityAndLaterUnhookedRunStarts() {
        let now = Date(), folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: "Kilobat-audit-2-\(UUID())")!
        defaults.register(defaults: ["awake.agents": false, "awake.notify": false])
        let store = SessionStore(directory: folder, defaults: defaults)
        store.observesWorkspace = false
        store.probe = ProcessProbe(children: { $0 == 99 ? [100] : [] }, cpuTime: { _ in 0 }, alive: { _ in true }, path: { _ in nil })
        store.receive(.init(kind: .start, agent: "codex", session: "hooked", pid: 99, time: now))
        store.receive(.init(kind: .done, agent: "codex", session: "hooked", pid: 99, time: now + 1))
        #expect(store.agents.count == 1)
        let child = AppTraffic(id: "process:curl", name: "curl", processIDs: [100], downloadRate: 200_000, uploadRate: 0)
        let root = AppTraffic(id: "process:codex", name: "codex", processIDs: [99], downloadRate: 0, uploadRate: 0)
        store.tick(apps: [root, child], interval: 2, now: now + 12)
        #expect(store.agents["Codex|hooked"]?.note != nil)
        store.tick(apps: [], interval: 2, now: now + 24)
        #expect(store.agents.isEmpty)
        let later = AppTraffic(id: "process:codex", name: "codex", processIDs: [101], downloadRate: 200_000, uploadRate: 0)
        store.tick(apps: [later], interval: 2, now: now + 26)
        #expect(store.agents.values.contains { $0.hooks != true })
    }

    @Test func genericWebhookIsJSONAndNtfyIsExplicit() throws {
        let json = try #require(SessionStore.webhookRequest("https://example.com/webhook", title: "Done", body: "Body"))
        #expect(json.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let payload = try JSONSerialization.jsonObject(with: #require(json.httpBody)) as? [String: String]
        #expect(payload == ["title": "Done", "body": "Body", "source": "Kilobat"])
        for address in ["https://ntfy.sh/topic", "ntfy+https://example.com/topic"] {
            let request = try #require(SessionStore.webhookRequest(address, title: "Done", body: "Body"))
            #expect(request.url?.scheme == "https" && request.value(forHTTPHeaderField: "Title") == "Done" && request.httpBody == Data("Body".utf8))
        }
    }

    @Test func aValidNeighborEnding255AndMonitoringRecovery() {
        let rows = [LANDevice(address: "192.168.0.255", mac: "02:11:22:33:44:55", interface: "en0", name: "?"),
                    LANDevice(address: "192.168.1.255", mac: "ff:ff:ff:ff:ff:ff", interface: "en0", name: "?")]
        #expect(LANScan.sightings(rows, interface: "en0", own: []).map(\.address) == ["192.168.0.255"])
        let folder = temporaryDirectory(), now = Date()
        defer { try? FileManager.default.removeItem(at: folder) }
        let traffic = TrafficStore(directory: folder, startMonitoring: false, recordHistory: false)
        traffic.monitoringFailed("Retrying")
        #expect(traffic.error == "Retrying")
        traffic.consume(.init(timestamp: now, processes: []))
        traffic.consume(.init(timestamp: now + 2, processes: []))
        #expect(traffic.ready && traffic.error == nil)
        traffic.error = "Could not save"
        traffic.monitoringFailed("Retrying")
        traffic.consume(.init(timestamp: now + 4, processes: []))
        #expect(traffic.error == "Could not save" && traffic.monitoringError == nil)
    }

    @Test func portalDoesNotLearnAcrossObservationGaps() {
        let now = Date(), folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let portal = PortalWatch(directory: folder, notifies: false)
        for (offset, state) in [(0.0, PortalCheck.State.portal), (10, .open), (3610, .open), (3910, .portal)] {
            portal.observe(.init(state: state, date: now + offset), network: "A", name: "A", now: now + offset)
        }
        #expect(portal.record?.sessions.first?.measured == false)
    }

    @Test func failedPlanCheckStillReservesTheNextRunAfterRestart() {
        let folder = temporaryDirectory(), now = Date()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = NetworkJournal(directory: folder)
        #expect(journal.reservePlanCheck(network: "A", maximumBytes: 80_000_000, now: now))
        let reloaded = NetworkJournal(directory: folder)
        #expect(reloaded.speedTests.isEmpty && reloaded.planAttempts.first?.reservedBytes == 80_000_000)
        let moment = PlanCheck.Moment(enabled: true, network: "A", planMbps: 100, connected: true, metered: false,
                                      vpn: false, call: false, busy: false, quietSeconds: 120, onAC: true, batteryPercent: 100, lowPowerMode: false)
        #expect(PlanCheck.wait(moment, history: [], attempts: reloaded.planAttempts, now: now + 120) == .recent)
    }
}
