import Foundation
import Observation

/// A consent-based alternative for a reachable network whose normal portal checks fail.
@MainActor @Observable
public final class PortalAlternative {
    public enum State: Equatable { case hidden, suggested, checking, worked, signIn, failed }
    public private(set) var state: State = .hidden
    public private(set) var signInURL: URL?
    public private(set) var network: String?
    public private(set) var canRemember = false
    private var failures = 0
    private var lastFailure: Date?
    private var dismissed = Set<String>()
    private var generation = UUID()
    private let defaults: UserDefaults
    private let preference = "portal.alternativeNetworks"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func enabled(for key: String, identified: Bool) -> Bool {
        identified && (defaults.stringArray(forKey: preference) ?? []).contains(key)
    }
    public func context(network key: String, identified: Bool, wifi: Bool, reachable: Bool) {
        if key != network { network = key; reset() }
        canRemember = identified && wifi
        if !wifi || !reachable { reset() }
    }
    private func reset() { failures = 0; lastFailure = nil; generation = UUID(); state = .hidden; signInURL = nil }
    public func observe(_ check: PortalCheck, normal: Bool, reachable: Bool, wifi: Bool, now: Date = Date()) {
        guard normal, reachable, wifi, let network, !dismissed.contains(network) else { reset(); return }
        guard check.state == .offline else { reset(); return }
        if let lastFailure, now.timeIntervalSince(lastFailure) < 30 { return }
        lastFailure = now; failures += 1
        if failures >= 2 && state != .checking && state != .worked { state = .suggested }
    }
    public var needsRetry: Bool { failures == 1 && state == .hidden }
    public func dismiss() { if let network { dismissed.insert(network) }; reset() }
    public func tryOnce(probe: @Sendable () async -> PortalCheck = { await CaptivePortal.alternativeCheck() }) async {
        guard state == .suggested || state == .failed else { return }
        let token = generation; state = .checking
        let result = await probe()
        guard token == generation else { return }
        if result.state == .portal {
            signInURL = result.url ?? CaptivePortal.Endpoint.xiaomi.url
            state = .signIn
        } else { state = result.state == .open ? .worked : .failed }
    }
    public func remember() {
        guard state == .worked, canRemember, let network else { return }
        var saved = defaults.stringArray(forKey: preference) ?? []
        if !saved.contains(network) { saved.append(network); defaults.set(saved, forKey: preference) }
        reset()
    }
    public func forgetCurrentNetwork() {
        guard let network else { return }
        defaults.set((defaults.stringArray(forKey: preference) ?? []).filter { $0 != network }, forKey: preference)
        reset()
    }
}
