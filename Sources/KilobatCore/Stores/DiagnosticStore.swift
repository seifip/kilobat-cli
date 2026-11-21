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
    public var automaticTrace = UserDefaults.standard.object(forKey: "automaticOutageTrace") as? Bool ?? true { didSet { UserDefaults.standard.set(automaticTrace, forKey: "automaticOutageTrace") } }
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
    @ObservationIgnored private var refreshingExit = false
    @ObservationIgnored private var exitRefreshPending = false
    @ObservationIgnored private var routeRefresh: Task<Void, Never>?
    @ObservationIgnored private var routeWatch: RouteWatch?
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
    public let portalAlternative = PortalAlternative()
    /// Router check-up: whether the router has been getting slower over days, from the checks below.
    public let router = RouterWatch()
    /// Off in Lite, which has no router check-up: then no check is kept for it.
    public var watchesRouter = true
    /// Which mesh node or access point the Mac is on, and whether a much closer one is in range.
    public let nodes = NodeWatch()
    /// Off in Lite, which doesn't scan in the background.
    public var watchesNodes = true
    /// Fastest DNS: quiet resolver runs per network and, when the person turns it on (Pro), the switch on joining.
    public let fastestDNS = FastestDNSWatch()
    /// Off in Lite, which has neither the panel nor Kilobat's helper.
    public var watchesDNS = true
    /// This Mac's network ports' byte total at the previous check, for telling quiet checks from busy ones.
    private var lastPortBytes: (bytes: UInt64, date: Date)?
    @ObservationIgnored private(set) var networkRevision = 0
    public var snapshot: DiagnosticSnapshot? {
        didSet { if snapshot?.networkKey != oldValue?.networkKey { networkRevision &+= 1 } }
    }
    public let survey = SurveyJournal()
    /// Each network's devices with the person's names and answers, for the Devices tab and new-device alerts.
    public let knownDevices = DeviceRegistry()
    /// Connect your router: every device's usage from the router's own counters (Pro).
    public let homeUsage = HomeUsageStore()
    public var radio: RadioSample?
    public var networks: [NearbyNetwork] = []
    /// When `networks` was last scanned, so a room saved from Radar uses a fresh one.
    public private(set) var scannedAt: Date?
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
            // Health, Speed or Radar just came on screen: a check now when the last one is older than the fast interval.
            if visible && !oldValue { radioTask?.cancel(); radioTask = nil; startRadio(); checkPause?.cancel() }
        }
    }
    /// When the background loop last checked (or any check finished), and the loop's current wait, which a surface
    /// coming on screen cuts short so the next check is worked out again.
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private var checkPause: Task<Void, Never>?
    /// macOS's view of the path: nil until it first says, false while there is no usable path at all.
    @ObservationIgnored private var pathSatisfied: Bool?
    /// Checks in a row made while there was no path, for backing off.
    @ObservationIgnored private var offlineChecks = 0
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
    public var lastSpeedRecord: SavedSpeedTest? {
        guard let lastSpeed else { return nil }
        return journal.speedTests.last { $0.result.date == lastSpeed.date }
    }
    public private(set) var speedAttemptMessage: String?
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
    /// Bluetooth headphones playing, and what on the Wi-Fi side can make them crackle.
    public let bluetoothAudio = BluetoothAudioWatch()
    /// "Can I cast or print here?" for this network, and the device's own Wi-Fi the Mac may be on.
    public let localReach = LocalReachWatch()
    /// AirPlay or a cast tab, and what on the Mac's side can make it stutter.
    public let casting = CastingWatch()
    /// This Mac's Ethernet ports: the link each negotiated, what the adapter is, and whether it has a service.
    public let wired = WiredWatch()
    /// Whether IPv6 connects on this network: a finding after two failed readings, and a note on IPv6-only networks.
    public let ipv6 = IPv6Watch()
    /// Mounted network shares, and whether their servers still answer.
    public let shares = ShareWatch()
    private let probe = DiagnosticProbe()
    private let location = CLLocationManager()
    private var radioTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    /// Off in Lite: the wake watch runs a lookup and a web request after each wake.
    public var watchesWakes = true
    /// When the Mac went to sleep and the interface it was using, for the next wake's stage timing.
    private var sleptAt: Date?
    private var sleptInterface: (name: String?, wired: Bool)?
    private var wakeTask: Task<Void, Never>?

    public override init() {
        super.init()
        stutter.starlink = { [weak self] in self?.starlink.present ?? false }
        stutter.portal = { [weak self] in self?.portal.intercepting == true }
        // Every switch lands in History beside VPN and outage events.
        fastestDNS.onSwitch = { [weak self] change in
            let to = DNSResolverChoice.from(id: change.to)?.name ?? change.to, why = FastestDNS.describe(change.reason)
            let detail = change.to != DNSResolverChoice.network.id ? String(localized: "Kilobat switched DNS to \(to) (\(why)).", comment: "History: fastest DNS switch; resolver and reason")
                                                   : String(localized: "Kilobat put the network’s own DNS back (\(why)).", comment: "History: fastest DNS switched back; the reason")
            self?.journal.record(kind: "DNS", detail: detail, network: change.networkName, date: change.date)
        }
        // A share that went away goes in History, with an alert under Connection alerts.
        shares.onChange = { [weak self] check, gone in
            guard let self else { return }
            let network = self.snapshot?.networkName ?? String(localized: "This Mac")
            if gone {
                self.journal.record(kind: "Share not answering", detail: check.finding?.title ?? check.name, network: network)
                self.journal.alert(String(localized: "\(check.name) isn’t responding", comment: "Alert: a mounted network share's server went away; the share's name"),
                                   String(localized: "Finder and Save dialogs may freeze until it’s ejected. Eject it from Health.", comment: "Alert body for a network share that went away"))
            } else {
                self.journal.record(kind: "Share answering", detail: String(localized: "\(check.name) answers again.", comment: "History: a network share's server is back"), network: network)
            }
        }
        lastSpeed = journal.speedTests.last?.result
        nextScheduledTest = scheduleHours > 0 ? Date().addingTimeInterval(Double(scheduleHours) * 3600) : nil
        scheduleNetwork.start { [weak self] connected, metered, _ in
            Task { @MainActor in
                guard let self else { return }
                let returned = connected && self.pathSatisfied == false
                self.scheduleConnected = connected; self.scheduleMetered = metered; self.pathSatisfied = connected
                // The path is back: check now rather than at the end of an offline wait.
                if returned { self.lastCheck = .distantPast; self.checkPause?.cancel() }
            }
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
            Task { @MainActor in self?.journal.suspend(); self?.portal.interruptObservation(); self?.sleeping = true; self?.speedTask?.cancel(); self?.willSleep() }
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            let woke = Date()
            Task { @MainActor in self?.sleeping = false; self?.didWake(woke); await self?.diagnose() }
        })
    }
    private func willSleep() {
        wakeTask?.cancel(); wakeTask = nil
        sleptAt = Date()
        sleptInterface = snapshot.map { ($0.wiredInterface ?? $0.radio.interface, $0.wiredInterface != nil) }
    }
    /// Times each step of the connection coming back, then keeps it in the journal with the network it came back on.
    private func didWake(_ woke: Date) {
        guard watchesWakes else { return }
        let interface = sleptInterface, slept = sleptAt
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            var record = await WakeProbe.watch(woke: woke, slept: slept, interface: interface?.name, wired: interface?.wired ?? false)
            guard !Task.isCancelled, let self else { return }
            // The check started on waking has usually finished by now and names the network.
            for _ in 0..<100 where self.diagnosing { try? await Task.sleep(for: .milliseconds(100)) }
            if let snapshot = self.snapshot, snapshot.date >= woke {
                record.network = snapshot.networkName; record.networkKey = snapshot.networkIdentified ? snapshot.networkKey : nil
            }
            self.journal.addWake(record)
        }
    }
    static func scheduledTestDue(next: Date?, hours: Int, connected: Bool, metered: Bool, busy: Bool, now: Date = Date()) -> Bool {
        guard let next else { return false }
        return next <= now && hours > 0 && connected && !metered && !busy
    }
    public func setSurface(_ id: UUID, radar: Bool?, menuBar: Bool) {
        if let radar { surfaces[id] = (radar, menuBar) }
        else { surfaces.removeValue(forKey: id) }
        let wasVisible = visible
        refreshVisibility()
        if self.radar { bestScore = max(bestScore, radio?.score ?? 0) }
        // Opening a menu shows a fresh route, not the last periodic check's.
        if visible, !wasVisible || radar != nil, Date().timeIntervalSince(exitPath?.date ?? .distantPast) > 3 { Task { [weak self] in await self?.refreshExit() } }
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
        if routeWatch == nil {
            routeWatch = RouteWatch { [weak self] in Task { @MainActor in self?.routeDidChange() } }
            routeWatch?.start()
        }
        starlink.start(visible: { [weak self] in self?.visible ?? false }, network: { [weak self] in self?.snapshot?.networkKey })
        guard diagnosticTask == nil else { return }
        diagnosticTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.nextCheckDelay() - Date().timeIntervalSince(self.lastCheck)
                if wait > 0 { await self.pauseChecks(seconds: wait); continue }
                if !self.sleeping { await self.diagnose() }
                // Also when the check was skipped (asleep, or one already running): the wait starts again from now.
                self.lastCheck = Date()
            }
        }
    }
    private func nextCheckDelay() -> Double {
        let delay = Self.checkDelay(visible: visible, interval: checkInterval, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        return pathSatisfied == false && !visible && offlineChecks > 0 ? max(delay, Self.offlineDelay(failures: offlineChecks)) : delay
    }
    /// While macOS says there is no usable path: the first three checks keep the usual minute, so an outage is recorded
    /// as soon as before, then two minutes, then five, until the path comes back.
    nonisolated static func offlineDelay(failures: Int) -> Double { failures < 3 ? 60 : failures == 3 ? 120 : 300 }
    /// The gap the journal and the router watch should expect before this check: longer while backing off, so the
    /// longer waits aren't read as monitoring having paused. `offlineChecks` counts the offline checks before this one too.
    nonisolated static func expectedGap(offlineChecks: Int, interval: Int) -> Double {
        let usual = Double(max(60, interval))
        return offlineChecks > 0 ? max(usual, offlineDelay(failures: offlineChecks)) : usual
    }
    /// Seconds until the next background check: the person's interval while Health, Speed or Radar is on screen,
    /// a minute otherwise, two in Low Power Mode.
    nonisolated static func checkDelay(visible: Bool, interval: Int, lowPower: Bool) -> Double {
        visible ? Double(max(12, interval)) : lowPower ? 120 : Double(max(60, interval))
    }
    /// Waits `seconds`, or less when `checkPause` is cancelled because what's on screen changed.
    private func pauseChecks(seconds: Double) async {
        let pause = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        checkPause = pause
        await withTaskCancellationHandler { await pause.value } onCancel: { pause.cancel() }
        if checkPause == pause { checkPause = nil }
    }
    public func stop() { journal.suspend(); portal.interruptObservation(); scheduleTask?.cancel(); speech.stopSpeaking(at: .immediate); radioTask?.cancel(); diagnosticTask?.cancel(); speedTask?.cancel(); radioTask = nil; diagnosticTask = nil }
    /// The latest network proxy check. Runs only when asked: `diagnose` is on a timer, and this spends the person's data.
    public private(set) var proxyCheck: SplitProxyCheck?
    public private(set) var checkingProxy = false
    /// Whether the connection looks like one where the proxy check is worth offering.
    public var proxyCheckWorthOffering: Bool {
        guard let snapshot else { return false }
        return SplitProxyCheck.worthOffering(pingMs: snapshot.internet.average, dnsWorks: snapshot.dnsMilliseconds != nil, vpn: exitPath?.tunnel == true, portal: snapshot.captivePortal == true)
    }
    #if DEBUG
    public func previewProxyCheck(_ check: SplitProxyCheck?) { proxyCheck = check }
    #endif
    public func checkForNetworkProxy() async {
        guard !checkingProxy else { return }
        checkingProxy = true; defer { checkingProxy = false }
        let network = snapshot?.networkKey, vpn = exitPath?.tunnel == true, portal = snapshot?.captivePortal == true
        // Through a tunnel or a sign-in page the handshakes would time the wrong thing, and the data is spent for nothing.
        let hosts = vpn || portal ? [] : await SplitProxyProbe.measure()
        proxyCheck = SplitProxyCheck(network: network, hosts: hosts, vpn: vpn, portal: portal)
    }
    public func diagnose() async {
        guard !diagnosing, !sleeping else { return }
        diagnosing = true
        IdleCounters.bump(visible ? "check visible" : "check hidden")
        let offline = pathSatisfied == false
        let gap = Self.expectedGap(offlineChecks: offline ? offlineChecks + 1 : offlineChecks, interval: checkInterval)
        offlineChecks = offline ? offlineChecks + 1 : 0
        if offline { IdleCounters.bump("check offline") }
        let before = Self.portBytes(), started = Date()
        var sample = await probe.snapshot(checkPortal: false, offline: offline)
        let after = Self.portBytes(), finished = Date()
        let other = sample.secondary ?? PingResult(host: "8.8.8.8", samples: [], lossPercent: nil)
        let fallback = sample.httpReachable
        await checkPortal(&sample, internetFailed: fallback == false, reachable: sample.internet.average != nil || other.average != nil || fallback == true)
        if sample.wiredInterface == nil {
            let reachable = sample.internet.average != nil || other.average != nil || fallback == true
            sample.setupNetwork = SetupNetworks.judge(ssid: sample.radio.ssid, gateway: sample.gateway, internetReachable: reachable)
        }
        snapshot = sample; onSnapshot?(sample)
        localReach.observe(sample, portal: portal.record != nil)
        await refreshExit()
        // Each throttles itself; neither waits for the other or holds up the next check.
        Task { [weak self] in await self?.wired.refresh() }
        Task { [weak self] in await self?.shares.refresh() }
        Task { [weak self] in await self?.checkIPv6() }
        if !sleeping {
            journal.ingest(sample, secondary: other, httpReachable: fallback, interval: gap)
            let since = lastPortBytes.flatMap { last in after.map { ($0 >= last.bytes ? $0 - last.bytes : 0, finished.timeIntervalSince(last.date)) } }
            let busy = speedRunning || RouterWatch.busy(checkBytes: before.flatMap { b in after.map { $0 >= b ? $0 - b : 0 } } ?? 0, checkSeconds: finished.timeIntervalSince(started),
                                                        sinceBytes: since?.0, sinceSeconds: since?.1)
            lastPortBytes = after.map { ($0, finished) }
            // A device's own Wi-Fi has no internet by design: nothing there to judge a router, mesh or DNS by.
            let device = sample.setupNetwork != nil
            if watchesRouter && !device { await router.observe(sample, busy: busy, interval: gap) }
            if watchesNodes && !device { await nodes.observe(sample, locationAllowed: locationAllowed) }
            if watchesDNS && !device { await fastestDNS.observe(dnsContext(sample, secondary: other, busy: busy)) }
            if automaticTrace, let incident = journal.events.last(where: { $0.kind == "Unreachable" && $0.end == nil }), tracedIncident != incident.id {
                tracedIncident = incident.id
                Task { [weak self] in
                    if let result = try? await ExpertTools.route(to: "1.1.1.1", options: .background) { self?.survey.saveRoute(host: "1.1.1.1", output: "Automatic outage trace\n" + result) }
                }
            }
        }
        lastCheck = Date()
        diagnosing = false
    }
    /// Reads IPv6 on this network; `forced` (Test again) opens the connections now.
    public func checkIPv6(forced: Bool = false) async {
        guard let snapshot else { return }
        await ipv6.observe(network: snapshot.networkKey, portal: snapshot.captivePortal == true, metered: metered?() ?? true, forced: forced)
    }
    /// Looks for the network's sign-in page when PortalWatch says it's due, and marks the sample with what it knows.
    private func checkPortal(_ sample: inout DiagnosticSnapshot, internetFailed: Bool, reachable: Bool) async {
        let key = sample.networkKey
        let wifi = sample.wiredInterface == nil && sample.gateway != nil
        portalAlternative.context(network: key, identified: sample.networkIdentified, wifi: wifi, reachable: reachable)
        let alternative = portalAlternative.enabled(for: key, identified: sample.networkIdentified)
        if portal.due(network: key, internetFailed: internetFailed) || (portalAlternative.needsRetry && reachable) {
            let check = await CaptivePortal.check(useAlternative: alternative)
            portal.observe(check, network: key, name: sample.networkName, identified: sample.networkIdentified)
            portalAlternative.observe(check, normal: !alternative && !UserDefaults.standard.bool(forKey: "network.chinaPortalFallback"), reachable: reachable, wifi: wifi)
        }
        portal.tick()
        sample.captivePortal = portal.intercepting
        if portal.loggedOut, sample.captivePortal == true { sample.portalLoggedOut = true }
    }
    /// What Fastest DNS needs from a check: the network, whether lookups and the network work, and the guards' inputs.
    /// Any VPN counts, split ones too: they bring their own DNS for their domains.
    private func dnsContext(_ sample: DiagnosticSnapshot, secondary: PingResult, busy: Bool) -> FastestDNSWatch.Context {
        let network = sample.networkIdentified ? sample.networkKey : nil
        let vpn = exitPath.map { $0.vpn != .off } ?? false
        let moment = FastestDNS.Moment(network: network, identified: sample.networkIdentified, connected: sample.gateway != nil, metered: metered?() ?? true,
                                       vpn: vpn, portal: portal.intercepting == true, busy: busy || speedRunning, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        return FastestDNSWatch.Context(network: network, name: sample.networkName, service: sample.networkService, interface: sample.wiredInterface ?? sample.radio.interface,
                                       gateway: sample.gateway, resolvers: sample.dnsServers, lookupWorked: sample.dnsMilliseconds != nil,
                                       networkUp: sample.router?.average != nil || sample.internet.average != nil || secondary.average != nil, moment: moment)
    }
    /// Bytes this Mac's Wi-Fi and Ethernet ports have carried, both ways.
    private static func portBytes() -> UInt64? {
        InterfaceCounters.read().map { counters in counters.filter { $0.key.hasPrefix("en") }.values.reduce(0) { $0 &+ $1.total } }
    }
    /// Reads the route and VPN list (local), asks Cloudflare for the public address when that's on and due,
    /// and logs a VPN going on or off and a changed public address.
    /// `routeChanged`: macOS just reported a new route or tunnel, so the public address may have moved even on the same tunnel.
    public func refreshExit(force: Bool = false, routeChanged: Bool = false) async {
        guard !refreshingExit else { exitRefreshPending = true; return }
        refreshingExit = true
        defer {
            refreshingExit = false
            if exitRefreshPending { exitRefreshPending = false; Task { [weak self] in await self?.refreshExit(routeChanged: true) } }
        }
        let before = exitPath, previousNetwork = exitNetwork
        var path = await ExitPath.current()
        // A VPN that seems to have gone must still be gone a moment later: one failed read or a brief reconnect isn't "off".
        var confirmations = 0
        while ExitPath.lostTunnel(previous: before, current: path), confirmations < 2 {
            confirmations += 1
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            path = await ExitPath.current()
        }
        let network = snapshot?.networkKey
        // After a failed lookup (Cloudflare blocked, a captive portal) wait five minutes rather than retrying every check.
        let backingOff = lookupError != nil && lookupAttempt.map { Date().timeIntervalSince($0) < 300 } == true
        let moved = routeChanged && lookupAttempt.map { Date().timeIntervalSince($0) >= 10 } != false
        let due = publicLookup && path.interface != nil
            && (force || (!backingOff && (moved || ExitPath.lookupDue(enabled: publicLookup, previous: before, current: path, network: network, previousNetwork: previousNetwork))))
        if path.interface == before?.interface, path.vpn == before?.vpn { path.publicAddress = before?.publicAddress }
        // Lookup could have been turned off while the route was read.
        if !publicLookup { path.publicAddress = nil }
        // The route shows at once; Cloudflare's answer can take seconds and follows when it comes.
        exitPath = path; exitNetwork = network
        if due {
            lookingUp = true; lookupAttempt = Date(); defer { lookingUp = false }
            do {
                let address = try await ExitPath.publicAddress(); lookupError = nil
                if publicLookup, exitPath?.interface == path.interface { path.publicAddress = address; exitPath?.publicAddress = address }
            } catch { lookupError = String(localized: "Couldn’t get the public IP: \(error.localizedDescription)") }
        }
        for change in path.changes(since: before) { journal.record(kind: change.kind, detail: change.detail, network: snapshot?.networkName ?? "Unknown network") }
    }
    /// A route change arrives as a burst of notifications: one read, shortly after the last of them.
    private func routeDidChange() {
        routeRefresh?.cancel()
        routeRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            await self?.refreshExit(routeChanged: true)
        }
    }
    public func scan() async {
        guard !scanning else { return }
        guard locationAllowed else { error = String(localized: "Enable Location access to scan nearby Wi-Fi networks. macOS uses this permission for Wi-Fi names and scanning."); return }
        scanning = true
        defer { scanning = false }
        do { networks = try await probe.scan(); scannedAt = Date(); survey.saveScan(networks) }
        catch { self.error = error.localizedDescription }
    }
    /// `streams` overrides the Single or Parallel choice; `scheduled` marks a test Kilobat started on its own.
    public func runSpeedTest(maximumBytes: Int = 80_000_000, streams: Int? = nil, scheduled: Bool = false, planCheck: Bool = false) {
        guard !speedRunning else { return }
        if planCheck {
            guard let key = snapshot?.networkKey, key != "unknown",
                  journal.reservePlanCheck(network: key, maximumBytes: maximumBytes) else { return }
        }
        speedRunning = true
        speedAttemptMessage = nil
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
                self.journal.add(result, network: testedNetwork, networkChanged: testedNetwork?.networkKey != self.snapshot?.networkKey, scheduled: scheduled, reservedAttempt: planCheck ? true : nil)
                if self.scheduleHours > 0 { self.nextScheduledTest = Date().addingTimeInterval(Double(self.scheduleHours) * 3600) }
                self.speedProgress = String(localized: "Test complete.")
            } catch is CancellationError {
                self.speedProgress = String(localized: "Test cancelled.")
                self.speedAttemptMessage = self.speedProgress
            }
            catch {
                // The internet check doesn't touch the test host, so it can tell "offline" from "this server is blocked".
                let reach = self.snapshot?.reachability
                let up: Bool? = reach == .up ? true : reach == .down ? false : nil
                let kind = SpeedTest.failureKind(error: error, internetReachable: up, bytesTransferred: self.speedBytes)
                if Task.isCancelled || kind == .cancelled { self.speedProgress = String(localized: "Test cancelled.") }
                else {
                    // With the reachability unknown, say what the error said rather than claim a verdict.
                    self.speedProgress = (up == nil ? nil : SpeedTest.failureMessage(kind)) ?? error.localizedDescription
                    if scheduled, up == true, kind == .serverUnreachable {
                        self.journal.record(kind: "Speed test server unreachable", detail: SpeedTest.failureMessage(kind) ?? "", network: testedNetwork?.networkName ?? "Unknown network")
                    }
                }
                self.speedAttemptMessage = self.speedProgress
            }
        }
    }
    public func automaticSpeedTestBytes() async throws -> Int {
        for _ in 0..<20 where metered == nil { try await Task.sleep(for: .milliseconds(250)) }
        return ((metered?() ?? true) ? 10 : 80) * 1_000_000
    }
    public func cancelSpeedTest() { speedTask?.cancel() }
    /// Runs a test, or waits for the one already running, and returns its result: for Shortcuts.
    public func speedTestResult(maximumBytes: Int = 80_000_000) async throws -> SpeedTestResult {
        let previous = lastSpeed?.date
        runSpeedTest(maximumBytes: maximumBytes)
        await speedTask?.value
        guard let result = lastSpeed, result.date != previous else { throw SpeedTestFailure(message: speedAttemptMessage ?? speedProgress) }
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
    /// The person's pick in Health › DNS. Network DNS over Kilobat's own switch is Undo: back through the helper,
    /// without a password, and the fastest-DNS switch off on this network so it stays that way.
    public func changeDNS(_ choice: DNSResolverChoice) async {
        guard let service = snapshot?.networkService else { error = String(localized: "Could not determine the current network service. Run diagnostics first."); return }
        guard !changingDNS else { return }
        changingDNS = true
        defer { changingDNS = false }
        if choice.isNetwork, fastestDNS.applied != nil {
            await fastestDNS.undo()
            if fastestDNS.applied == nil { notice = String(localized: "\(service) now uses Network DNS.") }
            await diagnose()
            return
        }
        do {
            try await DNSService.set(choice, service: service)
            notice = choice.isNetwork ? String(localized: "\(service) now uses Network DNS.") : String(localized: "\(service) now uses \(choice.name) for DNS.")
            await diagnose()
        } catch { self.error = error.localizedDescription }
    }
    public var textReport: String {
        guard let snapshot else { return String(localized: "No diagnostic sample yet. Run a check first.") }
        return Self.report(snapshot, speed: speed)
    }
    public static func report(_ sample: DiagnosticSnapshot, speed: SpeedTestResult? = nil) -> String {
        let unavailable = String(localized: "Unavailable")
        func ms(_ number: Double?) -> String { number.map { String(format: "%.1f ms", locale: Locale.current, $0) } ?? unavailable }
        let radio = sample.radio, health = sample.health.rawValue
        let network = radio.ssid ?? String(localized: "Name unavailable (Location permission may be required)")
        let signal = radio.rssi.map { $0.formatted() + " dBm" } ?? unavailable, noise = radio.noise.map { $0.formatted() + " dBm" } ?? unavailable, snr = radio.snr.map { $0.formatted() + " dB" } ?? unavailable
        let rate = radio.transmitMbps.map { String(format: "%.0f Mbps", locale: Locale.current, $0) } ?? unavailable
        let channel = radio.channel.map { $0.formatted() } ?? unavailable, band = radio.band ?? String(localized: "Unknown band")
        let router = sample.gateway ?? String(localized: "Unknown"), loss = sample.internet.lossPercent.map { $0.formatted(.percent.scale(1)) } ?? unavailable
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
            let down = String(format: "%.1f", locale: Locale.current, speed.downloadMbps), up = String(format: "%.1f", locale: Locale.current, speed.uploadMbps), bufferbloat = speed.bufferbloat
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
