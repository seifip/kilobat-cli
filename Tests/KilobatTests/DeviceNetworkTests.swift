import Foundation
import Testing
@testable import KilobatCore

/// Working with a Wi-Fi device: device network names, the internet priority switch's service order, the isolation
/// verdicts, the link to the device, the finder and saved devices.
struct DeviceNetworkTests {
    // MARK: Device networks

    @Test func everyFamilyHasAKindWithAnIcon() {
        for rule in SetupNetworks.rules {
            #expect(!rule.kind.symbol.isEmpty, "\(rule.id)")
            #expect(rule.source.hasPrefix("https://"), "\(rule.id)")
        }
        // Each kind names its own icon, so no two families read as the same device.
        let symbols = SetupDeviceKind.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(SetupNetworks.match(ssid: "GO2-8A2C1F")?.symbol == "robot")
        #expect(SetupNetworks.match(ssid: "TELLO-5A1B2C")?.symbol == "drone")
        #expect(SetupNetworks.match(ssid: "ITEAD-1000A1B2C3")?.symbol == "switch.2")
        #expect(SetupNetworks.match(ssid: "Tapo_Cam_1A2B")?.symbol == "web.camera")
        #expect(SetupNetworks.match(ssid: "DIRECT-Q7-Lounge")?.symbol == "devices")
    }

    @Test func robotsAndRelaysSaySo() {
        #expect(SetupNetworks.match(ssid: "GO2-8A2C1F")!.headline == "You’re on your Unitree robot’s own Wi-Fi; there’s no internet here, by design.")
        #expect(SetupNetworks.match(ssid: "GO2-8A2C1F")!.detail(previous: nil).hasPrefix("Control it from its app or a browser."))
        #expect(SetupNetworks.match(ssid: "ITEAD-1000A1B2C3")!.headline == "You’re on a Sonoff smart switch’s setup Wi-Fi; there’s no internet here, by design.")
        #expect(SetupNetworks.match(ssid: "TP-LINK_Smart Plug_1A2B")!.headline == "You’re on a Kasa smart plug’s setup Wi-Fi; there’s no internet here, by design.")
    }

    @Test func savedDevicesCountAsDeviceNetworks() {
        let saved: [String: (kind: SetupDeviceKind, name: String)] = ["Rover AP": (.robot, "Rover"), "GP24500702": (.actionCamera, "Helmet cam")]
        let rover = SetupNetworks.judge(ssid: "Rover AP", gateway: "192.168.12.1", internetReachable: false, saved: saved)
        #expect(rover?.kind == .robot && rover?.rule == "saved" && rover?.name == "Rover")
        #expect(rover?.headline == "You’re on Rover’s own Wi-Fi; there’s no internet here, by design.")
        // The person's name wins over the table.
        #expect(SetupNetworks.judge(ssid: "GP24500702", gateway: nil, internetReachable: false, saved: saved)?.name == "Helmet cam")
        // Never when the internet works, saved or not.
        #expect(SetupNetworks.judge(ssid: "Rover AP", gateway: "192.168.12.1", internetReachable: true, saved: saved) == nil)
        #expect(SetupNetworks.judge(ssid: "Home", gateway: nil, internetReachable: false, saved: saved) == nil)
        // A match saved before 1.46 has no name and still decodes.
        let old = #"{"kind":"printer","maker":"HP","rule":"hp-direct"}"#
        #expect(try! JSONDecoder().decode(SetupNetworkMatch.self, from: Data(old.utf8)).name == nil)
    }

    // MARK: Service order

    static let listed = """
    An asterisk (*) denotes that a network service is disabled.
    (1) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    (2) iPhone USB
    (Hardware Port: iPhone USB, Device: en8)

    (3) Thunderbolt Bridge
    (Hardware Port: Thunderbolt Bridge, Device: bridge0)

    (*) Bluetooth PAN
    (Hardware Port: Bluetooth PAN, Device: en5)

    (4) Work VPN
    (Hardware Port: com.example.vpn, Device: )

    """

    @Test func readsTheServiceOrder() {
        let entries = ServiceOrder.parse(Self.listed)
        #expect(entries.map(\.name) == ["Wi-Fi", "iPhone USB", "Thunderbolt Bridge", "Bluetooth PAN", "Work VPN"])
        #expect(entries[1].device == "en8" && entries[1].hardwarePort == "iPhone USB" && entries[1].enabled)
        #expect(entries[3].enabled == false && entries[3].device == "en5")
        #expect(entries[4].device == nil)
        #expect(ServiceOrder.parse("") == [])
        // A service named with brackets keeps them.
        #expect(ServiceOrder.parse("(1) Lab (2.4 GHz)\n(Hardware Port: Wi-Fi, Device: en0)").first?.name == "Lab (2.4 GHz)")
    }

    @Test func plansTheSwitch() {
        let order = ["Wi-Fi", "iPhone USB", "Thunderbolt Bridge", "Bluetooth PAN"]
        #expect(ServiceOrder.promoting("iPhone USB", in: order) == ["iPhone USB", "Wi-Fi", "Thunderbolt Bridge", "Bluetooth PAN"])
        #expect(ServiceOrder.promoting("Wi-Fi", in: order) == nil)
        #expect(ServiceOrder.promoting("Ethernet", in: order) == nil)
    }

    @Test func putsTheOrderBack() {
        let saved = ["Wi-Fi", "iPhone USB", "Thunderbolt Bridge"]
        #expect(ServiceOrder.restored(saved: saved, current: ["iPhone USB", "Wi-Fi", "Thunderbolt Bridge"], promoted: "iPhone USB") == saved)
        // Changed elsewhere since: the person's own order now, left alone.
        #expect(ServiceOrder.restored(saved: saved, current: ["Thunderbolt Bridge", "iPhone USB", "Wi-Fi"], promoted: "iPhone USB") == nil)
        // A service removed since is simply gone; one added keeps its place after the one it follows now.
        #expect(ServiceOrder.restored(saved: saved + ["Old"], current: ["iPhone USB", "Wi-Fi", "Dock Ethernet", "Thunderbolt Bridge"], promoted: "iPhone USB")
                == ["Wi-Fi", "Dock Ethernet", "iPhone USB", "Thunderbolt Bridge"])
        // The phone's service was new when the switch moved it up: it goes after the rest.
        #expect(ServiceOrder.restored(saved: ["Wi-Fi", "Ethernet"], current: ["iPhone USB", "Wi-Fi", "Ethernet"], promoted: "iPhone USB") == ["Wi-Fi", "Ethernet", "iPhone USB"])
        // Already back.
        #expect(ServiceOrder.restored(saved: ["iPhone USB", "Wi-Fi"], current: ["iPhone USB", "Wi-Fi"], promoted: "iPhone USB") == nil)
    }

    @Test func theHelperOnlyReorders() {
        let current = ["Wi-Fi", "iPhone USB", "Thunderbolt Bridge"]
        let ok = ServiceOrderRequest(order: ["iPhone USB", "Wi-Fi", "Thunderbolt Bridge"], expected: current)
        #expect(ok.arguments(current: current) == ["-ordernetworkservices", "iPhone USB", "Wi-Fi", "Thunderbolt Bridge"])
        // The order changed while the prompt was open.
        #expect(ok.arguments(current: ["iPhone USB", "Wi-Fi", "Thunderbolt Bridge"]) == nil)
        // Missing, extra, repeated or made-up services, or something that reads as a flag.
        #expect(ServiceOrderRequest(order: ["iPhone USB", "Wi-Fi"], expected: current).arguments(current: current) == nil)
        #expect(ServiceOrderRequest(order: ["iPhone USB", "Wi-Fi", "Wi-Fi"], expected: current).arguments(current: current) == nil)
        #expect(ServiceOrderRequest(order: ["iPhone USB", "Wi-Fi", "Evil"], expected: current).arguments(current: current) == nil)
        let flag = ["-setdnsservers", "Wi-Fi", "x"]
        #expect(ServiceOrderRequest(order: flag.reversed(), expected: flag).arguments(current: flag) == nil)
        #expect(ServiceOrderRequest(order: [], expected: []).arguments(current: []) == nil)
    }

    // MARK: Internet priority

    private let wifi = ConnectionRoute(service: "Wi-Fi", interface: "en0", router: "192.168.12.1", kind: .wifi, primary: true)
    private let phone = ConnectionRoute(service: "iPhone USB", interface: "en8", router: "172.20.10.1", kind: .phone, primary: false, internet: true)
    private let ethernet = ConnectionRoute(service: "USB 10/100/1000 LAN", interface: "en7", router: "10.0.0.1", kind: .ethernet, primary: false)

    @Test func namesTheConnections() {
        #expect(ConnectionRoute.kind(service: "iPhone USB", hardwarePort: "iPhone USB", wifi: false) == .phone)
        #expect(ConnectionRoute.kind(service: "SAMSUNG Mobile USB Modem", hardwarePort: nil, wifi: false) == .phone)
        #expect(ConnectionRoute.kind(service: "Bluetooth PAN", hardwarePort: "Bluetooth PAN", wifi: false) == .phone)
        #expect(ConnectionRoute.kind(service: "USB 10/100/1000 LAN", hardwarePort: "USB 10/100/1000 LAN", wifi: false) == .ethernet)
        #expect(ConnectionRoute.kind(service: "Thunderbolt Bridge", hardwarePort: "Thunderbolt Bridge", wifi: false) == .other)
        #expect(ConnectionRoute.kind(service: "Office", hardwarePort: "Wi-Fi", wifi: true) == .wifi)
        #expect(phone.symbol == "personalhotspot" && ethernet.symbol == "cable.connector" && wifi.symbol == "wifi")
    }

    @Test func offersTheSwitchWhenTwoAreUp() {
        #expect(InternetPriority.candidates([wifi]).isEmpty)
        #expect(InternetPriority.candidates([wifi, ethernet, phone]).map(\.service) == ["iPhone USB", "USB 10/100/1000 LAN"])
        // Known to have no internet: not offered.
        var dead = phone; dead.internet = false
        #expect(InternetPriority.candidates([wifi, dead]).isEmpty)
        // Already carrying it: nothing to switch to.
        var carrying = phone; carrying.primary = true
        var behind = wifi; behind.primary = false
        #expect(InternetPriority.candidates([behind, carrying]).isEmpty)
        #expect(InternetPriority.carrier([behind, carrying])?.service == "iPhone USB")
        // No router, no default route to give it.
        var bare = ethernet; bare.router = nil
        #expect(InternetPriority.candidates([wifi, bare]).isEmpty)
    }

    @Test func urgentOnlyWhenTheWiFiHasNoInternet() {
        #expect(InternetPriority.urgent([wifi, phone], wifiHasInternet: false)?.service == "iPhone USB")
        #expect(InternetPriority.urgent([wifi, phone], wifiHasInternet: true) == nil)
        #expect(InternetPriority.urgent([wifi, phone], wifiHasInternet: nil) == nil)
        var behind = wifi; behind.primary = false
        #expect(InternetPriority.urgent([behind, ethernet], wifiHasInternet: false) == nil)
    }

    @Test func restoresWhenTheConnectionIsGone() {
        let hold = PriorityHold(service: "iPhone USB", interface: "en8", previous: ["Wi-Fi", "iPhone USB"], applied: ["iPhone USB", "Wi-Fi"], wifi: "GO2-8A2C1F")
        let now = Date()
        #expect(!InternetPriority.shouldRestore(hold, routes: [wifi, phone], goneSince: nil, now: now))
        #expect(!InternetPriority.shouldRestore(hold, routes: [wifi], goneSince: nil, now: now))
        #expect(!InternetPriority.shouldRestore(hold, routes: [wifi], goneSince: now.addingTimeInterval(-10), now: now))
        #expect(InternetPriority.shouldRestore(hold, routes: [wifi], goneSince: now.addingTimeInterval(-31), now: now))
        #expect(InternetPriority.restore(hold, current: ["iPhone USB", "Wi-Fi"]) == .apply(["Wi-Fi", "iPhone USB"]))
        #expect(InternetPriority.restore(hold, current: ["Wi-Fi", "iPhone USB"]) == .leave(changedElsewhere: true))
        #expect(InternetPriority.activeLine(hold) == "iPhone USB carries the internet. Wi-Fi stays on GO2-8A2C1F for local devices.")
        #expect(InternetPriority.useSentence(phone) == "Use iPhone USB for internet, keep Wi-Fi for local devices")
    }

    @MainActor final class FakeApplier: ServiceOrderApplying {
        var automatic: Bool
        var applied: [(order: [String], expected: [String], prompt: Bool)] = []
        var order: [String]
        var fails = false
        init(automatic: Bool, order: [String]) { self.automatic = automatic; self.order = order }
        func apply(order: [String], expected: [String], prompt: Bool) async throws {
            if fails { throw DiagnosticError("refused") }
            applied.append((order, expected, prompt)); self.order = order
        }
    }

    @MainActor private func store(automatic: Bool, routes: [ConnectionRoute]) -> (InternetPriorityStore, FakeApplier, UserDefaults) {
        let defaults = UserDefaults(suiteName: "kilobat-priority-" + UUID().uuidString)!
        let store = InternetPriorityStore(defaults: defaults)
        let applier = FakeApplier(automatic: automatic, order: ["Wi-Fi", "iPhone USB", "Thunderbolt Bridge"])
        store.applier = applier
        var current = routes
        store.readRoutes = { current }
        store.checkInternet = { _ in true }
        store.readOrder = { applier.order }
        _ = current; current = routes
        return (store, applier, defaults)
    }

    @MainActor @Test func switchesAndPutsBack() async {
        let (store, applier, defaults) = store(automatic: false, routes: [wifi, phone])
        await store.refresh()
        #expect(store.candidates.map(\.service) == ["iPhone USB"])
        await store.use(phone, wifi: "GO2-8A2C1F")
        #expect(applier.order == ["iPhone USB", "Wi-Fi", "Thunderbolt Bridge"])
        #expect(applier.applied.last?.prompt == true && applier.applied.last?.expected == ["Wi-Fi", "iPhone USB", "Thunderbolt Bridge"])
        #expect(store.hold?.previous == ["Wi-Fi", "iPhone USB", "Thunderbolt Bridge"])
        // Kept across a relaunch.
        #expect(PriorityHold.load(defaults)?.service == "iPhone USB")
        await store.turnOff()
        #expect(applier.order == ["Wi-Fi", "iPhone USB", "Thunderbolt Bridge"])
        #expect(store.hold == nil && PriorityHold.load(defaults) == nil)
    }

    @MainActor @Test func switchingAgainPreservesManualChanges() async {
        let (store, applier, _) = store(automatic: true, routes: [wifi, phone])
        await store.use(phone, wifi: nil)
        let manual = ["Thunderbolt Bridge", "Wi-Fi", "iPhone USB"]
        applier.order = manual
        await store.use(phone, wifi: nil)
        await store.turnOff()
        #expect(applier.order == manual)
    }

    @MainActor @Test func leavesAnOrderChangedElsewhere() async {
        let (store, applier, _) = store(automatic: true, routes: [wifi, phone])
        await store.use(phone, wifi: nil)
        applier.order = ["Thunderbolt Bridge", "iPhone USB", "Wi-Fi"]
        let count = applier.applied.count
        await store.turnOff()
        #expect(applier.applied.count == count && store.hold == nil)
        #expect(store.notice?.contains("changed elsewhere") == true)
    }

    @MainActor @Test func goneConnectionRestoresOnlyWithTheHelper() async {
        for automatic in [true, false] {
            let defaults = UserDefaults(suiteName: "kilobat-priority-" + UUID().uuidString)!
            let store = InternetPriorityStore(defaults: defaults)
            let applier = FakeApplier(automatic: automatic, order: ["Wi-Fi", "iPhone USB"])
            store.applier = applier
            var routes = [wifi, phone]
            store.readRoutes = { routes }
            store.checkInternet = { _ in true }
            store.readOrder = { applier.order }
            await store.use(phone, wifi: "GO2-8A2C1F")
            routes = [wifi]
            let start = Date()
            await store.refresh(now: start)
            #expect(store.hold != nil)
            await store.refresh(now: start.addingTimeInterval(InternetPriority.goneGrace + 1))
            if automatic {
                #expect(store.hold == nil && applier.order == ["Wi-Fi", "iPhone USB"] && applier.applied.last?.prompt == false)
            } else {
                // No password prompt out of nowhere: Health offers the button.
                #expect(store.hold != nil && store.restoreWaiting && applier.applied.count == 1)
            }
        }
    }

    @MainActor @Test func recoversALeftoverAtLaunch() async {
        let defaults = UserDefaults(suiteName: "kilobat-priority-" + UUID().uuidString)!
        PriorityHold(service: "iPhone USB", interface: "en8", previous: ["Wi-Fi", "iPhone USB"], applied: ["iPhone USB", "Wi-Fi"]).save(defaults)
        let store = InternetPriorityStore(defaults: defaults)
        let applier = FakeApplier(automatic: true, order: ["iPhone USB", "Wi-Fi"])
        store.applier = applier; store.readRoutes = { [] }; store.readOrder = { applier.order }
        await store.recover()
        #expect(applier.order == ["Wi-Fi", "iPhone USB"] && store.hold == nil)
        // On quit, synchronously, through the blocking helper call.
        let quitting = UserDefaults(suiteName: "kilobat-priority-" + UUID().uuidString)!
        PriorityHold(service: "iPhone USB", interface: "en8", previous: ["Wi-Fi", "iPhone USB"], applied: ["iPhone USB", "Wi-Fi"]).save(quitting)
        var sent: [String]?
        InternetPriorityStore(defaults: quitting).quit({ order, _ in sent = order; return true }, current: ["iPhone USB", "Wi-Fi"])
        #expect(sent == ["Wi-Fi", "iPhone USB"] && PriorityHold.load(quitting) == nil)
        // The helper not answering keeps it for the next launch.
        let failing = UserDefaults(suiteName: "kilobat-priority-" + UUID().uuidString)!
        PriorityHold(service: "iPhone USB", interface: "en8", previous: ["Wi-Fi", "iPhone USB"], applied: ["iPhone USB", "Wi-Fi"]).save(failing)
        InternetPriorityStore(defaults: failing).quit({ _, _ in false }, current: ["iPhone USB", "Wi-Fi"])
        #expect(PriorityHold.load(failing) != nil)
    }

    // MARK: Device network mode

    private func snapshot(ssid: String, wired: String? = nil, internet: Bool, setup: SetupNetworkMatch? = nil) -> DiagnosticSnapshot {
        var value = DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: ssid, interface: "en0", rssi: -50, noise: -92, transmitMbps: 144, channel: 6, band: "2.4 GHz"),
                                       gateway: wired == nil ? "192.168.12.1" : "172.20.10.1", router: PingResult(host: "192.168.12.1", samples: [2], lossPercent: 0),
                                       internet: PingResult(host: "1.1.1.1", samples: internet ? [20] : [], lossPercent: internet ? 0 : 100), dnsMilliseconds: nil, dnsServers: [],
                                       captivePortal: nil, networkService: wired == nil ? "Wi-Fi" : "iPhone USB")
        value.wiredInterface = wired
        value.secondary = PingResult(host: "8.8.8.8", samples: internet ? [20] : [], lossPercent: internet ? 0 : 100)
        value.httpReachable = internet
        value.setupNetwork = setup
        return value
    }

    @MainActor @Test func knowsADeviceNetworkWhateverCarriesTheInternet() async {
        let defaults = UserDefaults(suiteName: "kilobat-mode-" + UUID().uuidString)!
        let priority = InternetPriorityStore(defaults: defaults)
        let applier = FakeApplier(automatic: true, order: ["Wi-Fi", "iPhone USB"])
        priority.applier = applier
        var routes = [wifi, phone]
        priority.readRoutes = { routes }
        priority.checkInternet = { _ in true }
        priority.readOrder = { applier.order }
        let watch = DeviceNetworkWatch(priority: priority, notes: DeviceNotesStore(defaults: defaults, keychain: .memory()))
        var looked = 0
        watch.runFinder = { network, gateway, _ in looked += 1; return DeviceFinding(network: network, devices: [FoundDevice(address: gateway ?? "?", gateway: true)]) }
        // Off until the app turns it on (Lite never does).
        await watch.observe(snapshot(ssid: "GO2-8A2C1F", internet: false), portal: false)
        #expect(watch.mode == nil)
        watch.enabled = true

        // An ordinary Wi-Fi first: the one to go back to.
        var home = wifi; home.router = "192.168.1.1"
        routes = [home]
        await watch.observe(snapshot(ssid: "Venue Guest", internet: true), portal: false)
        #expect(watch.mode == nil)

        // The robot's Wi-Fi carrying the internet, none there: the device's own network, found once.
        routes = [wifi, phone]
        let match = SetupNetworks.judge(ssid: "GO2-8A2C1F", gateway: "192.168.12.1", internetReachable: false)
        await watch.observe(snapshot(ssid: "GO2-8A2C1F", internet: false, setup: match), portal: false)
        #expect(watch.match?.kind == .robot && watch.previous == "Venue Guest" && watch.deviceAddress == "192.168.12.1" && looked == 1)
        #expect(watch.link.target?.address == "192.168.12.1")
        watch.link.stop()

        // The switch on: the phone carries the internet, the Wi-Fi's name alone still says it's the robot's.
        await priority.use(phone, wifi: "GO2-8A2C1F")
        var carrying = phone; carrying.primary = true
        var behind = wifi; behind.primary = false
        routes = [behind, carrying]
        await watch.observe(snapshot(ssid: "GO2-8A2C1F", wired: "en8", internet: true), portal: false)
        #expect(watch.match?.rule == "unitree-go2" && watch.gateway == "192.168.12.1" && looked == 1)
        watch.link.stop()

        // A manual rescan finishes after the Mac leaves Wi-Fi.
        var pending: CheckedContinuation<DeviceFinding, Never>?
        watch.runFinder = { _, _, _ in await withCheckedContinuation { pending = $0 } }
        let scan = Task { await watch.find() }
        while pending == nil { await Task.yield() }

        // Back on an ordinary Wi-Fi: the order goes back through the helper.
        routes = [home, carrying]
        await watch.observe(snapshot(ssid: "Venue Guest", wired: "en8", internet: true), portal: false)
        #expect(watch.mode == nil && priority.hold == nil && applier.order == ["Wi-Fi", "iPhone USB"])

        pending?.resume(returning: DeviceFinding(network: "old", devices: []))
        await scan.value
        #expect(!watch.searching && watch.finding == nil)

        // A Wi-Fi with no internet that matches nothing: not a device network, but the switch is offered.
        routes = [wifi, phone]
        await watch.observe(snapshot(ssid: "Robot-Lab", internet: false), portal: false)
        #expect(watch.mode == .noInternet && InternetPriority.urgent(priority.routes, wifiHasInternet: false)?.service == "iPhone USB")
        // Behind a sign-in page it's the venue's Wi-Fi, not a device's.
        await watch.observe(snapshot(ssid: "Robot-Lab", internet: false), portal: true)
        #expect(watch.mode == nil)
    }

    // MARK: Why can't I see my device?

    private func check(_ edit: (inout LocalPeers) -> Void, services: [LocalService] = [], access: LocalNetworkAccess = .allowed, connected: Bool = true) -> LocalReachCheck {
        var peers = LocalPeers(); peers.swept = true; edit(&peers)
        return LocalReachCheck(network: "Hotel", services: services, peers: peers, access: access, connected: connected)
    }

    @Test func isolationVerdictsStayHonest() {
        // Proxy ARP and silence: possible isolation, never certain.
        let isolated = DeviceVisibility.judge(check { $0.routerAliases = 14; $0.pinged = 0 }, routerAnswered: true)
        #expect(isolated.verdict == .mayIsolate && isolated.confidence == .possible && isolated.fixes == [.hotspot, .direct, .venue])
        #expect(isolated.signals.contains { $0.kind == .proxyARP && $0.ok == false })
        // Devices answer pings but none announce: discovery may be filtered.
        let filtered = DeviceVisibility.judge(check { $0.neighbours = 5; $0.pinged = 5; $0.answered = 3 }, routerAnswered: true)
        #expect(filtered.verdict == .discoveryFiltered && filtered.confidence == .possible && filtered.fixes.first == .address)
        // One answer is too little to call it.
        #expect(DeviceVisibility.judge(check { $0.neighbours = 2; $0.pinged = 2; $0.answered = 1 }, routerAnswered: true).verdict == .visible)
        // Anyone announcing: devices can see each other.
        let visible = DeviceVisibility.judge(check { $0.bonjourDevices = 2 }, routerAnswered: true, target: (name: "Rover", answered: false))
        #expect(visible.verdict == .visible && visible.fixes == [.wake, .sameDevice])
        #expect(visible.signals.contains { $0.kind == .device && $0.ok == false && $0.text == "Rover didn’t answer." })
        // Silence alone is never isolation.
        let quiet = DeviceVisibility.judge(check { $0.neighbours = 0 }, routerAnswered: true)
        #expect(quiet.verdict == .unclear && quiet.confidence == .unknown)
        #expect(quiet.headline == "Kilobat can’t tell whether this Wi-Fi keeps devices apart")
        // Proxy ARP while someone else answers: the network does let devices talk.
        #expect(DeviceVisibility.judge(check { $0.routerAliases = 14; $0.bonjourDevices = 1 }, routerAnswered: true).verdict == .visible)
        #expect(DeviceVisibility.judge(check({ _ in }, access: .denied), routerAnswered: nil).verdict == .noAccess)
        #expect(DeviceVisibility.judge(nil, routerAnswered: nil).verdict == .offline)
        #expect(DeviceVisibility.judge(check({ _ in }, connected: false), routerAnswered: nil).verdict == .offline)
        // Every verdict explains itself and every fix has words.
        for fix in DeviceVisibility.Fix.allCases { #expect(!DeviceVisibility.text(fix).isEmpty) }
        #expect(isolated.detail.contains("isn’t proof"))
    }

    // MARK: Link quality

    private func pings(_ values: [Double?], from start: Double = 0) -> [CallSamples.Ping] {
        values.enumerated().map { CallSamples.Ping(at: start + Double($0.offset), ms: $0.element) }
    }

    @Test func readsTheLink() {
        let steady = LinkQuality.reading(pings(Array(repeating: 3, count: 30)))
        #expect(steady.median == 3 && steady.lossPercent == 0 && steady.jitter == 0 && steady.grade == .good)
        let lossy = LinkQuality.reading(pings([3, nil, 4, nil, 3, 5, 3, 4, 3, 4]))
        #expect(lossy.lossPercent == 20 && lossy.grade == .poor)
        let jittery = LinkQuality.reading(pings([3, 60, 4, 70, 3, 65, 4, 66, 3, 70]))
        #expect(jittery.grade == .fair || jittery.grade == .poor)
        #expect((jittery.jitter ?? 0) > 50)
        // Too few to judge.
        #expect(LinkQuality.reading(pings([3, 3, 3])).grade == nil)
        // The window counts from `since`.
        #expect(LinkQuality.reading(pings([nil, nil, nil, nil] + Array(repeating: 3, count: 10)), since: 4).lossPercent == 0)
    }

    @Test func alertsOnlyWhenItTurnsPoor() {
        let good: [Double?] = Array(repeating: 3, count: 60)
        let bad: [Double?] = Array(repeating: nil, count: 10) + [3, 3, 3, 3, 3]
        #expect(!LinkQuality.degraded(pings(good), now: 60))
        #expect(LinkQuality.degraded(pings(good + bad), now: 75))
        // Poor all along: no news to alert about.
        #expect(!LinkQuality.degraded(pings(Array(repeating: nil, count: 75)), now: 75))
    }

    @Test func drawsOneBarASecond() {
        let line = LinkQuality.line(pings([5, nil, 7], from: 57), now: 60)
        #expect(line.count == 60 && line[57] == 5 && line[58] == nil && line[59] == 7 && line[0] == nil)
    }

    @Test func spotsACrowdedChannel() {
        func network(_ channel: Int, _ band: String = "2.4 GHz") -> NearbyNetwork {
            NearbyNetwork(id: UUID().uuidString, ssid: "n\(channel)", rssi: -60, noise: -92, channel: channel, band: band, widthMHz: 20)
        }
        #expect(LinkQuality.crowding(channel: 6, band: "2.4 GHz", networks: [network(6), network(4), network(8), network(11), network(1), network(36, "5 GHz")]) == 3)
        #expect(LinkQuality.crowding(channel: 6, band: "2.4 GHz", networks: []) == nil)
        #expect(LinkQuality.crowding(channel: nil, band: nil, networks: [network(6)]) == nil)
    }

    // MARK: Where's my device?

    @Test func findsTheDevice() {
        let web = PortScan.Service(port: 80, name: "Web page", web: "http"), rtsp = PortScan.Service(port: 554, name: "Camera video (RTSP)")
        let secure = PortScan.Service(port: 443, name: "Secure web page", web: "https"), alt = PortScan.Service(port: 8080, name: "Web page", web: "http")
        #expect(DeviceFinder.webURL(address: "192.168.12.1", ports: [web, secure])?.absoluteString == "https://192.168.12.1")
        #expect(DeviceFinder.webURL(address: "192.168.12.1", ports: [alt])?.absoluteString == "http://192.168.12.1:8080")
        #expect(DeviceFinder.webURL(address: "192.168.12.1", ports: [rtsp]) == nil)
        #expect(Set(DeviceFinder.services.map(\.port)) == Set(DeviceFinder.ports))

        let states: [UInt16: PortScan.State] = [80: .open, 554: .open, 22: .closed]
        let report = PortReport(address: "192.168.12.1", date: Date(), services: DeviceFinder.services, states: states, seconds: 1)
        let silent = PortReport(address: "192.168.12.40", date: Date(), services: DeviceFinder.services, states: [:], seconds: 1)
        let bonjour = [BonjourService(type: "_rtsp._tcp", name: "Go2 Front Camera", host: "GO2-8A2C1F.local.", port: 554, addresses: ["192.168.12.1"]),
                       BonjourService(type: "_http._tcp", name: "Elsewhere", addresses: ["10.9.9.9"])]
        let devices = DeviceFinder.merge(gateway: "192.168.12.1", neighbours: [("192.168.12.40", "aa:bb:cc:00:00:01", nil), ("192.168.12.1", "02:00:00:00:00:01", nil)],
                                         bonjour: bonjour, reports: ["192.168.12.1": report, "192.168.12.40": silent], makers: ["192.168.12.40": "Apple, Inc."])
        #expect(devices.map(\.address) == ["192.168.12.1", "192.168.12.40"])
        let robot = devices[0]
        #expect(robot.gateway && robot.title == "Go2 Front Camera" && robot.hostname == "GO2-8A2C1F.local" && robot.rtsp)
        #expect(robot.ports.map(\.port) == [80, 554] && robot.webURL?.absoluteString == "http://192.168.12.1")
        #expect(devices[1].silent && devices[1].title == "Apple, Inc.")
        let finding = DeviceFinding(network: "GO2-8A2C1F", devices: devices)
        #expect(finding.main?.address == "192.168.12.1")
    }

    // MARK: Saved devices

    @Test func tidiesANote() {
        let note = DeviceNote(name: "  Rover ", kind: .robot, ssid: " GO2-8A2C1F ", address: "192.168.12.1", webURL: "192.168.12.1:8080", notes: "  ")
        let clean = note.cleaned()!
        #expect(clean.name == "Rover" && clean.ssid == "GO2-8A2C1F" && clean.notes == nil && clean.webURL == "http://192.168.12.1:8080")
        #expect(clean.openURL?.absoluteString == "http://192.168.12.1:8080")
        #expect(DeviceNote(name: " ", kind: .robot).cleaned() == nil)
        #expect(DeviceNote(name: "Cam", kind: .camera, address: "192.168.1.9").openURL?.absoluteString == "http://192.168.1.9")
        #expect(DeviceNote(name: "Cam", kind: .camera, address: "camera.local", webURL: "javascript:alert(1)").openURL == nil)
    }

    @MainActor @Test func preservesDeviceNotesWhenKeychainIsLocked() {
        let defaults = UserDefaults(suiteName: "kilobat-locked-" + UUID().uuidString)!
        let locked = DevicePasswords(get: { _ in nil }, set: { _, _ in -25308 }, remove: { _ in -25308 })
        let notes = DeviceNotesStore(defaults: defaults, keychain: locked)
        var note = DeviceNote(name: "Rover", kind: .robot)
        #expect(notes.save(note, password: nil))
        note.name = "Updated"
        #expect(!notes.save(note, password: "password"))
        #expect(!notes.delete(note.id))
        #expect(notes.notes.first?.name == "Rover" && notes.keychainError != nil)
    }

    @MainActor @Test func keepsPasswordsOutOfDefaults() throws {
        let defaults = UserDefaults(suiteName: "kilobat-notes-" + UUID().uuidString)!
        let passwords = DevicePasswords.memory()
        let store = DeviceNotesStore(defaults: defaults, keychain: passwords)
        let rover = DeviceNote(name: "Rover", kind: .robot, ssid: "GO2-8A2C1F", address: "192.168.12.1")
        #expect(store.save(rover, password: "hunter22"))
        #expect(store.password(rover.id) == "hunter22")
        let stored = String(decoding: try #require(defaults.data(forKey: DeviceNotesStore.key)), as: UTF8.self)
        #expect(stored.contains("Rover") && !stored.contains("hunter22"))
        #expect(DeviceNotesStore.networks(defaults)["GO2-8A2C1F"]?.name == "Rover")
        #expect(store.note(ssid: "GO2-8A2C1F")?.id == rover.id)
        // nil keeps the password; empty removes it.
        var renamed = rover; renamed.name = "Rover 2"
        store.save(renamed, password: nil)
        #expect(store.password(rover.id) == "hunter22" && store.notes.map(\.name) == ["Rover 2"])
        store.save(renamed, password: "")
        #expect(store.password(rover.id) == nil)
        store.save(renamed, password: "again")
        store.delete(rover.id)
        #expect(store.notes.isEmpty && store.password(rover.id) == nil && defaults.data(forKey: DeviceNotesStore.key) == nil)
    }
}
