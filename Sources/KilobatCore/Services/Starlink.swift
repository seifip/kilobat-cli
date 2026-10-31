import Foundation

/// A Starlink dish as it describes itself on the local network: state, alerts, obstructions, its outage log and the
/// map of the sky it has seen. Every field is optional because firmware changes them; Kilobat shows what it reads.
/// All of it comes from the dish at 192.168.100.1 and stays on this Mac. Kilobat only reads: it never stows,
/// reboots or reconfigures the dish.
public enum Starlink {
    // Request and response field numbers in SpaceX.API.Device (see RESEARCH-DECISIONS.md › Starlink).
    static let getStatus = 1004, getHistory = 1007, getObstructionMap = 2008
    static let dishStatus = 2004, dishHistory = 2006, dishObstructionMap = 2008

    /// The dish's status; nil when no dish answers.
    public static func status(timeout: TimeInterval = 3) async -> StarlinkStatus? {
        guard let response = try? await request(getStatus, timeout: timeout) else { return nil }
        return StarlinkStatus(response: response)
    }
    public static func history(timeout: TimeInterval = 4) async -> StarlinkHistory? {
        guard let response = try? await request(getHistory, timeout: timeout) else { return nil }
        return StarlinkHistory(response: response)
    }
    public static func obstructionMap(timeout: TimeInterval = 4) async -> StarlinkSkyMap? {
        guard let response = try? await request(getObstructionMap, timeout: timeout) else { return nil }
        return StarlinkSkyMap(response: response)
    }
    /// A quick look: is a dish answering? Takes about a second when nothing is there.
    public static func detect() async -> Bool { await status(timeout: 1.5) != nil }

    static func request(_ field: Int, timeout: TimeInterval) async throws -> ProtoMessage {
        let bytes = try await StarlinkWire.call(ProtoWriter.field(field, message: []), timeout: timeout)
        guard let message = ProtoMessage(bytes) else { throw StarlinkWire.Failure("decode") }
        return message
    }

    /// Starlink reassigns each dish's satellite every 15 seconds, at :12, :27, :42 and :57 past the minute; a short
    /// spike in latency often lands on those seconds. True when a moment falls within the second before such a
    /// handover or the 1.5 seconds after it.
    public static func nearHandover(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        let offset = (seconds - 12).truncatingRemainder(dividingBy: 15)
        let phase = offset < 0 ? offset + 15 : offset
        return phase <= 1.5 || phase >= 14
    }
    /// Whether spikes at these moments line up with the handovers more than chance would: spikes at two or more
    /// different handovers (a 20-second test spans two), and at least 60% of all spikes near one. A random moment
    /// lands near a handover about 17% of the time, so two by chance happen in about 3% of tests.
    public static func alignedWithHandovers(_ moments: [Date]) -> Bool {
        let near = moments.filter { nearHandover($0) }
        let handovers = Set(near.map { (($0.timeIntervalSince1970 - 12) / 15).rounded() })
        return handovers.count >= 2 && Double(near.count) >= 0.6 * Double(moments.count)
    }
}

// MARK: Status

public struct StarlinkStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case online, booting, stowed, thermalShutdown, searching, noSatellites, obstructed, noDownlink, noPings, moving, cableTest, sleeping, skySearch, radioOff, unknown
    }
    public enum Alert: String, Codable, Sendable, CaseIterable {
        case motorsStuck, thermalThrottle, thermalShutdown, mastNotVertical, unexpectedLocation, slowEthernet, slowEthernet100, updatePending,
             heating, powerSupplyHot, powerSave, lowMotorCurrent, weakSignal, waterInDish, waterInRouter, noEthernet
        /// DishAlerts field numbers.
        static let fields: [(Int, Alert)] = [(1, .motorsStuck), (2, .thermalShutdown), (3, .thermalThrottle), (4, .unexpectedLocation), (5, .mastNotVertical),
                                             (6, .slowEthernet), (8, .updatePending), (9, .heating), (10, .powerSupplyHot), (11, .powerSave), (16, .lowMotorCurrent),
                                             (17, .weakSignal), (18, .slowEthernet100), (20, .waterInDish), (21, .waterInRouter), (23, .noEthernet)]
    }
    public enum Update: String, Codable, Sendable { case idle, fetching, checking, writing, rebootRequired, disabled, faulted, unknown }

    public var date = Date()
    /// The dish's serial-like id. Shown on this Mac only, never put in a report.
    public var id: String?
    public var hardware: String?
    public var software: String?
    public var uptimeSeconds: Double?
    public var state: State
    /// While offline: when the current outage started and how long it has lasted.
    public var outage: StarlinkOutage?
    /// Round trip from the dish to Starlink's ground station (the PoP), in ms.
    public var popLatencyMs: Double?
    /// Share of pings to the ground station that were lost, 0–1.
    public var popDropRate: Double?
    /// What the dish is moving right now, all devices together, in bits a second.
    public var downlinkBps: Double?
    public var uplinkBps: Double?
    /// Share of the sky the dish uses that is blocked, 0–1, and whether it is blocked right now.
    public var fractionObstructed: Double?
    public var currentlyObstructed: Bool?
    /// Over how many seconds the obstruction figure was measured.
    public var obstructionValidSeconds: Double?
    /// "Prolonged" obstructions: how long they last and how often, on average.
    public var obstructionDurationSeconds: Double?
    public var obstructionIntervalSeconds: Double?
    public var alerts: [Alert] = []
    public var update: Update?
    public var rebootReady: Bool?
    /// Seconds until the dish may restart for the update it downloaded; negative when unknown.
    public var secondsUntilUpdateReboot: Double?
    /// Where the dish points.
    public var azimuth: Double?
    public var elevation: Double?
    /// stationary, nomadic or mobile, as the plan sets it.
    public var mobility: String?
    public var ethernetMbps: Int?
    public var snrAboveNoiseFloor: Bool?
    /// The dish is set to treat its connection as metered.
    public var treatAsMetered: Bool?

    public init(state: State) { self.state = state }

    init?(response: ProtoMessage, now: Date = Date()) {
        guard let status = response.message(Starlink.dishStatus) else { return nil }
        let info = status.message(1)
        id = info?.string(1); hardware = info?.string(2); software = info?.string(3)
        uptimeSeconds = status.message(2)?.uint(1).map { Double($0) }
        if let outage = status.message(1014) {
            let cause = StarlinkOutage.Cause(code: Int(outage.int(1) ?? 0))
            state = cause.state
            self.outage = StarlinkOutage(message: outage, now: now)
        } else { state = .online }
        popLatencyMs = status.float(1009).map(Double.init)
        popDropRate = status.float(1003).map(Double.init) ?? 0
        downlinkBps = status.float(1007).map(Double.init) ?? 0
        uplinkBps = status.float(1008).map(Double.init) ?? 0
        if let stats = status.message(1004) {
            fractionObstructed = Double(stats.float(1) ?? 0)
            currentlyObstructed = stats.bool(5) ?? false
            obstructionValidSeconds = stats.float(4).map(Double.init)
            if let duration = stats.float(6), duration > 0, let interval = stats.float(7), interval.isFinite, interval > 0 {
                obstructionDurationSeconds = Double(duration); obstructionIntervalSeconds = Double(interval)
            }
        }
        if let flags = status.message(1005) { alerts = StarlinkStatus.Alert.fields.compactMap { flags.bool($0.0) == true ? $0.1 : nil } }
        if let code = status.int(1021) ?? status.message(1026)?.int(1) {
            update = switch code { case 1: .idle; case 2: .fetching; case 3, 5: .checking; case 4: .writing; case 6: .rebootRequired; case 7: .disabled; case 8: .faulted; default: .unknown }
        }
        rebootReady = status.bool(1030)
        secondsUntilUpdateReboot = status.int(1031).map { Double($0) }
        azimuth = status.float(1011).map(Double.init); elevation = status.float(1012).map(Double.init)
        // proto3 leaves out a zero, so a missing class is STATIONARY.
        mobility = status.int(1017).map { switch $0 { case 1: "nomadic"; case 2: "mobile"; default: "stationary" } } ?? "stationary"
        ethernetMbps = status.int(1016).map(Int.init)
        snrAboveNoiseFloor = status.bool(1018)
        treatAsMetered = status.bool(1056)
    }

    public var online: Bool { state == .online }
    /// Software that is waiting for a restart, from the update state or the alert.
    public var updatePending: Bool { update == .rebootRequired || rebootReady == true || alerts.contains(.updatePending) }

    /// "Online", "Obstructed", "Searching for satellites"…
    public var stateTitle: String {
        switch state {
        case .online: String(localized: "Online", comment: "Starlink dish state")
        case .booting: String(localized: "Starting up", comment: "Starlink dish state")
        case .stowed: String(localized: "Stowed", comment: "Starlink dish state: folded flat")
        case .thermalShutdown: String(localized: "Too hot, paused", comment: "Starlink dish state")
        case .searching, .skySearch: String(localized: "Searching", comment: "Starlink dish state: looking for satellites")
        case .noSatellites: String(localized: "No satellites", comment: "Starlink dish state")
        case .obstructed: String(localized: "Obstructed", comment: "Starlink dish state: something blocks its view of the sky")
        case .noDownlink, .noPings: String(localized: "Network not answering", comment: "Starlink dish state")
        case .moving: String(localized: "Moving into place", comment: "Starlink dish state: motors adjusting")
        case .cableTest: String(localized: "Testing its cable", comment: "Starlink dish state")
        case .sleeping: String(localized: "Sleeping", comment: "Starlink dish state: power-save schedule")
        case .radioOff: String(localized: "Radio off", comment: "Starlink dish state")
        case .unknown: String(localized: "Offline", comment: "Starlink dish state")
        }
    }
}

public extension StarlinkStatus.Alert {
    enum Severity: String, Sendable { case problem, caution, info }
    var severity: Severity {
        switch self {
        case .motorsStuck, .thermalShutdown, .waterInDish, .waterInRouter, .noEthernet, .mastNotVertical: .problem
        case .thermalThrottle, .powerSupplyHot, .slowEthernet, .slowEthernet100, .unexpectedLocation, .lowMotorCurrent, .weakSignal: .caution
        case .updatePending, .heating, .powerSave: .info
        }
    }
    var title: String {
        switch self {
        case .motorsStuck: String(localized: "Motors stuck", comment: "Starlink alert")
        case .thermalThrottle: String(localized: "Slowed down by heat", comment: "Starlink alert")
        case .thermalShutdown: String(localized: "Shut down by heat", comment: "Starlink alert")
        case .mastNotVertical: String(localized: "Mast not upright", comment: "Starlink alert")
        case .unexpectedLocation: String(localized: "Outside its service area", comment: "Starlink alert")
        case .slowEthernet, .slowEthernet100: String(localized: "Slow cable link", comment: "Starlink alert")
        case .updatePending: String(localized: "Update waiting for a restart", comment: "Starlink alert")
        case .heating: String(localized: "Melting snow", comment: "Starlink alert: the dish heats itself")
        case .powerSupplyHot: String(localized: "Power supply too hot", comment: "Starlink alert")
        case .powerSave: String(localized: "Power save", comment: "Starlink alert")
        case .lowMotorCurrent: String(localized: "Weak motor power", comment: "Starlink alert")
        case .weakSignal: String(localized: "Weaker signal than expected", comment: "Starlink alert")
        case .waterInDish: String(localized: "Water in the dish", comment: "Starlink alert")
        case .waterInRouter: String(localized: "Water in the router", comment: "Starlink alert")
        case .noEthernet: String(localized: "No cable link", comment: "Starlink alert")
        }
    }
    var advice: String {
        switch self {
        case .motorsStuck: String(localized: "Check that nothing (ice, a branch, the mount) stops the dish from tilting, then restart it in the Starlink app.", comment: "Starlink alert advice")
        case .thermalThrottle: String(localized: "It’s running hot and slower to protect itself. Shade or airflow helps; it recovers as it cools.", comment: "Starlink alert advice")
        case .thermalShutdown: String(localized: "It turned its radio off to cool down. Give it shade or airflow; it comes back by itself.", comment: "Starlink alert advice")
        case .mastNotVertical: String(localized: "Level the mount: a tilted mast skews where the dish looks.", comment: "Starlink alert advice")
        case .unexpectedLocation: String(localized: "The dish is away from its service address. A Roam plan, or updating the address, fixes it.", comment: "Starlink alert advice")
        case .slowEthernet, .slowEthernet100: String(localized: "The cable between the dish and router links slowly. Reseat or replace it, and check the adapter.", comment: "Starlink alert advice")
        case .updatePending: String(localized: "Software is ready and the dish restarts to install it, usually overnight. Expect a few minutes offline.", comment: "Starlink alert advice")
        case .heating: String(localized: "The dish warms itself to melt snow. It uses more power meanwhile; that’s normal.", comment: "Starlink alert advice")
        case .powerSupplyHot: String(localized: "Keep the power supply somewhere cool and ventilated.", comment: "Starlink alert advice")
        case .powerSave: String(localized: "The dish is idling on its power-save schedule; change it in the Starlink app.", comment: "Starlink alert advice")
        case .lowMotorCurrent: String(localized: "The dish may not get enough power to move. Check the cable and power supply.", comment: "Starlink alert advice")
        case .weakSignal: String(localized: "Look for something new in its view, or snow and debris on its face.", comment: "Starlink alert advice")
        case .waterInDish, .waterInRouter: String(localized: "Unplug it and let it dry; contact Starlink support if it keeps showing.", comment: "Starlink alert advice")
        case .noEthernet: String(localized: "The dish and router aren’t linked. Check both ends of the cable.", comment: "Starlink alert advice")
        }
    }
}

// MARK: Outages

/// A stretch the dish was offline, with the cause it logged.
public struct StarlinkOutage: Codable, Sendable, Equatable, Hashable {
    /// DishOutage.Cause.
    public enum Cause: String, Codable, Sendable, CaseIterable {
        case unknown, booting, stowed, thermalShutdown, noSchedule, noSatellites, obstructed, noDownlink, noPings, actuatorActivity, cableTest, sleeping, skySearch, radioOff
        public init(code: Int) {
            self = switch code {
            case 1: .booting; case 2: .stowed; case 3: .thermalShutdown; case 4: .noSchedule; case 5: .noSatellites; case 6: .obstructed
            case 7: .noDownlink; case 8: .noPings; case 9: .actuatorActivity; case 10: .cableTest; case 11: .sleeping; case 13: .skySearch; case 14: .radioOff
            default: .unknown
            }
        }
        var state: StarlinkStatus.State {
            switch self {
            case .booting: .booting; case .stowed: .stowed; case .thermalShutdown: .thermalShutdown; case .noSchedule: .searching; case .noSatellites: .noSatellites
            case .obstructed: .obstructed; case .noDownlink: .noDownlink; case .noPings: .noPings; case .actuatorActivity: .moving; case .cableTest: .cableTest
            case .sleeping: .sleeping; case .skySearch: .skySearch; case .radioOff: .radioOff; case .unknown: .unknown
            }
        }
        /// Whose side an outage is on.
        public var side: Side {
            switch self {
            case .obstructed, .stowed, .thermalShutdown, .cableTest, .sleeping: .setup
            case .noSatellites, .noSchedule, .noDownlink, .noPings: .network
            case .booting, .actuatorActivity, .skySearch, .radioOff, .unknown: .dish
            }
        }
        public var title: String {
            switch self {
            case .obstructed: String(localized: "Obstructed", comment: "Starlink outage cause")
            case .stowed: String(localized: "Stowed", comment: "Starlink outage cause")
            case .thermalShutdown: String(localized: "Too hot", comment: "Starlink outage cause")
            case .cableTest: String(localized: "Cable test", comment: "Starlink outage cause")
            case .sleeping: String(localized: "Power save", comment: "Starlink outage cause")
            case .noSatellites: String(localized: "No satellites", comment: "Starlink outage cause")
            case .noSchedule: String(localized: "Searching", comment: "Starlink outage cause: no satellite scheduled for the dish")
            case .noDownlink: String(localized: "No downlink", comment: "Starlink outage cause")
            case .noPings: String(localized: "Network not answering", comment: "Starlink outage cause: no replies from the ground station")
            case .booting: String(localized: "Restarting", comment: "Starlink outage cause")
            case .actuatorActivity: String(localized: "Repositioning", comment: "Starlink outage cause: motors moving the dish")
            case .skySearch: String(localized: "Finding the sky", comment: "Starlink outage cause: the dish learning where it is")
            case .radioOff: String(localized: "Radio off", comment: "Starlink outage cause")
            case .unknown: String(localized: "Unknown", comment: "Starlink outage cause")
            }
        }
    }
    /// "Your setup" can be fixed where the dish is; "Starlink's network" can't; "the dish" restarted or moved itself.
    public enum Side: String, Codable, Sendable, CaseIterable {
        case setup, network, dish
        public var title: String {
            switch self {
            case .setup: String(localized: "Your setup", comment: "Starlink outages on the user's side: obstructions, heat, cable")
            case .network: String(localized: "Starlink’s network", comment: "Starlink outages on the provider's side: no satellites, no reply")
            case .dish: String(localized: "Dish restarts", comment: "Starlink outages when the dish restarted or repositioned itself")
            }
        }
    }

    public var cause: Cause
    public var start: Date
    public var seconds: Double
    /// The dish switched satellites to get out of it.
    public var didSwitch: Bool?

    public init(cause: Cause, start: Date, seconds: Double, didSwitch: Bool? = nil) {
        self.cause = cause; self.start = start; self.seconds = seconds; self.didSwitch = didSwitch
    }

    init?(message: ProtoMessage, now: Date = Date()) {
        cause = Cause(code: Int(message.int(1) ?? 0))
        seconds = Double(message.uint(3) ?? 0) / 1e9
        guard let start = message.int(2).flatMap({ Self.date(nanoseconds: $0, now: now) }) else { return nil }
        self.start = start
        didSwitch = message.bool(4)
    }

    public var end: Date { start.addingTimeInterval(seconds) }
    public var side: Side { cause.side }

    /// The dish's timestamps count nanoseconds, from 1970 or, by some accounts, from the GPS epoch (6 January 1980,
    /// 18 leap seconds behind today). Whichever reading lands within the last 31 days and not in the future wins;
    /// neither does, and the outage is dropped rather than misdated.
    static func date(nanoseconds: Int64, now: Date) -> Date? {
        let seconds = Double(nanoseconds) / 1e9
        let unix = Date(timeIntervalSince1970: seconds), gps = Date(timeIntervalSince1970: seconds + 315_964_800 - 18)
        func plausible(_ date: Date) -> Bool { date <= now.addingTimeInterval(120) && now.timeIntervalSince(date) <= 31 * 86_400 }
        return plausible(unix) ? unix : plausible(gps) ? gps : nil
    }
}

// MARK: History

/// The dish's last 15 minutes or so, one sample a second, oldest first, and the outages it logged.
public struct StarlinkHistory: Codable, Sendable, Equatable {
    public var date = Date()
    public var latencyMs: [Double?] = []
    public var dropRate: [Double] = []
    public var downlinkBps: [Double] = []
    public var uplinkBps: [Double] = []
    public var outages: [StarlinkOutage] = []

    public init(date: Date = Date(), latencyMs: [Double?] = [], dropRate: [Double] = [], downlinkBps: [Double] = [], uplinkBps: [Double] = [], outages: [StarlinkOutage] = []) {
        self.date = date; self.latencyMs = latencyMs; self.dropRate = dropRate; self.downlinkBps = downlinkBps; self.uplinkBps = uplinkBps; self.outages = outages
    }

    init?(response: ProtoMessage, now: Date = Date()) {
        guard let history = response.message(Starlink.dishHistory) else { return nil }
        date = now
        let current = Int(clamping: history.uint(1) ?? 0)
        let drop = history.floats(1001), latency = history.floats(1002), down = history.floats(1003), up = history.floats(1004)
        // Ring buffers: `current` counts every sample ever written, so the newest is at (current - 1) % size and
        // only the last `current` slots hold data while the buffer is still filling.
        func unwrap(_ ring: [Float]) -> [Float] {
            let size = ring.count
            guard size > 0, current > 0 else { return [] }
            if current < size { return Array(ring.prefix(current)) }
            let next = current % size
            return Array(ring[next...] + ring[..<next])
        }
        dropRate = unwrap(drop).map(Double.init)
        // A sample whose pings were all lost carries no latency.
        let lost = unwrap(drop)
        latencyMs = unwrap(latency).enumerated().map { index, value in (index < lost.count && lost[index] >= 1) || value <= 0 ? nil : Double(value) }
        downlinkBps = unwrap(down).map(Double.init); uplinkBps = unwrap(up).map(Double.init)
        outages = history.messages(1009).compactMap { StarlinkOutage(message: $0, now: now) }.sorted { $0.start < $1.start }
    }

    /// Bytes the dish carried for every device on its network in this window, from its own throughput samples.
    public var bytes: (down: Double, up: Double) { (downlinkBps.reduce(0, +) / 8, uplinkBps.reduce(0, +) / 8) }
    public var seconds: Int { max(downlinkBps.count, latencyMs.count) }
}

// MARK: Sky map

/// What the dish has seen of the sky: one value per cell, 1 clear, 0 blocked, negative where it has no data yet.
/// The centre is straight up; the edge is `maxTheta` degrees from it. With the earth frame, up on the map is north.
public struct StarlinkSkyMap: Codable, Sendable, Equatable {
    public var rows: Int
    public var columns: Int
    public var snr: [Float]
    public var minElevation: Double?
    public var maxTheta: Double?
    /// The map is turned to the compass (earth) rather than to the dish itself.
    public var earthFrame: Bool

    public init(rows: Int, columns: Int, snr: [Float], minElevation: Double? = nil, maxTheta: Double? = nil, earthFrame: Bool = true) {
        self.rows = rows; self.columns = columns; self.snr = snr; self.minElevation = minElevation; self.maxTheta = maxTheta; self.earthFrame = earthFrame
    }

    init?(response: ProtoMessage) {
        guard let map = response.message(Starlink.dishObstructionMap) else { return nil }
        rows = Int(map.uint(1) ?? 0); columns = Int(map.uint(2) ?? 0); snr = map.floats(3)
        guard rows > 0, columns > 0, snr.count == rows * columns else { return nil }
        minElevation = map.float(4).map(Double.init); maxTheta = map.float(5).map(Double.init)
        // FRAME_UT (2) turns the map with the dish; anything else, including no answer, reads as the compass frame.
        earthFrame = map.int(6) != 2
    }

    /// Degrees from straight up at the map's edge.
    var edge: Double {
        if let maxTheta, maxTheta > 10, maxTheta <= 90 { return maxTheta }
        if let minElevation, minElevation > 0, minElevation < 80 { return 90 - minElevation }
        return 80
    }

    public struct Cell: Sendable { public let azimuth: Double; public let elevation: Double; public let value: Float }
    /// Every cell inside the circle with data, with its direction.
    public var cells: [Cell] {
        var cells: [Cell] = []
        let centreX = Double(columns) / 2, centreY = Double(rows) / 2, radius = min(centreX, centreY)
        for row in 0..<rows {
            for column in 0..<columns {
                let value = snr[row * columns + column]
                guard value >= 0 else { continue }
                let dx = Double(column) + 0.5 - centreX, dy = centreY - (Double(row) + 0.5)
                let distance = (dx * dx + dy * dy).squareRoot() / radius
                guard distance <= 1 else { continue }
                var azimuth = atan2(dx, dy) * 180 / .pi
                if azimuth < 0 { azimuth += 360 }
                cells.append(Cell(azimuth: azimuth, elevation: 90 - distance * edge, value: value))
            }
        }
        return cells
    }

    /// A cell below this counts as blocked.
    static let blocked: Float = 0.5

    public struct Sector: Codable, Sendable, Equatable {
        /// 0 north, 1 north-east … 7 north-west.
        public let index: Int
        public let seen: Int
        public let blocked: Int
        /// Median elevation of the blocked cells.
        public let elevation: Double?
        public var share: Double { seen == 0 ? 0 : Double(blocked) / Double(seen) }
    }
    public var sectors: [Sector] {
        var seen = [Int](repeating: 0, count: 8), blocked = [Int](repeating: 0, count: 8), heights = [[Double]](repeating: [], count: 8)
        for cell in cells {
            let index = Int(((cell.azimuth + 22.5) / 45).rounded(.down)) % 8
            seen[index] += 1
            if cell.value < Self.blocked { blocked[index] += 1; heights[index].append(cell.elevation) }
        }
        return (0..<8).map { index in
            let sorted = heights[index].sorted()
            return Sector(index: index, seen: seen[index], blocked: blocked[index], elevation: sorted.isEmpty ? nil : sorted[sorted.count / 2])
        }
    }
    /// Share of the cells with data that are blocked, 0–1.
    public var blockedShare: Double {
        let cells = cells
        return cells.isEmpty ? 0 : Double(cells.filter { $0.value < Self.blocked }.count) / Double(cells.count)
    }
    /// Directions where at least 8% of what the dish saw was blocked, worst first.
    public var blockedSectors: [Sector] {
        sectors.filter { $0.seen >= 12 && $0.blocked >= 3 && $0.share >= 0.08 }.sorted { $0.share > $1.share }
    }
    /// Enough of the sky mapped to say anything.
    public var mapped: Bool { cells.count >= 40 }

    public static func direction(_ index: Int) -> String {
        switch index {
        case 0: String(localized: "north", comment: "Compass direction, mid-sentence")
        case 1: String(localized: "north-east", comment: "Compass direction, mid-sentence")
        case 2: String(localized: "east", comment: "Compass direction, mid-sentence")
        case 3: String(localized: "south-east", comment: "Compass direction, mid-sentence")
        case 4: String(localized: "south", comment: "Compass direction, mid-sentence")
        case 5: String(localized: "south-west", comment: "Compass direction, mid-sentence")
        case 6: String(localized: "west", comment: "Compass direction, mid-sentence")
        default: String(localized: "north-west", comment: "Compass direction, mid-sentence")
        }
    }
    /// The same directions relative to the dish, for a map in the dish's frame.
    public static func side(_ index: Int) -> String {
        switch index {
        case 0: String(localized: "in front of the dish", comment: "Direction relative to a Starlink dish, mid-sentence")
        case 1, 2, 3: String(localized: "to the dish’s right", comment: "Direction relative to a Starlink dish, mid-sentence")
        case 4: String(localized: "behind the dish", comment: "Direction relative to a Starlink dish, mid-sentence")
        default: String(localized: "to the dish’s left", comment: "Direction relative to a Starlink dish, mid-sentence")
        }
    }

    /// The map in a sentence or two: where it's blocked, how high, and what to do. `mobile` words it for a vehicle or boat.
    public func advice(mobile: Bool = false) -> String {
        guard mapped else { return String(localized: "The dish is still mapping the sky. The picture fills in over a few hours of use.", comment: "Starlink sky map advice") }
        let worst = blockedSectors
        guard let first = worst.first else { return String(localized: "Clear in every direction the dish has used. Nothing to move.", comment: "Starlink sky map advice") }
        let names = worst.prefix(2).map { earthFrame ? Self.direction($0.index) : Self.side($0.index) }
        let place = names.count == 2 && abs(worst[0].index - worst[1].index) % 6 <= 2 && abs(worst[0].index - worst[1].index) != 0
            ? String(localized: "\(names[0]) and \(names[1])", comment: "Two compass directions, such as “north-east and east”") : names[0]
        let low = (first.elevation ?? 30) < 45
        let height = low ? String(localized: "low in the sky, like a tree, a building or a hill", comment: "Where a Starlink obstruction is, mid-sentence")
                         : String(localized: "high up, like branches overhead, a roof edge or an awning", comment: "Where a Starlink obstruction is, mid-sentence")
        let blocked = earthFrame ? String(localized: "Blocked to the \(place), \(height).", comment: "Starlink sky map: a direction such as “north-east”, then how high")
                                 : String(localized: "Blocked \(place), \(height).", comment: "Starlink sky map: a side such as “to the dish’s left”, then how high")
        let fix: String
        if mobile { fix = String(localized: "Park or moor with that side open, or raise the dish above it.", comment: "Starlink sky map advice for a vehicle or boat") }
        else if low { fix = String(localized: "Mounting the dish higher, or a few metres away from it, usually clears it.", comment: "Starlink sky map advice") }
        else { fix = String(localized: "Move the dish out from under it, or trim it back.", comment: "Starlink sky map advice") }
        return blocked + " " + fix
    }
}

// MARK: Plans

/// Starlink's capped plans, for a data budget that matches the plan. Caps as starlink.com and Starlink's support
/// articles described them in October 2026 (see RESEARCH-DECISIONS.md); after the cap Starlink slows the dish to
/// about 1 Mbps rather than cutting it off. Kilobat counts this Mac only, so the budget is a share of the plan.
public enum StarlinkPlan: String, CaseIterable, Identifiable, Sendable {
    case roam100, roam300, unlimited
    public var id: String { rawValue }
    /// The plan's high-speed data a month, in GB; nil without a cap.
    public var gigabytes: Double? { switch self { case .roam100: 100; case .roam300: 300; case .unlimited: nil } }
    public var title: String {
        switch self {
        case .roam100: String(localized: "Roam 100 GB", comment: "A Starlink plan")
        case .roam300: String(localized: "Roam 300 GB", comment: "A Starlink plan")
        case .unlimited: String(localized: "Unlimited", comment: "Starlink plans without a data cap (Residential, Roam Unlimited)")
        }
    }

    /// The plan this network is set up for: metered with a monthly budget of the cap, or not metered.
    @MainActor public static func current(_ store: TrafficStore) -> StarlinkPlan? {
        switch store.cost {
        case .metered: allCases.first { $0.gigabytes == store.preferences.limitGB && store.budgetCycle.period == .monthly }
        case .unmetered: .unlimited
        case .automatic: nil
        }
    }

    /// Marks this network metered for a capped plan and, with `budget` (Pro), sets a monthly budget of the cap,
    /// keeping the day a monthly budget already starts on. Unlimited marks it unmetered and leaves the budget.
    /// False when Kilobat can't tell this network apart yet.
    @MainActor @discardableResult public func apply(to store: TrafficStore, budget: Bool) -> Bool {
        guard let gigabytes else { return store.setCost(.unmetered) }
        guard store.setCost(.metered) else { return false }
        guard budget else { return true }
        var preferences = store.preferences
        preferences.limitGB = gigabytes
        let cycle = store.budgetCycle
        preferences.budgetCycle = BudgetCycle(period: .monthly, anchor: cycle.period == .monthly ? cycle.anchor : nil, alerts: cycle.alerts)
        store.preferences = preferences
        return true
    }
}

// MARK: Report evidence

/// The dish's outage log for the provider report, split by whose side each outage was on.
public struct StarlinkEvidence: Codable, Sendable {
    public struct Outage: Codable, Sendable {
        public let start: Date
        public let seconds: Double
        public let cause: String
        public let side: String
    }
    public let outages: [Outage]
    public let setupSeconds: Double
    public let networkSeconds: Double
    public let dishSeconds: Double
    /// Share of the sky blocked, from the dish's status at the time of the report, 0–100.
    public let obstructionPercent: Double?
    public let software: String?

    public static func make(outages: [StarlinkOutage], status: StarlinkStatus?, since: Date, now: Date = Date()) -> StarlinkEvidence {
        let window = outages.filter { $0.end >= since && $0.start <= now }.sorted { $0.start < $1.start }
        func total(_ side: StarlinkOutage.Side) -> Double { window.filter { $0.side == side }.reduce(0) { $0 + $1.seconds } }
        return StarlinkEvidence(outages: window.suffix(60).map { Outage(start: $0.start, seconds: $0.seconds, cause: $0.cause.rawValue, side: $0.side.rawValue) },
                                setupSeconds: total(.setup), networkSeconds: total(.network), dishSeconds: total(.dish),
                                obstructionPercent: status?.fractionObstructed.map { $0 * 100 }, software: status?.software)
    }

    public var totalSeconds: Double { setupSeconds + networkSeconds + dishSeconds }

    static func length(_ seconds: Double) -> String {
        seconds < 60 ? String(localized: "\(Int(seconds.rounded())) s", comment: "Seconds, abbreviated")
            : seconds < 5400 ? String(localized: "\(String(format: "%.1f", seconds / 60)) min", comment: "Minutes with one decimal, abbreviated")
            : String(localized: "\(String(format: "%.1f", seconds / 3600)) h", comment: "Hours, abbreviated")
    }

    /// The finding: how often the dish was down, and which side each share was on.
    public var finding: String? {
        guard !outages.isEmpty else { return nil }
        var parts: [String] = []
        if networkSeconds > 0 { parts.append(String(localized: "\(Self.length(networkSeconds)) with no satellite in view or no reply from Starlink’s network", comment: "Part of the Starlink finding in the provider report")) }
        if setupSeconds > 0 { parts.append(String(localized: "\(Self.length(setupSeconds)) from obstructions, heat or power save at the dish", comment: "Part of the Starlink finding in the provider report")) }
        if dishSeconds > 0 { parts.append(String(localized: "\(Self.length(dishSeconds)) while the dish restarted or repositioned", comment: "Part of the Starlink finding in the provider report")) }
        return String(localized: "The Starlink dish logged \(outages.count) outages, \(Self.length(totalSeconds)) in all: \(parts.formatted(.list(type: .and))).", comment: "Provider report finding: a count, a total length and the parts by cause")
    }
}
