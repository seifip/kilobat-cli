import Foundation

/// One line of a settings import's preview.
public struct SettingsImportLine: Equatable, Identifiable, Sendable {
    public let id: Int
    public let kind: RuleImportLine.Kind
    public let area: SettingsArea
    public let text: String
    /// The setting only acts with Kilobat Pro, which this Mac doesn't have: "Takes effect with Kilobat Pro".
    public let needsPro: Bool
    /// The network it belongs to isn't the one the Mac is on: "Applies when you next join Home Wi-Fi".
    public let whenJoining: String?
}

/// Something an import leaves for the person to do on this Mac, because it never travels in a file.
public enum SettingsToDo: String, CaseIterable, Sendable, Identifiable {
    case filter, powerHelper, licence, calendar, obsPassword, blocklist
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .filter: String(localized: "Turn on the network filter", comment: "Settings import: still to do on this Mac")
        case .powerHelper: String(localized: "Approve the power helper", comment: "Settings import: still to do on this Mac")
        case .licence: String(localized: "Enter your licence", comment: "Settings import: still to do on this Mac")
        case .calendar: String(localized: "Allow Kilobat to read your calendar", comment: "Settings import: still to do on this Mac")
        case .obsPassword: String(localized: "Enter the OBS password again", comment: "Settings import: still to do on this Mac")
        case .blocklist: String(localized: "Import your blocklist again", comment: "Settings import: still to do on this Mac")
        }
    }
}

/// What this Mac already has, for the "Still to do on this Mac" list.
public struct SettingsMacState: Sendable {
    public var filterActive: Bool
    public var hasPro: Bool
    public var powerHelperApproved: Bool
    public var calendarAllowed: Bool
    public init(filterActive: Bool, hasPro: Bool, powerHelperApproved: Bool, calendarAllowed: Bool) {
        self.filterActive = filterActive; self.hasPro = hasPro; self.powerHelperApproved = powerHelperApproved; self.calendarAllowed = calendarAllowed
    }
}

/// What importing a settings file would change, worked out before anything does. Settings merge only: what the file
/// doesn't hold stays as it is, and lists gain entries but never lose them. The rules part follows `RuleImportPlan`.
public struct SettingsImportPlan: Equatable {
    /// `SavedPreferences` after the import.
    public let result: SavedPreferences
    /// Keys of the app's `UserDefaults` domain to write or remove.
    public let defaultsChanges: [String: DefaultsChange]
    public let lines: [SettingsImportLine]
    /// Said above the lines: the import makes the Mac less protected, or a kill switch may hold connections.
    public let warnings: [String]
    /// What the file held that isn't applied, and values brought into range: one sentence each.
    public let notes: [String]
    /// The rules part, when the file has rules and their area is ticked.
    public let rules: RuleImportPlan?
    /// Something written waits for Kilobat to be reopened.
    public let needsRelaunch: Bool
    /// Things the file asks for that need this Mac: see `stillToDo(_:)`.
    let wants: Set<SettingsToDo>

    public var added: Int { lines.filter { $0.kind == .added }.count }
    public var changed: Int { lines.filter { $0.kind == .changed }.count }
    public var removed: Int { lines.filter { $0.kind == .removed }.count }
    public var isEmpty: Bool { lines.isEmpty && defaultsChanges.isEmpty }
    public func count(_ area: SettingsArea) -> Int { lines.filter { $0.area == area }.count }

    /// The areas ticked unless the person changes them: all the file holds, except those that contact other services.
    public static func defaultAreas(_ backup: SettingsBackup) -> Set<SettingsArea> { Set(backup.areas).subtracting(SettingsArea.askedOnImport) }

    /// What is left to do on this Mac after the import, given what it already has.
    public func stillToDo(_ mac: SettingsMacState) -> [SettingsToDo] {
        SettingsToDo.allCases.filter { item in
            guard wants.contains(item) else { return false }
            switch item {
            case .filter: return !mac.filterActive
            case .powerHelper: return !mac.powerHelperApproved
            case .licence: return !mac.hasPro
            case .calendar: return !mac.calendarAllowed
            case .obsPassword, .blocklist: return true
            }
        }
    }

    /// `defaults` is the app's `UserDefaults` domain as a dictionary; `knownNetworks` the networks this Mac has seen,
    /// by key, with their names; `currentNetwork` the one it is on now.
    public init(_ backup: SettingsBackup, preferences: SavedPreferences, defaults: [String: Any], mode: RuleImportMode = .merge, areas: Set<SettingsArea>? = nil,
                knownNetworks: [String: String] = [:], currentNetwork: String? = nil, hasPro: Bool = true,
                appName: (String) -> String = RuleImportPlan.plainName, newID: () -> String = { "Custom-" + String(UUID().uuidString.prefix(8)) }) {
        let ticked = areas ?? Self.defaultAreas(backup)
        var lines: [SettingsImportLine] = [], warnings: [String] = [], notes: [String] = []
        var changes: [String: DefaultsChange] = [:]
        var relaunch = false
        var wants = Set<SettingsToDo>()
        var nextID = 0
        func line(_ kind: RuleImportLine.Kind, _ area: SettingsArea, _ text: String, pro: Bool = false, joining: String? = nil) {
            lines.append(SettingsImportLine(id: nextID, kind: kind, area: area, text: text, needsPro: pro && !hasPro, whenJoining: joining))
            nextID += 1
            if pro && !hasPro { wants.insert(.licence) }
        }
        func changedText(_ setting: String, _ old: String, _ new: String) -> String {
            String(localized: "\(setting): \(old) → \(new)", comment: "Settings import preview: a setting, its value now and the file's")
        }

        // Rules first: per-network profiles follow the ids the rules import gives the file's profiles.
        var next = preferences
        var rulesPlan: RuleImportPlan?
        if let rules = backup.rules, ticked.contains(.rules) {
            let plan = RuleImportPlan(rules, into: preferences, mode: mode, appName: appName, newID: newID)
            rulesPlan = plan
            next = plan.result
            for rule in plan.lines { line(rule.kind, .rules, rule.text) }
            for name in plan.skipped { notes.append(String(localized: "\(name) is left out: you already have \(ProfileEditing.maxCustom) profiles of your own, or one with its name.", comment: "Rules import: a profile that can't be added")) }
            if !plan.lines.isEmpty { wants.insert(.filter) }
        }

        // Settings in the table.
        let reader = { SettingsReader(preferences: next, defaults: defaults) }
        var defaultsNow = defaults
        var lineFor: [String: Int] = [:]
        func show(_ value: SettingsValue, _ entry: SettingsFileEntry) -> String { SettingsImportPlan.show(value, entry.kind) }
        for entry in SettingsFile.entries where ticked.contains(entry.area) {
            guard var raw = backup.value(at: entry.path) else { continue }
            if let member = entry.member { raw = .bool(raw.strings?.contains(member) == true) }
            let current = SettingsReader(preferences: next, defaults: defaultsNow).current(entry)
            var wanted: SettingsValue
            switch entry.kind {
            case .bool: wanted = raw
            case .int(_, let range, let clamp, let unit):
                guard let number = raw.int else { continue }
                if range.contains(number) { wanted = .int(number) }
                else if clamp {
                    let fitted = min(range.upperBound, max(range.lowerBound, number))
                    wanted = .int(fitted)
                    notes.append(String(localized: "\(entry.title): \(unit.format(Double(number))) adjusted to \(unit.format(Double(fitted)))", comment: "Settings import: a value brought into range"))
                } else { notes.append(Self.leftAsIs(entry.title, unit.format(Double(number)))); continue }
            case .intChoice(_, let choices, let unit):
                guard let number = raw.int else { continue }
                guard choices.contains(number) else { notes.append(Self.leftAsIs(entry.title, unit.format(Double(number)))); continue }
                wanted = .int(number)
            case .double(_, let range, let unit):
                guard let number = raw.number else { continue }
                let fitted = min(range.upperBound, max(range.lowerBound, number))
                if fitted != number {
                    notes.append(String(localized: "\(entry.title): \(unit.format(number)) adjusted to \(unit.format(fitted))", comment: "Settings import: a value brought into range"))
                }
                wanted = .double(fitted)
            case .choice(_, let valid, _):
                guard let text = raw.string else { continue }
                guard valid(text) else { notes.append(Self.leftAsIs(entry.title, text)); continue }
                wanted = raw
            case .text(_, _, let secret, let valid):
                guard let text = raw.string else { continue }
                guard valid(text) else { notes.append(Self.leftAsIs(entry.title, secret ? String(localized: "the address isn’t HTTPS", comment: "Settings import: why a webhook is left as it is") : text)); continue }
                wanted = raw
            case .list(_, let normalize, _):
                // Merge: add what's missing, never remove.
                let have = current.strings ?? []
                let added = (raw.strings ?? []).compactMap(normalize).reduce(into: [String]()) { list, item in if !have.contains(item) && !list.contains(item) { list.append(item) } }
                guard !added.isEmpty else { continue }
                for item in added { line(.added, entry.area, String(localized: "\(entry.title): \(Self.listItem(item, entry.path))", comment: "Settings import preview: a list and an entry added to it"), pro: entry.pro) }
                wanted = .array((have + added).map(SettingsValue.string))
            }
            guard !Self.same(wanted, current) else { continue }
            if case .list = entry.kind {} else {
                lineFor[entry.path + (entry.member.map { "|" + $0 } ?? "")] = nextID
                line(.changed, entry.area, changedText(entry.title, show(current, entry), show(wanted, entry)), pro: entry.pro && wanted.bool != false)
            }
            switch entry.storage {
            case .preferences: entry.write?(&next, wanted)
            case .defaults(let key):
                let change: DefaultsChange = Self.same(wanted, entry.kind.defaultValue) ? .remove : .set(Self.stored(wanted, entry.kind))
                changes[key] = change
                switch change { case .remove: defaultsNow[key] = nil; case .set(let value): defaultsNow[key] = value.object }
                if !entry.live { relaunch = true }
            }
        }
        // The file can't take away every way back to Kilobat: its own menu bar item stays.
        let shown = SettingsReader(preferences: next, defaults: defaultsNow)
        if let main = SettingsFile.entry("menuBar.statusItem"), let wifi = SettingsFile.entry("menuBar.wifiItem"),
           shown.current(main).bool == false, shown.current(wifi).bool == false {
            if case .defaults(let key) = main.storage {
                let before = SettingsReader(preferences: preferences, defaults: defaults).current(main)
                changes[key] = before.bool == true ? nil : .remove
                if let id = lineFor[main.path] { lines.removeAll { $0.id == id } }
                if before.bool != true { line(.changed, .menuBar, changedText(main.title, show(.bool(false), main), show(.bool(true), main))) }
            }
            notes.append(String(localized: "Kilobat’s own menu bar item stays on, so you can always reach Kilobat.", comment: "Settings import: a file that hides every menu bar item"))
        }

        // App limits: matched by app name, network and whether they count uploads only; never removed.
        var limits = next.quotas ?? []
        func mergeLimit(_ file: SettingsAppLimit, network: String?, area: SettingsArea, joining: String?, label: String?) {
            let uploadOnly = file.uploadOnly == true
            let mode = file.mode.flatMap(NetworkBudgetMode.init(rawValue:))
            if file.mode != nil, mode == nil { notes.append(Self.leftAsIs(String(localized: "Limit for \(file.name)", comment: "Settings import: an app limit"), file.mode ?? "")); return }
            let size = TrafficFormat.bytes(file.bytes)
            let title = label.map { String(localized: "\($0) · limit for \(file.name)", comment: "Settings import: a network's name and an app limit") } ?? String(localized: "Limit for \(file.name)", comment: "Settings import: an app limit")
            if let at = limits.firstIndex(where: { $0.name == file.name && $0.network == network && $0.uploadOnly == uploadOnly }) {
                var limit = limits[at]
                let old = limit
                limit.bytes = file.bytes; limit.apps = file.apps; limit.mode = mode; limit.cycle = file.cycle
                guard limit != old else { return }
                limits[at] = limit
                let before = TrafficFormat.bytes(old.bytes)
                line(.changed, area, changedText(title, before + " · " + old.effectiveMode.title, size + " · " + limit.effectiveMode.title), joining: joining)
            } else {
                limits.append(AppLimit(name: file.name, apps: file.apps, bytes: file.bytes, uploadOnly: uploadOnly, network: network, mode: mode, cycle: file.cycle))
                line(.added, area, String(localized: "\(title): \(size)", comment: "Settings import preview: a new app limit and its size"), joining: joining)
            }
            if mode == nil || mode == .block { wants.insert(.filter) }
        }
        if ticked.contains(.budgets) { for limit in backup.appLimits { mergeLimit(limit, network: nil, area: .budgets, joining: nil, label: nil) } }

        // Provider and plan, kept in one CreditSettings with the network it serves.
        let credit = reader().credit
        var newCredit = credit ?? CreditSettings()
        if ticked.contains(.provider), let provider = backup.value(at: "provider")?.object {
            func text(_ key: String, _ path: WritableKeyPath<CreditSettings, String?>, _ label: String) {
                guard let value = provider[key]?.string else { return }
                let wanted = value.isEmpty ? nil : value, old = newCredit[keyPath: path]
                guard wanted != old else { return }
                if key == "id", let wanted, OutageCreditTable.bundled.provider(wanted) == nil { notes.append(Self.leftAsIs(label, wanted)); return }
                newCredit[keyPath: path] = wanted
                func display(_ text: String?) -> String {
                    guard let text else { return String(localized: "none", comment: "Settings import: no value") }
                    if key == "planWording" { return String(localized: "your wording", comment: "Settings import: the plan wording, not shown") }
                    return key == "id" ? OutageCreditTable.bundled.provider(text)?.name ?? text : text
                }
                line(.changed, .provider, changedText(label, display(old), display(wanted)))
            }
            func number(_ key: String, _ path: WritableKeyPath<CreditSettings, Double?>, _ label: String, _ unit: SettingsUnit) {
                guard let value = provider[key]?.number else { return }
                let fitted = min(100_000, max(0, value))
                if fitted != value { notes.append(String(localized: "\(label): \(unit.format(value)) adjusted to \(unit.format(fitted))", comment: "Settings import: a value brought into range")) }
                guard fitted != newCredit[keyPath: path] else { return }
                let old = newCredit[keyPath: path]
                newCredit[keyPath: path] = fitted
                line(.changed, .provider, changedText(label, old.map { unit.format($0) } ?? String(localized: "none", comment: "Settings import: no value"), unit.format(fitted)))
            }
            text("id", \.provider, String(localized: "Provider", comment: "Settings import preview"))
            text("country", \.country, String(localized: "Country", comment: "Settings import preview"))
            text("otherProvider", \.otherProvider, String(localized: "Provider name", comment: "Settings import preview"))
            number("monthlyPrice", \.monthlyPrice, String(localized: "Monthly price", comment: "Settings import preview"), .none)
            number("uploadMbps", \.uploadMbps, String(localized: "Plan upload speed", comment: "Settings import preview"), .mbps)
            number("minimumMbps", \.minimumMbps, String(localized: "Guaranteed download speed", comment: "Settings import preview"), .mbps)
            text("planWording", \.planWording, String(localized: "Plan wording", comment: "Settings import preview"))
        }

        // Settings for specific networks.
        var plans = reader().plans, plansChanged = false
        var fast = reader().fastNetworks, fastChanged = false
        var places = reader().places, placesChanged = false
        if ticked.contains(.networks) {
            for network in backup.networks ?? [] {
                let key = network.key.trimmingCharacters(in: .whitespaces)
                let name = network.name ?? knownNetworks[key] ?? key
                let joining: String? = knownNetworks[key] == nil && key != currentNetwork ? name : nil
                func networkLine(_ kind: RuleImportLine.Kind, _ setting: String, _ old: String, _ new: String, atJoin: Bool = false, pro: Bool = false) {
                    line(kind, .networks, changedText(String(localized: "\(name) · \(setting)", comment: "Settings import preview: a network's name and one of its settings"), old, new),
                         pro: pro, joining: atJoin ? name : joining)
                }
                if let budget = network.budget {
                    let now = SettingsReader(preferences: next, defaults: defaultsNow).budget(key, current: currentNetwork)
                    let title = String(localized: "budget", comment: "Settings import preview: a network's budget")
                    if let limit = budget.limitGB {
                        let fitted = min(100_000, limit)
                        if fitted != limit { notes.append(String(localized: "\(name) · \(title): \(SettingsUnit.gigabytes.format(limit)) adjusted to \(SettingsUnit.gigabytes.format(fitted))", comment: "Settings import: a value brought into range")) }
                        if fitted != now.limit {
                            next.networkLimits = (next.networkLimits ?? [:]).merging([key: fitted]) { $1 }
                            if key == currentNetwork { next.limitGB = fitted }
                            networkLine(.changed, title, SettingsUnit.gigabytes.format(now.limit), SettingsUnit.gigabytes.format(fitted))
                        }
                    }
                    if let text = budget.mode {
                        if let mode = NetworkBudgetMode(rawValue: text) {
                            if mode != now.mode {
                                next.networkBudgetModes = (next.networkBudgetModes ?? [:]).merging([key: mode]) { $1 }
                                networkLine(.changed, title, now.mode.title, mode.title)
                                if mode == .block { wants.insert(.filter) }
                            }
                        } else { notes.append(Self.leftAsIs("\(name) · \(title)", text)) }
                    }
                    if let cycle = budget.cycle {
                        let wanted: BudgetCycle? = cycle == BudgetCycle() ? nil : cycle
                        if wanted != now.cycle {
                            if let wanted { next.networkCycles = (next.networkCycles ?? [:]).merging([key: wanted]) { $1 } } else { next.networkCycles?[key] = nil }
                            if next.networkCycles?.isEmpty == true { next.networkCycles = nil }
                            if key == currentNetwork { next.budgetCycle = wanted }
                            networkLine(.changed, title, (now.cycle ?? BudgetCycle()).summary(), cycle.summary())
                        }
                    }
                    // A limit or cycle without a stored mode reads as Block, so the file's mode is kept whenever it reads otherwise.
                    if let mode = budget.mode.flatMap(NetworkBudgetMode.init(rawValue:)), next.budgetMode(for: key) != mode {
                        next.networkBudgetModes = (next.networkBudgetModes ?? [:]).merging([key: mode]) { $1 }
                    }
                }
                if let text = network.dataCost {
                    if let cost = NetworkCost(rawValue: text) {
                        let old = next.cost(of: key)
                        if cost != old {
                            next.setCost(cost, for: key)
                            networkLine(.changed, String(localized: "data cost", comment: "Settings import preview: a network's data cost"), old.title, cost.title)
                        }
                    } else { notes.append(Self.leftAsIs("\(name) · " + String(localized: "data cost", comment: "Settings import preview: a network's data cost"), text)) }
                }
                if let profile = network.profile {
                    let stored = RuleBackup.storedID(profile)
                    if let local = rulesPlan?.profileMap[stored] ?? next.knownProfile(stored)?.rawValue {
                        if next.networkProfiles?[key] != local {
                            let old = next.networkProfiles?[key].map { next.title(of: $0) } ?? String(localized: "none", comment: "Settings import: no value")
                            next.networkProfiles = (next.networkProfiles ?? [:]).merging([key: local]) { $1 }
                            // Profiles chosen for a network apply when the Mac joins it.
                            networkLine(.changed, String(localized: "profile", comment: "Settings import preview: a network's profile"), old, next.title(of: local), atJoin: true)
                        }
                    } else { notes.append(Self.leftAsIs("\(name) · " + String(localized: "profile", comment: "Settings import preview: a network's profile"), profile)) }
                }
                if let on = network.fastestDNS, next.networkFastestDNS?[key] != on {
                    let old = next.fastestDNSEnabled(on: key)
                    next.networkFastestDNS = (next.networkFastestDNS ?? [:]).merging([key: on]) { $1 }
                    if old != on { networkLine(.changed, String(localized: "fastest DNS", comment: "Settings import preview: a network's fastest DNS"), Self.show(.bool(old), .bool(false)), Self.show(.bool(on), .bool(false)), pro: true) }
                }
                if let plan = network.planMbps {
                    let fitted = min(100_000, plan)
                    if plans[key] != fitted {
                        let old = plans[key]
                        plans[key] = fitted; plansChanged = true
                        networkLine(.changed, String(localized: "plan speed", comment: "Settings import preview: a network's plan speed"),
                                    old.map { SettingsUnit.mbps.format($0) } ?? String(localized: "none", comment: "Settings import: no value"), SettingsUnit.mbps.format(fitted))
                    }
                }
                if let on = network.sendLaterFastEnough, fast.contains(key) != on {
                    if on { fast.append(key) } else { fast.removeAll { $0 == key } }
                    fastChanged = true
                    networkLine(.changed, String(localized: "fast enough for Send later", comment: "Settings import preview"), Self.show(.bool(!on), .bool(false)), Self.show(.bool(on), .bool(false)))
                }
                if let place = network.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty,
                   ((places[key] as? [String: Any])?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) != place {
                    var draft = places[key] as? [String: Any] ?? [:]
                    let old = (draft["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    draft["name"] = place
                    places[key] = draft; placesChanged = true
                    networkLine(.changed, String(localized: "place name", comment: "Settings import preview: the This place card's name"), old ?? String(localized: "none", comment: "Settings import: no value"), place)
                }
                if network.providerHere == true, newCredit.networkKey != key {
                    newCredit.networkKey = key; newCredit.networkName = network.name ?? knownNetworks[key]
                    line(.changed, .networks, String(localized: "\(name) is your provider’s network", comment: "Settings import preview"), joining: joining)
                }
                for limit in network.appLimits ?? [] { mergeLimit(limit, network: key, area: .networks, joining: joining, label: name) }
            }
        }
        next.quotas = limits.isEmpty ? nil : limits
        if newCredit != (credit ?? CreditSettings()), let data = try? JSONEncoder().encode(newCredit) { changes[CreditSettings.key] = .set(.data(data)); relaunch = true }
        if plansChanged { changes[PlanSpeeds.key] = .set(.numbers(plans)); relaunch = true }
        if fastChanged { changes["uploadFastNetworks"] = .set(.strings(fast.sorted())) }
        if placesChanged, let data = try? JSONSerialization.data(withJSONObject: places, options: [.sortedKeys]) { changes["share.places"] = .set(.data(data)) }

        // What the file held that isn't applied.
        for area in backup.areas where !ticked.contains(area) {
            notes.append(area == .consent
                ? String(localized: "Settings that contact other services weren’t turned on. Tick them to import them.", comment: "Settings import note")
                : String(localized: "Left out by you: \(area.title)", comment: "Settings import note: an area the person unticked"))
        }
        if ticked.contains(.protection), let name = backup.value(at: "protection.blocklistName")?.string, !name.isEmpty {
            notes.append(String(localized: "Your blocklist was \(name). Import it again in Protection.", comment: "Settings import note"))
            if next.blockedDomains?.isEmpty != false { wants.insert(.blocklist) }
        }
        for path in backup.notImported { notes.append(String(localized: "Not imported: \(path), which stays on each Mac", comment: "Settings import note: a key that never travels")) }
        for path in backup.unknown { notes.append(String(localized: "Not known to this version: \(path)", comment: "Settings import note")) }

        // Warnings: less protected, or connections held.
        let before = SettingsReader(preferences: preferences, defaults: defaults), after = SettingsReader(preferences: next, defaults: defaultsNow)
        var turnedOff: [String] = []
        for path in ["protection.threats", "protection.agentGuard", "budget.switchToEssentialsOnMetered", "updaters.pauseUpdaters", "updaters.pauseCloudSync"] {
            guard let entry = SettingsFile.entry(path) else { continue }
            if before.current(entry).bool == true, after.current(entry).bool == false { turnedOff.append(entry.title) }
        }
        if !turnedOff.isEmpty { warnings.append(String(localized: "This import turns off: \(turnedOff.joined(separator: ", ")).", comment: "Settings import warning; a list of settings follows")) }
        if let entry = SettingsFile.entry("killSwitch.enabled"), before.current(entry).bool == false, after.current(entry).bool == true {
            warnings.append(String(localized: "This import turns on the VPN kill switch: new connections wait while the VPN is down.", comment: "Settings import warning"))
        }
        if !Self.allowsNewApps(preferences), Self.allowsNewApps(next) {
            warnings.append(String(localized: "This import allows new apps without asking.", comment: "Settings import warning"))
        }

        // Wishes that need this Mac.
        if ticked.contains(.awake), ["awake.lidBatteryFloor", "awake.lidMaxHours", "awake.lidOnlyOnPower"].contains(where: { backup.value(at: $0) != nil }),
           lines.contains(where: { $0.area == .awake }) { wants.insert(.powerHelper) }
        if let entry = SettingsFile.entry("calls.meetingCheck"), after.current(entry).bool == true, ticked.contains(.calls) { wants.insert(.calendar) }
        if let entry = SettingsFile.entry("streaming.obs"), after.current(entry).bool == true, before.current(entry).bool == false { wants.insert(.obsPassword) }

        result = next
        defaultsChanges = changes
        self.lines = lines
        self.warnings = warnings
        self.notes = notes
        rules = rulesPlan
        needsRelaunch = relaunch
        self.wants = wants
    }

    static func allowsNewApps(_ preferences: SavedPreferences) -> Bool { preferences.askNewApps != true && preferences.defaultAllow }

    static func leftAsIs(_ setting: String, _ value: String) -> String {
        String(localized: "\(setting): left as it is, “\(value)” isn’t a choice", comment: "Settings import note: a value this version doesn't accept")
    }
    static func listItem(_ item: String, _ path: String) -> String {
        path == "dns.excluded" ? DNSResolverChoice.from(id: item)?.name ?? item : item
    }
    static func same(_ a: SettingsValue, _ b: SettingsValue) -> Bool {
        if let x = a.number, let y = b.number { return x == y }
        return a == b
    }
    static func stored(_ value: SettingsValue, _ kind: SettingsKind) -> SettingsStored {
        switch kind {
        case .bool: .bool(value.bool ?? false)
        case .int, .intChoice: .int(value.int ?? 0)
        case .double: .double(value.number ?? 0)
        case .choice, .text: .string(value.string ?? "")
        case .list: .strings(value.strings ?? [])
        }
    }
    /// A value as the preview shows it.
    public static func show(_ value: SettingsValue, _ kind: SettingsKind) -> String {
        switch kind {
        case .bool: value.bool == true ? String(localized: "On", comment: "A setting's value") : String(localized: "Off", comment: "A setting's value")
        case .int(_, _, _, let unit), .intChoice(_, _, let unit): unit.format(value.number ?? 0)
        case .double(_, _, let unit): unit.format(value.number ?? 0)
        case .choice(_, _, let name): name(value.string ?? "")
        case .text(_, _, let secret, _):
            secret ? ((value.string ?? "").isEmpty ? String(localized: "none", comment: "Settings import: no value") : String(localized: "set", comment: "Settings import: a secret value is set, not shown")) : "“\(value.string ?? "")”"
        case .list: (value.strings ?? []).joined(separator: ", ")
        }
    }
}

/// An inverse of a local import. Stores only fields the import changed, including fields which were absent before.
public struct SettingsImportRecovery: Codable {
    private struct Field: Codable {
        let name: String
        let previous: Data?
    }

    private let preferences: [Field]
    private let defaults: [Field]
    public let needsRelaunch: Bool
    private let network: String?

    public init(before: SavedPreferences, defaults: [String: Any], plan: SettingsImportPlan, network: String? = nil) throws {
        let previous = try Self.fields(before), next = try Self.fields(plan.result)
        preferences = try Set(previous.keys).union(next.keys).sorted().compactMap { name in
            guard (previous[name] as? NSObject) != (next[name] as? NSObject) else { return nil }
            return Field(name: name, previous: try previous[name].map {
                try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys])
            })
        }
        self.defaults = try plan.defaultsChanges.keys.sorted().map { name in
            Field(name: name, previous: try defaults[name].map {
                try PropertyListSerialization.data(fromPropertyList: ["value": $0], format: .binary, options: 0)
            })
        }
        needsRelaunch = plan.needsRelaunch
        self.network = network
    }

    public func restoring(_ current: SavedPreferences, network: String? = nil) throws -> SavedPreferences {
        var fields = try Self.fields(current)
        for field in preferences {
            fields[field.name] = try field.previous.map { try JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
        }
        var result = try JSONDecoder().decode(SavedPreferences.self, from: JSONSerialization.data(withJSONObject: fields))
        if network != self.network {
            result.limitGB = network.flatMap { result.networkLimits?[$0] } ?? current.limitGB
            result.budgetCycle = network.flatMap { result.networkCycles?[$0] }
        }
        return result
    }

    public func restoreDefaults(in target: UserDefaults) throws {
        let values = try defaults.map { field in
            let box = try field.previous.map { try PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
            return (field.name, (box as? [String: Any])?["value"])
        }
        for (name, value) in values {
            if let value { target.set(value, forKey: name) }
            else { target.removeObject(forKey: name) }
        }
    }

    private static func fields(_ preferences: SavedPreferences) throws -> [String: Any] {
        let data = try JSONEncoder().encode(preferences)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return fields
    }
}
