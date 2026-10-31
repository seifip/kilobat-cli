import Darwin
import Foundation
import Testing
@testable import KilobatCore

struct SendLaterTests {
    // MARK: Detection

    @Test func thresholdIsOneMegabyteOrHalfASlowUplink() {
        #expect(SendLater.threshold(uplinkMbps: nil) == 1_000_000)
        #expect(SendLater.threshold(uplinkMbps: 100) == 1_000_000)
        // 4 Mbps up is 500 kB/s; half of it counts.
        #expect(SendLater.threshold(uplinkMbps: 4) == 250_000)
        #expect(SendLater.threshold(uplinkMbps: 0.5) == SendLater.minimumRate)
    }

    /// Ticks of two seconds sending `bytes` each, from `start`.
    private func feed(_ tracker: inout UploadTracker, _ bytes: [UInt64], key: String = "Dropbox", start: Date, threshold: Double = 1_000_000) -> [[UploadTracker.Live]] {
        bytes.enumerated().map { index, bytes in
            tracker.observe([.init(key: key, name: key, bytes: bytes)], elapsed: 2, threshold: threshold, now: start.addingTimeInterval(Double(index + 1) * 2))
        }
    }

    @Test func showsOnlyAfterTwentySecondsAboveTheThreshold() {
        var tracker = UploadTracker()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let results = feed(&tracker, Array(repeating: 4_000_000, count: 14), start: start)
        // Above from the first tick (t = 0…2 s); 20 s later it shows.
        #expect(results.prefix(9).allSatisfy { $0.isEmpty })
        #expect(results[10].first?.key == "Dropbox")
        let last = results.last!.first!
        #expect(abs(last.rate - 2_000_000) < 1)
        #expect(last.sent == 14 * 4_000_000 && last.since == start)
    }

    @Test func aSlowOrShortUploadNeverShows() {
        var slow = UploadTracker(), burst = UploadTracker()
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(feed(&slow, Array(repeating: 1_800_000, count: 30), start: start).allSatisfy { $0.isEmpty })
        // Ten seconds at 5 MB/s, then quiet: not sustained.
        #expect(feed(&burst, Array(repeating: 10_000_000, count: 5) + Array(repeating: 0, count: 20), start: start).allSatisfy { $0.isEmpty })
        // On a slow link half the measured uplink counts.
        var hotspot = UploadTracker()
        #expect(!feed(&hotspot, Array(repeating: 600_000, count: 14), start: start, threshold: SendLater.threshold(uplinkMbps: 4)).last!.isEmpty)
    }

    @Test func aShortDipKeepsItAndThirtyQuietSecondsEndIt() {
        var tracker = UploadTracker()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let results = feed(&tracker, Array(repeating: 4_000_000, count: 12) + [0, 0, 0] + Array(repeating: 4_000_000, count: 3) + Array(repeating: 0, count: 20), start: start)
        #expect(!results[11].isEmpty && !results[17].isEmpty)
        #expect(results[17].first?.since == start)
        #expect(results.last!.isEmpty)
    }

    // MARK: Time left

    @Test func timeLeftOnlyWhenTheTotalIsKnown() {
        var upload = BigUpload(key: "Dropbox", name: "Dropbox", apps: [], rate: 2_000_000, sent: 1_000_000_000, since: Date(), method: .suspend)
        #expect(upload.eta == nil)
        upload.progress = UploadProgress(total: 1_000_000_000, done: 400_000_000)
        #expect(upload.eta == 300)
        upload.rate = 0
        #expect(upload.eta == nil)
        upload.rate = 2_000_000
        upload.hold = UploadHold(key: "Dropbox", name: "Dropbox", method: .suspend, condition: .unmetered, since: Date(), network: "Hotspot", sent: 0)
        #expect(upload.eta == nil)
        #expect(UploadsReport.entry(upload).etaSeconds == nil)
        #expect(SendLater.eta(rate: 1, progress: UploadProgress(total: 10, done: 10)) == nil)
    }

    /// A child holding `files` open for reading, as curl -T holds the file it sends.
    private func reader(_ files: [URL]) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        let opens = files.indices.map { "\($0 + 3)<\"$\($0)\"" }.joined(separator: " ")
        child.arguments = ["-c", "exec \(opens); exec sleep 20"] + files.map(\.path)
        try child.run()
        return child
    }

    @Test func findsTheOneFileAProcessUploads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("trip.mov"), other = folder.appendingPathComponent("other.mov")
        try Data(count: 2_000_000).write(to: video); try Data(count: 2_000_000).write(to: other)
        let one = try reader([video]), two = try reader([video, other])
        defer { one.terminate(); two.terminate() }
        var found: UploadProgress?
        for _ in 0..<60 {
            found = SendLater.progress(pid: one.processIdentifier, sent: 600_000, minimum: 1_000_000)
            if found != nil { break }
            usleep(50_000)
        }
        #expect(found == UploadProgress(total: 2_000_000, done: 600_000, file: "trip.mov"))
        // Headers and TLS can take what curl sent past the file's size.
        #expect(SendLater.progress(pid: one.processIdentifier, sent: 2_100_000, minimum: 1_000_000)?.done == 2_000_000)
        // No count of what it sent, a file too small, or two files: the total isn't known.
        #expect(SendLater.progress(pid: one.processIdentifier, sent: nil, minimum: 1_000_000) == nil)
        #expect(SendLater.progress(pid: one.processIdentifier, sent: 1, minimum: 3_000_000) == nil)
        usleep(200_000)
        #expect(SendLater.uploadFile(pid: two.processIdentifier, minimum: 1_000_000) == nil)
        #expect(SendLater.knowsTotal(id: "process:curl") && !SendLater.knowsTotal(id: "process:git") && !SendLater.knowsTotal(id: "process:rsync") && !SendLater.knowsTotal(id: "com.getdropbox.dropbox"))
    }

    @MainActor @Test func curlGetsATimeLeftAndDropboxDoesNot() throws {
        let setup = try Setup(id: "process:curl", name: "curl"); defer { setup.finish() }
        setup.traffic.apps.append(AppTraffic(id: "com.getdropbox.dropbox", name: "Dropbox", processIDs: [setup.child.processIdentifier]))
        setup.store.progress = { _, _ in UploadProgress(total: 400_000_000, done: 100_000_000, file: "trip.mov") }
        for _ in 0..<13 {
            setup.traffic.apps[0].sent += 6_000_000; setup.traffic.apps[1].sent += 4_000_000
            setup.now = setup.now.addingTimeInterval(2); setup.store.tick(now: setup.now)
        }
        let curl = try #require(setup.store.uploads.first { $0.key == "process:curl" })
        let dropbox = try #require(setup.store.uploads.first { $0.key == "Dropbox" })
        #expect(curl.method == .none && curl.eta == 100 && curl.progress?.total == 400_000_000)
        #expect(dropbox.progress == nil && dropbox.eta == nil)
    }

    // MARK: Conditions

    @Test func conditionsFollowTheNetwork() {
        let hotspot = UploadNetwork(key: "a", name: "Hotspot", metered: true, uploadMbps: 4)
        let home = UploadNetwork(key: "b", name: "Home Wi-Fi", metered: false, uploadMbps: 40)
        let café = UploadNetwork(key: "c", name: "Café", metered: false, uploadMbps: 8)
        #expect(!UploadCondition.unmetered.met(on: hotspot) && UploadCondition.unmetered.met(on: home) && UploadCondition.unmetered.met(on: café))
        var offline = home; offline.connected = false
        var unknown = home; unknown.key = "unknown"
        #expect(!UploadCondition.unmetered.met(on: offline) && !UploadCondition.unmetered.met(on: unknown))
        #expect(UploadCondition.fast().met(on: home) && !UploadCondition.fast().met(on: café) && !UploadCondition.fast().met(on: hotspot))
        #expect(UploadCondition.fast(5).met(on: café))
        var marked = café; marked.markedFast = true
        #expect(UploadCondition.fast().met(on: marked))
        var untested = home; untested.uploadMbps = nil
        #expect(!UploadCondition.fast().met(on: untested))
        let now = Date()
        #expect(!UploadCondition.time(now.addingTimeInterval(60)).met(on: hotspot, now: now) && UploadCondition.time(now).met(on: hotspot, now: now))
        #expect(!UploadCondition.manual.met(on: home))
        #expect(UploadCondition.automatic(metered: true) == .unmetered && UploadCondition.automatic(metered: false) == .fast())
    }

    @Test func parsesUntil() throws {
        let now = Date(timeIntervalSince1970: 0)
        #expect(try UploadCondition.parse("unmetered") == .unmetered)
        #expect(try UploadCondition.parse("fast") == .fast())
        #expect(try UploadCondition.parse("fast:30") == .fast(30))
        #expect(try UploadCondition.parse("manual") == .manual)
        #expect(try UploadCondition.parse("2h", now: now) == .time(now.addingTimeInterval(7200)))
        #expect(try UploadCondition.parse("1h30m", now: now) == .time(now.addingTimeInterval(5400)))
        #expect(try UploadCondition.parse("90m", now: now) == .time(now.addingTimeInterval(5400)))
        #expect(try UploadCondition.parse("auto") == nil)
        #expect(try UploadCondition.parse(nil) == nil)
        for bad in ["tomorrow", "9h", "30s", "fast:", "fast:-1", "2x", "h"] { #expect(throws: UploadError.self) { try UploadCondition.parse(bad) } }
    }

    @Test func parsesTheCommand() throws {
        #expect(try UploadsCommand.parse([]) == (.list, false))
        #expect(try UploadsCommand.parse(["--json"]) == (.list, true))
        #expect(try UploadsCommand.parse(["hold", "Dropbox"]) == (.hold(app: "Dropbox", until: nil), false))
        #expect(try UploadsCommand.parse(["hold", "Google Drive", "--until", "2h", "--json"]) == (.hold(app: "Google Drive", until: "2h"), true))
        #expect(try UploadsCommand.parse(["--until", "unmetered", "hold", "Dropbox"]) == (.hold(app: "Dropbox", until: "unmetered"), false))
        #expect(try UploadsCommand.parse(["resume", "Dropbox"]) == (.resume(app: "Dropbox"), false))
        for bad in [["hold"], ["resume"], ["hold", "Dropbox", "--until"], ["hold", "Dropbox", "--until", "soon"], ["resume", "Dropbox", "--until", "2h"], ["--until", "2h"], ["pause", "Dropbox"], ["hold", "a", "b"]] {
            #expect(throws: UploadError.self) { try UploadsCommand.parse(bad) }
        }
    }

    // MARK: What can be held

    @Test func neverPausesBrowsersMacOSToolsOrLaunchers() {
        for id in ["com.apple.Safari", "com.apple.WebKit.Networking", "com.google.Chrome", "com.google.Chrome.helper", "org.mozilla.firefox", "company.thebrowser.Browser",
                   "company.thebrowser.dia", "com.microsoft.edgemac", "com.brave.Browser", "com.apple.finder", "com.apple.bird", "com.apple.Photos", "process:git", "process:ssh",
                   "process:curl", "process:rsync", "com.valvesoftware.steam", "co.seifi.kilobat"] {
            #expect(SendLater.plan(id: id).method == .none && SendLater.plan(id: id).reason != nil, "\(id)")
        }
        #expect(SendLater.plan(id: "com.example.Helper", bundlePath: "/System/Library/CoreServices/Helper.app").method == .none)
        #expect(SendLater.plan(id: "com.example.VPN", carrier: true).method == .none)
        for id in ["com.getdropbox.dropbox", "com.google.drivefs", "com.microsoft.OneDrive", "com.backblaze.bzserv", "org.qbittorrent.qBittorrent"] {
            #expect(SendLater.plan(id: id).method == .suspend, "\(id)")
        }
        #expect(SendLater.plan(id: "com.example.Uploader").method == .block)
        #expect(SendLater.identity(id: "com.getdropbox.dropbox.fileprovider", name: "File Provider", pid: nil) == ("Dropbox", "Dropbox"))
    }

    // MARK: Holding and resuming

    private func status(_ pid: Int32) -> UInt32? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return info.pbi_status
    }

    @MainActor private final class Setup {
        let folder: URL, ledger: URL, child: Process
        let traffic: TrafficStore, store: UploadStore
        var notices: [String] = []
        var now = Date(timeIntervalSince1970: 2_000_000)
        init(id: String = "com.getdropbox.dropbox", name: String = "Dropbox", pro: Bool = true) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("send-later-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ledger = folder.appendingPathComponent("held.json")
            child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
            try child.run()
            traffic = TrafficStore(directory: folder, startMonitoring: false)
            traffic.networkKey = "hotspot"; traffic.networkName = "Phone hotspot"; traffic.connected = true; traffic.osExpensive = true
            traffic.apps = [AppTraffic(id: id, name: name, processIDs: [child.processIdentifier])]
            let defaults = UserDefaults(suiteName: "send-later-\(UUID().uuidString)")!
            store = UploadStore(ledger: ledger, defaults: defaults)
            store.allowed = { pro }
            store.frontmost = { nil }
            // Only the test's own child is ever paused, never a real app with the same bundle ID.
            store.running = { _ in [] }
            store.notify = { [unowned self] _, body in notices.append(body) }
            store.start(traffic: traffic, polling: false)
        }
        /// Uploads `bytes` every two seconds for `ticks` samples.
        func upload(_ ticks: Int, bytes: UInt64 = 6_000_000) {
            for _ in 0..<ticks {
                traffic.apps[0].sent += bytes
                now = now.addingTimeInterval(2)
                store.tick(now: now)
            }
        }
        func finish() {
            kill(child.processIdentifier, SIGCONT); child.terminate()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @MainActor @Test func holdsOnAHotspotAndResumesOnHomeWiFi() throws {
        let setup = try Setup(); defer { setup.finish() }
        setup.upload(13)
        let upload = try #require(setup.store.uploads.first)
        #expect(upload.key == "Dropbox" && upload.method == .suspend && upload.hold == nil && upload.eta == nil)
        let hold = try setup.store.hold("Dropbox", now: setup.now)
        #expect(hold.condition == .unmetered && hold.method == .suspend && hold.network == "Phone hotspot")
        #expect(status(setup.child.processIdentifier) == UInt32(SSTOP))
        #expect(CallMode.held(ledger: setup.ledger).first?.holders == [SendLater.owner])
        #expect(setup.traffic.temporaryRule("com.getdropbox.dropbox")?.allowed == false)
        #expect(setup.store.uploads.first?.hold != nil)
        // Still on the hotspot: it stays held.
        setup.upload(3, bytes: 0)
        #expect(status(setup.child.processIdentifier) == UInt32(SSTOP))
        setup.traffic.networkKey = "home"; setup.traffic.networkName = "Home Wi-Fi"; setup.traffic.osExpensive = false
        setup.upload(1, bytes: 0)
        #expect(status(setup.child.processIdentifier) != UInt32(SSTOP))
        #expect(setup.notices == ["Dropbox’s upload resumed on Home Wi-Fi."])
        #expect(setup.store.holds.isEmpty && CallMode.held(ledger: setup.ledger).isEmpty)
        #expect(setup.traffic.temporaryRule("com.getdropbox.dropbox") == nil)
    }

    @MainActor @Test func resumesByHandWhenOpenedAtTheLimitAndOnQuit() throws {
        let setup = try Setup(); defer { setup.finish() }
        let pid = setup.child.processIdentifier
        try setup.store.hold("Dropbox", until: .manual, now: setup.now)
        #expect(status(pid) == UInt32(SSTOP))
        #expect(setup.store.resume("dropbox") && status(pid) != UInt32(SSTOP) && setup.notices.isEmpty)
        #expect(!setup.store.resume("Dropbox"))

        try setup.store.hold("Dropbox", until: .manual, now: setup.now)
        setup.store.frontmost = { "com.getdropbox.dropbox" }
        setup.upload(1, bytes: 0)
        #expect(status(pid) != UInt32(SSTOP) && setup.store.holds.isEmpty && setup.notices.isEmpty)
        setup.store.frontmost = { nil }

        try setup.store.hold("Dropbox", until: .manual, now: setup.now)
        setup.now = setup.now.addingTimeInterval(SendLater.limit + 1)
        setup.store.tick(now: setup.now)
        #expect(status(pid) != UInt32(SSTOP) && setup.store.holds.isEmpty)
        #expect(setup.notices.count == 1 && setup.notices[0].contains("8 hours"))

        try setup.store.hold("Dropbox", until: .fast(), now: setup.now)
        setup.store.quit()
        #expect(status(pid) != UInt32(SSTOP) && setup.store.holds.isEmpty && CallMode.held(ledger: setup.ledger).isEmpty)
        #expect(setup.traffic.temporaryRule("com.getdropbox.dropbox") == nil)
    }

    @MainActor @Test func aCrashLeavesTheLedgerToResumeAndACallKeepsItsOwnHold() throws {
        let setup = try Setup(); defer { setup.finish() }
        let pid = setup.child.processIdentifier
        try setup.store.hold("Dropbox", until: .time(setup.now.addingTimeInterval(3600)), now: setup.now)
        // What the next launch runs: every owner's line resumes.
        #expect(CallMode.resume(ledger: setup.ledger).count == 1 && status(pid) != UInt32(SSTOP))
        // A call holding the same app keeps it held when the upload's hold ends.
        setup.store.resume("Dropbox")
        CallMode.hold([pid], app: "Dropbox", owner: CallMode.call, ledger: setup.ledger)
        try setup.store.hold("Dropbox", until: .manual, now: setup.now)
        setup.store.resume("Dropbox")
        #expect(status(pid) == UInt32(SSTOP))
        CallMode.resume(owner: CallMode.call, ledger: setup.ledger)
        #expect(status(pid) != UInt32(SSTOP))
    }

    @MainActor @Test func letsGoWhenTheAppQuitsAndMarkedFastNetworksCount() throws {
        let setup = try Setup(); defer { setup.finish() }
        setup.traffic.osExpensive = false
        setup.store.uplink = { _ in 8 }
        setup.upload(1, bytes: 0)
        try setup.store.hold("Dropbox", now: setup.now)
        #expect(setup.store.holds.first?.condition == .fast())
        setup.store.markFast()
        #expect(setup.store.holds.isEmpty && setup.notices == ["Dropbox’s upload resumed on Phone hotspot."])

        try setup.store.hold("Dropbox", until: .manual, now: setup.now)
        kill(setup.child.processIdentifier, SIGCONT); setup.child.terminate(); setup.child.waitUntilExit()
        setup.traffic.apps[0].processIDs = []
        setup.upload(1, bytes: 0)
        #expect(setup.store.holds.isEmpty && CallMode.held(ledger: setup.ledger).isEmpty)
    }

    @MainActor @Test func refusesWhatItShouldNotHold() throws {
        let setup = try Setup(); defer { setup.finish() }
        let pid = setup.child.processIdentifier
        setup.store.frontmost = { "com.getdropbox.dropbox" }
        #expect(throws: UploadError.self) { try setup.store.hold("Dropbox", now: setup.now) }
        setup.store.frontmost = { nil }
        setup.traffic.osExpensive = false
        #expect(throws: UploadError.self) { try setup.store.hold("Dropbox", until: .unmetered, now: setup.now) }
        #expect(throws: UploadError.self) { try setup.store.hold("Nothing", now: setup.now) }
        setup.store.allowed = { false }
        #expect(throws: UploadError.self) { try setup.store.hold("Dropbox", until: .manual, now: setup.now) }
        #expect(status(pid) != UInt32(SSTOP) && CallMode.held(ledger: setup.ledger).isEmpty)

        setup.store.allowed = { true }
        setup.traffic.apps = [AppTraffic(id: "com.google.Chrome", name: "Chrome", processIDs: [pid]), AppTraffic(id: "process:git", name: "git", processIDs: [pid])]
        #expect(throws: UploadError.self) { try setup.store.hold("com.google.Chrome", until: .manual, now: setup.now) }
        #expect(throws: UploadError.self) { try setup.store.hold("process:git", until: .manual, now: setup.now) }
        #expect(status(pid) != UInt32(SSTOP) && CallMode.held(ledger: setup.ledger).isEmpty)
    }

    @MainActor @Test func otherAppsOnlyHaveNewConnectionsRefused() throws {
        let setup = try Setup(id: "com.example.Uploader", name: "Uploader"); defer { setup.finish() }
        let pid = setup.child.processIdentifier
        setup.traffic.preferences.profile = .travel
        #expect(throws: UploadError.self) { try setup.store.hold("Uploader", until: .manual, now: setup.now) }
        setup.store.filterActive = { true }
        let hold = try setup.store.hold("Uploader", until: .manual, now: setup.now)
        #expect(hold.method == .block && status(pid) != UInt32(SSTOP) && CallMode.held(ledger: setup.ledger).isEmpty)
        #expect(setup.traffic.temporaryRule("com.example.Uploader")?.allowed == false)
        setup.store.resume("Uploader")
        #expect(setup.traffic.temporaryRule("com.example.Uploader") == nil)
        // A rule someone else set is left alone.
        setup.traffic.setTemporary("com.example.Uploader", allowed: true, minutes: 60)
        try setup.store.hold("Uploader", until: .manual, now: setup.now)
        setup.store.resume("Uploader")
        #expect(setup.traffic.temporaryRule("com.example.Uploader")?.allowed == true)
    }

    @MainActor @Test func reportsOverTheRelay() throws {
        let setup = try Setup(); defer { setup.finish() }
        setup.upload(13)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(UploadsReport.self, from: try #require(setup.store.answer("uploads")))
        #expect(report.appRunning && report.metered == true && report.uploads.first?.state == "uploading" && report.uploads.first?.totalBytes == nil)
        func object(_ action: String) throws -> [String: Any] {
            let data = try #require(setup.store.answer(action))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let held = try object("uploads|hold|Dropbox|2h")
        #expect(held["held"] as? Bool == true && held["method"] as? String == "suspend")
        #expect(try object("uploads|resume|Dropbox")["resumed"] as? Bool == true)
        let refused = try object("uploads|hold|Dropbox|unmetered-ish")
        #expect(refused["held"] as? Bool == false && refused["error"] != nil)
        #expect(setup.store.answer("uploads|pause|Dropbox") == nil)
    }
}
