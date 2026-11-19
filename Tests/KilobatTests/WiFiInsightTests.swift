import Foundation
import Testing
@testable import KilobatCore

/// Wake timing, the private Wi-Fi address and roam analysis, on fixtures captured from macOS 27.
struct WakeTimingTests {
    private let woke = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func linkStateFromSystemConfiguration() {
        #expect(WakeProbe.linkActive(["Active": true]) == true)
        #expect(WakeProbe.linkActive(["Active": NSNumber(value: false)]) == false)
        #expect(WakeProbe.linkActive([:]) == nil)
        #expect(WakeProbe.linkActive(nil) == nil)
    }
    @Test func selfAssignedAddressesDontCount() {
        #expect(WakeProbe.usableAddress("192.168.33.162"))
        #expect(!WakeProbe.usableAddress("169.254.12.7"))
        #expect(!WakeProbe.usableAddress("0.0.0.0"))
    }
    @Test func digAnswerParses() {
        let answered = """
        ; <<>> DiG 9.10.6 <<>> +time=1 +tries=1 apple.com A
        ;; global options: +cmd
        ;; Got answer:
        ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 52012
        ;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

        ;; ANSWER SECTION:
        apple.com.\t\t1200\tIN\tA\t17.253.144.10

        ;; Query time: 31 msec
        """
        #expect(WakeProbe.dnsAnswered(dig: answered))
        #expect(!WakeProbe.dnsAnswered(dig: ";; connection timed out; no servers could be reached\n"))
        #expect(!WakeProbe.dnsAnswered(dig: ";; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n"))
    }

    @Test func watchKeepsFirstTimesAndFillsEarlierStages() {
        var watch = WakeWatch(woke: woke, interface: "en0", wired: false)
        watch.observe(at: 0.2, link: false, address: false)
        watch.observe(at: 1.4, link: true, address: false)
        watch.observe(at: 1.9, link: true, address: false)
        watch.observe(at: 3.1, link: true, address: true)
        watch.dnsAnswered(at: 3.6)
        watch.internetAnswered(at: 4.2)
        watch.pingAnswered(at: 3.9)
        #expect(watch.record.link == 1.4 && watch.record.address == 3.1 && watch.record.dns == 3.6 && watch.record.internet == 4.2)
        #expect(watch.done(at: 4.3))
        // An address seen with no link reading means the link was up too.
        var quiet = WakeWatch(woke: woke, interface: nil, wired: true)
        quiet.observe(at: 0.5, link: nil, address: true)
        #expect(quiet.record.link == 0.5 && quiet.record.address == 0.5)
        #expect(!quiet.done(at: 0.5))
    }
    @Test func quickWakeIsFine() {
        let wake = WakeRecord(woke: woke, interface: "en0", wired: false, link: 0.4, address: 2.1, dns: 2.3, internet: 2.8, ping: 2.5, watched: 3)
        #expect(wake.problem == .none && wake.advice == nil)
        #expect(wake.stagesLine.contains("Link 0.4 s") && wake.stagesLine.contains("Internet 2.8 s"))
    }
    @Test func slowAddressIsNamed() {
        // The link back at once, the router's address 14 s later.
        let wake = WakeRecord(woke: woke, interface: "en0", wired: false, link: 1.0, address: 15.2, dns: 15.6, internet: 16.1, ping: 15.9, watched: 17)
        #expect(wake.problem == .slow(.address, seconds: 15.2 - 1.0))
        #expect(wake.advice?.contains("router") == true)
    }
    @Test func wiredLinkThatNeverCameBack() {
        // The Mac mini and dock cases: no link for the whole watch.
        let wake = WakeRecord(woke: woke, interface: "en5", wired: true, watched: 90)
        #expect(wake.problem == .never(.link))
        #expect(wake.title.contains("cable"))
        #expect(wake.advice?.contains("dock") == true)
        #expect(wake.plainProblem == "link never came back")
    }
    @Test func tunnelPassingPingButNotTCP() {
        // Tailscale #20859: ICMP answered, TCP dead, the app showing connected.
        var watch = WakeWatch(woke: woke, interface: "en0", wired: false)
        watch.observe(at: 0.8, link: true, address: true)
        watch.dnsAnswered(at: 1.2)
        watch.pingAnswered(at: 1.5)
        watch.tunnel(vpn: "Tailscale", full: true)
        let wake = watch.record
        #expect(wake.problem == .tunnelNoTCP && wake.tunnelTCP == false)
        #expect(wake.title.contains("Tailscale"))
        #expect(wake.plainLine.contains("tunnel passed no TCP (ping did)"))
    }
    @Test func splitTunnelIsNotJudged() {
        var watch = WakeWatch(woke: woke, interface: "en0", wired: false)
        watch.tunnel(vpn: "Work VPN", full: false)
        #expect(watch.record.vpn == nil && watch.record.tunnelTCP == nil)
    }
    @MainActor @Test func journalKeepsWakesAndLogsOnlyBadOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = NetworkJournal(directory: folder)
        journal.addWake(WakeRecord(woke: woke, interface: "en0", wired: false, link: 0.4, address: 1, dns: 1.2, internet: 1.5, ping: 1.3, watched: 2))
        journal.addWake(WakeRecord(woke: woke.addingTimeInterval(3600), interface: "en0", wired: false, network: "Home", link: 0.4, watched: 90))
        #expect(journal.wakes.count == 2)
        #expect(journal.events.filter { $0.kind == "Slow wake" }.count == 1)
        #expect(NetworkJournal(directory: folder).wakes.count == 2)
        #expect(journal.recentWake(within: 900, now: woke.addingTimeInterval(3700))?.network == "Home")
        #expect(journal.recentWake(within: 900, now: woke.addingTimeInterval(9000)) == nil)
    }
    @Test func historyCommandParses() throws {
        #expect(try WiFiHistoryCommand.parse(["wakes"]) == .wakes(days: 7))
        #expect(try WiFiHistoryCommand.parse(["wakes", "--days", "30"]) == .wakes(days: 30))
        #expect(try WiFiHistoryCommand.parse(["roams", "--hours", "48", "--csv"]) == .roams(hours: 48, format: .csv))
        #expect(try WiFiHistoryCommand.parse(["roams", "--text"]) == .roams(hours: 24, format: .text))
        #expect(throws: DiagnosticError.self) { try WiFiHistoryCommand.parse(["roams", "--csv", "--text"]) }
        #expect(throws: DiagnosticError.self) { try WiFiHistoryCommand.parse(["wakes", "--days", "0"]) }
        #expect(throws: DiagnosticError.self) { try WiFiHistoryCommand.parse(["wakes", "--csv"]) }
    }
}

struct PrivateWiFiAddressTests {
    /// `ifconfig en0` on macOS 27 run from Terminal: the per-network address.
    static let ifconfig = """
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \toptions=6460<TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
    \tether ce:3e:80:2e:8e:92
    \tinet6 fe80::1c8b:2f9a:8e1d:4c2b%en0 prefixlen 64 secured scopeid 0xb
    \tinet 192.168.33.162 netmask 0xffffff00 broadcast 192.168.33.255
    \tmedia: autoselect
    \tstatus: active
    """
    /// The same from a third-party app: macOS 27 hides the address.
    static let redactedIfconfig = ifconfig.replacingOccurrences(of: "ce:3e:80:2e:8e:92", with: "02:00:00:00:00:00")
    static let ports = """

    Hardware Port: Ethernet Adapter (en4)
    Device: en4
    Ethernet Address: 9e:2b:31:aa:10:02

    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: a0:9a:8e:10:ce:46

    Hardware Port: Thunderbolt Bridge
    Device: bridge0
    Ethernet Address: N/A

    VLAN Configurations
    ===================
    """
    static let packet = """
    op = BOOTREPLY
    htype = 1
    flags = 0x0
    hlen = 6
    hops = 0
    xid = 0x3ec8c26b
    secs = 0
    ciaddr = 0.0.0.0
    yiaddr = 192.168.33.162
    siaddr = 192.168.33.1
    giaddr = 0.0.0.0
    chaddr = ce:3e:80:2e:8e:92
    sname =
    file =
    options:
    Options count is 11
    dhcp_message_type (uint8): ACK 0x5
    """

    @Test func parsesEachSource() {
        #expect(PrivateWiFiAddress.parseEther(Self.ifconfig) == "ce:3e:80:2e:8e:92")
        #expect(PrivateWiFiAddress.parseEther(Self.redactedIfconfig) == nil)
        #expect(PrivateWiFiAddress.parseHardwarePorts(Self.ports) == ["en4": "9e:2b:31:aa:10:02", "en0": "a0:9a:8e:10:ce:46"])
        #expect(PrivateWiFiAddress.parseChaddr(Self.packet) == "ce:3e:80:2e:8e:92")
        #expect(PrivateWiFiAddress.parseChaddr("") == nil)
        #expect(PrivateWiFiAddress.parseChaddr(Self.packet.replacingOccurrences(of: "htype = 1", with: "htype = 32")) == nil)
    }
    @Test func privateWhenTheRouterSeesAnotherAddress() {
        let state = WiFiAddressState(interface: "en0", current: "CE:3E:80:2E:8E:92", hardware: "a0:9a:8e:10:ce:46")
        #expect(state.isPrivate == true && state.current == "ce:3e:80:2e:8e:92")
        #expect(PrivateWiFiAddress.routerNote(state).contains("ce:3e:80:2e:8e:92"))
        #expect(PrivateWiFiAddress.value(state) == "On · ce:3e:80:2e:8e:92")
        let off = WiFiAddressState(interface: "en0", current: "a0:9a:8e:10:ce:46", hardware: "a0:9a:8e:10:ce:46")
        #expect(off.isPrivate == false)
        #expect(PrivateWiFiAddress.advice(off, drops: 9) == nil)
        // No hardware address: a locally administered one is private, a universal one can't be told.
        #expect(WiFiAddressState(interface: "en0", current: "ce:3e:80:2e:8e:92", hardware: nil).isPrivate == true)
        #expect(WiFiAddressState(interface: "en0", current: "a0:9a:8e:10:ce:46", hardware: nil).isPrivate == nil)
    }
    @Test func adviceOnlyAfterDrops() {
        let state = WiFiAddressState(interface: "en0", current: "ce:3e:80:2e:8e:92", hardware: "a0:9a:8e:10:ce:46")
        #expect(PrivateWiFiAddress.advice(state, drops: 1) == nil)
        #expect(PrivateWiFiAddress.advice(state, drops: 3)?.contains("Fixed") == true)
    }
    @Test func dropsCountLostRouterOutagesThisWeek() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func outage(_ ago: TimeInterval, answered: Int, network: String = "home") -> NetworkEvent {
            NetworkEvent(start: now.addingTimeInterval(-ago), end: now.addingTimeInterval(-ago + 60), network: "Home", kind: "Unreachable", detail: "",
                         routerChecks: 3, routerAnswered: answered, networkKey: network)
        }
        let events = [outage(3600, answered: 0), outage(7200, answered: 0), outage(9000, answered: 3), outage(8 * 86_400, answered: 0), outage(600, answered: 0, network: "cafe")]
        #expect(PrivateWiFiAddress.drops(events, network: "home", now: now) == 2)
        #expect(PrivateWiFiAddress.drops(events, network: nil, now: now) == 0)
    }
}

struct RoamAnalysisTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let living = "a4:2b:b0:10:00:30", office = "a4:2b:b0:20:00:30", upstairs = "a4:2b:b0:30:00:30"

    private func reading(_ minutes: Double, on bssid: String?, rssi: Int = -55, scan: [NodeRadio] = []) -> NodeReading {
        NodeReading(date: start.addingTimeInterval(minutes * 60), ssid: "Example Home",
                    current: bssid.map { NodeRadio(bssid: $0, rssi: rssi, channel: 36, band: "5 GHz", widthMHz: 80) }, transmitMbps: nil, scan: scan)
    }
    private func walk() -> RoamLog {
        var log = RoamLog()
        // Twenty minutes in the living room, a slow fade, then a roam to the office at −77 dBm.
        for minute in stride(from: 0.0, through: 20, by: 1) { log.observe(reading(minute, on: living, rssi: -55 - Int(minute)), network: "home") }
        // Forty minutes in the office, with the upstairs node heard 20 dB stronger for a while.
        let upstairsRadio = NodeRadio(bssid: upstairs, rssi: -52, channel: 149, band: "5 GHz", widthMHz: 80)
        for minute in stride(from: 21.0, through: 60, by: 1) {
            let scan = (30...34).contains(Int(minute)) ? [upstairsRadio, NodeRadio(bssid: office, rssi: -73, channel: 36, band: "5 GHz", widthMHz: 80)] : []
            log.observe(reading(minute, on: office, rssi: -72, scan: scan), network: "home")
        }
        // A brief hop to upstairs and straight back.
        log.observe(reading(60.5, on: upstairs, rssi: -60), network: "home")
        log.observe(reading(61, on: office, rssi: -70), network: "home")
        return log
    }

    @Test func staysEndInRoamsWithTheSignalBeforeIt() {
        let log = walk()
        #expect(log.visits.count == 4)
        let first = log.visits[0]
        #expect(first.bssid == living && first.ended == .roam && first.next == office)
        #expect(first.firstRSSI == -55 && first.lastRSSI == -75 && first.dwell == 20 * 60)
        #expect(log.open?.bssid == office)
    }
    @Test func aClearlyBetterNodeIgnoredIsKept() {
        let office = walk().visits[1]
        let ignored = office.ignored
        #expect(ignored?.bssid == upstairs && ignored?.difference == 20 && ignored?.seconds == 4 * 60)
    }
    @Test func summaryCountsLateAndBriefRoams() {
        let summary = RoamSummary(walk(), network: "home", since: start, names: [living: "Living room", office: "Office"])
        #expect(summary.roams == 3 && summary.late == 1 && summary.brief == 1 && summary.ignored.count == 1)
        #expect(summary.accessPoints.first?.bssid == office && summary.accessPoints.first?.name == "Office")
        #expect(summary.accessPoints.first { $0.bssid == living }?.leftAt == -75)
        #expect(summary.headline.contains("3 roams"))
        let line = summary.ignoredLines(names: [office: "Office"]).first
        #expect(line?.contains("Office") == true && line?.contains("20 dB") == true)
    }
    @Test func gapsAndLeavingEndAStay() {
        var log = RoamLog()
        log.observe(reading(0, on: living), network: "home")
        log.observe(reading(1, on: living), network: "home")
        // Asleep for an hour: the stay ends at its last reading, and a new one starts.
        log.observe(reading(61, on: living), network: "home")
        #expect(log.visits.count == 2 && log.visits[0].ended == .gap && log.visits[0].dwell == 60)
        log.observe(reading(62, on: nil), network: "home")
        #expect(log.visits[1].ended == .left)
        // Another network starts its own stay; the old one isn't a roam.
        log.observe(reading(63, on: living), network: "home")
        log.observe(reading(64, on: "11:22:33:44:55:66"), network: "cafe")
        #expect(log.visits[2].ended == .left && log.visits[2].next == nil && log.visits[3].network == "cafe")
        log.interrupt()
        #expect(log.open == nil)
    }
    @Test func oldStaysArePruned() {
        var log = RoamLog()
        log.observe(reading(0, on: living), network: "home")
        log.observe(reading(1, on: office), network: "home")
        log.observe(reading(15 * 24 * 60, on: office), network: "home")
        #expect(log.visits.count == 1)
    }
    @Test func csvIsOneRowPerStayAndQuoted() {
        let summary = RoamSummary(walk(), network: "home", since: start)
        let csv = summary.csv(names: [office: "Office, upstairs \"east\""])
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("ssid,access_point,node_name"))
        #expect(lines[2].contains("\"Office, upstairs \"\"east\"\"\"") && lines[2].contains(upstairs) && lines[2].contains(",20,"))
        #expect(lines[1].contains(",1200,-55,-75,-75,21,roam,\(office),"))
        #expect(lines[4].contains(",current,"))
    }
    @Test func textReportIsPlainEnglish() {
        let text = RoamSummary(walk(), network: "home", since: start).text(names: [:], mac: "MacBookAir10,1", system: "Version 27.1")
        #expect(text.contains("Mac: MacBookAir10,1 · Version 27.1"))
        #expect(text.contains("Roams: 3 · at -75 dBm or weaker: 1"))
        #expect(text.contains("roamed to \(office)") && text.contains("still connected"))
        #expect(text.contains("\(upstairs) heard at -52 dBm (20 dB stronger)"))
    }
    @MainActor @Test func nodeWatchSavesTheLogForTheCLI() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("roams-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let watch = NodeWatch(directory: folder)
        watch.ingest(reading(0, on: living), network: "home")
        watch.ingest(reading(1, on: office), network: "home")
        let saved = NodeWatch.saved(directory: folder)
        #expect(saved.roams.visits.count == 2 && saved.roams.visits[0].ended == .roam)
    }
}
