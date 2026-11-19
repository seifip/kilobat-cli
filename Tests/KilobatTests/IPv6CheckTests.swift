import Foundation
import Testing
@testable import KilobatCore

private func reading(global: Bool = true, route: Bool? = true, v4route: Bool = true, tunneled: Bool = false, reachable: Bool? = true, v4: Bool? = true) -> IPv6Reading {
    IPv6Reading(globalAddress: global, defaultRoute: route, ipv4Route: v4route, tunneled: tunneled, reachable: reachable, ipv4Reachable: v4)
}

private actor Counter {
    private(set) var count = 0
    func add() { count += 1 }
}

@Suite("IPv6 check")
struct IPv6CheckTests {
    @Test("the verdict table, first matching row wins", arguments: [
        (reading(tunneled: true, reachable: false), IPv6Verdict.unknown),
        (reading(global: false, reachable: nil), .none),
        (reading(global: false, route: true), .none),
        (reading(route: nil), .unknown),
        (reading(route: false, v4: true), .none),
        (reading(reachable: nil), .unknown),
        (reading(), .working),
        (reading(v4: false), .working),
        (reading(v4route: false, reachable: true, v4: nil), .ipv6Only),
        (reading(v4route: false, reachable: true, v4: true), .ipv6Only),
        (reading(reachable: false, v4: true), .advertisedButBroken),
        (reading(reachable: false, v4: false), .unknown),
        (reading(reachable: false, v4: nil), .unknown),
        (reading(v4route: false, reachable: false, v4: nil), .unknown),
    ])
    func verdict(input: IPv6Reading, expected: IPv6Verdict) {
        #expect(IPv6Check.verdict(input) == expected)
    }

    @Test("two failures in a row, on one network")
    func confirmed() {
        let broken = IPv6Verdict.advertisedButBroken
        #expect(!IPv6Check.confirmed([broken]))
        #expect(IPv6Check.confirmed([broken, broken]))
        #expect(!IPv6Check.confirmed([.working, broken]))
        #expect(!IPv6Check.confirmed([broken, .working, broken]))
        #expect(IPv6Check.confirmed([broken, .unknown, broken, broken]))
        #expect(!IPv6Check.confirmed([]))
    }

    @Test("routes come from the primary interface of each family")
    func routes() {
        let en0: [String: Any] = ["PrimaryInterface": "en0"]
        #expect(IPv6Probe.routes(ipv4: en0, ipv6: nil) == ("en0", nil))
        #expect(IPv6Probe.routes(ipv4: en0, ipv6: en0) == ("en0", "en0"))
        #expect(IPv6Probe.routes(ipv4: nil, ipv6: en0) == (nil, "en0"))
        #expect(IPv6Probe.routes(ipv4: nil, ipv6: nil) == (nil, nil))
        #expect(IPv6Probe.routes(ipv4: ["PrimaryInterface": ""], ipv6: [:]) == (nil, nil))
    }

    @Test("the findings are gated and worded as measured")
    func findings() throws {
        #expect(IPv6Check.finding(.advertisedButBroken, confirmed: false) == nil)
        let broken = try #require(IPv6Check.finding(.advertisedButBroken, confirmed: true))
        #expect(broken.level == .caution)
        #expect(broken.title == "IPv6 isn’t connecting on this network")
        #expect(broken.detail == "This Mac has an IPv6 address and route here, but connections to Cloudflare and Google over IPv6 didn’t go through, twice in a row. A connection to Cloudflare over IPv4 did. If some apps are slow to connect, restart your router; if it stays like this, check its IPv6 settings or ask your provider.")
        #expect(broken.help == "This Mac has an IPv6 address and route here, but connections to Cloudflare and Google over IPv6 didn’t go through, twice in a row. A connection to Cloudflare over IPv4 did.")
        let only = try #require(IPv6Check.finding(.ipv6Only, confirmed: false))
        #expect(only.level == .fine)
        #expect(only.title == "No IPv4 on this network")
        for verdict in [IPv6Verdict.working, .none, .unknown] {
            #expect(IPv6Check.finding(verdict, confirmed: false) == nil)
            #expect(IPv6Check.finding(verdict, confirmed: true) == nil)
        }
        for text in [broken.title, broken.detail, broken.help, only.title, only.detail] {
            for claim in ["slow down", "your provider is", "turn off IPv6", "outage"] { #expect(!text.contains(claim)) }
        }
    }

    @Test("a reading keeps no address")
    func noAddress() throws {
        let data = try JSONEncoder().encode(reading())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for forbidden in ["address", "source", "host", "ip"] { #expect(!object.keys.contains(forbidden)) }
        #expect(try JSONDecoder().decode(IPv6Reading.self, from: data) == reading())
        let summary = IPv6Summary(reading(reachable: false, v4: true), confirmed: true)
        #expect(summary.verdict == .advertisedButBroken && summary.confirmed)
    }

    @Test("the address classifier")
    func classifier() {
        #expect(IPv6Facts.kind("2001:db8::1") == .global)
        #expect(IPv6Facts.kind("2606:4700:4700::1111") == .global)
        #expect(IPv6Facts.kind("fe80::1%en0") == .linkLocal)
        #expect(IPv6Facts.kind("fd12:3456::1") == .unique)
        #expect(IPv6Facts.kind("::1") == .other)
    }

    @Test("the schedule: first run, every 15 minutes, a minute after a first failure, metered left alone")
    func schedule() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func due(_ ago: Double?, _ last: IPv6Verdict? = .working, confirmed: Bool = false, metered: Bool = false, forced: Bool = false) -> Bool {
            IPv6Check.due(now: now, lastRun: ago.map { now.addingTimeInterval(-$0) }, lastVerdict: last, confirmed: confirmed, metered: metered, forced: forced)
        }
        #expect(due(nil))
        #expect(due(nil, metered: true))
        #expect(!due(60))
        #expect(!due(14 * 60))
        #expect(due(15 * 60))
        #expect(!due(30, .advertisedButBroken))
        #expect(due(60, .advertisedButBroken))
        #expect(!due(60, .advertisedButBroken, confirmed: true))
        #expect(!due(3600, metered: true))
        #expect(due(5, metered: true, forced: true))
    }

    @Test("a network without IPv6 opens no connection")
    func opensNothing() async {
        let calls = Counter()
        let connector: IPv6Probe.Connector = { _, _ in await calls.add(); return true }
        let none = await IPv6Probe.reading(connect: true, local: IPv6Probe.Local(ipv4Interface: "en0", ipv6Interface: nil, globalAddress: false), connector: connector)
        #expect(IPv6Check.verdict(none) == .none)
        let linkOnly = await IPv6Probe.reading(connect: true, local: IPv6Probe.Local(ipv4Interface: "en0", ipv6Interface: "en0", globalAddress: false), connector: connector)
        #expect(IPv6Check.verdict(linkOnly) == .none)
        let tunnel = await IPv6Probe.reading(connect: true, local: IPv6Probe.Local(ipv4Interface: "utun4", ipv6Interface: "utun4", globalAddress: true), connector: connector)
        #expect(IPv6Check.verdict(tunnel) == .unknown)
        let unread = await IPv6Probe.reading(connect: true, local: IPv6Probe.Local(readable: false, globalAddress: true), connector: connector)
        #expect(unread.defaultRoute == nil)
        #expect(await calls.count == 0)
    }

    @Test("the connects: both IPv6 targets must fail, IPv4 is compared")
    func connects() async {
        let local = IPv6Probe.Local(ipv4Interface: "en0", ipv6Interface: "en0", globalAddress: true)
        func run(_ connects: @escaping @Sendable (String, Bool) -> Bool) async -> IPv6Verdict {
            IPv6Check.verdict(await IPv6Probe.reading(connect: true, local: local, connector: { host, v6 in connects(host, v6) }))
        }
        #expect(await run({ _, _ in true }) == .working)
        #expect(await run({ host, v6 in !v6 || host == IPv6Check.targets6[1] }) == .working)
        #expect(await run({ _, v6 in !v6 }) == .advertisedButBroken)
        #expect(await run({ _, _ in false }) == .unknown)
        let stateOnly = await IPv6Probe.reading(connect: false, local: local, connector: { _, _ in Issue.record("connected"); return true })
        #expect(stateOnly.reachable == nil && stateOnly.ipv4Reachable == nil)
        let v6Only = IPv6Probe.Local(ipv4Interface: nil, ipv6Interface: "en0", globalAddress: true)
        let noV4 = await IPv6Probe.reading(connect: true, local: v6Only, connector: { _, v6 in v6 })
        #expect(IPv6Check.verdict(noV4) == .ipv6Only)
    }

    @MainActor @Test("the watch shows a failure on the second reading, never the first, and forgets it on another network")
    func watch() async {
        let watch = IPv6Watch()
        let state = reading(reachable: nil, v4: nil), broken = reading(reachable: false, v4: true), fine = reading()
        var answers = [broken, broken, fine, broken]
        watch.probe = { connect in connect ? answers.removeFirst() : state }
        let start = Date(timeIntervalSince1970: 2_000_000)
        await watch.observe(network: "a", portal: false, metered: false, now: start)
        #expect(watch.verdict == .advertisedButBroken && watch.finding == nil)
        await watch.observe(network: "a", portal: false, metered: false, now: start.addingTimeInterval(30))
        #expect(watch.finding == nil && answers.count == 3)
        await watch.observe(network: "a", portal: false, metered: false, now: start.addingTimeInterval(61))
        #expect(watch.finding?.id == "ipv6:advertisedButBroken")
        await watch.observe(network: "a", portal: true, metered: false, now: start.addingTimeInterval(62))
        #expect(watch.finding == nil)
        await watch.observe(network: "a", portal: false, metered: false, forced: true, now: start.addingTimeInterval(63))
        #expect(watch.finding == nil && watch.verdict == .working)
        await watch.observe(network: "b", portal: false, metered: false, now: start.addingTimeInterval(64))
        #expect(watch.verdict == .advertisedButBroken && watch.finding == nil)
    }
}
