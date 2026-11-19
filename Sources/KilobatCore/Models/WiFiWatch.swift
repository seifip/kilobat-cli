import Foundation
import Observation

/// A watch session: nearby access points' signal over a few minutes, from scans the person started. Each scan takes
/// the Mac's radio off its channel for a moment, so scans come at least 10 seconds apart; the joined link's own signal
/// is read every 2 seconds in between, which costs nothing on the air.
public struct WiFiWatchRecording: Codable, Sendable, Equatable {
    public struct Radio: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let ssid: String
        public let band: String
        public let channel: Int
        public let widthMHz: Int
    }
    /// One scan: signal per radio id.
    public struct Scan: Codable, Sendable, Equatable {
        public let date: Date
        public let readings: [String: Int]
    }
    /// The joined link's signal between scans.
    public struct LinkSample: Codable, Sendable, Equatable {
        public let date: Date
        public let rssi: Int
    }
    public let start: Date
    public let duration: TimeInterval
    public let interval: TimeInterval
    public private(set) var radios: [String: Radio] = [:]
    public private(set) var scans: [Scan] = []
    public private(set) var link: [LinkSample] = []
    /// The joined access point's id and network, from the first link reading that named them.
    public private(set) var joined: String?
    public private(set) var ssid: String?
    public private(set) var joinedBand: String?
    public private(set) var joinedChannel: Int?
    /// Scans left out because a call was live, or that failed.
    public var skipped = 0

    public init(start: Date, duration: TimeInterval, interval: TimeInterval) { self.start = start; self.duration = duration; self.interval = interval }

    /// A scan result's key across scans: its BSSID, or without Location access its name, band and channel.
    public static func key(_ network: NearbyNetwork) -> String {
        network.id.hasPrefix("hidden-") ? "\(network.ssid)|\(network.band)|\(network.channel)" : network.id.lowercased()
    }

    public mutating func add(scan networks: [NearbyNetwork], at date: Date) {
        var readings: [String: Int] = [:]
        for network in networks where network.rssi < 0 {
            let key = Self.key(network)
            readings[key] = max(readings[key] ?? -999, network.rssi)
            if radios[key] == nil { radios[key] = Radio(id: key, ssid: network.ssid, band: network.band, channel: network.channel, widthMHz: network.widthMHz) }
        }
        scans.append(Scan(date: date, readings: readings))
    }

    public mutating func add(link radio: RadioSample, at date: Date) {
        guard let rssi = radio.rssi else { return }
        link.append(LinkSample(date: date, rssi: rssi))
        if joined == nil, let bssid = radio.bssid { joined = bssid.lowercased() }
        if ssid == nil { ssid = radio.ssid }
        if joinedBand == nil { joinedBand = radio.band; joinedChannel = radio.channel }
    }

    /// One access point's line.
    public struct Series: Sendable, Equatable, Identifiable {
        public let radio: Radio
        /// One point per scan, nil where the scan didn't hear it.
        public let points: [Int?]
        /// The radio this Mac is joined to.
        public let own: Bool
        /// Another radio of the Mac's own network.
        public let sameNetwork: Bool
        public var id: String { radio.id }
        public var heard: [Int] { points.compactMap { $0 } }
        public var median: Int? { let sorted = heard.sorted(); return sorted.isEmpty ? nil : sorted[sorted.count / 2] }
        public var low: Int? { heard.min() }
        public var high: Int? { heard.max() }
        /// Scans that didn't hear it. A scan can miss an access point that's there, so one gap means little.
        public var missed: Int { points.filter { $0 == nil }.count }
    }

    /// Whether a radio is the joined one: by BSSID, or without it by name, band and channel.
    func isOwn(_ radio: Radio) -> Bool {
        if let joined { return radio.id == joined }
        guard let ssid, radio.ssid == ssid else { return false }
        return radio.band == joinedBand && radio.channel == joinedChannel
    }

    /// The joined access point first, then the rest of its network, then the strongest others; `limit` lines at most.
    public func series(limit: Int = 8) -> [Series] {
        let all = radios.values.map { radio in
            Series(radio: radio, points: scans.map { $0.readings[radio.id] }, own: isOwn(radio), sameNetwork: !isOwn(radio) && ssid != nil && radio.ssid == ssid)
        }
        return all.sorted { a, b in
            if a.own != b.own { return a.own }
            if a.sameNetwork != b.sameNetwork { return a.sameNetwork }
            return (a.median ?? -999, b.radio.id) > (b.median ?? -999, a.radio.id)
        }.prefix(limit).map { $0 }
    }

    /// How much the joined link's signal moved, from the 2-second readings.
    public var linkSpread: Int? {
        let values = link.map(\.rssi)
        guard values.count >= 3, let low = values.min(), let high = values.max() else { return nil }
        return high - low
    }

    /// What the session showed, in a sentence or two.
    public var summary: String {
        guard !scans.isEmpty || !link.isEmpty else { return String(localized: "No readings yet.", comment: "Wi-Fi watch") }
        var parts: [String] = []
        if let spread = linkSpread, let low = link.map(\.rssi).min(), let high = link.map(\.rssi).max() {
            parts.append(spread >= 15
                ? String(localized: "Your signal swung by \(spread) dB (\(low) to \(high) dBm): something between this Mac and the router moved, or the Mac did.", comment: "Wi-Fi watch summary; spread, weakest and strongest dBm")
                : String(localized: "Your signal held steady between \(low) and \(high) dBm.", comment: "Wi-Fi watch summary; weakest and strongest dBm"))
        }
        let lines = series(limit: 64)
        if let own = lines.first(where: \.own), let ownMedian = own.median,
           let better = lines.filter(\.sameNetwork).max(by: { ($0.median ?? -999) < ($1.median ?? -999) }), let betterMedian = better.median, betterMedian - ownMedian >= 10 {
            parts.append(String(localized: "Another access point of your network was about \(betterMedian - ownMedian) dB stronger the whole time (\(better.radio.band), channel \(better.radio.channel)).",
                                comment: "Wi-Fi watch summary; dB difference, band and channel"))
        }
        if skipped > 0 { parts.append(String(localized: "\(skipped) scans were skipped during a call or failed.", comment: "Wi-Fi watch summary; a count")) }
        return parts.joined(separator: " ")
    }

    /// One row per access point per scan, plus the link's own readings, for a spreadsheet.
    public var csv: String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        format.timeZone = .current
        var rows = [["time", "source", "ssid", "bssid", "band", "channel", "rssi_dbm", "joined"]]
        let joinedRadio = radios.values.first(where: isOwn)
        for scan in scans {
            for (key, rssi) in scan.readings.sorted(by: { $0.key < $1.key }) {
                guard let radio = radios[key] else { continue }
                rows.append([format.string(from: scan.date), "scan", WiFiScanExport.text(radio.ssid), key.contains("|") ? "" : key, radio.band, String(radio.channel), String(rssi), isOwn(radio) ? "yes" : "no"])
            }
        }
        for sample in link {
            rows.append([format.string(from: sample.date), "link", WiFiScanExport.text(ssid ?? ""), joinedRadio.map { $0.id.contains("|") ? "" : $0.id } ?? (joined ?? ""), joinedBand ?? "",
                         joinedChannel.map(String.init) ?? "", String(sample.rssi), "yes"])
        }
        return rows.map(WiFiScanExport.line).joined()
    }
}

/// Runs a watch session: scans every `interval` seconds for `duration`, the joined link every 2 seconds. Started by the
/// person, never in the background, and gone once it ends or the app quits.
@MainActor @Observable public final class WiFiWatchSession {
    public static let defaultDuration: TimeInterval = 120
    public static let longest: TimeInterval = 600
    public static let shortest: TimeInterval = 30
    public static let defaultInterval: TimeInterval = 15
    /// A scan takes the radio off its channel for a moment; closer than this and a video call notices.
    public static let minimumInterval: TimeInterval = 10
    public static let linkEvery: TimeInterval = 2

    public private(set) var recording: WiFiWatchRecording?
    public private(set) var running = false
    /// 0–1 through the session.
    public private(set) var progress = 0.0
    private var task: Task<Void, Never>?

    public typealias Scan = @MainActor () async throws -> [NearbyNetwork]
    public typealias Link = @MainActor () async -> RadioSample
    private let scan: Scan
    private let readLink: Link
    private let pauseScans: @MainActor () -> Bool
    private let clock: @MainActor () -> Date
    private let pause: @MainActor (TimeInterval) async -> Void

    /// `clock` and `pause` are the wall clock and a sleep, replaced in tests.
    public init(scan: @escaping Scan, link: @escaping Link, pauseScans: @escaping @MainActor () -> Bool,
                clock: @escaping @MainActor () -> Date, pause: @escaping @MainActor (TimeInterval) async -> Void) {
        self.scan = scan; self.readLink = link; self.pauseScans = pauseScans; self.clock = clock; self.pause = pause
    }

    public static func clamp(duration: TimeInterval) -> TimeInterval { min(longest, max(shortest, duration)) }
    public static func clamp(interval: TimeInterval) -> TimeInterval { min(60, max(minimumInterval, interval)) }

    public func start(duration: TimeInterval = defaultDuration, interval: TimeInterval = defaultInterval) {
        guard !running else { return }
        running = true; progress = 0
        task = Task { [weak self] in
            guard let self else { return }
            _ = await self.record(duration: duration, interval: interval)
            self.running = false
        }
    }
    public func stop() { task?.cancel(); task = nil; running = false }
    #if DEBUG
    public func preview(_ recording: WiFiWatchRecording?, running: Bool = false, progress: Double = 1) { self.recording = recording; self.running = running; self.progress = progress }
    #endif
    public func clear() { guard !running else { return }; recording = nil; progress = 0 }

    /// The session itself, for the app (through `start`) and the CLI (awaited). Returns what it recorded.
    @discardableResult public func record(duration: TimeInterval, interval: TimeInterval, onUpdate: (@MainActor (WiFiWatchRecording) -> Void)? = nil) async -> WiFiWatchRecording {
        let duration = Self.clamp(duration: duration), interval = Self.clamp(interval: interval)
        let start = clock()
        var recording = WiFiWatchRecording(start: start, duration: duration, interval: interval)
        self.recording = recording
        var nextScan = start
        let end = start.addingTimeInterval(duration)
        while !Task.isCancelled {
            let now = clock()
            if now >= nextScan && now <= end {
                if pauseScans() { recording.skipped += 1 }
                else if let networks = try? await scan() { recording.add(scan: networks, at: clock()) }
                else { recording.skipped += 1 }
                while nextScan <= clock() { nextScan = nextScan.addingTimeInterval(interval) }
            }
            recording.add(link: await readLink(), at: clock())
            self.recording = recording
            progress = min(1, clock().timeIntervalSince(start) / duration)
            onUpdate?(recording)
            let left = end.timeIntervalSince(clock())
            if left <= 0 { break }
            await pause(min(Self.linkEvery, left))
        }
        progress = 1
        self.recording = recording
        return recording
    }
}
