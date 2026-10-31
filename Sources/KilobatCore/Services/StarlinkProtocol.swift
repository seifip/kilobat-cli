import Foundation
import Network

/// Just enough Protocol Buffers for the dish: a reader that keeps every field it sees, by number, and a writer for the
/// one-field requests Kilobat sends. Field numbers come from the published, reflection-dumped `SpaceX.API.Device`
/// protos (see RESEARCH-DECISIONS.md). Unknown fields are skipped, and a missing field is nil, never a guess: when a
/// firmware renames or drops something, that line of the Starlink panel just doesn't show.
struct ProtoMessage: Sendable {
    enum Value: Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }
    private(set) var fields: [Int: [Value]] = [:]

    init() {}

    /// Nil for bytes that aren't a well-formed message.
    init?(_ data: Data) { self.init(Array(data)) }
    init?(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count {
            guard let key = Self.varint(bytes, &index) else { return nil }
            let number = Int(key >> 3), wire = key & 7
            guard number > 0 else { return nil }
            switch wire {
            case 0:
                guard let value = Self.varint(bytes, &index) else { return nil }
                fields[number, default: []].append(.varint(value))
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                var value: UInt64 = 0
                for offset in 0..<8 { value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset)) }
                index += 8
                fields[number, default: []].append(.fixed64(value))
            case 2:
                guard let length = Self.varint(bytes, &index), length <= UInt64(bytes.count - index) else { return nil }
                fields[number, default: []].append(.bytes(Array(bytes[index..<index + Int(length)])))
                index += Int(length)
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                var value: UInt32 = 0
                for offset in 0..<4 { value |= UInt32(bytes[index + offset]) << (8 * UInt32(offset)) }
                index += 4
                fields[number, default: []].append(.fixed32(value))
            default: return nil
            }
        }
    }

    static func varint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]; index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    // MARK: Reading, with proto3's rule that an absent scalar is unknown here rather than zero

    func has(_ number: Int) -> Bool { fields[number] != nil }
    func uint(_ number: Int) -> UInt64? {
        guard case .varint(let value)? = fields[number]?.last else { return nil }
        return value
    }
    /// int32, int64 and enums, which put negatives in ten-byte two's complement.
    func int(_ number: Int) -> Int64? { uint(number).map { Int64(bitPattern: $0) } }
    func bool(_ number: Int) -> Bool? { uint(number).map { $0 != 0 } }
    func float(_ number: Int) -> Float? {
        guard case .fixed32(let bits)? = fields[number]?.last else { return nil }
        return Float(bitPattern: bits)
    }
    func double(_ number: Int) -> Double? {
        guard case .fixed64(let bits)? = fields[number]?.last else { return nil }
        return Double(bitPattern: bits)
    }
    func string(_ number: Int) -> String? {
        guard case .bytes(let bytes)? = fields[number]?.last else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
    func message(_ number: Int) -> ProtoMessage? {
        guard case .bytes(let bytes)? = fields[number]?.last else { return nil }
        return ProtoMessage(bytes)
    }
    func messages(_ number: Int) -> [ProtoMessage] {
        (fields[number] ?? []).compactMap { if case .bytes(let bytes) = $0 { ProtoMessage(bytes) } else { nil } }
    }
    /// A repeated float, packed (proto3's default) or one value per field.
    func floats(_ number: Int) -> [Float] {
        var result: [Float] = []
        for value in fields[number] ?? [] {
            switch value {
            case .fixed32(let bits): result.append(Float(bitPattern: bits))
            case .bytes(let bytes) where bytes.count % 4 == 0:
                result.reserveCapacity(result.count + bytes.count / 4)
                for start in stride(from: 0, to: bytes.count, by: 4) {
                    let bits = UInt32(bytes[start]) | UInt32(bytes[start + 1]) << 8 | UInt32(bytes[start + 2]) << 16 | UInt32(bytes[start + 3]) << 24
                    result.append(Float(bitPattern: bits))
                }
            default: continue
            }
        }
        return result
    }
}

/// Builds requests: a field number with an empty message, the shape of every `Request` the dish takes here.
enum ProtoWriter {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f); value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }
    static func field(_ number: Int, message: [UInt8]) -> [UInt8] {
        varint(UInt64(number) << 3 | 2) + varint(UInt64(message.count)) + message
    }
    static func field(_ number: Int, varint value: UInt64) -> [UInt8] { varint(UInt64(number) << 3) + varint(value) }
}

/// The dish's one RPC, `SpaceX.API.Device.Device/Handle`, over the two doors it opens on the local network:
/// gRPC-Web on port 9201 (HTTP/1.1, what the dish's own web page used) and plain gRPC on port 9200 (HTTP/2 without TLS,
/// what grpcurl and the open-source tools use). Kilobat knocks on 9201 first because URLSession speaks it; when that
/// door is shut it tries 9200 with a small HTTP/2 client on Network.framework. No request leaves the local network.
enum StarlinkWire {
    static let path = "/SpaceX.API.Device.Device/Handle"
    /// The dish's fixed address. `KILOBAT_STARLINK_HOST` points Kilobat at another one, such as a test server.
    static var host: String { ProcessInfo.processInfo.environment["KILOBAT_STARLINK_HOST"].flatMap { $0.isEmpty ? nil : $0 } ?? "192.168.100.1" }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The 5-byte gRPC length prefix both transports share: an uncompressed flag, then the length, big-endian.
    static func frame(_ message: [UInt8]) -> [UInt8] {
        let count = UInt32(message.count)
        return [0, UInt8(count >> 24 & 0xff), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)] + message
    }

    /// Splits a gRPC-Web body into its messages and the trailer's grpc-status (nil when there is no trailer frame).
    static func unframe(_ body: [UInt8]) -> (messages: [[UInt8]], status: Int?)? {
        var index = 0, messages: [[UInt8]] = [], status: Int?
        while index < body.count {
            guard index + 5 <= body.count else { return nil }
            let flag = body[index]
            let length = Int(body[index + 1]) << 24 | Int(body[index + 2]) << 16 | Int(body[index + 3]) << 8 | Int(body[index + 4])
            index += 5
            guard length <= body.count - index else { return nil }
            let payload = Array(body[index..<index + length]); index += length
            if flag & 0x80 != 0 {
                for line in String(decoding: payload, as: UTF8.self).split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, parts[0].lowercased() == "grpc-status" { status = Int(parts[1]) }
                }
            } else if flag & 0x01 == 0 { messages.append(payload) } else { return nil }
        }
        return (messages, status)
    }

    /// One call: the `Request` bytes in, the `Response` bytes out. Tries gRPC-Web, then HTTP/2.
    static func call(_ request: [UInt8], timeout: TimeInterval = 3) async throws -> [UInt8] {
        do { return try await grpcWeb(request, timeout: timeout) }
        // The dish answered and refused: the other door gives the same answer.
        catch let error as Failure where error.message == "status" { throw error }
        // Nothing at the address at all: the other door won't answer either, so don't wait twice.
        catch let error as URLError where [.timedOut, .cannotFindHost, .notConnectedToInternet].contains(error.code) { throw error }
        catch { return try await H2C.call(host: host, port: 9200, path: path, message: frame(request), timeout: timeout) }
    }

    static func grpcWeb(_ request: [UInt8], timeout: TimeInterval) async throws -> [UInt8] {
        guard let url = URL(string: "http://\(host):9201\(path)") else { throw Failure("address") }
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        urlRequest.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        urlRequest.httpBody = Data(frame(request))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout + 1
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        // The dish is on the local network: a system proxy must not carry the request.
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("grpc") else { throw Failure("not grpc-web") }
        if let status = http.value(forHTTPHeaderField: "grpc-status").flatMap(Int.init), status != 0 { throw Failure("status") }
        guard let body = unframe(Array(data)) else { throw Failure("frame") }
        if let status = body.status, status != 0 { throw Failure("status") }
        guard let message = body.messages.first else { throw Failure("empty") }
        return message
    }
}

/// A one-request HTTP/2 client over cleartext TCP ("prior knowledge", RFC 9113 §3.3), for the dish's gRPC port.
/// It sends the connection preface, its settings with a large window, one HEADERS frame of literal fields (HPACK
/// without indexing or Huffman, which every decoder accepts) and one DATA frame; then it answers SETTINGS and PING and
/// gathers stream 1's DATA until the stream ends. It never decodes the server's headers: the gRPC message in the
/// body is the answer, and a call that failed has none.
enum H2C {
    static func call(host: String, port: UInt16, path: String, message: [UInt8], timeout: TimeInterval) async throws -> [UInt8] {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 9200, using: .tcp)
        let session = Session(connection: connection)
        return try await withThrowingTaskGroup(of: [UInt8].self) { group in
            group.addTask { try await session.run(host: host, port: port, path: path, message: message) }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); throw StarlinkWire.Failure("timeout") }
            defer { group.cancelAll(); connection.cancel() }
            guard let result = try await group.next() else { throw StarlinkWire.Failure("timeout") }
            return result
        }
    }

    static let preface = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    static func frame(type: UInt8, flags: UInt8, stream: UInt32, payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        return [UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff), type, flags,
                UInt8(stream >> 24 & 0x7f), UInt8(stream >> 16 & 0xff), UInt8(stream >> 8 & 0xff), UInt8(stream & 0xff)] + payload
    }
    /// An HPACK integer with an `prefix`-bit prefix (RFC 7541 §5.1).
    static func integer(_ value: Int, prefix: Int, first: UInt8 = 0) -> [UInt8] {
        let limit = (1 << prefix) - 1
        guard value >= limit else { return [first | UInt8(value)] }
        var bytes = [first | UInt8(limit)], rest = value - limit
        while rest >= 128 { bytes.append(UInt8(rest % 128 + 128)); rest /= 128 }
        return bytes + [UInt8(rest)]
    }
    /// Literal header field without indexing, new name (RFC 7541 §6.2.2).
    static func header(_ name: String, _ value: String) -> [UInt8] {
        let name = Array(name.utf8), value = Array(value.utf8)
        return [0] + integer(name.count, prefix: 7) + name + integer(value.count, prefix: 7) + value
    }
    /// What the client sends before reading anything.
    static func opening(host: String, port: UInt16, path: String, message: [UInt8]) -> [UInt8] {
        let window: UInt32 = 1 << 24
        let settings: [UInt8] = [0, 2, 0, 0, 0, 0] + [0, 4, UInt8(window >> 24), UInt8(window >> 16 & 0xff), UInt8(window >> 8 & 0xff), UInt8(window & 0xff)]
        let increment = window - 65_535
        let headers = header(":method", "POST") + header(":scheme", "http") + header(":path", path) + header(":authority", "\(host):\(port)")
            + header("content-type", "application/grpc") + header("te", "trailers")
        return preface + frame(type: 4, flags: 0, stream: 0, payload: settings)
            + frame(type: 8, flags: 0, stream: 0, payload: [UInt8(increment >> 24), UInt8(increment >> 16 & 0xff), UInt8(increment >> 8 & 0xff), UInt8(increment & 0xff)])
            + frame(type: 1, flags: 0x4, stream: 1, payload: headers)
            + frame(type: 0, flags: 0x1, stream: 1, payload: message)
    }

    /// Reads frames from `buffer`, returning replies to send and whether stream 1 ended. Consumed bytes are removed.
    struct Reader {
        var buffer: [UInt8] = []
        var body: [UInt8] = []
        var ended = false
        var failed = false
        mutating func feed(_ bytes: [UInt8]) -> [UInt8] {
            buffer += bytes
            var replies: [UInt8] = []
            while buffer.count >= 9 {
                let length = Int(buffer[0]) << 16 | Int(buffer[1]) << 8 | Int(buffer[2])
                guard buffer.count >= 9 + length else { break }
                let type = buffer[3], flags = buffer[4]
                let stream = UInt32(buffer[5] & 0x7f) << 24 | UInt32(buffer[6]) << 16 | UInt32(buffer[7]) << 8 | UInt32(buffer[8])
                var payload = Array(buffer[9..<9 + length])
                buffer.removeFirst(9 + length)
                switch type {
                case 0 where stream == 1: // DATA
                    if flags & 0x8 != 0, let pad = payload.first { payload = Array(payload.dropFirst().dropLast(Int(pad))) }
                    body += payload
                    if flags & 0x1 != 0 { ended = true }
                case 1 where stream == 1: // HEADERS, the response's or the trailers
                    if flags & 0x1 != 0 { ended = true }
                case 3 where stream == 1: failed = true; ended = true // RST_STREAM
                case 4 where flags & 0x1 == 0: replies += H2C.frame(type: 4, flags: 1, stream: 0, payload: []) // SETTINGS → ACK
                case 6 where flags & 0x1 == 0: replies += H2C.frame(type: 6, flags: 1, stream: 0, payload: payload) // PING → ACK
                case 7: ended = true // GOAWAY
                default: break
                }
            }
            return replies
        }
        /// The first gRPC message in the body.
        var message: [UInt8]? {
            guard !failed, let parts = StarlinkWire.unframe(body), let first = parts.messages.first else { return nil }
            return first
        }
    }

    final class Session: @unchecked Sendable {
        let connection: NWConnection
        init(connection: NWConnection) { self.connection = connection }

        func run(host: String, port: UInt16, path: String, message: [UInt8]) async throws -> [UInt8] {
            try await ready()
            try await send(H2C.opening(host: host, port: port, path: path, message: message))
            var reader = Reader()
            while !reader.ended {
                let (bytes, complete) = try await receive()
                let replies = reader.feed(bytes)
                if !replies.isEmpty { try await send(replies) }
                if complete { break }
            }
            guard let result = reader.message else { throw StarlinkWire.Failure("no message") }
            return result
        }

        private func ready() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = Once()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { continuation.resume() }
                    case .failed(let error): once.run { continuation.resume(throwing: error) }
                    case .waiting(let error): once.run { continuation.resume(throwing: error) }
                    case .cancelled: once.run { continuation.resume(throwing: StarlinkWire.Failure("cancelled")) }
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .utility))
            }
        }
        private func send(_ bytes: [UInt8]) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: Data(bytes), completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
        private func receive() async throws -> ([UInt8], Bool) {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (data.map { Array($0) } ?? [], complete)) }
                }
            }
        }
    }

    /// Resumes a continuation once, whatever order the connection's states arrive in.
    final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true; body()
        }
    }
}
