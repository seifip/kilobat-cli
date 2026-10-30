import Foundation
import Observation

/// Notices calls and writes a report card for each. While an app holds the microphone it pings the internet and the
/// router once a second and notes the busiest other app; when the call ends, `CallAnalysis` names each freeze's cause.
@MainActor @Observable public final class CallStore {
    public private(set) var reports: [CallReport] = []
    /// The call in progress and when it started.
    public private(set) var live: (call: CallDetector.Call, start: Date)?
    public var enabled = UserDefaults.standard.object(forKey: "callReports") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "callReports"); if !enabled { Task { await stop(report: false) } } }
    }
    /// Called with each finished report, for the notification.
    public var onReport: ((CallReport) -> Void)?
    private let file: URL
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var candidate: (call: CallDetector.Call, since: Date)?
    @ObservationIgnored private var silentSince: Date?
    @ObservationIgnored private var samples = CallSamples()
    @ObservationIgnored private var internet: PingStream?
    @ObservationIgnored private var router: PingStream?
    @ObservationIgnored private var lastAirDropCheck = Date.distantPast
    @ObservationIgnored private var ticks: MacLoad.Ticks?
    @ObservationIgnored private var lastLoad = Date.distantPast
    /// A call this short isn't worth a card; mic tests and voice messages are.
    static let shortest: TimeInterval = 60

    public init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("calls.json")
        reports = StoredJSON.read(file) ?? []
    }

    #if DEBUG
    /// Made-up calls for screenshots and layout checks; debug builds only.
    public func preview(_ reports: [CallReport]) { self.reports = reports }
    #endif

    nonisolated public static func load(directory: URL? = nil) -> [CallReport] {
        StoredJSON.read((directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")).appendingPathComponent("calls.json")) ?? []
    }

    public func start(traffic: TrafficStore, diagnostics: DiagnosticStore) {
        guard loop == nil else { return }
        loop = Task { [weak self, weak traffic, weak diagnostics] in
            while !Task.isCancelled {
                guard let self, let traffic, let diagnostics else { return }
                await self.tick(traffic: traffic, diagnostics: diagnostics)
                try? await Task.sleep(for: .seconds(self.live == nil ? 3 : 1))
            }
        }
    }

    private func tick(traffic: TrafficStore, diagnostics: DiagnosticStore) async {
        guard enabled else { return }
        let call = CallDetector.microphoneUsers().flatMap { CallDetector.call(microphone: $0) }
        let now = Date()
        if let live {
            if call?.app == live.call.app { silentSince = nil; record(traffic: traffic, diagnostics: diagnostics, call: live.call, now: now) }
            else if let since = silentSince, now.timeIntervalSince(since) >= 10 { await stop(report: true, end: since, diagnostics: diagnostics) }
            else if silentSince == nil { silentSince = now }
            return
        }
        // Ten seconds on the microphone before it counts, so a quick dictation or mic check doesn't start one.
        guard let call else { candidate = nil; return }
        if candidate?.call != call { candidate = (call, now); return }
        guard let since = candidate?.since, now.timeIntervalSince(since) >= 10 else { return }
        live = (call, since); candidate = nil; samples = CallSamples(); silentSince = nil; ticks = nil; lastLoad = .distantPast
        internet = PingStream(target: "internet", start: since); router = PingStream(target: "router", start: since)
        await internet?.start(); await router?.start()
    }

    private func record(traffic: TrafficStore, diagnostics: DiagnosticStore, call: CallDetector.Call, now: Date) {
        guard let start = live?.start else { return }
        let at = now.timeIntervalSince(start)
        let others = traffic.apps.filter { app in !app.carrier && !call.own.contains { app.id.hasPrefix($0) || app.name == $0 } }
        if let top = others.max(by: { $0.rate < $1.rate }), top.rate > 0 {
            samples.traffic.append(.init(at: at, app: top.name, upload: top.uploadRate, download: top.downloadRate))
        }
        if diagnostics.snapshot?.radio.health == .poor { samples.weakSignal.append(at) }
        if now.timeIntervalSince(lastLoad) >= 5 {
            lastLoad = now
            if let previous = ticks { Task { if let (load, next) = await MacLoad.sample(since: previous) { self.ticks = next; self.samples.load.append(.init(at: at, load: load)) } } }
            else { ticks = MacLoad.ticks() }
        }
        if now.timeIntervalSince(lastAirDropCheck) >= 30 {
            lastAirDropCheck = now
            Task { if await NearbyRadios.awdlStatus().active { self.samples.airDrop = true } }
        }
    }

    private func stop(report: Bool, end: Date = Date(), diagnostics: DiagnosticStore? = nil) async {
        guard let live else { return }
        samples.internet = await internet?.stop() ?? []; samples.router = await router?.stop() ?? []
        internet = nil; router = nil; self.live = nil; silentSince = nil
        guard report, end.timeIntervalSince(live.start) >= Self.shortest, !samples.internet.isEmpty else { return }
        let network = diagnostics?.snapshot.map { ($0.networkKey, $0.networkName) }
        let card = CallAnalysis.report(app: live.call.app, browser: live.call.browser, start: live.start, end: end, network: network, samples: samples)
        reports.append(card); reports = Array(reports.suffix(200))
        try? JSONEncoder().encode(reports).write(to: file, options: .atomic)
        onReport?(card)
    }
}

/// `ping` once a second for as long as a call lasts; a reply later than a second counts as lost, as the call feels it.
actor PingStream {
    private let target: String, start: Date
    private var process: Process?
    private var pings: [CallSamples.Ping] = []
    /// Seconds from the call's start to the first ping; each ping's time comes from its sequence number, since a lost one is only reported later.
    private var offset = 0.0
    init(target: String, start: Date) { self.target = target; self.start = start }

    func start() async {
        guard let host = try? await StutterTest.host(for: target) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-n", "-i", "1", "-W", "1000", host]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let self, !text.isEmpty else { return }
            Task { await self.ingest(text) }
        }
        offset = Date().timeIntervalSince(start)
        do { try process.run(); self.process = process } catch { self.process = nil }
    }

    func stop() -> [CallSamples.Ping] {
        process?.terminate(); process = nil
        return pings.sorted { $0.at < $1.at }
    }

    private func ingest(_ text: String) {
        for line in text.split(separator: "\n").map(String.init) {
            guard let seq = DiagnosticProbe.matches("icmp_seq[= ]([0-9]+)", in: line).first.flatMap(Double.init) else { continue }
            if line.contains("Request timeout") { pings.append(.init(at: offset + seq, ms: nil)) }
            else if let time = DiagnosticProbe.matches("time=([0-9.]+) ms", in: line).first.flatMap(Double.init) { pings.append(.init(at: offset + seq, ms: time)) }
        }
    }
}
