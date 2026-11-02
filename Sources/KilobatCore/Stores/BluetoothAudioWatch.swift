import Foundation
import Observation

/// While Bluetooth headphones or a speaker play, checks every five seconds what on the Wi-Fi side can make them crackle:
/// 2.4 GHz, a crowded channel, AirDrop's link, a big transfer, a weak Bluetooth signal, many Bluetooth devices. It never
/// scans Wi-Fi while sound plays (a scan can itself make audio skip); it uses the last scan from the half hour before.
@MainActor @Observable public final class BluetoothAudioWatch {
    nonisolated public static let alertsKey = "bluetoothAudioAlerts"
    nonisolated public static func alertsEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: alertsKey) as? Bool ?? true }
    nonisolated static let lastAlertKey = "bluetoothAudioLastAlert"

    /// The latest check while Bluetooth audio plays; nil when it doesn't.
    public private(set) var check: BluetoothAudioCheck?
    /// Times the person said the audio crackled, newest last.
    public private(set) var reports: [BluetoothAudioReport] = []
    /// Kilobat paused AirDrop for this listening session, and brings it back when the session ends.
    public private(set) var holdingAirDrop = false
    public private(set) var joining = false
    public var error: String?
    /// Called once per listening session when two or more causes line up; the app posts the notification.
    @ObservationIgnored public var onNotify: ((BluetoothAudioCheck) -> Void)?
    /// Bluetooth devices with their signal, from IOBluetooth in the app; nil without Bluetooth permission.
    @ObservationIgnored public var devices: () -> [BluetoothDevice]? = { nil }
    /// The busiest app on the network now, with its rates in bytes a second.
    @ObservationIgnored public var busiest: () -> (name: String, upload: Double, download: Double)? = { nil }

    @ObservationIgnored private var notifier: BluetoothAudioNotifier
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var awdl: AWDLStatus?
    @ObservationIgnored private var paired: [BluetoothDevice]?
    @ObservationIgnored private var lastAWDL = Date.distantPast
    @ObservationIgnored private var lastBytes: (bytes: UInt64, date: Date)?
    @ObservationIgnored private var known: Set<String>?
    @ObservationIgnored private weak var diagnostics: DiagnosticStore?
    private let file: URL

    public init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        file = folder.appendingPathComponent("bluetooth-audio.json")
        reports = StoredJSON.read(file) ?? []
        notifier = BluetoothAudioNotifier(lastNotified: UserDefaults.standard.object(forKey: Self.lastAlertKey) as? Date)
    }

    nonisolated public static func load(directory: URL? = nil) -> [BluetoothAudioReport] {
        StoredJSON.read((directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")).appendingPathComponent("bluetooth-audio.json")) ?? []
    }

    #if DEBUG
    /// A made-up check for screenshots; debug builds only.
    public func preview(_ check: BluetoothAudioCheck?, holding: Bool = false) { loop?.cancel(); loop = nil; self.check = check; holdingAirDrop = holding }
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

    private func tick(_ diagnostics: DiagnosticStore) async {
        let now = Date()
        guard !diagnostics.sleeping, let output = BluetoothAudioProbe.output(), output.playing else {
            check = nil; lastBytes = nil
            observe(playing: false, lineUp: false, now: now)
            return
        }
        let radio = diagnostics.radio
        var conditions = BluetoothAudioConditions()
        conditions.wifiBand = radio?.band; conditions.wifiChannel = radio?.channel; conditions.wifiName = radio?.ssid
        // lsof runs for this and IOBluetooth reads every paired device, so every 30 seconds is enough; right away after a pause.
        if now.timeIntervalSince(lastAWDL) >= 30 { lastAWDL = now; awdl = await NearbyRadios.awdlStatus(); paired = devices() }
        conditions.airDropActive = awdl.map { $0.up && $0.active }
        conditions.airDropUsers = awdl?.users ?? []
        if let bytes = BluetoothAudioProbe.wifiBytes(interface: radio?.interface) {
            if let last = lastBytes, bytes >= last.bytes, now.timeIntervalSince(last.date) > 1 {
                conditions.wifiBytesPerSecond = Double(bytes - last.bytes) / now.timeIntervalSince(last.date)
            } else { conditions.wifiBytesPerSecond = check?.conditions.wifiBytesPerSecond }
            lastBytes = (bytes, now)
        }
        if let top = busiest(), top.upload + top.download >= BluetoothAudioCheck.heavyBytesPerSecond / 2 {
            conditions.busiestApp = top.name; conditions.busiestUploading = top.upload > top.download
        }
        if let paired { Self.fill(&conditions, output: output.name, devices: paired) }
        let networks = BluetoothAudioProbe.recentScan(diagnostics.survey.scans, now: now)
        if let crowd = BluetoothAudioCheck.crowding(channel: radio?.channel, band: radio?.band, ownName: radio?.ssid, networks: networks) {
            conditions.channelCrowding = crowd.crowding; conditions.quieterChannel = crowd.quieter
        }
        if known == nil { known = BluetoothAudioProbe.knownNetworks() }
        conditions.fasterBand = BluetoothAudioCheck.fasterBand(current: radio?.ssid, band: radio?.band, networks: networks, known: known ?? [])
        let next = BluetoothAudioCheck(date: now, output: output, conditions: conditions, reported: notifier.session?.reported ?? false)
        check = next
        observe(playing: true, lineUp: next.lineUp, now: now)
    }

    private func observe(playing: Bool, lineUp: Bool, now: Date) {
        let notify = notifier.observe(playing: playing, lineUp: lineUp, now: now)
        if notifier.ended {
            known = nil
            if holdingAirDrop { diagnostics?.lowLatency.release(); holdingAirDrop = false }
        }
        guard notify, let check else { return }
        UserDefaults.standard.set(now, forKey: Self.lastAlertKey)
        if Self.alertsEnabled() { onNotify?(check) }
    }

    /// The headphones' signal and how many other Bluetooth devices are connected.
    nonisolated public static func fill(_ conditions: inout BluetoothAudioConditions, output: String, devices: [BluetoothDevice]) {
        let connected = devices.filter(\.connected)
        let mine = match(output, connected)
        conditions.bluetoothRSSI = mine?.rssi
        conditions.otherBluetoothDevices = max(0, connected.count - 1)
    }
    /// The Bluetooth device behind Core Audio's output: the same name, else the only connected headphones or speaker.
    nonisolated public static func match(_ output: String, _ connected: [BluetoothDevice]) -> BluetoothDevice? {
        if let named = connected.first(where: { $0.name == output }) { return named }
        let audio = connected.filter(\.audio)
        return audio.count == 1 ? audio[0] : nil
    }

    /// The person says it's crackling now: kept with what was in the way, and the advice stays up for this session.
    public func reportCrackling(now: Date = Date()) {
        guard let current = check else { return }
        notifier.session?.reported = true
        check?.reported = true
        reports.append(BluetoothAudioReport(date: now, device: current.output.name, microphone: current.output.microphone, risks: current.risks))
        reports = Array(reports.suffix(50))
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(reports).write(to: file, options: .atomic)
    }

    /// Pauses AirDrop's link until the listening session ends, or an hour at most. macOS asks for an administrator password.
    public func pauseAirDrop() async {
        guard let diagnostics, !diagnostics.lowLatency.active else { return }
        await diagnostics.lowLatency.enable(seconds: 3600)
        holdingAirDrop = diagnostics.lowLatency.active
        error = diagnostics.lowLatency.error
        lastAWDL = .distantPast
        if let diagnostics = self.diagnostics { await tick(diagnostics) }
    }

    /// Moves the Mac to the 5 GHz network the check found, with the password macOS saved for it.
    public func joinFasterBand() async {
        guard let diagnostics, let faster = check?.conditions.fasterBand, faster.known, !joining else { return }
        joining = true; error = nil
        defer { joining = false }
        do {
            try await WiFiConnection().join(name: faster.name, band: faster.band)
            await diagnostics.diagnose()
            await tick(diagnostics)
        } catch { self.error = error.localizedDescription }
    }
}
