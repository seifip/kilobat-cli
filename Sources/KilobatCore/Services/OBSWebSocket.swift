import CryptoKit
import Foundation
import Network
import Security

/// obs-websocket v5, the server built into OBS Studio 28 and later (Tools › WebSocket Server Settings): the messages
/// Kilobat sends and reads, without a connection, so they can be tested against the protocol's own rules.
public enum OBSProtocol {
    public static let defaultPort: UInt16 = 4455
    public static let rpcVersion = 1
    /// Outputs (1 << 6): StreamStateChanged and the other output events, and nothing high-volume.
    public static let outputEvents = 1 << 6

    /// The Identify answer to a Hello that asks for a password: base64(sha256(base64(sha256(password + salt)) + challenge)).
    public static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    public enum Message: Equatable, Sendable {
        /// op 0. `challenge` and `salt` are there when the server has a password.
        case hello(rpcVersion: Int, version: String?, challenge: String?, salt: String?)
        /// op 2.
        case identified(rpcVersion: Int)
        /// op 5.
        case event(type: String, data: JSONValue)
        /// op 7.
        case response(type: String, id: String, ok: Bool, code: Int, comment: String?, data: JSONValue)
        /// Anything else, ignored.
        case other(op: Int)
    }

    public static func parse(_ data: Data) -> Message? {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: data), let op = object["op"]?.int, let d = object["d"] else { return nil }
        switch op {
        case 0:
            let auth = d["authentication"]
            return .hello(rpcVersion: d["rpcVersion"]?.int ?? rpcVersion, version: d["obsWebSocketVersion"]?.string,
                          challenge: auth?["challenge"]?.string, salt: auth?["salt"]?.string)
        case 2: return .identified(rpcVersion: d["negotiatedRpcVersion"]?.int ?? rpcVersion)
        case 5:
            guard let type = d["eventType"]?.string else { return nil }
            return .event(type: type, data: d["eventData"] ?? .object([:]))
        case 7:
            guard let type = d["requestType"]?.string, let id = d["requestId"]?.string else { return nil }
            let status = d["requestStatus"]
            return .response(type: type, id: id, ok: status?["result"]?.bool ?? false, code: status?["code"]?.int ?? 0,
                             comment: status?["comment"]?.string, data: d["responseData"] ?? .object([:]))
        default: return .other(op: op)
        }
    }

    /// op 1, with the password's answer when the Hello asked for one.
    public static func identify(authentication: String?, subscriptions: Int = outputEvents) -> Data {
        var d: [String: JSONValue] = ["rpcVersion": .number(Double(rpcVersion)), "eventSubscriptions": .number(Double(subscriptions))]
        if let authentication { d["authentication"] = .string(authentication) }
        return encode(.object(["op": .number(1), "d": .object(d)]))
    }

    /// op 6.
    public static func request(_ type: String, id: String, data: [String: JSONValue]? = nil) -> Data {
        var d: [String: JSONValue] = ["requestType": .string(type), "requestId": .string(id)]
        if let data { d["requestData"] = .object(data) }
        return encode(.object(["op": .number(6), "d": .object(d)]))
    }

    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    /// The close codes that mean something to the person: a wrong password, or an OBS too old or too new.
    public static let authenticationFailed = 4009, unsupportedRPCVersion = 4010
}

/// A JSON value, for obs-websocket's loosely typed messages.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    public subscript(key: String) -> JSONValue? { if case .object(let object) = self { object[key] } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value) = self { value } else { nil } }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}

/// GetStreamStatus: the stream output's own counters. `skippedFrames` is OBS's "Dropped Frames (Network)":
/// obs-websocket fills it from obs_output_get_frames_dropped, frames the output threw away because the
/// connection couldn't take them.
public struct OBSStreamStatus: Codable, Sendable, Equatable {
    public var active: Bool
    public var reconnecting: Bool
    /// Milliseconds since the stream started.
    public var duration: Double
    /// 0 to 1: how full the output's send buffer is.
    public var congestion: Double
    public var bytes: Double
    public var skippedFrames: Int
    public var totalFrames: Int
    public init(active: Bool, reconnecting: Bool = false, duration: Double = 0, congestion: Double = 0, bytes: Double = 0, skippedFrames: Int = 0, totalFrames: Int = 0) {
        self.active = active; self.reconnecting = reconnecting; self.duration = duration; self.congestion = congestion
        self.bytes = bytes; self.skippedFrames = skippedFrames; self.totalFrames = totalFrames
    }
    public init?(_ data: JSONValue) {
        guard let active = data["outputActive"]?.bool else { return nil }
        self.init(active: active, reconnecting: data["outputReconnecting"]?.bool ?? false, duration: data["outputDuration"]?.double ?? 0,
                  congestion: data["outputCongestion"]?.double ?? 0, bytes: data["outputBytes"]?.double ?? 0,
                  skippedFrames: data["outputSkippedFrames"]?.int ?? 0, totalFrames: data["outputTotalFrames"]?.int ?? 0)
    }
}

/// GetStats: OBS's own side. `renderSkipped` is "frames missed due to rendering lag" (obs_get_lagged_frames), the
/// GPU not finishing a frame in time; `encoderSkipped` is "skipped frames due to encoding lag"
/// (video_output_get_skipped_frames), the encoder falling behind. Neither is the network.
public struct OBSStats: Codable, Sendable, Equatable {
    public var cpuUsage: Double?
    public var activeFps: Double?
    /// Milliseconds to render a frame, on average.
    public var averageFrameRenderTime: Double?
    public var renderSkipped: Int
    public var renderTotal: Int
    public var encoderSkipped: Int
    public var encoderTotal: Int
    public init(cpuUsage: Double? = nil, activeFps: Double? = nil, averageFrameRenderTime: Double? = nil, renderSkipped: Int = 0, renderTotal: Int = 0, encoderSkipped: Int = 0, encoderTotal: Int = 0) {
        self.cpuUsage = cpuUsage; self.activeFps = activeFps; self.averageFrameRenderTime = averageFrameRenderTime
        self.renderSkipped = renderSkipped; self.renderTotal = renderTotal; self.encoderSkipped = encoderSkipped; self.encoderTotal = encoderTotal
    }
    public init?(_ data: JSONValue) {
        guard data["renderTotalFrames"] != nil || data["outputTotalFrames"] != nil else { return nil }
        self.init(cpuUsage: data["cpuUsage"]?.double, activeFps: data["activeFps"]?.double, averageFrameRenderTime: data["averageFrameRenderTime"]?.double,
                  renderSkipped: data["renderSkippedFrames"]?.int ?? 0, renderTotal: data["renderTotalFrames"]?.int ?? 0,
                  encoderSkipped: data["outputSkippedFrames"]?.int ?? 0, encoderTotal: data["outputTotalFrames"]?.int ?? 0)
    }
}

/// Where OBS keeps the stream's bitrate. Simple output mode has it as a profile parameter; Advanced keeps the stream
/// encoder's settings in the profile folder's streamEncoder.json, which obs-websocket doesn't expose.
public enum OBSBitrate {
    /// OBS's own defaults, for a profile that never changed them.
    public static let simpleVideoDefault = 2500, audioDefault = 160

    /// Video plus audio in kbps, or nil when it can't be told (a CRF or CQP encoder in Advanced mode has no bitrate).
    public static func kbps(mode: String?, simpleVideo: String?, simpleAudio: String?, encoder: Data?, advancedAudio: String?) -> Int? {
        if mode?.lowercased() == "advanced" {
            guard let encoder, let settings = try? JSONDecoder().decode(JSONValue.self, from: encoder) else { return nil }
            if let control = settings["rate_control"]?.string?.uppercased(), ["CRF", "CQP", "CQ", "ICQ", "LOSSLESS"].contains(control) { return nil }
            guard let video = settings["bitrate"]?.int ?? settings["max_bitrate"]?.int, video > 0 else { return nil }
            return video + (advancedAudio.flatMap(Int.init) ?? audioDefault)
        }
        let video = simpleVideo.flatMap(Int.init) ?? simpleVideoDefault
        return video + (simpleAudio.flatMap(Int.init) ?? audioDefault)
    }

    /// The profile's folder: its name, or the folder whose basic.ini names it.
    public static func profileFolder(named name: String, root: URL = profilesRoot) -> URL? {
        let direct = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.appendingPathComponent("basic.ini").path) { return direct }
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let ini = try? String(contentsOf: folder.appendingPathComponent("basic.ini"), encoding: .utf8) else { continue }
            if ini.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Name=\(name)" }) { return root.appendingPathComponent(folder.lastPathComponent) }
        }
        return nil
    }
    public static var profilesRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("obs-studio/basic/profiles")
    }
}

public struct OBSError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable { case notRunning, passwordNeeded, wrongPassword, unsupported, timeout, closed, failed }
    public let kind: Kind
    public var detail: String? = nil
    public init(_ kind: Kind, detail: String? = nil) { self.kind = kind; self.detail = detail }
    /// What to tell the person, and what to do about it.
    public var message: String {
        switch kind {
        case .notRunning: String(localized: "OBS isn’t answering on this port. Open OBS and turn on Tools › WebSocket Server Settings › Enable WebSocket server.", comment: "OBS connection error")
        case .passwordNeeded: String(localized: "OBS asks for a password. Copy it from OBS › Tools › WebSocket Server Settings › Show Connect Info.", comment: "OBS connection error")
        case .wrongPassword: String(localized: "OBS turned down the password. Copy it again from OBS › Tools › WebSocket Server Settings › Show Connect Info.", comment: "OBS connection error")
        case .unsupported: String(localized: "This OBS speaks an older WebSocket protocol. Kilobat needs OBS 28 or later.", comment: "OBS connection error")
        case .timeout: String(localized: "OBS didn’t answer in time. Is something else using this port?", comment: "OBS connection error")
        case .closed: String(localized: "OBS closed the connection.", comment: "OBS connection error")
        case .failed: detail.map { String(localized: "OBS said: \($0)", comment: "OBS connection error; the argument is OBS's own message") } ?? String(localized: "OBS couldn’t answer.", comment: "OBS connection error")
        }
    }
}

/// One WebSocket over Network.framework: text messages in and out, and the close code the other side gave.
final class WebSocketLink: @unchecked Sendable {
    struct Closed: Error { let code: Int? }
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "co.seifi.kilobat.obs")

    init(url: URL) {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    private func operation<Value: Sendable>(_ begin: (SocketCompletion<Value>) -> Void) async throws -> Value {
        let completion = SocketCompletion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if completion.install(continuation) { begin(completion) }
            }
        } onCancel: { [self] in
            completion.finish(.failure(CancellationError()))
            close()
        }
    }

    /// Waits for the handshake; a refused port fails at once instead of waiting for the network to change.
    func open() async throws {
        try await operation { (completion: SocketCompletion<Void>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(.success(()))
                case .failed(let error), .waiting(let error): completion.finish(.failure(error))
                case .cancelled: completion.finish(.failure(Closed(code: nil)))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await operation { (completion: SocketCompletion<Void>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { completion.finish(.failure(error)) } else { completion.finish(.success(())) }
            })
        }
    }

    /// The next text or binary message. Throws `Closed` with the close code when the other side hangs up.
    func receive() async throws -> Data {
        try await operation { (completion: SocketCompletion<Data>) in
            connection.receiveMessage { content, context, _, error in
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if let metadata, metadata.opcode == .close { completion.finish(.failure(Closed(code: Self.code(metadata.closeCode)))); return }
                if let error { completion.finish(.failure(error)); return }
                guard let content else { completion.finish(.failure(Closed(code: nil))); return }
                completion.finish(.success(content))
            }
        }
    }

    func close() { connection.cancel() }

    static func code(_ code: NWProtocolWebSocket.CloseCode) -> Int {
        switch code {
        case .protocolCode(let value): Int(value.rawValue)
        case .applicationCode(let value): Int(value)
        case .privateCode(let value): Int(value)
        @unknown default: 0
        }
    }

}

/// A connection to OBS's WebSocket server on this Mac: the handshake, requests by ID, and StreamStateChanged.
public actor OBSClient {
    public nonisolated let port: UInt16
    private let password: String?
    private var link: WebSocketLink?
    private var waiting: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var counter = 0
    private var reader: Task<Void, Never>?
    public private(set) var version: String?
    public private(set) var connected = false
    /// Called with each StreamStateChanged: whether the stream output is active.
    private var onStreamState: (@Sendable (Bool) -> Void)?
    private var onClose: (@Sendable () -> Void)?

    public init(port: UInt16 = OBSProtocol.defaultPort, password: String?) {
        self.port = port; self.password = password?.isEmpty == true ? nil : password
    }

    public func observe(streamState: @escaping @Sendable (Bool) -> Void, closed: @escaping @Sendable () -> Void) {
        onStreamState = streamState; onClose = closed
    }

    /// Connects and identifies. Throws an `OBSError` that says what to fix.
    public func connect(timeout: Duration = .seconds(4)) async throws {
        guard self.link == nil else { return }
        let link = WebSocketLink(url: URL(string: "ws://127.0.0.1:\(port)")!)
        self.link = link
        do {
            try await within(timeout) {
                do { try await link.open() } catch { throw OBSError(.notRunning) }
                try await self.handshake(link)
            }
        } catch {
            link.close()
            if self.link === link { self.link = nil }
            if let closed = error as? WebSocketLink.Closed {
                if closed.code == OBSProtocol.authenticationFailed { throw OBSError(.wrongPassword) }
                if closed.code == OBSProtocol.unsupportedRPCVersion { throw OBSError(.unsupported) }
                throw OBSError(.closed)
            }
            if let error = error as? OBSError { throw error }
            if error is CancellationError { throw OBSError(.timeout) }
            throw OBSError(.notRunning)
        }
        guard self.link === link, !Task.isCancelled else { link.close(); throw OBSError(.closed) }
        connected = true
        reader = Task { await self.read(link) }
    }

    private func handshake(_ link: WebSocketLink) async throws {
        guard case .hello(let rpc, let version, let challenge, let salt)? = OBSProtocol.parse(try await link.receive()) else { throw OBSError(.unsupported) }
        guard rpc >= OBSProtocol.rpcVersion else { throw OBSError(.unsupported) }
        self.version = version
        var authentication: String?
        if let challenge, let salt {
            guard let password else { throw OBSError(.passwordNeeded) }
            authentication = OBSProtocol.authentication(password: password, salt: salt, challenge: challenge)
        }
        try await link.send(OBSProtocol.identify(authentication: authentication))
        guard case .identified? = OBSProtocol.parse(try await link.receive()) else { throw OBSError(.unsupported) }
    }

    private func read(_ link: WebSocketLink) async {
        while !Task.isCancelled, let data = try? await link.receive() {
            switch OBSProtocol.parse(data) {
            case .response(_, let id, let ok, let code, let comment, let data)?:
                guard let continuation = waiting.removeValue(forKey: id) else { continue }
                if ok { continuation.resume(returning: data) } else { continuation.resume(throwing: OBSError(.failed, detail: comment ?? "code \(code)")) }
            case .event(let type, let data)? where type == "StreamStateChanged":
                if let active = data["outputActive"]?.bool { onStreamState?(active) }
            default: continue
            }
        }
        if self.link === link { closeDown() }
    }

    private func closeDown() {
        guard connected || link != nil else { return }
        connected = false; link?.close(); link = nil
        for continuation in waiting.values { continuation.resume(throwing: OBSError(.closed)) }
        waiting = [:]
        onClose?()
    }

    /// One request and its response data.
    public func request(_ type: String, _ data: [String: JSONValue]? = nil, timeout: Duration = .seconds(3)) async throws -> JSONValue {
        guard connected, let link else { throw OBSError(.closed) }
        counter += 1
        let id = "kilobat-\(counter)"
        let message = OBSProtocol.request(type, id: id, data: data)
        let timer = Task { try? await Task.sleep(for: timeout); self.fail(id, OBSError(.timeout)) }
        defer { timer.cancel() }
        // Waiting before sending, so a reply that comes back at once still finds its request.
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            Task { do { try await link.send(message) } catch { self.fail(id, OBSError(.closed)) } }
        }
    }

    private func fail(_ id: String, _ error: OBSError) { waiting.removeValue(forKey: id)?.resume(throwing: error) }

    public func streamStatus() async throws -> OBSStreamStatus {
        guard let status = OBSStreamStatus(try await request("GetStreamStatus")) else { throw OBSError(.failed, detail: "GetStreamStatus") }
        return status
    }

    public func stats() async throws -> OBSStats {
        guard let stats = OBSStats(try await request("GetStats")) else { throw OBSError(.failed, detail: "GetStats") }
        return stats
    }

    /// The stream's bitrate in kbps, video plus audio, from the current profile; nil when OBS doesn't say.
    public func bitrate(profiles: URL = OBSBitrate.profilesRoot) async -> Int? {
        func parameter(_ category: String, _ name: String) async -> String? {
            let value = try? await request("GetProfileParameter", ["parameterCategory": .string(category), "parameterName": .string(name)])
            return value?["parameterValue"]?.string ?? value?["defaultParameterValue"]?.string
        }
        let mode = await parameter("Output", "Mode")
        if mode?.lowercased() == "advanced" {
            let profile = (try? await request("GetProfileList"))?["currentProfileName"]?.string
            let encoder = profile.flatMap { OBSBitrate.profileFolder(named: $0, root: profiles) }.flatMap { try? Data(contentsOf: $0.appendingPathComponent("streamEncoder.json")) }
            let track = await parameter("AdvOut", "TrackIndex") ?? "1"
            return OBSBitrate.kbps(mode: mode, simpleVideo: nil, simpleAudio: nil, encoder: encoder, advancedAudio: await parameter("AdvOut", "Track\(track)Bitrate"))
        }
        return OBSBitrate.kbps(mode: mode, simpleVideo: await parameter("SimpleOutput", "VBitrate"), simpleAudio: await parameter("SimpleOutput", "ABitrate"), encoder: nil, advancedAudio: nil)
    }

    public func disconnect() {
        reader?.cancel(); reader = nil
        onStreamState = nil; onClose = nil
        closeDown()
    }

    private func within(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: timeout); throw CancellationError() }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

/// The OBS WebSocket password, in the login Keychain on this Mac only, never synced.
public enum OBSPassword {
    static let service = "co.seifi.kilobat.obs-websocket"
    private static func query(_ port: UInt16) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "127.0.0.1:\(port)", kSecAttrSynchronizable as String: false]
    }
    public static func read(port: UInt16) -> String? {
        var query = query(port); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Saves it, or removes it when empty.
    @discardableResult public static func save(_ password: String?, port: UInt16) -> Bool {
        SecItemDelete(query(port) as CFDictionary)
        guard let password, !password.isEmpty else { return true }
        var insert = query(port)
        insert[kSecValueData as String] = Data(password.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecAttrLabel as String] = "Kilobat: OBS WebSocket password"
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}
