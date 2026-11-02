import Foundation
import Testing
@testable import KilobatCore

struct DataPackTests {
    /// Lisbon changes clocks on 25 October 2026, inside the packs below.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }()
    static func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    static let gb: UInt64 = 1_000_000_000
    static let hotspot = DataPackNetworks(keys: ["phone": "Sam’s iPhone"])
    static let names: [String: String] = ["phone": "Sam’s iPhone", "router": "GL-MT3000", "hotel": "Hotel Guest", "usb": "iPhone USB"]
    static func name(_ key: String) -> String? { names[key] }
    static func entry(_ date: Date, _ bytes: UInt64, on network: String = "phone") -> UsageEntry {
        UsageEntry(date: date, received: bytes * 3 / 4, sent: bytes - bytes * 3 / 4, apps: ["Safari": bytes], networkKey: network)
    }
    static func pack(_ gb: Double = 10, days: Int = 30, start: Date = date(11, 1, 9), networks: DataPackNetworks = hotspot, name: String = "Japan eSIM") throws -> DataPack {
        try DataPack.make(name: name, gb: gb, days: days, start: start, networks: networks, calendar: calendar)
    }
    static func status(_ pack: DataPack, _ usage: [UsageEntry], packs: [DataPack]? = nil, pending: (key: String, bytes: UInt64)? = nil, now: Date) -> DataPackStatus {
        DataPacks.status(pack, packs: packs ?? [pack], usage: usage, names: name, pending: pending, now: now, calendar: calendar)
    }

    // MARK: The pack and its end date

    @Test func validityInDaysFollowsTheCalendarAcrossTheClockChange() throws {
        let pack = try Self.pack(days: 30, start: Self.date(10, 10, 9))
        // 30 days later at the same time of day, although 25 October had 25 hours.
        #expect(pack.end == Self.date(11, 9, 9))
        #expect(pack.end.timeIntervalSince(pack.start) == 30 * 86_400 + 3_600)
        #expect(pack.days(calendar: Self.calendar) == 30)
        #expect(pack.bytes == 10 * Self.gb && pack.name == "Japan eSIM" && pack.thresholds == [50, 80, 95])
        let dated = try DataPack.make(gb: 5, until: Self.date(11, 20, 0), start: Self.date(11, 1, 9), networks: Self.hotspot, calendar: Self.calendar)
        #expect(dated.end == Self.date(11, 20, 0) && dated.name == "5 GB pack")
        #expect(throws: DataPackError.self) { try DataPack.make(gb: 0, days: 30, start: Date(), networks: Self.hotspot) }
        #expect(throws: DataPackError.self) { try DataPack.make(gb: 10, days: 0, start: Date(), networks: Self.hotspot) }
        #expect(throws: DataPackError.self) { try DataPack.make(gb: 10, until: Self.date(10, 1), start: Self.date(11, 1), networks: Self.hotspot) }
        #expect(throws: DataPackError.self) { try DataPack.make(gb: 10, days: 30, start: Date(), networks: DataPackNetworks()) }
    }

    // MARK: Which networks count

    @Test func networksMatchByKeyOrByTextInTheName() {
        let picked = DataPackNetworks(keys: ["router": "GL-MT3000"])
        #expect(picked.matches(key: "router", name: "anything"))
        #expect(!picked.matches(key: "hotel", name: "GL-MT3000 guest"))
        let phone = DataPackNetworks(nameContains: "  iphone ")
        #expect(phone.nameContains == "iphone")
        #expect(phone.matches(key: "phone", name: "Sam’s iPhone") && phone.matches(key: "usb", name: "iPhone USB"))
        #expect(!phone.matches(key: "hotel", name: "Hotel Guest") && !phone.matches(key: "phone", name: nil))
        #expect(DataPackNetworks(nameContains: "cafe").matches(key: "x", name: "Café Lisboa"))
        // Kilobat never counts traffic before it knows the network.
        #expect(!DataPackNetworks(keys: ["unknown": "Wi-Fi"], nameContains: "Wi").matches(key: "unknown", name: "Wi-Fi"))
        #expect(DataPackNetworks(keys: ["unknown": "Wi-Fi"]).isEmpty && DataPackNetworks(nameContains: " ").isEmpty)

        #expect(picked.overlaps(DataPackNetworks(keys: ["router": "GL-MT3000", "hotel": "Hotel Guest"])))
        #expect(phone.overlaps(DataPackNetworks(keys: ["usb": "iPhone USB"])))
        #expect(phone.overlaps(DataPackNetworks(nameContains: "Sam’s iPhone")))
        #expect(!phone.overlaps(picked, known: Self.names))
        #expect(DataPackNetworks(nameContains: "GL").overlaps(picked, known: Self.names))
        #expect(phone.summary == "names with “iphone”")
        #expect(DataPackNetworks(keys: ["router": "GL-MT3000", "phone": "Sam’s iPhone"], nameContains: "Pixel").summary == "GL-MT3000, Sam’s iPhone, names with “Pixel”")
    }

    // MARK: The forecast

    @Test func paceOfTheLastThreeDaysSaysWhenItRunsOut() throws {
        let pack = try Self.pack()   // 10 GB, 1 Nov 09:00 to 1 Dec 09:00
        let now = Self.date(11, 8, 12)
        // 3.8 GB in the first four days, then 1 GB a day: 600 MB is outside the three-day window, and the hotel Wi-Fi never counts.
        let usage = [Self.entry(Self.date(11, 2), 1_800_000_000), Self.entry(Self.date(11, 4), 2_000_000_000), Self.entry(Self.date(11, 5, 11), 600_000_000),
                     Self.entry(Self.date(11, 5, 13), 1 * Self.gb), Self.entry(Self.date(11, 6), 1 * Self.gb), Self.entry(Self.date(11, 7), 1 * Self.gb),
                     Self.entry(Self.date(11, 7, 20), 9 * Self.gb, on: "hotel")]
        let status = Self.status(pack, usage, now: now)
        #expect(status.state == .active)
        #expect(status.used == 7_400_000_000 && status.macBytes == 7_400_000_000 && status.left == 2_600_000_000)
        #expect(status.paceDays == 3 && status.perDay == 1_000_000_000)
        // 2.6 GB at 1 GB a day: 2.6 days from 8 Nov noon, 11 Nov, 20 days before the pack ends on 1 Dec.
        #expect(status.runsOut == now.addingTimeInterval(2.6 * 86_400))
        #expect(status.daysEarly == 20 && status.early && !status.lastsWholePack && !status.settling)
        let runsOut = now.addingTimeInterval(2.6 * 86_400).formatted(.dateTime.day().month()), ends = pack.end.formatted(.dateTime.day().month())
        #expect(status.forecast(calendar: Self.calendar) == "runs out around \(runsOut), 20 days before the pack ends")
        #expect(status.line(calendar: Self.calendar) == "2.6 GB left · runs out around \(runsOut), 20 days before the pack ends")
        #expect(abs(status.fraction - 0.74) < 0.0001)

        // At 100 MB a day it lasts.
        let light = Self.status(pack, [Self.entry(Self.date(11, 6), 300_000_000)], now: now)
        #expect(light.runsOut == nil && light.lastsWholePack && light.daysEarly == nil)
        #expect(light.line(calendar: Self.calendar) == "9.7 GB left · at this pace it lasts the whole pack · ends \(ends)")
        // No use lately: nothing to forecast from.
        let quiet = Self.status(pack, [], now: now)
        #expect(quiet.perDay == 0 && !quiet.lastsWholePack && quiet.forecast(calendar: Self.calendar) == "no use on it in the last few days · ends \(ends)")
    }

    @Test func runningOutOnTheLastDayOrTheDayBeforeReadsSo() throws {
        let pack = try Self.pack(2, days: 10)   // 1 Nov 09:00 to 11 Nov 09:00
        let now = Self.date(11, 8, 12)
        // 400 MB left at 400 MB a day: 9 Nov noon, two days before the end.
        let twoDays = Self.status(pack, [Self.entry(Self.date(11, 2), 400_000_000), Self.entry(Self.date(11, 6), 1_200_000_000)], now: now)
        #expect(twoDays.left == 400_000_000 && twoDays.perDay == 400_000_000 && twoDays.daysEarly == 2)
        #expect(twoDays.forecast(calendar: Self.calendar)?.hasSuffix(", 2 days before the pack ends") == true)
        // 600 MB left at 300 MB a day: 10 Nov noon, the day before.
        let dayBefore = Self.status(pack, [Self.entry(Self.date(11, 2), 500_000_000), Self.entry(Self.date(11, 6), 900_000_000)], now: now)
        #expect(dayBefore.left == 600_000_000 && dayBefore.daysEarly == 1)
        #expect(dayBefore.forecast(calendar: Self.calendar)?.hasSuffix(", a day before the pack ends") == true)
        // 150 MB left at 180 MB a day from 10 Nov 08:00: about 04:00 on 11 Nov, the morning it ends.
        let last = Self.status(pack, [Self.entry(Self.date(11, 2), 1_310_000_000), Self.entry(Self.date(11, 8), 540_000_000)], now: Self.date(11, 10, 8))
        #expect(last.left == 150_000_000 && last.daysEarly == 0)
        #expect(last.forecast(calendar: Self.calendar)?.hasSuffix(", the day the pack ends") == true)
    }

    @Test func aNewPackCountsItsPaceAsAtLeastADay() throws {
        let start = Self.date(11, 1, 9, 20)
        let pack = try Self.pack(10, days: 7, start: start)
        let now = Self.date(11, 1, 15, 20)
        // Six hours, 1.5 GB: the pace is 1.5 GB a day, not 6, and says it's early on.
        let status = Self.status(pack, [Self.entry(Self.date(11, 1, 9, 10), 500_000_000), Self.entry(Self.date(11, 1, 14), 1 * Self.gb)], now: now)
        #expect(status.settling && status.paceDays == 0.25)
        // The first hour counts from 09:00, so the 09:10 bytes, saved before the pack started, are its: history merges them into that hour.
        #expect(status.used == 1_500_000_000 && status.perDay == 1_500_000_000)
        #expect(status.runsOut == now.addingTimeInterval(8.5 / 1.5 * 86_400) && status.daysEarly == 1)
        // Before the start hour nothing counts, and pending bytes on the network do.
        let earlier = Self.status(pack, [Self.entry(Self.date(11, 1, 8, 59), 4 * Self.gb)], pending: ("phone", 250_000_000), now: now)
        #expect(earlier.used == 250_000_000)
        #expect(Self.status(pack, [], pending: ("hotel", 250_000_000), now: now).used == 0)
    }

    @Test func statesBeforeDuringAndAfter() throws {
        let pack = try Self.pack(2, days: 10)
        let starts = pack.start.formatted(.dateTime.day().month()), ends = pack.end.formatted(.dateTime.day().month())
        #expect(Self.status(pack, [], now: Self.date(10, 30)).state == .upcoming)
        #expect(Self.status(pack, [], now: Self.date(10, 30)).line(calendar: Self.calendar) == "Starts \(starts)")
        let full = Self.status(pack, [Self.entry(Self.date(11, 3), 3 * Self.gb)], now: Self.date(11, 4))
        #expect(full.state == .usedUp && full.used == 2 * Self.gb && full.left == 0 && full.fraction == 1)
        #expect(full.line(calendar: Self.calendar) == "0 B left · used up by this Mac’s count · ends \(ends)")
        let over = Self.status(pack, [Self.entry(Self.date(11, 3), 1 * Self.gb), Self.entry(Self.date(11, 12), 1 * Self.gb)], now: Self.date(11, 20))
        #expect(over.state == .expired && over.used == 1 * Self.gb && over.line(calendar: Self.calendar) == "Ended \(ends) · 1 GB of 2 GB used")
        var ended = pack; ended.ended = Self.date(11, 5)
        let early = Self.status(ended, [Self.entry(Self.date(11, 3), 1 * Self.gb), Self.entry(Self.date(11, 6), 1 * Self.gb)], now: Self.date(11, 6, 13))
        #expect(early.state == .ended && early.used == 1 * Self.gb && early.perDay == nil)
    }

    // MARK: Correcting

    @Test func correctionStartsFromTheCarriersFigureAndAddsTheMacsUseSince() throws {
        var pack = try Self.pack()
        var usage = [Self.entry(Self.date(11, 2), 2 * Self.gb)]
        // The carrier says 6 GB left: the phone used 2 GB the Mac never saw.
        let before = Self.status(pack, usage, now: Self.date(11, 3))
        try DataPacks.correct(&pack, leftBytes: 6 * Self.gb, macBytes: before.macBytes, now: Self.date(11, 3))
        #expect(Self.status(pack, usage, now: Self.date(11, 3)).left == 6 * Self.gb)
        usage.append(Self.entry(Self.date(11, 4), 1 * Self.gb))
        let after = Self.status(pack, usage, now: Self.date(11, 5))
        #expect(after.used == 5 * Self.gb && after.left == 5 * Self.gb && after.macBytes == 3 * Self.gb)
        // More left than the Mac counted is fine; more than the pack holds isn't.
        try DataPacks.correct(&pack, leftBytes: 9_500_000_000, macBytes: after.macBytes, now: Self.date(11, 5))
        #expect(Self.status(pack, usage, now: Self.date(11, 5)).left == 9_500_000_000)
        #expect(throws: DataPackError.self) { try DataPacks.correct(&pack, leftBytes: 11 * Self.gb, macBytes: 0) }
    }

    // MARK: Several packs

    @Test func aNewPackOnTheSameNetworksEndsTheOldOneAndBytesCountOnce() throws {
        let old = try Self.pack(5, days: 30, start: Self.date(10, 20, 9), name: "First")
        var packs = [old]
        let fresh = try Self.pack(10, days: 30, start: Self.date(11, 2, 9), networks: DataPackNetworks(nameContains: "iPhone"), name: "Second")
        let ended = DataPacks.add(fresh, to: &packs, known: Self.names)
        #expect(ended.map(\.name) == ["First"] && packs.map(\.name) == ["First", "Second"])
        #expect(packs[0].ended == fresh.start && packs[0].finish == fresh.start)
        let usage = [Self.entry(Self.date(10, 25), 1 * Self.gb), Self.entry(Self.date(11, 2, 8), 300_000_000), Self.entry(Self.date(11, 2, 9, 30), 400_000_000),
                     Self.entry(Self.date(11, 3), 500_000_000, on: "usb")]
        let first = Self.status(packs[0], usage, packs: packs, now: Self.date(11, 4)), second = Self.status(packs[1], usage, packs: packs, now: Self.date(11, 4))
        #expect(first.state == .ended && first.used == 1_300_000_000)
        #expect(second.used == 900_000_000)
        #expect(DataPacks.owner(of: "phone", name: "Sam’s iPhone", at: Self.date(11, 3), in: packs, calendar: Self.calendar)?.name == "Second")
        #expect(DataPacks.owner(of: "hotel", name: "Hotel Guest", at: Self.date(11, 3), in: packs, calendar: Self.calendar) == nil)

        // Another network keeps its own pack running alongside.
        let router = try Self.pack(20, days: 14, start: Self.date(11, 3, 9), networks: DataPackNetworks(keys: ["router": "GL-MT3000"]), name: "Router")
        #expect(DataPacks.add(router, to: &packs, known: Self.names).isEmpty && packs.count == 3)
        // A pack added for earlier stays in its slot: the later one keeps the network from its start.
        let backdated = try Self.pack(1, days: 30, start: Self.date(10, 28, 9), networks: DataPackNetworks(keys: ["router": "GL-MT3000"]), name: "Backdated")
        DataPacks.add(backdated, to: &packs, known: Self.names)
        #expect(packs.first { $0.name == "Backdated" }?.finish == router.start && packs.first { $0.name == "Router" }?.ended == nil)
        // The same start replaces it.
        let again = try Self.pack(25, days: 14, start: router.start, networks: DataPackNetworks(keys: ["router": "GL-MT3000"]), name: "Router again")
        #expect(DataPacks.add(again, to: &packs, known: Self.names).map(\.name) == ["Router"])
        #expect(!packs.contains { $0.name == "Router" } && packs.contains { $0.name == "Router again" })
        #expect(DataPacks.current(packs, network: "router", name: "GL-MT3000", now: Self.date(11, 5))?.name == "Router again")
        #expect(DataPacks.current(packs, network: "hotel", name: "Hotel Guest", now: Self.date(11, 5)) == nil)
        #expect(DataPacks.find("second", in: packs)?.name == "Second" && DataPacks.find(String(fresh.id.uuidString.prefix(6)), in: packs)?.name == "Second")
        #expect(DataPacks.pruned(packs, now: Self.date(11, 5).addingTimeInterval(400 * 86_400)).isEmpty)
    }

    // MARK: Alerts

    @Test func thresholdsNotifyOnceEachAndTheHighestOnly() throws {
        let pack = try Self.pack()
        var ledger = AlertLedger()
        func check(_ gb: Double, at now: Date) -> [DataPackAlert] {
            DataPackAlert.due([Self.status(pack, [Self.entry(Self.date(11, 1, 12), UInt64(gb * 1e9))], now: now)], ledger: &ledger, now: now, calendar: Self.calendar)
        }
        // Used early in the pack and checked in its third week, so the pace is quiet and only thresholds speak.
        #expect(check(4, at: Self.date(11, 20)).isEmpty)
        let half = check(5.5, at: Self.date(11, 20, 13))
        #expect(half.map(\.kind) == [.threshold(50)] && half[0].title == "50% of Japan eSIM used" && !half[0].offerHold)
        #expect(half[0].body.hasPrefix("4.5 GB left by this Mac’s count. No use on it in the last few days"))
        #expect(check(6, at: Self.date(11, 20, 14)).isEmpty)
        // 80 and 95 both crossed since: one notification, at 95.
        #expect(check(9.6, at: Self.date(11, 20, 15)).map(\.kind) == [.threshold(95)])
        #expect(check(9.7, at: Self.date(11, 20, 16)).isEmpty)
        // A correction upward re-arms them.
        #expect(check(4, at: Self.date(11, 20, 17)).isEmpty && check(5.5, at: Self.date(11, 20, 18)).map(\.kind) == [.threshold(50)])
    }

    @Test func runningOutEarlyNotifiesFromHistory() throws {
        let pack = try Self.pack(10, days: 30)
        var ledger = AlertLedger()
        // 1.2 GB a day from 1 Nov: 3.6 GB stays under 50%, and runs out weeks before 1 Dec.
        let usage = (1...3).map { Self.entry(Self.date(11, $0, 10), 1_200_000_000) }
        let now = Self.date(11, 3, 20), status = Self.status(pack, usage, now: now)
        let alerts = DataPackAlert.due([status], ledger: &ledger, now: now, calendar: Self.calendar)
        #expect(alerts.map(\.kind) == [.early] && alerts[0].title == "Japan eSIM may run out early" && alerts[0].offerHold)
        #expect(alerts[0].body == "Runs out around \(status.runsOut!.formatted(.dateTime.day().month())), \(status.daysEarly!) days before the pack ends. 6.4 GB left by this Mac’s count.")
    }

    @Test func runningOutEarlyNotifiesAtMostDailyAndOnlyWhenItGetsEarlier() throws {
        let pack = try Self.pack(10, days: 30)   // ends 1 Dec 09:00
        var ledger = AlertLedger()
        func early(_ runsOut: Date, at now: Date, holding: Bool = false) -> [DataPackAlert] {
            var held = pack; held.holdUploads = holding ? true : nil
            let days = Self.calendar.dateComponents([.day], from: Self.calendar.startOfDay(for: runsOut), to: Self.calendar.startOfDay(for: pack.end)).day!
            let status = DataPackStatus(pack: held, used: 3 * Self.gb, macBytes: 3 * Self.gb, left: 7 * Self.gb, state: .active, perDay: 1e9, paceDays: 3, runsOut: runsOut, daysEarly: days, now: now)
            return DataPackAlert.due([status], ledger: &ledger, now: now, calendar: Self.calendar)
        }
        let now = Self.date(11, 4, 12)
        #expect(early(Self.date(11, 11, 12), at: now).map(\.kind) == [.early])
        // Within the day, even a day sooner: quiet.
        #expect(early(Self.date(11, 10, 12), at: now.addingTimeInterval(3_600)).isEmpty)
        // A day later, no sooner than last time: quiet.
        #expect(early(Self.date(11, 11, 12), at: now.addingTimeInterval(25 * 3_600)).isEmpty)
        // At least a day sooner: once more; with uploads held already there's nothing to offer.
        let again = early(Self.date(11, 10, 6), at: now.addingTimeInterval(26 * 3_600), holding: true)
        #expect(again.map(\.kind) == [.early] && !again[0].offerHold)
        // Running out on the pack's last day isn't early enough to notify.
        var fresh = AlertLedger()
        let lastDay = DataPackStatus(pack: pack, used: 9 * Self.gb, macBytes: 9 * Self.gb, left: 1 * Self.gb, state: .active, perDay: 1e9, paceDays: 3,
                                     runsOut: Self.date(12, 1, 2), daysEarly: 0, now: Self.date(11, 30, 2))
        #expect(DataPackAlert.due([lastDay], ledger: &fresh, now: Self.date(11, 30, 2), calendar: Self.calendar).map(\.kind) == [.threshold(80)])
    }

    @Test func aCorrectionDoesNotNotifyWhatTheCarrierJustSaid() throws {
        var pack = try Self.pack()
        var ledger = AlertLedger()
        let usage = [Self.entry(Self.date(11, 2), 1 * Self.gb)]
        let now = Self.date(11, 20)
        #expect(DataPackAlert.due([Self.status(pack, usage, now: now)], ledger: &ledger, now: now, calendar: Self.calendar).isEmpty)
        // The carrier says 1.5 GB left: 85% used, past 50 and 80, which the person just read.
        try DataPacks.correct(&pack, leftBytes: 1_500_000_000, macBytes: 1 * Self.gb, now: now)
        let soon = now.addingTimeInterval(30)
        #expect(DataPackAlert.due([Self.status(pack, usage, now: soon)], ledger: &ledger, now: soon, calendar: Self.calendar).isEmpty)
        // Later use past the next threshold does notify.
        let more = usage + [Self.entry(Self.date(11, 20, 13), 1 * Self.gb)]
        let then = Self.date(11, 20, 14)
        #expect(DataPackAlert.due([Self.status(pack, more, now: then)], ledger: &ledger, now: then, calendar: Self.calendar).map(\.kind) == [.threshold(95)])
    }

    // MARK: Metered while on a pack

    @MainActor @Test func aPackNetworkIsMeteredUnlessMarkedUnmetered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kilobat-packs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TrafficStore(directory: folder, startMonitoring: false)
        store.networkKey = "phone"; store.networkName = "Sam’s iPhone"
        #expect(!store.metered && store.currentPack == nil)
        let pack = try DataPack.make(name: "Trip", gb: 10, days: 30, start: Date().addingTimeInterval(-3_600), networks: Self.hotspot)
        store.addPack(pack)
        #expect(store.currentPack?.id == pack.id && store.metered)
        store.preferences.setCost(.unmetered, for: "phone")
        #expect(!store.metered)
        store.preferences.setCost(.automatic, for: "phone")
        try store.correctPack(pack.id, leftBytes: 4 * Self.gb)
        #expect(store.packStatus(store.dataPacks[0]).left == 4 * Self.gb)
        store.endPack(pack.id)
        #expect(store.currentPack == nil && store.dataPacks.count == 1 && !store.metered)
        store.removePack(pack.id)
        #expect(store.preferences.dataPacks == nil)
        // Saved with the preferences, where the CLI writes them.
        store.addPack(pack)
        let reread = TrafficStore(directory: folder, startMonitoring: false)
        #expect(reread.dataPacks == [pack])
    }

    // MARK: The CLI's arguments

    @Test func packCommandsParse() throws {
        #expect(try PackCommand.parse([]) == (.status, false))
        #expect(try PackCommand.parse(["status", "--json"]) == (.status, true))
        let add = try PackCommand.parse(["add", "10", "30", "--network", "Sam’s iPhone", "--network", "GL-MT3000", "--name", "Japan", "--json"], calendar: Self.calendar)
        #expect(add.command == .add(gb: 10, validity: .days(30), networks: ["Sam’s iPhone", "GL-MT3000"], name: "Japan", start: nil) && add.json)
        #expect(try PackCommand.parse(["add", "2.5GB", "7d"]).command == .add(gb: 2.5, validity: .days(7), networks: [], name: nil, start: nil))
        let dated = try PackCommand.parse(["add", "5", "2026-11-30", "--start", "2026-11-02"], calendar: Self.calendar).command
        #expect(dated == .add(gb: 5, validity: .until(Self.date(11, 30, 0)), networks: [], name: nil, start: Self.date(11, 2, 0)))
        #expect(try PackCommand.parse(["correct", "6.2"]).command == .correct(leftGB: 6.2, pack: nil))
        #expect(try PackCommand.parse(["correct", "0", "--pack", "Japan"]).command == .correct(leftGB: 0, pack: "Japan"))
        #expect(try PackCommand.parse(["end", "--pack", "Japan", "--json"]) == (.end(pack: "Japan"), true))
        for bad in [["add", "10"], ["add", "ten", "30"], ["add", "10", "0"], ["add", "10", "401"], ["add", "0", "30"], ["add", "10", "2026-02-30"], ["add", "10", "30", "--network"],
                    ["add", "10", "30", "--pack", "x"], ["add", "10", "30", "--start", "soon"], ["correct"], ["correct", "-1"], ["end", "now"], ["status", "--name", "x"],
                    ["remove"], ["status", "--verbose"], ["add", "10", "30", "--name", "a", "--name", "b"]] {
            #expect(throws: DataPackError.self, "\(bad)") { try PackCommand.parse(bad, calendar: Self.calendar) }
        }
    }
}
