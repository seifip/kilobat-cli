import Foundation
import Observation

/// The fastest DNS for each network: quiet runs a few times a day, the remembered choice per network, the switch on
/// joining (Pro, opt-in, through Kilobat's helper) and the watchdog that takes it back. Kept in fastest-dns.json.
/// Kilobat only ever undoes its own change: DNS the person set, a VPN's, a profile's, is left exactly as it is.
@MainActor @Observable public final class FastestDNSWatch {
    public private(set) var records: [DNSNetworkRecord] = []
    public private(set) var switches: [DNSSwitch] = []
    /// What Kilobat has set on a network service right now, if anything.
    public private(set) var applied: DNSApplied?
    /// The network Kilobat is on now.
    public private(set) var current: String?
    /// The current network's verdict, why DNS stays as it is, and why no run is starting.
    public private(set) var verdict: FastestDNS.Verdict?
    public private(set) var hold: FastestDNS.Hold?
    public private(set) var wait: FastestDNS.Wait?
    public private(set) var measuring = false
    public private(set) var error: String?

    /// Pro, read when switching. Measuring and the verdict are free.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    /// The person's settings: on per network or everywhere, excluded and added resolvers.
    @ObservationIgnored public var preferences: () -> SavedPreferences? = { nil }
    /// Turns the setting off for one network (Undo does, so it doesn't switch straight back).
    @ObservationIgnored public var disable: ((String) -> Void)?
    /// Each switch, for the History log.
    @ObservationIgnored public var onSwitch: ((DNSSwitch) -> Void)?
    @ObservationIgnored public var applier: DNSApplying?
    @ObservationIgnored private let system: DNSSystem
    @ObservationIgnored private let probe: DNSProbing
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var watchdog = FastestDNS.Watchdog()
    @ObservationIgnored private var managed: (value: Bool, read: Date)?
    @ObservationIgnored private var last: Context?
    @ObservationIgnored private var acting = false
    @ObservationIgnored private var paths: NetworkStatus?

    nonisolated public static let fileName = "fastest-dns.json"
    public struct Saved: Codable, Sendable {
        public var current: String?
        public var networks: [DNSNetworkRecord]
        public var switches: [DNSSwitch]
        public var applied: DNSApplied?
    }

    /// What one health check knew, for the switch.
    public struct Context: Sendable, Equatable {
        public var network: String?
        public var name: String
        public var service: String?
        public var interface: String?
        public var gateway: String?
        /// The resolvers macOS uses now, for the network's own when DHCP doesn't say.
        public var resolvers: [String]
        public var lookupWorked: Bool
        public var networkUp: Bool
        public var moment: FastestDNS.Moment
        public init(network: String?, name: String, service: String?, interface: String?, gateway: String?, resolvers: [String],
                    lookupWorked: Bool, networkUp: Bool, moment: FastestDNS.Moment) {
            self.network = network; self.name = name; self.service = service; self.interface = interface; self.gateway = gateway
            self.resolvers = resolvers; self.lookupWorked = lookupWorked; self.networkUp = networkUp; self.moment = moment
        }
    }

    /// `directory` nil keeps everything in memory, as screenshot runs and tests need.
    public init(directory: URL?, system: DNSSystem = SystemDNS(), probe: DNSProbing = SystemDNSProbe(), calendar: Calendar = .current) {
        self.system = system; self.probe = probe; self.calendar = calendar
        file = directory?.appendingPathComponent(Self.fileName)
        if let file, let saved: Saved = StoredJSON.read(file) {
            records = saved.networks; switches = saved.switches; applied = saved.applied; current = saved.current
            // Records from before the history: start it from the runs they kept.
            for index in records.indices where records[index].tallies == nil { records[index].tallies = FastestDNS.tallies(from: records[index].runs, calendar: calendar) }
        }
    }
    /// Kilobat's own folder; in a screenshot run (KILOBAT_SNAPSHOT) nothing is read, written, measured or switched.
    public convenience init() {
        let snapshot = ProcessInfo.processInfo.environment["KILOBAT_SNAPSHOT"] != nil
        self.init(directory: snapshot ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat"))
        inert = snapshot
    }
    @ObservationIgnored private var inert = false

    /// Read-only, for the CLI: what the app last saved.
    nonisolated public static func load(directory: URL? = nil) -> Saved {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        return StoredJSON.read(folder.appendingPathComponent(fileName)) ?? Saved(current: nil, networks: [], switches: [], applied: nil)
    }

    public var record: DNSNetworkRecord? { current.flatMap { key in records.first { $0.network == key } } }

    /// Watches for a network change between health checks: when the router's address changes under Kilobat's own DNS
    /// change, it goes at once, so the next network's sign-in page and local names get its own DNS.
    public func start() {
        guard paths == nil, !inert else { return }
        let status = NetworkStatus()
        status.start { [weak self] _, _, _ in Task { @MainActor in await self?.pathChanged() } }
        paths = status
    }

    private func pathChanged() async {
        guard let applied, !acting else { return }
        let gateway = await system.gateway()
        guard gateway != applied.gateway else { return }
        await revert(.leftNetwork, now: Date())
    }

    // MARK: Each check

    public func observe(_ context: Context, now: Date = Date()) async {
        guard !inert else { return }
        last = context
        current = context.network
        let preferences = preferences() ?? SavedPreferences()
        let index = context.network.map { record(network: $0, name: context.name, now: now) }

        // The watchdog first: Kilobat's own change goes when lookups stop working through it, to the person's
        // fallback when there's one that works, else to the network's own.
        if let applied, applied.network == context.network {
            var answered: Bool?
            if !context.lookupWorked, context.networkUp, let server = applied.servers.first { answered = await probe.lookup("example.com", server: server).answered }
            if watchdog.observe(applied: true, lookupWorked: context.lookupWorked, resolverAnswered: answered, networkUp: context.networkUp) {
                if let index { records[index].failedUntil[applied.resolver] = now.addingTimeInterval(FastestDNS.failurePause) }
                if let index, let fallback = usableFallback(index: index, preferences: preferences, now: now), fallback.id != applied.resolver {
                    await useFallback(fallback, context: context, index: index, now: now)
                } else { await revert(.watchdog, now: now) }
            }
        } else { _ = watchdog.observe(applied: false, lookupWorked: true, resolverAnswered: nil, networkUp: true) }

        if let index {
            let next = FastestDNS.decide(runs: records[index].runs, incumbent: records[index].choice, excluded: preferences.dnsExcludedSet,
                                         now: now, calendar: calendar)
            if next.choice != records[index].choice { records[index].choice = next.choice; records[index].choiceSince = now }
            verdict = next
        } else { verdict = nil }

        var servers: [String] = []
        if let service = context.service { servers = await system.serviceServers(service) }
        let failed = index.map { records[$0].failed(at: now) } ?? []
        let situation = FastestDNS.Situation(network: context.network, enabled: context.network.map(preferences.fastestDNSEnabled(on:)) ?? false,
                                             pro: allowed(), helper: applier?.available ?? false, vpn: context.moment.vpn, managed: await isManaged(now: now),
                                             portal: context.moment.portal, serviceServers: servers, applied: applied, verdict: verdict, failed: failed,
                                             fallback: index.flatMap { usableFallback(index: $0, preferences: preferences, now: now) })
        await act(FastestDNS.plan(situation), context: context, now: now)

        wait = FastestDNS.wait(context.moment, runs: index.map { records[$0].runs } ?? [], now: now)
        if wait == nil, !measuring, let index { measure(index: index, context: context, preferences: preferences) }
        save()
    }

    private func act(_ action: FastestDNS.Action, context: Context, now: Date) async {
        switch action {
        case .hold(let reason): hold = reason
        case .forget: applied = nil; hold = .ownDNS
        case .revert(let reason): await revert(reason, now: now); hold = nil
        case .fallback(let choice):
            guard let network = context.network, let index = records.firstIndex(where: { $0.network == network }) else { return }
            await useFallback(choice, context: context, index: index, now: now)
        case .apply(let choice):
            guard let network = context.network, let service = context.service, let applier, !acting, !inert else { return }
            acting = true; defer { acting = false }
            let from = applied?.resolver ?? DNSResolverChoice.network.id
            do {
                try await applier.apply(servers: choice.servers, service: service)
                applied = DNSApplied(network: network, networkName: context.name, service: service, resolver: choice.id, servers: choice.servers, gateway: context.gateway, date: now)
                watchdog = FastestDNS.Watchdog()
                log(DNSSwitch(date: now, network: network, networkName: context.name, from: from, to: choice.id, reason: .fastest))
                hold = .applied; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    /// The person's fallback on this network now: set, not left out, not failing in the latest run, and not paused here.
    private func usableFallback(index: Int, preferences: SavedPreferences, now: Date) -> DNSResolverChoice? {
        guard let choice = FastestDNS.fallback(preferences.dnsFallback, excluded: preferences.dnsExcludedSet, latest: records[index].runs.last),
              !records[index].failed(at: now).contains(choice.id) else { return nil }
        return choice
    }

    /// Moves to the fallback, from Kilobat's own change or from automatic DNS. Only to a resolver that answers Kilobat's
    /// own lookup right now; if it doesn't, or the change doesn't take, it's paused here like a failed pick and automatic
    /// DNS goes back, so the Mac is never left on a resolver that isn't answering.
    private func useFallback(_ choice: DNSResolverChoice, context: Context, index: Int, now: Date) async {
        guard let network = context.network, let service = applied?.service ?? context.service, let applier, !acting, !inert else { return }
        guard applier.available else { await revert(.watchdog, now: now); return }
        let answers: Bool
        if let server = choice.servers.first { answers = await probe.lookup("example.com", server: server).answered } else { answers = false }
        guard answers else {
            records[index].failedUntil[choice.id] = now.addingTimeInterval(FastestDNS.failurePause)
            if applied != nil { await revert(.watchdog, now: now) } else { hold = .failedRecently }
            return
        }
        let from = applied?.resolver ?? DNSResolverChoice.network.id
        acting = true
        do {
            try await applier.apply(servers: choice.servers, service: service)
            acting = false
            applied = DNSApplied(network: network, networkName: context.name, service: service, resolver: choice.id, servers: choice.servers,
                                 gateway: context.gateway, date: now, fallback: true)
            watchdog = FastestDNS.Watchdog()
            log(DNSSwitch(date: now, network: network, networkName: context.name, from: from, to: choice.id, reason: .fallback))
            hold = .onFallback; error = nil
        } catch {
            acting = false
            records[index].failedUntil[choice.id] = now.addingTimeInterval(FastestDNS.failurePause)
            let message = error.localizedDescription
            // Whatever the service has now, automatic DNS is the safe place to leave it.
            if applied != nil { await revert(.watchdog, now: now) } else { try? await applier.apply(servers: [], service: service) }
            self.error = message
        }
    }

    /// Puts automatic DNS back on the service Kilobat changed. Without the helper the change stays, and the panel
    /// says so: the person can choose Automatic there.
    private func revert(_ reason: DNSSwitch.Reason, now: Date) async {
        guard let done = applied, !acting, !inert else { return }
        guard let applier, applier.available else { error = String(localized: "Kilobat’s helper isn’t available to put automatic DNS back. Choose Automatic in Health › DNS."); return }
        acting = true; defer { acting = false }
        do {
            try await applier.apply(servers: [], service: done.service)
            applied = nil; error = nil; watchdog = FastestDNS.Watchdog()
            log(DNSSwitch(date: now, network: done.network, networkName: done.networkName, from: done.resolver, to: DNSResolverChoice.network.id, reason: reason))
            save()
        } catch { self.error = error.localizedDescription }
    }

    /// Undo: back to the network's own DNS, and the setting off for this network so it stays that way.
    public func undo() async {
        guard let done = applied else { return }
        disable?(done.network)
        await revert(.undo, now: Date())
    }

    /// On quit Kilobat puts automatic DNS back, so a network joined while it isn't running never inherits its choice.
    /// `automatic` puts automatic DNS back on a service synchronously and says whether it did: the app is
    /// terminating, when Swift tasks no longer run.
    public func quit(automatic: (String) -> Bool) {
        guard let done = applied, !inert, automatic(done.service) else { return }
        applied = nil
        log(DNSSwitch(date: Date(), network: done.network, networkName: done.networkName, from: done.resolver, to: DNSResolverChoice.network.id, reason: .quit))
    }

    /// A run now, from the panel's Test now. Not through a VPN or a sign-in page, where it would time the wrong thing.
    public func measureNow() {
        guard let context = last, !measuring, let network = context.network, !context.moment.vpn, !context.moment.portal else { return }
        let index = record(network: network, name: context.name, now: Date())
        measure(index: index, context: context, preferences: preferences() ?? SavedPreferences())
    }

    private func measure(index: Int, context: Context, preferences: SavedPreferences) {
        let network = records[index].network
        measuring = true
        Task { [weak self, system, probe] in
            // The network's own: what DHCP handed out, or what macOS uses when DNS is automatic.
            var servers: [String] = []
            if let interface = context.interface { servers = await system.dhcpServers(interface: interface) }
            if servers.isEmpty, let service = context.service, await system.serviceServers(service).isEmpty { servers = context.resolvers.filter(DNSAddress.valid) }
            let run = await FastestDNSMeter.run(candidates: preferences.dnsCandidates(), networkServers: servers, probe: probe)
            guard let self else { return }
            self.measuring = false
            guard !run.resolvers.isEmpty, let index = self.records.firstIndex(where: { $0.network == network }) else { return }
            self.records[index].runs = Array((self.records[index].runs + [run]).filter { run.date.timeIntervalSince($0.date) <= FastestDNS.window }.suffix(FastestDNS.keptRuns))
            self.records[index].tallies = FastestDNS.tally(run, into: self.records[index].tallies ?? [], calendar: self.calendar)
            if self.current == network {
                self.verdict = FastestDNS.decide(runs: self.records[index].runs, incumbent: self.records[index].choice, excluded: preferences.dnsExcludedSet,
                                                 calendar: self.calendar)
            }
            self.save()
        }
    }

    private func isManaged(now: Date) async -> Bool {
        if let managed, now.timeIntervalSince(managed.read) < 300 { return managed.value }
        let value = await system.managed()
        managed = (value, now)
        return value
    }

    private func record(network: String, name: String, now: Date) -> Int {
        if let index = records.firstIndex(where: { $0.network == network }) { records[index].name = name; records[index].lastSeen = now; return index }
        records.append(DNSNetworkRecord(network: network, name: name, lastSeen: now))
        return records.count - 1
    }

    private func log(_ change: DNSSwitch) {
        switches = Array((switches + [change]).suffix(100))
        onSwitch?(change)
        save()
    }

    private func save() {
        guard let file else { return }
        // Networks not seen for 90 days go.
        records.removeAll { Date().timeIntervalSince($0.lastSeen) > 90 * 86_400 }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Saved(current: current, networks: records, switches: switches, applied: applied)).write(to: file, options: .atomic)
    }

    #if DEBUG
    /// Sample networks for screenshots; debug builds only.
    public func preview(_ record: DNSNetworkRecord, applied: DNSApplied? = nil, switches: [DNSSwitch] = [], hold: FastestDNS.Hold? = nil, now: Date = Date()) {
        records = [record]; current = record.network; self.applied = applied; self.switches = switches; self.hold = hold
        verdict = FastestDNS.decide(runs: record.runs, incumbent: record.choice, now: now)
    }
    #endif
}
