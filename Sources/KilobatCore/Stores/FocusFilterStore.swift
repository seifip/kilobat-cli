import AppKit
import Foundation
import Observation

/// What a Focus asks of Kilobat while it's on. All off is also what macOS sends when the Focus ends, since it then
/// runs the filter with its parameters' default values.
public struct FocusFilter: Codable, Equatable, Sendable {
    /// The profile to switch to; nil keeps the current one.
    public var profile: NetworkProfile?
    /// Hold the apps in `CallMode.known`, except those the person told call mode to leave alone.
    public var holdApps: Bool
    /// Pause updaters on every network, not only metered ones.
    public var pauseUpdaters: Bool
    public init(profile: NetworkProfile? = nil, holdApps: Bool = false, pauseUpdaters: Bool = false) {
        self.profile = profile; self.holdApps = holdApps; self.pauseUpdaters = pauseUpdaters
    }
    public var isEmpty: Bool { profile == nil && !holdApps && !pauseUpdaters }
    /// Without Pro only switching to Unrestricted works, as in the Shortcuts action; holding apps and pausing updaters are Pro.
    public var free: FocusFilter { FocusFilter(profile: profile == .unrestricted ? .unrestricted : nil) }
}

/// What a Focus changed, saved so it's put back after a quit or a crash.
public struct FocusChanges: Codable, Equatable, Sendable {
    public var filter: FocusFilter
    /// The profile before the Focus switched it; it returns only while `appliedProfile` is still the one in use.
    public var previousProfile: NetworkProfile?
    public var appliedProfile: NetworkProfile?
    /// The apps held now.
    public var holding: [String] = []
    public var since: Date
}

/// Focus filters: a Focus set up in System Settings › Focus switches Kilobat's profile, holds sync and download apps
/// and pauses updaters, and everything goes back when it ends. Apps are held through `CallMode`'s ledger as the
/// `focus` owner, so a call ending never resumes what the Focus holds, and the Focus ending never resumes what a call holds.
@MainActor @Observable public final class FocusFilterStore {
    public static let shared = FocusFilterStore()
    /// Nil while no Focus asks anything of Kilobat.
    public private(set) var state: FocusChanges?
    /// The Focus asked for something that needs Pro, and only the rest was applied.
    public private(set) var refused: FocusFilter?
    /// Whether Pro features may be used: the app answers with the license.
    @ObservationIgnored public var allowed: () -> Bool = { false }
    /// The store whose preferences the Focus changes: the live one, or one that writes them for the app to read.
    @ObservationIgnored public var traffic: () -> TrafficStore = { TrafficStore(startMonitoring: false) }
    /// Bundle IDs, their processes and download rate (nil when unknown): Kilobat's own traffic list adds helpers and
    /// rates the running apps don't show.
    @ObservationIgnored public var processes: () -> [(id: String, pids: [Int32], download: Double?)] = FocusFilterStore.runningApps
    /// Whether a game is in front, so game launchers stay running; see `CallMode.launchers`.
    @ObservationIgnored public var gameInFront: () -> Bool = {
        let front = NSWorkspace.shared.frontmostApplication
        return CallMode.gameInFront(bundleURL: front?.bundleURL, executable: front?.executableURL?.lastPathComponent)
    }
    @ObservationIgnored public var skipped: () -> Set<String> = { Set(UserDefaults.standard.stringArray(forKey: "callModeSkipped") ?? []) }
    /// Apps the person brought to the front during this Focus; they stay running until the next one.
    @ObservationIgnored private var released: Set<String> = []
    /// A Focus has been applied since launch, so the launch check mustn't overrule it.
    @ObservationIgnored private var applied = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    private let file: URL
    private let ledger: URL

    public init(directory: URL? = nil, ledger: URL = CallMode.ledgerURL) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat")
        file = folder.appendingPathComponent("focus.json")
        self.ledger = ledger
        state = StoredJSON.read(file) as FocusChanges?
        // Whatever a previous run held is resumed before this one holds anything; the launch check then holds again
        // if the Focus is still on.
        CallMode.recoverAtLaunch(ledger: ledger)
        if state != nil { state?.holding = [] }
    }

    public var holding: [String] { state?.holding ?? [] }

    /// Applies what the Focus asks, from where things stand: switching between two Focuses keeps the profile from
    /// before the first, and an empty filter puts everything back. Returns false when part of it needed Pro.
    @discardableResult public func apply(_ wanted: FocusFilter, now: Date = Date()) -> Bool {
        applied = true
        let pro = allowed()
        let filter = pro ? wanted : wanted.free
        refused = filter == wanted ? nil : wanted
        var next = state ?? FocusChanges(filter: FocusFilter(), since: now)
        if state == nil { released = [] }
        // Only a profile or the updater pause, now or from before, touches preferences; reading them without the live
        // store loads the whole history, so a Focus that only holds apps doesn't.
        if filter.profile != nil || filter.pauseUpdaters || next.appliedProfile != nil || next.filter.pauseUpdaters {
            let store = traffic()
            var preferences = store.preferences
            if let profile = filter.profile {
                // A profile picked by hand during the Focus is the one to come back to.
                if next.appliedProfile == nil || preferences.profile != next.appliedProfile { next.previousProfile = preferences.profile }
                preferences.profile = profile; next.appliedProfile = profile
            } else if let profile = next.appliedProfile {
                if preferences.profile == profile, let previous = next.previousProfile { preferences.profile = previous }
                next.appliedProfile = nil; next.previousProfile = nil
            }
            preferences.focusPausesUpdaters = filter.pauseUpdaters ? true : nil
            next.filter = filter
            // What's about to change is written down first, and forgotten only after it's put back, so a crash in
            // between still restores it at the next launch.
            if !filter.isEmpty { state = next; save() }
            if preferences != store.preferences { store.preferences = preferences }
        }
        next.filter = filter
        if !filter.holdApps { CallMode.resume(owner: CallMode.focus, ledger: ledger); next.holding = [] }
        state = filter.isEmpty ? nil : next
        if filter.isEmpty { released = [] }
        if filter.holdApps { rescan() } else { save() }
        return refused == nil
    }

    /// At launch: the Focus filter macOS has on now, or nil when none is. A Focus applied since launch wins.
    public func reconcile(_ current: FocusFilter?) {
        guard !applied else { return }
        apply(current ?? FocusFilter())
    }

    /// Kilobat is quitting: nothing stays held or switched while it can't follow the Focus. The next launch applies
    /// the Focus again if it's still on.
    public func quit() {
        guard state != nil else { return }
        apply(FocusFilter())
    }

    /// Holds the known apps that are running and not held yet, and lets go of any the person told call mode to skip.
    /// Game launchers follow call mode's rule: held only while they download and no game is in front, and let go
    /// as soon as one is, since a Focus can last a whole evening.
    public func rescan() {
        guard var current = state, current.filter.holdApps else { return }
        let skip = skipped(), gaming = gameInFront()
        let free = current.holding.filter { skip.contains($0) || (gaming && CallMode.launchers.contains($0)) }
        for name in free { CallMode.resume(app: name, owner: CallMode.focus, ledger: ledger) }
        current.holding.removeAll { free.contains($0) }
        var pids: [String: [Int32]] = [:], downloading: Set<String> = []
        for (id, ids, download) in processes() {
            guard let name = CallMode.name(of: id), !skip.contains(name), !released.contains(name), !current.holding.contains(name) else { continue }
            pids[name, default: []] += ids
            if let download, download >= CallAnalysis.downloadLoad / 2 { downloading.insert(name) }
        }
        for name in CallMode.launchers where gaming || !downloading.contains(name) { pids[name] = nil }
        for (name, ids) in pids.sorted(by: { $0.key < $1.key }) where !CallMode.hold(ids, app: name, owner: CallMode.focus, ledger: ledger).isEmpty {
            current.holding.append(name)
        }
        state = current
        save()
    }

    /// The person brought an app to the front: it runs for the rest of this Focus.
    public func letGo(_ bundleID: String) {
        guard let name = CallMode.name(of: bundleID), var current = state, current.holding.contains(name) else { return }
        CallMode.resume(app: name, owner: CallMode.focus, ledger: ledger)
        released.insert(name); current.holding.removeAll { $0 == name }
        state = current; save()
    }

    /// Picks up apps opened during the Focus, and lets go of one the person switches to.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.rescan()
            }
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let id { self?.letGo(id) } }
        }
    }

    /// One line for Settings, such as “Focus: Work is holding Dropbox”; nil while no Focus asks anything.
    public var summary: String? {
        guard let state else { return refused.map { _ in String(localized: "Focus: this filter needs Kilobat Pro", comment: "Settings line when a Focus filter asked for a Pro feature without Pro") } }
        let head = state.filter.profile.map { String(localized: "Focus: \($0.title)", comment: "Settings line: a Focus switched Kilobat to this profile") }
            ?? String(localized: "Focus", comment: "Settings line: a Focus filter is on and kept the profile")
        var line = head
        if !state.holding.isEmpty {
            let apps = ListFormatter.localizedString(byJoining: state.holding)
            line = String(localized: "\(head) is holding \(apps)", comment: "Settings line: 'Focus: Work is holding Dropbox and Steam'")
        } else if state.filter.holdApps {
            line = String(localized: "\(head) holds sync apps as they open", comment: "Settings line: a Focus will hold sync and download apps, none are running yet")
        }
        if state.filter.pauseUpdaters { line = String(localized: "\(line) · updaters paused", comment: "Settings line: the Focus also pauses updaters") }
        return line
    }

    nonisolated public static func runningApps() -> [(id: String, pids: [Int32], download: Double?)] {
        NSWorkspace.shared.runningApplications.compactMap { app in app.bundleIdentifier.map { ($0, [app.processIdentifier], nil) } }
    }

    private func save() {
        guard let state else { try? FileManager.default.removeItem(at: file); return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: file, options: .atomic)
    }
}
