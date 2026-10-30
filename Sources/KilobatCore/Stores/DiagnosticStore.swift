import AppKit
import CoreLocation
import Observation
import AVFoundation

@MainActor @Observable
public final class DiagnosticStore: NSObject, @preconcurrency CLLocationManagerDelegate {
    public static let shared = DiagnosticStore()
    public var scheduleHours = UserDefaults.standard.integer(forKey: "speedScheduleHours") {
        didSet { UserDefaults.standard.set(scheduleHours, forKey: "speedScheduleHours"); nextScheduledTest = scheduleHours > 0 ? Date().addingTimeInterval(Double(scheduleHours) * 3600) : nil }
    }
    public var automaticTrace = UserDefaults.standard.bool(forKey: "automaticOutageTrace") { didSet { UserDefaults.standard.set(automaticTrace, forKey: "automaticOutageTrace") } }
    public var checkInterval = max(12, UserDefaults.standard.integer(forKey: "diagnosticInterval")) { didSet { UserDefaults.standard.set(checkInterval, forKey: "diagnosticInterval") } }
    /// Connections a speed test opens at once: 1, or SpeedTest.parallelStreams.
    public var speedStreams = max(1, UserDefaults.standard.integer(forKey: "speedStreams")) { didSet { UserDefaults.standard.set(speedStreams, forKey: "speedStreams") } }
    /// Off unless the person turns it on: the public address takes a request to Cloudflare.
    public var publicLookup = UserDefaults.standard.bool(forKey: "publicIPLookup") {
        didSet {
            UserDefaults.standard.set(publicLookup, forKey: "publicIPLookup")
            if publicLookup { Task { await refreshExit(force: true) } } else { exitPath?.publicAddress = nil; lookupError = nil }
        }
    }
    /// Where traffic leaves: the default route, VPN and, with `publicLookup`, the public address.
    public private(set) var exitPath: ExitPath?
    public private(set) var lookingUp = false
    public private(set) var lookupError: String?
    private var exitNetwork: String?
    private var lookupAttempt: Date?
    private var tracedIncident: UUID?
    public var nextScheduledTest: Date?
    private var scheduleConnected = false
    private var scheduleMetered = true
    private let scheduleNetwork = NetworkStatus()
    /// The current network's cost as the app sees it, including networks marked by hand; macOS's flag otherwise.
    public var metered: (@MainActor () -> Bool)?
    private var scheduleTask: Task<Void, Never>?
    public var onSnapshot: ((DiagnosticSnapshot) -> Void)?
    public let tools = ToolsStore()
    public let journal = NetworkJournal()
    public var snapshot: DiagnosticSnapshot?
    public let survey = SurveyJournal()
    public var radio: RadioSample?
    public var networks: [NearbyNetwork] = []
    public var signalHistory: [Double] = []
    public var bestScore = 0
    public var speakDirections = false
    private let speech = AVSpeechSynthesizer()
    private var lastSpoken = Date.distantPast
    private var lastDirection = ""
    private var surfaces: [UUID: (radar: Bool, menuBar: Bool)] = [:]
    public private(set) var radar = false
    public private(set) var visible = false {
        didSet {
            if visible && !oldValue { radioTask?.cancel(); radioTask = nil; startRadio() }
        }
    }
    public var scanning = false
    public var diagnosing = false
    public var speedPhase: SpeedTestUpdate.Phase = .latency
    public var speedFraction = 0.0
    public var speedDown: Double?
    public var speedUp: Double?
    public var speedDownHistory: [Double] = []
    public var speedUpHistory: [Double] = []
    public var speedStarted: Date?
    public var speedBytes = 0
    public var speedRunning = false
    public var speedProgress = "Ready when you are."
    /// The result shown while idle; nil during a run so live progress shows instead.
    public var speed: SpeedTestResult? { speedRunning ? nil : lastSpeed }
    /// The latest completed test. A cancelled or failed run never clears it.
    public private(set) var lastSpeed: SpeedTestResult?
    public var error: String?
    public var notice: String?
    public var reportNotice: String?
    private var reportNoticeTask: Task<Void, Never>?
    public var locationAllowed = false
    /// macOS asks once; after that only System Settings can change the answer.
    public var locationAsked = false
    public var sleeping = false
    public var changingDNS = false
    public var flushingDNS = false
    public let lowLatency = LowLatencyMode()
    public let stutter = StutterStore()
    public let nearby = NearbyStore()
    public let bluetooth = BluetoothState()
    private let probe = DiagnosticProbe()
    private let location = CLLocationManager()
    private var radioTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []

    public override init() {
        super.init()
        lastSpeed = journal.speedTests.last?.result
        nextScheduledTest = scheduleHours > 0 ? Date().addingTimeInterval(Double(scheduleHours) * 3600) : nil
        scheduleNetwork.start { [weak self] connected, metered, _ in
            Task { @MainActor in self?.scheduleConnected = connected; self?.scheduleMetered = metered }
        }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                if Self.scheduledTestDue(next: self.nextScheduledTest, hours: self.scheduleHours, connected: self.scheduleConnected, metered: self.metered?() ?? self.scheduleMetered, busy: self.sleeping || self.speedRunning) {
                    self.nextScheduledTest = Date().addingTimeInterval(Double(self.scheduleHours) * 3600)
                    self.runSpeedTest()
                }
            }
        }
        location.delegate = self
        updateLocation(location.authorizationStatus)
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshVisibility() }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshVisibility() }
        })
        let center = NSWorkspace.shared.notificationCenter
        notifications.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.journal.suspend(); self?.sleeping = true; self?.speedTask?.cancel() }
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; await self?.diagnose() }
        })
    }
    static func scheduledTestDue(next: Date?, hours: Int, connected: Bool, metered: Bool, busy: Bool, now: Date = Date()) -> Bool {
        guard let next else { return false }
        return next <= now && hours > 0 && connected && !metered && !busy
    }
    public func setSurface(_ id: UUID, radar: Bool?, menuBar: Bool) {
        if let radar { surfaces[id] = (radar, menuBar) }
        else { surfaces.removeValue(forKey: id) }
        refreshVisibility()
        if self.radar { bestScore = max(bestScore, radio?.score ?? 0) }
    }
    private func refreshVisibility() {
        radar = surfaces.values.contains { $0.radar }
        visible = surfaces.values.contains { $0.menuBar || NSApp.isActive }
    }
    public var guidance: String {
        guard let score = radio?.score else { return "Connect to Wi-Fi to start finding a better spot." }
        if score >= 85 { return "Great spot. Stay here." }
        if bestScore - score >= 10 { return "Go back. Your previous spot was stronger." }
        if score >= 65 { return "Getting warmer. Keep going." }
        return "Keep going. Try closer to the router."
    }
    public func requestLocation() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices")!) }
    }
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updateLocation(manager.authorizationStatus) }
    private func updateLocation(_ status: CLAuthorizationStatus) {
        locationAllowed = status == .authorizedAlways
        locationAsked = status != .notDetermined
    }
    private func startRadio() {
        guard radioTask == nil else { return }
        radioTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping {
                    let sample = await self.probe.radio()
                    self.radio = sample
                    if self.radar && self.visible, let score = sample.score {
                        self.signalHistory = Array((self.signalHistory + [Double(score)]).suffix(120))
                        self.bestScore = max(self.bestScore, score)
                        let direction = self.guidance
                        if self.speakDirections, direction != self.lastDirection, Date().timeIntervalSince(self.lastSpoken) > 5 {
                            self.lastDirection = direction; self.lastSpoken = Date()
                            let utterance = AVSpeechUtterance(string: direction)
                            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                            self.speech.speak(utterance)
                        }
                    }
                }
                let delay: Double = self.sleeping ? 2 : self.radar && self.visible ? 0.25 : self.visible ? 2 : 15
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    public func start() {
        startRadio()
        guard diagnosticTask == nil else { return }
        diagnosticTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping { await self.diagnose() }
                do { try await Task.sleep(for: .seconds(self.visible ? Double(max(12, self.checkInterval)) : ProcessInfo.processInfo.isLowPowerModeEnabled ? 120 : Double(max(60, self.checkInterval)))) } catch { return }
            }
        }
    }
    public func stop() { journal.suspend(); scheduleTask?.cancel(); speech.stopSpeaking(at: .immediate); radioTask?.cancel(); diagnosticTask?.cancel(); speedTask?.cancel(); radioTask = nil; diagnosticTask = nil }
    public func diagnose() async {
        guard !diagnosing, !sleeping else { return }
        diagnosing = true
        async let secondary = DiagnosticProbe.ping("8.8.8.8", count: 2)
        let sample = await probe.snapshot()
        let other = await secondary
        let fallback = sample.internet.average == nil && other.average == nil ? await NetworkJournal.httpFallback() : nil
        snapshot = sample; onSnapshot?(sample)
        await refreshExit()
        if !sleeping {
            journal.ingest(sample, secondary: other, httpReachable: fallback, interval: Double(max(60, checkInterval)))
            if automaticTrace, let incident = journal.events.last(where: { $0.kind == "Unreachable" && $0.end == nil }), tracedIncident != incident.id {
                tracedIncident = incident.id
                Task { [weak self] in
                    if let result = try? await ExpertTools.route(to: "1.1.1.1") { self?.survey.saveRoute(host: "1.1.1.1", output: "Automatic outage trace\n" + result) }
                }
            }
        }
        diagnosing = false
    }
    /// Reads the route and VPN list (local), asks Cloudflare for the public address when that's on and due,
    /// and logs a VPN going on or off and a changed public address.
    public func refreshExit(force: Bool = false) async {
        guard !lookingUp else { return }
        var path = await ExitPath.current()
        let network = snapshot?.networkKey
        // After a failed lookup (Cloudflare blocked, a captive portal) wait five minutes rather than retrying every check.
        let backingOff = lookupError != nil && lookupAttempt.map { Date().timeIntervalSince($0) < 300 } == true
        if force || (!backingOff && ExitPath.lookupDue(enabled: publicLookup, previous: exitPath, current: path, network: network, previousNetwork: exitNetwork)) {
            if publicLookup, path.interface != nil {
                lookingUp = true; lookupAttempt = Date(); defer { lookingUp = false }
                do { path.publicAddress = try await ExitPath.publicAddress(); lookupError = nil }
                catch { lookupError = "Couldn’t get the public IP: \(error.localizedDescription)" }
            }
        } else if path.interface == exitPath?.interface, path.vpn == exitPath?.vpn { path.publicAddress = exitPath?.publicAddress }
        // Lookup could have been turned off while Cloudflare answered.
        if !publicLookup { path.publicAddress = nil }
        for change in path.changes(since: exitPath) { journal.record(kind: change.kind, detail: change.detail, network: snapshot?.networkName ?? "Unknown network") }
        exitPath = path; exitNetwork = network
    }
    public func scan() async {
        guard !scanning else { return }
        guard locationAllowed else { error = "Enable Location access to scan nearby Wi-Fi networks. macOS uses this permission for Wi-Fi names and scanning."; return }
        scanning = true
        defer { scanning = false }
        do { networks = try await probe.scan(); survey.saveScan(networks) }
        catch { self.error = error.localizedDescription }
    }
    public func runSpeedTest(maximumBytes: Int = 80_000_000) {
        guard !speedRunning else { return }
        speedRunning = true
        speedPhase = .latency; speedFraction = 0; speedDown = nil; speedUp = nil
        speedDownHistory = []; speedUpHistory = []; speedStarted = Date(); speedBytes = 0
        let testedNetwork = snapshot
        speedTask = Task { [weak self] in
            guard let self else { return }
            defer { self.speedRunning = false }
            do {
                let result = try await SpeedTest.run(maximumBytes: maximumBytes, streams: self.speedStreams, updates: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.speedRunning else { return }
                        self.speedPhase = update.phase; self.speedFraction = update.fraction; self.speedBytes = update.bytes
                        if let rate = update.megabits {
                            if update.phase == .download { self.speedDown = rate; self.speedDownHistory.append(rate) }
                            if update.phase == .upload { self.speedUp = rate; self.speedUpHistory.append(rate) }
                        }
                    }
                }, progress: { [weak self] text in Task { @MainActor in self?.speedProgress = text } })
                self.lastSpeed = result
                self.journal.add(result, network: testedNetwork, networkChanged: testedNetwork?.networkKey != self.snapshot?.networkKey)
                if self.scheduleHours > 0 { self.nextScheduledTest = Date().addingTimeInterval(Double(self.scheduleHours) * 3600) }
                self.speedProgress = "Test complete."
            } catch is CancellationError { self.speedProgress = "Test cancelled." }
            catch { self.speedProgress = Task.isCancelled ? "Test cancelled." : error.localizedDescription }
        }
    }
    public func cancelSpeedTest() { speedTask?.cancel() }
    /// Runs a test, or waits for the one already running, and returns its result: for Shortcuts.
    public func speedTestResult(maximumBytes: Int = 80_000_000) async throws -> SpeedTestResult {
        let previous = lastSpeed?.date
        runSpeedTest(maximumBytes: maximumBytes)
        await speedTask?.value
        guard let result = lastSpeed, result.date != previous else { throw SpeedTestFailure(message: speedProgress) }
        return result
    }
    public func flushDNS() async {
        guard !flushingDNS else { return }
        flushingDNS = true; defer { flushingDNS = false }
        do { try await NetworkTools.flushDNS(); notice = "DNS cache flushed."; await diagnose() }
        catch { self.error = error.localizedDescription }
    }
    public func changeDNS(_ provider: DNSProvider) async {
        guard let service = snapshot?.networkService else { error = "Could not determine the current network service. Run diagnostics first."; return }
        guard !changingDNS else { return }
        changingDNS = true
        defer { changingDNS = false }
        do {
            try await DNSService.set(provider, service: service)
            notice = "\(service) now uses \(provider.rawValue) DNS."
            await diagnose()
        } catch { self.error = error.localizedDescription }
    }
    public var textReport: String {
        guard let snapshot else { return "No diagnostic sample yet. Run a check first." }
        return Self.report(snapshot, speed: speed)
    }
    public static func report(_ sample: DiagnosticSnapshot, speed: SpeedTestResult? = nil) -> String {
        func ms(_ number: Double?) -> String { number.map { String(format: "%.1f ms", $0) } ?? "Unavailable" }
        var lines = ["Kilobat · Network diagnostic", ISO8601DateFormatter().string(from: sample.date),
                     "Health: \(sample.health.rawValue)", "Network: \(sample.radio.ssid ?? "Name unavailable (Location permission may be required)")",
                     "Signal: \(sample.radio.rssi.map { "\($0) dBm" } ?? "Unavailable")",
                     "Noise: \(sample.radio.noise.map { "\($0) dBm" } ?? "Unavailable")",
                     "SNR: \(sample.radio.snr.map { "\($0) dB" } ?? "Unavailable")",
                     "Transmit rate: \(sample.radio.transmitMbps.map { String(format: "%.0f Mbps", $0) } ?? "Unavailable")",
                     "Channel: \(sample.radio.channel.map(String.init) ?? "Unavailable") · \(sample.radio.band ?? "Unknown band")",
                     "Router: \(sample.gateway ?? "Unknown") · \(ms(sample.router?.average))",
                     "Internet ICMP (1.1.1.1): \(ms(sample.internet.average))", "Jitter: \(ms(sample.internet.jitter))",
                     "Packet loss: \(sample.internet.lossPercent.map { "\($0)%" } ?? "Unavailable")",
                     "DNS lookup (example.com): \(ms(sample.dnsMilliseconds))", "Resolvers: \(sample.dnsServers.joined(separator: ", "))",
                     "Captive portal: \(sample.captivePortal.map { $0 ? "Suspected" : "Not detected" } ?? "Unknown")"]
        if let speed {
            lines += [String(format: "Speed: %.1f Mbps down / %.1f Mbps up", speed.downloadMbps, speed.uploadMbps), "Bufferbloat: \(speed.bufferbloat) · added latency \(ms(speed.addedLatency))"]
        }
        lines += ["", "Suggestions:"] + sample.advice.map { "• " + $0 }
        lines += ["", "A sample, not proof of root cause. ICMP may be blocked; Wi-Fi transmit rate is not internet speed."]
        return lines.joined(separator: "\n")
    }
    public func copyReport() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(textReport, forType: .string)
        reportNotice = "Report copied."; reportNoticeTask?.cancel()
        reportNoticeTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(3)); self?.reportNotice = nil } catch {} }
    }
}

/// A speed test that ended without a result, with the progress line that says why.
public struct SpeedTestFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}
