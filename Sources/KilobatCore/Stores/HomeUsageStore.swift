import Foundation
import Observation
import Security

/// Where router passwords and API keys live. The app keeps them in the login Keychain; tests and screenshots in memory.
public protocol RouterSecretStore: AnyObject {
    func secret(for id: String) -> String?
    @discardableResult func set(_ secret: String, for id: String) -> Bool
    func remove(_ id: String)
    /// Every saved connection id, to clear out ones whose router was disconnected while the app wasn't running.
    func ids() -> [String]
}

/// One generic password per connected router, this device only, never synced to iCloud.
public final class KeychainRouterSecrets: RouterSecretStore {
    static let service = "co.seifi.kilobat.router"
    public init() {}
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }
    public func secret(for id: String) -> String? {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult public func set(_ secret: String, for id: String) -> Bool {
        remove(id)
        var insert = query(id)
        insert[kSecValueData as String] = Data(secret.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecAttrLabel as String] = "Kilobat: router sign-in"
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
    public func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
    public func ids() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

public final class MemoryRouterSecrets: RouterSecretStore {
    private var secrets: [String: String] = [:]
    public init(_ secrets: [String: String] = [:]) { self.secrets = secrets }
    public func secret(for id: String) -> String? { secrets[id] }
    @discardableResult public func set(_ secret: String, for id: String) -> Bool { secrets[id] = secret; return true }
    public func remove(_ id: String) { secrets[id] = nil }
    public func ids() -> [String] { Array(secrets.keys) }
}

/// What the setup sheet sends: the router, where it is, and how to sign in.
public struct RouterDraft: Sendable, Equatable {
    public var kind: RouterKind
    public var entered: String
    public var user: String
    public var secret: String
    public var auth: RouterConnection.Auth
    /// The certificate the person just confirmed.
    public var pin: String?
    public init(kind: RouterKind, entered: String, user: String = "", secret: String, auth: RouterConnection.Auth = .password, pin: String? = nil) {
        self.kind = kind; self.entered = entered; self.user = user; self.secret = secret; self.auth = auth; self.pin = pin
    }
}

/// Connect your router (Kilobat Pro): the router per home network, read through its own local API every 10–15 seconds
/// while Devices or a call needs it and every few minutes otherwise, with each device's bytes per day for 30 days.
/// router.json holds the connection, home-usage.json the daily totals; the password is in the Keychain.
@MainActor @Observable public final class HomeUsageStore {
    public enum Need: String, Sendable { case devices, call, settings }
    public enum Phase: Equatable, Sendable { case idle, connecting, ok, needsAttention(String), failed(String) }
    public enum Outcome: Equatable, Sendable {
        case connected
        /// The router showed its own certificate; ask the person, then connect again with `pin`.
        case certificate(fingerprint: String, changed: Bool)
        case failed(String)
    }
    public struct Book: Codable, Sendable, Equatable { public var routers: [RouterConnection] = []; public init() {} }

    public private(set) var book = Book()
    public private(set) var phase: Phase = .idle
    public private(set) var latest: RouterPoll?
    public private(set) var rates: [String: HomeUsageMerge.Rate] = [:]
    public private(set) var line: HomeUsageMerge.Rate?
    public private(set) var ledger = HomeUsageLedger()
    /// The connected router's firmware and whether an update is out, as its API (or OpenWrt's release list) says.
    public private(set) var firmware: RouterFirmware?
    /// What detection found on each network's router.
    public private(set) var detected: [String: RouterDetect.Found] = [:]
    public private(set) var persistenceError: String?

    /// Reading the router is Kilobat Pro.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    /// The network now, and whether it is marked home.
    @ObservationIgnored public var network: () -> HouseholdNetwork? = { nil }
    @ObservationIgnored public var known: (String) -> DeviceNetwork? = { _ in nil }
    @ObservationIgnored public var peers: () -> [HouseholdLive] = { [] }
    @ObservationIgnored public var thisMac: () -> HomeUsageMerge.ThisMac? = { nil }
    @ObservationIgnored public var sleeping: () -> Bool = { false }
    /// The router's own uptime, for router check-up's restarts: network key, seconds, when read.
    @ObservationIgnored public var onUptime: ((String, TimeInterval, Date) -> Void)?
    /// The connected router reported its firmware: router check-up then knows it was checked.
    @ObservationIgnored public var onFirmware: ((String, RouterFirmware) -> Void)?
    /// Detection recognised the router on a network: router check-up then knows its maker.
    @ObservationIgnored public var onDetected: ((String, RouterKind) -> Void)?
    /// OpenWrt's published release list, asked at most once a week; tests answer it themselves.
    @ObservationIgnored public var releases: () async -> OpenWrtReleases? = {
        var request = URLRequest(url: OpenWrtReleases.url); request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return OpenWrtReleases.parse(data)
    }
    @ObservationIgnored private var knownReleases: (date: Date, releases: OpenWrtReleases)?
    /// How requests go out; tests point it at a local server.
    @ObservationIgnored public var transport: (_ pin: String?) -> RouterTransport = { RouterSession(pin: $0) }
    @ObservationIgnored public var loopback = false

    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private let secrets: RouterSecretStore
    @ObservationIgnored private var meter = RouterMeter()
    @ObservationIgnored private var measuredConnection: String?
    @ObservationIgnored private var phaseConnection: String?
    @ObservationIgnored private var reader: (id: String, reader: RouterReader)?
    @ObservationIgnored private var needs: Set<Need> = []
    @ObservationIgnored private var consumerNeeds: [Need: Set<UUID>] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastPoll = Date.distantPast
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var detecting: Set<String> = []

    nonisolated public static let bookFile = "router.json"
    nonisolated public static let ledgerFile = "home-usage.json"
    /// While Devices is open, or settings: every 15 s; during a call every 10 s.
    public static let fast: TimeInterval = 15, call: TimeInterval = 10
    /// Otherwise every five minutes; a FRITZ!Box every two, since its 32-bit line counters wrap at 4 GiB.
    public static let idle: TimeInterval = 300, idleFritz: TimeInterval = 120

    /// `directory` nil keeps everything in memory, as screenshot runs and tests need.
    public init(directory: URL?, secrets: RouterSecretStore) {
        folder = directory; self.secrets = secrets
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            book = StoredJSON.read(directory.appendingPathComponent(Self.bookFile)) ?? Book()
            ledger = StoredJSON.read(directory.appendingPathComponent(Self.ledgerFile)) ?? HomeUsageLedger()
        }
    }
    /// Kilobat's own folder and the Keychain; in a screenshot run (KILOBAT_SNAPSHOT) nothing is read or written.
    public convenience init() {
        if ProcessInfo.processInfo.environment["KILOBAT_SNAPSHOT"] != nil { self.init(directory: nil, secrets: MemoryRouterSecrets()); return }
        self.init(directory: Self.folder, secrets: KeychainRouterSecrets())
    }
    nonisolated static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat") }

    /// Read-only, for the CLI without the app: the connections and the daily totals.
    nonisolated public static func load(directory: URL? = nil) -> (book: Book, ledger: HomeUsageLedger) {
        let folder = directory ?? folder
        return (StoredJSON.read(folder.appendingPathComponent(bookFile)) ?? Book(), StoredJSON.read(folder.appendingPathComponent(ledgerFile)) ?? HomeUsageLedger())
    }
    /// The CLI's disconnect without the app: the connection goes from router.json; the app clears its Keychain item when it next starts.
    nonisolated public static func forget(network: String?, directory: URL? = nil) throws -> RouterConnection? {
        let url = (directory ?? folder).appendingPathComponent(bookFile)
        var book: Book = StoredJSON.read(url) ?? Book()
        let gone = network.map { key in book.routers.first { $0.network == key } } ?? book.routers.last
        guard let gone else { return nil }
        book.routers.removeAll { $0.id == gone.id }
        try JSONEncoder().encode(book).write(to: url, options: .atomic)
        return gone
    }

    // MARK: Connections

    public func connection(for network: String?) -> RouterConnection? { network.flatMap { key in book.routers.first { $0.network == key } } }
    /// The router of the network this Mac is on, when that network is home.
    public var current: RouterConnection? {
        guard let network = network(), network.home else { return nil }
        return connection(for: network.key)
    }

    /// Signs in and reads the router once; on success saves it for this network, and the secret in the Keychain.
    public func connect(_ draft: RouterDraft) async -> Outcome {
        guard allowed() else {
            return .failed(String(localized: "Reading your router is part of Kilobat Pro.", comment: "Router connection error"))
        }
        guard let network = network(), network.home else {
            return .failed(String(localized: "Mark this network as your home first. Kilobat reads a router only on your home network.", comment: "Router connection error"))
        }
        guard !draft.secret.isEmpty, !draft.kind.usesUser || draft.auth == .apiKey || !draft.user.isEmpty else {
            return .failed(String(localized: "Enter the router user and its password.", comment: "Router connection error"))
        }
        phase = .connecting
        do {
            var url = try RouterAddress.resolve(draft.entered, defaultScheme: draft.kind == .unifi || draft.kind == .mikrotik ? "https" : "http", loopback: loopback)
            if draft.kind == .fritzbox, url.scheme == "http" { url = await Self.fritzSecure(url, transport: transport(nil)) }
            var connection = RouterConnection(kind: draft.kind, network: network.key, networkName: network.name, url: url.absoluteString, entered: draft.entered,
                                              user: draft.kind.usesUser || draft.auth == .account ? draft.user : nil, auth: draft.auth, pin: url.scheme == "https" ? draft.pin : nil)
            let reader = try RouterReaders.make(connection, secret: draft.secret, transport: transport(connection.pin))
            if let unifi = reader as? UniFiConsole, let site = try await unifi.chosenSite() { connection.site = site.id.isEmpty ? nil : site.id; connection.siteName = site.reference }
            var poll = try await reader.poll()
            if poll.update == nil, let release = poll.release { poll.update = await openWrt(release, connection: connection) }
            guard allowed(), self.network()?.key == network.key, self.network()?.home == true else {
                phase = .idle
                return .failed(String(localized: "The home network changed while connecting. Connect the router again on its home network.", comment: "Router connection error"))
            }
            connection.model = poll.model; connection.firmware = poll.firmware
            guard secrets.set(draft.secret, for: connection.id) else {
                phase = .failed(String(localized: "Kilobat couldn’t save the password in the Keychain.", comment: "Router connection error"))
                return .failed(String(localized: "Kilobat couldn’t save the password in the Keychain.", comment: "Router connection error"))
            }
            // Save the replacement before retiring its predecessor, including a failed file write (for example a full disk).
            let previous = self.connection(for: network.key), previousBook = book
            book.routers.removeAll { $0.network == network.key }
            book.routers.append(connection)
            guard saveBook() else {
                book = previousBook
                secrets.remove(connection.id)
                let message = String(localized: "Kilobat couldn’t save the router connection. Check that this Mac has free disk space, then try again.", comment: "Router connection error")
                phase = .failed(message)
                return .failed(message)
            }
            if let previous { secrets.remove(previous.id) }
            self.reader = (connection.id, reader)
            meter = RouterMeter(); rates = [:]; line = nil
            ingest(poll, connection: connection)
            failures = 0; retryAfter = .distantPast
            return .connected
        } catch RouterAPIError.certificate(let fingerprint, let changed) {
            phase = .idle
            return .certificate(fingerprint: fingerprint, changed: changed)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message)
            return .failed(message)
        }
    }

    /// FRITZ! recommends TR-064 over HTTPS on the port GetSecurityPort names; plain HTTP only if the box offers none.
    static func fritzSecure(_ url: URL, transport: RouterTransport) async -> URL {
        let box = FritzBox(base: url, user: "", password: "", transport: transport)
        guard let port = try? await box.securityPort(), port > 0, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = "https"; parts.port = port
        return parts.url ?? url
    }

    public func disconnect(network: String? = nil) {
        guard let key = network ?? self.network()?.key, let connection = connection(for: key) else { return }
        var remaining = book
        remaining.routers.removeAll { $0.id == connection.id }
        guard saveBook(remaining) else { return }
        book = remaining
        secrets.remove(connection.id)
        if reader?.id == connection.id || phaseConnection == connection.id { reader = nil; clearMeasurements(); phaseConnection = nil; phase = .idle }
    }

    /// Keychain items whose router was disconnected from the CLI.
    public func pruneSecrets() {
        let live = Set(book.routers.map(\.id))
        for id in secrets.ids() where !live.contains(id) { secrets.remove(id) }
    }

    // MARK: Polling

    public func need(_ need: Need, _ on: Bool, consumer: UUID? = nil) {
        if let consumer {
            if on { consumerNeeds[need, default: []].insert(consumer) }
            else { consumerNeeds[need]?.remove(consumer) }
        } else if on { needs.insert(need) }
        else { needs.remove(need) }
        if on, lastPoll < Date().addingTimeInterval(-Self.fast) { Task { await tick() } }
    }

    public var interval: TimeInterval {
        if needs.contains(.call) || consumerNeeds[.call]?.isEmpty == false { return Self.call }
        if !needs.isEmpty || consumerNeeds.values.contains(where: { !$0.isEmpty }) { return Self.fast }
        return current?.kind == .fritzbox ? Self.idleFritz : Self.idle
    }

    public func start() {
        guard loop == nil else { return }
        pruneSecrets()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    public func stop() { loop?.cancel(); loop = nil; saveLedger(force: true) }

    func tick(now: Date = Date()) async {
        guard !previewing, allowed(), !sleeping(), !polling, let connection = current else { return }
        if reader?.id != connection.id { lastPoll = .distantPast; retryAfter = .distantPast; failures = 0 }
        guard now.timeIntervalSince(lastPoll) >= interval - 1, now >= retryAfter else { return }
        if case .needsAttention = phase, phaseConnection == connection.id { return }
        await poll(connection, now: now)
    }

    /// One read now, whatever the interval; the Devices tab's refresh.
    public func refresh() async { if allowed(), let connection = current { await poll(connection, now: Date()) } }

    private func poll(_ connection: RouterConnection, now: Date) async {
        guard !polling else { return }
        polling = true; defer { polling = false }
        phaseConnection = connection.id
        lastPoll = now
        do {
            let reader: RouterReader
            if let cached = self.reader, cached.id == connection.id { reader = cached.reader }
            else {
                clearMeasurements()
                phase = .connecting
                guard let secret = secrets.secret(for: connection.id) else {
                    phase = .needsAttention(String(localized: "The router’s password isn’t in the Keychain any more. Connect the router again.", comment: "Router status")); return
                }
                reader = try RouterReaders.make(connection, secret: secret, transport: transport(connection.pin))
                self.reader = (connection.id, reader)
            }
            var poll = try await reader.poll()
            guard allowed(), current?.id == connection.id else { return }
            failures = 0; retryAfter = .distantPast
            if poll.update == nil, let release = poll.release { poll.update = await openWrt(release, connection: connection) }
            guard allowed(), current?.id == connection.id else { return }
            ingest(poll, connection: connection)
        } catch let error as RouterAPIError {
            guard allowed(), current?.id == connection.id else { return }
            switch error {
            case .unauthorized, .certificate, .notLocal: phase = .needsAttention(error.errorDescription ?? "")
            default:
                failures += 1
                retryAfter = now.addingTimeInterval(min(900, 30 * pow(2, Double(min(failures, 5)))))
                phase = .failed(error.errorDescription ?? "")
            }
        } catch {
            guard allowed(), current?.id == connection.id else { return }
            failures += 1; retryAfter = now.addingTimeInterval(60); phase = .failed(error.localizedDescription)
        }
    }

    /// An OpenWrt release against OpenWrt's own list; only the project's own builds, never a vendor's fork.
    func openWrt(_ release: (distribution: String, version: String), connection: RouterConnection) async -> RouterFirmware? {
        guard release.distribution == "OpenWrt", OpenWrtReleases.number(release.version) != nil else { return nil }
        if knownReleases.map({ Date().timeIntervalSince($0.date) > 7 * 86_400 }) ?? true, let list = await releases() { knownReleases = (Date(), list) }
        guard let list = knownReleases?.releases else { return nil }
        let newer = list.newer(than: release.version)
        let flash = connection.base.flatMap { URL(string: "/cgi-bin/luci/admin/system/flash", relativeTo: $0)?.absoluteString }
        return RouterFirmware(product: "OpenWrt", installed: release.version, available: newer, updateAvailable: newer != nil, url: flash, source: "openwrt.org")
    }

    private var lastRouterUptime: TimeInterval?

    private func clearMeasurements() {
        lastRouterUptime = nil
        measuredConnection = nil; meter = RouterMeter(); latest = nil; rates = [:]; line = nil; firmware = nil
    }

    /// A poll's counters into rates and today's totals.
    public func ingest(_ poll: RouterPoll, connection: RouterConnection, calendar: Calendar = .current) {
        if measuredConnection != connection.id { clearMeasurements(); measuredConnection = connection.id }
        phaseConnection = connection.id
        if let uptime = poll.uptime {
            if let previous = lastRouterUptime, uptime < previous { meter = RouterMeter() }
            lastRouterUptime = uptime
        }
        var next: [String: HomeUsageMerge.Rate] = [:]
        for client in poll.clients {
            guard let mac = MACAddress.normalized(client.mac) else { continue }
            var rate: HomeUsageMerge.Rate?
            if let down = client.down, let up = client.up, let step = meter.step(mac, down: down, up: up, at: poll.date) {
                ledger.add(mac, down: step.down, up: step.up, at: poll.date, calendar: calendar, network: connection.network)
                rate = .init(down: step.downRate, up: step.upRate)
            }
            if let down = client.downRate, let up = client.upRate { rate = .init(down: down, up: up) }
            if poll.perDevice, let rate { next[mac] = rate }
        }
        rates = next
        var lineRate: HomeUsageMerge.Rate?
        if let wan = poll.wan {
            if let down = wan.down, let up = wan.up, let step = meter.step(HomeUsageLedger.home, down: down, up: up, at: poll.date, bits: wan.bits) {
                ledger.add(HomeUsageLedger.home, down: step.down, up: step.up, at: poll.date, calendar: calendar, network: connection.network)
                lineRate = .init(down: step.downRate, up: step.upRate)
            }
            if let down = wan.downRate, let up = wan.upRate { lineRate = .init(down: down, up: up) }
        }
        // Client counters may include LAN traffic, so their sum is never a substitute for WAN counters.
        line = lineRate
        latest = poll
        phase = .ok
        meter.prune(now: poll.date)
        if let uptime = poll.uptime { onUptime?(connection.network, uptime, poll.date) }
        firmware = poll.update
        if let update = poll.update { onFirmware?(connection.network, update) }
        if let index = book.routers.firstIndex(where: { $0.id == connection.id }), book.routers[index].model != poll.model || book.routers[index].firmware != poll.firmware {
            book.routers[index].model = poll.model; book.routers[index].firmware = poll.firmware; saveBook()
        }
        saveLedger()
    }

    // MARK: Reading

    /// Rates are worth showing until three polls have been missed.
    public var fresh: Bool { fresh(at: Date()) }
    private func fresh(at now: Date) -> Bool {
        guard current?.id == measuredConnection, let latest else { return false }
        return now.timeIntervalSince(latest.date) < max(45, 3 * interval)
    }

    public func report(now: Date = Date()) -> HomeUsageReport {
        let pro = allowed()
        let network = network()
        guard let network, let connection = connection(for: network.key) else {
            return HomeUsageReport(state: .notConnected, network: network?.name, note: HomeUsageReport.note(kind: nil, perDevice: false, missing: []), pro: pro)
        }
        let poll = measuredConnection == connection.id ? latest : nil
        let router = HomeUsageReport.Router(kind: connection.kind, name: connection.model ?? connection.kind.name, model: connection.model, firmware: connection.firmware,
                                            address: connection.base?.host ?? connection.url, measures: poll?.perDevice == true ? "perDevice" : "wholeHome",
                                            uptimeSeconds: poll?.uptime.map { $0 + now.timeIntervalSince(poll!.date) }, missing: poll?.missing ?? [], firmware: poll?.update)
        let note = HomeUsageReport.note(kind: connection.kind, perDevice: poll?.perDevice ?? false, missing: poll?.missing ?? [])
        guard network.home else { return HomeUsageReport(state: .notHome, network: network.name, router: router, note: note, pro: pro) }
        guard pro else { return HomeUsageReport(state: .needsPro, network: network.name, router: router, note: note, pro: pro) }
        let state: HomeUsageReport.State, error: String?
        switch phaseConnection == connection.id ? phase : .idle {
        case .needsAttention(let message): state = .needsAttention; error = message
        case .failed(let message): state = poll == nil ? .error : .ok; error = message
        case .connecting, .idle: state = poll == nil ? .connecting : .ok; error = nil
        case .ok: state = .ok; error = nil
        }
        guard let poll else { return HomeUsageReport(state: state, network: network.name, router: router, error: error, note: note, pro: pro) }
        let live = fresh(at: now)
        let today = ledger.today(now: now, network: connection.network)
        let devices = HomeUsageMerge.devices(clients: poll.clients, rates: live ? rates : [:], today: today, known: known(network.key), peers: peers(),
                                             thisMac: thisMac(), perDevice: poll.perDevice, now: now)
        let total = today[HomeUsageLedger.home]
        let home = HomeUsageReport.Line(down: live ? line?.down : nil, up: live ? line?.up : nil, todayDown: total?.down, todayUp: total?.up)
        return HomeUsageReport(state: state, network: network.name, router: router, updated: poll.date, error: error, home: home, devices: devices,
                               others: poll.perDevice ? nil : HomeUsageMerge.others(home: home, devices: devices), note: note, pro: pro)
    }

    /// For call reports: each device's rate as the router last measured it, with its name; nil without per-device counters.
    public func deviceRates() -> (date: Date, devices: [(mac: String, address: String?, name: String?, down: Double, up: Double)])? {
        guard allowed(), let poll = latest, poll.perDevice, fresh, let network = network(), network.home else { return nil }
        let known = known(network.key), me = thisMac()
        let rows = poll.clients.compactMap { client -> (String, String?, String?, Double, Double)? in
            guard let mac = MACAddress.normalized(client.mac), let rate = rates[mac] else { return nil }
            // This Mac's own traffic, the call's included, is never another device's.
            if let me, me.mac.flatMap(MACAddress.normalized) == mac || (me.address != nil && me.address == client.address) { return nil }
            let device = known?.index(of: mac).map { known!.devices[$0] }
            let name = device?.name.flatMap { $0.isEmpty ? nil : $0 } ?? DeviceNames.readable(device?.hostname) ?? DeviceNames.readable(client.name) ?? device?.callName
            return (mac, client.address, name, rate.down, rate.up)
        }
        return (poll.date, rows.map { (mac: $0.0, address: $0.1, name: $0.2, down: $0.3, up: $0.4) })
    }

    /// The whole line now, for call reports on routers without UPnP.
    public func lineRate() -> (date: Date, down: Double, up: Double)? {
        guard allowed(), let poll = latest, fresh, let line else { return nil }
        return (poll.date, line.down, line.up)
    }

    // MARK: Detection

    /// Looks once a day per network for a router Kilobat can read, from its maker and its ports.
    public func detect(gateway: String?, vendor: String?) {
        // Screenshot runs never probe this Mac's router.
        guard !previewing, ProcessInfo.processInfo.environment["KILOBAT_SNAPSHOT"] == nil else { return }
        guard let network = network(), network.home, connection(for: network.key) == nil, let gateway, !detecting.contains(network.key), detected[network.key] == nil else { return }
        detecting.insert(network.key)
        Task {
            let found = await RouterDetect.detect(gateway: gateway, vendor: vendor)
            detecting.remove(network.key)
            if let found { detected[network.key] = found; onDetected?(network.key, found.kind) }
        }
    }

    // MARK: Files

    @discardableResult private func saveBook(_ candidate: Book? = nil) -> Bool {
        guard let folder else { return true }
        do {
            let url = folder.appendingPathComponent(Self.bookFile)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(candidate ?? book).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            persistenceError = nil
            return true
        } catch { persistenceError = error.localizedDescription; return false }
    }

    private func saveLedger(force: Bool = false) {
        let now = Date()
        guard let folder, force || now.timeIntervalSince(lastSave) >= 60 else { return }
        lastSave = now
        ledger.prune(now: now)
        let url = folder.appendingPathComponent(Self.ledgerFile)
        try? JSONEncoder().encode(ledger).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    #if DEBUG
    /// A made-up router for screenshots; debug builds only. Nothing is read, sent or saved.
    public func preview(_ connection: RouterConnection, polls: [RouterPoll], today: [String: HomeUsageLedger.Total] = [:], detected found: RouterDetect.Found? = nil) {
        previewing = true
        book.routers = [connection]
        if let found { detected[connection.network] = found }
        for poll in polls { ingest(poll, connection: connection) }
        for (key, total) in today { ledger.add(key, down: total.down, up: total.up, at: Date(), network: connection.network) }
    }
    public func previewDetected(_ network: String, _ found: RouterDetect.Found) { previewing = true; book.routers = []; detected[network] = found }
    @ObservationIgnored private var previewing = false
    #else
    private let previewing = false
    #endif
}
