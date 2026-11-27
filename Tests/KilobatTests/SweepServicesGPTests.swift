import Foundation
import Testing
@testable import KilobatCore

struct SweepServicesGPTests {
    @Test func orderedJSONReadsOnlyRealSurrogatePairs() throws {
        let u = "\\u"
        func parsed(_ escapes: String) throws -> String? { try OrderedJSON.parse("{\"a\": \"" + escapes + "\"}")["a"]?.string }
        #expect(try parsed(u + "d83d" + u + "0041") == "\u{FFFD}A")
        #expect(try parsed(u + "d83d" + u + "d83d") == "\u{FFFD}\u{FFFD}")
        #expect(try parsed(u + "d83d" + u + "ffff") == "\u{FFFD}\u{FFFF}")
        #expect(try parsed(u + "d83d" + u + "de00") == "\u{1F600}")
    }

    @Test func sniffingStopsAtAFirstLineThatIsNotHTTP() {
        #expect(FlowSniffer.sniff(Array("GET key\r\n".utf8)) == .unknown)
        #expect(FlowSniffer.sniff(Array("GET /\r\n".utf8)) == .unknown)
        #expect(FlowSniffer.sniff(Array("CONNECT {\"verbose\":false}\r\nPING\r\n".utf8)) == .unknown)
        guard case .needMore = FlowSniffer.sniff(Array("GET / HTTP/1.1\r\nHost: tracker.exa".utf8)) else {
            Issue.record("An unfinished HTTP header was decided")
            return
        }
    }

    @Test func sniffingReadsABareLineFeedHeader() {
        #expect(FlowSniffer.sniff(Array("GET / HTTP/1.0\nHost: Tracker.Example\n\n".utf8)) == .name("tracker.example"))
        #expect(FlowSniffer.sniff(Array("GET / HTTP/1.1\r\nHost: example.com\n\r\n".utf8)) == .name("example.com"))
    }

    @MainActor @Test func mcpServerSkipsAReplyItCannotWrite() async {
        var written: [Data] = []
        let server = MCPServer(name: "kilobat", title: "Kilobat", version: "1.0", instructions: "", tools: []) { written.append($0) }
        server.receive(Data(#"{"jsonrpc":"2.0","id":-1e999,"method":"ping"}"#.utf8))
        await server.drain()
        server.receive(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8))
        await server.drain()
        #expect(written.count == 1)
        let reply = written.first.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(reply?["id"] as? Int == 2)
    }

    @Test func macLoadSurvivesATickCounterWrap() {
        let before = MacLoad.Ticks(user: 100, system: 50, idle: 4_294_967_000, nice: 0)
        let after = MacLoad.Ticks(user: 200, system: 50, idle: 604, nice: 0)
        #expect(MacLoad.share(from: before, to: after) == 10)
        #expect(MacLoad.share(from: before, to: before) == nil)
    }

    @Test func leakTestReadsAMissingIPv6Route() {
        let missing = "route: writing to routing socket: not in table\n"
        #expect(LeakTest.ipv6Route(CommandResult(output: missing, status: 0)) == (nil, true))
        #expect(LeakTest.ipv6Route(CommandResult(output: missing, status: 1)) == (nil, true))
        #expect(LeakTest.ipv6Route(CommandResult(output: "   route to: 2606:4700:4700::1111\n  interface: utun4\n", status: 0)) == ("utun4", false))
        #expect(LeakTest.ipv6Route(CommandResult(output: "", status: -1)) == (nil, false))
    }

    @Test func leakTestUDPNeedsAnIPv4Exit() {
        var seen = LeakTest.Observations(exit: ExitPath(interface: "utun4", connected: ["Mullvad"]))
        seen.resolvers = [LeakTest.Resolver(servers: ["10.64.0.1"])]
        seen.resolverRoutes = ["10.64.0.1": "utun4"]
        seen.exitSeen = .init(address: "198.51.100.7", asn: "AS39351", org: "31173 Services AB", country: "se")
        seen.dnsSeen = [.init(address: "198.51.100.53", asn: "AS39351", org: "31173 Services AB", country: "se")]
        seen.ipv6Interface = "utun4"
        seen.physical = "en0"; seen.physicalPort = "Wi-Fi"
        seen.udpAsked = true; seen.udpInterfaces = ["en0"]; seen.udpDefault = "198.51.100.7:40211"
        seen.exitAddress = "198.51.100.7"
        #expect(LeakTest.evaluate(seen).checks.first { $0.id == "udp" }?.status == .pass)
        seen.exitAddress = "2001:db8::7"
        #expect(LeakTest.evaluate(seen).checks.first { $0.id == "udp" }?.status == .warning)
    }
}
