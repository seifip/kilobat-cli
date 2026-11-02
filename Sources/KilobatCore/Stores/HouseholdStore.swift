import Foundation
import Observation
import CryptoKit
import Security
import SystemConfiguration
import Network

/// Where the pair keys live. The app keeps them in the login Keychain; tests and screenshots in memory.
public protocol HouseholdKeyStore: AnyObject {
    func key(for peer: String) -> SymmetricKey?
    func set(_ key: SymmetricKey, for peer: String) throws
    func remove(_ peer: String)
}

/// One generic password per paired Mac, this device only, never synced to iCloud.
public final class KeychainHouseholdKeys: HouseholdKeyStore {
    static let service = "co.seifi.kilobat.household"
    public init() {}
    private func query(_ peer: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: peer, kSecAttrSynchronizable as String: false]
    }
    public func key(for peer: String) -> SymmetricKey? {
        var query = query(peer); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
    public func set(_ key: SymmetricKey, for peer: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        remove(peer)
        var insert = query(peer); insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecAttrLabel as String] = "Kilobat household pairing"
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw HouseholdLinkError.failed("Keychain error \(status)") }
    }
    public func remove(_ peer: String) { SecItemDelete(query(peer) as CFDictionary) }
}

public final class MemoryHouseholdKeys: HouseholdKeyStore {
    private var keys: [String: SymmetricKey] = [:]
    public init() {}
    public func key(for peer: String) -> SymmetricKey? { keys[peer] }
    public func set(_ key: SymmetricKey, for peer: String) throws { keys[peer] = key }
    public func remove(_ peer: String) { keys[peer] = nil }
}

/// The network this Mac is on, as the app sees it.
public struct HouseholdNetwork: Equatable, Sendable {
    public var key: String
    public var name: String
    public var home: Bool
    public init(key: String, name: String, home: Bool) { self.key = key; self.name = name; self.home = home }
}

/// A pairing in progress, for the Household settings.
public struct HouseholdPairingStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case connecting, comparing, waiting, paired, failed(String) }
    public var peerName: String
    public var code: String?
    public var phase: Phase
    /// The other Mac asked; this one shows the request.
    public var incoming: Bool
    public init(peerName: String, code: String? = nil, phase: Phase, incoming: Bool) { self.peerName = peerName; self.code = code; self.phase = phase; self.incoming = incoming }
}

/// Household Macs on this Mac: whether it shares its summary with the Macs it is paired with, the pairing itself, and,
/// with Kilobat Pro, the other Macs' summaries, asked for every few seconds only while something needs them: a call,
/// the Devices tab or Household settings on screen, or the CLI. Off by default, and only on a network marked home.
@MainActor @Observable public final class HouseholdStore {
    public enum Need: String, Sendable { case devices, settings }
    /// Open to pairing this long after the person asks.
    public static let pairingWindow: TimeInterval = 180
    /// How long a pairing may take, codes compared included.
    public static let pairingTimeout: TimeInterval = 120

    public private(set) var book: HouseholdBook
    public private(set) var live: [String: HouseholdLive] = [:]
    /// Peers that didn't answer the last time they were asked.
    public private(set) var unreachable: Set<String> = []
    /// Peers that answered they don't share with this Mac now, and why.
    public private(set) var refused: [String: String] = [:]
    /// Kilobat Macs open to pairing on this network.
    public private(set) var nearby: [HouseholdNearby] = []
    public private(set) var pairing: HouseholdPairingStatus?
    public private(set) var pairableUntil: Date?
    public private(set) var localNetwork: LocalNetworkAccess = .unknown
    public private(set) var persistenceError: String?
    public private(set) var answering = false

    /// Whether this Mac may read other Macs' usage: Kilobat Pro.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    /// This Mac's rates and apps now.
    @ObservationIgnored public var usage: () -> (download: Double, upload: Double, apps: [AppTraffic])? = { nil }
    @ObservationIgnored public var network: () -> HouseholdNetwork? = { nil }
    @ObservationIgnored public var inCall: () -> Bool = { false }

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let keys: HouseholdKeyStore
    @ObservationIgnored private var keyCache: [String: SymmetricKey] = [:]
    @ObservationIgnored private var stamp: Date?
    @ObservationIgnored private var server: HouseholdServer?
    @ObservationIgnored private var browser: HouseholdBrowser?
    @ObservationIgnored private var found: [HouseholdNearby] = []
    @ObservationIgnored private var replay = HouseholdReplayGuard()
    @ObservationIgnored private var lastAnswer: [String: Date] = [:]
    @ObservationIgnored private var needs: Set<Need> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastPoll = Date.distantPast
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var advertised: [String: String]?
    @ObservationIgnored private var session: HouseholdPairing?
    @ObservationIgnored private var sessionLink: HouseholdConnection?
    @ObservationIgnored private var sessionNetwork: HouseholdNetwork?

    public init(directory: URL? = nil, keys: HouseholdKeyStore = KeychainHouseholdKeys()) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("household.json")
        self.keys = keys
        book = Self.load(file) ?? HouseholdBook()
        if Self.load(file) == nil { save() }
    }

    nonisolated public static func load(directory: URL? = nil) -> HouseholdBook? {
        load((directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")).appendingPathComponent("household.json"))
    }
    nonisolated static func load(_ file: URL) -> HouseholdBook? {
        guard let book: HouseholdBook = StoredJSON.read(file), HouseholdBook.validID(book.me) else { return nil }
        return book
    }

    /// The name other Macs see: the person's, else the computer's.
    public var name: String { book.name ?? Self.computerName }
    nonisolated public static var computerName: String {
        let name = HouseholdNames.clean((SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "")
        return name.isEmpty ? "Mac" : name
    }

    public var sharing: Bool {
        get { book.sharing }
        set { change { $0.sharing = newValue }; reconcile() }
    }
    public func rename(_ name: String) {
        let clean = HouseholdNames.clean(name)
        change { $0.name = clean.isEmpty || clean == Self.computerName ? nil : clean }
        reconcile()
    }

    private func change(_ edit: (inout HouseholdBook) -> Void) {
        var next = book; edit(&next)
        guard next != book else { return }
        book = next; save()
    }
    private func save() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(book).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    private func key(_ peer: String) -> SymmetricKey? {
        guard book.peer(peer) != nil else { return nil }
        if let cached = keyCache[peer] { return cached }
        let key = keys.key(for: peer)
        keyCache[peer] = key
        return key
    }

    // MARK: Running

    /// Starts the loop that keeps the listener, the browser and the asking in step with the settings and the network.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.reconcile()
                await self?.pollIfDue()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        loop?.cancel(); loop = nil
        server?.stop(); server = nil; browser?.stop(); browser = nil; answering = false; advertised = nil
    }

    /// Something on screen wants the other Macs' summaries, or no longer does.
    public func need(_ reason: Need, _ on: Bool) {
        if on { needs.insert(reason); lastPoll = .distantPast } else { needs.remove(reason) }
        reconcile()
    }

    private var wanted: Bool { !needs.isEmpty || inCall() }
    public var pairable: Bool { pairableUntil.map { $0 > Date() } ?? false }

    /// Starts or stops the listener and the browser, and updates the Bonjour record.
    public func reconcile() {
        // Nothing listens or browses until the app starts the store: not in tests, previews or screenshot runs.
        guard loop != nil else { return }
        let net = network()
        if let until = pairableUntil, until <= Date(), pairing == nil { pairableUntil = nil }
        let home = net?.home == true
        answering = home && book.sharing
        let listen = home && (book.sharing || pairable)
        if listen {
            let txt = pairable ? ["v": "1", "id": book.me, "p": "1", "n": name] : ["v": "1", "id": book.me]
            if server == nil {
                let server = HouseholdServer(onConnection: { [weak self] link in Task { @MainActor in await self?.accept(link) } },
                                             onState: { [weak self] state in Task { @MainActor in self?.noteAccess(state) } })
                do { try server.start(name: "Kilobat " + book.me.prefix(8), txt: txt); self.server = server; advertised = txt }
                catch { self.server = nil }
            } else if advertised != txt {
                server?.advertise(name: "Kilobat " + book.me.prefix(8), txt: txt); advertised = txt
            }
        } else if server != nil {
            server?.stop(); server = nil; advertised = nil
        }
        let peersHere = net.map { book.peers(on: $0.key) } ?? []
        let browse = home && (pairable || (wanted && allowed() && !peersHere.isEmpty))
        if browse, browser == nil {
            let browser = HouseholdBrowser(onResults: { [weak self] results in Task { @MainActor in self?.heard(results) } },
                                           onState: { [weak self] state in Task { @MainActor in self?.noteAccess(state) } })
            browser.start(); self.browser = browser
        } else if !browse, browser != nil {
            browser?.stop(); browser = nil; found = []; nearby = []
        }
    }

    private func noteAccess(_ state: LocalNetworkAccess) {
        if state == .denied || localNetwork != .denied || state == .allowed { localNetwork = state }
    }

    private func heard(_ results: [HouseholdNearby]) {
        found = results.filter { $0.id != book.me }
        nearby = found.filter(\.pairing)
    }

    // MARK: Asking paired Macs

    private func pollIfDue() async {
        guard wanted, allowed(), !polling else { return }
        let interval: TimeInterval = inCall() ? 3 : 5
        guard Date().timeIntervalSince(lastPoll) >= interval else { return }
        await refresh()
    }

    /// Asks every Mac paired on this network for its summary now.
    public func refresh() async {
        guard allowed(), !polling, let net = network(), net.home else { return }
        let peers = book.peers(on: net.key)
        guard !peers.isEmpty else { return }
        polling = true; lastPoll = Date()
        defer { polling = false }
        if browser == nil, loop != nil {
            reconcile()
            if browser == nil {
                let browser = HouseholdBrowser(onResults: { [weak self] results in Task { @MainActor in self?.heard(results) } },
                                               onState: { [weak self] state in Task { @MainActor in self?.noteAccess(state) } })
                browser.start(); self.browser = browser
            }
        }
        // A browser that just started needs a moment to hear the others.
        for _ in 0..<20 where peers.contains(where: { peer in !found.contains { $0.id == peer.id } }) { try? await Task.sleep(for: .milliseconds(100)) }
        let me = book.me
        await withTaskGroup(of: (String, Result<HouseholdLive, Error>).self) { group in
            for peer in peers {
                guard let endpoint = found.first(where: { $0.id == peer.id })?.endpoint, let key = key(peer.id) else {
                    unreachable.insert(peer.id); continue
                }
                let id = peer.id
                group.addTask {
                    do { return (id, .success(try await Self.ask(endpoint: endpoint, me: me, peer: id, key: key))) }
                    catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let answer):
                    live[id] = answer; unreachable.remove(id); refused[id] = nil; localNetwork = .allowed
                    if book.peer(id)?.name != answer.summary.name { change { $0.rename(peer: id, to: answer.summary.name) } }
                case .failure(let error):
                    if let reason = (error as? HouseholdWire.Malformed)?.reason, ["notPaired", "notSharing", "otherNetwork"].contains(reason) { refused[id] = reason; unreachable.remove(id) }
                    else { unreachable.insert(id) }
                    if error as? HouseholdLinkError == .localNetworkDenied { localNetwork = .denied }
                }
            }
        }
    }

    /// One request to one Mac: connect, ask, open the sealed answer.
    nonisolated public static func ask(endpoint: NWEndpoint, me: String, peer: String, key: SymmetricKey, now: Date = Date()) async throws -> HouseholdLive {
        let link = try await HouseholdConnection.connect(to: endpoint)
        defer { link.cancel() }
        let request = HouseholdCrypto.request(from: me, to: peer, key: key, now: now)
        try await link.send(request)
        let answer = try await link.receive(timeout: 4)
        let summary = try HouseholdCrypto.open(answer, for: request, peer: peer, key: key)
        return HouseholdLive(summary: summary, received: Date(), address: link.remoteAddress)
    }

    /// Fresh summaries from Macs paired on this network.
    public func current(now: Date = Date()) -> [HouseholdLive] {
        guard let net = network() else { return [] }
        let here = Set(book.peers(on: net.key).map(\.id))
        return live.filter { here.contains($0.key) && $0.value.fresh(now: now) }.map(\.value).sorted { $0.summary.name < $1.summary.name }
    }
    /// Fresh summaries busy enough to freeze a call.
    public func busy(now: Date = Date()) -> [HouseholdLive] { current(now: now).filter(\.summary.busy) }

    // MARK: Answering

    private func accept(_ link: HouseholdConnection) async {
        defer { if session == nil || sessionLink !== link { link.cancel() } }
        guard let first = try? await link.receive(timeout: 5) else { return }
        switch first.kind {
        case .request: await answer(first, on: link)
        case .hello: await respond(to: first, on: link)
        default: break
        }
    }

    private func answer(_ request: HouseholdMessage, on link: HouseholdConnection) async {
        let verdict = HouseholdCrypto.check(request, me: book.me, key: key, replay: &replay)
        guard verdict == .ok, let from = request.id, let peer = book.peer(from), let key = key(from) else {
            if verdict == .notPaired { try? await link.send(HouseholdMessage(kind: .refused, id: book.me, reason: "notPaired")) }
            return
        }
        guard let net = network(), net.home, book.sharing else { try? await link.send(HouseholdMessage(kind: .refused, id: book.me, reason: "notSharing")); return }
        guard peer.network == net.key else { try? await link.send(HouseholdMessage(kind: .refused, id: book.me, reason: "otherNetwork")); return }
        // A paired Mac asks every few seconds; faster than once a second is refused.
        if let last = lastAnswer[from], Date().timeIntervalSince(last) < 0.8 { try? await link.send(HouseholdMessage(kind: .refused, id: book.me, reason: "busy")); return }
        lastAnswer[from] = Date()
        let traffic = usage()
        let summary = HouseholdSummary.make(id: book.me, name: name, download: traffic?.download ?? 0, upload: traffic?.upload ?? 0, apps: traffic?.apps ?? [], onCall: inCall())
        guard let response = try? HouseholdCrypto.response(summary, to: request, me: book.me, key: key) else { return }
        try? await link.send(response)
    }

    // MARK: Pairing

    /// Makes this Mac open to pairing for three minutes and looks for others that are.
    public func openPairing() {
        guard network()?.home == true else { return }
        pairableUntil = Date().addingTimeInterval(Self.pairingWindow)
        if case .failed? = pairing?.phase { pairing = nil }
        if pairing?.phase == .paired { pairing = nil }
        reconcile()
    }
    public func closePairing() {
        if session != nil { cancelPairing() }
        pairableUntil = nil; pairing = nil
        reconcile()
    }

    /// Asks a Mac open to pairing to pair with this one.
    public func pair(with mac: HouseholdNearby) {
        guard session == nil, let net = network(), net.home else { return }
        let (start, hello) = HouseholdPairing.initiator(me: book.me, name: name)
        session = start; sessionNetwork = net
        pairing = HouseholdPairingStatus(peerName: mac.name ?? String(localized: "the other Mac", comment: "Household pairing, when the other Mac's name isn't known"), phase: .connecting, incoming: false)
        Task {
            do {
                let link = try await HouseholdConnection.connect(to: mac.endpoint)
                sessionLink = link
                try await link.send(hello)
                await run(on: link)
            } catch {
                finish(failure: error as? HouseholdLinkError == .localNetworkDenied
                       ? String(localized: "Local Network access is off for Kilobat.", comment: "Household pairing failed")
                       : String(localized: "Couldn’t reach that Mac.", comment: "Household pairing failed"))
            }
        }
    }

    /// Another Mac asked to pair while this one is open to it.
    private func respond(to hello: HouseholdMessage, on link: HouseholdConnection) async {
        guard pairable, session == nil, let net = network(), net.home else {
            try? await link.send(HouseholdMessage(kind: .cancel, reason: "busy")); return
        }
        var responder = HouseholdPairing.responder(me: book.me, name: name)
        let replies = responder.receive(hello)
        session = responder; sessionLink = link; sessionNetwork = net
        pairing = HouseholdPairingStatus(peerName: responder.peerName ?? String(localized: "the other Mac"), phase: .connecting, incoming: true)
        for reply in replies { try? await link.send(reply) }
        await run(on: link)
    }

    /// Reads the other Mac's messages until the pairing ends.
    private func run(on link: HouseholdConnection) async {
        let deadline = Date().addingTimeInterval(Self.pairingTimeout)
        while let open = session, !open.finished, sessionLink === link {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let message = try? await link.receive(timeout: left) else {
                if session != nil, sessionLink === link { _ = session?.cancel(); finish(failure: String(localized: "Pairing timed out or the other Mac stopped.", comment: "Household pairing failed")) }
                return
            }
            // The person may have confirmed while this waited: read the session again.
            guard var current = session, sessionLink === link else { return }
            let replies = current.receive(message)
            session = current
            for reply in replies { try? await link.send(reply) }
            update()
        }
    }

    /// This Mac's person saw the same code on both Macs.
    public func confirmPairing() {
        guard var current = session, let link = sessionLink else { return }
        let replies = current.confirm()
        session = current
        Task { for reply in replies { try? await link.send(reply) }; update() }
        update()
    }

    public func cancelPairing() {
        guard var current = session else { pairing = nil; return }
        let replies = current.cancel()
        let link = sessionLink
        session = nil; sessionLink = nil
        Task { for reply in replies { try? await link?.send(reply) }; link?.cancel() }
        pairing = nil
    }

    private func update() {
        guard let current = session else { return }
        var status = pairing ?? HouseholdPairingStatus(peerName: current.peerName ?? "", phase: .connecting, incoming: current.role == .responder)
        if let name = current.peerName, !name.isEmpty { status.peerName = name }
        status.code = current.code
        switch current.state {
        case .awaitingHello, .awaitingCommit, .awaitingNonce, .awaitingReveal: status.phase = .connecting
        case .comparing: status.phase = .comparing
        case .confirmed: status.phase = .waiting
        case .paired:
            pairing = status
            complete(current)
            return
        case .failed(let failure):
            pairing = status
            finish(failure: failure == .cancelled ? String(localized: "Pairing was cancelled.", comment: "Household pairing failed")
                                                  : String(localized: "The Macs couldn’t agree on a key. Try again.", comment: "Household pairing failed"))
            return
        }
        pairing = status
    }

    private func complete(_ current: HouseholdPairing) {
        guard let key = current.pairKey, let peer = current.peer, let net = sessionNetwork else { finish(failure: String(localized: "Pairing failed.")); return }
        do { try keys.set(key, for: peer) } catch {
            finish(failure: String(localized: "Kilobat couldn’t save the pairing in the Keychain.", comment: "Household pairing failed")); return
        }
        keyCache[peer] = key
        change { $0.add(HouseholdPeer(id: peer, name: current.peerName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Mac"), network: net.key, networkName: net.name, paired: Date())) }
        refused[peer] = nil; unreachable.remove(peer)
        let link = sessionLink
        session = nil; sessionLink = nil; sessionNetwork = nil
        pairing?.phase = .paired
        pairableUntil = nil
        // The last confirmation may still be on its way.
        Task { try? await Task.sleep(for: .seconds(1)); link?.cancel() }
        reconcile()
        lastPoll = .distantPast
    }

    private func finish(failure: String) {
        let link = sessionLink
        session = nil; sessionLink = nil; sessionNetwork = nil
        link?.cancel()
        if pairing != nil { pairing?.phase = .failed(failure) }
        else { pairing = HouseholdPairingStatus(peerName: "", phase: .failed(failure), incoming: false) }
    }

    /// Forgets a paired Mac and its key. The other Mac learns it the next time it asks.
    public func unpair(_ id: String) {
        keys.remove(id); keyCache[id] = nil
        live[id] = nil; refused[id] = nil; unreachable.remove(id)
        change { $0.remove(id) }
        reconcile()
    }

    /// `kilobat household --json` and MCP `get_household`, as the running app sees it.
    public func report() -> HouseholdReport {
        let net = network(), pro = allowed(), now = Date()
        let peers = book.peers.map { peer -> HouseholdReport.Peer in
            let here = peer.network == net?.key
            let fresh = live[peer.id].flatMap { $0.fresh(now: now) ? $0 : nil }
            return HouseholdReport.Peer(id: peer.id, name: peer.name, network: peer.networkName, pairedAt: peer.paired, onThisNetwork: here,
                                        reachable: here && pro ? (fresh != nil ? true : unreachable.contains(peer.id) ? false : nil) : nil,
                                        refused: refused[peer.id], live: pro ? fresh?.summary : nil,
                                        ageSeconds: pro ? fresh.map { (now.timeIntervalSince($0.received) * 10).rounded() / 10 } : nil, busy: pro ? fresh?.summary.busy : nil)
        }
        return HouseholdReport(name: name, sharing: book.sharing, answering: answering, network: net?.name, home: net?.home, appRunning: true, pro: pro,
                               localNetwork: localNetwork.rawValue, peers: peers)
    }

    #if DEBUG
    /// Made-up Macs for screenshots and layout checks; debug builds only. Nothing is listened for or sent.
    public func preview(book: HouseholdBook, live: [HouseholdLive], nearby: [HouseholdNearby] = [], pairing: HouseholdPairingStatus? = nil,
                        unreachable: Set<String> = [], pairable: Bool = false, localNetwork: LocalNetworkAccess = .allowed) {
        self.book = book; self.live = Dictionary(live.map { ($0.summary.id, $0) }) { $1 }; self.nearby = nearby; self.pairing = pairing
        self.unreachable = unreachable; self.localNetwork = localNetwork; pairableUntil = pairable ? Date().addingTimeInterval(Self.pairingWindow) : nil
        answering = book.sharing
    }
    #endif
}
