import Foundation
import Observation

/// One app's traffic as the casting watch needs it: totals to the local network, rates, and what to hold.
public struct CastingApp: Sendable {
    public let id: String
    public let name: String
    public let local: UInt64
    public let upload: Double
    public let download: Double
    public let pids: [Int32]
    public init(id: String, name: String, local: UInt64, upload: Double, download: Double, pids: [Int32]) {
        self.id = id; self.name = name; self.local = local; self.upload = upload; self.download = download; self.pids = pids
    }
}

/// While the Mac AirPlays or casts a tab, checks every five seconds what on its side can make the stream stutter:
/// 2.4 GHz, a weak signal, AirDrop's link, another app's big transfer. It reuses the Bluetooth audio watch's 5 GHz pick
/// and AirDrop pause, and call mode's hold for background apps (Pro). It never scans Wi-Fi while casting.
@MainActor @Observable public final class CastingWatch {
    /// The latest check while casting; nil otherwise.
    public private(set) var check: CastingCheck?
    /// Apps Kilobat paused for this cast.
    public private(set) var holding: [String] = []
    public private(set) var holdingAirDrop = false
    public private(set) var joining = false
    public var error: String?
    /// Every app's traffic, from the traffic store in the app.
    @ObservationIgnored public var apps: () -> [CastingApp] = { [] }
    /// Whether pausing background apps is allowed: Kilobat Pro, like call mode.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    /// The sound output's Core Audio transport type and name.
    @ObservationIgnored public var output: () -> (transport: UInt32, name: String)? = { BluetoothAudioProbe.defaultOutput() }

    /// Casting gone this long ends the session, and what Kilobat paused for it comes back.
    public static let gap: TimeInterval = 90
    public static let holdLimit: TimeInterval = 3600

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastLocal: (bytes: [String: UInt64], date: Date)?
    @ObservationIgnored private var awdl: AWDLStatus?
    @ObservationIgnored private var lastAWDL = Date.distantPast
    @ObservationIgnored private var lastSeen: Date?
    @ObservationIgnored private var started: Date?
    @ObservationIgnored private var known: Set<String>?
    @ObservationIgnored private weak var diagnostics: DiagnosticStore?

    public init() {}

    #if DEBUG
    /// A made-up check for screenshots; debug builds only.
    public func preview(_ check: CastingCheck?) { loop?.cancel(); loop = nil; self.check = check }
    #endif

    public func start(diagnostics: DiagnosticStore) {
        guard loop == nil else { return }
        self.diagnostics = diagnostics
        loop = Task { [weak self, weak diagnostics] in
            while !Task.isCancelled {
                guard let self, let diagnostics else { return }
                await self.tick(diagnostics)
                try? await Task.sleep(for: .seconds(self.check == nil ? 10 : 5))
            }
        }
    }

    /// Each app's local-network rate since the last reading, in bytes a second.
    nonisolated public static func localRates(previous: [String: UInt64]?, current: [String: UInt64], seconds: TimeInterval) -> [String: Double] {
        guard let previous, seconds > 0.5 else { return [:] }
        var rates: [String: Double] = [:]
        for (name, bytes) in current { if let before = previous[name], bytes > before { rates[name] = Double(bytes - before) / seconds } }
        return rates
    }

    private func tick(_ diagnostics: DiagnosticStore) async {
        let now = Date()
        let apps = self.apps()
        let totals = Dictionary(apps.map { ($0.name, $0.local) }, uniquingKeysWith: +)
        let rates = Self.localRates(previous: lastLocal?.bytes, current: totals, seconds: lastLocal.map { now.timeIntervalSince($0.date) } ?? 0)
        lastLocal = (totals, now)
        let sound = output()
        guard !diagnostics.sleeping, let activity = CastingActivity.detect(outputTransport: sound?.transport, outputName: sound?.name, local: rates) else {
            // A moment's quiet (a paused video) keeps the line; a longer one ends the session and lets go of what it paused.
            if let lastSeen {
                if now.timeIntervalSince(lastSeen) > Self.gap { end() } else if now.timeIntervalSince(lastSeen) > 15 { check = nil }
            }
            return
        }
        if started == nil { started = now }
        lastSeen = now
        if let started, now.timeIntervalSince(started) > Self.holdLimit, !holding.isEmpty { releaseBackground() }
        let radio = diagnostics.radio
        var conditions = CastingConditions()
        conditions.wifiBand = radio?.band; conditions.wifiName = radio?.ssid; conditions.rssi = radio?.rssi
        if now.timeIntervalSince(lastAWDL) >= 30 { lastAWDL = now; awdl = await NearbyRadios.awdlStatus() }
        conditions.airDropActive = awdl.map { $0.up && $0.active }
        conditions.airDropUsers = awdl?.users ?? []
        if let top = apps.filter({ $0.name != activity.sender }).max(by: { $0.upload + $0.download < $1.upload + $1.download }), top.upload + top.download >= CastingCheck.heavyBytesPerSecond / 4 {
            conditions.busiestApp = top.name; conditions.busiestBytesPerSecond = top.upload + top.download
            conditions.busiestUploading = top.upload > top.download
            conditions.busiestPausable = CallMode.name(of: top.id) != nil && allowed()
        }
        if known == nil { known = BluetoothAudioProbe.knownNetworks() }
        conditions.fasterBand = BluetoothAudioCheck.fasterBand(current: radio?.ssid, band: radio?.band,
                                                              networks: BluetoothAudioProbe.recentScan(diagnostics.survey.scans, now: now), known: known ?? [])
        check = CastingCheck(date: now, activity: activity, conditions: conditions)
    }

    private func end() {
        lastSeen = nil; started = nil; check = nil; known = nil
        releaseBackground()
        if holdingAirDrop { diagnostics?.lowLatency.release(); holdingAirDrop = false }
    }

    /// Pauses AirDrop's link until the cast ends, or an hour at most. macOS asks for an administrator password.
    public func pauseAirDrop() async {
        guard let diagnostics, !diagnostics.lowLatency.active else { return }
        await diagnostics.lowLatency.enable(seconds: Self.holdLimit)
        holdingAirDrop = diagnostics.lowLatency.active
        error = diagnostics.lowLatency.error
        lastAWDL = .distantPast
    }

    /// Holds the sync and download apps that are moving data, as call mode does, until the cast ends or an hour passes.
    public func pauseBackground() {
        guard allowed() else { return }
        for app in apps() where app.upload + app.download >= 50_000 {
            guard let name = CallMode.name(of: app.id), !holding.contains(name), !CallMode.hold(app.pids, app: name, owner: CallMode.cast).isEmpty else { continue }
            holding.append(name)
        }
    }

    /// Lets go of what this cast paused, never what a call, Focus or a stream holds too.
    public func releaseBackground() {
        guard !holding.isEmpty else { return }
        CallMode.resume(owner: CallMode.cast)
        holding = []
    }

    /// Moves the Mac to the 5 GHz network the check found, with the password macOS saved for it.
    public func joinFasterBand() async {
        guard let diagnostics, let faster = check?.conditions.fasterBand, faster.known, !joining else { return }
        joining = true; error = nil
        defer { joining = false }
        do {
            try await WiFiConnection().join(name: faster.name, band: faster.band)
            await diagnostics.diagnose()
        } catch { self.error = error.localizedDescription }
    }
}
