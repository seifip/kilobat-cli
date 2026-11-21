import Foundation
import Observation

/// Changes the network service order. The app's applier goes through Kilobat's helper when it's on (no password), and
/// otherwise through macOS's administrator prompt, but only when `prompt` says the person just clicked.
@MainActor public protocol ServiceOrderApplying: AnyObject {
    /// Kilobat's helper is on, so a change needs no password: the only way the order is put back on its own.
    var automatic: Bool { get }
    func apply(order: [String], expected: [String], prompt: Bool) async throws
}

/// The internet priority switch: which connections are up, the one carrying the internet, and the order Kilobat
/// changed, put back when the person turns it off, when the chosen connection goes away, when Kilobat quits, and at
/// the next launch if it couldn't. A change made elsewhere since is the person's own and is left alone.
@MainActor @Observable public final class InternetPriorityStore {
    public private(set) var routes: [ConnectionRoute] = []
    public private(set) var hold: PriorityHold?
    public private(set) var busy = false
    public var error: String?
    /// A one-off line after something changed: the order put back, or left alone because it changed elsewhere.
    public private(set) var notice: String?
    /// The order should go back but needs the person's click: no helper to do it without a password.
    public private(set) var restoreWaiting = false

    @ObservationIgnored public weak var applier: ServiceOrderApplying?
    @ObservationIgnored var readRoutes: () -> [ConnectionRoute] = InternetRoutes.read
    @ObservationIgnored var checkInternet: (String) async -> Bool = InternetRoutes.internet(through:)
    @ObservationIgnored var readOrder: () async -> [String]? = { await InternetRoutes.order()?.map(\.name) }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var goneSince: Date?
    @ObservationIgnored private var checked: [String: (date: Date, internet: Bool)] = [:]
    @ObservationIgnored private var checking: Set<String> = []
    /// A route's internet check is kept this long.
    static let checkFresh: TimeInterval = 90

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hold = PriorityHold.load(defaults)
    }

    #if DEBUG
    /// Made-up state for screenshots; debug builds only.
    public func preview(routes: [ConnectionRoute], hold: PriorityHold? = nil, restoreWaiting: Bool = false, notice: String? = nil) {
        self.routes = routes; self.hold = hold; self.restoreWaiting = restoreWaiting; self.notice = notice
    }
    #endif

    public var carrier: ConnectionRoute? { InternetPriority.carrier(routes) }
    public var candidates: [ConnectionRoute] { InternetPriority.candidates(routes) }
    public var twoUp: Bool { InternetPriority.twoUp(routes) }
    /// The route the switch is on for, while it's on and still up.
    public var active: ConnectionRoute? { hold.flatMap { hold in routes.first { $0.service == hold.service } } }

    /// Reads the connections (cheap: the dynamic store), checks the internet on the ones not carrying it at most every
    /// 90 seconds, and puts the order back when the chosen connection has been gone a while.
    public func refresh(now: Date = Date()) async {
        var fresh = readRoutes()
        for index in fresh.indices {
            if let known = checked[fresh[index].interface], now.timeIntervalSince(known.date) < Self.checkFresh { fresh[index].internet = known.internet }
        }
        routes = fresh
        for route in fresh where !route.primary && route.router != nil && route.internet == nil && !checking.contains(route.interface) {
            checking.insert(route.interface)
            let answered = await checkInternet(route.interface)
            checking.remove(route.interface)
            checked[route.interface] = (Date(), answered)
            if let index = routes.firstIndex(where: { $0.interface == route.interface }) { routes[index].internet = answered }
        }
        guard let hold else { goneSince = nil; return }
        if routes.contains(where: { $0.service == hold.service }) { goneSince = nil; return }
        if goneSince == nil { goneSince = now }
        if InternetPriority.shouldRestore(hold, routes: routes, goneSince: goneSince, now: now) {
            await restore(prompt: false, reason: String(localized: "\(hold.service) went away, so Kilobat put Wi-Fi first again.", comment: "Internet priority notice; the argument is a connection such as iPhone USB"))
        }
    }

    /// The switch: moves `route` to the top of the service order. The person's click.
    public func use(_ route: ConnectionRoute, wifi: String?) async {
        guard !busy, let applier else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        guard let current = await readOrder() else { error = String(localized: "Couldn’t read the network service order.", comment: "Internet priority error"); return }
        guard let order = ServiceOrder.promoting(route.service, in: current) else {
            if current.first == route.service { notice = String(localized: "\(route.service) is already first in the service order.", comment: "Internet priority notice; the argument is a connection such as iPhone USB") }
            else { error = String(localized: "\(route.service) isn’t in the network service order.", comment: "Internet priority error; the argument is a connection") }
            return
        }
        // A hold from before stays the one to go back to: the order the person had, not one Kilobat made.
        let previous = hold?.previous ?? current
        do {
            try await applier.apply(order: order, expected: current, prompt: true)
            let saved = PriorityHold(service: route.service, interface: route.interface, previous: previous, applied: order, wifi: wifi)
            saved.save(defaults); hold = saved; restoreWaiting = false
            routes = readRoutes()
        } catch { self.error = error.localizedDescription }
    }

    /// The person turned it off.
    public func turnOff() async { await restore(prompt: true, reason: nil) }
    /// The Mac left the Wi-Fi the switch was for. Through the helper; otherwise Health offers the button.
    public func leaveDevice(reason: String) async { await restore(prompt: false, reason: reason) }

    /// At launch: an order a quit or crash left behind goes back, through the helper; without it, Health offers the button,
    /// since a password prompt at launch would come from nowhere.
    public func recover() async {
        guard let hold else { return }
        guard let applier, applier.automatic else { restoreWaiting = true; return }
        await restore(prompt: false, reason: String(localized: "Kilobat put Wi-Fi first again: \(hold.service) was still first from before it quit.", comment: "Internet priority notice at launch; the argument is a connection such as iPhone USB"))
    }

    /// On quit, synchronously (Swift tasks don't run while the app terminates): `blocking` asks the helper and waits a
    /// few seconds. Without the helper the hold stays for the next launch.
    public func quit(_ blocking: (_ order: [String], _ expected: [String]) -> Bool, current: [String]?) {
        guard let hold, let current else { return }
        switch InternetPriority.restore(hold, current: current) {
        case .apply(let order): if blocking(order, current) { PriorityHold.clear(defaults) }
        case .leave: PriorityHold.clear(defaults)
        }
    }

    private func restore(prompt: Bool, reason: String?) async {
        guard let hold, !busy else { return }
        guard let applier, prompt || applier.automatic else { restoreWaiting = true; return }
        busy = true; error = nil
        defer { busy = false }
        guard let current = await readOrder() else { error = String(localized: "Couldn’t read the network service order.", comment: "Internet priority error"); return }
        switch InternetPriority.restore(hold, current: current) {
        case .leave(let elsewhere):
            notice = elsewhere ? String(localized: "The service order was changed elsewhere since, so Kilobat left it as it is.", comment: "Internet priority notice") : reason
            finish()
        case .apply(let order):
            do {
                try await applier.apply(order: order, expected: current, prompt: prompt)
                notice = reason
                finish()
            } catch {
                self.error = error.localizedDescription
                if !prompt { restoreWaiting = true }
            }
        }
    }

    private func finish() {
        PriorityHold.clear(defaults); hold = nil; restoreWaiting = false; goneSince = nil
        routes = readRoutes()
    }
}
