import Darwin
import Foundation
import Testing
@testable import KilobatCore

@MainActor struct FourthAuditTests {
    @Test func networkAndAccountingRegressions() async throws {
        let now = Date(), fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("kilobat-audit-four-\(UUID())")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let list = ProtectionList(id: "fixture", name: "Fixture", url: URL(string:"https://fixture.invalid/list")!, homepage: URL(string:"https://fixture.invalid")!, licence: "fixture", category: .threat, group: .threats, minimum: 1)
        let updater = ProtectionUpdater(directory: folder.appendingPathComponent("protection"), fetch: { request in (Data("malware.example\n".utf8), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) })
        let protection = ProtectionStore(updater: updater)
        await protection.refresh([list], known: ["old.example"])
        await protection.refresh([list], known: ["new.example"])
        #expect(protection.index?.match(host: "old.example", in: [.known]) == nil)
        #expect(protection.index?.match(host: "new.example", in: [.known]) != nil)
        let traffic = TrafficStore(directory:folder.appendingPathComponent("traffic"),startMonitoring:false)
        traffic.networkKey="A"; traffic.networkName="A"; traffic.preferences.limitGB=0.1
        traffic.setBudgetMode(.alert)
        traffic.preferences.budgetCycle=BudgetCycle(period:.session,alerts:[80])
        let alerts=BudgetWatch(directory:folder.appendingPathComponent("traffic"))
        traffic.received=90_000_000; let first=alerts.check(traffic,now:now)
        traffic.resetSession(); traffic.received=90_000_000
        let second=alerts.check(traffic,now:now+30)
        #expect(first.count == 1 && second.count == 1)
        func sample(_ name:String)->DiagnosticSnapshot {
        DiagnosticSnapshot(date:Date(),radio:RadioSample(ssid:name,interface:"en0",rssi:-55,noise:-95,transmitMbps:400,channel:149,band:"5 GHz"),gateway:"192.168.1.1",router:PingResult(host:"192.168.1.1",samples:[3],lossPercent:0),internet:PingResult(host:"1.1.1.1",samples:[20],lossPercent:0),dnsMilliseconds:20,dnsServers:["192.168.1.1"],captivePortal:false,networkService:"Wi-Fi")
        }
        let reach=LocalReachWatch(); let a=sample("A"),b=sample("B")
        var entered=false, release=false, published:String?
        reach.runProbe = { _,_,_,_,_ in entered=true; while !release { await Task.yield() }; return LocalReachCheck(network:"B",services:[LocalService(kind:.printer,name:"B printer")],peers:LocalPeers()) }
        reach.onServices={ key,_ in published=key }
        reach.observe(a,portal:false,automatic:false)
        let work=Task { await reach.run() }; while !entered { await Task.yield() }
        reach.observe(b,portal:false,automatic:false); release=true; _=await work.value
        reach.observe(a,portal:false,automatic:false)
        #expect(published == nil && reach.check == nil)
        let node=NodeWatch(directory:nil)
        let weak=NodeRadio(bssid:"00:11:22:33:44:50",rssi:-80,channel:36,band:"5 GHz",widthMHz:80)
        let strong=NodeRadio(bssid:"00:11:22:66:77:80",rssi:-45,channel:36,band:"5 GHz",widthMHz:80)
        for seconds in [0.0,120,240,360] { node.ingest(NodeReading(date:now+seconds,ssid:"A",current:weak,transmitMbps:nil,scan:[weak,strong]),network:"A") }
        let opened=node.place("A")?.episodes.last
        node.ingest(NodeReading(date:now+400,ssid:"B",current:strong,transmitMbps:nil,scan:[]),network:"B")
        #expect(opened != nil && node.place("A")?.episodes.last?.end == now + 360)
        let home=HomeUsageStore(directory:nil,secrets:MemoryRouterSecrets())
        let one = UUID(), two = UUID()
        home.need(.call, true, consumer: one); home.need(.call, true, consumer: two)
        let active = home.interval
        home.need(.call, false, consumer: one)
        #expect(home.interval == active)
        home.need(.call, false, consumer: two)
        #expect(home.interval > active)
        traffic.networkKey=a.networkKey
        traffic.preferences.profile = .unrestricted; traffic.preferences.autoHotspot=true
        traffic.preferences.dataPacks=[DataPack(name:"Expiring",bytes:1000,start:Date()-3600,end:Date()+0.1,networks:.init(keys:[a.networkKey:"A"]))]
        traffic.pathChanged(connected:true,expensive:false,kind:"Wi-Fi")
        let before=traffic.preferences.profile
        try await Task.sleep(for:.milliseconds(200))
        traffic.switchNetwork(a)
        #expect(before == .travel && !traffic.metered && traffic.preferences.profile == .unrestricted)
    }

    @Test func gamingHoldExpiresWithoutTrafficAndPreservesOtherOwners() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gaming-hold-\(UUID())")
        let ledger = folder.appendingPathComponent("held.json")
        let traffic = TrafficStore(directory: folder, startMonitoring: false)
        let gaming = CloudGamingStore(directory: folder)
        gaming.processHoldLedger = ledger
        gaming.processHoldLimit = .zero
        var wake: CheckedContinuation<Void, Never>?
        gaming.waitForHoldDeadline = { _ in await withCheckedContinuation { wake = $0 } }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            CallMode.resume(ledger: ledger)
            kill(child.processIdentifier, SIGCONT)
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
            try? FileManager.default.removeItem(at: folder)
        }
        let app = AppTraffic(id: "com.getdropbox.dropbox", name: "Dropbox", processIDs: [child.processIdentifier])
        gaming.hold([app], traffic: traffic)
        #expect(gaming.holding == ["Dropbox"])
        #expect(traffic.temporaryRule(app.id)?.allowed == false)
        _ = CallMode.hold(app.processIDs, app: "Dropbox", owner: CallMode.call, ledger: ledger)
        traffic.setTemporary(app.id, allowed: true)

        while wake == nil { await Task.yield() }
        wake?.resume()
        while !gaming.holding.isEmpty { await Task.yield() }
        #expect(gaming.holding.isEmpty)
        #expect(CallMode.held(ledger: ledger).first?.holders == [CallMode.call])
        #expect(traffic.temporaryRule(app.id)?.allowed == true)
        gaming.hold([app], traffic: traffic)
        #expect(gaming.holding.isEmpty)
        #expect(CallMode.resume(owner: CallMode.call, ledger: ledger).map(\.pid) == [child.processIdentifier])
    }

    @Test func losingCallModeEntitlementResumesItsOwnedProcess() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("call-entitlement-\(UUID())")
        let ledger = folder.appendingPathComponent("held.json")
        let traffic = TrafficStore(directory: folder, startMonitoring: false)
        let calls = CallStore(directory: folder, ledger: ledger)
        calls.start(traffic: traffic, diagnostics: DiagnosticStore(), polling: false)
        calls.allowed = { true }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            calls.release()
            kill(child.processIdentifier, SIGCONT)
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
            try? FileManager.default.removeItem(at: folder)
        }
        let app = AppTraffic(id: "com.getdropbox.dropbox", name: "Dropbox", processIDs: [child.processIdentifier])
        traffic.apps = [app]
        calls.holdBeforeCall(["Dropbox"])
        #expect(CallMode.held(ledger: ledger).first?.holders == [CallMode.call])
        #expect(traffic.temporaryRule(app.id)?.allowed == false)
        calls.allowed = { false }
        let now = Date()
        calls.hold(traffic: traffic, now: now, start: now - 60)
        #expect(calls.holding.isEmpty && CallMode.held(ledger: ledger).isEmpty)
        #expect(traffic.temporaryRule(app.id) == nil)
        var info = proc_bsdinfo()
        _ = proc_pidinfo(child.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        #expect(info.pbi_status != UInt32(SSTOP))
    }

    @Test func overlayRejectsForeignOriginsAndReboundHosts() {
        #expect(StreamOverlay.localPath("GET /data.json HTTP/1.1\r\nHost: localhost:7171", port: 7171) == "/data.json")
        #expect(StreamOverlay.localPath("GET /data.json HTTP/1.1\r\nHost: localhost:7171\r\nOrigin: https://foreign.example", port: 7171) == nil)
        #expect(StreamOverlay.localPath("GET /data.json HTTP/1.1\r\nHost: rebound.example:7171", port: 7171) == nil)
        #expect(StreamOverlay.localPath("GET /data.json HTTP/1.1\r\nHost: localhost:7171\r\nSec-Fetch-Site: cross-site", port: 7171) == nil)
    }

    @Test func callHoldPicksUpNewHelpers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ledger = folder.appendingPathComponent("held.json")
        let traffic = TrafficStore(directory: folder, startMonitoring: false)
        let calls = CallStore(directory: folder, ledger: ledger)
        let oldMode = UserDefaults.standard.object(forKey: "callMode")
        calls.callMode = true
        calls.allowed = { true }
        var children: [Process] = []
        defer {
            calls.release()
            UserDefaults.standard.set(oldMode, forKey: "callMode")
            for child in children {
                if child.isRunning { kill(child.processIdentifier, SIGCONT); child.terminate() }
                child.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        let start = Date()
        for offset in [0.0, 11.0] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["60"]
            try child.run()
            children.append(child)
            traffic.apps = [AppTraffic(id: "com.getdropbox.dropbox", name: "Dropbox", processIDs: children.map(\.processIdentifier))]
            calls.hold(traffic: traffic, now: start + offset, start: start)
        }
        #expect(calls.holding == ["Dropbox"])
        #expect(Set(CallMode.held(ledger: ledger).map(\.pid)) == Set(children.map(\.processIdentifier)))
    }

    @Test func routerDisconnectCanRetryAfterFailedPersistence() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? manager.removeItem(at: folder)
        }
        let connection = RouterConnection(kind: .openwrt, network: "home", networkName: "Home",
                                          url: "http://192.168.1.1", entered: "192.168.1.1")
        var book = HomeUsageStore.Book()
        book.routers = [connection]
        try JSONEncoder().encode(book).write(to: folder.appendingPathComponent(HomeUsageStore.bookFile))
        let secrets = MemoryRouterSecrets([connection.id: "fixture"])
        let store = HomeUsageStore(directory: folder, secrets: secrets)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        store.disconnect(network: "home")
        #expect(store.connection(for: "home")?.id == connection.id)
        #expect(secrets.secret(for: connection.id) == "fixture")

        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        store.disconnect(network: "home")
        #expect(store.connection(for: "home") == nil)
        #expect(HomeUsageStore.load(directory: folder).book.routers.isEmpty)
        #expect(secrets.secret(for: connection.id) == nil)
    }

    @Test func stoppingPingWhileResolvingDoesNotLaunchProcess() async {
        let (entered, signalEntry) = AsyncStream<Void>.makeStream()
        let (resume, signalResume) = AsyncStream<Void>.makeStream()
        let stream = PingStream(target: "router", start: Date()) { _ in
            signalEntry.yield(())
            for await _ in resume { break }
            return "127.0.0.1"
        }
        let start = Task { await stream.start() }
        for await _ in entered { break }
        _ = await stream.stop()
        signalResume.yield(())
        await start.value
        #expect(await !stream.isRunning)
        _ = await stream.stop()
    }


    @Test func streamPreflightDiscardsResultsAfterNetworkRoundTrip() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let traffic = TrafficStore(directory: folder, startMonitoring: false)
        traffic.networkKey = "home"
        let stream = StreamStore(directory: folder)
        let diagnostics = DiagnosticStore()
        stream.start(traffic: traffic, diagnostics: diagnostics, polling: false)
        stream.metered = { traffic.networkKey == "hotspot" }

        let (entered, signalEntry) = AsyncStream<Bool>.makeStream()
        let (resume, signalResume) = AsyncStream<Void>.makeStream()
        stream.runReadiness = { bitrate, source, measure, _, metered, busy in
            signalEntry.yield(measure)
            for await _ in resume { break }
            return StreamReadiness(bitrate: bitrate, bitrateSource: source, upload: nil, uploadSource: .none,
                                   uploadDate: nil, latency: nil, jitter: nil, lossPercent: nil, metered: metered, busy: busy)
        }
        let check = Task { await stream.runCheck(bitrate: 6000) }
        while !stream.checking { await Task.yield() }
        traffic.networkKey = "hotspot"
        var iterator = entered.makeAsyncIterator()
        #expect(await iterator.next() == false)
        traffic.networkKey = "home"
        traffic.networkKey = "hotspot"
        signalResume.yield(())
        await check.value
        #expect(stream.check == nil)
    }

    @Test func queuedSmartHomeCheckCannotPublishOnAnotherNetwork() async {
        let diagnostics = DiagnosticStore()
        func snapshot(_ name: String) -> DiagnosticSnapshot {
            DiagnosticSnapshot(date: Date(), radio: RadioSample(ssid: name, interface: "en0", rssi: -55, noise: -95,
                               transmitMbps: 400, channel: 149, band: "5 GHz"), gateway: "192.168.1.1",
                               router: PingResult(host: "192.168.1.1", samples: [3], lossPercent: 0),
                               internet: PingResult(host: "1.1.1.1", samples: [20], lossPercent: 0), dnsMilliseconds: 20,
                               dnsServers: [], captivePortal: false, networkService: "Wi-Fi")
        }
        diagnostics.snapshot = snapshot("A")
        let networkA = diagnostics.snapshot?.networkKey
        let watch = SmartHomeWatch()
        let (entered, signalEntry) = AsyncStream<Void>.makeStream()
        let (resume, signalResume) = AsyncStream<Void>.makeStream()
        var probes = 0
        watch.probe = { _ in
            probes += 1
            if probes == 1 {
                signalEntry.yield(())
                for await _ in resume { break }
            }
            return SmartHomeReport(date: Date(), headline: "Fixture", threadNetworks: [], idleBorderRouters: [],
                                   matter: .build(operational: [], commissionable: []), homeKit: .build([]), checks: [], findings: [],
                                   localNetwork: "unknown", routerGuide: nil)
        }
        let first = Task { await watch.check(network: networkA, diagnostics: diagnostics) }
        for await _ in entered { break }
        let queued = Task { await watch.check(network: networkA, diagnostics: diagnostics) }
        await Task.yield()
        diagnostics.snapshot = snapshot("B")
        signalResume.yield(())
        await first.value
        await queued.value
        #expect(probes == 1)
        #expect(watch.report == nil)
    }

    @Test func serviceTraceDoesNotSurviveNetworkRoundTrip() async throws {
        let watch = ServiceSpeedWatch(directory: nil)
        let now = Date()
        var log = ServiceSpeedLog()
        log.add(ServiceTransfer(date: now, seconds: 10, bytes: 10_000_000, mbps: 8, otherMbps: 0, address: "192.0.2.1"),
                key: "github", network: "A", name: "A", now: now)
        watch.preview(log, network: "A", speedTests: [], now: now)
        func visit(_ key: String) {
            watch.consume(TrafficSnapshot(timestamp: now, processes: []), network: key, name: key, vpn: false)
        }
        visit("A")
        let (entered, signalEntry) = AsyncStream<Void>.makeStream()
        let (resume, signalResume) = AsyncStream<Void>.makeStream()
        watch.trace = { _ in
            signalEntry.yield(())
            for await _ in resume { break }
            return "stale trace"
        }
        let trace = try #require(watch.traceRoute(to: "192.0.2.1", key: "github", network: "A"))
        for await _ in entered { break }
        visit("B")
        visit("A")
        signalResume.yield(())
        await trace.value
        #expect(watch.log.networks["A"]?.traces?["github"] == nil)
        watch.trace = { _ in "current trace" }
        let retry = try #require(watch.traceRoute(to: "192.0.2.1", key: "github", network: "A"))
        await retry.value
        #expect(watch.log.networks["A"]?.traces?["github"] != nil)
    }


    @Test func focusCannotChangePreferencesWithoutRecoveryRecord() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recovery = folder.appendingPathComponent("focus.json")
        let ledger = folder.appendingPathComponent("held.json")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let traffic = TrafficStore(directory: folder, startMonitoring: false)
        traffic.preferences.profile = .unrestricted
        let focus = FocusFilterStore(directory: folder, ledger: ledger)
        focus.allowed = { true }; focus.traffic = { traffic }
        let filter = FocusFilter(profile: .travel, pauseUpdaters: true)
        #expect(!focus.apply(filter))
        #expect(focus.persistenceError != nil && focus.state == nil)
        #expect(traffic.preferences.profile == .unrestricted)
        #expect(traffic.preferences.focusPausesUpdaters == nil)

        try FileManager.default.removeItem(at: recovery)
        #expect(focus.apply(filter))
        let reloaded = TrafficStore(directory: folder, startMonitoring: false)
        #expect(reloaded.preferences.profile == .travel)
        let restarted = FocusFilterStore(directory: folder, ledger: ledger)
        restarted.allowed = { true }; restarted.traffic = { reloaded }
        restarted.reconcile(nil)
        #expect(reloaded.preferences.profile == .unrestricted && reloaded.preferences.focusPausesUpdaters == nil)
    }

    @Test func identicalPreferenceRetryPersistsAfterFailedWrite() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let traffic = TrafficStore(directory: folder, startMonitoring: false)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? manager.removeItem(at: folder)
        }
        traffic.preferences.profile = .travel
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        traffic.setAllowed("fixture.app", false)
        #expect(traffic.error != nil)
        traffic.reloadPreferences()
        #expect(traffic.preferences.rules[NetworkProfile.travel.rawValue]?["fixture.app"] == false)

        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        traffic.setAllowed("fixture.app", false)
        #expect(traffic.error == nil)
        let reloaded = TrafficStore(directory: folder, startMonitoring: false)
        #expect(reloaded.preferences.rules[NetworkProfile.travel.rawValue]?["fixture.app"] == false)
    }

}
