import Foundation
import Testing
@testable import KilobatCore

/// A DSL line as FRITZ! documents it (TR-064 WANDSLInterfaceConfig, version 9), and routers that only share UPnP's counters.
struct RouterLineAndUPnPTests {
    private let dslInfo = ["NewDownstreamCurrRate": "98200", "NewUpstreamCurrRate": "36100", "NewDownstreamMaxRate": "116000", "NewUpstreamMaxRate": "42000",
                           "NewDownstreamNoiseMargin": "81", "NewUpstreamNoiseMargin": "64", "NewDownstreamAttenuation": "152", "NewUpstreamAttenuation": "98",
                           "NewCRCErrors": "12", "NewFECErrors": "3400"]

    @Test func readsASyncedLine() {
        let line = RouterDSLLine(info: dslInfo)
        #expect(line == RouterDSLLine(downKbps: 98_200, upKbps: 36_100, maxDownKbps: 116_000, maxUpKbps: 42_000, marginDownTenths: 81, marginUpTenths: 64,
                                      attenuationDownTenths: 152, attenuationUpTenths: 98, crcErrors: 12, fecErrors: 3400))
    }

    @Test func noSyncIsNoLine() {
        #expect(RouterDSLLine(info: ["NewDownstreamCurrRate": "0", "NewUpstreamCurrRate": "0"]) == nil)
        #expect(RouterDSLLine(info: [:]) == nil)
    }

    @Test func aCableFaultNeedsAFinishedTestOnAnActiveLine() {
        func info(_ state: String, _ distance: String, active: String = "1") -> [String: String] {
            ["NewX_AVM-DE_DSLDigagnoseState": state, "NewX_AVM-DE_CableNokDistance": distance, "NewX_AVM-DE_DSLActive": active]
        }
        #expect(RouterDSLLine.cableFault(info("DONE_CABLE_NOK", "340")) == 340)
        #expect(RouterDSLLine.cableFault(info("DONE_CABLE_NOK", "-1")) == nil)
        #expect(RouterDSLLine.cableFault(info("DONE_CABLE_OK", "340")) == nil)
        #expect(RouterDSLLine.cableFault(info("DONE_CABLE_NOK", "340", active: "0")) == nil)
    }

    @Test func upnpReportsWholeHomeCounters() async throws {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let router = UPnPRouter(controlURL: "http://192.168.1.1:5000/ctl", model: "Archer AX55") { url in
            #expect(url == "http://192.168.1.1:5000/ctl")
            return RouterReading(date: date, received: 4_000, sent: 900)
        }
        let poll = try await router.poll()
        #expect(poll.wan == RouterWAN(down: 4_000, up: 900, bits: 32))
        #expect(poll.model == "Archer AX55" && !poll.perDevice && poll.clients.isEmpty && poll.date == date)
    }

    @Test func aReaderNeedsNoSecretForUPnP() throws {
        let connection = RouterConnection(kind: .upnp, network: "home", networkName: "Home", url: "http://192.168.1.1:5000/ctl", entered: "http://192.168.1.1:5000/ctl")
        #expect(try RouterReaders.make(connection, secret: "", transport: RouterSession(pin: nil, trustAny: false)) is UPnPRouter)
    }

    @Test func aDescriptionNamesTheModel() {
        let named = Data("<root><device><friendlyName>Home gateway</friendlyName><modelName> Archer &amp; AX55 </modelName></device></root>".utf8)
        let friendly = Data("<root><device><friendlyName>Home gateway</friendlyName></device></root>".utf8)
        #expect(RouterCounters.modelName(description: named) == "Archer & AX55")
        #expect(RouterCounters.modelName(description: friendly) == "Home gateway")
        #expect(RouterCounters.modelName(description: Data("<root/>".utf8)) == nil)
    }

    @Test func aRouterWithOnlyUPnPIsFoundLast() async {
        struct Silent: RouterTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.cannotConnectToHost) }
        }
        let found = await RouterDetect.detect(gateway: "192.168.1.1", vendor: nil, transport: Silent()) { _ in
            RouterCounters.Device(control: "http://192.168.1.1:5000/ctl", model: "Archer AX55")
        }
        #expect(found == RouterDetect.Found(kind: .upnp, url: "http://192.168.1.1:5000/ctl", model: "Archer AX55"))
        #expect(await RouterDetect.detect(gateway: "192.168.1.1", vendor: nil, transport: Silent()) { _ in nil } == nil)
    }

    @Test func aLookalikePageFallsThroughToUPnP() async {
        struct Lookalike: RouterTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let body = "<html><head><style>body{font-family:Lucida Grande}</style></head><body>Unified login for your gateway</body></html>"
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let found = await RouterDetect.detect(gateway: "192.168.1.1", vendor: nil, transport: Lookalike()) { _ in
            RouterCounters.Device(control: "http://192.168.1.1:5000/ctl", model: "Archer AX55")
        }
        #expect(found == RouterDetect.Found(kind: .upnp, url: "http://192.168.1.1:5000/ctl", model: "Archer AX55"))
    }

    @Test func eachProbeNamesOnlyItsOwnRouter() async {
        struct Pages: RouterTransport {
            var pages: [String: String]
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = request.url!
                return (Data((pages[url.absoluteString] ?? "<html></html>").utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let unifi = await RouterDetect.detect(gateway: "192.168.1.1", vendor: nil, transport: Pages(pages: ["https://192.168.1.1/": "<title>UniFi OS</title>"])) { _ in nil }
        #expect(unifi == RouterDetect.Found(kind: .unifi, url: "https://192.168.1.1"))
        let luci = "<link rel=\"stylesheet\" href=\"/luci-static/bootstrap/cascade.css\"><title>OpenWrt - LuCI</title>"
        let refresh = "<meta http-equiv=\"refresh\" content=\"0; URL=cgi-bin/luci/\" />"
        let openwrt = await RouterDetect.detect(gateway: "192.168.1.1", vendor: nil,
                                                transport: Pages(pages: ["http://192.168.1.1/cgi-bin/luci/": luci, "http://192.168.1.1/": refresh])) { _ in nil }
        #expect(openwrt?.kind == .openwrt && openwrt?.url == "http://192.168.1.1")
    }

    @MainActor @Test func aUPnPRouterIsReadOftenEnoughForGigabit() {
        let unknown = HomeUsageStore.idleInterval(kind: .upnp, wan: nil)
        let known = HomeUsageStore.idleInterval(kind: .upnp, wan: RouterWAN(down: 1, up: 1, bits: 32))
        #expect(unknown < 18 && unknown >= HomeUsageStore.fast)
        #expect(known < 18 && known >= HomeUsageStore.fast)
    }

    @MainActor @Test func aSlowLineKeepsTheUsualInterval() {
        #expect(HomeUsageStore.idleInterval(kind: .fritzbox, wan: RouterWAN(down: 1, up: 1, bits: 32, downMax: 13_900_000, upMax: 5_000_000)) == HomeUsageStore.idleFritz)
    }

    @MainActor @Test func aFastLineIsReadSooner() {
        let gigabit = HomeUsageStore.idleInterval(kind: .fritzbox, wan: RouterWAN(down: 1, up: 1, bits: 32, downMax: 125_000_000))
        #expect(gigabit > 15 && gigabit < 18)
        #expect(HomeUsageStore.idleInterval(kind: .fritzbox, wan: RouterWAN(down: 1, up: 1, bits: 32, downMax: 312_500_000)) == HomeUsageStore.fast)
    }

    @MainActor @Test func sixtyFourBitRoutersAreUnchanged() {
        #expect(HomeUsageStore.idleInterval(kind: .unifi, wan: RouterWAN(down: 1, up: 1)) == HomeUsageStore.idle)
        #expect(HomeUsageStore.idleInterval(kind: nil, wan: nil) == HomeUsageStore.idle)
    }

    @MainActor @Test func aResetOnALineWithAKnownMaximumAddsNothingMuch() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let c = RouterConnection(kind: .upnp, network: "A", networkName: "A", url: "http://192.168.1.1", entered: "192.168.1.1")
        let home = HomeUsageStore(directory: nil, secrets: MemoryRouterSecrets())
        let before = RouterPoll(date: now - 60, clients: [], wan: RouterWAN(down: 3_000_000_000, up: 0, bits: 32, downMax: 1_000_000, upMax: 1_000_000), perDevice: false)
        let after = RouterPoll(date: now, clients: [], wan: RouterWAN(down: 5_000_000, up: 0, bits: 32, downMax: 1_000_000, upMax: 1_000_000), perDevice: false)
        home.ingest(before, connection: c, calendar: cal); home.ingest(after, connection: c, calendar: cal)
        #expect(home.ledger.today(now: now, calendar: cal, network: "A")[HomeUsageLedger.home]?.down == 5_000_000)
    }
}
