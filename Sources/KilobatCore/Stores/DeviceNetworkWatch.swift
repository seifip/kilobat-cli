import Foundation
import Observation

/// Working with a Wi-Fi device: notices when the Mac's Wi-Fi is a device's own network (a robot's, drone's, camera's,
/// printer's or smart plug's, or one the person saved), or a Wi-Fi with no internet while another connection has it,
/// and brings together what helps there: the internet priority switch, where the device is, the link to it, its notes
/// and the way back to the usual Wi-Fi.
@MainActor @Observable public final class DeviceNetworkWatch {
    public enum Mode: Equatable, Sendable {
        /// The Wi-Fi is a device's own network, whatever carries the internet.
        case device(SetupNetworkMatch)
        /// The Wi-Fi carries the internet but has none, and it isn't a known device network or a sign-in page.
        case noInternet
    }
    public let priority: InternetPriorityStore
    public let notes: DeviceNotesStore
    public let link = LinkQualityWatch()
    public private(set) var mode: Mode?
    /// The Wi-Fi name and its router, read from the Wi-Fi's own service even when another connection is primary.
    public private(set) var ssid: String?
    public private(set) var gateway: String?
    public private(set) var interface: String?
    public private(set) var finding: DeviceFinding?
    public private(set) var searching = false
    /// The ordinary Wi-Fi before the device's own, to go back to.
    public private(set) var previous: String?
    public private(set) var returning = false
    public var error: String?
    /// The full app turns it on; Lite has no helper, no administrator prompts and no view for it, so it never looks.
    @ObservationIgnored public var enabled = false

    @ObservationIgnored var runFinder: (String?, String?, String?) async -> DeviceFinding = { network, gateway, interface in
        await DeviceFinder.run(network: network, gateway: gateway, interface: interface)
    }
    @ObservationIgnored private var lastOrdinary: String?
    @ObservationIgnored private var generation = UUID()

    public init(priority: InternetPriorityStore = InternetPriorityStore(), notes: DeviceNotesStore = DeviceNotesStore()) {
        self.priority = priority; self.notes = notes
    }

    #if DEBUG
    /// Made-up state for screenshots; debug builds only.
    public func preview(mode: Mode?, ssid: String?, gateway: String?, finding: DeviceFinding? = nil, previous: String? = nil) {
        self.mode = mode; self.ssid = ssid; self.gateway = gateway; self.finding = finding; self.previous = previous
    }
    #endif

    public var match: SetupNetworkMatch? { if case .device(let match) = mode { match } else { nil } }
    /// The saved notes for the device network the Mac is on.
    public var note: DeviceNote? { notes.note(ssid: ssid) }
    /// The address to reach the device at: its saved one, what the finder led with, or the Wi-Fi's router.
    public var deviceAddress: String? { note?.address ?? finding?.main?.address ?? gateway }
    /// What to call the device: its saved name, the maker the Wi-Fi name says, what it announces, or its kind.
    public var deviceName: String {
        note?.name ?? match?.name ?? match?.maker ?? finding?.main.flatMap { $0.names.first ?? $0.hostname } ?? match?.kind.name
            ?? ssid ?? String(localized: "Your device", comment: "Device Wi-Fi: a device with no name yet")
    }

    /// Takes each health check. `wifiInternet` is whether the internet answered over the Wi-Fi when it's primary.
    public func observe(_ sample: DiagnosticSnapshot, portal: Bool) async {
        guard enabled else { return }
        await priority.refresh()
        let wifiRoute = priority.routes.first { $0.kind == .wifi }
        let ssid = sample.radio.ssid
        let wifiPrimary = wifiRoute?.primary ?? (sample.wiredInterface == nil)
        let router = wifiRoute?.router ?? (wifiPrimary ? sample.gateway : nil)
        let deviceInterface = wifiRoute?.interface ?? sample.radio.interface
        if ssid != self.ssid || router != gateway || deviceInterface != interface {
            generation = UUID()
            finding = nil
            searching = false
            link.stop()
        }
        self.ssid = ssid; gateway = router; interface = deviceInterface

        let saved = DeviceNotesStore.networks()
        var next: Mode?
        if let setup = sample.setupNetwork { next = .device(setup) }
        else if !wifiPrimary, let ssid {
            // The internet goes another way, so the Wi-Fi's name alone says what it is.
            if let own = saved[ssid] { next = .device(SetupNetworkMatch(kind: own.kind, maker: nil, rule: "saved", name: own.name)) }
            else if let known = SetupNetworks.match(ssid: ssid) { next = .device(known) }
        } else if ssid != nil, wifiPrimary, !portal, sample.reachability == .down, sample.gateway != nil { next = .noInternet }
        mode = next

        if case .device = next {
            if let lastOrdinary, lastOrdinary != ssid { previous = lastOrdinary }
        } else {
            if let ssid, next == nil { lastOrdinary = ssid }
            previous = nil
        }
        // The Mac moved from the device's Wi-Fi to an ordinary one: the switch has done its job.
        if let wifi = priority.hold?.wifi, let ssid, ssid != wifi, next == nil || next == .noInternet {
            await priority.leaveDevice(reason: String(localized: "You left \(wifi), so Kilobat put Wi-Fi first again.", comment: "Internet priority notice; the argument is the device's Wi-Fi name"))
        }

        if case .device = next {
            if finding == nil, !searching { await find() }
            if let address = deviceAddress { link.watch(address, name: deviceName) }
        } else if link.target != nil, !(link.target.map { $0.address == note?.address } ?? false) { link.stop() }
    }

    /// Looks for the device: the router, Bonjour names and the common ports. "Find again".
    public func find() async {
        guard !searching else { return }
        let generation = self.generation
        searching = true; defer { if self.generation == generation { searching = false } }
        let result = await runFinder(ssid, gateway, interface)
        guard self.generation == generation else { return }
        finding = result
        if case .device = mode, let address = deviceAddress { link.watch(address, name: deviceName) }
    }

    /// Back to the usual Wi-Fi: Wi-Fi first in the order again if Kilobat moved it, then the Wi-Fi from before.
    public func goBack(then diagnose: @escaping @MainActor () async -> Void) async {
        guard let previous, !returning else { return }
        returning = true; error = nil
        defer { returning = false }
        if priority.hold != nil { await priority.turnOff() }
        do { try await WiFiConnection().join(name: previous); link.stop(); await diagnose() }
        catch { self.error = String(localized: "Couldn’t rejoin \(previous): \(error.localizedDescription)", comment: "Device Wi-Fi; the arguments are a Wi-Fi name and an error") }
    }

    /// Joins a saved device's Wi-Fi with its saved password, or the one macOS saved.
    public func join(_ note: DeviceNote) async {
        guard let ssid = note.ssid, !returning else { return }
        returning = true; error = nil
        defer { returning = false }
        do { try await WiFiConnection().join(name: ssid, password: notes.password(note.id)) }
        catch { self.error = String(localized: "Couldn’t join \(ssid): \(error.localizedDescription)", comment: "Device Wi-Fi; the arguments are a Wi-Fi name and an error") }
    }
}
