import Foundation
@preconcurrency import NetworkExtension
import SystemExtensions
import Observation

/// Owns the explicit, user-initiated installation of the signed filter.
/// Never installs anything on launch or reports a source-only build as protected.
@MainActor @Observable
public final class FilterController: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
    public let eventJournal = FilterEventJournal()
    public let approvals = ApprovalCenter()
    public private(set) var enabled = false
    public private(set) var extensionEnabled = false
    public private(set) var busy = false
    public private(set) var message: String?
    public var active: Bool { enabled && extensionEnabled }
    public var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/co.seifi.kilobat.filter.systemextension").path)
    }
    private var policyPolling: Task<Void, Never>?
    private var eventPolling: Task<Void, Never>?
    private var configuration: [String: Any] = [:]
    private var activationRequest: OSSystemExtensionRequest?
    private var removal: (request: OSSystemExtensionRequest, done: CheckedContinuation<Bool, Never>)?
    private var lastPolicy: Data?
    private var pendingPolicy: [String: Any]?
    private let manager = NEFilterManager.shared()
    public static let identifier = "co.seifi.kilobat.filter"

    public override init() {
        super.init()
        if bundled {
            refresh()
            eventPolling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard self != nil else { return }
                    if let self, self.active { self.eventJournal.refresh() }
                }
            }
        }
    }

    isolated deinit { eventPolling?.cancel(); policyPolling?.cancel() }

    /// Policy enforcement must keep working with every app window closed.
    public func observe(_ store: TrafficStore) {
        guard policyPolling == nil else { return }
        policyPolling = Task { [weak self, weak store] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, let store else { return }
                store.reloadPreferences()
                self.sync(preferences: store.preferences, budgetReached: store.limitFraction >= 1)
                // Polling is also how the filter knows someone is here to answer, so it only runs while asking.
                tick += 1
                if self.active && store.preferences.askNewApps == true && store.preferences.profile != .unrestricted {
                    if tick % 2 == 0 { await self.approvals.poll() }
                } else if !self.approvals.pending.isEmpty { self.approvals.clear() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    public func refresh() {
        guard bundled else { return }
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.message = error.localizedDescription; return }
                self.enabled = self.manager.isEnabled
                let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
                request.delegate = self
                OSSystemExtensionManager.shared.submitRequest(request)
            }
        }
    }

    public func activate(preferences: SavedPreferences, budgetReached: Bool) {
        guard bundled else { message = "This build has no signed network extension. Use a provisioned build to enable filtering."; return }
        configuration = policy(preferences, budgetReached: budgetReached)
        busy = true
        message = "Approve Kilobat in System Settings → General → Login Items & Extensions → Network Extensions."
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    public func sync(preferences: SavedPreferences, budgetReached: Bool) {
        guard bundled, active || busy else { return }
        let next = policy(preferences, budgetReached: budgetReached)
        let encoded = try? JSONSerialization.data(withJSONObject: next, options: .sortedKeys)
        if busy { pendingPolicy = next; return }
        guard encoded != lastPolicy else { return }
        configuration = next
        save(enabled: true)
    }
    public func disable() { guard bundled else { return }; save(enabled: false) }

    /// Takes the filter out completely: its configuration, then the system extension itself. Turning it off
    /// leaves both installed, and a leftover default-deny policy would outlive the app. Returns whether macOS
    /// removed the extension now; it may finish after a restart.
    public func remove() async -> Bool {
        guard bundled, removal == nil else { return false }
        busy = true
        let manager = manager
        _ = await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            // NetworkExtension may answer on its own queue, so these must not be main-actor closures.
            manager.loadFromPreferences { @Sendable _ in manager.removeFromPreferences { @Sendable _ in done.resume() } }
        }
        enabled = false; lastPolicy = nil
        let removed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
            request.delegate = self
            removal = (request, done)
            OSSystemExtensionManager.shared.submitRequest(request)
        }
        busy = false
        extensionEnabled = false
        message = removed ? "Network filter removed." : "The network filter is turned off and will be removed after a restart."
        return removed
    }

    /// Answers an approval: releases the held connections and saves the rule in the current profile.
    public func decide(_ approval: PendingApproval, allowed: Bool, minutes: Int? = nil, store: TrafficStore) {
        if let minutes { store.setTemporary(approval.app, allowed: allowed, minutes: minutes) } else { store.setAllowed(approval.app, allowed) }
        Task { await approvals.decide(approval.app, allowed: allowed) }
    }

    func policy(_ preferences: SavedPreferences, budgetReached: Bool) -> [String: Any] { Self.policy(preferences, budgetReached: budgetReached) }
    /// The configuration the filter enforces; `FilterPolicy` reads it back for the filter and the doctor alike.
    public nonisolated static func policy(_ preferences: SavedPreferences, budgetReached: Bool) -> [String: Any] {
        ["enabled": true, "unrestricted": preferences.profile == .unrestricted, "profile": preferences.profile.rawValue,
         "defaultAllow": preferences.defaultAllow,
         "rules": preferences.rules[preferences.profile.rawValue] ?? [:],
         "budgetReached": budgetReached && preferences.profile != .unrestricted,
         "connectionRules": (try? JSONEncoder().encode((preferences.connectionRules ?? []).filter { $0.profile == preferences.profile.rawValue }))?.base64EncodedString() ?? "",
         "temporary": (preferences.temporaryRules ?? [:]).filter { $0.key.hasPrefix(preferences.profile.rawValue + "|") }.reduce(into: [String: [String: Any]]()) { output, item in
             output[String(item.key.dropFirst(preferences.profile.rawValue.count + 1))] = ["allowed": item.value.allowed, "expires": item.value.expires.timeIntervalSince1970]
         },
         "blockedDomains": (preferences.blockedDomains ?? []) + (preferences.blockedHosts ?? []), "domainExceptions": preferences.domainExceptions ?? [:],
         "askNewApps": preferences.askNewApps == true, "allowApple": preferences.allowApple == true]
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
                self.manager.localizedDescription = "Kilobat app access rules"
                self.manager.isEnabled = enabled
                self.manager.saveToPreferences { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error { self.fail(error); return }
                        self.enabled = enabled
                        self.lastPolicy = try? JSONSerialization.data(withJSONObject: self.configuration, options: .sortedKeys)
                        self.busy = false
                        self.message = enabled ? "Network filter enabled." : "Network filter disabled. All traffic allowed."
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
    private func fail(_ error: Error) { pendingPolicy = nil; busy = false; message = error.localizedDescription; refresh() }
    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        message = "Waiting for approval in System Settings → General → Login Items & Extensions."
    }
    public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        if let removal, removal.request === request { self.removal = nil; removal.done.resume(returning: false); return }
        busy = false; message = error.localizedDescription; activationRequest = nil
    }
    public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if let removal, removal.request === request { self.removal = nil; removal.done.resume(returning: result == .completed); return }
        guard request === activationRequest else { return }
        activationRequest = nil
        if result == .completed { extensionEnabled = true; save(enabled: true) }
        else { busy = false; message = "Restart your Mac to finish installing the network extension." }
    }
    public func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let ours = properties.filter { $0.bundleIdentifier == Self.identifier && $0.isEnabled }
        extensionEnabled = !ours.isEmpty
        // An app update ships a newer filter, but macOS keeps running the old one until asked to replace it.
        guard extensionEnabled, activationRequest == nil, let bundled = Self.bundledVersion, !ours.contains(where: { $0.bundleVersion == bundled }) else { return }
        let update = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        update.delegate = self
        activationRequest = update
        OSSystemExtensionManager.shared.submitRequest(update)
    }
    static var bundledVersion: String? {
        Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension"))?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}
