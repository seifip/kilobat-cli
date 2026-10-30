import Foundation
import Network

/// A live ping overlay for OBS and other streaming apps: a page on 127.0.0.1 that a Browser Source shows over the
/// stream, with ping, jitter and loss from a once-a-second ping, and optionally this Mac's download and upload.
/// Only this Mac can reach it; nothing is sent anywhere.
public final class StreamOverlay: @unchecked Sendable {
    public static let defaultPort: UInt16 = 7171

    public struct Rates: Sendable {
        public let downloadBytesPerSecond: Double
        public let uploadBytesPerSecond: Double
        public init(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
            self.downloadBytesPerSecond = downloadBytesPerSecond; self.uploadBytesPerSecond = uploadBytesPerSecond
        }
    }

    public let port: UInt16
    public var url: String { "http://localhost:\(port)/" }
    private let pinger: LivePing
    private let rates: @Sendable () async -> Rates?
    /// Pro may hide the wordmark and the bat; the free overlay always shows Kilobat's name.
    private let unbranded: @Sendable () async -> Bool
    private let queue = DispatchQueue(label: "co.seifi.kilobat.overlay")
    private var listener: NWListener?

    /// `target` is "internet" (1.1.1.1), "router" or a host name. `rates` reads this Mac's traffic, if the caller has it.
    public init(port: UInt16 = StreamOverlay.defaultPort, target: String = "internet", rates: @escaping @Sendable () async -> Rates? = { nil },
                unbranded: @escaping @Sendable () async -> Bool = { false }) {
        self.port = port; self.pinger = LivePing(target: target); self.rates = rates; self.unbranded = unbranded
    }

    public func start() throws {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
        Task { await pinger.start() }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        Task { await pinger.stop() }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            Task {
                let (status, type, body) = await self.respond(to: path)
                let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func respond(to path: String) async -> (String, String, Data) {
        let route = path.split(separator: "?").first.map(String.init) ?? "/"
        switch route {
        case "/", "/overlay": return ("200 OK", "text/html; charset=utf-8", Data(Self.page.utf8))
        case "/data.json":
            var value = await pinger.summary()
            if let rates = await rates() {
                value.downloadBytesPerSecond = rates.downloadBytesPerSecond
                value.uploadBytesPerSecond = rates.uploadBytesPerSecond
            }
            value.unbrandedAllowed = await unbranded()
            return ("200 OK", "application/json", (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
        default: return ("404 Not Found", "text/plain", Data("Not found".utf8))
        }
    }
}

/// One ping a second to the target, kept for the last minute. Missed replies count as loss.
actor LivePing {
    private let target: String
    private var process: Process?
    private var samples: [Double?] = []
    private var host = ""
    init(target: String) { self.target = target }

    func start() async {
        guard process == nil else { return }
        host = (try? await StutterTest.host(for: target)) ?? "1.1.1.1"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        // -n numeric, 1 s apart, 1 s wait each: a reply later than that counts as lost, as a stream would feel it.
        process.arguments = ["-n", "-i", "1", "-W", "1000", host]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let self, !text.isEmpty else { return }
            Task { await self.ingest(text) }
        }
        do { try process.run(); self.process = process } catch { self.process = nil }
    }

    func stop() {
        process?.terminate(); process = nil; samples = []
    }

    private func ingest(_ text: String) {
        for line in text.split(separator: "\n") {
            if line.contains("Request timeout") { append(nil) }
            else if let time = DiagnosticProbe.matches("time=([0-9.]+) ms", in: String(line)).first.flatMap(Double.init) { append(time) }
        }
    }
    private func append(_ value: Double?) {
        samples.append(value)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
    }

    struct Summary: Encodable, Sendable {
        let host: String, target: String
        let pingMs: Double?, jitterMs: Double?, lossPercent: Double?
        /// The last minute, oldest first; null for a missed reply.
        let history: [Double?]
        var downloadBytesPerSecond: Double?, uploadBytesPerSecond: Double?
        var unbrandedAllowed = false
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(host, forKey: .host); try c.encode(target, forKey: .target)
            try c.encode(pingMs, forKey: .pingMs); try c.encode(jitterMs, forKey: .jitterMs); try c.encode(lossPercent, forKey: .lossPercent)
            try c.encode(history, forKey: .history)
            try c.encodeIfPresent(downloadBytesPerSecond, forKey: .downloadBytesPerSecond); try c.encodeIfPresent(uploadBytesPerSecond, forKey: .uploadBytesPerSecond)
            try c.encode(unbrandedAllowed, forKey: .unbrandedAllowed)
        }
        enum CodingKeys: String, CodingKey { case host, target, pingMs, jitterMs, lossPercent, history, downloadBytesPerSecond, uploadBytesPerSecond, unbrandedAllowed }
    }

    func summary() -> Summary {
        let recent = Array(samples.suffix(30)), replies = recent.compactMap { $0 }
        let jitter = replies.count > 1 ? zip(replies, replies.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(replies.count - 1) : nil
        let loss = recent.isEmpty ? nil : Double(recent.filter { $0 == nil }.count) / Double(recent.count) * 100
        return Summary(host: host, target: target, pingMs: samples.last.flatMap { $0 }, jitterMs: jitter, lossPercent: loss, history: samples)
    }
}
