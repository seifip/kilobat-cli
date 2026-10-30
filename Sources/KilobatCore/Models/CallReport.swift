import Foundation

/// One call as Kilobat heard it: which app held the microphone, how the line behaved, and what got in the way.
public struct CallReport: Codable, Identifiable, Sendable, Equatable {
    /// Why a freeze happened, judged from the router ping, the Wi-Fi and every other app's traffic at that moment.
    public struct Cause: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case app, wifi, airDrop, beyondRouter }
        public let kind: Kind
        /// The app moving data at the time, for `app`.
        public var app: String? = nil
        public var uploading: Bool? = nil
        /// The Wi-Fi signal was weak at the time, for `wifi`.
        public var weakSignal: Bool? = nil
        public init(kind: Kind, app: String? = nil, uploading: Bool? = nil, weakSignal: Bool? = nil) {
            self.kind = kind; self.app = app; self.uploading = uploading; self.weakSignal = weakSignal
        }
        /// Reads on from "caused by" or "on": "Dropbox uploading", "weak Wi-Fi".
        public var phrase: String {
            switch kind {
            case .app: uploading == true ? String(localized: "caused by \(app ?? "another app") uploading", comment: "Call report: what caused a freeze; the argument is an app")
                                         : String(localized: "caused by \(app ?? "another app") downloading", comment: "Call report: what caused a freeze; the argument is an app")
            case .wifi: weakSignal == true ? String(localized: "on weak Wi-Fi", comment: "Call report: where a freeze happened")
                                           : String(localized: "on the Wi-Fi or router", comment: "Call report: where a freeze happened")
            case .airDrop: String(localized: "caused by AirDrop scanning", comment: "Call report: AirDrop's radio hopping channels caused a freeze")
            case .beyondRouter: String(localized: "beyond your router", comment: "Call report: the freeze happened between the router and the call's server")
            }
        }
        /// What to try before the next call.
        public var advice: String {
            switch kind {
            case .app: String(localized: "Pause \(app ?? "that app") before calls, or block it with a profile while you’re on one.", comment: "Call report advice; the argument is an app")
            case .wifi: weakSignal == true ? String(localized: "Move closer to the router, or use Radar to find a stronger spot.", comment: "Call report advice")
                                           : String(localized: "Restart the router, or try a cable or the 5 GHz band.", comment: "Call report advice")
            case .airDrop: String(localized: "Turn on low latency before calls; it pauses AirDrop until you turn it off.", comment: "Call report advice")
            case .beyondRouter: String(localized: "If it keeps happening, the report for your provider shows it over time.", comment: "Call report advice")
            }
        }
    }
    /// A stretch when the Mac itself was the bottleneck, which freezes a call on a clean line.
    public struct Strain: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case cpu, memory, thermal, gpu }
        public let kind: Kind
        public let seconds: Double
        /// The process that used the most CPU while it lasted, for `cpu`.
        public var top: String? = nil
        public init(kind: Kind, seconds: Double, top: String? = nil) { self.kind = kind; self.seconds = seconds; self.top = top }
        private var length: String { Duration.seconds(max(60, seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) }
        /// "The CPU was maxed out for 3 min, mostly by Xcode."
        public var sentence: String {
            switch kind {
            case .cpu: top.map { String(localized: "The Mac’s CPU was maxed out for \(length), mostly by \($0).", comment: "Call report; the arguments are a duration and a process") }
                ?? String(localized: "The Mac’s CPU was maxed out for \(length).", comment: "Call report; the argument is a duration")
            case .memory: String(localized: "The Mac ran out of memory for \(length).", comment: "Call report; the argument is a duration")
            case .thermal: String(localized: "The Mac was hot and slowed itself down for \(length).", comment: "Call report; the argument is a duration")
            case .gpu: String(localized: "The GPU was maxed out for \(length).", comment: "Call report; the argument is a duration")
            }
        }
        public var advice: String {
            switch kind {
            case .cpu: top.map { String(localized: "Quit \($0) during calls, or turn off video effects in the call app.", comment: "Call report advice; the argument is a process") }
                ?? String(localized: "Quit heavy apps during calls, or turn off video effects in the call app.", comment: "Call report advice")
            case .memory: String(localized: "Quit apps and close browser tabs you don’t need during calls.", comment: "Call report advice")
            case .thermal: String(localized: "Keep the Mac on a hard surface and out of the sun, with fewer heavy apps open.", comment: "Call report advice")
            case .gpu: String(localized: "Turn off background blur and other video effects in the call app.", comment: "Call report advice")
            }
        }
    }
    public struct Freeze: Codable, Sendable, Equatable {
        /// Seconds from the start of the call.
        public let at: Double
        public let seconds: Double
        /// The worst reply in milliseconds; nil when every ping in it was lost.
        public let peak: Double?
        public let cause: Cause
    }

    public var id = UUID()
    /// The calling app's name, such as Zoom, or the browser for a call on the web.
    public let app: String
    public let browser: Bool
    public let start: Date
    public let end: Date
    public let networkKey: String?
    public let networkName: String?
    /// Internet ping over the call.
    public let median: Double?
    public let jitter: Double?
    public let lossPercent: Double
    public let freezes: [Freeze]
    /// When the Mac itself was the bottleneck, longest first.
    public let strain: [Strain]
    /// The internet ping, at most 240 points, each the worst of its stretch; nil where every ping was lost.
    public let line: [Double?]

    public var seconds: Double { end.timeIntervalSince(start) }
    public var clean: Bool { freezes.isEmpty && strain.isEmpty }
    public var title: String {
        browser ? String(localized: "Call in \(app)", comment: "Call report title for a call in a web browser; the argument is the browser")
                : String(localized: "\(app) call", comment: "Call report title; the argument is an app such as Zoom")
    }
    /// The freezes' causes, most frequent first.
    public var causes: [(cause: Cause, count: Int)] {
        var order: [Cause] = [], counts: [Cause: Int] = [:]
        for freeze in freezes { if counts[freeze.cause] == nil { order.append(freeze.cause) }; counts[freeze.cause, default: 0] += 1 }
        return order.map { ($0, counts[$0]!) }.sorted { $0.count > $1.count }
    }
    /// "Clean call", "3 freezes", "Mac overloaded" — without the cause, for Kilobat without Pro.
    public var count: String {
        if clean { return String(localized: "Clean call", comment: "Call report: no freezes") }
        if freezes.isEmpty { return String(localized: "Mac overloaded", comment: "Call report: the network was fine but the Mac itself was struggling") }
        return String(localized: "\(freezes.count) freezes", comment: "Call report: how many times the call froze")
    }
    /// One line: "Clean call", "3 freezes, caused by Dropbox uploading", "3 freezes: 2 caused by Dropbox uploading, 1 on weak Wi-Fi".
    public var verdict: String {
        let causes = causes
        guard let first = causes.first else {
            return strain.isEmpty ? count : String(localized: "No network freezes, but the Mac was overloaded", comment: "Call report verdict: the line was clean, the Mac struggled")
        }
        if causes.count == 1 {
            return String(localized: "\(count), \(first.cause.phrase)", comment: "Call report verdict: the number of freezes, then their cause")
        }
        let parts = causes.prefix(2).map { String(localized: "\($0.count) \($0.cause.phrase)", comment: "Call report: how many freezes had this cause, such as “2 caused by Dropbox uploading”") }
        return String(localized: "\(count): \(parts.formatted(.list(type: .and)))", comment: "Call report verdict with mixed causes")
    }
    /// What to try first: for the most frequent freeze cause, or for the Mac when the line was clean.
    public var advice: String? { causes.first?.cause.advice ?? strain.first?.advice }
    /// The Mac's side in a sentence or two, when it struggled.
    public var macDetail: String? { strain.isEmpty ? nil : strain.prefix(2).map(\.sentence).joined(separator: " ") }
}

/// What a call's freezes are measured from: one ping a second to the internet and to the router, every other app's
/// traffic each second, and the Wi-Fi as Kilobat last saw it.
public struct CallSamples: Sendable {
    public struct Ping: Sendable { public let at: Double; public let ms: Double? ; public init(at: Double, ms: Double?) { self.at = at; self.ms = ms } }
    /// The busiest other app at a moment, with its rates in bytes a second.
    public struct Traffic: Sendable {
        public let at: Double; public let app: String; public let upload: Double; public let download: Double
        public init(at: Double, app: String, upload: Double, download: Double) { self.at = at; self.app = app; self.upload = upload; self.download = download }
    }
    public var internet: [Ping] = []
    public var router: [Ping] = []
    public var traffic: [Traffic] = []
    /// The Mac's own load, every few seconds.
    public struct Load: Sendable { public let at: Double; public let load: MacLoad; public init(at: Double, load: MacLoad) { self.at = at; self.load = load } }
    public var load: [Load] = []
    /// Moments the Wi-Fi signal was weak.
    public var weakSignal: [Double] = []
    /// AirDrop's link was busy at some point in the call.
    public var airDrop = false
    public init() {}
}

public enum CallAnalysis {
    /// A ping this much slower than the call's median, or lost, is a bad second; two in a row the other side hears.
    static let spike = 200.0
    /// Another app moving this much at the time is enough to choke a call: about 1 Mbps up, 12 Mbps down.
    static let uploadLoad = 125_000.0, downloadLoad = 1_500_000.0

    public static func report(app: String, browser: Bool, start: Date, end: Date, network: (key: String, name: String)?, samples: CallSamples) -> CallReport {
        let replies = samples.internet.compactMap(\.ms).sorted()
        let median = StutterTest.percentile(replies, 50)
        let jitter = Self.jitter(samples.internet.compactMap(\.ms))
        let loss = samples.internet.isEmpty ? 0 : Double(samples.internet.filter { $0.ms == nil }.count) / Double(samples.internet.count) * 100
        let freezes = runs(samples.internet, median: median).map { run in
            CallReport.Freeze(run: run, cause: cause(from: run.first!.at, to: run.last!.at, samples: samples))
        }
        return CallReport(app: app, browser: browser, start: start, end: end, networkKey: network?.key, networkName: network?.name,
                          median: median, jitter: jitter, lossPercent: loss, freezes: freezes, strain: strain(samples.load), line: line(samples.internet, points: 240))
    }

    /// Bad seconds two or more in a row, with lone good replies inside a freeze bridged over.
    static func runs(_ pings: [CallSamples.Ping], median: Double?) -> [[CallSamples.Ping]] {
        func bad(_ ping: CallSamples.Ping) -> Bool { ping.ms.map { $0 > (median ?? 0) + spike } ?? true }
        var runs: [[CallSamples.Ping]] = [], current: [CallSamples.Ping] = [], gap = 0
        func close() { if current.filter(bad).count >= 2 { runs.append(current) }; current = []; gap = 0 }
        for ping in pings {
            if bad(ping) { current.append(ping); gap = 0 }
            else if !current.isEmpty { gap += 1; if gap > 1 { close() } else { current.append(ping) } }
        }
        close()
        return runs.map { run in Array(run.reversed().drop { !bad($0) }.reversed()) }
    }

    static func cause(from start: Double, to end: Double, samples: CallSamples) -> CallReport.Cause {
        let routerReplies = samples.router.compactMap(\.ms).sorted()
        let routerMedian = StutterTest.percentile(routerReplies, 50) ?? 0
        let local = samples.router.contains { $0.at >= start - 1 && $0.at <= end + 1 && ($0.ms.map { $0 > routerMedian + 100 } ?? true) }
        if local {
            let weak = samples.weakSignal.contains { abs($0 - start) < 60 }
            if samples.airDrop && !weak { return .init(kind: .airDrop) }
            return .init(kind: .wifi, weakSignal: weak)
        }
        let busy = samples.traffic.filter { $0.at >= start - 5 && $0.at <= end + 1 && ($0.upload >= uploadLoad || $0.download >= downloadLoad) }
        if let top = busy.max(by: { $0.upload / uploadLoad + $0.download / downloadLoad < $1.upload / uploadLoad + $1.download / downloadLoad }) {
            return .init(kind: .app, app: top.app, uploading: top.upload / uploadLoad >= top.download / downloadLoad)
        }
        return .init(kind: .beyondRouter)
    }

    /// Each kind of strain that lasted at least 15 seconds, longest first. Samples are a few seconds apart.
    static func strain(_ load: [CallSamples.Load]) -> [CallReport.Strain] {
        guard load.count > 1 else { return [] }
        let step = (load.last!.at - load.first!.at) / Double(load.count - 1)
        let kinds: [(CallReport.Strain.Kind, (MacLoad) -> Bool)] = [(.cpu, \.cpuMaxed), (.memory, \.memoryOut), (.thermal, \.throttled), (.gpu, \.gpuMaxed)]
        return kinds.compactMap { kind, test in
            let hits = load.filter { test($0.load) }
            guard Double(hits.count) * step >= 15 else { return nil }
            let tops = Dictionary(grouping: hits.compactMap(\.load.top), by: { $0 })
            return CallReport.Strain(kind: kind, seconds: Double(hits.count) * step, top: kind == .cpu ? tops.max { $0.value.count < $1.value.count }?.key : nil)
        }.sorted { $0.seconds > $1.seconds }
    }

    static func jitter(_ replies: [Double]) -> Double? {
        guard replies.count > 1 else { return nil }
        return zip(replies.dropFirst(), replies).map { abs($0 - $1) }.reduce(0, +) / Double(replies.count - 1)
    }

    /// The ping squeezed to `points` values, each the worst reply of its stretch.
    static func line(_ pings: [CallSamples.Ping], points: Int) -> [Double?] {
        guard pings.count > points else { return pings.map(\.ms) }
        let size = Double(pings.count) / Double(points)
        return (0..<points).map { index in
            let slice = pings[Int(Double(index) * size)..<min(pings.count, Int(Double(index + 1) * size))]
            return slice.compactMap(\.ms).max()
        }
    }
}

extension CallReport.Freeze {
    init(run: [CallSamples.Ping], cause: CallReport.Cause) {
        self.init(at: run.first!.at, seconds: run.last!.at - run.first!.at + 1, peak: run.compactMap(\.ms).max(), cause: cause)
    }
}
