import Foundation

/// The call engine's measurements, for calls and for SSH and remote desktop sessions alike: a ping a second to the
/// internet and to the router, the busiest other app each second, the Mac's load every five seconds, the router's
/// counters for other devices, paired Macs' own reports, the Wi-Fi's sign-in page, the Wi-Fi signal, AirDrop and a
/// Starlink dish while one answers.
@MainActor final class LineSampler {
    private(set) var samples = CallSamples()
    let start: Date
    private let consumer = UUID()
    private var networkKey: String?
    private var networkName: String?
    private var mixedNetworks = false
    private var finished = false
    var reportNetwork: (String, String)? {
        guard !mixedNetworks, let networkKey, networkKey != "unknown", let networkName else { return nil }
        return (networkKey, networkName)
    }
    private var internet: PingStream?
    private var router: PingStream?
    private var ticks: MacLoad.Ticks?
    private var lastLoad = Date.distantPast
    private var routerControl: String?
    private var routerLast: RouterReading?
    private var lastRouterRead = Date.distantPast
    private var lastAirDropCheck = Date.distantPast
    private weak var starlink: StarlinkStore?
    private var lastDish: Date?
    private let peers: () -> [HouseholdLive]
    private var lastPeers = Date.distantPast
    private weak var homeUsage: HomeUsageStore?
    private var lastRouterPoll: Date?
    private var lastLine: Date?

    init(start: Date, starlink: StarlinkStore?, peers: @escaping () -> [HouseholdLive] = { [] }) {
        self.start = start; self.starlink = starlink; self.peers = peers
    }

    func begin(diagnostics: DiagnosticStore) async {
        guard !finished else { return }
        networkKey = diagnostics.snapshot?.networkKey
        networkName = diagnostics.snapshot?.networkName
        internet = PingStream(target: "internet", start: start); router = PingStream(target: "router", start: start)
        await internet?.start(); await router?.start()
        guard !finished else { return }
        // A connected router is read every 10 s while the call lasts.
        homeUsage = diagnostics.homeUsage
        homeUsage?.need(.call, true, consumer: consumer)
        if let snapshot = diagnostics.snapshot, let gateway = snapshot.gateway {
            let key = snapshot.networkKey
            Task { if let control = await CallStore.routerCounters(network: key, gateway: gateway) { self.routerControl = control; self.samples.household = [] } }
        }
    }

    /// One second of the line. `own` picks out the traffic that is the call's or session's own, so it is never blamed.
    func record(traffic: TrafficStore, diagnostics: DiagnosticStore, own: (AppTraffic) -> Bool, now: Date) {
        guard !finished else { return }
        if diagnostics.snapshot?.networkKey != networkKey || (traffic.networkKey != "unknown" && traffic.networkKey != networkKey) { mixedNetworks = true }
        guard !mixedNetworks else { return }
        let at = now.timeIntervalSince(start)
        let others = traffic.apps.filter { !$0.carrier && !own($0) }
        if let top = others.max(by: { $0.rate < $1.rate }), top.rate > 0 {
            samples.traffic.append(.init(at: at, app: top.name, upload: top.uploadRate, download: top.downloadRate))
        }
        if diagnostics.snapshot?.radio.health == .poor { samples.weakSignal.append(at) }
        if let stuck = diagnostics.nodes.report?.stuck {
            samples.farNode.append(at)
            if samples.farNodes == nil { samples.farNodes = .init(node: stuck.node.name, better: stuck.better.name, rssi: stuck.rssi, betterRSSI: stuck.betterRSSI) }
        }
        if samples.loggedOut == nil, case .loggedOut(let since) = diagnostics.portal.status { samples.loggedOut = max(0, since.timeIntervalSince(start)) }
        if let starlink, let status = starlink.status, status.date != lastDish, starlink.present {
            starlink.watch(for: consumer, active: true); lastDish = status.date
            if let sample = CallSamples.Dish(status: status, start: start) { samples.dish.append(sample) }
        }
        if now.timeIntervalSince(lastLoad) >= 5 {
            lastLoad = now
            samples.audioChecks += 1
            if let check = diagnostics.bluetoothAudio.check, check.output.playing {
                samples.bluetoothAudio.append(.init(at: at, device: check.output.name, microphone: check.output.microphone, risks: check.risks, reported: check.reported))
            }
            if let previous = ticks { Task { if let (load, next) = await MacLoad.sample(since: previous) { self.ticks = next; self.samples.load.append(.init(at: at, load: load)) } } }
            else { ticks = MacLoad.ticks() }
        }
        if let control = routerControl, now.timeIntervalSince(lastRouterRead) >= 5 {
            lastRouterRead = now
            let mac = traffic.apps.filter { !$0.carrier }.reduce((up: 0.0, down: 0.0)) { ($0.up + $1.uploadRate, $0.down + $1.downloadRate) }
            Task {
                guard let reading = try? await RouterCounters.read(controlURL: control) else { return }
                defer { self.routerLast = reading }
                guard let last = self.routerLast, reading.date > last.date, reading.received >= last.received, reading.sent >= last.sent else { return }
                let seconds = reading.date.timeIntervalSince(last.date)
                let down = Double(reading.received - last.received) / seconds, up = Double(reading.sent - last.sent) / seconds
                self.samples.household?.append(.init(at: at, upload: max(0, up - mac.up), download: max(0, down - mac.down)))
            }
        }
        if now.timeIntervalSince(lastPeers) >= 3 {
            lastPeers = now
            let live = peers().filter { $0.fresh(now: now) }
            for peer in live {
                samples.peers.append(.init(at: peer.received.timeIntervalSince(start), name: peer.summary.name, upload: peer.summary.up, download: peer.summary.down, app: peer.summary.apps.first))
            }
            recordRouter(traffic: traffic, peers: live)
        }
        if now.timeIntervalSince(lastAirDropCheck) >= 30 {
            lastAirDropCheck = now
            Task { if await NearbyRadios.awdlStatus().active { self.samples.airDrop = true } }
        }
    }

    /// Each new read of a connected router: every other device's rates, named, and a paired Mac's busiest app beside
    /// it. Without UPnP counters the router's line, minus this Mac, stands in for them.
    private func recordRouter(traffic: TrafficStore, peers: [HouseholdLive]) {
        guard let homeUsage else { return }
        if let reading = homeUsage.deviceRates(), reading.date != lastRouterPoll {
            lastRouterPoll = reading.date
            samples.routerPerDevice = true
            let at = reading.date.timeIntervalSince(start)
            for device in reading.devices where device.down + device.up > 0 {
                let peer = device.address.flatMap { address in peers.first { $0.address == address } }
                samples.routerDevices.append(.init(at: at, mac: device.mac, name: device.name ?? peer?.summary.name, upload: device.up, download: device.down,
                                                   app: peer?.summary.apps.first))
            }
        }
        if routerControl == nil, let line = homeUsage.lineRate(), line.date != lastLine {
            lastLine = line.date
            let mac = traffic.apps.filter { !$0.carrier }.reduce((up: 0.0, down: 0.0)) { ($0.up + $1.uploadRate, $0.down + $1.downloadRate) }
            if samples.household == nil { samples.household = [] }
            samples.household?.append(.init(at: line.date.timeIntervalSince(start), upload: max(0, line.up - mac.up), download: max(0, line.down - mac.down)))
        }
    }
    /// The internet pings so far, for a live readout.
    func recentInternet() async -> [CallSamples.Ping] { await internet?.current() ?? [] }

    /// Stops the pings. For a report it also reads the dish's outage log and the devices that joined around it.
    func finish(report: Bool, end: Date, diagnostics: DiagnosticStore?) async -> CallSamples {
        finished = true
        if let diagnostics, diagnostics.snapshot?.networkKey != networkKey { mixedNetworks = true }
        let internet = self.internet, router = self.router
        self.internet = nil; self.router = nil
        homeUsage?.need(.call, false, consumer: consumer)
        starlink?.watch(for: consumer, active: false); lastDish = nil
        samples.internet = await internet?.stop() ?? []; samples.router = await router?.stop() ?? []
        guard !mixedNetworks else { return unscopedSamples() }
        guard report else { return samples }
        // The dish's own log has each outage to the second, with its cause.
        if starlink?.present == true, diagnostics?.snapshot?.networkKey == networkKey, let history = await Starlink.history() {
            if diagnostics?.snapshot?.networkKey != networkKey { mixedNetworks = true; return unscopedSamples() }
            samples.dish += history.outages.compactMap { CallSamples.Dish(outage: $0, start: start) }
        }
        // Devices that joined around it, so a freeze the router blames on another device can name it.
        if let key = networkKey, diagnostics?.snapshot?.networkKey == key,
           let devices = diagnostics?.knownDevices, devices.isHome(key) {
            devices.reload()
            samples.arrivals = devices.book.arrivals(network: key, from: start.addingTimeInterval(-CallAnalysis.joinWindow), to: end)
                .map { .init(at: $0.arrived.timeIntervalSince(start), name: $0.callName) }
            samples.cameras = CameraUpload.cameras(devices.devices(on: key), router: devices.book.networks[key]?.router)
            if !samples.cameras.isEmpty { samples.deviceUsage = DeviceUsage.window(network: key, from: start, to: end) }
        }
        return samples
    }
    /// Internet probes still describe the session when it changes networks. The original router and
    /// network-specific evidence cannot explain the entire session.
    private func unscopedSamples() -> CallSamples {
        var result = CallSamples()
        result.internet = samples.internet
        return result
    }

}
