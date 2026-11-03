import Foundation

/// A prepaid data pack, such as a travel eSIM: so many gigabytes for so many days from a start date, on the networks
/// that reach the Mac through it (the phone's hotspot, a travel router's Wi-Fi). Unlike a budget it doesn't start
/// over: it ends. Kilobat counts only this Mac, so the forecast says so, and a correction re-syncs it with the
/// figure in the carrier's app. Several packs can be kept over time; on each network the newest one that has started counts.
public struct DataPack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// What the person calls it, such as “Japan eSIM”.
    public var name: String
    public var bytes: UInt64
    public var start: Date
    /// When the carrier ends it, used up or not.
    public var end: Date
    public var networks: DataPackNetworks
    /// The figure from the carrier's app, set by hand; nil until corrected.
    public var correction: DataPackCorrection?
    /// Ended by hand, or by a newer pack on the same networks, before `end`.
    public var ended: Date?
    /// Percentages that notify once; nil means 50, 80 and 95.
    public var alerts: [Int]?
    /// While on this pack, Send later holds big uploads until an unmetered network.
    public var holdUploads: Bool?

    public static let defaultAlerts = [50, 80, 95]
    public static let maximumBytes: UInt64 = 10_000_000_000_000
    public static let maximumDays = 400

    public init(id: UUID = UUID(), name: String, bytes: UInt64, start: Date, end: Date, networks: DataPackNetworks, correction: DataPackCorrection? = nil,
                ended: Date? = nil, alerts: [Int]? = nil, holdUploads: Bool? = nil) {
        self.id = id; self.name = name; self.bytes = bytes; self.start = start; self.end = end; self.networks = networks
        self.correction = correction; self.ended = ended; self.alerts = alerts; self.holdUploads = holdUploads
    }

    /// A pack of `gb` gigabytes valid for `days` days from `start`, or until `until`. Days follow the calendar, so a
    /// clock change can't move the end off the hour it started.
    public static func make(name: String? = nil, gb: Double, days: Int? = nil, until: Date? = nil, start: Date, networks: DataPackNetworks,
                            calendar: Calendar = .current) throws -> DataPack {
        guard gb.isFinite, gb >= 0.01, gb * 1_000_000_000 <= Double(maximumBytes) else {
            throw DataPackError(String(localized: "A data pack is between 0.01 and 10000 GB.", comment: "Data pack: the size is out of range"))
        }
        let end: Date
        if let until {
            end = until
        } else if let days, (1...maximumDays).contains(days), let date = calendar.date(byAdding: .day, value: days, to: start) {
            end = date
        } else {
            throw DataPackError(String(localized: "A data pack lasts 1 to 400 days.", comment: "Data pack: the validity is out of range"))
        }
        guard end > start, end.timeIntervalSince(start) <= Double(maximumDays) * 86_400 + 3_600 else {
            throw DataPackError(String(localized: "A data pack ends after it starts, and within 400 days.", comment: "Data pack: the end date is out of range"))
        }
        guard !networks.isEmpty else {
            throw DataPackError(String(localized: "Choose the networks that use the pack: a hotspot, a travel router, or names that contain some text.", comment: "Data pack: no network chosen"))
        }
        let size = (gb * 1_000_000_000).rounded()
        let label = filled(name)
            ?? String(localized: "\(gb.formatted(.number.precision(.fractionLength(0...2)))) GB pack", comment: "Data pack: the default name, such as “10 GB pack”")
        return DataPack(name: label, bytes: UInt64(size), start: start, end: end, networks: networks)
    }

    public var thresholds: [Int] { Array(Set((alerts ?? Self.defaultAlerts).filter { (1...100).contains($0) })).sorted() }
    /// When it stops counting: its end, or earlier if it was ended.
    public var finish: Date { min(end, ended ?? end) }
    /// Whole days from start to end, as the carrier sold it.
    public func days(calendar: Calendar = .current) -> Int {
        max(1, calendar.dateComponents([.day], from: start, to: end).day ?? Int((end.timeIntervalSince(start) / 86_400).rounded()))
    }
    public func active(at now: Date) -> Bool { start <= now && now < finish }
    /// Bytes count from the start of the hour it started in: history keeps older traffic in hourly buckets, and
    /// counting from the bucket keeps a pack's figure from dropping when its first hour is merged.
    public func countsFrom(calendar: Calendar = .current) -> Date { calendar.dateInterval(of: .hour, for: start)?.start ?? start }
    func counts(at date: Date, calendar: Calendar = .current) -> Bool { date >= countsFrom(calendar: calendar) && date < finish }
}

/// What the carrier's app said was left, and what this Mac had counted on the pack at that moment, so the Mac's
/// use from then on is added to the carrier's figure.
public struct DataPackCorrection: Codable, Equatable, Sendable {
    public var at: Date
    public var leftBytes: UInt64
    public var macBytes: UInt64
    var after: Date { Date(timeIntervalSinceReferenceDate: at.timeIntervalSinceReferenceDate.nextUp) }
    public init(at: Date, leftBytes: UInt64, macBytes: UInt64) { self.at = at; self.leftBytes = leftBytes; self.macBytes = macBytes }
}

/// The networks a pack counts: ones picked by their key (a phone's hotspot, a travel router), and any network whose
/// name contains some text, such as “iPhone” for each of that phone's hotspots and its USB tethering.
public struct DataPackNetworks: Codable, Equatable, Sendable {
    /// Network keys, each with its name when it was picked.
    public var keys: [String: String]
    public var nameContains: String?
    public init(keys: [String: String] = [:], nameContains: String? = nil) {
        self.keys = keys.filter { $0.key != "unknown" }
        self.nameContains = filled(nameContains)
    }
    public var isEmpty: Bool { keys.isEmpty && nameContains == nil }

    /// Whether a network counts. Case and accents don't matter for the name.
    public func matches(key: String, name: String?) -> Bool {
        guard key != "unknown" else { return false }
        if keys[key] != nil { return true }
        guard let text = nameContains, let name else { return false }
        return name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Whether some network would count for both: a key both pick, a known network both match, or name texts where one contains the other.
    public func overlaps(_ other: DataPackNetworks, known: [String: String] = [:]) -> Bool {
        if !Set(keys.keys).isDisjoint(with: other.keys.keys) { return true }
        let names = known.merging(keys) { first, _ in first }.merging(other.keys) { first, _ in first }
        if names.contains(where: { matches(key: $0.key, name: $0.value) && other.matches(key: $0.key, name: $0.value) }) { return true }
        if let mine = nameContains, let theirs = other.nameContains {
            return mine.range(of: theirs, options: [.caseInsensitive, .diacriticInsensitive]) != nil || theirs.range(of: mine, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return false
    }

    /// “iPhone, Travel router · names with “Pixel””.
    public var summary: String {
        var parts = keys.values.sorted()
        if let text = nameContains { parts.append(String(localized: "names with “\(text)”", comment: "Data pack networks: any network whose name contains this text")) }
        return parts.joined(separator: ", ")
    }
}

public struct DataPackError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Where a pack stands and when, at the recent pace, it runs out.
public struct DataPackStatus: Equatable, Sendable {
    public enum State: String, Codable, Sendable { case upcoming, active, usedUp, expired, ended }
    public let pack: DataPack
    /// Used, by this Mac's count, or from the carrier's figure when corrected.
    public let used: UInt64
    /// What this Mac used on the pack since it started.
    public let macBytes: UInt64
    public let left: UInt64
    public let state: State
    /// Bytes a day at the recent pace; nil when the pack isn't running.
    public let perDay: Double?
    /// The days the pace is measured over: the last three, or since the pack started.
    public let paceDays: Double
    /// When it runs out at that pace, if before the pack ends.
    public let runsOut: Date?
    /// Whole days between running out and the pack's end.
    public let daysEarly: Int?
    public let now: Date

    public var fraction: Double { pack.bytes == 0 ? 1 : min(1, Double(used) / Double(pack.bytes)) }
    public var early: Bool { runsOut != nil }
    /// Less than a day to go on, so the pace counts as at least a day and may be low.
    public var settling: Bool { state == .active && paceDays < 1 }
    public var lastsWholePack: Bool { state == .active && runsOut == nil && (perDay ?? 0) > 0 }

    /// “6.2 GB left”.
    public var leftPhrase: String { String(localized: "\(TrafficFormat.bytes(left)) left", comment: "Data pack: what's left, such as “6.2 GB left”") }

    /// “runs out around 14 Nov, 5 days before the pack ends”, “at this pace it lasts the whole pack · ends 19 Nov”, or nil
    /// when there's nothing to forecast. Written to follow “·”; `sentenceStart` capitalizes it to stand alone.
    public func forecast(calendar: Calendar = .current) -> String? {
        let ends = pack.end.formatted(.dateTime.day().month())
        switch state {
        case .upcoming: return String(localized: "starts \(pack.start.formatted(.dateTime.day().month()))", comment: "Data pack: it hasn't started yet; follows “10 GB left ·”")
        case .usedUp: return String(localized: "used up by this Mac’s count · ends \(ends)", comment: "Data pack: nothing left; follows “0 B left ·”")
        case .expired, .ended: return nil
        case .active: break
        }
        guard let runsOut, let daysEarly else {
            return (perDay ?? 0) > 0 ? String(localized: "at this pace it lasts the whole pack · ends \(ends)", comment: "Data pack forecast; follows “6.2 GB left ·”")
                : String(localized: "no use on it in the last few days · ends \(ends)", comment: "Data pack forecast with no pace to go on; follows “6.2 GB left ·”")
        }
        let date = runsOut.formatted(.dateTime.day().month())
        switch daysEarly {
        case 0: return String(localized: "runs out around \(date), the day the pack ends", comment: "Data pack forecast; follows “6.2 GB left ·”")
        case 1: return String(localized: "runs out around \(date), a day before the pack ends", comment: "Data pack forecast; follows “6.2 GB left ·”")
        default: return String(localized: "runs out around \(date), \(daysEarly) days before the pack ends", comment: "Data pack forecast: a date, then a number of days; follows “6.2 GB left ·”")
        }
    }

    /// The one line for the menu, Health and the CLI: “6.2 GB left · runs out around 14 Nov, 5 days before the pack ends”.
    public func line(calendar: Calendar = .current) -> String {
        switch state {
        case .expired, .ended:
            return String(localized: "Ended \(pack.finish.formatted(.dateTime.day().month())) · \(TrafficFormat.bytes(used)) of \(TrafficFormat.bytes(pack.bytes)) used", comment: "Data pack history line")
        case .upcoming: return (forecast(calendar: calendar) ?? "").sentenceStart
        case .active, .usedUp:
            guard let forecast = forecast(calendar: calendar) else { return leftPhrase }
            return leftPhrase + " · " + forecast
        }
    }

    /// What Kilobat can't see, for a tooltip or the CLI.
    public static let limits = String(localized: "Kilobat counts this Mac only. If your phone or another device uses the same pack, less is left than it says. Correct it with the figure in your carrier’s app.", comment: "Data pack: what the count leaves out")
}

/// The packs together: which one counts on a network, what each has used, its pace and forecast.
public enum DataPacks {
    /// Days of history the pace is measured over.
    public static let paceDays = 3.0

    /// The pack that counts on a network at `date`: of the packs that match it and are running then, the one that started last.
    public static func owner(of key: String, name: String?, at date: Date, in packs: [DataPack], calendar: Calendar = .current) -> DataPack? {
        packs.filter { $0.active(at: date) && $0.networks.matches(key: key, name: name) }.max { $0.start < $1.start }
    }

    /// What this Mac used on `pack` from `from` (by default its start) to `to`: each usage entry counts for the one pack
    /// that owned its network then, so overlapping packs never count a byte twice. `pending` is traffic not saved yet.
    public static func macBytes(_ pack: DataPack, packs: [DataPack], usage: [UsageEntry], names: (String) -> String?, pending: (key: String, bytes: UInt64)? = nil,
                                from: Date? = nil, to: Date, calendar: Calendar = .current) -> UInt64 {
        let lower = max(from ?? .distantPast, pack.countsFrom(calendar: calendar)), upper = min(to, pack.finish)
        guard upper > lower else { return 0 }
        // Per network, the packs that could own it and when each counts; usually only this one.
        var rivals: [String: [(start: Date, from: Date, finish: Date, mine: Bool)]] = [:]
        func owns(_ key: String, _ date: Date) -> Bool {
            if rivals[key] == nil {
                let name = names(key)
                rivals[key] = packs.filter { $0.networks.matches(key: key, name: name) }.map { ($0.start, $0.countsFrom(calendar: calendar), $0.finish, $0.id == pack.id) }
            }
            return rivals[key]?.filter { date >= $0.from && date < $0.finish }.max { $0.start < $1.start }?.mine == true
        }
        var total = usage.reduce(UInt64(0)) { total, entry in
            guard entry.date >= lower, entry.date < upper, let key = entry.networkKey, key != "unknown", owns(key, entry.date) else { return total }
            return total + entry.total
        }
        if let pending, pending.bytes > 0, to <= pack.finish, to >= lower, owns(pending.key, to) { total += pending.bytes }
        return total
    }

    /// The pack's status at `now`, at the pace of the last three days (or since it started, counted as at least a day).
    public static func status(_ pack: DataPack, packs: [DataPack], usage: [UsageEntry], names: (String) -> String?, pending: (key: String, bytes: UInt64)? = nil,
                              now: Date = Date(), calendar: Calendar = .current) -> DataPackStatus {
        let mac = macBytes(pack, packs: packs, usage: usage, names: names, pending: pending, to: now, calendar: calendar)
        let used: UInt64
        if let correction = pack.correction {
            let since = macBytes(pack, packs: packs, usage: usage, names: names, pending: pending,
                                 from: correction.after, to: now, calendar: calendar)
            used = pack.bytes - min(pack.bytes, correction.leftBytes - min(correction.leftBytes, since))
        } else {
            used = min(pack.bytes, mac)
        }
        let left = pack.bytes - used
        let state: DataPackStatus.State
        if now < pack.start { state = .upcoming }
        else if now >= pack.finish { state = pack.ended.map { $0 < pack.end } == true ? .ended : .expired }
        else if left == 0 { state = .usedUp }
        else { state = .active }
        guard state == .active else {
            return DataPackStatus(pack: pack, used: used, macBytes: mac, left: left, state: state, perDay: nil, paceDays: 0, runsOut: nil, daysEarly: nil, now: now)
        }
        let windowStart = max(now.addingTimeInterval(-paceDays * 86_400), pack.start)
        let measured = now.timeIntervalSince(windowStart) / 86_400
        // Since the start, the pace counts what the pack counts, its first hour too.
        let recent = macBytes(pack, packs: packs, usage: usage, names: names, pending: pending, from: windowStart == pack.start ? nil : windowStart, to: now, calendar: calendar)
        let perDay = Double(recent) / max(1, measured)
        var runsOut: Date?, daysEarly: Int?
        if perDay > 0 {
            let date = now.addingTimeInterval(Double(left) / perDay * 86_400)
            if date < pack.end {
                runsOut = date
                daysEarly = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: pack.end)).day ?? 0)
            }
        }
        return DataPackStatus(pack: pack, used: used, macBytes: mac, left: left, state: state, perDay: perDay, paceDays: measured, runsOut: runsOut, daysEarly: daysEarly, now: now)
    }

    /// Adds `pack` so each network has one pack at a time: a pack still running on the same networks when it starts
    /// ends then, one that starts later stays and ends this one when it starts, and one that starts at the same moment
    /// is replaced. Returns the packs it ended or replaced.
    @discardableResult public static func add(_ pack: DataPack, to packs: inout [DataPack], known: [String: String] = [:]) -> [DataPack] {
        var pack = pack, ended: [DataPack] = []
        for other in packs where other.id != pack.id && other.networks.overlaps(pack.networks, known: known) {
            if other.start == pack.start {
                ended.append(other); packs.removeAll { $0.id == other.id }
            } else if other.start < pack.start {
                guard other.finish > pack.start, let index = packs.firstIndex(where: { $0.id == other.id }) else { continue }
                packs[index].ended = pack.start
                ended.append(packs[index])
            } else if other.start < pack.finish {
                pack.ended = other.start
            }
        }
        packs.removeAll { $0.id == pack.id }
        packs.append(pack)
        packs.sort { $0.start < $1.start }
        return ended
    }

    /// Keeps a year of finished packs.
    public static func pruned(_ packs: [DataPack], now: Date = Date()) -> [DataPack] {
        packs.filter { now.timeIntervalSince($0.finish) < 366 * 86_400 }
    }

    /// Sets what the carrier says is left, keeping what this Mac counted until now so its use from here is added.
    public static func correct(_ pack: inout DataPack, leftBytes: UInt64, macBytes: UInt64, now: Date = Date()) throws {
        guard leftBytes <= pack.bytes else {
            throw DataPackError(String(localized: "That’s more than the pack holds (\(TrafficFormat.bytes(pack.bytes))).", comment: "Data pack: a correction above the pack's size"))
        }
        pack.correction = DataPackCorrection(at: now, leftBytes: leftBytes, macBytes: macBytes)
    }

    /// The pack to act on when none is named: the one counting on the current network, or else the only one running.
    public static func current(_ packs: [DataPack], network: String?, name: String?, now: Date = Date()) -> DataPack? {
        if let network, let owner = owner(of: network, name: name, at: now, in: packs) { return owner }
        let running = packs.filter { $0.active(at: now) }
        return running.count == 1 ? running[0] : nil
    }

    /// A pack by its name or the start of its ID, as the CLI takes it.
    public static func find(_ text: String, in packs: [DataPack]) -> DataPack? {
        let wanted = text.lowercased()
        return packs.last { $0.name.lowercased() == wanted } ?? packs.last { wanted.count >= 4 && $0.id.uuidString.lowercased().hasPrefix(wanted) }
    }
}

/// Notifications for a pack: as it reaches 50, 80 and 95%, and when the pace says it runs out early, at most once a
/// day and only again when the forecast moves at least a day earlier. Remembered in the budget alerts' ledger.
public struct DataPackAlert: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case threshold(Int), early }
    public let pack: UUID
    public let kind: Kind
    public let title: String
    public let body: String
    /// Offer to hold big uploads: the pack runs short and they aren't held already.
    public let offerHold: Bool

    public static let earlyInterval: TimeInterval = 86_400

    public static func due(_ statuses: [DataPackStatus], ledger: inout AlertLedger, now: Date = Date(), calendar: Calendar = .current) -> [DataPackAlert] {
        var alerts: [DataPackAlert] = []
        for status in statuses where status.state == .active || status.state == .usedUp {
            let pack = status.pack, id = pack.id.uuidString
            let key = "pack|\(id)|\(Int(pack.start.timeIntervalSince1970))"
            let crossed = ledger.crossed(pack.thresholds, fraction: status.fraction, key: key, now: now)
            // A correction is the carrier's own figure, which the person just read: thresholds it passes don't notify.
            let synced = "packsync|\(id)"
            if let correction = pack.correction, correction.at > (ledger.seen[synced] ?? .distantPast) {
                ledger.seen[synced] = correction.at
                if correction.at > now.addingTimeInterval(-120) { continue }
            }
            let offer = pack.holdUploads != true
            let forecast = status.forecast(calendar: calendar)
            let earlyKey = "packearly|\(id)", earlyDate = "packearlyat|\(id)"
            let earlyDue: Bool = {
                guard let runsOut = status.runsOut, (status.daysEarly ?? 0) >= 1 else { return false }
                if let last = ledger.seen[earlyKey], now.timeIntervalSince(last) < earlyInterval { return false }
                if let previous = ledger.seen[earlyDate], runsOut > previous.addingTimeInterval(-86_400) { return false }
                return true
            }()
            let left = String(localized: "\(TrafficFormat.bytes(status.left)) left by this Mac’s count.", comment: "Data pack alert, such as “2 GB left by this Mac’s count.”")
            if let threshold = crossed.max() {
                let body = left + (forecast.map { " " + $0.sentenceStart + "." } ?? "")
                alerts.append(DataPackAlert(pack: pack.id, kind: .threshold(threshold), title: String(localized: "\(threshold)% of \(pack.name) used", comment: "Data pack alert title"),
                                            body: body, offerHold: offer && status.early))
                if status.early, let runsOut = status.runsOut { ledger.seen[earlyKey] = now; ledger.seen[earlyDate] = runsOut }
            } else if earlyDue, let runsOut = status.runsOut, let forecast {
                ledger.seen[earlyKey] = now; ledger.seen[earlyDate] = runsOut
                alerts.append(DataPackAlert(pack: pack.id, kind: .early, title: String(localized: "\(pack.name) may run out early", comment: "Data pack alert title"),
                                            body: forecast.sentenceStart + ". " + left, offerHold: offer))
            }
        }
        return alerts
    }
}

/// `kilobat pack`, `pack add <GB> <days|YYYY-MM-DD> [--network <name>]… [--name <label>] [--start <YYYY-MM-DD>]`,
/// `pack correct <GB-left> [--pack <name>]` and `pack end [--pack <name>]`, each with `--json`.
public enum PackCommand: Equatable, Sendable {
    public enum Validity: Equatable, Sendable { case days(Int), until(Date) }
    case status
    case add(gb: Double, validity: Validity, networks: [String], name: String?, start: Date?)
    case correct(leftGB: Double, pack: String?)
    case end(pack: String?)

    public static let usage = "Use pack [status], pack add <GB> <days|YYYY-MM-DD> [--network <name>] [--name <label>] [--start <YYYY-MM-DD>], pack correct <GB-left> [--pack <name>] or pack end [--pack <name>], each with --json."

    public static func parse(_ arguments: [String], calendar: Calendar = .current) throws -> (command: PackCommand, json: Bool) {
        var rest = arguments.filter { $0 != "--json" }
        let json = rest.count != arguments.count
        var options: [String: [String]] = [:]
        for flag in ["--network", "--name", "--start", "--pack"] {
            while let index = rest.firstIndex(of: flag) {
                guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else { throw DataPackError("\(flag) needs a value. " + usage) }
                options[flag, default: []].append(rest[index + 1]); rest.removeSubrange(index...index + 1)
            }
        }
        if let flag = rest.first(where: { $0.hasPrefix("--") }) { throw DataPackError("Unexpected '\(flag)'. " + usage) }
        func only(_ allowed: Set<String>) throws {
            if let extra = options.keys.first(where: { !allowed.contains($0) }) { throw DataPackError("\(extra) doesn't go with pack \(rest.first ?? "status"). " + usage) }
            if let repeated = options.first(where: { $0.key != "--network" && $0.value.count > 1 }) { throw DataPackError("Pass \(repeated.key) once.") }
        }
        func gigabytes(_ text: String) throws -> Double {
            let value = text.lowercased().replacingOccurrences(of: "gb", with: "").trimmingCharacters(in: .whitespaces)
            guard let gb = Double(value), gb.isFinite, gb >= 0 else { throw DataPackError("'\(text)' isn't an amount in GB, such as 10 or 2.5.") }
            return gb
        }
        switch rest.first {
        case nil, "status":
            guard rest.count <= 1 else { throw DataPackError(usage) }
            try only([])
            return (.status, json)
        case "add":
            try only(["--network", "--name", "--start"])
            guard rest.count == 3 else { throw DataPackError("Use pack add <GB> <days|YYYY-MM-DD>, such as pack add 10 30.") }
            let gb = try gigabytes(rest[1])
            guard gb >= 0.01, gb <= 10_000 else { throw DataPackError("A data pack is between 0.01 and 10000 GB.") }
            let validity: Validity
            if let days = Int(rest[2].lowercased().replacingOccurrences(of: "d", with: "")) {
                guard (1...DataPack.maximumDays).contains(days) else { throw DataPackError("A data pack lasts 1 to \(DataPack.maximumDays) days.") }
                validity = .days(days)
            } else if let date = day(rest[2], calendar: calendar) {
                validity = .until(date)
            } else { throw DataPackError("'\(rest[2])' isn't a number of days or a date such as 2026-11-30.") }
            var start: Date?
            if let text = options["--start"]?.first {
                guard let date = day(text, calendar: calendar) else { throw DataPackError("--start takes a date such as 2026-11-02.") }
                start = date
            }
            let networks = (options["--network"] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            guard networks.allSatisfy({ !$0.isEmpty }) else { throw DataPackError("--network takes a network's name, or text its name contains.") }
            return (.add(gb: gb, validity: validity, networks: networks, name: options["--name"]?.first, start: start), json)
        case "correct":
            try only(["--pack"])
            guard rest.count == 2 else { throw DataPackError("Use pack correct <GB-left>, with what your carrier’s app says is left.") }
            return (.correct(leftGB: try gigabytes(rest[1]), pack: options["--pack"]?.first), json)
        case "end":
            try only(["--pack"])
            guard rest.count == 1 else { throw DataPackError("Use pack end [--pack <name>].") }
            return (.end(pack: options["--pack"]?.first), json)
        default: throw DataPackError(usage)
        }
    }

    /// `2026-11-30` as the start of that day.
    static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.split(separator: "-").count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        return date.flatMap { calendar.component(.day, from: $0) == parts[2] ? $0 : nil }
    }
}

/// Text with its spaces trimmed, or nil when nothing is left.
private func filled(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
}

public extension String {
    /// The first letter in capitals, for a phrase that starts a sentence. Phrases are written to follow “·”, where
    /// they start in lower case; capitalizing is right in every language, lowering a first letter is not.
    var sentenceStart: String { prefix(1).uppercased() + dropFirst() }
}
