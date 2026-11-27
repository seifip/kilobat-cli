import Foundation
import Security
@preconcurrency import NetworkExtension
import SystemExtensions
import Observation

/// What to tell someone while macOS wants their approval for the filter, and after a removal.
public enum FilterApproval {
    /// Apple's support article "If you get an alert about a system extension on Mac" (support.apple.com/en-us/120363)
    /// says macOS Sequoia 15 and later ask in Login Items & Extensions, earlier versions in Privacy & Security.
    public static func usesLoginItemsPane(macOS major: Int) -> Bool { major >= 15 }
    /// Version-neutral on purpose: Apple's documentation does not describe the exact macOS 14 steps, so the sentence
    /// names no pane path that could be wrong on either version. The button next to it opens the right pane.
    public static func instruction(macOS major: Int) -> String {
        String(localized: "Open System Settings, where macOS asks you to allow Kilobat’s network extension.", comment: "Filter setup: where to approve the network extension; the same sentence for every macOS version")
    }
    /// The pane to open on macOS 14; on 15 and later the app opens Login Items & Extensions itself.
    public static let privacySecurityURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security")
    /// A sentence for a system-extension error, instead of "The operation couldn’t be completed. (OSSystemExtensionErrorDomain error 4.)".
    public static func describe(_ error: Error) -> String {
        let error = error as NSError
        guard error.domain == OSSystemExtensionErrorDomain, let code = OSSystemExtensionError.Code(rawValue: error.code) else { return error.localizedDescription }
        switch code {
        case .requestCanceled: return String(localized: "The request was cancelled. Nothing changed.", comment: "Network filter: the system extension request was cancelled")
        case .authorizationRequired: return String(localized: "macOS needs an administrator to approve this. Try again and enter an administrator’s password.", comment: "Network filter error")
        case .forbiddenBySystemPolicy: return String(localized: "This Mac’s settings don’t allow new system extensions. If it is managed by an organisation, ask its administrator.", comment: "Network filter error")
        case .unsupportedParentBundleLocation: return String(localized: "Move Kilobat to the Applications folder, open it from there, and try again.", comment: "Network filter error: the app must run from /Applications")
        case .missingEntitlement, .codeSignatureInvalid, .validationFailed, .extensionNotFound:
            return String(localized: "This copy of Kilobat can’t install its network filter. Download Kilobat again from kilobat.app.", comment: "Network filter error: unsigned or damaged copy")
        default: return error.localizedDescription
        }
    }
    public static func isMissingEntitlement(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == OSSystemExtensionErrorDomain && error.code == OSSystemExtensionError.Code.missingEntitlement.rawValue
    }
    /// What Settings shows after "Remove network filter…". `detail` is the reason when it failed, if one is known.
    public static func removalNotice(_ result: FilterController.RemovalResult, detail: String?) -> String {
        switch result {
        case .removed: return String(localized: "Network filter removed.")
        case .restartRequired: return String(localized: "The network filter is turned off and will be removed after a restart.")
        case .failed:
            let base = String(localized: "The network filter couldn’t be removed.", comment: "Settings: removing the network filter failed")
            return detail.map { base + " " + $0 } ?? base
        }
    }
    /// Uninstalling goes on only once the filter is out (or will be after a restart): a leftover policy would outlive the app.
    public static func uninstallMayContinue(after result: FilterController.RemovalResult) -> Bool { result != .failed }
}

/// Owns the explicit, user-initiated installation of the signed filter.
/// Never installs anything on launch or reports a source-only build as protected.
@MainActor @Observable
public final class FilterController: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
    public let eventJournal = FilterEventJournal(recover: true)
    public let approvals = ApprovalCenter()
    /// Alert mode's apps to review.
    public let newApps = NewAppReview()
    /// This session's connection log, in memory only.
    public let connectionLog = ConnectionLogStore()
    /// How often each rule decided a connection.
    public let ruleHits = RuleHitStore()
    public private(set) var enabled = false
    public private(set) var extensionEnabled = false
    public private(set) var busy = false
    public private(set) var message: String?
    /// macOS is waiting for the person to approve the extension in System Settings.
    public private(set) var awaitingApproval = false
    /// The last attempt's failure, in words; nil once a new attempt starts or one succeeds.
    public private(set) var failure: String?
    /// This copy isn't signed for system extensions (the last failure was the missing entitlement).
    public private(set) var missingEntitlement = false
    public var active: Bool { enabled && extensionEnabled }
    public var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/co.seifi.kilobat.filter.systemextension").path)
    }
    /// A leftover extension bundle does not grant the host permission to manage it.
    public var canManage: Bool { bundled && Self.hostHasFilterEntitlements }
    private static let hostHasFilterEntitlements: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let capabilities = entitlements["com.apple.developer.networking.networkextension"] as? [String] else { return false }
        return capabilities.contains(where: { ["content-filter-provider-systemextension", "content-filter-provider"].contains($0) }) &&
            (entitlements["com.apple.developer.system-extension.install"] as? Bool == true)
    }()
    private var policyPolling: Task<Void, Never>?
    private var eventPolling: Task<Void, Never>?
    private var configuration: [String: Any] = [:]
    private var activationRequest: OSSystemExtensionRequest?
    public enum RemovalResult: Sendable { case removed, restartRequired, failed }
    private var removal: (request: OSSystemExtensionRequest, done: CheckedContinuation<RemovalResult, Error>)?
    private var explicitActivation = false
    private var attemptedUpgrade: String?
    private var lastPolicy: Data?
    private var pendingPolicy: [String: Any]?
    /// The last inputs `sync` saw, so a kill-switch change goes to the filter at once rather than on the next tick.
    private var lastInputs: (preferences: SavedPreferences, budgetReached: Bool, quotaReached: [String], metered: Bool)?
    /// The VPN kill switch, set by the app's monitor as the VPN goes down and comes back; saved to the filter right away.
    public var killSwitch = KillSwitchPolicy() {
        didSet {
            if !seeding { killSwitchDelivered = true }
            guard killSwitch != oldValue, let inputs = lastInputs else { return }
            sync(preferences: inputs.preferences, budgetReached: inputs.budgetReached, quotaReached: inputs.quotaReached, metered: inputs.metered)
        }
    }
    /// Protection's switches, allowed sites and index digest, set by the app (which applies Pro); saved to the filter right away.
    public var protection = ProtectionSettings() {
        didSet {
            if !seeding { protectionDelivered = true }
            guard protection != oldValue, let inputs = lastInputs else { return }
            sync(preferences: inputs.preferences, budgetReached: inputs.budgetReached, quotaReached: inputs.quotaReached, metered: inputs.metered)
        }
    }
    private let manager = NEFilterManager.shared()
    public static let identifier = "co.seifi.kilobat.filter"

    /// False until the filter's saved configuration and the extension's state have been read once at launch. Until
    /// then `active` is false whatever the truth, so nothing should conclude "the filter is off" from it.
    public private(set) var stateKnown = false
    @ObservationIgnored private var seeding = false
    @ObservationIgnored private var killSwitchDelivered = false
    @ObservationIgnored private var protectionDelivered = false
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?

    /// The kill switch and Protection as the filter last got them, from its saved configuration: what stays in force
    /// at launch until the app's monitors have looked for themselves.
    public nonisolated static func savedState(_ configuration: [String: Any]?) -> (killSwitch: KillSwitchPolicy, protection: ProtectionSettings) {
        (KillSwitchPolicy(configuration?["killSwitch"] as? [String: Any]), ProtectionSettings(configuration?["protection"] as? [String: Any]))
    }

    public override init() {
        super.init()
        // A build without the filter has nothing to wait for.
        if !canManage { stateKnown = true }
        if canManage {
            refresh()
            // Switched off or removed in System Settings: read it again, so a later sync doesn't switch it back on. The
            // app's own saves post this too and end in a refresh of their own.
            configurationObserver = NotificationCenter.default.addObserver(forName: .NEFilterConfigurationDidChange, object: manager, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.busy else { return }
                    self.refresh(allowUpgrade: false)
                }
            }
            // Should macOS never answer, the monitors still start; with `active` false nothing is saved meanwhile.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.stateKnown = true
            }
            eventPolling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5), tolerance: .seconds(1)) } catch { return }
                    guard self != nil else { return }
                    if let self, self.active { self.eventJournal.refresh() }
                }
            }
        }
    }

    isolated deinit {
        eventPolling?.cancel(); policyPolling?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Policy enforcement must keep working with every app window closed.
    public func observe(_ store: TrafficStore) {
        guard policyPolling == nil else { return }
        policyPolling = Task { [weak self, weak store] in
            var tick = 0
            var schedule = PolicySyncSchedule()
            while !Task.isCancelled {
                guard let self, let store else { return }
                store.reloadPreferences()
                // "Until quit" answers end with their process.
                if tick % 5 == 0, var temporary = store.preferences.temporaryRules, temporary.values.contains(where: { $0.pid != nil }),
                   TemporaryRule.pruneExited(&temporary, alive: Self.processAlive) {
                    store.preferences.temporaryRules = temporary.isEmpty ? nil : temporary
                }
                // The budget and app limits scan usage history: only for a filter that takes a policy, and only on a
                // change or every few seconds (`PolicySyncSchedule` lists what counts as a change).
                if schedule.due(filterWantsPolicy: self.bundled && (self.active || self.busy),
                                inputs: { PolicySyncSchedule.Inputs(preferences: store.preferences, network: store.networkKey, metered: store.metered) }) {
                    self.sync(preferences: store.preferences, budgetReached: store.budgetBlocksNewConnections, quotaReached: store.quotaReached, metered: store.metered)
                }
                // Polling is also how the filter knows someone is here to answer, so it only runs while asking.
                tick += 1
                if self.active && NewAppPolicy.asks(store.preferences) {
                    if tick % 2 == 0 { await self.approvals.poll() }
                } else if !self.approvals.pending.isEmpty { self.approvals.clear() }
                // The connection log and rule hits, every five seconds while the filter runs. Asking keeps the log
                // recording; pausing it stops the filter's copy too.
                if tick % 5 == 2, self.active {
                    let record = store.preferences.connectionLog != false
                    if let snapshot = await self.approvals.connectionLog(record: record, browsers: store.preferences.connectionLogBrowsers == true) {
                        self.ruleHits.add(snapshot.hits)
                        if record { self.connectionLog.take(snapshot) } else { self.connectionLog.clear() }
                    }
                } else if tick % 5 == 2, !self.connectionLog.entries.isEmpty { self.connectionLog.clear() }
                // Counts that arrived since the last save reach the disk within a minute, for the CLI and MCP.
                if tick % 60 == 30 { self.ruleHits.save() }
                // Alert mode's list, every ten seconds while it's the mode.
                if tick % 10 == 0, self.active, store.preferences.profile != .unrestricted, NewAppPolicy.mode(store.preferences) == .alert,
                   let sightings = await self.approvals.newApps() {
                    self.newApps.merge(sightings)
                }
                do { try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(200)) } catch { return }
            }
        }
    }

    public func refresh() { refresh(allowUpgrade: true) }

    private var upgradeDiscovery: OSSystemExtensionRequest?
    private func refresh(allowUpgrade: Bool) {
        guard canManage else { return }
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.message = error.localizedDescription; self.stateKnown = true; return }
                self.enabled = self.manager.isEnabled
                // Once, at launch: keep what the filter was last told until the monitors have read the VPN and the lists.
                if !self.stateKnown {
                    let saved = Self.savedState(self.manager.providerConfiguration?.vendorConfiguration)
                    self.seeding = true
                    if !self.killSwitchDelivered { self.killSwitch = saved.killSwitch }
                    if !self.protectionDelivered { self.protection = saved.protection }
                    self.seeding = false
                }
                let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
                request.delegate = self
                if allowUpgrade { self.upgradeDiscovery = request }
                OSSystemExtensionManager.shared.submitRequest(request)
            }
        }
    }

    public func activate(preferences: SavedPreferences, budgetReached: Bool, quotaReached: [String] = [], metered: Bool) {
        guard !busy else { return }
        guard canManage else { message = String(localized: "This build cannot manage the network filter. Use the signed release to change filtering."); return }
        lastInputs = (preferences, budgetReached, quotaReached, metered)
        configuration = policy(preferences, budgetReached: budgetReached, quotaReached: quotaReached, metered: metered)
        busy = true
        failure = nil; awaitingApproval = false
        message = FilterApproval.instruction(macOS: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        explicitActivation = true
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    public func sync(preferences: SavedPreferences, budgetReached: Bool, quotaReached: [String] = [], metered: Bool) {
        lastInputs = (preferences, budgetReached, quotaReached, metered)
        guard canManage, active || busy else { return }
        let next = policy(preferences, budgetReached: budgetReached, quotaReached: quotaReached, metered: metered)
        let encoded = try? JSONSerialization.data(withJSONObject: next, options: .sortedKeys)
        if busy { pendingPolicy = next; return }
        guard encoded != lastPolicy else { return }
        configuration = next
        save(enabled: true)
    }
    /// True only after macOS accepted the saved configuration; initiating a save is not an applied acknowledgement.
    public func teamsRulesApplied(_ expected: [String]) -> Bool {
        if expected.isEmpty { return true }
        guard active, !busy, let lastPolicy,
              let saved = try? JSONSerialization.jsonObject(with: lastPolicy) as? [String: Any] else { return false }
        return Set(saved["teamsBlockedApps"] as? [String] ?? []) == Set(expected)
    }
    public func disable() { guard canManage, !busy else { return }; save(enabled: false) }

    /// Takes the filter out completely: its configuration, then the system extension itself. Turning it off
    /// leaves both installed, and a leftover default-deny policy would outlive the app.
    public func remove() async -> RemovalResult {
        guard canManage, !busy else { return .failed }
        busy = true
        failure = nil
        defer { busy = false; pendingPolicy = nil }
        do {
            let manager = manager
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                manager.loadFromPreferences { @Sendable error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                manager.removeFromPreferences { @Sendable error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
            enabled = false; lastPolicy = nil
            let result: RemovalResult = try await withCheckedThrowingContinuation { done in
                let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
                request.delegate = self
                removal = (request, done)
                OSSystemExtensionManager.shared.submitRequest(request)
            }
            switch result {
            case .removed:
                extensionEnabled = false
                message = String(localized: "Network filter removed.")
            case .restartRequired:
                message = String(localized: "The network filter is turned off and will be removed after a restart.")
            case .failed: break
            }
            return result
        } catch {
            failure = FilterApproval.describe(error); message = nil
            refresh(allowUpgrade: false)
            return .failed
        }
    }

    /// Answers an approval: releases the held connections and saves the rule in the current profile.
    public func decide(_ approval: PendingApproval, allowed: Bool, minutes: Int? = nil, store: TrafficStore) {
        answer(approval, allowed: allowed) {
            if let minutes { store.setTemporary(approval.app, allowed: allowed, minutes: minutes) } else { store.setAllowed(approval.app, allowed) }
        }
    }

    /// The same for a chosen duration. Once saves nothing: the held connections go, and the filter's recent answer
    /// covers the app's next half-minute. Until quit binds the rule to the process that asked.
    public func decide(_ approval: PendingApproval, allowed: Bool, duration: ApprovalDuration, store: TrafficStore) {
        if approval.site != nil { decideDestination(approval, allowed: allowed, scope: .domain, duration: duration, store: store); return }
        answer(approval, allowed: allowed) {
            switch duration {
            case .forever: store.setAllowed(approval.app, allowed)
            case .hour: store.setTemporary(approval.app, allowed: allowed, minutes: 60)
            case .untilQuit: store.setUntilQuit(approval.app, allowed: allowed, pid: approval.pid)
            case .once: break
            }
        }
    }

    /// Answers for everything the app's developer signed: a `team:` rule in the current profile, which this app and
    /// its helpers (now and later) follow while they have no rule of their own. Only for a Team ID the filter verified.
    public func decideDeveloper(_ approval: PendingApproval, allowed: Bool, store: TrafficStore) {
        guard DeveloperRule.eligible(identifier: approval.app, team: approval.team), let team = approval.team else { return }
        answer(approval, allowed: allowed) {
            DeveloperRule.remember(DeveloperName.name(signer: approval.signer, team: team), team: team, in: &store.preferences)
            store.setAllowed(DeveloperRule.key(team), allowed)
        }
    }

    /// Answers a prompt about a new destination: a destination rule for the hosts shown (exactly) or the whole site
    /// (with its subdomains), or, for anywhere, the app stops asking (allow) or is blocked (block). Once saves nothing;
    /// the hour makes the rule lapse. Until quit isn't offered for destinations: the rule would outlive the process anyway.
    public func decideDestination(_ approval: PendingApproval, allowed: Bool, scope: ApprovalAnswer.Scope, duration: ApprovalDuration, store: TrafficStore) {
        answer(approval, allowed: allowed, scope: scope) {
            for rule in Self.destinationRules(approval, allowed: allowed, scope: scope, duration: duration, profile: store.preferences.profile.rawValue) {
                store.preferences.connectionRules = (store.preferences.connectionRules ?? []) + [rule]
            }
            guard scope == .anywhere, duration != .once else { return }
            if duration == .hour { store.setTemporary(approval.app, allowed: allowed, minutes: 60); return }
            if allowed { AskDestinations.set(approval.app, on: false, in: &store.preferences) } else { store.setAllowed(approval.app, false) }
        }
    }

    /// The destination rules an answer saves: none for once or anywhere.
    public nonisolated static func destinationRules(_ approval: PendingApproval, allowed: Bool, scope: ApprovalAnswer.Scope, duration: ApprovalDuration,
                                                    profile: String, now: Date = Date()) -> [ConnectionRule] {
        guard duration != .once, let site = approval.site else { return [] }
        let expires = duration == .hour ? now.addingTimeInterval(3_600) : nil
        switch scope {
        case .anywhere: return []
        case .domain: return [ConnectionRule(app: approval.app, host: site, direction: "outgoing", allowed: allowed, profile: profile, expires: expires)]
        case .host:
            let hosts = Array(Set(approval.destinations.compactMap { $0.host ?? $0.address }.compactMap(ConnectionRule.validDestination))).sorted()
            return hosts.map { ConnectionRule(app: approval.app, host: $0, direction: "outgoing", allowed: allowed, profile: profile, expires: expires, exact: true) }
        }
    }

    /// Sends the answer, then saves the rule: unless the prompt changed after it was shown, when the window asks
    /// again with what it shows now. A prompt that's gone, or a filter that didn't answer, still gets the rule.
    private func answer(_ approval: PendingApproval, allowed: Bool, scope: ApprovalAnswer.Scope? = nil, save: @escaping @MainActor () -> Void) {
        Task {
            let outcome = await approvals.decide(approval, allowed: allowed, scope: scope)
            if outcome != .refused || !approvals.pending.contains(where: { $0.id == approval.id }) { save() }
        }
    }

    /// Whether a process still runs: signal 0 checks without sending anything; EPERM means it runs as another user.
    public nonisolated static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func policy(_ preferences: SavedPreferences, budgetReached: Bool, quotaReached: [String] = [], metered: Bool = false) -> [String: Any] {
        Self.policy(preferences, budgetReached: budgetReached, quotaReached: quotaReached, metered: metered, killSwitch: killSwitch, protection: protection)
    }
    /// The configuration the filter enforces; `FilterPolicy` reads it back for the filter and the doctor alike.
    /// `metered` is the current network's effective cost, which decides whether updaters are paused.
    /// The budget, app-limit and metered-pause fields are what the app worked out just now; `stateLease` says how long
    /// the filter may go on applying them without hearing from the app (`boot` and `uptime` are when it is issued).
    public nonisolated static func policy(_ preferences: SavedPreferences, budgetReached: Bool, quotaReached: [String] = [], metered: Bool = false,
                                          killSwitch: KillSwitchPolicy = KillSwitchPolicy(), protection: ProtectionSettings = ProtectionSettings(),
                                          boot: String = StateLease.currentBoot, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any] {
        let budget = budgetReached && preferences.profile != .unrestricted
        let quota = preferences.profile == .unrestricted ? [] : quotaReached.sorted()
        let updaters = UpdaterPause.active(preferences, metered: metered)
        let cloud = CloudSyncPause.active(preferences, metered: metered)
        var configuration: [String: Any] = ["enabled": true, "unrestricted": preferences.profile == .unrestricted, "profile": preferences.profile.rawValue,
         "defaultAllow": preferences.defaultAllow,
         "rules": preferences.rules[preferences.profile.rawValue] ?? [:],
         "budgetReached": budget,
         "quotaReached": quota,
         "updatersPaused": updaters,
         "syncPaused": cloud,
         "connectionRules": (try? JSONEncoder().encode((preferences.connectionRules ?? []).filter { $0.profile == preferences.profile.rawValue }))?.base64EncodedString() ?? "",
         "temporary": (preferences.temporaryRules ?? [:]).filter { $0.key.hasPrefix(preferences.profile.rawValue + "|") }.reduce(into: [String: [String: Any]]()) { output, item in
             var rule: [String: Any] = ["allowed": item.value.allowed, "expires": item.value.expires.timeIntervalSince1970]
             if let pid = item.value.pid { rule["pid"] = NSNumber(value: pid) }
             output[String(item.key.dropFirst(preferences.profile.rawValue.count + 1))] = rule
         },
         "blockedDomains": (preferences.blockedDomains ?? []) + (preferences.blockedHosts ?? []), "domainExceptions": preferences.domainExceptions ?? [:],
         "askNewApps": preferences.askNewApps == true, "allowApple": preferences.allowApple == true,
         "alertNewApps": NewAppPolicy.mode(preferences) == .alert,
         "askDestinations": (preferences.askDestinations ?? []).sorted(),
         "killSwitch": killSwitch.configuration, "protection": protection.configuration]
        // Only while something derived is set, so an idle policy doesn't change every quarter of an hour.
        if budget || !quota.isEmpty || updaters || cloud { configuration["stateLease"] = StateLease.issued(boot: boot, uptime: uptime).configuration }
        configuration["teamsBlockedApps"] = TeamsRuleEnforcement.blockedApps()
        return configuration
    }
    private func save(enabled: Bool) {
        busy = true
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.fail(error); return }
                let provider = NEFilterProviderConfiguration()
                provider.filterSockets = true
                provider.filterPackets = false
                provider.filterDataProviderBundleIdentifier = Self.identifier
                provider.vendorConfiguration = self.configuration
                self.manager.providerConfiguration = provider
                self.manager.localizedDescription = String(localized: "Kilobat app access rules")
                self.manager.isEnabled = enabled
                self.manager.saveToPreferences { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error { self.fail(error); return }
                        self.enabled = enabled
                        self.lastPolicy = try? JSONSerialization.data(withJSONObject: self.configuration, options: .sortedKeys)
                        self.busy = false
                        self.failure = nil
                        self.message = enabled ? String(localized: "Network filter enabled.") : String(localized: "Network filter disabled. All traffic allowed.")
                        if enabled, let pending = self.pendingPolicy {
                            self.pendingPolicy = nil
                            let encoded = try? JSONSerialization.data(withJSONObject: pending, options: .sortedKeys)
                            if encoded != self.lastPolicy { self.configuration = pending; self.save(enabled: true) } else { self.refresh() }
                        } else { self.pendingPolicy = nil; self.refresh() }
                    }
                }
            }
        }
    }
    private func fail(_ error: Error) { pendingPolicy = nil; busy = false; awaitingApproval = false; message = nil; failure = FilterApproval.describe(error); missingEntitlement = FilterApproval.isMissingEntitlement(error); refresh() }
    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        awaitingApproval = true
        message = FilterApproval.instruction(macOS: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
    public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        if let removal, removal.request === request { self.removal = nil; removal.done.resume(throwing: error); return }
        guard request === activationRequest else { failure = FilterApproval.describe(error); stateKnown = true; return }
        activationRequest = nil; explicitActivation = false
        fail(error)
    }
    public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if let removal, removal.request === request { self.removal = nil; switch result {
            case .completed: removal.done.resume(returning: .removed)
            case .willCompleteAfterReboot: removal.done.resume(returning: .restartRequired)
            @unknown default: removal.done.resume(throwing: CocoaError(.featureUnsupported))
            }; return }
        guard request === activationRequest else { return }
        awaitingApproval = false
        activationRequest = nil
        let shouldEnable = explicitActivation
        explicitActivation = false
        if result == .completed {
            extensionEnabled = true
            if shouldEnable { save(enabled: true) }
            else { busy = false; pendingPolicy = nil }
        }
        else { busy = false; pendingPolicy = nil; message = String(localized: "Restart your Mac to finish installing the network extension.") }
    }
    public func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let ours = properties.filter { $0.bundleIdentifier == Self.identifier && $0.isEnabled }
        extensionEnabled = !ours.isEmpty
        stateKnown = true
        // An app update ships a newer filter, but macOS keeps running the old one until asked to replace it.
        guard request === upgradeDiscovery else { return }
        upgradeDiscovery = nil
        guard extensionEnabled, !busy, activationRequest == nil, let bundled = Self.bundledVersion, attemptedUpgrade != bundled, !ours.contains(where: { $0.bundleVersion == bundled }) else { return }
        attemptedUpgrade = bundled
        let update = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        update.delegate = self
        busy = true
        activationRequest = update
        OSSystemExtensionManager.shared.submitRequest(update)
    }
    static var bundledVersion: String? {
        Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension"))?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    #if DEBUG
    /// Sample states for snapshots; touches nothing on the system.
    public func preview(message: String? = nil, failure: String? = nil, awaitingApproval: Bool = false) {
        self.message = message; self.failure = failure; self.awaitingApproval = awaitingApproval
    }
    #endif
}
