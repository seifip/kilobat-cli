import Foundation

/// "Fix it": takes the cause Health found, tries the safest fix, measures again with the same check, keeps it if it
/// helped and undoes it if it didn't. This file is the plain logic: what the cause is, which steps to try and what to
/// decide after each reading. Nothing here touches the network; `FixRunner` drives it and the app supplies the actions.
public enum FixPolicy {
    /// Who gets Fix it: Pro. Free users see the button as an upgrade (`FixCause.alreadyFree`).
    public static let needsPro = true
    public static func allowed(hasPro: Bool) -> Bool { !needsPro || hasPro }

    /// No cause gets more tries than this.
    public static let mostSteps = 3
    /// Good readings in a row before a change counts as Fixed: an intermittent problem can look fixed by chance.
    public static let steadyReadings = 3
    public static let steadyInterval: TimeInterval = 10
    /// How much a reading must move to count: a quarter of the old value, and at least these.
    public static let improvedShare = 0.25
    public static let improvedMs = 15.0
    public static let improvedDB = 6.0
    /// Health's own limits, so Fix it and Health never disagree about what is good.
    public static let goodDNS = 150.0, goodInternet = 120.0, goodJitter = 30.0, goodLoss = 5.0
    /// Higher than Health's 20 ms note: ordinary Wi-Fi often reads 20 to 30, and nobody should unplug a router for that.
    public static let goodRouter = 50.0
    public static let goodSignal = MeshNodes.weakAbove
}

/// Something on the network the Mac is in the middle of, which a dropped Wi-Fi would interrupt.
public enum FixLiveSession: Equatable, Sendable {
    case call(String?), stream, game(String?), cast, listening
    /// Bluetooth headphones keep playing local audio through a Wi-Fi blip.
    public var interruptedByWiFiDrop: Bool { if case .listening = self { false } else { true } }
    public var name: String {
        switch self {
        case .call(let app): app.map { String(localized: "your \($0) call", comment: "Fix it: a live session; the argument is an app such as Zoom") } ?? String(localized: "your call", comment: "Fix it: a live session")
        case .stream: String(localized: "your stream", comment: "Fix it: a live session")
        case .game(let name): name.map { String(localized: "your \($0) match", comment: "Fix it: a live session; the argument is a game or service") } ?? String(localized: "your match", comment: "Fix it: a live session")
        case .cast: String(localized: "your cast", comment: "Fix it: a live session, AirPlay or a cast tab")
        case .listening: String(localized: "your audio", comment: "Fix it: a live session, Bluetooth headphones playing")
        }
    }
}

/// Who can fix what isn't this Mac's to fix.
public enum FixWho: Equatable, Sendable {
    case router, provider, vpn(String?), network(String?)
    public var name: String {
        switch self {
        case .router: String(localized: "Your router", comment: "Fix it: who can fix the problem")
        case .provider: String(localized: "Your internet provider", comment: "Fix it: who can fix the problem")
        case .vpn(let name): name ?? String(localized: "Your VPN", comment: "Fix it: who can fix the problem")
        case .network(let place): place ?? String(localized: "Whoever runs this Wi-Fi", comment: "Fix it: who can fix the problem: a hotel, café or office network")
        }
    }
}

public enum FixCause: Equatable, Sendable {
    case dnsFailing, dnsSlow, wifiStuck
    /// `blockers`: what on this Mac may keep the page from showing. With the person's own DNS among them, Fix it uses
    /// the Wi-Fi's DNS for the sign-in and puts theirs back after.
    case signIn(place: String?, blockers: PortalBlockers = PortalBlockers())
    case farNode(better: String?)
    case upload(key: String, name: String)
    case airDrop(FixLiveSession)
    case vpnBroken(String?)
    case router, provider

    public var title: String {
        switch self {
        case .dnsFailing: String(localized: "DNS isn’t answering", comment: "Fix it: the cause")
        case .dnsSlow: String(localized: "Slow DNS lookups", comment: "Fix it: the cause")
        case .wifiStuck: String(localized: "Wi-Fi has no working address", comment: "Fix it: the cause")
        case .signIn(_, let blockers):
            blockers.lead.map { String(localized: "\($0) may hide the sign-in page", comment: "Fix it: the cause; the argument is like 'Your DNS settings' or a VPN's name") }
                ?? String(localized: "Wi-Fi sign-in expired", comment: "Fix it: the cause")
        case .farNode: String(localized: "On a far Wi-Fi node", comment: "Fix it: the cause")
        case .upload(_, let name): String(localized: "\(name) is filling your upload", comment: "Fix it: the cause; the argument is an app")
        case .airDrop(let session): String(localized: "AirDrop is interrupting \(session.name)", comment: "Fix it: the cause; the argument is like 'your call'")
        case .vpnBroken(let name): name.map { String(localized: "\($0) isn’t passing traffic", comment: "Fix it: the cause; the argument is a VPN") } ?? String(localized: "Your VPN isn’t passing traffic", comment: "Fix it: the cause")
        case .router: String(localized: "Your router is struggling", comment: "Fix it: the cause")
        case .provider: String(localized: "The problem is past your router", comment: "Fix it: the cause")
        }
    }

    /// Its fix already has a free button of its own in Health, so a locked Fix it would sell what's free beside it.
    public var alreadyFree: Bool {
        switch self {
        // Switching DNS for the sign-in is Fix it's own; opening the page and naming a VPN aren't.
        case .signIn(_, let blockers): !blockers.switchesDNS
        case .farNode, .airDrop: true
        default: false
        }
    }

    /// For a prompt pasted into an AI service: the title, without a place or a device's name.
    var agentTitle: String {
        switch self {
        case .signIn(_, let blockers): (["A Wi-Fi sign-in page is in the way."] + [blockers.agentNote].compactMap { $0 }).joined(separator: " ")
        case .farNode: "This Mac is stuck on a far mesh node"
        default: title
        }
    }

    public var isAirDrop: Bool { if case .airDrop = self { true } else { false } }

    /// Its fixes go through the root helper when that's on: a fresh address, or DNS without a password.
    public var usesHelper: Bool {
        switch self {
        case .wifiStuck, .dnsFailing, .dnsSlow: true
        case .signIn(_, let blockers): blockers.switchesDNS
        default: false
        }
    }

    /// Who to name when nothing on the Mac helped.
    public var who: FixWho {
        switch self {
        case .dnsFailing, .dnsSlow, .upload, .airDrop, .provider: .provider
        case .wifiStuck, .farNode, .router: .router
        case .signIn(let place, _): .network(place)
        case .vpnBroken(let name): .vpn(name)
        }
    }

    /// What the wizard's before-and-after shows, and whether that reading is good, from the check that found the cause.
    public func metric(_ reading: FixReading) -> FixMetric {
        switch self {
        case .dnsFailing, .dnsSlow:
            return FixMetric(.ms(reading.dnsMs), good: reading.dnsMs.map { $0 <= FixPolicy.goodDNS } ?? false)
        case .wifiStuck:
            return FixMetric(.ms(reading.routerMs), good: reading.hasAddress && reading.routerMs != nil)
        case .signIn:
            // Signed in means the page is gone and something past it answers: a page hidden by this Mac's own DNS or
            // VPN doesn't show as a portal at all, only as nothing working.
            let through = !reading.portal && (reading.dnsMs != nil || reading.internetMs != nil)
            return FixMetric(.state(through ? 1 : 0, .signedIn), good: through)
        case .farNode:
            return FixMetric(.dBm(reading.rssi), good: !reading.stuckNode && (reading.rssi ?? -100) > FixPolicy.goodSignal)
        case .upload:
            return FixMetric(.ms(reading.internetMs.map { $0 + (reading.jitter ?? 0) }), good: reading.internetClear)
        case .airDrop:
            return FixMetric(.state(reading.airDropBusy ? 0 : 1, .airDropQuiet), good: !reading.airDropBusy)
        case .vpnBroken:
            return FixMetric(.ms(reading.internetMs), good: (reading.internetMs != nil || reading.reachable) && reading.dnsMs != nil)
        case .router:
            return FixMetric(.ms(reading.routerMs), good: reading.routerMs.map { $0 <= FixPolicy.goodRouter } ?? false)
        case .provider:
            return FixMetric(.ms(reading.internetMs), good: reading.internetClear)
        }
    }
}

/// One reading, in the terms Fix it needs. The app takes it from a fresh Health check.
public struct FixReading: Equatable, Sendable {
    public var dnsMs: Double?, routerMs: Double?, internetMs: Double?, jitter: Double?, loss: Double?
    public var hasAddress: Bool, portal: Bool, stuckNode: Bool, airDropBusy: Bool
    public var rssi: Int?
    /// Something past the router answered, by either ping target or the HTTPS check.
    public var reachable: Bool
    public init(dnsMs: Double? = nil, routerMs: Double? = nil, internetMs: Double? = nil, jitter: Double? = nil, loss: Double? = nil,
                hasAddress: Bool = true, portal: Bool = false, stuckNode: Bool = false, airDropBusy: Bool = false, rssi: Int? = nil, reachable: Bool = false) {
        self.dnsMs = dnsMs; self.routerMs = routerMs; self.internetMs = internetMs; self.jitter = jitter; self.loss = loss
        self.hasAddress = hasAddress; self.portal = portal; self.stuckNode = stuckNode; self.airDropBusy = airDropBusy; self.rssi = rssi
        self.reachable = reachable
    }
    public init(_ snapshot: DiagnosticSnapshot, stuckNode: Bool = false, airDropBusy: Bool = false) {
        let ping = snapshot.measured
        self.init(dnsMs: snapshot.dnsMilliseconds, routerMs: snapshot.router?.average, internetMs: ping.average, jitter: ping.jitter,
                  loss: ping.lossPercent, hasAddress: FixPlanner.hasAddress(snapshot), portal: snapshot.captivePortal == true,
                  stuckNode: stuckNode, airDropBusy: airDropBusy, rssi: snapshot.radio.rssi, reachable: snapshot.reachability == .up)
    }
    var internetClear: Bool {
        guard let internetMs else { return false }
        return internetMs <= FixPolicy.goodInternet && (jitter ?? 0) <= FixPolicy.goodJitter && (loss ?? 0) < FixPolicy.goodLoss
    }
}

/// A reading as the wizard shows it.
public struct FixMetric: Equatable, Sendable {
    public enum StateKind: Equatable, Sendable { case signedIn, airDropQuiet }
    public enum Value: Equatable, Sendable {
        case ms(Double?), dBm(Int?), state(Double, StateKind)
        /// Bigger is better for signal and states, smaller for time.
        var higherIsBetter: Bool { if case .ms = self { false } else { true } }
        var number: Double? {
            switch self {
            case .ms(let value): value
            case .dBm(let value): value.map(Double.init)
            case .state(let value, _): value
            }
        }
    }
    public let value: Value
    public let good: Bool
    public init(_ value: Value, good: Bool) { self.value = value; self.good = good }

    public var text: String {
        switch value {
        case .ms(let value): value.map { Self.number($0) + " ms" } ?? String(localized: "No answer", comment: "Fix it: a reading where nothing replied")
        case .dBm(let value): value.map { "\($0) dBm" } ?? "—"
        case .state(let value, .signedIn): value > 0 ? String(localized: "Signed in", comment: "Fix it: a reading") : String(localized: "Signed out", comment: "Fix it: a reading")
        case .state(let value, .airDropQuiet): value > 0 ? String(localized: "Quiet", comment: "Fix it: a reading of AirDrop's radio") : String(localized: "Busy", comment: "Fix it: a reading of AirDrop's radio")
        }
    }
    private static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
}

/// What can be tried. Each of these either changes nothing lasting or can be put back.
public enum FixAction: Equatable, Sendable {
    case switchDNS(DNSResolverChoice)
    case renewAddress, reconnectWiFi, closerNode, openSignIn
    /// The Wi-Fi's own DNS in place of the person's for the sign-in, the page opened, theirs put back after.
    case signInOnNetworkDNS
    case holdUpload(key: String, name: String)
    case pauseAirDrop
    case openVPN(String?)
    case restartRouter

    public var dropsWiFi: Bool { self == .reconnectWiFi || self == .closerNode }
    /// A person does it; Kilobat can only open the way and measure afterwards.
    public var needsPerson: Bool {
        switch self { case .openSignIn, .signInOnNetworkDNS, .openVPN, .restartRouter: true; default: false }
    }
    /// How long a person gets before the check gives up. A VPN to turn off first takes longer than a page.
    public var patience: TimeInterval {
        switch self { case .openSignIn: 150; case .signInOnNetworkDNS: 300; case .openVPN: 60; case .restartRouter: 240; default: 0 }
    }
    /// Only for the sign-in: put back as soon as the run ends, kept or not.
    public var restoresAfter: Bool { self == .signInOnNetworkDNS }
    /// How long the network needs before a reading means anything.
    public var settle: TimeInterval {
        switch self {
        case .pauseAirDrop: 1
        case .switchDNS: 2
        case .renewAddress: 3
        case .closerNode: 6
        // Joined isn't enough: the router still has to hand out an address.
        case .reconnectWiFi: 8
        case .holdUpload: 5
        case .openSignIn, .signInOnNetworkDNS, .openVPN, .restartRouter: 0
        }
    }

    public var doing: String {
        switch self {
        case .switchDNS(let choice): String(localized: "Trying \(choice.name) DNS", comment: "Fix it: step in progress; the argument is a resolver")
        case .renewAddress: String(localized: "Getting a fresh address", comment: "Fix it: step in progress")
        case .reconnectWiFi: String(localized: "Reconnecting to Wi-Fi", comment: "Fix it: step in progress")
        case .closerNode: String(localized: "Moving to a closer node", comment: "Fix it: step in progress")
        case .openSignIn: String(localized: "Sign in to this Wi-Fi", comment: "Fix it: the step a person does")
        case .signInOnNetworkDNS: String(localized: "Sign in on this Wi-Fi’s DNS", comment: "Fix it: the step a person does, after Kilobat switches to the Wi-Fi's own DNS")
        case .holdUpload(_, let name): String(localized: "Holding \(name)’s upload", comment: "Fix it: step in progress; the argument is an app")
        case .pauseAirDrop: String(localized: "Pausing AirDrop", comment: "Fix it: step in progress")
        case .openVPN(let name): name.map { String(localized: "Reconnect \($0)", comment: "Fix it: the step a person does; the argument is a VPN") } ?? String(localized: "Reconnect your VPN", comment: "Fix it: the step a person does")
        case .restartRouter: String(localized: "Restart your router", comment: "Fix it: the step a person does")
        }
    }
    /// What the log says was done.
    public var done: String {
        switch self {
        case .switchDNS(let choice): String(localized: "DNS switched to \(choice.name)", comment: "Fix it log; the argument is a resolver")
        case .renewAddress: String(localized: "Fresh address requested", comment: "Fix it log")
        case .reconnectWiFi: String(localized: "Wi-Fi reconnected", comment: "Fix it log")
        case .closerNode: String(localized: "Moved to a closer node", comment: "Fix it log")
        case .openSignIn: String(localized: "Sign-in page opened", comment: "Fix it log")
        case .signInOnNetworkDNS: String(localized: "Used the Wi-Fi’s DNS to sign in", comment: "Fix it log")
        case .holdUpload(_, let name): String(localized: "\(name)’s upload held", comment: "Fix it log; the argument is an app")
        case .pauseAirDrop: String(localized: "AirDrop paused", comment: "Fix it log")
        case .openVPN(let name): name.map { String(localized: "\($0) opened", comment: "Fix it log; the argument is a VPN") } ?? String(localized: "VPN settings opened", comment: "Fix it log")
        case .restartRouter: String(localized: "Router restarted", comment: "Fix it log")
        }
    }
    /// The one button of a step a person does.
    public var personAction: String? {
        switch self {
        case .openSignIn: String(localized: "Open sign-in page", comment: "Fix it: main button")
        case .signInOnNetworkDNS: String(localized: "Switch DNS and sign in", comment: "Fix it: main button; switches to the Wi-Fi's own DNS and opens its sign-in page")
        case .openVPN(let name): name.map { String(localized: "Open \($0)", comment: "Fix it: main button; the argument is a VPN") } ?? String(localized: "Open VPN settings", comment: "Fix it: main button")
        case .restartRouter: String(localized: "I’ve restarted it", comment: "Fix it: main button")
        default: nil
        }
    }
}

public struct FixStep: Identifiable, Equatable, Sendable {
    public let id: Int
    public let action: FixAction
    /// macOS will show its administrator prompt for this one.
    public let asksPassword: Bool
    public init(id: Int, action: FixAction, asksPassword: Bool = false) { self.id = id; self.action = action; self.asksPassword = asksPassword }
}

/// What it takes to put a kept change back.
public enum FixUndo: Equatable, Sendable {
    /// `tracked`: Fastest DNS holds the change, so it also goes back for a VPN, a sign-in page, another network or quitting.
    case dns(service: String, previous: [String], applied: [String], tracked: Bool)
    case resumeUpload(key: String)
    case resumeAirDrop
}

/// Everything Health knows that could name a cause.
public struct FixSituation: Sendable {
    public var snapshot: DiagnosticSnapshot?
    public var vpn: ExitPath.VPN
    public var vpnName: String?
    public var stuck: StuckNode?
    public var upload: (key: String, name: String)?
    public var live: FixLiveSession?
    public var airDropBusy: Bool
    public var routerSlowing: Bool
    public var portalPlace: String?
    /// What on this Mac may hide a sign-in page, read while one is in the way or likely.
    public var portalBlockers: PortalBlockers
    /// A sign-in page was seen on this network before.
    public var portalSeenHere: Bool
    public init(snapshot: DiagnosticSnapshot?, vpn: ExitPath.VPN = .off, vpnName: String? = nil, stuck: StuckNode? = nil, upload: (key: String, name: String)? = nil,
                live: FixLiveSession? = nil, airDropBusy: Bool = false, routerSlowing: Bool = false, portalPlace: String? = nil,
                portalBlockers: PortalBlockers = PortalBlockers(), portalSeenHere: Bool = false) {
        self.snapshot = snapshot; self.vpn = vpn; self.vpnName = vpnName; self.stuck = stuck; self.upload = upload
        self.live = live; self.airDropBusy = airDropBusy; self.routerSlowing = routerSlowing; self.portalPlace = portalPlace
        self.portalBlockers = portalBlockers; self.portalSeenHere = portalSeenHere
    }
}

public enum FixPlanner {
    /// `route` can report a link rather than a router, and a link-local router means macOS gave itself an address.
    static func usableGateway(_ gateway: String?) -> Bool {
        guard let gateway, AddressRange.parse(gateway) != nil else { return false }
        return !gateway.hasPrefix("169.254.")
    }
    /// Whether Wi-Fi holds an address a network gave it. The interface's own addresses decide when the check read
    /// them. Samples from before that fall back to the router's address, as Fix it always did.
    static func hasAddress(_ snapshot: DiagnosticSnapshot) -> Bool {
        if let state = snapshot.radioAddress { return state == .assigned }
        return usableGateway(snapshot.gateway)
    }

    /// The one cause worth fixing first, or nil when Health found nothing Fix it can act on. What breaks the most sits
    /// first: a sign-in page or a dead link explains every other reading. Weak signal with no closer node stays with
    /// Radar: moving the Mac is the only fix.
    public static func cause(_ situation: FixSituation) -> FixCause? {
        guard let snapshot = situation.snapshot, snapshot.setupNetwork == nil else { return nil }
        if snapshot.captivePortal == true { return .signIn(place: situation.portalPlace, blockers: situation.portalBlockers) }
        let wifi = snapshot.wiredInterface == nil && snapshot.radio.rssi != nil
        let routerAnswers = snapshot.router?.average != nil
        let internetAnswers = snapshot.reachability == .up, dnsAnswers = snapshot.dnsMilliseconds != nil
        let offline = !internetAnswers && !dnsAnswers
        // No router to ask (a VPN owns the route and the physical one can't be told, or the network has no IPv4 route)
        // says nothing about Wi-Fi: only a missing address, or a known router that is silent with nothing beyond it, does.
        let routerKnown = usableGateway(snapshot.gateway)
        if wifi && (!hasAddress(snapshot) || (routerKnown && !routerAnswers && offline)) { return .wifiStuck }
        if hiddenSignIn(situation, wifi: wifi, dnsAnswers: dnsAnswers, offline: offline) { return .signIn(place: situation.portalPlace, blockers: situation.portalBlockers) }
        if situation.vpn == .full && (offline || !dnsAnswers) { return .vpnBroken(situation.vpnName) }
        if offline { return routerAnswers ? .provider : (usableGateway(snapshot.gateway) ? .router : nil) }
        if !dnsAnswers { return situation.vpn == .off ? .dnsFailing : nil }
        if let stuck = situation.stuck { return .farNode(better: stuck.better.name) }
        if situation.airDropBusy, let live = situation.live { return .airDrop(live) }
        let ping = snapshot.measured
        let internetMs = ping.average ?? 0, routerMs = snapshot.router?.average ?? 0
        let laggy = internetMs > FixPolicy.goodInternet || (ping.jitter ?? 0) > FixPolicy.goodJitter || (ping.lossPercent ?? 0) >= FixPolicy.goodLoss
        if laggy, let upload = situation.upload { return .upload(key: upload.key, name: upload.name) }
        if situation.vpn == .off, (snapshot.dnsMilliseconds ?? 0) > FixPolicy.goodDNS { return .dnsSlow }
        if situation.routerSlowing { return .router }
        // Slow to the router on a weak signal is the signal's doing, and a VPN's latency is the VPN's.
        let radioFine = snapshot.activeRadioHealth.map { $0 == .good } ?? true
        if radioFine, routerMs > FixPolicy.goodRouter { return .router }
        guard situation.vpn == .off else { return nil }
        if internetMs > FixPolicy.goodInternet, routerMs < FixPolicy.goodRouter { return .provider }
        if snapshot.heavyLoss || snapshot.reachability == .down, (snapshot.router?.lossPercent ?? 100) < FixPolicy.goodLoss { return .provider }
        return nil
    }

    /// A sign-in page this Mac's own settings hide: on a network that showed one before, or Wi-Fi with no password,
    /// lookups or everything fail while this Mac has its own DNS, encrypted DNS or a VPN on. The page can't be seen
    /// then, so the checks read as DNS or the provider failing. Nothing on the Mac in the way means it's the network.
    static func hiddenSignIn(_ situation: FixSituation, wifi: Bool, dnsAnswers: Bool, offline: Bool) -> Bool {
        guard let snapshot = situation.snapshot, wifi, offline || !dnsAnswers, usableGateway(snapshot.gateway) else { return false }
        let blockers = situation.portalBlockers
        guard blockers.switchesDNS || blockers.encryptedDNS || blockers.vpn else { return false }
        return situation.portalSeenHere || snapshot.radio.securityInfo?.level == .open
    }

    /// What to try for a cause, safest first. `helper` is whether the root helper can act without a password.
    public static func steps(for cause: FixCause, helper: Bool, dns: [DNSResolverChoice] = []) -> [FixStep] {
        let actions: [FixAction]
        switch cause {
        case .dnsFailing, .dnsSlow: actions = dns.prefix(2).map(FixAction.switchDNS)
        // Renewing needs root: only through the helper, so the fix never costs a password. Reconnecting gets an address too.
        case .wifiStuck: actions = (helper ? [.renewAddress] : []) + [.reconnectWiFi]
        // The page and the person's own DNS together: switching alone signs nobody in, so it's one step.
        case .signIn(_, let blockers): actions = [blockers.switchesDNS ? .signInOnNetworkDNS : .openSignIn]
        case .farNode: actions = [.closerNode]
        case .upload(let key, let name): actions = [.holdUpload(key: key, name: name)]
        case .airDrop: actions = [.pauseAirDrop]
        case .vpnBroken(let name): actions = [.openVPN(name)]
        case .router: actions = [.restartRouter]
        case .provider: actions = []
        }
        return actions.prefix(FixPolicy.mostSteps).enumerated().map { index, action in
            let password: Bool
            switch action {
            case .switchDNS, .signInOnNetworkDNS: password = !helper
            case .pauseAirDrop: password = true
            default: password = false
            }
            return FixStep(id: index, action: action, asksPassword: password)
        }
    }

    /// Resolvers worth switching to, from timings just taken: they answered, this Mac isn't on them, and they beat what
    /// it uses by a clear margin. The fastest first; no point asking for a password for one that wouldn't help.
    public static func dnsCandidates(inUse: [String], currentMs: Double?, timed: [(choice: DNSResolverChoice, ms: Double?)]) -> [DNSResolverChoice] {
        let current = Set(inUse)
        return timed.compactMap { item -> (DNSResolverChoice, Double)? in
            guard let ms = item.ms, !item.choice.isNetwork, current.isDisjoint(with: item.choice.servers) else { return nil }
            if let currentMs, currentMs - ms < max(currentMs * FixPolicy.improvedShare, FixPolicy.improvedMs) { return nil }
            return (item.choice, ms)
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

/// What a reading says about the step just tried.
public enum FixVerdict: Equatable, Sendable { case cleared, better, same, worse }

public enum FixJudge {
    public static func verdict(_ cause: FixCause, before: FixReading, after: FixReading) -> FixVerdict {
        let then = cause.metric(before), now = cause.metric(after)
        if now.good { return .cleared }
        guard let old = then.value.number, let new = now.value.number else {
            // Nothing answered before and something does now is progress; the reverse is not.
            if now.value.number != nil { return .better }
            return then.value.number != nil ? .worse : .same
        }
        let gain = now.value.higherIsBetter ? new - old : old - new
        let needed: Double
        switch now.value {
        case .ms: needed = max(abs(old) * FixPolicy.improvedShare, FixPolicy.improvedMs)
        case .dBm: needed = FixPolicy.improvedDB
        case .state: needed = 1
        }
        if gain >= needed { return .better }
        return gain <= -needed ? .worse : .same
    }
}

/// How a run ends. Fixed, Better and This isn't your Mac are the three results; the other two mean nothing was judged.
public enum FixOutcome: Equatable, Sendable {
    case fixed, better
    case notYourMac(FixWho)
    /// The first reading was already fine: nothing tried.
    case noIssue
    /// Nothing could be tried: the person declined, stopped, or a step couldn't run.
    case stopped(String?)
}

/// What happened to the step just judged, for the log.
public enum FixDecision: Equatable, Sendable { case keep, undo, noEffect }

/// The run, one decision at a time. It asks for what to do next and is told what happened; the runner and the tests
/// do the doing, so every path can be exercised without a network.
public struct FixEngine: Sendable {
    public enum Command: Equatable, Sendable {
        /// This step drops Wi-Fi during `FixLiveSession`: ask first.
        case ask(FixStep, FixLiveSession)
        case apply(FixStep)
        case person(FixStep)
        case measure(FixStep, after: TimeInterval)
        case steady(FixStep, passed: Int)
        case undo(FixStep)
        case finish(FixOutcome)
    }

    public let cause: FixCause
    public let steps: [FixStep]
    public let baseline: FixReading
    public private(set) var reference: FixReading
    public private(set) var command: Command
    public private(set) var verdict: FixVerdict?
    public private(set) var decision: FixDecision?
    public private(set) var kept: [FixStep] = []
    private let live: FixLiveSession?
    private var index = 0
    private var tried = false, reason: String?

    public init(cause: FixCause, steps: [FixStep], baseline: FixReading, live: FixLiveSession? = nil) {
        self.cause = cause; self.steps = Array(steps.prefix(FixPolicy.mostSteps)); self.baseline = baseline; self.live = live
        reference = baseline
        command = .finish(.noIssue)
        if !cause.metric(baseline).good { command = commandForCurrentStep() }
    }

    /// The step being worked on, while there is one.
    public var step: FixStep? { index < steps.count ? steps[index] : nil }
    public var position: Int { min(index, steps.count) }

    private func commandForCurrentStep() -> Command {
        guard index < steps.count else { return .finish(result) }
        let step = steps[index]
        if step.action.dropsWiFi, let live, live.interruptedByWiFiDrop { return .ask(step, live) }
        return step.action.needsPerson ? .person(step) : .apply(step)
    }
    private var result: FixOutcome {
        if !kept.isEmpty { return .better }
        return tried || steps.isEmpty ? .notYourMac(cause.who) : .stopped(reason)
    }
    private mutating func advance() { index += 1; command = commandForCurrentStep() }

    /// The person agreed to the Wi-Fi drop.
    public mutating func allowed() {
        guard case .ask(let step, _) = command else { return }
        command = step.action.needsPerson ? .person(step) : .apply(step)
    }
    /// The person said not now, so this step is skipped.
    public mutating func declined() {
        guard case .ask = command else { return }
        decision = nil; verdict = nil
        advance()
    }
    /// The change is in place (or the page is open and the person has acted); the next reading judges it.
    public mutating func applied() {
        guard let step, case .apply = command else { return }
        tried = true
        command = .measure(step, after: step.action.settle)
    }
    public mutating func acted() {
        guard let step, case .person = command else { return }
        tried = true
        command = .measure(step, after: step.action.settle)
    }
    /// The step couldn't run, such as a cancelled password prompt. A person's step only fails when Kilobat's part of it,
    /// such as switching DNS before the page, couldn't be done.
    public mutating func failed(_ message: String?) {
        switch command { case .apply, .person: break; default: return }
        reason = message
        decision = nil; verdict = nil
        advance()
    }

    public mutating func measured(_ reading: FixReading) {
        decision = nil
        switch command {
        case .measure(let step, _):
            let verdict = FixJudge.verdict(cause, before: reference, after: reading)
            self.verdict = verdict
            switch verdict {
            case .cleared: command = .steady(step, passed: 1)
            case .better: keep(step, reading)
            case .same, .worse: drop(step)
            }
        case .steady(let step, let passed):
            if cause.metric(reading).good {
                if passed + 1 >= FixPolicy.steadyReadings {
                    if !kept.contains(step) { kept.append(step) }
                    decision = .keep; verdict = .cleared
                    command = .finish(.fixed)
                } else { command = .steady(step, passed: passed + 1) }
            } else {
                // It didn't last: still better than before it's kept, else it goes.
                verdict = FixJudge.verdict(cause, before: reference, after: reading)
                if verdict == .better { keep(step, reading) } else { drop(step) }
            }
        default: break
        }
    }
    /// The change was put back; on to the next step.
    public mutating func undone() {
        guard case .undo = command else { return }
        advance()
    }
    private mutating func keep(_ step: FixStep, _ reading: FixReading) {
        kept.append(step); reference = reading; decision = .keep
        advance()
    }
    private mutating func drop(_ step: FixStep) {
        if step.action.undoable {
            decision = .undo
            command = .undo(step)
        } else {
            decision = .noEffect
            advance()
        }
    }
}

public extension FixAction {
    /// Whether anything stays changed that can be put back. Renewing and reconnecting leave nothing behind.
    var undoable: Bool {
        switch self { case .switchDNS, .signInOnNetworkDNS, .holdUpload, .pauseAirDrop: true; default: false }
    }
}

/// One line of the log of what changed.
public struct FixLogEntry: Identifiable, Equatable, Sendable {
    /// `restored`: a change made only for the run, put back once it ended.
    /// `undoFailed`: putting the change back didn't work; it is still in place and `undo` can be tried again.
    public enum Status: Equatable, Sendable { case kept, undone, noEffect, skipped, restored, failed(String?), undoFailed(String?) }
    public let id: Int
    public let action: FixAction
    public let date: Date
    public var status: Status
    public var undo: FixUndo?
    public init(id: Int, action: FixAction, date: Date, status: Status, undo: FixUndo? = nil) {
        self.id = id; self.action = action; self.date = date; self.status = status; self.undo = undo
    }
    public var note: String {
        switch status {
        case .kept: String(localized: "Kept", comment: "Fix it log: the change helped and stays")
        case .undone: String(localized: "Undone", comment: "Fix it log: the change didn't help and was put back")
        case .noEffect: String(localized: "Didn’t help", comment: "Fix it log: nothing to put back")
        case .skipped: String(localized: "Skipped", comment: "Fix it log: the person said not now")
        case .restored: String(localized: "Your DNS is back", comment: "Fix it log: the person's own DNS was put back after the Wi-Fi sign-in")
        case .failed(let message): message ?? String(localized: "Couldn’t run", comment: "Fix it log")
        case .undoFailed(let message):
            message.map { String(localized: "Couldn’t undo: \($0)", comment: "Fix it log: putting a change back failed; the argument is the reason") }
                ?? String(localized: "Couldn’t undo", comment: "Fix it log: putting a change back failed")
        }
    }
    /// Still in place, with a way to put it back: kept, or an undo that failed.
    public var canUndo: Bool { guard undo != nil else { return false }; if case .undoFailed = status { return true }; return status == .kept }
}
