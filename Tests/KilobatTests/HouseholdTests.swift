import Foundation
import CryptoKit
import Network
import Testing
@testable import KilobatCore

/// Household Macs: the wire format, request authentication, pairing, which cause a call report names, staleness, the
/// CLI's arguments, and two peers talking over loopback. Every name, address and number here is made up.
struct HouseholdTests {
    private let anna = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
    private let philip = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var summary: HouseholdSummary {
        HouseholdSummary(id: anna, name: "Anna’s MacBook", down: 4_000_000, up: 30_000, apps: ["Steam", "Safari"], call: false, at: now)
    }

    @Test func framesRoundTripAndRejectOversizeOrGarbage() throws {
        let message = HouseholdMessage(kind: .request, id: philip, nonce: Data(repeating: 7, count: 16), to: anna, at: 1_800_000_000_000, mac: Data(repeating: 1, count: 32))
        var buffer = try HouseholdWire.frame(message) + HouseholdWire.frame(HouseholdMessage(kind: .cancel, reason: "x"))
        // A frame cut short waits for the rest.
        var partial = Data(buffer.prefix(10))
        #expect(try HouseholdWire.unframe(&partial) == nil)
        #expect(try HouseholdWire.unframe(&buffer) == message)
        #expect(try HouseholdWire.unframe(&buffer)?.kind == .cancel)
        #expect(buffer.isEmpty)
        var huge = Data([0x00, 0x01, 0x00, 0x01]) + Data(repeating: 0x20, count: 10)
        #expect(throws: HouseholdWire.Malformed.self) { try HouseholdWire.unframe(&huge) }
        var garbage = Data([0, 0, 0, 3]) + Data("abc".utf8)
        #expect(throws: HouseholdWire.Malformed.self) { try HouseholdWire.unframe(&garbage) }
    }

    @Test func requestsNeedThePairKeyAFreshTimeAndANewNonce() throws {
        let key = SymmetricKey(size: .bits256), other = SymmetricKey(size: .bits256)
        var replay = HouseholdReplayGuard()
        let request = HouseholdCrypto.request(from: philip, to: anna, key: key, now: now)
        #expect(HouseholdCrypto.check(request, me: anna, key: { $0 == philip ? key : nil }, replay: &replay, now: now) == .ok)
        // The same request again is a replay.
        #expect(HouseholdCrypto.check(request, me: anna, key: { $0 == philip ? key : nil }, replay: &replay, now: now.addingTimeInterval(2)) == .replayed)
        // Signed with another key, for someone else, by a stranger, or too old.
        let forged = HouseholdCrypto.request(from: philip, to: anna, key: other, now: now)
        #expect(HouseholdCrypto.check(forged, me: anna, key: { _ in key }, replay: &replay, now: now) == .badMAC)
        #expect(HouseholdCrypto.check(HouseholdCrypto.request(from: philip, to: anna, key: key, now: now), me: philip, key: { _ in key }, replay: &replay, now: now) == .malformed)
        #expect(HouseholdCrypto.check(HouseholdCrypto.request(from: philip, to: anna, key: key, now: now), me: anna, key: { _ in nil }, replay: &replay, now: now) == .notPaired)
        #expect(HouseholdCrypto.check(HouseholdCrypto.request(from: philip, to: anna, key: key, now: now), me: anna, key: { _ in key }, replay: &replay, now: now.addingTimeInterval(45)) == .stale)
        // A tampered field breaks the MAC; a rejected request's nonce isn't remembered.
        var tampered = HouseholdCrypto.request(from: philip, to: anna, key: key, now: now)
        tampered.at = (tampered.at ?? 0) + 1
        #expect(HouseholdCrypto.check(tampered, me: anna, key: { _ in key }, replay: &replay, now: now) == .badMAC)
    }

    @Test func answersAreSealedForTheirRequestOnly() throws {
        let key = SymmetricKey(size: .bits256)
        let request = HouseholdCrypto.request(from: philip, to: anna, key: key, now: now)
        let response = try HouseholdCrypto.response(summary, to: request, me: anna, key: key)
        #expect(try HouseholdCrypto.open(response, for: request, peer: anna, key: key) == summary)
        // An old answer replayed against a new request, another key, or a different sender don't open.
        let later = HouseholdCrypto.request(from: philip, to: anna, key: key, now: now.addingTimeInterval(3))
        #expect(throws: (any Error).self) { try HouseholdCrypto.open(response, for: later, peer: anna, key: key) }
        #expect(throws: (any Error).self) { try HouseholdCrypto.open(response, for: request, peer: anna, key: SymmetricKey(size: .bits256)) }
        #expect(throws: (any Error).self) { try HouseholdCrypto.open(response, for: request, peer: philip, key: key) }
        // Nothing readable on the wire: no name or app in the frame.
        let wire = String(decoding: try HouseholdWire.frame(response), as: UTF8.self)
        #expect(!wire.contains("Steam") && !wire.contains("Anna"))
        // A refusal says why.
        #expect(throws: HouseholdWire.Malformed(reason: "notPaired")) { try HouseholdCrypto.open(HouseholdMessage(kind: .refused, id: anna, reason: "notPaired"), for: request, peer: anna, key: key) }
    }

    /// Runs two pairing sessions against each other, optionally through `relay`, which may change messages.
    private func pair(confirm: Bool = true, relay: (HouseholdMessage) -> HouseholdMessage = { $0 }) -> (HouseholdPairing, HouseholdPairing) {
        var (a, hello) = HouseholdPairing.initiator(me: philip, name: "Philip’s Mac")
        var b = HouseholdPairing.responder(me: anna, name: "Anna’s MacBook")
        var toB = [hello], toA: [HouseholdMessage] = []
        func drain() {
            while !toB.isEmpty || !toA.isEmpty {
                if !toB.isEmpty { toA += b.receive(relay(toB.removeFirst())) }
                if !toA.isEmpty { toB += a.receive(relay(toA.removeFirst())) }
            }
        }
        drain()
        if confirm { toB += a.confirm(); drain(); toA += b.confirm(); drain() }
        return (a, b)
    }

    @Test func pairingShowsTheSameCodeAndEndsWithTheSameKey() throws {
        let (a, b) = pair(confirm: false)
        #expect(a.state == .comparing && b.state == .comparing)
        #expect(a.code != nil && a.code == b.code && a.code?.count == 7)
        #expect(a.peer == anna && b.peer == philip && a.peerName == "Anna’s MacBook" && b.peerName == "Philip’s Mac")
        #expect(a.pairKey == nil)
        let (x, y) = pair()
        #expect(x.state == .paired && y.state == .paired)
        let keyA = try #require(x.pairKey), keyB = try #require(y.pairKey)
        #expect(keyA.withUnsafeBytes { Data($0) } == keyB.withUnsafeBytes { Data($0) })
        // Two pairings never share a code's key.
        let (other, _) = pair()
        #expect(other.pairKey.map { $0.withUnsafeBytes { Data($0) } } != keyA.withUnsafeBytes { Data($0) })
    }

    @Test func pairingNeedsBothPeopleAndRejectsTampering() {
        // One confirmation is not enough.
        var (a, b) = pair(confirm: false)
        let confirmation = a.confirm()
        #expect(a.state == .confirmed)
        _ = b.receive(confirmation[0])
        #expect(b.state == .comparing && b.pairKey == nil)
        // Someone in between who swaps the responder's key: the commitment no longer matches its key.
        let (mitm, _) = pair(confirm: false) { message in
            var changed = message
            if message.kind == .commit { changed.key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }
            return changed
        }
        #expect(mitm.state == .failed(.badCommitment))
        // A changed nonce: the codes differ, which is what the people comparing them catch, and the keys differ too.
        let (left, right) = pair(confirm: false) { message in
            var changed = message
            if message.kind == .reveal { changed.nonce = Data(repeating: 9, count: 16) }
            return changed
        }
        #expect(left.state == .failed(.badCommitment) || left.code != right.code)
        // A forged confirmation, a message out of turn, a cancel.
        var (c, _) = pair(confirm: false)
        _ = c.receive(HouseholdMessage(kind: .confirm, mac: Data(repeating: 0, count: 32)))
        #expect(c.state == .failed(.badConfirmation))
        var d = HouseholdPairing.responder(me: anna, name: "Anna")
        #expect(d.receive(HouseholdMessage(kind: .nonce, nonce: Data(count: 16))).first?.kind == .cancel)
        #expect(d.state == .failed(.outOfOrder))
        var (e, _) = pair(confirm: false)
        #expect(e.cancel().first?.kind == .cancel && e.state == .failed(.cancelled) && e.pairKey == nil)
        // A Mac can't pair with itself.
        var f = HouseholdPairing.responder(me: philip, name: "Me")
        _ = f.receive(HouseholdPairing.initiator(me: philip, name: "Me").1)
        #expect(f.state == .failed(.malformed))
    }

    private func freeze(peers: [CallSamples.Peer], household: Bool = true, arrivals: [CallSamples.Arrival] = [], withoutRouter: Bool = true, loggedOut: Double? = nil) -> CallReport.Cause? {
        func pings(_ values: [Double?]) -> [CallSamples.Ping] { values.enumerated().map { .init(at: Double($0.offset), ms: $0.element) } }
        var samples = CallSamples()
        samples.internet = pings(Array(repeating: 30, count: 100) + [nil, 600, nil] + Array(repeating: 30, count: 100))
        samples.router = pings(Array(repeating: 3, count: 203))
        samples.household = household ? [.init(at: 95, upload: 20_000, download: 4_000_000)] : nil
        samples.arrivals = arrivals
        samples.peers = peers
        samples.peersWithoutRouter = withoutRouter
        samples.loggedOut = loggedOut
        return CallAnalysis.report(app: "Zoom", browser: false, start: now, end: now.addingTimeInterval(600), network: nil, samples: samples).freezes.first?.cause
    }

    @Test func aPairedMacThatWasBusyComesBeforeANewDeviceAndTheGenericCause() {
        let steam = CallSamples.Peer(at: 97, name: "Anna’s MacBook", upload: 20_000, download: 3_900_000, app: "Steam")
        let rita = CallSamples.Arrival(at: -120, name: "Rita’s iPad")
        let named = freeze(peers: [steam], arrivals: [rita])
        #expect(named?.phrase == "caused by Anna’s MacBook downloading (Steam)")
        #expect(named?.kilobat == true && named?.advice.contains("Steam") == true)
        // A quiet paired Mac, or one heard long before the freeze, isn't the cause: the device that joined is named.
        #expect(freeze(peers: [.init(at: 97, name: "Anna’s MacBook", upload: 0, download: 20_000, app: "Safari")], arrivals: [rita])?.phrase == "caused by Rita’s iPad downloading")
        #expect(freeze(peers: [.init(at: 40, name: "Anna’s MacBook", upload: 0, download: 3_900_000, app: "Steam")], arrivals: [rita])?.phrase == "caused by Rita’s iPad downloading")
        // Neither: the generic wording.
        #expect(freeze(peers: [])?.phrase == "caused by another device on your network downloading")
        // The busier of two paired Macs, and an upload named as one.
        let both = freeze(peers: [steam, .init(at: 99, name: "Studio iMac", upload: 2_000_000, download: 0, app: "Dropbox")])
        #expect(both?.phrase == "caused by Studio iMac uploading (Dropbox)")
        // Without the router's counters a paired Mac's own report still names it; without either, it's beyond the router.
        #expect(freeze(peers: [steam], household: false)?.device == "Anna’s MacBook")
        #expect(freeze(peers: [steam], household: false)?.unconfirmed == true && named?.unconfirmed == nil)
        // A service outage found after the call outranks a paired Mac only its own report blamed, not one the router confirms.
        #expect(freeze(peers: [steam], household: false, withoutRouter: false)?.kind == .beyondRouter)
        #expect(freeze(peers: [steam], withoutRouter: false)?.device == "Anna’s MacBook")
        // The Wi-Fi's sign-in page logging the Mac out explains a freeze before any other device does.
        #expect(freeze(peers: [steam], loggedOut: 90)?.kind == .portal)
        #expect(freeze(peers: [], household: false, arrivals: [rita])?.kind == .beyondRouter)
        // A paired Mac with no busiest app.
        #expect(freeze(peers: [.init(at: 97, name: "Anna’s MacBook", upload: 0, download: 3_900_000, app: nil)])?.phrase == "caused by Anna’s MacBook downloading")
    }

    @Test func anOldSummaryIsIgnored() {
        let live = HouseholdLive(summary: summary, received: now)
        #expect(live.fresh(now: now.addingTimeInterval(5)))
        #expect(!live.fresh(now: now.addingTimeInterval(HouseholdLive.maxAge + 1)))
        // Received just now, but taken long ago by its own clock: a replayed or wrong-clock summary.
        var old = summary; old.at = now.addingTimeInterval(-300)
        #expect(!HouseholdLive(summary: old, received: now).fresh(now: now))
    }

    @Test func summariesNameTheBusiestAppsOnly() {
        func app(_ id: String, _ name: String, down: Double, carrier: Bool = false) -> AppTraffic {
            var traffic = AppTraffic(id: id, name: name, bundlePath: nil); traffic.downloadRate = down; traffic.carrier = carrier; return traffic
        }
        let apps = [app("steam", "Steam", down: 5_000_000), app("tunnel", "WireGuard", down: 9_000_000, carrier: true), app("safari", "Safari", down: 80_000),
                    app("music", "Music", down: 30_000), app("mail", "Mail", down: 20_000), app("idle", "Notes", down: 100)]
        let made = HouseholdSummary.make(id: anna, name: "  Anna’s\nMacBook ", download: 5_200_000, upload: 1_000, apps: apps, onCall: true, now: now)
        #expect(made.apps == ["Steam", "Safari", "Music"])
        #expect(made.name == "Anna’sMacBook" && made.call && made.busy && !made.uploading)
    }

    @Test func theBookKeepsPeersPerNetwork() {
        var book = HouseholdBook(me: anna)
        #expect(!book.sharing && HouseholdBook.validID(HouseholdBook.newID()) && !HouseholdBook.validID("not-an-id"))
        book.add(HouseholdPeer(id: philip, name: "Philip’s Mac", network: "home", networkName: "Home", paired: now))
        book.add(HouseholdPeer(id: philip, name: "Philip’s Mac", network: "home", networkName: "Home", paired: now))
        #expect(book.peers.count == 1 && book.peers(on: "home").count == 1 && book.peers(on: "café").isEmpty)
        book.rename(peer: philip, to: "Philip’s MacBook Pro")
        #expect(book.peer(philip)?.name == "Philip’s MacBook Pro")
        #expect(book.remove(philip) && book.peers.isEmpty)
    }

    @Test func parsesTheHouseholdCommand() throws {
        #expect(try HouseholdCommand.parse(["household"]) == .list(json: false))
        #expect(try HouseholdCommand.parse(["household", "--json"]) == .list(json: true))
        #expect(throws: DiagnosticError.self) { try HouseholdCommand.parse(["household", "pair"]) }
        #expect(throws: DiagnosticError.self) { try HouseholdCommand.parse(["household", "--all"]) }
    }

    @Test func onlyLocalAddressesMayConnect() {
        for host in ["192.168.1.20", "10.0.0.5", "172.20.1.1", "169.254.3.4", "127.0.0.1", "fe80::1%en0", "fd12:3456::1", "::1", "::ffff:192.168.1.2"] { #expect(HouseholdLink.local(host), "\(host)") }
        for host in ["8.8.8.8", "172.32.0.1", "2001:db8::1", "example.com", "100.64.0.1"] { #expect(!HouseholdLink.local(host), "\(host)") }
    }

    /// Two peers in this process over 127.0.0.1: they pair, both people confirm, then one asks the other for its summary.
    @Test func twoPeersPairAndTalkOverLoopback() async throws {
        actor Box { var key: SymmetricKey?; var code: String?; func set(_ key: SymmetricKey?, _ code: String?) { self.key = key; self.code = code } }
        let responderKey = Box()
        let anna = anna, philip = philip, summary = summary
        let server = HouseholdServer(onConnection: { link in
            Task {
                guard let first = try? await link.receive() else { link.cancel(); return }
                if first.kind == .hello {
                    var session = HouseholdPairing.responder(me: anna, name: "Anna’s MacBook")
                    for reply in session.receive(first) { try? await link.send(reply) }
                    while !session.finished, let message = try? await link.receive() {
                        for reply in session.receive(message) { try? await link.send(reply) }
                        if session.state == .comparing { for reply in session.confirm() { try? await link.send(reply) } }
                    }
                    await responderKey.set(session.pairKey, session.code)
                } else if first.kind == .request, let key = await responderKey.key {
                    var replay = HouseholdReplayGuard()
                    if HouseholdCrypto.check(first, me: anna, key: { $0 == philip ? key : nil }, replay: &replay) == .ok,
                       let response = try? HouseholdCrypto.response(summary, to: first, me: anna, key: key) { try? await link.send(response) }
                }
                try? await Task.sleep(for: .milliseconds(200))
                link.cancel()
            }
        })
        try server.start(name: "test", txt: [:], loopback: true)
        defer { server.stop() }
        let port = try #require(await server.ready())
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)))

        let link = try await HouseholdConnection.connect(to: endpoint)
        var (session, hello) = HouseholdPairing.initiator(me: philip, name: "Philip’s Mac")
        try await link.send(hello)
        var confirmed = false
        while !session.finished {
            let message = try await link.receive()
            for reply in session.receive(message) { try await link.send(reply) }
            if session.state == .comparing, !confirmed { confirmed = true; for reply in session.confirm() { try await link.send(reply) } }
        }
        link.cancel()
        #expect(session.state == .paired)
        let key = try #require(session.pairKey)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await responderKey.code == session.code)

        let live = try await HouseholdStore.ask(endpoint: endpoint, me: philip, peer: anna, key: key)
        #expect(live.summary == summary && live.address == "127.0.0.1")
        // A Mac with the wrong key gets nothing.
        await #expect(throws: (any Error).self) { try await HouseholdStore.ask(endpoint: endpoint, me: philip, peer: anna, key: SymmetricKey(size: .bits256)) }
    }

    @MainActor @Test func theStoreSavesTheBookWithoutKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-household-\(UUID().uuidString)")
        let keys = MemoryHouseholdKeys()
        let store = HouseholdStore(directory: folder, keys: keys)
        store.sharing = true
        store.rename("Anna’s MacBook")
        let saved = try #require(HouseholdStore.load(directory: folder))
        #expect(saved.sharing && saved.name == "Anna’s MacBook" && saved.me == store.book.me)
        let text = try String(contentsOf: folder.appendingPathComponent("household.json"), encoding: .utf8)
        #expect(!text.contains("key"))
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("household.json").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        // Without Pro nothing is read, and the report says so.
        let report = store.report()
        #expect(report.pro == false && report.peers.isEmpty && report.sharing)
    }
}
