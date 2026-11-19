import Foundation
import Testing
@testable import KilobatCore

/// Profiles the person names and adds, weekly profile schedules, and the rules file.
struct ProfileEditingTests {
    let slack = "com.tinyspeck.slackmacgap"

    func sample() -> SavedPreferences {
        var preferences = SavedPreferences()
        preferences.rules = ["Work": [slack: true, "com.valvesoftware.steam": false], "Travel": ["com.apple.Music": false]]
        preferences.connectionRules = [ConnectionRule(app: slack, host: "a.example", allowed: false, profile: "Work"),
                                       ConnectionRule(app: slack, host: "b.example", allowed: true, profile: "Work", expires: Date().addingTimeInterval(600))]
        return preferences
    }

    @Test func aNewProfileCopiesSavedRulesButNotTimedOnes() throws {
        var preferences = sample()
        let school = try preferences.addProfile(named: "  School ", symbol: "house", copying: .work, id: "Custom-1")
        #expect(school.rawValue == "Custom-1")
        #expect(preferences.profileDefinitions == [ProfileDefinition(id: "Custom-1", name: "School", symbol: "house")])
        #expect(preferences.rules["Custom-1"] == preferences.rules["Work"])
        #expect(preferences.connectionRules?.filter { $0.profile == "Custom-1" }.map(\.host) == ["a.example"])
        #expect(preferences.definedProfiles.map(\.rawValue) == ["Travel", "Work", "Unrestricted", "Custom-1"])
        #expect(preferences.title(of: "Custom-1") == "School")
        #expect(preferences.knownProfile("Custom-1") == school && preferences.knownProfile("Custom-2") == nil)
    }

    @Test func namesMustBeFreeAndShort() {
        var preferences = sample()
        #expect(throws: ProfileEditError.emptyName) { try preferences.addProfile(named: "   ") }
        #expect(throws: ProfileEditError.nameTooLong) { try preferences.addProfile(named: String(repeating: "a", count: 31)) }
        #expect(throws: ProfileEditError.nameTaken("work")) { try preferences.addProfile(named: "work") }
        #expect(throws: ProfileEditError.nameTaken("essentials")) { try preferences.addProfile(named: "essentials") }
        _ = try? preferences.addProfile(named: "Late night", id: "Custom-a")
        #expect(throws: ProfileEditError.nameTaken("Late night")) { try preferences.addProfile(named: "late  NIGHT") }
        for index in 0..<7 { _ = try? preferences.addProfile(named: "P\(index)", id: "Custom-\(index)") }
        #expect(throws: ProfileEditError.tooMany) { try preferences.addProfile(named: "One too many") }
    }

    @Test func builtInsCanBeRenamedAndGoBack() throws {
        var preferences = sample()
        try preferences.editProfile(.work, name: "Office", symbol: "building.2")
        #expect(preferences.title(of: "Work") == "Office")
        #expect(preferences.profileDefinitions == [ProfileDefinition(id: "Work", name: "Office", symbol: "building.2")])
        #expect(preferences.rules["Work"]?[slack] == true, "rules stay under the stored name")
        try preferences.editProfile(.work, name: "", symbol: NetworkProfile.work.defaultSymbol)
        #expect(preferences.profileDefinitions == nil)
        #expect(throws: ProfileEditError.nameTaken("Essentials")) { try preferences.editProfile(.work, name: "Essentials", symbol: nil) }
        #expect(throws: ProfileEditError.notCustom) { try preferences.removeProfile(.work) }
    }

    @Test func removingAProfileTakesItsRulesSchedulesAndNetworksAndFallsBackToWork() throws {
        var preferences = sample()
        let school = try preferences.addProfile(named: "School", copying: .work, id: "Custom-1")
        preferences.profile = school
        preferences.temporaryRules = ["Custom-1|com.spotify.client": TemporaryRule(allowed: false, expires: Date().addingTimeInterval(60)),
                                      "Work|com.spotify.client": TemporaryRule(allowed: true, expires: Date().addingTimeInterval(60))]
        preferences.networkProfiles = ["wifi:home": "Custom-1", "wifi:cafe": "Travel"]
        preferences.profileSchedules = [ProfileSchedule(profile: "Custom-1", days: ProfileSchedule.weekdays, start: 540, end: 1_080)]
        try preferences.removeProfile(school)
        #expect(preferences.profile == .work)
        #expect(preferences.rules["Custom-1"] == nil && preferences.rules["Work"] != nil)
        #expect(preferences.connectionRules?.contains { $0.profile == "Custom-1" } == false)
        #expect(preferences.temporaryRules?.keys.sorted() == ["Work|com.spotify.client"])
        #expect(preferences.networkProfiles == ["wifi:cafe": "Travel"])
        #expect(preferences.profileSchedules == nil && preferences.profileDefinitions == nil)
    }

    @Test func aProfileThatIsGoneFallsBackOnLoad() throws {
        let json = #"{"profile":"Custom-9","rules":{},"limitGB":5,"autoHotspot":true,"defaultAllow":false,"networkProfiles":{"wifi:home":"Custom-9","wifi:cafe":"Work"},"autoProfileFrom":"Custom-9"}"#
        var preferences = try JSONDecoder().decode(SavedPreferences.self, from: Data(json.utf8))
        #expect(preferences.profile.rawValue == "Custom-9", "decoded as stored, before the catalog is known")
        preferences.settleProfiles()
        #expect(preferences.profile == .work && preferences.networkProfiles == ["wifi:cafe": "Work"] && preferences.autoProfileFrom == "Work")
    }

    @Test func aProfileOfYourOwnIsWrittenSoEarlierVersionsStillReadTheFile() throws {
        var preferences = sample()
        preferences.profile = try preferences.addProfile(named: "School", id: "Custom-1")
        let data = try JSONEncoder().encode(preferences.forDisk)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""profile":"Work""#) && text.contains(#""customProfile":"Custom-1""#))
        // An earlier version knows only the three built-in names.
        enum OldProfile: String, Decodable { case Travel, Work, Unrestricted }
        struct OldPreferences: Decodable { let profile: OldProfile; let rules: [String: [String: Bool]] }
        #expect(try JSONDecoder().decode(OldPreferences.self, from: data).profile == .Work)
        var read = try JSONDecoder().decode(SavedPreferences.self, from: data)
        read.settleProfiles()
        #expect(read.profile.rawValue == "Custom-1" && read.customProfile == nil)
        #expect(read == preferences)
    }

    /// Every optional property set. When a property is added to `SavedPreferences`, add it here.
    func everythingSet() -> SavedPreferences {
        var p = sample()
        p.temporaryRules = ["x|y": TemporaryRule(allowed: true, expires: Date(timeIntervalSince1970: 2_000_000_000))]
        p.networkProfiles = ["wifi:a": "Work"]
        p.networkBudgetModes = ["wifi:a": .alert]
        p.networkLimits = ["wifi:a": 3]
        p.trafficScope = "external"
        p.blockedDomains = ["a.test"]
        p.blockedHosts = ["b.test"]
        p.blocklistName = "list"
        p.domainExceptions = ["app": ["c.test"]]
        p.autoProfileFrom = "Work"
        p.customProfile = "Custom-9"
        p.profileDefinitions = [ProfileDefinition(id: "Custom-9", name: "Nine", symbol: "house")]
        p.profileSchedules = [ProfileSchedule(profile: "Work", days: [1], start: 60, end: 120)]
        p.profileScheduleState = ProfileScheduleState(applied: UUID(), previous: "Work")
        p.destinationHistory = DestinationHistorySettings(allApps: true)
        p.historyDays = 30
        p.askNewApps = true
        p.allowApple = true
        p.budgetCycle = BudgetCycle(period: .monthly, anchor: 1, alerts: [80])
        p.networkCycles = ["wifi:a": BudgetCycle(period: .weekly)]
        p.quotas = [AppLimit(name: "q", apps: ["a"], bytes: 1)]
        p.uploadAlerts = true
        p.networkCost = ["wifi:a": "metered"]
        p.pauseUpdaters = true
        p.pauseCloudSync = true
        p.focusPausesUpdaters = true
        p.killSwitch = true
        p.killSwitchLAN = true
        p.killSwitchAllowedUntil = Date(timeIntervalSince1970: 2_000_000_000)
        p.protectThreats = true
        p.protectTrackers = true
        p.trackerList = "list"
        p.agentGuard = true
        p.agentGuardUploadMB = 10
        p.allowedSites = ["d.test"]
        p.fastestDNS = true
        p.networkFastestDNS = ["wifi:a": true]
        p.dnsExcluded = ["google"]
        p.dnsExtra = ["1.1.1.1"]
        p.dataPacks = [DataPack(name: "pack", bytes: 1, start: Date(timeIntervalSince1970: 1_000_000_000), end: Date(timeIntervalSince1970: 2_000_000_000), networks: DataPackNetworks())]
        p.blockCheckResolver = "quad9"
        p.dnsFallback = "cloudflare"
        p.alertNewApps = true
        p.askDestinations = ["com.example.app"]
        p.developerNames = ["AB12CD34EF": "Example Inc"]
        p.blocklistSubscriptions = [BlocklistSubscription(name: "list", url: "https://lists.example/a", id: "sub-a")]
        p.connectionLog = false
        p.connectionLogBrowsers = true
        p.schema = 1
        return p
    }

    @Test func knownKeysCoverEverythingThisVersionWrites() throws {
        let full = everythingSet()
        // Guard the helper itself: nothing optional may have been left nil.
        let unset = Mirror(reflecting: full).children.filter { String(describing: $0.value) == "nil" }.compactMap(\.label)
        #expect(unset.isEmpty, "everythingSet() misses \(unset)")
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        #expect(Set(object.keys).isSubset(of: SavedPreferences.knownKeys))
        #expect(SavedPreferences.knownKeys.contains("customProfile") && SavedPreferences.knownKeys.contains("rules"))
        var custom = sample(); custom.profile = try custom.addProfile(named: "School", id: "Custom-1")
        let disk = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(custom.forDisk)) as? [String: Any])
        #expect(Set(disk.keys).isSubset(of: SavedPreferences.knownKeys))
    }

    @Test func savingKeepsKeysFromANewerVersion() throws {
        let existing = Data(#"{"profile":"Work","rules":{},"limitGB":5,"autoHotspot":true,"defaultAllow":false,"someFutureSetting":{"a":[1,2]},"anotherOne":true}"#.utf8)
        let preferences = sample()   // sample() carries a date from "now": build it once
        let data = try preferences.dataForDisk(over: existing)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["someFutureSetting"] as? [String: [Int]] == ["a": [1, 2]])
        #expect(object["anotherOne"] as? Bool == true)
        var read = try JSONDecoder().decode(SavedPreferences.self, from: data)
        read.settleProfiles()
        var expected = preferences; expected.settleProfiles()
        #expect(read == expected)
    }

    @Test func savingWithNothingForeignWritesTheSameBytesAsBefore() throws {
        let preferences = sample()
        let plain = try JSONEncoder().encode(preferences.forDisk)
        // JSONEncoder doesn't promise one key order from call to call, so compare what the bytes say.
        func parsed(_ data: Data) throws -> NSDictionary { try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary) }
        #expect(try parsed(preferences.dataForDisk(over: plain)) == parsed(plain))
        #expect(try parsed(preferences.dataForDisk(over: nil)) == parsed(plain))
    }

    @Test func aKnownKeyTheFileHasIsNotResurrected() throws {
        let existing = Data(#"{"profile":"Work","rules":{},"blockedHosts":["x.test"],"futureKey":1}"#.utf8)
        var preferences = sample()
        preferences.blockedHosts = nil
        let object = try #require(try JSONSerialization.jsonObject(with: preferences.dataForDisk(over: existing)) as? [String: Any])
        #expect(object["blockedHosts"] == nil)
        #expect(object["futureKey"] as? Int == 1)
    }

    @Test func profilesEncodeAsTheirStoredName() throws {
        var preferences = SavedPreferences()
        preferences.profile = .travel
        let text = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        #expect(text.contains(#""profile":"Travel""#))
        #expect(NetworkProfile.named("essentials") == .travel && NetworkProfile.named("TRAVEL") == .travel && NetworkProfile.named("Work") == .work)
        #expect(NetworkProfile.named("nothing-like-this") == nil)
        #expect(NetworkProfile(rawValue: "Unrestricted") == .unrestricted && !NetworkProfile.unrestricted.keepsRules)
    }
}

struct ProfileScheduleTests {
    var calendar: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; calendar.firstWeekday = 2; return calendar }
    /// 2026-11-09 is a Monday.
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    let work = ProfileSchedule(profile: "Work", days: ProfileSchedule.weekdays, start: 9 * 60, end: 18 * 60)
    let night = ProfileSchedule(profile: "Travel", days: [6], start: 22 * 60, end: 2 * 60)

    @Test func weekdayWindows() {
        #expect(work.windowStart(containing: at(9, 9), calendar: calendar) == at(9, 9))
        #expect(work.windowStart(containing: at(9, 17, 59), calendar: calendar) == at(9, 9))
        #expect(work.windowStart(containing: at(9, 18), calendar: calendar) == nil, "the end is when it stops")
        #expect(work.windowStart(containing: at(9, 8, 59), calendar: calendar) == nil)
        #expect(work.windowStart(containing: at(14, 12), calendar: calendar) == nil, "Saturday")
        var off = work; off.enabled = false
        #expect(off.windowStart(containing: at(9, 12), calendar: calendar) == nil)
        #expect(!ProfileSchedule(profile: "Work", days: [2], start: 60, end: 60).valid && !ProfileSchedule(profile: "Work", days: [], start: 0, end: 60).valid)
    }

    @Test func overnightWindowsRunIntoTheNextDay() {
        #expect(night.overnight)
        #expect(night.windowStart(containing: at(13, 23), calendar: calendar) == at(13, 22), "Friday night")
        #expect(night.windowStart(containing: at(14, 1, 30), calendar: calendar) == at(13, 22), "Saturday morning belongs to Friday")
        #expect(night.windowStart(containing: at(14, 2), calendar: calendar) == nil)
        #expect(night.windowStart(containing: at(14, 23), calendar: calendar) == nil, "not Saturday night")
        let sunday = ProfileSchedule(profile: "Travel", days: [7], start: 23 * 60, end: 60)
        #expect(sunday.windowStart(containing: at(15, 0, 30), calendar: calendar) == at(14, 23), "Saturday into Sunday wraps the week")
    }

    @Test func theWindowThatBeganLastWins() {
        let lunch = ProfileSchedule(profile: "Unrestricted", days: ProfileSchedule.weekdays, start: 12 * 60, end: 13 * 60)
        #expect(ProfileScheduler.active([work, lunch], now: at(9, 12, 30), calendar: calendar)?.id == lunch.id)
        #expect(ProfileScheduler.active([lunch, work], now: at(9, 13, 30), calendar: calendar)?.id == work.id)
        #expect(ProfileScheduler.active([work, lunch], now: at(9, 20), calendar: calendar) == nil)
    }

    @Test func switchesAtTheStartAndBackAtTheEnd() {
        var preferences = SavedPreferences()
        preferences.profile = .unrestricted
        preferences.profileSchedules = [work]
        #expect(!ProfileScheduler.step(&preferences, now: at(9, 8), calendar: calendar))
        #expect(ProfileScheduler.step(&preferences, now: at(9, 9), calendar: calendar))
        #expect(preferences.profile == .work)
        #expect(preferences.profileScheduleState == ProfileScheduleState(applied: work.id, previous: "Unrestricted"))
        #expect(!ProfileScheduler.step(&preferences, now: at(9, 12), calendar: calendar), "nothing new mid-window")
        #expect(ProfileScheduler.step(&preferences, now: at(9, 18), calendar: calendar))
        #expect(preferences.profile == .unrestricted && preferences.profileScheduleState == nil)
    }

    @Test func aProfilePickedByHandStaysPastTheEnd() {
        var preferences = SavedPreferences()
        preferences.profile = .unrestricted
        preferences.profileSchedules = [work]
        ProfileScheduler.step(&preferences, now: at(9, 9), calendar: calendar)
        preferences.profile = .travel
        #expect(!ProfileScheduler.step(&preferences, now: at(9, 12), calendar: calendar), "the schedule doesn't fight a hand-picked profile")
        ProfileScheduler.step(&preferences, now: at(9, 18, 1), calendar: calendar)
        #expect(preferences.profile == .travel && preferences.profileScheduleState == nil)
    }

    @Test func meteredEssentialsStaysOnAndTheScheduleFollowsIt() {
        var preferences = SavedPreferences()
        preferences.profile = .travel; preferences.autoProfileFrom = "Unrestricted"
        preferences.profileSchedules = [work]
        ProfileScheduler.step(&preferences, now: at(9, 9), calendar: calendar)
        #expect(preferences.profile == .travel && preferences.autoProfileFrom == "Work")
        #expect(preferences.profileScheduleState?.previous == "Unrestricted")
        ProfileScheduler.step(&preferences, now: at(9, 18), calendar: calendar)
        #expect(preferences.profile == .travel && preferences.autoProfileFrom == "Unrestricted")
    }

    @Test func aFocusHoldsAndMissingProfilesAreIgnored() {
        var preferences = SavedPreferences()
        preferences.profile = .unrestricted
        preferences.profileSchedules = [work, ProfileSchedule(profile: "Custom-gone", days: ProfileSchedule.everyDay, start: 0, end: 1_439)]
        #expect(!ProfileScheduler.step(&preferences, now: at(9, 10), held: true, calendar: calendar))
        #expect(preferences.profile == .unrestricted)
        ProfileScheduler.step(&preferences, now: at(9, 20), calendar: calendar)
        #expect(preferences.profile == .unrestricted, "a schedule for a profile that's gone does nothing")
    }

    @Test func oneWindowGivingWayToAnotherKeepsTheProfileFromBefore() {
        var preferences = SavedPreferences()
        preferences.profile = .unrestricted
        let evening = ProfileSchedule(profile: "Travel", days: ProfileSchedule.weekdays, start: 18 * 60, end: 20 * 60)
        preferences.profileSchedules = [work, evening]
        ProfileScheduler.step(&preferences, now: at(9, 10), calendar: calendar)
        ProfileScheduler.step(&preferences, now: at(9, 18), calendar: calendar)
        #expect(preferences.profile == .travel && preferences.profileScheduleState?.previous == "Unrestricted")
        ProfileScheduler.step(&preferences, now: at(9, 20), calendar: calendar)
        #expect(preferences.profile == .unrestricted)
    }

    @Test func nextChangeFindsTheNextStartOrEnd() throws {
        let start = try #require(ProfileScheduler.nextChange([work], after: at(9, 7), calendar: calendar))
        #expect(start.date == at(9, 9) && start.schedule?.id == work.id)
        let end = try #require(ProfileScheduler.nextChange([work], after: at(9, 10), calendar: calendar))
        #expect(end.date == at(9, 18) && end.schedule == nil)
        let monday = try #require(ProfileScheduler.nextChange([work], after: at(13, 19), calendar: calendar))
        #expect(monday.date == at(16, 9), "Friday evening waits for Monday")
        #expect(ProfileScheduler.nextChange([], after: at(9, 7), calendar: calendar) == nil)
    }

    @Test func summariesNameTheDays() {
        let locale = Locale(identifier: "en_US")
        #expect(ProfileSchedule.daysSummary(ProfileSchedule.weekdays, calendar: calendar, locale: locale) == "Weekdays")
        #expect(ProfileSchedule.daysSummary([7, 1], calendar: calendar, locale: locale) == "Weekends")
        #expect(ProfileSchedule.daysSummary([4, 2], calendar: calendar, locale: locale) == "Mon and Wed")
        #expect(ProfileSchedule.time(9 * 60 + 30, locale: Locale(identifier: "en_GB")).hasSuffix("9:30"))
        #expect(ProfileSchedule.time(18 * 60, locale: Locale(identifier: "en_GB")) == "18:00")
    }
}

struct RuleBackupTests {
    let slack = "com.tinyspeck.slackmacgap"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func sample() throws -> SavedPreferences {
        var preferences = SavedPreferences()
        preferences.rules = ["Work": [slack: true, "process:node": false], "Travel": ["com.apple.Music": false]]
        preferences.temporaryRules = ["Work|com.spotify.client": TemporaryRule(allowed: false, expires: now.addingTimeInterval(600))]
        preferences.connectionRules = [ConnectionRule(app: slack, host: "a.example", port: "443", direction: "outgoing", allowed: false, profile: "Work"),
                                       ConnectionRule(app: slack, host: "timed.example", allowed: true, profile: "Work", expires: now.addingTimeInterval(60))]
        preferences.blockedHosts = ["tracker.example", "203.0.113.0/24"]
        preferences.allowedSites = ["shop.example"]
        preferences.domainExceptions = ["com.apple.Safari": ["cdn.example"]]
        preferences.networkProfiles = ["wifi:Home Network": "Work"]
        preferences.askNewApps = true
        try preferences.addProfile(named: "School", symbol: "lightbulb", copying: nil, id: "Custom-1")
        preferences.rules["Custom-1"] = ["com.valvesoftware.steam": false]
        preferences.profileSchedules = [ProfileSchedule(profile: "Custom-1", days: ProfileSchedule.weekdays, start: 8 * 60, end: 15 * 60)]
        return preferences
    }

    @Test func exportIsReadableAndLeavesOutTimedRulesAndNetworks() throws {
        let data = try RuleBackup(try sample(), now: now).data()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""format" : "kilobat-rules""#))
        #expect(text.contains(#""id" : "essentials""#) && text.contains(#""id" : "work""#) && text.contains(#""name" : "School""#))
        #expect(text.contains(#""start" : "08:00""#) && text.contains(#""mon""#))
        #expect(!text.contains("timed.example") && !text.contains("spotify"), "timed rules end on their own")
        #expect(!text.contains("Home Network"), "no Wi-Fi names")
        let parsed = try RuleBackup.parse(data)
        #expect(parsed.profiles.count == 4 && parsed.newApps == "ask")
    }

    @Test func importingYourOwnExportChangesNothing() throws {
        let preferences = try sample()
        let backup = try RuleBackup.parse(try RuleBackup(preferences, now: now).data())
        for mode in RuleImportMode.allCases {
            let plan = RuleImportPlan(backup, into: preferences, mode: mode)
            #expect(plan.isEmpty, "\(mode): \(plan.lines.map(\.text))")
            #expect(plan.result.rules == preferences.rules && plan.result.connectionRules?.count == preferences.connectionRules?.count)
        }
    }

    @Test func mergeAddsAndUpdatesAndKeepsTheRest() throws {
        let preferences = try sample()
        var other = SavedPreferences()
        other.rules = ["Work": [slack: false, "com.figma.Desktop": true]]
        other.connectionRules = [ConnectionRule(app: slack, host: "a.example", port: "443", direction: "outgoing", allowed: true, profile: "Work"),
                                 ConnectionRule(app: "process:curl", host: "api.example.com", allowed: true, profile: "Work")]
        other.blockedHosts = ["ads.example"]
        try other.addProfile(named: "school", id: "Custom-77")
        other.rules["Custom-77"] = ["com.roblox.RobloxPlayer": false]
        try other.addProfile(named: "Gaming", symbol: "gamecontroller", id: "Custom-88")
        other.profileSchedules = [ProfileSchedule(profile: "Custom-88", days: [1, 7], start: 10 * 60, end: 22 * 60)]
        let backup = try RuleBackup.parse(try RuleBackup(other, now: now).data())
        let plan = RuleImportPlan(backup, into: preferences, mode: .merge, newID: { "Custom-new" })
        let result = plan.result
        #expect(result.rules["Work"] == [slack: false, "process:node": false, "com.figma.Desktop": true])
        #expect(result.rules["Travel"] == ["com.apple.Music": false], "merge leaves profiles the file doesn't change")
        #expect(result.rules["Custom-1"] == ["com.valvesoftware.steam": false, "com.roblox.RobloxPlayer": false], "matched by name, whatever the case")
        #expect(result.title(of: "Custom-1") == "school")
        #expect(result.title(of: "Custom-88") == "Gaming", "a new profile keeps the file's id when it's free")
        #expect(result.profileSchedules?.count == 2)
        #expect(result.connectionRules?.first { $0.host == "a.example" }?.allowed == true)
        #expect(result.connectionRules?.contains { $0.host == "timed.example" } == true, "timed rules here are left alone")
        #expect(result.blockedHosts == ["203.0.113.0/24", "ads.example", "tracker.example"])
        #expect(result.askNewApps == nil && result.defaultAllow == false, "the file says block new apps")
        #expect(plan.removed == 0 && plan.added > 0 && plan.changed > 0)
        #expect(plan.lines.contains { $0.kind == .changed && $0.text.contains("Block \(slack) in Work, was Allow") })
        #expect(plan.lines.contains { $0.kind == .added && $0.text == "New profile: Gaming" })
    }

    @Test func replaceMakesTheRulesMatchTheFile() throws {
        let preferences = try sample()
        var other = SavedPreferences()
        other.rules = ["Work": [slack: true]]
        other.askNewApps = true
        let backup = try RuleBackup.parse(try RuleBackup(other, now: now).data())
        let plan = RuleImportPlan(backup, into: preferences, mode: .replace)
        let result = plan.result
        #expect(result.rules == ["Work": [slack: true]])
        #expect(result.connectionRules?.map(\.host) == ["timed.example"], "only the timed rule, which files never hold")
        #expect(result.blockedHosts == nil && result.allowedSites == nil && result.domainExceptions == nil)
        #expect(result.profileDefinitions == nil && result.profileSchedules == nil, "your own profile and its schedule go")
        #expect(result.temporaryRules == preferences.temporaryRules)
        #expect(plan.lines.contains { $0.kind == .removed && $0.text == "Remove profile: School" })
        #expect(plan.added == 0 && plan.removed >= 6)
    }

    @Test func filesAreCheckedBeforeAnythingChanges() throws {
        func parse(_ json: String) throws { _ = try RuleBackup.parse(Data(json.utf8)) }
        #expect(throws: RuleBackupError.notRules) { try parse(#"{"hello":"world"}"#) }
        #expect(throws: RuleBackupError.notRules) { try parse("not json") }
        #expect(throws: RuleBackupError.unreadable) { try parse(#"{"format":"kilobat-rules","version":1}"#) }
        #expect(throws: RuleBackupError.newerVersion) { try parse(#"{"format":"kilobat-rules","version":2,"profiles":[]}"#) }
        #expect(throws: RuleBackupError.tooLarge) { _ = try RuleBackup.parse(Data(count: RuleBackup.maxBytes + 1)) }
        let bad = [
            #"{"format":"kilobat-rules","version":1,"profiles":[{"id":"work","apps":[{"app":"not an id","allow":true}]}]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[{"id":"work","destinations":[{"app":"com.a.b","host":"bad host!","allow":true}]}]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[{"id":"work","destinations":[{"app":"com.a.b","host":"a.example","port":"99999","allow":true}]}]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[{"id":"unrestricted","apps":[{"app":"com.a.b","allow":false}]}]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[{"id":"Custom-1"}]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[{"id":"work"},{"id":"Work"}]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[],"schedules":[{"profile":"Custom-9","days":["mon"],"start":"09:00","end":"17:00"}]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[],"schedules":[{"profile":"work","days":["someday"],"start":"09:00","end":"17:00"}]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[],"schedules":[{"profile":"work","days":["mon"],"start":"25:00","end":"17:00"}]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[],"everyApp":{"blocked":["localhost"]}}"#,
            #"{"format":"kilobat-rules","version":1,"newApps":"maybe","profiles":[]}"#,
            #"{"format":"kilobat-rules","version":1,"profiles":[{"id":"work","symbol":"rocket"}]}"#,
        ]
        for json in bad {
            #expect(throws: RuleBackupError.self, "\(json)") { try parse(json) }
            #expect((try? RuleBackup.parse(Data(json.utf8))) == nil)
        }
        // Handwritten files may use "travel" and leave out what they don't need.
        let minimal = try RuleBackup.parse(Data(#"{"format":"kilobat-rules","version":1,"profiles":[{"id":"travel","apps":[{"app":"com.apple.Music","allow":false}]}]}"#.utf8))
        let plan = RuleImportPlan(minimal, into: SavedPreferences(), mode: .merge)
        #expect(plan.result.rules == ["Travel": ["com.apple.Music": false]] && plan.lines.map(\.text) == ["Block com.apple.Music in Essentials"])
    }
}
