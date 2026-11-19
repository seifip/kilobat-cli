import Foundation
import Testing
@testable import KilobatCore

struct SplitProxyCheckTests {
    typealias Host = SplitProxyCheck.Host
    func hosts(_ timings: [(Int, Int)]) -> [Host] { timings.enumerated().map { Host(name: "site\($0.offset)", tcpMs: $0.element.0, tlsMs: $0.element.1) } }
    func failing(_ count: Int, _ failure: SplitProxyCheck.Failure) -> [Host] { (0..<count).map { Host(name: "bad\($0)", failure: failure) } }

    @Test func aFastHandshakeThenASlowExchangeOnMostSitesIsAProxy() {
        #expect(SplitProxyCheck.verdict(hosts([(18, 720), (22, 810), (16, 690), (25, 940), (19, 760), (21, 700)])) == .proxyLikely)
        // Resets on top don't change what the timing shows.
        #expect(SplitProxyCheck.verdict(hosts([(18, 720), (22, 810), (16, 690), (25, 940)]) + failing(2, .reset)) == .proxyLikely)
    }

    @Test func ordinaryLinksAreNotAProxy() {
        // Home broadband: TLS is a little slower than TCP, and nothing is slow.
        #expect(SplitProxyCheck.verdict(hosts([(12, 31), (14, 38), (9, 25), (20, 44), (11, 30), (13, 33)])) == .noProxy)
        // A geostationary link with no proxy: TCP pays the full delay too.
        #expect(SplitProxyCheck.verdict(hosts([(620, 680), (640, 700), (610, 660), (655, 720), (630, 690), (625, 670)])) == .noProxy)
        // An office proxy on a fast line: a wide ratio, but nothing slow.
        #expect(SplitProxyCheck.verdict(hosts([(2, 40), (2, 45), (3, 50), (2, 38), (2, 41), (3, 44)])) == .noProxy)
        // One or two slow servers aren't the network.
        #expect(SplitProxyCheck.verdict(hosts([(18, 720), (22, 810), (14, 30), (16, 35), (11, 28), (13, 33)])) == .noProxy)
    }

    @Test func aRatioOnASlowTCPIsNotAProxy() {
        #expect(!Host(name: "a", tcpMs: 150, tlsMs: 900).looksProxied)
        #expect(!Host(name: "a", tcpMs: 90, tlsMs: 400).looksProxied)
        #expect(Host(name: "a", tcpMs: 60, tlsMs: 300).looksProxied)
        #expect(!Host(name: "a", failure: .reset).looksProxied)
    }

    @Test func failuresSideBySideAreSaidApartFromADeadLink() {
        #expect(SplitProxyCheck.verdict(hosts([(40, 90), (45, 95), (38, 88)]) + failing(3, .reset)) == .parallelFailures)
        #expect(SplitProxyCheck.verdict(hosts([(40, 90), (45, 95), (38, 88), (41, 90)]) + failing(2, .timeout)) == .parallelFailures)
        #expect(SplitProxyCheck.verdict(hosts([(40, 90), (45, 95), (38, 88), (41, 90), (39, 85)]) + failing(1, .reset)) == .noProxy)
        // Nothing got through, or blocked for another reason: not enough to say anything.
        #expect(SplitProxyCheck.verdict(failing(6, .reset)) == .notEnoughData)
        #expect(SplitProxyCheck.verdict(hosts([(40, 90)]) + failing(5, .other)) == .notEnoughData)
        #expect(SplitProxyCheck.verdict([]) == .notEnoughData)
    }

    @Test func aVPNOrSignInPageIsSaidInsteadOfMeasured() {
        #expect(SplitProxyCheck(network: "n", hosts: [], vpn: true).verdict == .behindVPN)
        #expect(SplitProxyCheck(network: "n", hosts: [], portal: true).verdict == .signInFirst)
    }

    @Test func itIsOfferedOnSlowOrPingBlockedLinksOnly() {
        #expect(SplitProxyCheck.worthOffering(pingMs: 620, dnsWorks: true, vpn: false, portal: false))
        #expect(!SplitProxyCheck.worthOffering(pingMs: 30, dnsWorks: true, vpn: false, portal: false))
        #expect(SplitProxyCheck.worthOffering(pingMs: nil, dnsWorks: true, vpn: false, portal: false))
        #expect(!SplitProxyCheck.worthOffering(pingMs: nil, dnsWorks: false, vpn: false, portal: false))
        #expect(!SplitProxyCheck.worthOffering(pingMs: 620, dnsWorks: true, vpn: true, portal: false))
        #expect(!SplitProxyCheck.worthOffering(pingMs: 620, dnsWorks: true, vpn: false, portal: true))
    }

    @Test func aResultBelongsToItsNetworkAndGoesStale() {
        let now = Date(timeIntervalSince1970: 1_000_000), check = SplitProxyCheck(date: now, network: "plane", hosts: [])
        #expect(check.isCurrent(network: "plane", now: now.addingTimeInterval(60)))
        #expect(!check.isCurrent(network: "home", now: now.addingTimeInterval(60)))
        #expect(!check.isCurrent(network: "plane", now: now.addingTimeInterval(SplitProxyCheck.freshFor + 1)))
    }

    @Test func failuresAreClassifiedFromTheProbesOwnWords() {
        func host(_ outcome: ConnectionProbe.Attempt.Outcome) -> Host { SplitProxyProbe.host("a", ConnectionProbe.Attempt(outcome: outcome)) }
        #expect(host(.failed(String(cString: strerror(ECONNRESET)).lowercased())).failure == .reset)
        #expect(host(.timedOut).failure == .timeout)
        #expect(host(.refused).failure == .other)
        #expect(host(.tlsFailed("certificate name does not match")).failure == .other)
        // A connection that reports no handshake timings can't count as measured.
        #expect(host(.connected).failure == .other)
    }

    @Test func theWordingNeverClaimsAFixOrNamesACauseItCantShow() {
        let plane = SplitProxyCheck(network: "n", hosts: hosts([(18, 720), (22, 810), (16, 690), (25, 940), (19, 760), (21, 700)]))
        #expect(plane.isConcern && plane.detail.contains("about 20 ms") && plane.title.contains("seems"))
        for line in [plane.title, plane.detail, plane.advice] { #expect(!line.lowercased().contains("faster") && !line.lowercased().contains("speed up")) }
    }
}
