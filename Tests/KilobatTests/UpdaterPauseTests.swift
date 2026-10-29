import Foundation
import Testing
@testable import KilobatCore

struct UpdaterPauseTests {
    /// The filter's decision for a flow, from the configuration the host saves for it.
    func decide(_ app: String, process: String, via: String? = nil, metered: Bool = true, _ change: (inout SavedPreferences) -> Void = { _ in }) -> (verdict: FilterPolicy.Verdict, reason: FilterPolicy.Reason) {
        var preferences = SavedPreferences()
        preferences.profile = .work
        preferences.defaultAllow = true
        change(&preferences)
        return FilterPolicy(FilterController.policy(preferences, budgetReached: false, metered: metered))
            .decide(.init(app: app, process: process, host: "update.example.com", via: via))
    }

    @Test func helpersMatchByTheIdentifiersInstalledCopiesCarry() {
        // Signing identifiers and executable names from codesign -dv on installed copies.
        let cases: [(app: String, process: String?, helper: String)] = [
            ("com.google.GoogleUpdater", "GoogleUpdater", "google"), ("com.google.Keystone.Agent", "GoogleSoftwareUpdateAgent", "google"),
            ("com.microsoft.autoupdate2", "Microsoft AutoUpdate", "microsoft"), ("com.microsoft.autoupdate.fba", "Microsoft Update Assistant", "microsoft"),
            ("com.apple.softwareupdated", "softwareupdated", "macos"),
            ("com.apple.appstored", "appstored", "app-store"), ("com.apple.appstoreagent", "appstoreagent", "app-store"), ("com.apple.storedownloadd", "storedownloadd", "app-store"),
            ("Autoupdate", "Autoupdate", "sparkle"), ("Autoupdate-555549442401fd215d503466a26c3d081e5a8443", "Autoupdate", "sparkle"),
            ("org.sparkle-project.Sparkle.Updater", "Updater", "sparkle"), ("org.sparkle-project.DownloaderService", "Downloader", "sparkle-downloader"),
            ("ShipIt", "ShipIt", "squirrel"),
            // Kilobat's own app list names processes without a bundle by executable.
            ("process:softwareupdated", nil, "macos"), ("process:ShipIt", nil, "squirrel"), ("process:GoogleUpdater", nil, "google"),
        ]
        for item in cases { #expect(UpdaterHelpers.helper(item.app, process: item.process)?.id == item.helper, "\(item.app)") }
        // An unsigned build of a helper still matches by the executable name the filter reports.
        #expect(UpdaterHelpers.helper("a.b.c", process: "GoogleUpdater")?.id == "google")
        // The apps they update, and generic names, are not updaters.
        for app in ["com.google.Chrome", "com.microsoft.Word", "com.apple.AppStore", "com.tinyspeck.slackmacgap", "company.thebrowser.dia",
                    "com.apple.nsurlsessiond", "process:Updater", "process:Downloader", "org.sparkle-project.InstallerLauncher", ""] {
            #expect(UpdaterHelpers.helper(app, process: "Google Chrome") == nil, "\(app)")
        }
        #expect(UpdaterHelpers.helper(nil, process: "ShipIt") == nil)
        #expect(UpdaterHelpers.helper("com.example.App", process: "") == nil)
    }

    @Test func meteredNetworksPauseUpdatersAndUnmeteredOnesDont() {
        #expect(decide("com.google.GoogleUpdater", process: "GoogleUpdater") == (.block, .updaterPaused("Google Updater")))
        #expect(decide("com.apple.softwareupdated", process: "softwareupdated") == (.block, .updaterPaused("macOS Software Update")))
        #expect(decide("com.google.GoogleUpdater", process: "GoogleUpdater", metered: false) == (.allow, .newAppDefault(true)))
        #expect(decide("com.google.GoogleUpdater", process: "GoogleUpdater") { $0.pauseUpdaters = false } == (.allow, .newAppDefault(true)))
        // Unrestricted allows every connection, even on a hotspot.
        #expect(decide("com.google.GoogleUpdater", process: "GoogleUpdater") { $0.profile = .unrestricted } == (.allow, .unrestricted))
        // It comes after the budget and quotas and before saved rules; a temporary allow lets an update through.
        #expect(decide("com.google.GoogleUpdater", process: "GoogleUpdater") { $0.rules["Work"] = ["com.google.GoogleUpdater": true] }.reason == .updaterPaused("Google Updater"))
        // Allowing Apple software doesn't exempt macOS updates on a metered network.
        #expect(decide("com.apple.softwareupdated", process: "softwareupdated") { $0.defaultAllow = false; $0.allowApple = true }.reason == .updaterPaused("macOS Software Update"))
        // Whole seconds: the policy travels as JSON, which keeps no fractions.
        let temporary = TemporaryRule(allowed: true, expires: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 600).rounded()))
        #expect(decide("com.google.GoogleUpdater", process: "GoogleUpdater") { $0.temporaryRules = ["Work|com.google.GoogleUpdater": temporary] } == (.allow, .temporaryRule(temporary)))
        // A Sparkle download service connecting for its app is paused through the delegating process.
        #expect(decide("com.example.Sandboxed", process: "Sandboxed", via: "org.sparkle-project.DownloaderService").reason == .updaterPaused("Sparkle downloader"))
        #expect(FilterPolicy.Reason.updaterPaused("Google Updater").summary == "Updater paused on a metered network")
        // Without the network's cost nothing is paused, and the key is in the saved configuration only when it applies.
        #expect(FilterController.policy(SavedPreferences(), budgetReached: false)["updatersPaused"] as? Bool == false)
        #expect(FilterController.policy(SavedPreferences(), budgetReached: false, metered: true)["updatersPaused"] as? Bool == true)
    }

    @Test func theAppsThemselvesStayAllowed() {
        for (app, process) in [("com.google.Chrome", "Google Chrome"), ("com.microsoft.Word", "Microsoft Word"), ("com.apple.AppStore", "App Store"),
                               ("com.tinyspeck.slackmacgap", "Slack"), ("company.thebrowser.dia", "Dia")] {
            #expect(decide(app, process: process) == (.allow, .newAppDefault(true)), "\(app)")
        }
        // nsurlsessiond downloading for Music isn't an update; one made for softwareupdated is, under softwareupdated's identity.
        #expect(decide("com.apple.Music", process: "Music", via: "com.apple.nsurlsessiond").verdict == .allow)
        #expect(decide("com.apple.softwareupdated", process: "softwareupdated", via: "com.apple.nsurlsessiond").reason == .updaterPaused("macOS Software Update"))
        // The doctor reads the same verdict, and says how to let it through.
        let policy = ConnectionDoctor.Policy(preferences: SavedPreferences(profile: .work, defaultAllow: true), filterActive: true, budgetReached: false, metered: true)
        let step = ConnectionDoctor.rules(host: "dl.google.com", port: "443", app: "com.google.GoogleUpdater", policy: policy)
        #expect(step.status == .failed && step.detail.contains("pauses updaters"))
        #expect(ConnectionDoctor.rules(host: "dl.google.com", port: "443", app: "com.google.Chrome", policy: policy).status == .ok)
    }

    @Test func inProcessUpdatersAreReportedAsUnpausable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func app(_ path: String, framework: String?, info: [String: Any] = [:]) throws {
            let contents = folder.appendingPathComponent(path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            if let framework { try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks/\(framework).framework"), withIntermediateDirectories: true) }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try app("Electron.app", framework: "Squirrel")
        try app("Sparkly.app", framework: "Sparkle")
        try app("Sandboxed.app", framework: "Sparkle", info: ["SUEnableDownloaderService": true])
        try app("Plain.app", framework: nil)
        try app("Kilobat.app", framework: "Sparkle", info: ["CFBundleIdentifier": "co.seifi.kilobat"])
        try app("Utilities/Nested.app", framework: "Sparkle")
        let found = UpdaterPause.inProcessApps(in: [folder, folder.appendingPathComponent("Missing")])
        #expect(found.map(\.name) == ["Electron", "Nested", "Sparkly"])
        #expect(found.map(\.updater) == ["Squirrel", "Sparkle", "Sparkle"])

        let report = UpdaterPause.report(SavedPreferences(), metered: true, filterActive: true, apps: [], delegations: [], events: [], inProcess: found)
        #expect(report.paused && report.inProcess == found && report.limits.contains("inside their own process"))
        #expect(report.covered.map(\.id) == UpdaterHelpers.helpers.map(\.id))
        #expect(report.covered.filter { !$0.downloads }.map(\.id) == ["sparkle", "squirrel"])
    }

    @Test func updateBytesThatGotThroughComeFromAttribution() {
        let now = Date()
        let apps = [AppTraffic(id: "process:softwareupdated", name: "softwareupdated", received: 9_000_000, sent: 1_000_000),
                    AppTraffic(id: "com.google.GoogleUpdater", name: "GoogleUpdater", received: 3_000_000, local: 1_000_000),
                    AppTraffic(id: "process:GoogleSoftwareUpdateAgent", name: "GoogleSoftwareUpdateAgent", received: 1_000_000),
                    AppTraffic(id: "process:nsurlsessiond", name: "nsurlsessiond", received: 40_000_000),
                    AppTraffic(id: "process:mobileassetd", name: "mobileassetd", received: 5_000_000),
                    AppTraffic(id: "com.google.Chrome", name: "Google Chrome", received: 80_000_000)]
        let flows = [DelegatedFlows(process: "com.apple.nsurlsessiond", app: "com.apple.softwareupdated", allowed: 2, last: now),
                     DelegatedFlows(process: "com.apple.nsurlsessiond", app: "com.apple.Music", allowed: 1, last: now),
                     DelegatedFlows(process: "com.apple.mobileassetd", app: "com.apple.Music", allowed: 1, last: now)]
        let events = [FilterEvent(date: now.addingTimeInterval(-60), app: "com.google.GoogleUpdater", endpoint: "x", direction: "outgoing", reason: UpdaterHelpers.reason),
                      FilterEvent(date: now.addingTimeInterval(-2 * 86_400), app: "com.google.GoogleUpdater", endpoint: "x", direction: "outgoing", reason: UpdaterHelpers.reason),
                      FilterEvent(date: now, app: "com.example.App", endpoint: "x", direction: "outgoing", reason: "App block rule")]
        let report = UpdaterPause.report(SavedPreferences(), metered: true, filterActive: true, apps: apps, delegations: flows, events: events, inProcess: [], now: now)
        // Updaters' own Internet bytes, local ones left out, then the shared service that connected for one; Chrome and mobileassetd aren't updates.
        #expect(report.gotThrough == [.init(name: "nsurlsessiond", bytes: 40_000_000, shared: true, forUpdaters: ["macOS Software Update"]),
                                      .init(name: "macOS Software Update", bytes: 10_000_000, shared: false, forUpdaters: []),
                                      .init(name: "Google Updater", bytes: 3_000_000, shared: false, forUpdaters: [])])
        #expect(report.pausedConnections == 1)
        // Without the running app nothing was counted, which isn't the same as nothing getting through.
        #expect(UpdaterPause.report(SavedPreferences(), metered: true, filterActive: nil, apps: nil, delegations: [], events: [], inProcess: []).gotThrough == nil)
    }

    @Test func theSummarySaysWhetherItIsPausingNow() {
        func summary(_ metered: Bool, filter: Bool?, _ change: (inout SavedPreferences) -> Void = { _ in }) -> String {
            var preferences = SavedPreferences(); change(&preferences)
            return UpdaterPause.report(preferences, metered: metered, filterActive: filter, apps: nil, delegations: [], events: [], inProcess: []).summary
        }
        #expect(summary(true, filter: true).hasPrefix("Paused"))
        #expect(summary(true, filter: false).contains("filter is off"))
        #expect(summary(false, filter: true).contains("isn’t metered"))
        #expect(summary(true, filter: true) { $0.pauseUpdaters = false }.hasPrefix("Off"))
        #expect(summary(true, filter: true) { $0.profile = .unrestricted }.contains("Unrestricted"))
        // On by default: the setting stays out of the saved file until it is turned off.
        #expect(SavedPreferences().pauseUpdaters == nil && UpdaterPause.enabled(SavedPreferences()))
    }
}
