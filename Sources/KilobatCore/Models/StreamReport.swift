import Foundation

/// One OBS stream as Kilobat saw it: OBS's own frame counters each second beside the call engine's line, the stretches
/// when frames dropped, and for each whether the network, the encoder or the GPU lost them.
public struct StreamReport: Codable, Identifiable, Sendable, Equatable {
    /// Which of OBS's counters a drop came from. Only `network` is the connection.
    public enum Source: String, Codable, Sendable {
        /// "Dropped Frames (Network)": the output threw frames away because the upload couldn't take them.
        case network
        /// "Skipped frames due to encoding lag": the encoder fell behind.
        case encoder
        /// "Frames missed due to rendering lag": the GPU didn't finish frames in time.
        case render
    }

    public struct Cause: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            case app, otherDevice, wifi, airDrop, starlink, portal, beyondRouter
            /// OBS's bitrate is more than the measured upload carries with 30% headroom.
            case bitrate
            /// OBS's encoder couldn't keep up; not the network.
            case encoder
            /// OBS's rendering lagged: the GPU was the bottleneck; not the network.
            case render
        }
        public let kind: Kind
        public var app: String? = nil
        public var uploading: Bool? = nil
        public var weakSignal: Bool? = nil
        public var dish: String? = nil
        public var device: String? = nil
        public var kilobat: Bool? = nil
        public var deviceApp: String? = nil
        /// The process that maxed out the CPU at the time, for `encoder`.
        public var top: String? = nil
        /// The GPU was maxed out at the time, for `render`.
        public var gpu: Bool? = nil
        public init(kind: Kind, app: String? = nil, uploading: Bool? = nil, weakSignal: Bool? = nil, dish: String? = nil, device: String? = nil,
                    kilobat: Bool? = nil, deviceApp: String? = nil, top: String? = nil, gpu: Bool? = nil) {
            self.kind = kind; self.app = app; self.uploading = uploading; self.weakSignal = weakSignal; self.dish = dish; self.device = device
            self.kilobat = kilobat; self.deviceApp = deviceApp; self.top = top; self.gpu = gpu
        }
        init(_ call: CallReport.Cause) {
            let kind: Kind = switch call.kind {
            case .app: .app
            case .otherDevice: .otherDevice
            case .wifi: .wifi
            case .airDrop: .airDrop
            case .starlink: .starlink
            case .beyondRouter: .beyondRouter
            case .portal: .portal
            }
            self.init(kind: kind, app: call.app, uploading: call.uploading, weakSignal: call.weakSignal, dish: call.dish, device: call.device,
                      kilobat: call.kilobat, deviceApp: call.deviceApp)
        }
        /// On the line, not in OBS.
        public var network: Bool { ![.encoder, .render].contains(kind) }

        /// Reads on from "Dropped 2% of frames 21:14–21:16:" — "Dropbox was uploading".
        public var phrase: String {
            switch kind {
            case .app: uploading == true ? String(localized: "\(app ?? "another app") was uploading", comment: "Stream report: why frames dropped; the argument is an app such as Dropbox")
                                         : String(localized: "\(app ?? "another app") was downloading", comment: "Stream report: why frames dropped; the argument is an app such as Steam")
            case .otherDevice:
                if let device, let deviceApp {
                    uploading == true ? String(localized: "\(device) was uploading on your network (\(deviceApp))", comment: "Stream report: a paired Mac was uploading; its name and busiest app")
                                      : String(localized: "\(device) was downloading on your network (\(deviceApp))", comment: "Stream report: a paired Mac was downloading; its name and busiest app")
                } else if let device {
                    uploading == true ? String(localized: "\(device) was uploading on your network", comment: "Stream report; the argument is a device's name, such as “Rita’s iPad”")
                                      : String(localized: "\(device) was downloading on your network", comment: "Stream report; the argument is a device's name, such as “Rita’s iPad”")
                } else {
                    uploading == true ? String(localized: "another device on your network was uploading", comment: "Stream report: a TV, phone or console on the same network")
                                      : String(localized: "another device on your network was downloading", comment: "Stream report: a TV, phone or console on the same network")
                }
            case .wifi: weakSignal == true ? String(localized: "the Wi-Fi signal was weak", comment: "Stream report: why frames dropped")
                                           : String(localized: "the Wi-Fi or router stalled", comment: "Stream report: why frames dropped")
            case .airDrop: String(localized: "AirDrop was scanning on your Wi-Fi", comment: "Stream report: AirDrop's radio hopping channels")
            case .portal: String(localized: "the Wi-Fi’s sign-in page logged you out", comment: "Stream report: a hotel or café Wi-Fi's sign-in ran out")
            case .starlink:
                switch dish {
                case "obstructed": String(localized: "something blocked the Starlink dish’s view of the sky", comment: "Stream report")
                case "noSatellites": String(localized: "no Starlink satellite was in view", comment: "Stream report")
                case "reboot": String(localized: "the Starlink dish restarted", comment: "Stream report")
                default: String(localized: "the Starlink dish was offline", comment: "Stream report")
                }
            case .beyondRouter: String(localized: "the upload slowed beyond your router, at your provider or on the way to the ingest server", comment: "Stream report: where the network drop came from")
            case .bitrate: String(localized: "OBS’s bitrate is more than your upload carries", comment: "Stream report: why frames dropped")
            case .encoder: top.map { String(localized: "OBS’s encoder couldn’t keep up while \($0) maxed out the CPU, not your connection", comment: "Stream report; the argument is a process") }
                ?? String(localized: "OBS’s encoder couldn’t keep up, not your connection", comment: "Stream report: frames skipped to encoding lag")
            case .render: String(localized: "your GPU was the bottleneck, not your connection", comment: "Stream report: frames missed to rendering lag")
            }
        }

        /// What to try before the next stream. The bitrate's advice needs the numbers, so the report gives it.
        public var advice: String {
            switch kind {
            case .app: String(localized: "Pause \(app ?? "that app") while you stream, or turn on Call mode for streams to hold it until the stream ends.", comment: "Stream report advice; the argument is an app")
            case .otherDevice where kilobat == true && device != nil:
                String(localized: "\(device ?? "") was busy at the time, as Kilobat on that Mac reported. Pause its downloads and uploads while you stream, or turn on call mode in Kilobat on that Mac.", comment: "Stream report advice; a paired Mac's name")
            case .otherDevice: String(localized: "Pause downloads and uploads on other devices while you stream, or give this Mac priority in your router’s QoS settings.", comment: "Stream report advice")
            case .wifi: weakSignal == true ? String(localized: "Stream over Ethernet, or move closer to the router.", comment: "Stream report advice")
                                           : String(localized: "Stream over Ethernet: Wi-Fi stalls drop frames even on a fast plan.", comment: "Stream report advice")
            case .airDrop: String(localized: "Turn on low latency before you stream; it pauses AirDrop until you turn it off.", comment: "Stream report advice")
            case .portal: String(localized: "Sign in again on the Wi-Fi’s page before you go live.", comment: "Stream report advice after a hotel or café Wi-Fi's sign-in ran out")
            case .starlink: CallSamples.Dish.advice(dish)
            case .beyondRouter: String(localized: "Pick a closer ingest server in OBS › Settings › Stream, or turn on “Dynamically change bitrate” in OBS › Settings › Advanced › Network so OBS lowers the bitrate instead of dropping frames.", comment: "Stream report advice; OBS's menu names")
            case .bitrate: String(localized: "Lower the bitrate in OBS › Settings › Output.", comment: "Stream report advice")
            case .encoder: top.map { String(localized: "Quit \($0) while you stream, or pick a faster encoder preset or the hardware encoder (Apple VT H264) in OBS › Settings › Output.", comment: "Stream report advice; the argument is a process") }
                ?? String(localized: "Pick a faster encoder preset or the hardware encoder (Apple VT H264) in OBS › Settings › Output, or lower the output resolution or frame rate.", comment: "Stream report advice")
            case .render: String(localized: "Lower the canvas or frame rate in OBS › Settings › Video, drop heavy sources and filters, and quit games or apps that load the GPU.", comment: "Stream report advice")
            }
        }
    }

    /// A stretch when frames dropped, from one of OBS's counters.
    public struct Drop: Codable, Sendable, Equatable {
        /// Seconds from the start of the stream.
        public let at: Double
        public let seconds: Double
        /// Frames lost in it.
        public let frames: Int
        /// Of the frames in it, the share lost.
        public let percent: Double
        public let source: Source
        public let cause: Cause
        public init(at: Double, seconds: Double, frames: Int, percent: Double, source: Source, cause: Cause) {
            self.at = at; self.seconds = seconds; self.frames = frames; self.percent = percent; self.source = source; self.cause = cause
        }
    }

    public var id = UUID()
    public let start: Date
    public let end: Date
    public let networkKey: String?
    public let networkName: String?
    /// The bitrate OBS was set to, video plus audio, in kbps; nil when OBS doesn't say.
    public let bitrate: Int?
    /// What OBS actually sent, on average, in kbps.
    public let sent: Double?
    /// The upload the last speed test on this network measured, in Mbps, and when.
    public let uplink: Double?
    public let uplinkDate: Date?
    /// OBS's counters over the stream: frames the output delivered and dropped, the encoder's and the renderer's.
    public let frames: Int
    public let dropped: Int
    public let encoderFrames: Int
    public let encoderSkipped: Int
    public let renderFrames: Int
    public let renderSkipped: Int
    /// The output's worst congestion, 0 to 1.
    public let congestion: Double?
    /// Internet ping over the stream.
    public let median: Double?
    public let jitter: Double?
    public let lossPercent: Double
    public let drops: [Drop]
    public let strain: [CallReport.Strain]
    public var household: Bool? = nil
    /// The apps Call mode for streams held until the stream ended.
    public var held: [String]? = nil
    /// The internet ping, at most 240 points, each the worst of its stretch.
    public let line: [Double?]

    public var seconds: Double { end.timeIntervalSince(start) }
    public var clean: Bool { drops.isEmpty }
    public var title: String { String(localized: "OBS stream", comment: "Stream report title") }

    static func share(_ part: Int, of total: Int) -> Double { total > 0 ? Double(part) / Double(total) * 100 : 0 }
    public var networkPercent: Double { Self.share(dropped, of: frames) }
    public var encoderPercent: Double { Self.share(encoderSkipped, of: encoderFrames) }
    public var renderPercent: Double { Self.share(renderSkipped, of: renderFrames) }
    /// The largest share any one counter lost.
    public var percent: Double { max(networkPercent, encoderPercent, renderPercent) }
    /// Worth a notification: half a percent of frames over the stream, or a stretch that lost one in twenty.
    public var meaningful: Bool { !drops.isEmpty && (percent >= 0.5 || drops.contains { $0.percent >= 5 }) }

    /// The bitrate plus 30% headroom, in Mbps.
    public var needed: Double? { bitrate.map(StreamHeadroom.needed) }
    /// Above what the upload carries with headroom.
    public var overBitrate: Bool { StreamHeadroom.verdict(bitrate: bitrate, upload: uplink) == .short || StreamHeadroom.verdict(bitrate: bitrate, upload: uplink) == .tight }

    /// "2.1%", "0.4%", "<0.1%".
    public static func format(_ percent: Double) -> String {
        percent > 0 && percent < 0.1 ? "<0.1%" : (percent / 100).formatted(.percent.precision(.fractionLength(percent >= 10 ? 0 : 1)))
    }

    /// The drops' causes, most frames first.
    public var causes: [(cause: Cause, count: Int, frames: Int)] {
        var order: [Cause] = [], counts: [Cause: (Int, Int)] = [:]
        for drop in drops {
            if counts[drop.cause] == nil { order.append(drop.cause) }
            let entry = counts[drop.cause] ?? (0, 0)
            counts[drop.cause] = (entry.0 + 1, entry.1 + drop.frames)
        }
        return order.map { ($0, counts[$0]!.0, counts[$0]!.1) }.sorted { $0.frames > $1.frames }
    }

    /// "No dropped frames", "Dropped 2.1% of frames" — without the cause, for Kilobat without Pro.
    public var count: String {
        if clean { return String(localized: "No dropped frames", comment: "Stream report: nothing dropped") }
        return String(localized: "Dropped \(Self.format(percent)) of frames", comment: "Stream report; the argument is a share such as 2.1%")
    }

    /// "21:14–21:16".
    public func span(_ drop: Drop) -> String {
        let from = start.addingTimeInterval(drop.at), to = start.addingTimeInterval(drop.at + drop.seconds)
        let a = from.formatted(date: .omitted, time: .shortened), b = to.formatted(date: .omitted, time: .shortened)
        return a == b ? a : "\(a)–\(b)"
    }

    /// The worst stretch: most frames lost.
    public var worst: Drop? { drops.max { $0.frames < $1.frames } }

    /// "Dropped 2.1% of frames 21:14–21:16: Dropbox was uploading", or with mixed causes, each with how many stretches.
    public var verdict: String {
        let causes = causes
        guard let first = causes.first, let worst else { return count }
        if causes.count == 1 {
            if drops.count == 1 {
                return String(localized: "Dropped \(Self.format(worst.percent)) of frames \(span(worst)): \(first.cause.phrase)", comment: "Stream report verdict: the share lost, when, then why")
            }
            return String(localized: "\(count) in \(drops.count) stretches: \(first.cause.phrase)", comment: "Stream report verdict: the share lost, how many stretches, then why")
        }
        let parts = causes.prefix(2).map { "\($0.cause.phrase) (\($0.count))" }
        return String(localized: "\(count): \(parts.formatted(.list(type: .and)))", comment: "Stream report verdict with mixed causes; each part ends with its count of stretches in brackets")
    }

    /// "Your upload is 12 Mbps and OBS needs 8." when both are known.
    public var capacity: String? {
        guard let uplink, let needed else { return nil }
        return String(localized: "Your upload is \(StreamHeadroom.mbps(uplink)) Mbps and OBS needs \(StreamHeadroom.mbps(needed)).", comment: "Stream report: measured upload, then the bitrate plus 30% headroom, both in Mbps")
    }

    /// What to try first: for the cause that lost the most frames, or the bitrate when it's set too high.
    public var advice: String? {
        if let first = causes.first?.cause {
            if first.kind == .bitrate || (first.network && overBitrate), let suggestion = lower { return suggestion }
            if first.kind == .beyondRouter, household != true {
                return first.advice + " " + String(localized: "If others share this network, a TV or console may be the cause; Kilobat sees other devices only when your router shares its traffic counters (UPnP).", comment: "Stream report advice")
            }
            return first.advice
        }
        return overBitrate ? lower : nil
    }

    /// "Lower the bitrate to 5,300 kbps: …" when the upload can't carry it with headroom.
    public var lower: String? {
        guard let uplink, let bitrate, overBitrate else { return nil }
        let target = StreamHeadroom.sustainable(upload: uplink)
        return String(localized: "Lower the bitrate in OBS › Settings › Output to \(target.formatted()) kbps: your upload measured \(StreamHeadroom.mbps(uplink)) Mbps, and \(bitrate.formatted()) kbps needs \(StreamHeadroom.mbps(StreamHeadroom.needed(bitrate))) Mbps with 30% headroom.",
                      comment: "Stream report advice: a bitrate in kbps, the measured upload in Mbps, the current bitrate in kbps and what it needs in Mbps")
    }

    /// When the encoder or GPU lost frames: said plainly, since people blame the connection.
    public var obsSide: String? {
        let encoder = drops.filter { $0.source == .encoder }.reduce(0) { $0 + $1.frames }, render = drops.filter { $0.source == .render }.reduce(0) { $0 + $1.frames }
        guard encoder + render > 0 else { return nil }
        if drops.allSatisfy({ $0.source != .network }) {
            return String(localized: "Every frame lost was inside OBS, not on your connection: a faster upload wouldn’t have helped.", comment: "Stream report")
        }
        return String(localized: "\((encoder + render).formatted()) of the frames lost were inside OBS, not on your connection.", comment: "Stream report; the argument is a count of frames")
    }

    public var macDetail: String? { strain.isEmpty ? nil : strain.prefix(2).map(\.sentence).joined(separator: " ") }

    /// The report as the CLI and MCP give it: the stored fields plus the sentences.
    public struct Exported: Encodable, Sendable {
        public let report: StreamReport
        public init(_ report: StreamReport) { self.report = report }
        private enum Keys: String, CodingKey { case title, verdict, advice, capacity, obsSide, clean, meaningful, networkPercent, encoderPercent, renderPercent, neededMbps, overBitrate, spans }
        public func encode(to encoder: Encoder) throws {
            try report.encode(to: encoder)
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(report.title, forKey: .title)
            try container.encode(report.verdict, forKey: .verdict)
            try container.encodeIfPresent(report.advice, forKey: .advice)
            try container.encodeIfPresent(report.capacity, forKey: .capacity)
            try container.encodeIfPresent(report.obsSide, forKey: .obsSide)
            try container.encode(report.clean, forKey: .clean)
            try container.encode(report.meaningful, forKey: .meaningful)
            try container.encode(report.networkPercent, forKey: .networkPercent)
            try container.encode(report.encoderPercent, forKey: .encoderPercent)
            try container.encode(report.renderPercent, forKey: .renderPercent)
            try container.encodeIfPresent(report.needed, forKey: .neededMbps)
            try container.encode(report.overBitrate, forKey: .overBitrate)
            try container.encode(report.drops.map(report.span), forKey: .spans)
        }
    }
}

/// The bitrate rule: the upload should carry the stream's bitrate with about 30% to spare, since the upload swings and
/// the stream also carries audio, retransmissions and whatever else the Mac sends.
public enum StreamHeadroom {
    public static let factor = 1.3
    public enum Verdict: String, Codable, Sendable { case ready, tight, short, unknown }

    /// Mbps the bitrate needs with headroom.
    /// In tenths, so 6,000 kbps needs exactly 7.8 Mbps rather than a hair over it.
    public static func needed(_ bitrate: Int) -> Double { Double(bitrate * 13) / 10_000 }
    /// The highest bitrate the upload carries with headroom, in kbps, rounded down to 100.
    public static func sustainable(upload: Double) -> Int { max(0, Int(upload * 10_000 / 13) / 100 * 100) }
    /// Ready with headroom; tight when the upload covers the bitrate but not the headroom; short when it doesn't cover it.
    public static func verdict(bitrate: Int?, upload: Double?) -> Verdict {
        guard let bitrate, bitrate > 0, let upload else { return .unknown }
        if upload >= needed(bitrate) { return .ready }
        return upload * 1000 >= Double(bitrate) ? .tight : .short
    }
    /// "12", "7.8".
    public static func mbps(_ value: Double) -> String { value >= 20 ? value.formatted(.number.precision(.fractionLength(0))) : value.formatted(.number.precision(.fractionLength(0...1))) }
}

/// What a stream's drops are measured from: the call engine's samples and OBS's counters each second.
public struct StreamSamples: Sendable {
    /// OBS's cumulative counters at one second of the stream.
    public struct Second: Codable, Sendable, Equatable {
        public let at: Double
        public let status: OBSStreamStatus
        public let stats: OBSStats?
        public init(at: Double, status: OBSStreamStatus, stats: OBSStats?) { self.at = at; self.status = status; self.stats = stats }
    }
    public var line = CallSamples()
    public var obs: [Second] = []
    public var bitrate: Int? = nil
    public var uplink: Double? = nil
    public var uplinkDate: Date? = nil
    public init() {}
}

public enum StreamAnalysis {
    /// A stretch counts once it loses this many frames; OBS drops a few now and then that nobody sees.
    static let fewest = 6
    /// Seconds without a loss that still join two stretches into one.
    static let gap = 3.0

    /// One counter's losses each second: what was lost and how many frames went through.
    struct Tick: Equatable { let at: Double; let lost: Int; let frames: Int }

    /// Per-second losses of a cumulative pair of counters. A counter that went backwards (OBS restarted the output)
    /// starts over from its new value.
    static func ticks(_ seconds: [StreamSamples.Second], _ read: (StreamSamples.Second) -> (lost: Int, total: Int)?) -> [Tick] {
        var result: [Tick] = [], last: (lost: Int, total: Int)?
        for second in seconds {
            guard let now = read(second) else { continue }
            if let previous = last {
                let lost = now.lost >= previous.lost ? now.lost - previous.lost : now.lost
                let frames = now.total >= previous.total ? now.total - previous.total : now.total
                result.append(Tick(at: second.at, lost: lost, frames: frames))
            }
            last = now
        }
        return result
    }

    /// Stretches of loss: seconds that lost frames, joined across gaps of up to three seconds, kept when they lost enough.
    static func windows(_ ticks: [Tick], fewest: Int = fewest, gap: Double = gap) -> [(from: Double, to: Double, lost: Int, frames: Int)] {
        var result: [(from: Double, to: Double, lost: Int, frames: Int)] = []
        var current: (from: Double, to: Double, lost: Int, frames: Int)?
        func close() { if let window = current, window.lost >= fewest { result.append(window) }; current = nil }
        for tick in ticks {
            if tick.lost > 0 {
                if let window = current, tick.at - window.to <= gap + 1 {
                    // The frames that went through in the quiet seconds between belong to the stretch too.
                    let between = ticks.filter { $0.at > window.to && $0.at < tick.at }.reduce(0) { $0 + $1.frames }
                    current = (window.from, tick.at, window.lost + tick.lost, window.frames + between + tick.frames)
                } else { close(); current = (tick.at, tick.at, tick.lost, tick.frames) }
            } else if let window = current, tick.at - window.to > gap { _ = window; close() }
        }
        close()
        return result
    }

    public static func report(start: Date, end: Date, network: (key: String, name: String)?, samples: StreamSamples) -> StreamReport {
        let obs = samples.obs.sorted { $0.at < $1.at }
        let replies = samples.line.internet.compactMap(\.ms)
        let median = StutterTest.percentile(replies.sorted(), 50)
        let loss = samples.line.internet.isEmpty ? 0 : Double(samples.line.internet.count - replies.count) / Double(samples.line.internet.count) * 100
        let strain = CallAnalysis.strain(samples.line.load)
        var drops: [StreamReport.Drop] = []

        func percent(_ lost: Int, _ frames: Int) -> Double { StreamReport.share(lost, of: max(frames, lost)) }
        for window in windows(ticks(obs) { ($0.status.skippedFrames, $0.status.totalFrames) }) {
            drops.append(.init(at: window.from, seconds: window.to - window.from + 1, frames: window.lost, percent: percent(window.lost, window.frames),
                               source: .network, cause: networkCause(from: window.from, to: window.to, samples: samples)))
        }
        for window in windows(ticks(obs) { $0.stats.map { ($0.encoderSkipped, $0.encoderTotal) } }) {
            let cpu = samples.line.load.first { $0.at >= window.from - 6 && $0.at <= window.to + 6 && $0.load.cpuMaxed }
            drops.append(.init(at: window.from, seconds: window.to - window.from + 1, frames: window.lost, percent: percent(window.lost, window.frames),
                               source: .encoder, cause: .init(kind: .encoder, top: cpu?.load.top)))
        }
        for window in windows(ticks(obs) { $0.stats.map { ($0.renderSkipped, $0.renderTotal) } }) {
            let gpu = samples.line.load.contains { $0.at >= window.from - 6 && $0.at <= window.to + 6 && $0.load.gpuMaxed }
            drops.append(.init(at: window.from, seconds: window.to - window.from + 1, frames: window.lost, percent: percent(window.lost, window.frames),
                               source: .render, cause: .init(kind: .render, gpu: gpu ? true : nil)))
        }
        drops.sort { $0.at < $1.at }

        func total(_ read: (StreamSamples.Second) -> (Int, Int)?) -> (lost: Int, frames: Int) {
            let ticks = ticks(obs) { read($0).map { (lost: $0.0, total: $0.1) } }
            return (ticks.reduce(0) { $0 + $1.lost }, ticks.reduce(0) { $0 + $1.frames })
        }
        let output = total { ($0.status.skippedFrames, $0.status.totalFrames) }
        let encoder = total { $0.stats.map { ($0.encoderSkipped, $0.encoderTotal) } }
        let render = total { $0.stats.map { ($0.renderSkipped, $0.renderTotal) } }
        let sent: Double? = {
            guard let first = obs.first, let last = obs.last, last.at > first.at, last.status.bytes >= first.status.bytes else { return nil }
            return (last.status.bytes - first.status.bytes) * 8 / (last.at - first.at) / 1000
        }()
        var card = StreamReport(start: start, end: end, networkKey: network?.key, networkName: network?.name, bitrate: samples.bitrate, sent: sent,
                                uplink: samples.uplink, uplinkDate: samples.uplinkDate,
                                frames: output.frames, dropped: output.lost, encoderFrames: encoder.frames, encoderSkipped: encoder.lost,
                                renderFrames: render.frames, renderSkipped: render.lost, congestion: obs.map(\.status.congestion).max(),
                                median: median, jitter: CallAnalysis.jitter(replies), lossPercent: loss, drops: drops, strain: strain,
                                line: CallAnalysis.line(samples.line.internet, points: 240))
        card.household = samples.line.household != nil
        return card
    }

    /// Why the output dropped frames: the call engine's causes, then the bitrate when nothing on this side was busy
    /// and the measured upload can't carry it.
    static func networkCause(from start: Double, to end: Double, samples: StreamSamples) -> StreamReport.Cause {
        let cause = StreamReport.Cause(CallAnalysis.cause(from: start, to: end, samples: samples.line))
        if cause.kind == .beyondRouter, [.short, .tight].contains(StreamHeadroom.verdict(bitrate: samples.bitrate, upload: samples.uplink)) { return .init(kind: .bitrate) }
        return cause
    }
}

/// The check before going live: can the upload carry OBS's bitrate with headroom, is the line steady, and is
/// anything else uploading right now.
public struct StreamReadiness: Codable, Sendable, Equatable {
    public enum Upload: String, Codable, Sendable {
        /// A short upload test just now.
        case test
        /// The last speed test on this network.
        case history
        case none
    }
    public let date: Date
    public let bitrate: Int?
    /// Where the bitrate came from: obs, lastStream or given.
    public let bitrateSource: String?
    public let upload: Double?
    public let uploadSource: Upload
    public let uploadDate: Date?
    public let latency: Double?
    public let jitter: Double?
    public let lossPercent: Double?
    public let metered: Bool
    /// Apps uploading or downloading a lot right now.
    public let busy: [Preflight.Issue]
    public init(date: Date = Date(), bitrate: Int?, bitrateSource: String?, upload: Double?, uploadSource: Upload, uploadDate: Date?,
                latency: Double?, jitter: Double?, lossPercent: Double?, metered: Bool, busy: [Preflight.Issue] = []) {
        self.date = date; self.bitrate = bitrate; self.bitrateSource = bitrateSource; self.upload = upload; self.uploadSource = uploadSource
        self.uploadDate = uploadDate; self.latency = latency; self.jitter = jitter; self.lossPercent = lossPercent; self.metered = metered; self.busy = busy
    }

    public var verdict: StreamHeadroom.Verdict { StreamHeadroom.verdict(bitrate: bitrate, upload: upload) }
    /// Jitter or loss that drops frames however fast the upload is.
    public var unstable: Bool { (jitter ?? 0) >= 30 || (lossPercent ?? 0) >= 1 }
    public var suggested: Int? { upload.map(StreamHeadroom.sustainable) }
    public var ready: Bool { verdict == .ready && !unstable && busy.isEmpty }

    /// One line on the upload and the bitrate.
    public var summary: String {
        guard let upload else { return String(localized: "Kilobat couldn’t measure your upload. Run a speed test, then check again.", comment: "Go live check") }
        let up = StreamHeadroom.mbps(upload)
        guard let bitrate else {
            return String(localized: "Your upload is \(up) Mbps: enough for up to \((suggested ?? 0).formatted()) kbps with 30% headroom.", comment: "Go live check without a known bitrate; upload in Mbps and a bitrate in kbps")
        }
        let need = StreamHeadroom.mbps(StreamHeadroom.needed(bitrate))
        switch verdict {
        case .ready: return String(localized: "Your upload is \(up) Mbps and OBS needs \(need) (\(bitrate.formatted()) kbps plus 30% headroom).", comment: "Go live check: ready; upload, need in Mbps, the bitrate in kbps")
        case .tight: return String(localized: "Tight: your upload is \(up) Mbps, enough for \(bitrate.formatted()) kbps but not the 30% headroom (\(need) Mbps). Lower the bitrate to \((suggested ?? 0).formatted()) kbps for margin.", comment: "Go live check: tight; upload in Mbps, the bitrate in kbps, need in Mbps, a suggested bitrate in kbps")
        case .short: return String(localized: "Not enough upload: \(up) Mbps, and OBS needs \(need). Lower the bitrate to \((suggested ?? 0).formatted()) kbps.", comment: "Go live check: short; upload, need in Mbps, a suggested bitrate in kbps")
        case .unknown: return String(localized: "Your upload is \(up) Mbps.", comment: "Go live check")
        }
    }

    /// The headline: "Ready to go live", "Tight", "Not enough upload".
    public var headline: String {
        if verdict == .short { return String(localized: "Not enough upload", comment: "Go live check headline") }
        if verdict == .tight || unstable || !busy.isEmpty { return String(localized: "Go live with care", comment: "Go live check headline") }
        if verdict == .ready { return String(localized: "Ready to go live", comment: "Go live check headline") }
        return String(localized: "Upload checked", comment: "Go live check headline when the bitrate is unknown")
    }

    /// The rest: where the upload came from, the line's steadiness, what's busy.
    public var notes: [String] {
        var notes: [String] = []
        if uploadSource == .history, let uploadDate {
            notes.append(metered ? String(localized: "This network is metered, so Kilobat used the speed test from \(uploadDate.formatted(.relative(presentation: .named))) instead of measuring.", comment: "Go live check; the argument is like “2 hours ago”")
                                 : String(localized: "From the speed test \(uploadDate.formatted(.relative(presentation: .named))).", comment: "Go live check; the argument is like “2 hours ago”"))
        } else if uploadSource == .none, metered {
            notes.append(String(localized: "This network is metered, so Kilobat didn’t measure. Measure anyway to check it.", comment: "Go live check"))
        }
        if unstable {
            notes.append(String(localized: "The line is unsteady (\(Int((jitter ?? 0).rounded())) ms jitter, \(StreamReport.format(lossPercent ?? 0)) loss): expect dropped frames whatever the bitrate. Ethernet helps if you’re on Wi-Fi.", comment: "Go live check; jitter in ms and a loss share"))
        }
        if !busy.isEmpty {
            let text = busy.map(\.phrase).formatted(.list(type: .and))
            notes.append(String(localized: "\(text.prefix(1).uppercased() + text.dropFirst()): pause it before you go live, or turn on Call mode for streams.", comment: "Go live check; the argument is like “Dropbox is uploading”"))
        }
        return notes
    }

    /// The check as the CLI and MCP give it.
    public struct Exported: Encodable, Sendable {
        public let check: StreamReadiness
        public init(_ check: StreamReadiness) { self.check = check }
        private enum Keys: String, CodingKey { case verdict, ready, unstable, neededMbps, suggestedKbps, headline, summary, notes }
        public func encode(to encoder: Encoder) throws {
            try check.encode(to: encoder)
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(check.verdict, forKey: .verdict)
            try container.encode(check.ready, forKey: .ready)
            try container.encode(check.unstable, forKey: .unstable)
            try container.encodeIfPresent(check.bitrate.map(StreamHeadroom.needed), forKey: .neededMbps)
            try container.encodeIfPresent(check.suggested, forKey: .suggestedKbps)
            try container.encode(check.headline, forKey: .headline)
            try container.encode(check.summary, forKey: .summary)
            try container.encode(check.notes, forKey: .notes)
        }
    }
}

public enum StreamCheck {
    /// The upload test before going live: about eight seconds, at most 16 MB, one connection to Cloudflare like
    /// OBS's one connection to the ingest server, and 20 pings to 1.1.1.1 for jitter and loss. `measure` false
    /// (a metered network nobody said yes to) reads `history` instead.
    public static func run(bitrate: Int?, bitrateSource: String?, measure: Bool, history: (mbps: Double, date: Date)?, metered: Bool,
                           busy: [Preflight.Issue] = []) async -> StreamReadiness {
        async let ping = DiagnosticProbe.ping("1.1.1.1", count: 20, interval: 0.2)
        var upload: Double?, source = StreamReadiness.Upload.none, date: Date?
        if measure, let measured = try? await SpeedTest.upload(maximumBytes: 16_000_000) {
            upload = measured; source = .test; date = Date()
        } else if let history {
            upload = history.mbps; source = .history; date = history.date
        }
        let result = await ping
        return StreamReadiness(bitrate: bitrate, bitrateSource: bitrateSource, upload: upload, uploadSource: source, uploadDate: date,
                               latency: result.average, jitter: result.jitter, lossPercent: result.lossPercent, metered: metered, busy: busy)
    }
}
