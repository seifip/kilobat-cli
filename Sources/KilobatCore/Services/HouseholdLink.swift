import Foundation
import Network

/// The household's transport: Bonjour (`_kilobat._tcp`) to find Kilobat Macs on the local network, and one short TCP
/// connection per request or pairing, carrying `HouseholdWire` frames. Local network only; nothing goes through a server.

public enum HouseholdLinkError: Error, Equatable, Sendable {
    /// macOS's Local Network permission is off for Kilobat.
    case localNetworkDenied
    case timeout
    case closed
    case failed(String)
}

/// What macOS lets Kilobat do on the local network, as the browser, the listener and connections report it.
public enum LocalNetworkAccess: String, Sendable, Codable { case unknown, allowed, denied }

/// A Kilobat Mac found on the network.
public struct HouseholdNearby: Identifiable, Sendable, Equatable {
    public var id: String
    /// Its name, shown only while it is open to pairing.
    public var name: String?
    public var pairing: Bool
    public var endpoint: NWEndpoint
    public init(id: String, name: String?, pairing: Bool, endpoint: NWEndpoint) { self.id = id; self.name = name; self.pairing = pairing; self.endpoint = endpoint }
}

public enum HouseholdLink {
    /// DNSServiceErrorType kDNSServiceErr_PolicyDenied: macOS refused Bonjour for lack of Local Network permission.
    static let policyDenied: Int32 = -65570

    static func denied(_ error: NWError?, path: NWPath? = nil) -> Bool {
        if path?.unsatisfiedReason == .localNetworkDenied { return true }
        if case .dns(let code)? = error, code == policyDenied { return true }
        return false
    }

    /// Addresses a household peer can have: private IPv4, link-local, loopback, and IPv6 link-local or unique local.
    /// A connection from anywhere else is closed before it is read.
    public static func local(_ host: String) -> Bool {
        var text = host.lowercased()
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if text.hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        let parts = text.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4, text.split(separator: ".").count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        guard text.contains(":") else { return false }
        if text == "::1" { return true }
        let first = text.split(separator: ":", omittingEmptySubsequences: false).first.flatMap { UInt16($0, radix: 16) } ?? 0
        return first & 0xffc0 == 0xfe80 || first & 0xfe00 == 0xfc00
    }

    static func host(of endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.connectionTimeout = 4; tcp.noDelay = true }
        return parameters
    }

    /// Runs `work`, giving up after `seconds`.
    static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw HouseholdLinkError.timeout }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw HouseholdLinkError.timeout }
            return result
        }
    }
}

/// A cancellation can arrive before the callback is registered, and the callback can
/// still arrive after cancellation. Complete the awaiting task once in either case.
final class SocketCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let prior = lock.withLock {
            if result == nil { self.continuation = continuation }
            return result
        }
        if let prior { continuation.resume(with: prior); return false }
        return true
    }

    func finish(_ result: Result<Value, Error>) {
        let waiting = lock.withLock {
            guard self.result == nil else { return nil as CheckedContinuation<Value, Error>? }
            self.result = result
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }
}

/// One TCP connection that sends and receives whole messages.
public final class HouseholdConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "co.seifi.kilobat.household.connection")
    private let lock = NSLock()
    private var buffer = Data()

    init(_ connection: NWConnection) { self.connection = connection }

    /// Connects to a Mac the browser found, or to an address and port.
    public static func connect(to endpoint: NWEndpoint, timeout: TimeInterval = 4) async throws -> HouseholdConnection {
        let link = HouseholdConnection(NWConnection(to: endpoint, using: HouseholdLink.parameters()))
        do { try await HouseholdLink.within(timeout) { try await link.start() } }
        catch { link.cancel(); throw error }
        return link
    }

    /// The other Mac's address once connected, for matching it with a device on the network.
    public var remoteAddress: String? { HouseholdLink.host(of: connection.currentPath?.remoteEndpoint ?? connection.endpoint) }

    private func operation<Value: Sendable>(
        _ begin: (SocketCompletion<Value>) -> Void
    ) async throws -> Value {
        let completion = SocketCompletion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if completion.install(continuation) { begin(completion) }
            }
        } onCancel: { [self] in
            completion.finish(.failure(CancellationError()))
            cancel()
        }
    }

    func start() async throws {
        try await operation { (completion: SocketCompletion<Void>) in
            let connection = connection
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready: completion.finish(.success(()))
                case .waiting(let error), .failed(let error):
                    let denied = HouseholdLink.denied(error, path: connection?.currentPath)
                    completion.finish(.failure(denied ? HouseholdLinkError.localNetworkDenied : HouseholdLinkError.failed(error.localizedDescription)))
                case .cancelled: completion.finish(.failure(HouseholdLinkError.closed))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ message: HouseholdMessage, timeout: TimeInterval = 5) async throws {
        let data = try HouseholdWire.frame(message)
        try await HouseholdLink.within(timeout) { [self] in
            try await operation { (completion: SocketCompletion<Void>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { completion.finish(.failure(HouseholdLinkError.failed(error.localizedDescription))) }
                    else { completion.finish(.success(())) }
                })
            }
        }
    }

    /// The next whole message; throws when the other side closes, sends something that isn't a message, or takes too long.
    public func receive(timeout: TimeInterval = 5) async throws -> HouseholdMessage {
        try await HouseholdLink.within(timeout) { [self] in
            while true {
                if let message = try lock.withLock({ try HouseholdWire.unframe(&buffer) }) { return message }
                let (data, complete) = try await chunk()
                if let data, !data.isEmpty { lock.withLock { buffer += data } }
                else if complete { throw HouseholdLinkError.closed }
                if lock.withLock({ buffer.count }) > 4 + HouseholdWire.maxFrame { throw HouseholdWire.Malformed(reason: "too large") }
            }
        }
    }

    private func chunk() async throws -> (Data?, Bool) {
        try await operation { completion in
            connection.receive(minimumIncompleteLength: 1, maximumLength: HouseholdWire.maxFrame + 4) { data, _, complete, error in
                if let error { completion.finish(.failure(HouseholdLinkError.failed(error.localizedDescription))) }
                else { completion.finish(.success((data, complete))) }
            }
        }
    }

    public func cancel() { connection.cancel() }
}

/// Listens for paired Macs' requests and for pairing, advertised over Bonjour by this Mac's random identity, so a
/// device browsing the network learns only that a Kilobat Mac is here; its name is in the record only while it is open to pairing.
public final class HouseholdServer: @unchecked Sendable {
    public static let maxConnections = 8
    private let queue = DispatchQueue(label: "co.seifi.kilobat.household.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var active = 0
    private let onConnection: @Sendable (HouseholdConnection) -> Void
    private let onState: @Sendable (LocalNetworkAccess) -> Void

    public init(onConnection: @escaping @Sendable (HouseholdConnection) -> Void, onState: @escaping @Sendable (LocalNetworkAccess) -> Void = { _ in }) {
        self.onConnection = onConnection; self.onState = onState
    }

    public var running: Bool { lock.withLock { listener != nil } }
    public var port: UInt16? { lock.withLock { listener?.port?.rawValue } }

    /// Starts listening, advertised as `name` with `txt` unless `loopback`, which listens on 127.0.0.1 only (tests).
    public func start(name: String, txt: [String: String], loopback: Bool = false) throws {
        guard lock.withLock({ listener == nil }) else { return }
        let parameters = HouseholdLink.parameters()
        if loopback { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let listener = try NWListener(using: parameters)
        if !loopback { listener.service = NWListener.Service(name: name, type: HouseholdWire.service, txtRecord: NWTXTRecord(txt)) }
        listener.stateUpdateHandler = { [onState] state in
            switch state {
            case .ready: onState(.allowed)
            case .waiting(let error), .failed(let error): if HouseholdLink.denied(error) { onState(.denied) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        lock.withLock { self.listener = listener }
    }

    /// Changes the Bonjour record, as when pairing opens or closes.
    public func advertise(name: String, txt: [String: String]) {
        lock.withLock { listener?.service = NWListener.Service(name: name, type: HouseholdWire.service, txtRecord: NWTXTRecord(txt)) }
    }

    /// Waits until the listener has a port, for the loopback tests.
    public func ready(timeout: TimeInterval = 3) async -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port, port != 0 { return port }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    public func stop() {
        lock.withLock { listener?.cancel(); listener = nil }
    }

    private func accept(_ connection: NWConnection) {
        let local = HouseholdLink.host(of: connection.endpoint).map(HouseholdLink.local) ?? false
        let admitted = lock.withLock { () -> Bool in
            guard local, active < Self.maxConnections else { return false }
            active += 1; return true
        }
        guard admitted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.lock.withLock { self?.active -= 1 }; connection.stateUpdateHandler = nil
            default: break
            }
        }
        connection.start(queue: queue)
        onConnection(HouseholdConnection(connection))
    }
}

/// Finds Kilobat Macs on the local network.
public final class HouseholdBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "co.seifi.kilobat.household.browser")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private let onResults: @Sendable ([HouseholdNearby]) -> Void
    private let onState: @Sendable (LocalNetworkAccess) -> Void

    public init(onResults: @escaping @Sendable ([HouseholdNearby]) -> Void, onState: @escaping @Sendable (LocalNetworkAccess) -> Void = { _ in }) {
        self.onResults = onResults; self.onState = onState
    }

    public var running: Bool { lock.withLock { browser != nil } }

    public func start() {
        guard lock.withLock({ browser == nil }) else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: HouseholdWire.service, domain: "local."), using: parameters)
        browser.stateUpdateHandler = { [onState] state in
            switch state {
            case .ready: onState(.allowed)
            case .waiting(let error), .failed(let error): if HouseholdLink.denied(error) { onState(.denied) }
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [onResults] results, _ in
            onResults(results.compactMap(Self.nearby))
        }
        browser.start(queue: queue)
        lock.withLock { self.browser = browser }
    }

    public func stop() { lock.withLock { browser?.cancel(); browser = nil } }

    static func nearby(_ result: NWBrowser.Result) -> HouseholdNearby? {
        guard case .bonjour(let txt) = result.metadata, let id = txt["id"], HouseholdBook.validID(id) else { return nil }
        let pairing = txt["p"] == "1"
        let name = pairing ? txt["n"].map(HouseholdNames.clean).flatMap { $0.isEmpty ? nil : $0 } : nil
        return HouseholdNearby(id: id, name: name, pairing: pairing, endpoint: result.endpoint)
    }
}
