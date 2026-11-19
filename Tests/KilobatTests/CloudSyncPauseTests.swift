import Foundation
import Testing
@testable import KilobatCore

struct CloudSyncPauseTests {
    func decide(_ app: String, process: String, metered: Bool = true, _ change: (inout SavedPreferences) -> Void = { _ in }) -> (verdict: FilterPolicy.Verdict, reason: FilterPolicy.Reason) {
        var preferences = SavedPreferences()
        preferences.profile = .work
        preferences.defaultAllow = true
        change(&preferences)
        return FilterPolicy(FilterController.policy(preferences, budgetReached: false, metered: metered))
            .decide(.init(app: app, process: process, host: "sync.example.com"))
    }

    @Test func clientsMatchTheirAppExtensionsAndHelpers() {
        let cases: [(app: String, process: String?, client: String)] = [
            // Google Drive's app and File Provider extension, from codesign -dv on an installed copy.
            ("com.google.drivefs", "Google Drive", "google-drive"), ("com.google.drivefs.fpext", "DFSFileProviderExtension", "google-drive"),
            ("com.getdropbox.dropbox", "Dropbox", "dropbox"), ("com.getdropbox.dropbox.fileprovider", nil, "dropbox"),
            ("com.microsoft.OneDrive-mac", "OneDrive", "onedrive"), ("com.microsoft.OneDrive.FileProvider", nil, "onedrive"),
            ("process:bztransmit", nil, "backblaze"), ("process:Google Drive", nil, "google-drive"),
        ]
        for item in cases { #expect(CloudSyncClients.client(item.app, process: item.process)?.id == item.client, "\(item.app)") }
        // Other apps from the same companies aren't sync clients, and neither is iCloud.
        for app in ["com.google.Chrome", "com.microsoft.Word", "com.microsoft.autoupdate2", "com.apple.cloudd", "com.apple.bird", "process:Box", ""] {
            #expect(CloudSyncClients.client(app, process: "Something") == nil, "\(app)")
        }
    }

    @Test func meteredNetworksPauseSyncAndUnmeteredOnesDont() {
        #expect(decide("com.google.drivefs.fpext", process: "DFSFileProviderExtension") == (.block, .syncPaused("Google Drive")))
        #expect(decide("com.google.drivefs", process: "Google Drive", metered: false) == (.allow, .newAppDefault(true)))
        #expect(decide("com.getdropbox.dropbox", process: "Dropbox") { $0.pauseCloudSync = false } == (.allow, .newAppDefault(true)))
        #expect(decide("com.getdropbox.dropbox", process: "Dropbox") { $0.profile = .unrestricted } == (.allow, .unrestricted))
        // A temporary allow lets one sync through on the hotspot.
        let temporary = TemporaryRule(allowed: true, expires: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 600).rounded()))
        #expect(decide("com.getdropbox.dropbox", process: "Dropbox") { $0.temporaryRules = ["Work|com.getdropbox.dropbox": temporary] } == (.allow, .temporaryRule(temporary)))
        #expect(FilterPolicy.Reason.syncPaused("Dropbox").summary == "Cloud sync paused on a metered network")
        #expect(FilterController.policy(SavedPreferences(), budgetReached: false)["syncPaused"] as? Bool == false)
        #expect(FilterController.policy(SavedPreferences(), budgetReached: false, metered: true)["syncPaused"] as? Bool == true)
    }

    @Test func theDoctorSaysWhyAndHowToAllowIt() {
        let reason = FilterPolicy.Reason.syncPaused("OneDrive")
        let policy = ConnectionDoctor.Policy(preferences: SavedPreferences(profile: .work, defaultAllow: true), filterActive: true, budgetReached: false, metered: true)
        let step = ConnectionDoctor.rules(host: "graph.microsoft.com", port: "443", app: "com.microsoft.OneDrive-mac", policy: policy)
        #expect(step.status == .failed && step.detail.contains("pauses cloud sync"))
        #expect(reason.summary.contains("Cloud sync"))
    }
}
