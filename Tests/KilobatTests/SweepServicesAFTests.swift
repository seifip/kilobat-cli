import Foundation
import Testing
@testable import KilobatCore

/// Regression tests for defects found in Services, files A to F.
@Suite struct SweepServicesAFTests {
    // MARK: AgentProcessTree

    @Test func processesThatExitedLeaveTheOutsideCache() {
        let table = FakeTable()
        table.add(100, parent: 1, "claude", path: "/opt/homebrew/bin/claude", arguments: ["claude"])
        table.add(500, parent: 1, "curl", path: "/usr/bin/curl")
        let tree = AgentProcessTree(source: table.source)
        tree.discover()
        #expect(tree.owner(pid: 500) == nil)
        #expect(tree.outsideCount == 1)
        table.exit(500)
        tree.discover()
        #expect(tree.outsideCount == 0)
    }

    // MARK: ConnectionProbe.scrubbed

    @Test func aShortQueryOrPasswordIsNotReplacedInsideOtherText() throws {
        let text = "example.com → 1.2.3.4 in 25 ms, HTTP 503"
        #expect(ConnectionProbe.scrubbed(text, [try #require(URL(string: "https://example.com/a.js?5"))]) == text)
        let scrubbed = ConnectionProbe.scrubbed("failed for https://u:a@example.com/ again and again", [try #require(URL(string: "https://u:a@example.com/"))])
        #expect(scrubbed.contains("again and again") && !scrubbed.contains(":a@"))
    }

    // MARK: CaptivePortal

    @Test func unclosedMetaTagsAreReadQuickly() {
        let clock = ContinuousClock()
        var result: URL? = URL(string: "http://x")
        let first = clock.measure { result = CaptivePortal.signInPage(location: nil, body: String(repeating: "<meta content=url=a ", count: 409), base: CaptivePortal.Endpoint.apple.url) }
        #expect(first < .seconds(1) && result == nil)
        result = URL(string: "http://x")
        let second = clock.measure { result = CaptivePortal.signInPage(location: nil, body: String(repeating: "<meta http-equiv=refresh x ", count: 303), base: CaptivePortal.Endpoint.apple.url) }
        #expect(second < .seconds(1) && result == nil)
        var hint: Int? = 1
        let third = clock.measure { hint = CaptivePortal.hint(in: String(repeating: "<a ", count: 21_845)) }
        #expect(third < .seconds(1) && hint == nil)
    }

    @Test func metaRefreshStillResolvesInEitherAttributeOrder() {
        let base = CaptivePortal.Endpoint.apple.url
        #expect(CaptivePortal.signInPage(location: nil, body: #"<html><meta http-equiv="refresh" content="0; url=http://192.168.3.1:8080/login.html?res=notyet"></html>"#, base: base)?.absoluteString
                == "http://192.168.3.1:8080/login.html?res=notyet")
        #expect(CaptivePortal.signInPage(location: nil, body: #"<meta content="0;url=/login" http-equiv="refresh">"#, base: base)?.absoluteString == "http://captive.apple.com/login")
    }

    // MARK: ConnectionDoctor

    @Test func aLookupThatOutlastsItsLimitGivesTheFallback() async {
        let started = ContinuousClock.now
        let slow: [String] = await ConnectionDoctor.first(of: { () async -> [String] in try? await Task.sleep(for: .seconds(60)); return ["late"] }, or: [], after: 0.1)
        #expect(slow.isEmpty && ContinuousClock.now - started < .seconds(20))
        let quick: [String] = await ConnectionDoctor.first(of: { () async -> [String] in ["now"] }, or: [], after: 5)
        #expect(quick == ["now"])
    }

    @Test func anUpperCaseSchemeIsLowercased() {
        #expect(ConnectionDoctor.requestURL("Https://Example.com/A?b=C")?.absoluteString == "https://Example.com/A?b=C")
        #expect(ConnectionDoctor.requestURL("HTTP://example.com")?.scheme == "http")
        #expect(ConnectionDoctor.requestURL("example.com/a?b=c")?.absoluteString == "https://example.com/a?b=c")
    }

    // MARK: ExpertTools.validHost

    @Test func validHostAcceptsLettersDigitsDotsHyphensAndColons() {
        for host in ["example.com", "2a00:1450::1", "A-b.9"] { #expect(ExpertTools.validHost(host), "\(host)") }
        for host in ["", "-x", "a b", "exämple.com", "a/b", "a;b", "a@b", String(repeating: "a", count: 254)] { #expect(!ExpertTools.validHost(host), "\(host)") }
    }

    // MARK: AwakeOptions

    @Test func aHugeQuietValueIsRefusedNotACrash() throws {
        for value in ["inf", "1e30", "99999999999999999999m"] {
            #expect(throws: AwakeOptions.Invalid.self) { try AwakeOptions.parse(["awake", "--until-quiet", "--quiet", value]) }
        }
        #expect(try AwakeOptions.parse(["awake", "--until-quiet", "--quiet", "3m"]).quietMinutes == 3)
        #expect(try AwakeOptions.parse(["awake", "--until-quiet", "--quiet", "90s"]).quietMinutes == 2)
    }

    // MARK: DiagnosticHandoff

    @Test func discoveryTakesOnlyPrivateAddressesAndSubnets() {
        for target in ["10.0.0.5", "192.168.1.0/24", "172.16.4.1/32"] { #expect(DiagnosticHandoff.discoveryTarget(target), "\(target)") }
        for target in ["192.168.1.1.example.com", "-iL=x.10.0.0.1", "+10.0.0.1", "10.0.0.x.1", "10.0.0.1/+24", "8.8.8.8", "10.0.0.0/16", "10.0.0"] {
            #expect(!DiagnosticHandoff.discoveryTarget(target), "\(target)")
        }
    }

    // MARK: DomainPolicy

    @Test func theCompiledListAgreesWithTheUncompiledOne() {
        let domains = ["example.com", "*.ads.test", "10.0.0.0/8"], exceptions = ["com.excepted.app": ["example.com"]]
        let compiled = DomainPolicy.Compiled(domains: domains, exceptions: exceptions)
        let cases: [(String?, String?, String)] = [("sub.example.com", nil, "com.example.app"), ("notexample.com", nil, "com.example.app"), ("x.ads.test", nil, "com.example.app"),
                                                  (nil, "10.1.2.3", "com.example.app"), ("example.com", nil, "com.excepted.app"), ("EXAMPLE.com.", nil, "com.example.app")]
        for (host, address, app) in cases {
            #expect(compiled.first(host, address: address, app: app) == DomainPolicy.blocked(host, address: address, app: app, domains: domains, exceptions: exceptions))
        }
        #expect(compiled.excepts("sub.example.com", app: "com.excepted.app") && !compiled.excepts("other.net", app: "com.excepted.app"))
    }

    @Test func aListWithWindowsLineEndingsOrAByteOrderMarkImportsWhole() throws {
        #expect(try DomainPolicy.parseList(Data("# My list\r\nads.example.com\r\ntracker.example.net # note\r\n0.0.0.0 metrics.example.org\r\n".utf8))
                == ["ads.example.com", "metrics.example.org", "tracker.example.net"])
        #expect(try DomainPolicy.parseList(Data("\u{FEFF}ads.example.com\ntracker.example.net\n".utf8)) == ["ads.example.com", "tracker.example.net"])
    }

    // MARK: FilterEvents

    @Test func aHostAnswerListsTheConnectionsStillHeld() throws {
        let queue = ApprovalQueue<Int>()
        var resumed: [Int: Bool] = [:]
        queue.resume = { resumed[$0] = $1 }
        for index in 0...20 {
            queue.hold(index, approval: PendingApproval(app: "com.example.app", process: "app", path: nil, signer: nil, signatureValid: true, pid: 1, uid: 501,
                                                        destinations: [.init(host: "h\(index).example.com", address: nil, port: "443")], site: "example.com"))
        }
        let shown = try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501))[0]
        #expect(shown.destinations.count == 20)
        #expect(queue.answer(ApprovalAnswer(shown, allowed: true, scope: .host), uid: 501))
        #expect(resumed == Dictionary(uniqueKeysWithValues: (0...19).map { ($0, true) }))
        let rest = try JSONDecoder().decode([PendingApproval].self, from: queue.encoded(for: 501))
        #expect(rest.count == 1 && rest[0].waiting == 1 && rest[0].destinations.map(\.host) == ["h20.example.com"])
    }

    @Test func aFullConnectionLogMakesRoomWithoutLosingFreshRows() throws {
        func decode(_ data: Data) throws -> ConnectionLogSnapshot {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ConnectionLogSnapshot.self, from: data)
        }
        func record(_ log: ConnectionLogRecorder, _ host: String, at now: Date) {
            log.record(uid: 501, app: "com.example.app", process: "app", host: host, address: nil, port: "443", transport: "tcp", direction: "outgoing",
                       verdict: "allow", reason: { "x" }, now: now, uptime: 101)
        }
        let now = Date(), capacity = ConnectionLogRecorder.capacity
        // Stale rows go together.
        let log = ConnectionLogRecorder()
        _ = log.snapshot(uid: 501, record: true, browsers: false, now: now, uptime: 100)
        for index in 0..<(capacity - 1) { record(log, "old\(index).example", at: now - 4_000) }
        record(log, "fresh.example", at: now)
        record(log, "new.example", at: now)
        #expect(Set(try decode(log.snapshot(uid: 501, record: true, browsers: false, now: now, uptime: 102)).entries.map(\.destination)) == ["fresh.example", "new.example"])
        // With nothing stale, the oldest makes room.
        let full = ConnectionLogRecorder()
        _ = full.snapshot(uid: 501, record: true, browsers: false, now: now, uptime: 100)
        record(full, "oldest.example", at: now - 10)
        for index in 0..<(capacity - 1) { record(full, "h\(index).example", at: now) }
        record(full, "h0.example", at: now)
        record(full, "new.example", at: now)
        let entries = try decode(full.snapshot(uid: 501, record: true, browsers: false, now: now, uptime: 102)).entries
        #expect(entries.count == capacity && !entries.contains { $0.destination == "oldest.example" } && entries.contains { $0.destination == "new.example" })
        #expect(entries.first { $0.destination == "h0.example" }?.count == 2)
    }

    // MARK: Explainer

    @Test func signerNamesAppleCodeAndNothingForAMissingFile() {
        #expect(Explainer.signer(path: "/bin/ls") == "Apple")
        #expect(Explainer.signer(path: "/nonexistent") == nil)
    }

    // MARK: CommandLineTool

    @Test func anotherToolsKbIsLeftAlone() async throws {
        let fm = FileManager.default
        let helper = "/Applications/Kilobat.app/Contents/Helpers/kilobat"
        for theirs in ["file", "link"] {
            let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            let old = folder.appendingPathComponent("kilobat").path, kb = folder.appendingPathComponent("kb").path
            try Data("old".utf8).write(to: URL(fileURLWithPath: old))
            if theirs == "file" { try Data("mine".utf8).write(to: URL(fileURLWithPath: kb)) } else { try fm.createSymbolicLink(atPath: kb, withDestinationPath: "/somewhere/else/kb") }
            try await CommandLineTool.link(to: helper, replacing: CommandLineTool(path: old, source: .other, version: nil))
            #expect(try fm.destinationOfSymbolicLink(atPath: old) == helper)
            if theirs == "file" { #expect(fm.contents(atPath: kb) == Data("mine".utf8)) } else { #expect(try fm.destinationOfSymbolicLink(atPath: kb) == "/somewhere/else/kb") }
        }
    }
}
