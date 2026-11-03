import Foundation
import Testing
@testable import KilobatCore

/// "What is this connection?": the bundled database, its lookups, the facts for unknown subjects, the on-device guess
/// (with a fake model) and `kilobat explain`'s arguments.
struct ExplainerTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let json = try! Data(contentsOf: GeoIP.resources.first!.appendingPathComponent("explainer.json"))
    private let explainer = Explainer(json: ExplainerTests.json)

    @Test func theDatabaseLoadsAndHangsTogether() throws {
        #expect(explainer.available)
        #expect(explainer.processes.count >= 50)
        #expect(explainer.hosts.count >= 50)
        let processSlugs = Set(explainer.processes.map(\.slug)), hostSlugs = Set(explainer.hosts.map(\.slug))
        for process in explainer.processes {
            #expect(!process.summary.isEmpty && !process.breaks.isEmpty, "\(process.slug)")
            #expect(process.hosts.allSatisfy(hostSlugs.contains), "\(process.slug) lists a host that doesn't exist")
            #expect(process.url.absoluteString == "https://kilobat.app/processes/\(process.slug)")
            // Plain text only: the popover shows these as they are.
            #expect(!process.summary.contains("<") && !process.summary.contains("[["), "\(process.slug)")
        }
        for host in explainer.hosts {
            #expect(host.processes.allSatisfy(processSlugs.contains), "\(host.slug) lists a process that doesn't exist")
            #expect(host.match.allSatisfy { $0 == $0.lowercased() && !$0.contains("/") }, "\(host.slug)")
        }
    }

    /// The committed JSON is what script/build_explainer.py makes from the site's YAML today.

    @Test func hostsMatchExactNamesFirstThenTheLongestPattern() {
        // gateway.icloud.com has its own entry, though *.icloud.com covers it too.
        #expect(explainer.host("gateway.icloud.com")?.slug == "gateway-icloud-com")
        #expect(explainer.host("p42-contacts.icloud.com")?.slug == "icloud-com")
        #expect(explainer.host("1-courier.push.apple.com")?.slug == "push-apple-com")
        // A pattern covers names under the domain, not the domain itself.
        #expect(explainer.host("push.apple.com") == nil)
        // An exact name under a pattern's domain wins over the pattern; otherwise the pattern answers.
        #expect(explainer.host("appleid.cdn-apple.com")?.slug == "account-apple-com")
        #expect(explainer.host("updates.cdn-apple.com")?.slug == "updates-cdn-apple-com")
        #expect(explainer.host("something.cdn-apple.com")?.slug == "cdn-apple-com")
        // URLs, ports, case and a trailing dot don't matter.
        #expect(explainer.host("https://MESU.apple.com/assets/x.xml")?.slug == "mesu-apple-com")
        #expect(explainer.host("time.apple.com:123")?.slug == "time-apple-com")
        #expect(explainer.host("ocsp2.apple.com.")?.slug == "ocsp-apple-com")
        #expect(explainer.host("example.com") == nil)
        #expect(explainer.host("") == nil)
    }

    @Test func codexAndItsKnownHostsHaveDescriptions() {
        #expect(explainer.process(name: "codex")?.slug == "codex")
        #expect(explainer.host("chatgpt.com")?.slug == "chatgpt-com")
        #expect(explainer.host("api.openai.com")?.slug == "api-openai-com")
        #expect(explainer.host("developers.openai.com")?.slug == "developers-openai-com")
        #expect(explainer.host("mcp.cloudflare.com")?.slug == "mcp-cloudflare-com")
        #expect(explainer.host("mcp.vercel.com")?.slug == "mcp-vercel-com")
        #expect(explainer.host("fake-chatgpt.com") == nil)
    }

    @Test func processesMatchByPathThenIdentifierThenName() {
        #expect(explainer.process(path: "/usr/libexec/nsurlsessiond")?.slug == "nsurlsessiond")
        #expect(explainer.process(identifier: "com.apple.cloudd")?.slug == "cloudd")
        #expect(explainer.process(identifier: "process:node")?.slug == "node")
        #expect(explainer.process(name: "MDNSRESPONDER")?.slug == "mdnsresponder")
        // An alias belongs to its main entry: ocspd is on trustd's page, WiFiAgent on airportd's.
        #expect(explainer.process(name: "ocspd")?.slug == "trustd")
        #expect(explainer.process(name: "WiFiAgent")?.slug == "airportd")
        // The path wins over a misleading name.
        #expect(explainer.process(name: "bird", path: "/usr/libexec/trustd")?.slug == "trustd")
        #expect(explainer.process(name: "not-a-process") == nil)
    }

    @Test func cutOffNamesAndPatternsStillMatch() {
        // nettop and Kilobat cut names to 15 characters.
        #expect(explainer.process(name: "identityservice")?.slug == "identityservicesd")
        #expect(explainer.process(name: "com.apple.Mobil")?.slug == "mobileassetd")
        // Electron helpers are named after their app; Chrome's have their own page.
        #expect(explainer.process(name: "Slack Helper (Renderer)")?.slug == "electron-helpers")
        #expect(explainer.process(name: "Code Helper")?.slug == "electron-helpers")
        #expect(explainer.process(identifier: "com.microsoft.VSCode.helper")?.slug == "electron-helpers")
        #expect(explainer.process(name: "Google Chrome Helper (Renderer)")?.slug == "chrome-helper")
        // A path with a placeholder: Sparkle inside any app.
        #expect(explainer.process(path: "/Applications/TripMode.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate")?.slug == "sparkle-autoupdate")
    }

    @Test func aConnectionGetsItsProcessAndItsHost() {
        let explanation = explainer.explain(ExplainSubject(process: "apsd", host: "1-courier.push.apple.com", address: "203.0.113.10"))
        #expect(explanation.process?.slug == "apsd")
        #expect(explanation.host?.slug == "push-apple-com")
        #expect(!explanation.unknown)
        #expect(explanation.facts.address == "203.0.113.10")
    }

    @Test func anUnknownSubjectGetsTheFactsAndNothingMore() {
        let subject = ExplainSubject(process: "acme-sync", path: "/Users/me/bin/acme-sync", identifier: "process:acme-sync", signer: "Unsigned", host: "api.acme.example")
        let explanation = explainer.explain(subject)
        #expect(explanation.unknown)
        #expect(explanation.facts.process == "acme-sync")
        #expect(explanation.facts.signer == "Unsigned")
        #expect(explanation.facts.host == "api.acme.example")
        #expect(explanation.facts.kind == "A command-line tool someone installed")
        #expect(Explainer.facts(ExplainSubject(path: "/usr/libexec/somethingd")).kind == "Part of macOS, by its location")
        #expect(Explainer.facts(ExplainSubject(path: "/Applications/Acme.app/Contents/MacOS/Acme")).kind == "Inside an app")
        #expect(ExplainSubject(process: "  ").isEmpty)
    }

    @Test func theSignerComesFromTheCodeSignatureOnThisMac() {
        #expect(Explainer.signer(path: "/usr/libexec/nsurlsessiond") == "Apple")
        #expect(Explainer.signer(path: "/no/such/file") == nil)
    }

    // MARK: The on-device guess, with a fake model

    private struct FakeModel: ExplainerModel {
        var isAvailable = true
        var answer: String = "This is probably a sync helper for Acme. I can't tell more from the facts."
        var fails = false
        func respond(instructions: String, prompt: String) async throws -> String {
            if fails { throw CocoaError(.featureUnsupported) }
            // The prompt carries only the facts, and the instructions forbid inventing things.
            #expect(prompt.contains("Process name: acme-sync"))
            #expect(!prompt.contains("process:acme-sync"))
            #expect(instructions.contains("Use only the facts given"))
            return answer
        }
    }
    private let facts = Explainer.facts(ExplainSubject(process: "acme-sync", identifier: "process:acme-sync", signer: "Unsigned", host: "api.acme.example"))

    @Test func theGuessComesFromTheModelWhenItIsAvailable() async {
        #expect(await ExplainerGuess.guess(facts, model: FakeModel()) == "This is probably a sync helper for Acme. I can't tell more from the facts.")
    }

    @Test func withoutTheModelThereIsNoGuessOnlyFacts() async {
        #expect(await ExplainerGuess.guess(facts, model: FakeModel(isAvailable: false)) == nil)
        #expect(await ExplainerGuess.guess(facts, model: FakeModel(fails: true)) == nil)
        #expect(await ExplainerGuess.guess(ExplainerFacts(), model: FakeModel()) == nil)
    }

    @Test func theGuessIsCleanedToShortPlainText() {
        #expect(ExplainerGuess.clean("**Likely** a [helper](https://example.com) for `Acme`. See https://acme.example now.") == "Likely a helper for Acme. See now.")
        #expect(ExplainerGuess.clean("One. Two. Three. Four.") == "One. Two. Three.")
        #expect(ExplainerGuess.clean("- ok") == nil)
        let long = ExplainerGuess.clean(String(repeating: "word ", count: 200))!
        #expect(long.count <= ExplainerGuess.limit + 1 && long.hasSuffix("…"))
    }

    @Test func thePromptListsOnlyTheFacts() {
        let prompt = ExplainerGuess.prompt(ExplainerFacts(process: "x", host: "h.example", network: "Akamai", country: "Germany"))
        #expect(prompt.contains("Process name: x") && prompt.contains("Host it connects to: h.example"))
        #expect(prompt.contains("Network that owns the address: Akamai") && prompt.contains("Country the address is registered in: Germany"))
        #expect(!prompt.contains("Executable path"))
    }

    // MARK: kilobat explain

    @Test func explainArgumentsTellProcessesFromHosts() throws {
        let parsed = try ExplainQuery.parse(["explain", "nsurlsessiond", "gateway.icloud.com", "--json"], explainer: explainer)
        #expect(parsed.json)
        #expect(parsed.queries == [ExplainQuery(process: "nsurlsessiond"), ExplainQuery(host: "gateway.icloud.com")])
        let ids = try ExplainQuery.parse(["explain", "com.apple.cloudd", "/usr/libexec/trustd", "process:node", "com.apple.WebKit.Networking", "https://example.com/x"], explainer: explainer)
        #expect(ids.queries.map(\.process) == ["com.apple.cloudd", "/usr/libexec/trustd", "process:node", "com.apple.WebKit.Networking", nil])
        #expect(ids.queries.last?.host == "https://example.com/x")
        #expect(!ids.json)
    }

    @Test func explainPairsAProcessWithItsHost() throws {
        let parsed = try ExplainQuery.parse(["explain", "--process", "apsd", "--host", "1-courier.push.apple.com"], explainer: explainer)
        #expect(parsed.queries == [ExplainQuery(process: "apsd", host: "1-courier.push.apple.com")])
        #expect(parsed.queries[0].subject == ExplainSubject(process: "apsd", identifier: "apsd", host: "1-courier.push.apple.com"))
        #expect(ExplainQuery(process: "/usr/libexec/trustd").subject.path == "/usr/libexec/trustd")
    }

    @Test func explainRejectsWhatItCantRead() {
        #expect(throws: ExplainQuery.ArgumentError.self) { try ExplainQuery.parse(["explain"], explainer: explainer) }
        #expect(throws: ExplainQuery.ArgumentError.self) { try ExplainQuery.parse(["explain", "--verbose", "x"], explainer: explainer) }
        #expect(throws: ExplainQuery.ArgumentError.self) { try ExplainQuery.parse(["explain", "--host"], explainer: explainer) }
    }
}
