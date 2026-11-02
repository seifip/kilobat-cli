import Foundation
import Network
import Testing
@testable import KilobatCore

/// Stream reports for OBS: the obs-websocket v5 handshake and its password hash, OBS's responses, when frames count as
/// dropped, whether the network, the encoder or the GPU is blamed, and the bitrate's 30% headroom.
struct StreamReportTests {
    // MARK: obs-websocket v5

    /// The protocol's own Hello example (docs/generated/protocol.md, "Creating an authentication string"), worked with
    /// Python's hashlib: base64(sha256(password + salt)), then base64(sha256(secret + challenge)). The docs' sample
    /// Identify doesn't match its own Hello, so these come from the published algorithm, not that sample.
    @Test func authenticationStringMatchesTheProtocolsAlgorithm() {
        let salt = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=", challenge = "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="
        #expect(OBSProtocol.authentication(password: "supersecretpassword", salt: salt, challenge: challenge) == "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")
        // A second vector, also from hashlib: a one-letter password, salt and challenge.
        #expect(OBSProtocol.authentication(password: "p", salt: "s", challenge: "c") == "LEfh2WVBWpa8M06P7MehLXlToA1PtH2lNSNPjUZVYls=")
    }

    @Test func parsesHelloIdentifiedEventAndResponse() {
        let hello = Data(#"{"op":0,"d":{"obsWebSocketVersion":"5.5.2","rpcVersion":1,"authentication":{"challenge":"c1","salt":"s1"}}}"#.utf8)
        #expect(OBSProtocol.parse(hello) == .hello(rpcVersion: 1, version: "5.5.2", challenge: "c1", salt: "s1"))
        let open = Data(#"{"op":0,"d":{"obsWebSocketVersion":"5.0.0","rpcVersion":1}}"#.utf8)
        #expect(OBSProtocol.parse(open) == .hello(rpcVersion: 1, version: "5.0.0", challenge: nil, salt: nil))
        #expect(OBSProtocol.parse(Data(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#.utf8)) == .identified(rpcVersion: 1))
        let event = Data(#"{"op":5,"d":{"eventType":"StreamStateChanged","eventIntent":64,"eventData":{"outputActive":true,"outputState":"OBS_WEBSOCKET_OUTPUT_STARTED"}}}"#.utf8)
        guard case .event(let type, let data)? = OBSProtocol.parse(event) else { Issue.record("no event"); return }
        #expect(type == "StreamStateChanged" && data["outputActive"]?.bool == true)
        let failed = Data(#"{"op":7,"d":{"requestType":"GetStats","requestId":"kilobat-1","requestStatus":{"result":false,"code":204,"comment":"nope"}}}"#.utf8)
        guard case .response(_, let id, let ok, let code, let comment, _)? = OBSProtocol.parse(failed) else { Issue.record("no response"); return }
        #expect(id == "kilobat-1" && !ok && code == 204 && comment == "nope")
        #expect(OBSProtocol.parse(Data("not json".utf8)) == nil)
    }

    @Test func identifyAndRequestAreWhatTheServerExpects() throws {
        let identify = try JSONDecoder().decode(JSONValue.self, from: OBSProtocol.identify(authentication: "abc"))
        #expect(identify["op"]?.int == 1 && identify["d"]?["rpcVersion"]?.int == 1 && identify["d"]?["authentication"]?.string == "abc")
        // Outputs only (1 << 6): StreamStateChanged, without high-volume events.
        #expect(identify["d"]?["eventSubscriptions"]?.int == 64)
        let open = try JSONDecoder().decode(JSONValue.self, from: OBSProtocol.identify(authentication: nil))
        #expect(open["d"]?["authentication"] == nil)
        let request = try JSONDecoder().decode(JSONValue.self, from: OBSProtocol.request("GetProfileParameter", id: "kilobat-7", data: ["parameterCategory": .string("Output")]))
        #expect(request["op"]?.int == 6 && request["d"]?["requestType"]?.string == "GetProfileParameter" && request["d"]?["requestId"]?.string == "kilobat-7")
        #expect(request["d"]?["requestData"]?["parameterCategory"]?.string == "Output")
    }

    // Response data as OBS 31 sends it.
    static let streamStatus = #"{"outputActive":true,"outputBytes":1834052096,"outputCongestion":0.0123,"outputDuration":1912345,"outputReconnecting":false,"outputSkippedFrames":412,"outputTimecode":"00:31:52.345","outputTotalFrames":114740}"#
    static let stats = #"{"activeFps":60.0000024,"availableDiskSpace":214748.36,"averageFrameRenderTime":3.81,"cpuUsage":21.4,"memoryUsage":612.5,"outputSkippedFrames":17,"outputTotalFrames":114760,"renderSkippedFrames":233,"renderTotalFrames":115400,"webSocketSessionIncomingMessages":40,"webSocketSessionOutgoingMessages":41}"#

    @Test func parsesStreamStatusAndStats() throws {
        let status = try #require(OBSStreamStatus(try JSONDecoder().decode(JSONValue.self, from: Data(Self.streamStatus.utf8))))
        #expect(status.active && !status.reconnecting && status.skippedFrames == 412 && status.totalFrames == 114_740 && status.bytes == 1_834_052_096)
        #expect(abs(status.congestion - 0.0123) < 1e-9 && status.duration == 1_912_345)
        let stats = try #require(OBSStats(try JSONDecoder().decode(JSONValue.self, from: Data(Self.stats.utf8))))
        // GetStats' outputSkippedFrames is the encoder's lag; renderSkippedFrames the GPU's. Neither is the network.
        #expect(stats.encoderSkipped == 17 && stats.encoderTotal == 114_760 && stats.renderSkipped == 233 && stats.renderTotal == 115_400)
        #expect(stats.cpuUsage == 21.4 && stats.averageFrameRenderTime == 3.81)
        #expect(OBSStreamStatus(.object([:])) == nil)
    }

    @Test func readsTheBitrateFromEitherOutputMode() throws {
        #expect(OBSBitrate.kbps(mode: "Simple", simpleVideo: "6000", simpleAudio: "160", encoder: nil, advancedAudio: nil) == 6_160)
        // A profile that never changed it: OBS's own defaults.
        #expect(OBSBitrate.kbps(mode: nil, simpleVideo: nil, simpleAudio: nil, encoder: nil, advancedAudio: nil) == 2_660)
        let encoder = Data(#"{"bitrate":8000,"keyint_sec":2,"rate_control":"CBR","profile":"high"}"#.utf8)
        #expect(OBSBitrate.kbps(mode: "Advanced", simpleVideo: nil, simpleAudio: nil, encoder: encoder, advancedAudio: "192") == 8_192)
        #expect(OBSBitrate.kbps(mode: "Advanced", simpleVideo: nil, simpleAudio: nil, encoder: Data(#"{"rate_control":"CRF","crf":20}"#.utf8), advancedAudio: nil) == nil)
        #expect(OBSBitrate.kbps(mode: "Advanced", simpleVideo: "6000", simpleAudio: nil, encoder: nil, advancedAudio: nil) == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obs-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Twitch_1080p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[General]\nName=Twitch 1080p\n".write(to: folder.appendingPathComponent("basic.ini"), atomically: true, encoding: .utf8)
        #expect(OBSBitrate.profileFolder(named: "Twitch 1080p", root: root)?.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(OBSBitrate.profileFolder(named: "YouTube", root: root) == nil)
    }

    // MARK: A fake OBS

    /// A WebSocket server on a free local port that answers as obs-websocket 5 does, with a password.
    final class FakeOBS: @unchecked Sendable {
        let listener: NWListener
        let password: String
        let salt = "c2FsdHNhbHQ=", challenge = "Y2hhbGxlbmdl"
        var port: UInt16 { listener.port?.rawValue ?? 0 }
        private let queue = DispatchQueue(label: "fake-obs")

        init(password: String) throws {
            self.password = password
            let options = NWProtocolWebSocket.Options()
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        func start() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // The handler runs on the listener's serial queue, and only one state is .ready.
                listener.stateUpdateHandler = { state in if case .ready = state { continuation.resume() } }
                listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
                listener.start(queue: queue)
            }
        }
        func stop() { listener.cancel() }

        private func send(_ connection: NWConnection, _ text: String) {
            let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
        }
        private func close(_ connection: NWConnection, code: UInt16) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .privateCode(code)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }

        private func serve(_ connection: NWConnection) {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state else { return }
                self.send(connection, #"{"op":0,"d":{"obsWebSocketVersion":"5.5.2","rpcVersion":1,"authentication":{"challenge":"\#(self.challenge)","salt":"\#(self.salt)"}}}"#)
                self.receive(connection)
            }
            connection.start(queue: queue)
        }

        private func receive(_ connection: NWConnection) {
            connection.receiveMessage { [weak self] content, _, _, error in
                guard let self, error == nil, let content, let message = try? JSONDecoder().decode(JSONValue.self, from: content) else { return }
                let d = message["d"]
                switch message["op"]?.int {
                case 1:
                    guard d?["authentication"]?.string == OBSProtocol.authentication(password: self.password, salt: self.salt, challenge: self.challenge) else {
                        self.close(connection, code: UInt16(OBSProtocol.authenticationFailed)); return
                    }
                    self.send(connection, #"{"op":2,"d":{"negotiatedRpcVersion":1}}"#)
                case 6:
                    let type = d?["requestType"]?.string ?? "", id = d?["requestId"]?.string ?? ""
                    let data: String = switch type {
                    case "GetStreamStatus": StreamReportTests.streamStatus
                    case "GetStats": StreamReportTests.stats
                    case "GetProfileParameter":
                        switch d?["requestData"]?["parameterName"]?.string {
                        case "Mode": #"{"parameterValue":"Simple","defaultParameterValue":"Simple"}"#
                        case "VBitrate": #"{"parameterValue":"6000","defaultParameterValue":"2500"}"#
                        default: #"{"parameterValue":null,"defaultParameterValue":"160"}"#
                        }
                    default: "{}"
                    }
                    self.send(connection, #"{"op":7,"d":{"requestType":"\#(type)","requestId":"\#(id)","requestStatus":{"result":true,"code":100},"responseData":\#(data)}}"#)
                default: break
                }
                self.receive(connection)
            }
        }
    }

    @Test func connectsToAFakeOBSAndReadsItsCounters() async throws {
        let obs = try FakeOBS(password: "hunter2-but-longer")
        await obs.start()
        defer { obs.stop() }
        let client = OBSClient(port: obs.port, password: "hunter2-but-longer")
        try await client.connect()
        #expect(await client.version == "5.5.2")
        let status = try await client.streamStatus()
        #expect(status.active && status.skippedFrames == 412)
        let stats = try await client.stats()
        #expect(stats.renderSkipped == 233)
        #expect(await client.bitrate() == 6_160)
        await client.disconnect()
    }

    @Test func saysWhatToFixWhenOBSTurnsTheConnectionDown() async throws {
        let obs = try FakeOBS(password: "right")
        await obs.start()
        defer { obs.stop() }
        await #expect(throws: OBSError(.wrongPassword)) { try await OBSClient(port: obs.port, password: "wrong").connect() }
        await #expect(throws: OBSError(.passwordNeeded)) { try await OBSClient(port: obs.port, password: nil).connect() }
        // Nothing listening: OBS closed, or its WebSocket server is off.
        // Port 1 (tcpmux) answers nothing on a Mac; a neighbouring port may be another test's fake OBS.
        await #expect(throws: OBSError(.notRunning)) { try await OBSClient(port: 1, password: nil).connect(timeout: .seconds(3)) }
        #expect(OBSError(.wrongPassword).message.contains("Show Connect Info"))
    }

    // MARK: Drops and their causes

    /// A stream at 60 fps from OBS's counters, with frames lost where asked, and a clean line.
    static func samples(seconds: Int = 600, network: [Int: Int] = [:], encoder: [Int: Int] = [:], render: [Int: Int] = [:]) -> StreamSamples {
        var samples = StreamSamples()
        var dropped = 0, skipped = 0, lagged = 0
        samples.obs = (0..<seconds).map { i in
            dropped += network[i] ?? 0; skipped += encoder[i] ?? 0; lagged += render[i] ?? 0
            return .init(at: Double(i), status: .init(active: true, bytes: Double(i) * 750_000, skippedFrames: dropped, totalFrames: i * 60),
                         stats: .init(renderSkipped: lagged, renderTotal: i * 60, encoderSkipped: skipped, encoderTotal: i * 60))
        }
        samples.line.internet = (0..<seconds).map { .init(at: Double($0), ms: 20) }
        samples.line.router = (0..<seconds).map { .init(at: Double($0), ms: 3) }
        return samples
    }

    @Test func findsStretchesOfDroppedFrames() {
        let ticks = StreamAnalysis.ticks(Self.samples(network: [100: 10, 101: 12, 104: 8, 300: 2, 400: 30]).obs) { ($0.status.skippedFrames, $0.status.totalFrames) }
        let windows = StreamAnalysis.windows(ticks)
        // 100–104 joins across a three-second gap; 300 lost too few to count; 400 stands alone.
        #expect(windows.count == 2)
        #expect(windows[0].from == 100 && windows[0].to == 104 && windows[0].lost == 30 && windows[0].frames == 300)
        #expect(windows[1].from == 400 && windows[1].lost == 30)
        // A counter that went back to zero (OBS restarted the output) starts over instead of counting negative.
        var restarted = Self.samples(seconds: 20).obs
        restarted[10] = .init(at: 10, status: .init(active: true, skippedFrames: 7, totalFrames: 60), stats: nil)
        let afterRestart = StreamAnalysis.ticks(restarted) { ($0.status.skippedFrames, $0.status.totalFrames) }
        #expect(afterRestart.allSatisfy { $0.lost >= 0 && $0.frames >= 0 } && afterRestart.contains { $0.at == 10 && $0.lost == 7 })
    }

    @Test func blamesTheAppThatWasUploading() {
        var samples = Self.samples(network: [200: 20, 201: 20, 202: 15])
        samples.line.traffic = [.init(at: 199, app: "Dropbox", upload: 1_200_000, download: 0)]
        samples.bitrate = 6_160; samples.uplink = 12
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let report = StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: nil, samples: samples)
        #expect(report.drops.count == 1)
        #expect(report.drops[0].source == .network && report.drops[0].cause == .init(kind: .app, app: "Dropbox", uploading: true))
        #expect(report.verdict.hasPrefix("Dropped") && report.verdict.contains("Dropbox was uploading"))
        #expect(report.capacity == "Your upload is 12 Mbps and OBS needs 8.")
        #expect(report.advice?.contains("Call mode for streams") == true)
        #expect(report.obsSide == nil && report.meaningful)
    }

    @Test func encoderAndRenderDropsAreNotTheNetwork() {
        var samples = Self.samples(encoder: [50: 10, 51: 10], render: [300: 20, 301: 20, 302: 20])
        samples.line.load = [.init(at: 300, load: MacLoad(cpu: 30, gpu: 99)), .init(at: 45, load: MacLoad(cpu: 98, top: "x264"))]
        // A busy uploader at the same time doesn't get the blame for frames OBS lost itself.
        samples.line.traffic = [.init(at: 300, app: "Dropbox", upload: 1_200_000, download: 0)]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let report = StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: nil, samples: samples)
        #expect(report.drops.map(\.source) == [.encoder, .render])
        #expect(report.drops[0].cause == .init(kind: .encoder, top: "x264"))
        #expect(report.drops[1].cause == .init(kind: .render, gpu: true))
        #expect(report.drops.allSatisfy { !$0.cause.network })
        #expect(report.networkPercent == 0 && report.renderPercent > 0)
        #expect(report.drops[1].cause.phrase.contains("GPU was the bottleneck, not your connection"))
        #expect(report.obsSide?.contains("faster upload wouldn’t have helped") == true)
    }

    @Test func blamesTheBitrateWhenNothingElseWasBusy() {
        var samples = Self.samples(network: [120: 30, 121: 30])
        samples.bitrate = 8_160; samples.uplink = 7.5
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let report = StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: nil, samples: samples)
        #expect(report.drops.first?.cause.kind == .bitrate)
        #expect(report.advice?.contains("5,700 kbps") == true)
        // The same drop with an upload that carries it is past the router: the provider or the path to the ingest server.
        samples.uplink = 40
        #expect(StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: nil, samples: samples).drops.first?.cause.kind == .beyondRouter)
        // Without a speed test, Kilobat doesn't guess at the bitrate.
        samples.uplink = nil
        #expect(StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: nil, samples: samples).drops.first?.cause.kind == .beyondRouter)
    }

    @Test func blamesWiFiWhenTheRouterStalled() {
        var samples = Self.samples(network: [60: 25, 61: 25])
        samples.line.router = (0..<600).map { .init(at: Double($0), ms: (59...62).contains($0) ? 400 : 3) }
        samples.line.weakSignal = [55]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let cause = StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: nil, samples: samples).drops.first?.cause
        #expect(cause == .init(kind: .wifi, weakSignal: true))
        #expect(cause?.advice.contains("Ethernet") == true)
    }

    @Test func aFewStrayFramesAreNotWorthANotification() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clean = StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: nil, samples: Self.samples(network: [10: 3, 400: 2]))
        #expect(clean.clean && !clean.meaningful && clean.count == "No dropped frames")
        // Six frames in three seconds is a stretch (3.3% of it), but far under half a percent of the stream.
        let minor = StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: nil, samples: Self.samples(network: [100: 2, 101: 2, 102: 2]))
        #expect(!minor.clean && minor.drops[0].percent < 5 && !minor.meaningful)
        // The same in one second is 10% of that second: worth knowing.
        let burst = StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: nil, samples: Self.samples(network: [100: 6]))
        #expect(burst.meaningful)
    }

    // MARK: Headroom

    @Test func headroomRule() {
        #expect(StreamHeadroom.needed(6_000) == 7.8)
        #expect(StreamHeadroom.verdict(bitrate: 6_000, upload: 12) == .ready)
        #expect(StreamHeadroom.verdict(bitrate: 6_000, upload: 7.8) == .ready)
        #expect(StreamHeadroom.verdict(bitrate: 6_000, upload: 7) == .tight)
        #expect(StreamHeadroom.verdict(bitrate: 6_000, upload: 5.9) == .short)
        #expect(StreamHeadroom.verdict(bitrate: nil, upload: 20) == .unknown)
        #expect(StreamHeadroom.verdict(bitrate: 6_000, upload: nil) == .unknown)
        #expect(StreamHeadroom.sustainable(upload: 10) == 7_600)
        #expect(StreamHeadroom.sustainable(upload: 7.5) == 5_700)

        let ready = StreamReadiness(bitrate: 6_160, bitrateSource: "obs", upload: 12.4, uploadSource: .test, uploadDate: Date(), latency: 20, jitter: 2, lossPercent: 0, metered: false)
        #expect(ready.ready && ready.headline == "Ready to go live" && ready.summary.contains("12.4 Mbps") && ready.summary.contains("8"))
        let short = StreamReadiness(bitrate: 6_160, bitrateSource: "obs", upload: 5, uploadSource: .history, uploadDate: Date().addingTimeInterval(-7_200),
                                    latency: 20, jitter: 45, lossPercent: 2, metered: true, busy: [.init(kind: .app, app: "Dropbox", uploading: true)])
        #expect(!short.ready && short.verdict == .short && short.unstable && short.suggested == 3_800)
        #expect(short.notes.count == 3 && short.notes[0].contains("metered"))
    }

    // MARK: CLI

    @Test func parsesStreamCommands() throws {
        #expect(try StreamQuery.parse(["stream"]).command == .status)
        let check = try StreamQuery.parse(["stream", "check", "--bitrate", "6000", "--no-measure", "--json"])
        #expect(check.command == .check && check.bitrate == 6_000 && check.measure == false && check.json)
        #expect(try StreamQuery.parse(["stream", "check", "--measure"]).measure == true)
        #expect(try StreamQuery.parse(["stream", "reports", "--limit", "3"]).limit == 3)
        let status = try StreamQuery.parse(["stream", "status", "--port", "4456", "--password-stdin"])
        #expect(status.port == 4_456 && status.passwordStdin)
        #expect(throws: StreamQuery.Invalid.self) { try StreamQuery.parse(["stream", "check", "--measure", "--no-measure"]) }
        #expect(throws: StreamQuery.Invalid.self) { try StreamQuery.parse(["stream", "reports", "--bitrate", "6000"]) }
        #expect(throws: StreamQuery.Invalid.self) { try StreamQuery.parse(["stream", "check", "--bitrate", "6 Mbps"]) }
        #expect(throws: StreamQuery.Invalid.self) { try StreamQuery.parse(["stream", "reports", "--limit", "0"]) }
        #expect(throws: StreamQuery.Invalid.self) { try StreamQuery.parse(["stream", "status", "--port", "80"]) }
        #expect(throws: StreamQuery.Invalid.self) { try StreamQuery.parse(["stream", "go"]) }
    }

    @Test func reportsRoundTripAndExportTheirSentences() throws {
        var samples = Self.samples(network: [200: 20, 201: 20])
        samples.bitrate = 6_160; samples.uplink = 12
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let report = StreamAnalysis.report(start: start, end: start.addingTimeInterval(600), network: ("net", "Home"), samples: samples)
        let decoded = try JSONDecoder().decode(StreamReport.self, from: try JSONEncoder().encode(report))
        #expect(decoded == report)
        let exported = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(StreamReport.Exported(report)))
        #expect(exported["verdict"]?.string == report.verdict && exported["neededMbps"]?.double != nil && exported["spans"] != nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([report]).write(to: directory.appendingPathComponent("streams.json"))
        #expect(StreamStore.load(directory: directory) == [report])
    }
}
