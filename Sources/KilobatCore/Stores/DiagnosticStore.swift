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
    /// The network's sign-in page, when it has one, and how long a sign-in lasts there.
    public let portal = PortalWatch()
    public var snapshot: DiagnosticSnapshot?
    public let survey = SurveyJournal()
    /// Each network's devices with the person's names and answers, for the Devices tab and new-device alerts.
    public let knownDevices = DeviceRegistry()
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
    public var speedProgress = String(localized: "Ready when you are.")
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
    /// A Starlink dish on this network, when one answers.
    public let starlink = StarlinkStore()
    public let games = GameServerStore()
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
        stutter.starlink = { [weak self] in self?.starlink.present ?? false }
        stutter.portal = { [weak self] in self?.portal.intercepting == true }
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
                    self.runSpeedTest(scheduled: true)
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
        guard let score = radio?.score else { return String(localized: "Connect to Wi-Fi to start finding a better spot.") }
        if score >= 85 { return String(localized: "Great spot. Stay here.") }
        if bestScore - score >= 10 { return String(localized: "Go back. Your previous spot was stronger.") }
        if score >= 65 { return String(localized: "Getting warmer. Keep going.") }
        return String(localized: "Keep going. Try closer to the router.")
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
        starlink.start(visible: { [weak self] in self?.visible ?? false }, network: { [weak self] in self?.snapshot?.networkKey })
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
        var sample = await probe.snapshot(checkPortal: false)
        let other = await secondary
        let fallback = sample.internet.average == nil && other.average == nil ? await NetworkJournal.httpFallback() : nil
        await checkPortal(&sample, internetFailed: fallback == false)
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
    /// Looks for the network's sign-in page when PortalWatch says it's due, and marks the sample with what it knows.
    private func checkPortal(_ sample: inout DiagnosticSnapshot, internetFailed: Bool) async {
        let key = sample.networkKey
        if portal.due(network: key, internetFailed: internetFailed) {
            portal.observe(await CaptivePortal.check(), network: key, name: sample.networkName, identified: sample.networkIdentified)
        }
        portal.tick()
        sample.captivePortal = portal.intercepting
        if portal.loggedOut, sample.captivePortal == true { sample.portalLoggedOut = true }
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
                catch { lookupError = String(localized: "Couldn’t get the public IP: \(error.localizedDescription)") }
            }
        } else if path.interface == exitPath?.interface, path.vpn == exitPath?.vpn { path.publicAddress = exitPath?.publicAddress }
        // Lookup could have been turned off while Cloudflare answered.
        if !publicLookup { path.publicAddress = nil }
        for change in path.changes(since: exitPath) { journal.record(kind: change.kind, detail: change.detail, network: snapshot?.networkName ?? "Unknown network") }
        exitPath = path; exitNetwork = network
    }
    public func scan() async {
        guard !scanning else { return }
        guard locationAllowed else { error = String(localized: "Enable Location access to scan nearby Wi-Fi networks. macOS uses this permission for Wi-Fi names and scanning."); return }
        scanning = true
        defer { scanning = false }
        do { networks = try await probe.scan(); survey.saveScan(networks) }
        catch { self.error = error.localizedDescription }
    }
    /// `streams` overrides the Single or Parallel choice; `scheduled` marks a test Kilobat started on its own.
    public func runSpeedTest(maximumBytes: Int = 80_000_000, streams: Int? = nil, scheduled: Bool = false) {
        guard !speedRunning else { return }
        speedRunning = true
        speedPhase = .latency; speedFraction = 0; speedDown = nil; speedUp = nil
        speedDownHistory = []; speedUpHistory = []; speedStarted = Date(); speedBytes = 0
        let testedNetwork = snapshot
        speedTask = Task { [weak self] in
            guard let self else { return }
            defer { self.speedRunning = false }
            do {
                let result = try await SpeedTest.run(maximumBytes: maximumBytes, streams: streams ?? self.speedStreams, updates: { [weak self] update in
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
                self.journal.add(result, network: testedNetwork, networkChanged: testedNetwork?.networkKey != self.snapshot?.networkKey, scheduled: scheduled)
                if self.scheduleHours > 0 { self.nextScheduledTest = Date().addingTimeInterval(Double(self.scheduleHours) * 3600) }
                self.speedProgress = String(localized: "Test complete.")
            } catch is CancellationError { self.speedProgress = String(localized: "Test cancelled.") }
            catch { self.speedProgress = Task.isCancelled ? String(localized: "Test cancelled.") : error.localizedDescription }
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

    #if DEBUG
    /// Made-up results for App Store screenshots; debug builds only.
    public func preview(speed: SpeedTestResult?, exit: ExitPath?) { lastSpeed = speed; exitPath = exit }
    #endif
    public func flushDNS() async {
        guard !flushingDNS else { return }
        flushingDNS = true; defer { flushingDNS = false }
        do { try await NetworkTools.flushDNS(); notice = String(localized: "DNS cache flushed."); await diagnose() }
        catch { self.error = error.localizedDescription }
    }
    public func changeDNS(_ provider: DNSProvider) async {
        guard let service = snapshot?.networkService else { error = String(localized: "Could not determine the current network service. Run diagnostics first."); return }
        guard !changingDNS else { return }
        changingDNS = true
        defer { changingDNS = false }
        do {
            try await DNSService.set(provider, service: service)
            notice = String(localized: "\(service) now uses \(provider.rawValue) DNS.")
            await diagnose()
        } catch { self.error = error.localizedDescription }
    }
    public var textReport: String {
        guard let snapshot else { return String(localized: "No diagnostic sample yet. Run a check first.") }
        return Self.report(snapshot, speed: speed)
    }
    public static func report(_ sample: DiagnosticSnapshot, speed: SpeedTestResult? = nil) -> String {
        let unavailable = String(localized: "Unavailable")
        func ms(_ number: Double?) -> String { number.map { String(format: "%.1f ms", $0) } ?? unavailable }
        let radio = sample.radio, health = sample.health.rawValue
        let network = radio.ssid ?? String(localized: "Name unavailable (Location permission may be required)")
        let signal = radio.rssi.map { "\($0) dBm" } ?? unavailable, noise = radio.noise.map { "\($0) dBm" } ?? unavailable, snr = radio.snr.map { "\($0) dB" } ?? unavailable
        let rate = radio.transmitMbps.map { String(format: "%.0f Mbps", $0) } ?? unavailable
        let channel = radio.channel.map(String.init) ?? unavailable, band = radio.band ?? String(localized: "Unknown band")
        let router = sample.gateway ?? String(localized: "Unknown"), loss = sample.internet.lossPercent.map { "\($0)%" } ?? unavailable
        let resolvers = sample.dnsServers.joined(separator: ", ")
        let portal = sample.captivePortal.map { $0 ? String(localized: "Suspected", comment: "A captive portal") : String(localized: "Not detected", comment: "A captive portal") } ?? String(localized: "Unknown")
        var lines = [String(localized: "Kilobat · Network diagnostic"), ISO8601DateFormatter().string(from: sample.date),
                     String(localized: "Health: \(health)"), String(localized: "Network: \(network)"),
                     String(localized: "Signal: \(signal)"),
                     String(localized: "Noise: \(noise)"),
                     String(localized: "SNR: \(snr)"),
                     String(localized: "Transmit rate: \(rate)"),
                     String(localized: "Channel: \(channel) · \(band)"),
                     String(localized: "Router: \(router) · \(ms(sample.router?.average))"),
                     String(localized: "Internet ICMP (1.1.1.1): \(ms(sample.internet.average))"), String(localized: "Jitter: \(ms(sample.internet.jitter))"),
                     String(localized: "Packet loss: \(loss)"),
                     String(localized: "DNS lookup (example.com): \(ms(sample.dnsMilliseconds))"), String(localized: "Resolvers: \(resolvers)"),
                     String(localized: "Captive portal: \(portal)")]
        if let speed {
            let down = String(format: "%.1f", speed.downloadMbps), up = String(format: "%.1f", speed.uploadMbps), bufferbloat = speed.bufferbloat
            lines += [String(localized: "Speed: \(down) Mbps down / \(up) Mbps up"), String(localized: "Bufferbloat: \(bufferbloat) · added latency \(ms(speed.addedLatency))")]
        }
        // The advice is stored English (the app matches it by its opening words); the app's catalog translates it.
        lines += ["", String(localized: "Suggestions:")] + sample.advice.map { "• " + Bundle.main.localizedString(forKey: $0, value: $0, table: nil) }
        lines += ["", String(localized: "A sample, not proof of root cause. ICMP may be blocked; Wi-Fi transmit rate is not internet speed.")]
        return lines.joined(separator: "\n")
    }
    public func copyReport() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(textReport, forType: .string)
        reportNotice = String(localized: "Report copied."); reportNoticeTask?.cancel()
        reportNoticeTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(3)); self?.reportNotice = nil } catch {} }
    }
}

/// A speed test that ended without a result, with the progress line that says why.
public struct SpeedTestFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}
