import Darwin
import Foundation

/// Send later: an app that keeps uploading a lot gets a row in the menu with its rate, what it has sent and, when
/// the total is knowable, how long is left. One click holds it until the Mac is on an unmetered or faster network,
/// for some hours, or until you send it. Sync and backup apps are suspended through `CallMode`'s ledger (owner
/// `upload`), so a call, a Focus and a held upload never resume each other's apps; other apps only have their new
/// connections refused by the filter; browsers, macOS, command-line tools and the app in front are never paused.
public enum SendLater {
    /// The ledger owner, beside `CallMode.call` and `CallMode.focus`.
    public static let owner = "upload"
    /// An upload this fast always counts as big.
    public static let floorRate: Double = 1_000_000
    /// On a slow uplink, half of what a speed test measured counts too…
    public static let uplinkShare = 0.5
    /// …but never less than this, so a trickle on a very slow link isn't a big upload.
    public static let minimumRate: Double = 64_000
    /// How long an app must keep it up before the row shows.
    public static let sustain: TimeInterval = 20
    /// The rate is averaged over this long, so one quiet second doesn't end it.
    public static let window: TimeInterval = 10
    /// Below the threshold this long and the upload is over.
    public static let quiet: TimeInterval = 30
    /// The longest Kilobat holds an upload, whatever it waits for: sync apps stay suspended no longer than a working day.
    public static let limit: TimeInterval = 8 * 60 * 60
    /// What “a faster network” means unless you say otherwise: a measured upload of at least this many Mbps.
    public static let fastMbps: Double = 20
    /// The filter's temporary block for a held app is renewed while the hold lasts, so after a crash it lapses within this.
    public static let blockMinutes = 30

    /// Bytes per second an app must keep up to count as a big upload on a network whose speed test measured `uplinkMbps`.
    public static func threshold(uplinkMbps: Double?) -> Double {
        guard let uplinkMbps, uplinkMbps > 0 else { return floorRate }
        return min(floorRate, max(minimumRate, uplinkMbps * 125_000 * uplinkShare))
    }

    /// Seconds left, only when the total is known: a rate alone never makes an estimate.
    public static func eta(rate: Double, progress: UploadProgress?) -> TimeInterval? {
        guard let progress, progress.total > progress.done, rate > 0 else { return nil }
        return Double(progress.total - progress.done) / rate
    }

    // MARK: Which apps can be held, and how

    /// Browsers: holding one would freeze every tab, so their uploads are only shown.
    static let browsers = ["com.apple.Safari", "com.apple.WebKit", "com.google.Chrome", "org.chromium.", "company.thebrowser.", "com.microsoft.edgemac",
                           "org.mozilla.", "com.brave.Browser", "com.operasoftware.", "com.vivaldi.", "app.zen-browser.", "com.kagi.kagimacOS",
                           "com.duckduckgo.macos.browser", "ai.perplexity.comet", "com.openai.atlas"]
    /// Command-line tools whose one open file is what they upload. Only curl was checked; scp and sftp hand the bytes
    /// to an ssh child, and rsync, rclone and git send something other than the file they read.
    static let fileReaders: Set<String> = ["curl"]

    /// How an app can be held: what `kilobat uploads` calls `method`, with the reason when it can't be.
    public static func plan(id: String, bundlePath: String? = nil, carrier: Bool = false) -> UploadPlan {
        if id.hasPrefix("co.seifi.kilobat") { return UploadPlan(.none, String(localized: "This is Kilobat itself.", comment: "Send later: why Kilobat's own upload can't be held")) }
        if carrier { return UploadPlan(.none, String(localized: "A VPN or proxy that carries other apps’ traffic. Hold the app behind it instead.", comment: "Send later: why a VPN or proxy can't be held")) }
        if browsers.contains(where: id.hasPrefix) {
            return UploadPlan(.none, String(localized: "Kilobat never pauses a browser: every tab would freeze. It shows the upload only.", comment: "Send later: why a browser upload can't be held"))
        }
        if id.hasPrefix("com.apple.") || bundlePath?.hasPrefix("/System/") == true {
            return UploadPlan(.none, String(localized: "Part of macOS, which isn’t safe to pause. Kilobat shows the upload only.", comment: "Send later: why an Apple service (iCloud, Photos, AirDrop) can't be held"))
        }
        if let name = CallMode.name(of: id) {
            if CallMode.launchers.contains(name) { return UploadPlan(.none, String(localized: "Game launchers run your games, so Kilobat doesn’t pause them for uploads.", comment: "Send later: why Steam or Epic can't be held")) }
            return UploadPlan(.suspend, nil)
        }
        if id.hasPrefix("process:") {
            return UploadPlan(.none, String(localized: "A command-line tool. Pausing it would leave the server waiting until it gives up and its terminal showing a stopped job, so Kilobat shows the upload only.", comment: "Send later: why git, curl or rsync can't be held"))
        }
        return UploadPlan(.block, nil)
    }

    /// The name and key an app's traffic is grouped under: call mode's name for the apps it knows, so Dropbox's helpers
    /// are one upload, and `git push` for the ssh or HTTPS helper git started.
    public static func identity(id: String, name: String, pid: Int32?) -> (key: String, name: String) {
        if let known = CallMode.name(of: id) { return (known, known) }
        if ["process:ssh", "process:git-remote-https", "process:git-remote-http", "process:git"].contains(id), let pid {
            if id == "process:git" || parentName(pid) == "git" { return ("git push", "git push") }
        }
        return (id, name)
    }

    static func parentName(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        var parent = proc_bsdinfo()
        guard proc_pidinfo(Int32(info.pbi_ppid), PROC_PIDTBSDINFO, 0, &parent, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return withUnsafeBytes(of: parent.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// How far `curl -T` is: the file's size, and what the process has sent since it started (`sent`, from nettop's
    /// own count, so headers and TLS are in it; capped at the total). curl finds the size by seeking to the end and
    /// reads by position, so the file's offset says nothing about progress and isn't used.
    public static func progress(pid: Int32, sent: UInt64?, minimum: UInt64 = 20_000_000) -> UploadProgress? {
        guard let sent, let file = uploadFile(pid: pid, minimum: minimum) else { return nil }
        return UploadProgress(total: file.total, done: min(sent, file.total), file: file.file, source: .file)
    }

    /// The one large regular file the process has open for reading only, with its size. Nil when there is none or
    /// more than one, since then the total isn't known.
    public static func uploadFile(pid: Int32, minimum: UInt64 = 20_000_000) -> (total: UInt64, file: String)? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return nil }
        var found: [(total: UInt64, file: String)] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            // Open for reading only (FREAD 1, FWRITE 2), and a regular file.
            let flags = info.pfi.fi_openflags, stat = info.pvip.vip_vi.vi_stat
            guard flags & 1 != 0, flags & 2 == 0, stat.vst_mode & S_IFMT == S_IFREG, stat.vst_size >= 0, UInt64(stat.vst_size) >= minimum else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            // The same file open twice is still one file.
            if !found.contains(where: { $0.file == path }) { found.append((UInt64(stat.vst_size), path)) }
        }
        return found.count == 1 ? (found[0].total, URL(fileURLWithPath: found[0].file).lastPathComponent) : nil
    }

    /// Where an upload's total can come from, for the app with `id`: only a file a command-line uploader reads.
    public static func knowsTotal(id: String) -> Bool { id.hasPrefix("process:") && fileReaders.contains(String(id.dropFirst(8))) }
}

public enum UploadMethod: String, Codable, Sendable {
    /// Suspended through call mode's ledger, and its new connections refused while the filter is on.
    case suspend
    /// Only its new connections refused, by the filter; a transfer already running may finish.
    case block
    /// Shown, never held.
    case none
}

public struct UploadPlan: Equatable, Sendable {
    public let method: UploadMethod
    public let reason: String?
    init(_ method: UploadMethod, _ reason: String?) { self.method = method; self.reason = reason }
}

/// How far an upload is when its total is knowable.
public struct UploadProgress: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case file }
    public let total: UInt64
    public let done: UInt64
    /// The file's name, without its folder.
    public let file: String?
    public let source: Source
    public init(total: UInt64, done: UInt64, file: String? = nil, source: Source = .file) { self.total = total; self.done = done; self.file = file; self.source = source }
}

/// What a held upload waits for.
public struct UploadCondition: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case unmetered, fast, time, manual }
    public let kind: Kind
    /// For `fast`: the measured upload a network needs, in Mbps.
    public var mbps: Double?
    /// For `time`.
    public var until: Date?
    public static let unmetered = UploadCondition(kind: .unmetered)
    public static let manual = UploadCondition(kind: .manual)
    public static func fast(_ mbps: Double = SendLater.fastMbps) -> UploadCondition { UploadCondition(kind: .fast, mbps: mbps) }
    public static func time(_ until: Date) -> UploadCondition { UploadCondition(kind: .time, until: until) }
    public init(kind: Kind, mbps: Double? = nil, until: Date? = nil) { self.kind = kind; self.mbps = mbps; self.until = until }

    /// The default for one click: an unmetered network when this one is metered, otherwise a faster one.
    public static func automatic(metered: Bool) -> UploadCondition { metered ? .unmetered : .fast() }

    /// `unmetered`, `fast`, `fast:30` (Mbps), `manual`, or a duration such as `2h`, `90m` or `1h30m`; `auto` or nil is nil.
    public static func parse(_ text: String?, now: Date = Date()) throws -> UploadCondition? {
        guard let text = text?.lowercased(), !text.isEmpty, text != "auto" else { return nil }
        switch text {
        case "unmetered": return .unmetered
        case "fast", "faster": return .fast()
        case "manual", "never": return .manual
        default: break
        }
        if text.hasPrefix("fast:") {
            guard let mbps = Double(text.dropFirst(5)), mbps > 0, mbps <= 10_000 else { throw UploadError(String(localized: "Use fast:<Mbps>, such as fast:30.", comment: "Send later: a bad --until fast value")) }
            return .fast(mbps)
        }
        guard let seconds = duration(text), seconds >= 60, seconds <= SendLater.limit else {
            throw UploadError(String(localized: "Use --until unmetered, fast, fast:<Mbps>, manual, or a time from 1m to 8h such as 2h or 90m.", comment: "Send later: a bad --until value"))
        }
        return .time(now.addingTimeInterval(seconds))
    }

    /// `2h`, `90m`, `1h30m`, `45s`.
    static func duration(_ text: String) -> TimeInterval? {
        var total = 0.0, digits = "", any = false
        for character in text {
            if character.isNumber || character == "." { digits.append(character); continue }
            guard let value = Double(digits), let unit = ["h": 3600.0, "m": 60, "s": 1][character] else { return nil }
            total += value * unit; digits = ""; any = true
        }
        return digits.isEmpty && any ? total : nil
    }

    /// Whether the network now is what it waits for.
    public func met(on network: UploadNetwork, now: Date = Date()) -> Bool {
        switch kind {
        case .unmetered: network.connected && network.known && !network.metered
        case .fast: network.connected && network.known && (network.markedFast || (network.uploadMbps ?? 0) >= (mbps ?? SendLater.fastMbps))
        case .time: now >= (until ?? .distantPast)
        case .manual: false
        }
    }

    /// “until an unmetered network”, for the row and the CLI.
    public var phrase: String {
        switch kind {
        case .unmetered: String(localized: "until an unmetered network", comment: "Send later: what a held upload waits for")
        case .fast: String(localized: "until a network with \(Int(mbps ?? SendLater.fastMbps)) Mbps up", comment: "Send later: a held upload waits for a network whose speed test measured this upload")
        case .time: String(localized: "until \((until ?? Date()).formatted(date: .omitted, time: .shortened))", comment: "Send later: a held upload waits until this time")
        case .manual: String(localized: "until you send it", comment: "Send later: a held upload waits for a click")
        }
    }
}

/// What the conditions are checked against: the network the Mac is on now.
public struct UploadNetwork: Equatable, Sendable {
    public var key: String
    public var name: String
    public var connected: Bool
    public var metered: Bool
    /// The newest speed test's upload on this network.
    public var uploadMbps: Double?
    /// You said this network is fast enough.
    public var markedFast: Bool
    public var known: Bool { key != "unknown" }
    public init(key: String, name: String, connected: Bool = true, metered: Bool, uploadMbps: Double? = nil, markedFast: Bool = false) {
        self.key = key; self.name = name; self.connected = connected; self.metered = metered; self.uploadMbps = uploadMbps; self.markedFast = markedFast
    }
}

/// One held upload, as saved while it lasts.
public struct UploadHold: Codable, Equatable, Sendable {
    /// The upload's key: call mode's name for apps it knows, otherwise the app's ID.
    public let key: String
    public let name: String
    public let method: UploadMethod
    public let condition: UploadCondition
    public let since: Date
    /// The network it was held on.
    public let network: String
    /// What it had sent before it was held.
    public let sent: UInt64
    public var deadline: Date { since.addingTimeInterval(SendLater.limit) }
    public init(key: String, name: String, method: UploadMethod, condition: UploadCondition, since: Date, network: String, sent: UInt64) {
        self.key = key; self.name = name; self.method = method; self.condition = condition; self.since = since; self.network = network; self.sent = sent
    }
}

/// Why a held upload went again.
public enum UploadResume: String, Codable, Sendable {
    case condition, manual, opened, limit, exited, quit
}

public struct UploadError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One app uploading a lot right now, or held.
public struct BigUpload: Codable, Equatable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public var name: String
    /// The traffic list's IDs it covers.
    public var apps: [String]
    public var bundlePath: String?
    /// Bytes per second over the last ten seconds; zero while held.
    public var rate: Double
    /// Bytes sent since it started, or before it was held.
    public var sent: UInt64
    public var since: Date
    /// Only when the total is knowable.
    public var progress: UploadProgress?
    public var method: UploadMethod
    public var reason: String?
    public var hold: UploadHold?
    public var eta: TimeInterval? { hold == nil ? SendLater.eta(rate: rate, progress: progress) : nil }
    public init(key: String, name: String, apps: [String], bundlePath: String? = nil, rate: Double, sent: UInt64, since: Date, progress: UploadProgress? = nil,
                method: UploadMethod, reason: String? = nil, hold: UploadHold? = nil) {
        self.key = key; self.name = name; self.apps = apps; self.bundlePath = bundlePath; self.rate = rate; self.sent = sent; self.since = since
        self.progress = progress; self.method = method; self.reason = reason; self.hold = hold
    }
}

/// Finds apps that keep uploading a lot. Fed each app's Internet bytes sent since the last sample.
public struct UploadTracker: Sendable {
    public struct Reading: Sendable {
        public let key: String
        public let name: String
        public let bytes: UInt64
        public init(key: String, name: String, bytes: UInt64) { self.key = key; self.name = name; self.bytes = bytes }
    }
    public struct Live: Equatable, Sendable {
        public let key: String
        public let name: String
        public let rate: Double
        public let sent: UInt64
        public let since: Date
    }
    struct Entry: Sendable {
        var name: String
        var samples: [(at: Date, bytes: UInt64, seconds: TimeInterval)] = []
        var start: Date?
        var lastAbove: Date?
        var sent: UInt64 = 0
    }
    var entries: [String: Entry] = [:]
    public init() {}

    /// The big uploads after this sample, `elapsed` seconds after the last one. Apps missing from `readings` sent nothing.
    public mutating func observe(_ readings: [Reading], elapsed: TimeInterval, threshold: Double, now: Date = Date()) -> [Live] {
        var bytes: [String: UInt64] = [:]
        for reading in readings {
            bytes[reading.key, default: 0] += reading.bytes
            if entries[reading.key] == nil { entries[reading.key] = Entry(name: reading.name) }
        }
        var live: [Live] = []
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            let sample = bytes[key] ?? 0
            entry.samples.append((now, sample, elapsed))
            entry.samples.removeAll { now.timeIntervalSince($0.at) >= SendLater.window }
            let seconds = entry.samples.reduce(0) { $0 + $1.seconds }
            let rate = seconds > 0 ? Double(entry.samples.reduce(0) { $0 + $1.bytes }) / seconds : 0
            if rate >= threshold {
                if entry.start == nil { entry.start = now.addingTimeInterval(-elapsed); entry.sent = entry.samples.reduce(0) { $0 + $1.bytes } }
                else { entry.sent += sample }
                entry.lastAbove = now
            } else if let last = entry.lastAbove, entry.start != nil {
                if now.timeIntervalSince(last) >= SendLater.quiet { entry.start = nil; entry.lastAbove = nil; entry.sent = 0 } else { entry.sent += sample }
            }
            if entry.start == nil, rate == 0 { entries[key] = nil; continue }
            entries[key] = entry
            if let start = entry.start, let last = entry.lastAbove, last.timeIntervalSince(start) >= SendLater.sustain {
                live.append(Live(key: key, name: entry.name, rate: rate, sent: entry.sent, since: start))
            }
        }
        return live.sorted { $0.rate == $1.rate ? $0.key < $1.key : $0.rate > $1.rate }
    }

    /// Forgets an upload, such as one just held, so it starts over when it goes again.
    public mutating func forget(_ key: String) { entries[key] = nil }
}

/// What `kilobat uploads --json` and the MCP tool return.
public struct UploadsReport: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let app: String
        public let name: String
        public let ids: [String]
        /// uploading or held.
        public let state: String
        public let bytesPerSecond: Double
        public let sentBytes: UInt64
        public let since: Date
        public let totalBytes: UInt64?
        public let doneBytes: UInt64?
        public let file: String?
        public let etaSeconds: Double?
        public let method: UploadMethod
        public let reason: String?
        public let until: UploadCondition?
        public let heldOn: String?
        public let resumesBy: Date?
    }
    public var appRunning: Bool
    public var network: String?
    public var metered: Bool?
    /// The newest speed test's upload on this network.
    public var uplinkMbps: Double?
    public var thresholdBytesPerSecond: Double
    public var filterActive: Bool?
    public var pro: Bool?
    public var uploads: [Entry]
    public var limits: String

    public static let limits = String(localized: "Totals and time left are known only for curl sending one file, from the file’s size; Dropbox, Google Drive, OneDrive, iCloud, git push and browsers show the rate and what they sent so far. Sync and backup apps are suspended; other apps only have new connections refused by the filter, so a transfer already running can finish. Browsers, macOS services, command-line tools and the app in front are never paused. Holds end after 8 hours at most, and when Kilobat quits.", comment: "Send later: what it can and can't do, in kilobat uploads")

    public static func entry(_ upload: BigUpload) -> Entry {
        Entry(app: upload.key, name: upload.name, ids: upload.apps, state: upload.hold == nil ? "uploading" : "held", bytesPerSecond: upload.rate.rounded(),
              sentBytes: upload.sent, since: upload.since, totalBytes: upload.progress?.total, doneBytes: upload.progress?.done, file: upload.progress?.file,
              etaSeconds: upload.eta.map { $0.rounded() }, method: upload.method, reason: upload.reason, until: upload.hold?.condition,
              heldOn: upload.hold?.network, resumesBy: upload.hold?.deadline)
    }

    public init(appRunning: Bool, network: String? = nil, metered: Bool? = nil, uplinkMbps: Double? = nil, thresholdBytesPerSecond: Double,
                filterActive: Bool? = nil, pro: Bool? = nil, uploads: [Entry], limits: String = UploadsReport.limits) {
        self.appRunning = appRunning; self.network = network; self.metered = metered; self.uplinkMbps = uplinkMbps
        self.thresholdBytesPerSecond = thresholdBytesPerSecond; self.filterActive = filterActive; self.pro = pro; self.uploads = uploads; self.limits = limits
    }
}

/// `kilobat uploads`, `uploads hold <app> [--until …]` and `uploads resume <app>`, each with `--json`.
public enum UploadsCommand: Equatable, Sendable {
    case list
    case hold(app: String, until: String?)
    case resume(app: String)

    public static let usage = "Use uploads [--json], uploads hold <app> [--until unmetered|fast|fast:<Mbps>|<duration>|manual], or uploads resume <app>."

    /// Parses the arguments after `uploads`; `--until` is checked here, so a typo never reaches the app.
    public static func parse(_ arguments: [String]) throws -> (command: UploadsCommand, json: Bool) {
        var rest = arguments.filter { $0 != "--json" }, until: String?
        let json = rest.count != arguments.count
        if let index = rest.firstIndex(of: "--until") {
            guard index + 1 < rest.count else { throw UploadError(usage) }
            until = rest[index + 1]; rest.removeSubrange(index...index + 1)
            _ = try UploadCondition.parse(until)
        }
        switch rest.first {
        case nil where until == nil: return (.list, json)
        case "hold" where rest.count == 2: return (.hold(app: rest[1], until: until), json)
        case "resume" where rest.count == 2 && until == nil: return (.resume(app: rest[1]), json)
        default: throw UploadError(usage)
        }
    }
}
