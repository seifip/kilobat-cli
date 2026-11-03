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
        gaming.processHoldLimit = .milliseconds(50)
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

        let clock = ContinuousClock()
        let waitUntil = clock.now.advanced(by: .seconds(5))
        while !gaming.holding.isEmpty && clock.now < waitUntil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gaming.holding.isEmpty)
        #expect(CallMode.held(ledger: ledger).first?.holders == [CallMode.call])
        #expect(traffic.temporaryRule(app.id)?.allowed == true)
        gaming.hold([app], traffic: traffic)
        #expect(gaming.holding.isEmpty)
        #expect(CallMode.resume(owner: CallMode.call, ledger: ledger).map(\.pid) == [child.processIdentifier])
    }

    @Test func overlayRejectsForeignOriginsAndReboundHosts() {
        #expect(StreamOverlay.localPath("GET /data.json HTTP/1.1\r\nHost: localhost:7171", port: 7171) == "/data.json")
        #expect(StreamOverlay.localPath("GET /data.json HTTP/1.1\r\nHost: localhost:7171\r\nOrigin: https://foreign.example", port: 7171) == nil)
        #expect(StreamOverlay.localPath("GET /data.json HTTP/1.1\r\nHost: rebound.example:7171", port: 7171) == nil)
        #expect(StreamOverlay.localPath("GET /data.json HTTP/1.1\r\nHost: localhost:7171\r\nSec-Fetch-Site: cross-site", port: 7171) == nil)
    }
}
