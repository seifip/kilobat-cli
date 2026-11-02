import Foundation

/// One radio heard on the joined Wi-Fi: a BSSID with its signal, channel and band.
public struct NodeRadio: Codable, Sendable, Hashable {
    public let bssid: String
    public let rssi: Int
    public let channel: Int
    public let band: String
    public let widthMHz: Int
    public init(bssid: String, rssi: Int, channel: Int, band: String, widthMHz: Int) {
        self.bssid = MeshNodes.normalize(bssid) ?? bssid.lowercased(); self.rssi = rssi; self.channel = channel; self.band = band; self.widthMHz = widthMHz
    }
    /// The link rate this signal could carry, as `MeshNodes.estimatedMbps` works it out.
    public var estimatedMbps: Double { MeshNodes.estimatedMbps(rssi: rssi, band: band, widthMHz: widthMHz) }
}

/// A mesh node or access point: the radios (2.4, 5 and 6 GHz) that share one box, as their addresses suggest.
public struct MeshNode: Codable, Sendable, Identifiable, Equatable {
    /// The lowest BSSID among its radios.
    public let id: String
    /// What the person called it, such as Office; nil until named.
    public var name: String?
    /// Strongest first.
    public var radios: [NodeRadio]
    /// This Mac is joined to one of its radios.
    public var current: Bool
    public var strongest: NodeRadio { radios[0] }
    public var bands: [String] { Array(Set(radios.map(\.band))).sorted() }
    public init(id: String, name: String?, radios: [NodeRadio], current: Bool) { self.id = id; self.name = name; self.radios = radios; self.current = current }
}

/// The joined network's nodes and the rules that say when the Mac clings to a far one.
///
/// macOS leaves an access point only once its signal falls to about −75 dBm and another is 12 dB stronger (Apple's
/// roaming guide for Mac). A Mac at −72 dBm on the living-room node never roams, however close the office node is.
public enum MeshNodes {
    /// The current node must be at least this much weaker than the other's radio to start a finding…
    public static let margin = 15
    /// …and this much to keep one going, so a reading or two near the line doesn't end it.
    public static let keepMargin = 12
    /// Only a weak link costs anything: at −65 dBm or better, the current node already carries more than the internet does.
    public static let weakAbove = -65
    /// The other node's radio has to promise this many times the current link rate; otherwise it's band steering at work.
    public static let gain = 1.5

    /// `aa:bb:cc:dd:ee:ff`, two lowercase digits per byte; nil when it isn't a MAC address.
    public static func normalize(_ bssid: String) -> String? {
        bytes(bssid).map { $0.map { String(format: "%02x", $0) }.joined(separator: ":") }
    }
    static func bytes(_ bssid: String) -> [UInt8]? {
        let parts = bssid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        let values = parts.compactMap { $0.count <= 2 && !$0.isEmpty ? UInt8($0, radix: 16) : nil }
        return values.count == 6 ? values : nil
    }

    /// Whether two radios look like the same box. A node's radios take addresses a few apart from one base address
    /// (`…:30`, `…:31`, `…:34`), and some derive extra ones by setting the locally administered bit, which changes the
    /// first byte (`78:…` and `7a:…`). Two radios on the same channel and band are always two boxes: a mesh shares its
    /// channel between nodes, and one radio has one address per network.
    public static func sameNode(_ a: NodeRadio, _ b: NodeRadio) -> Bool {
        if a.band == b.band && a.channel == b.channel { return false }
        return sameBox(a.bssid, b.bssid)
    }
    static func sameBox(_ a: String, _ b: String) -> Bool {
        guard let x = bytes(a), let y = bytes(b) else { return false }
        let local = x[0] & 0x02 != 0 || y[0] & 0x02 != 0
        guard local ? x[1] == y[1] && x[2] == y[2] : x[0...2] == y[0...2] else { return false }
        func nic(_ v: [UInt8]) -> Int { Int(v[3]) << 16 | Int(v[4]) << 8 | Int(v[5]) }
        return abs(nic(x) - nic(y)) <= 7
    }

    /// Radios grouped into nodes, strongest node first. `names` maps BSSIDs to the person's names for their node;
    /// `current` is the BSSID the Mac is joined to.
    public static func nodes(_ radios: [NodeRadio], current: String?, names: [String: String] = [:]) -> [MeshNode] {
        // One entry per BSSID, the strongest reading of it.
        var unique: [String: NodeRadio] = [:]
        for radio in radios where radio.rssi < 0 { if radio.rssi > (unique[radio.bssid]?.rssi ?? -999) { unique[radio.bssid] = radio } }
        let list = unique.values.sorted { $0.bssid < $1.bssid }
        var parent = Array(list.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in list.indices { for j in list.indices where j > i && sameNode(list[i], list[j]) { parent[root(j)] = root(i) } }
        let current = current.flatMap(normalize)
        return Dictionary(grouping: list.indices, by: root).values.map { members in
            let radios = members.map { list[$0] }.sorted { $0.rssi != $1.rssi ? $0.rssi > $1.rssi : $0.bssid < $1.bssid }
            // The name most of its radios carry, so one radio named by mistake doesn't rename the box.
            let named = radios.compactMap { names[$0.bssid] }
            let name = Dictionary(grouping: named, by: { $0 }).max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
            return MeshNode(id: radios.map(\.bssid).min()!, name: name, radios: radios, current: radios.contains { $0.bssid == current })
        }.sorted { $0.strongest.rssi != $1.strongest.rssi ? $0.strongest.rssi > $1.strongest.rssi : $0.id < $1.id }
    }

    // MARK: Link rate

    /// Lowest signal for each 802.11ax rate (MCS 0–11) on a 20 MHz channel; each doubling of width needs 3 dB more.
    static let sensitivity = [-82, -79, -77, -74, -70, -66, -65, -64, -59, -57, -54, -52]
    /// One spatial stream's rate on 20 MHz at each MCS, in Mbit/s.
    static let rate20 = [8.6, 17.2, 25.8, 34.4, 51.6, 68.8, 77.4, 86.0, 103.2, 114.7, 129.0, 143.4]
    /// How much more a wider channel carries than 20 MHz.
    static func widthFactor(_ width: Int) -> Double { switch width { case 160...: 8.36; case 80..<160: 4.18; case 40..<80: 2.07; default: 1 } }

    /// The link rate a radio could reach at this signal, for two spatial streams like most Macs: an estimate to compare
    /// two radios, not a speed. The radio falls back to a narrower channel when the wide one is out of reach. On
    /// 2.4 GHz the width counts at most 40 MHz and the result is cut by 30%, for the neighbours and Bluetooth that
    /// share that band's airtime.
    public static func estimatedMbps(rssi: Int, band: String, widthMHz: Int, streams: Int = 2) -> Double {
        let low = band == "2.4 GHz"
        let widest = low ? min(widthMHz, 40) : min(max(widthMHz, 20), 160)
        var best = 0.0, width = 20
        while width <= widest {
            let penalty = Int((3 * log2(Double(width) / 20)).rounded())
            if let mcs = sensitivity.lastIndex(where: { rssi >= $0 + penalty }) {
                best = max(best, rate20[mcs] * widthFactor(width) * Double(streams))
            }
            width *= 2
        }
        return low ? best * 0.7 : best
    }
}

/// What one look at the joined Wi-Fi saw: the radio the Mac is on, and the same network's radios from a scan.
public struct NodeReading: Sendable {
    public let date: Date
    public let ssid: String?
    /// The radio the Mac is joined to, with its live signal; nil while not joined or without Location permission.
    public let current: NodeRadio?
    /// What macOS says the link runs at now.
    public let transmitMbps: Double?
    /// The same network's radios from the latest scan; empty when no scan was available.
    public let scan: [NodeRadio]
    /// Bands this Mac's Wi-Fi can use.
    public let supportedBands: Set<String>
    public init(date: Date, ssid: String?, current: NodeRadio?, transmitMbps: Double?, scan: [NodeRadio], supportedBands: Set<String> = ["2.4 GHz", "5 GHz"]) {
        self.date = date; self.ssid = ssid; self.current = current; self.transmitMbps = transmitMbps; self.scan = scan; self.supportedBands = supportedBands
    }
    /// The scan with the current radio's live reading in place of its scanned one.
    public var radios: [NodeRadio] {
        guard let current else { return scan }
        return scan.filter { $0.bssid != current.bssid } + [current]
    }
}

/// The Mac on a far node while a much better one is in range.
public struct StuckNode: Codable, Sendable, Equatable {
    /// When the readings first showed it.
    public let since: Date
    public let node: MeshNode
    public let better: MeshNode
    /// The current radio's signal and the better node's radio, the one with the best estimated rate.
    public let rssi: Int
    public let betterRSSI: Int
    public let betterBand: String
    public let currentMbps: Double
    public let betterMbps: Double
    public var difference: Int { betterRSSI - rssi }
}

/// Watches readings for a Mac that stays on a far node: the gap held for two minutes over three readings or more,
/// with the Mac's own signal steady (not being carried around) and no roam in the last minute.
public struct StickyDetector: Sendable {
    public static let sustain: TimeInterval = 120
    public static let readings = 3
    /// After a roam, macOS may still be settling; nothing counts for a minute.
    public static let settle: TimeInterval = 60
    /// The current signal moving more than this over the window means the Mac is moving.
    public static let steadyRange = 12
    /// A gap longer than this between readings (sleep, the app paused) starts over.
    public static let gap: TimeInterval = 300

    public enum State: String, Codable, Sendable { case notJoined, settling, fine, watching, stuck }
    public private(set) var state: State = .notJoined
    public private(set) var stuck: StuckNode?
    /// When the latest roam happened, within this run.
    public private(set) var lastRoam: Date?
    private var bssid: String?
    private var since: Date?
    private var window: [Int] = []
    private var lastDate: Date?
    public init() {}

    /// Starts over, as after Kilobat itself reconnected.
    public mutating func reset() { state = .notJoined; stuck = nil; bssid = nil; since = nil; window = []; lastDate = nil }

    /// One reading. `names` are the person's names for nodes, by BSSID.
    @discardableResult
    public mutating func observe(_ reading: NodeReading, names: [String: String] = [:]) -> State {
        defer { lastDate = reading.date }
        if let last = lastDate, reading.date.timeIntervalSince(last) > Self.gap { since = nil; window = []; stuck = nil }
        guard let current = reading.current else { reset(); return state }
        if let bssid, bssid != current.bssid { lastRoam = reading.date; since = nil; window = []; stuck = nil }
        bssid = current.bssid
        if let roam = lastRoam, reading.date.timeIntervalSince(roam) < Self.settle { state = .settling; return state }
        // No scan this time is no evidence either way.
        guard !reading.scan.isEmpty else { return state }
        guard let found = Self.candidate(reading, names: names, margin: since == nil ? MeshNodes.margin : MeshNodes.keepMargin) else {
            since = nil; window = []; stuck = nil; state = .fine; return state
        }
        if since == nil { since = reading.date; window = [] }
        window = Array((window + [current.rssi]).suffix(10))
        if (window.max() ?? 0) - (window.min() ?? 0) > Self.steadyRange { since = reading.date; window = [current.rssi]; stuck = nil }
        let start = since ?? reading.date
        if reading.date.timeIntervalSince(start) >= Self.sustain && window.count >= Self.readings {
            stuck = StuckNode(since: stuck?.since ?? start, node: found.node, better: found.better, rssi: current.rssi, betterRSSI: found.radio.rssi,
                              betterBand: found.radio.band, currentMbps: found.currentMbps, betterMbps: found.radio.estimatedMbps)
            state = .stuck
        } else { state = .watching }
        return state
    }

    /// The other node worth moving to in one reading, ignoring time: its radio on a band this Mac supports is at least
    /// `margin` dB stronger than the current one, which is weaker than −65 dBm, and promises 1.5× the link rate.
    /// Among such radios, the one with the best estimated rate wins.
    public static func candidate(_ reading: NodeReading, names: [String: String] = [:], margin: Int = MeshNodes.margin)
        -> (node: MeshNode, better: MeshNode, radio: NodeRadio, currentMbps: Double)? {
        guard let current = reading.current, current.rssi < MeshNodes.weakAbove else { return nil }
        let nodes = MeshNodes.nodes(reading.radios, current: current.bssid, names: names)
        guard nodes.count > 1, let mine = nodes.first(where: \.current) else { return nil }
        // The link may be doing better than its signal suggests; then it isn't worth giving up.
        let now = max(current.estimatedMbps, reading.transmitMbps ?? 0)
        var best: (node: MeshNode, radio: NodeRadio)?
        for node in nodes where !node.current {
            for radio in node.radios where reading.supportedBands.contains(radio.band) && radio.rssi - current.rssi >= margin {
                guard radio.estimatedMbps >= now * MeshNodes.gain else { continue }
                if radio.estimatedMbps > best?.radio.estimatedMbps ?? 0 { best = (node, radio) }
            }
        }
        return best.map { (mine, $0.node, $0.radio, now) }
    }
}
