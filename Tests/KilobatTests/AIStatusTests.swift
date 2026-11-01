import Foundation
import Testing
@testable import KilobatCore

/// AI apps, agents and model providers: components, new formats, agent and host mapping.
struct AIStatusTests {
    private let now = ServiceStatusParser.date("2026-10-31T14:00:00Z")!
    private func service(_ id: String) -> StatusService { ServiceCatalog.services.first { $0.id == id }! }
    private func parse(_ pages: [String], _ id: String) throws -> ServiceStatus {
        try ServiceStatusParser.parse(pages.map { Data($0.utf8) }, for: service(id), now: now)
    }

    // MARK: Components

    @Test func aClaudeAIOutageDoesntBlameClaudeCode() throws {
        let web = try parse([AIStatusFixtures.claudeWebDown], "claude")
        #expect(web.state == .majorOutage)
        #expect(web.incident == "claude.ai unavailable for some users")
        #expect(web.page.absoluteString == "https://stspg.io/example1")
        #expect(try parse([AIStatusFixtures.claudeWebDown], "claude-code").state == .operational)
        #expect(try parse([AIStatusFixtures.claudeWebDown], "anthropic-api").state == .operational)
    }

    @Test func anAPIIncidentReachesClaudeCodeButNotClaudeAI() throws {
        let code = try parse([AIStatusFixtures.claudeAPIErrors], "claude-code")
        // Degraded by its component, raised by the incident being investigated that names it.
        #expect(code.state == .partialOutage)
        #expect(code.incident == "Elevated errors on Claude Opus")
        #expect(try parse([AIStatusFixtures.claudeAPIErrors], "anthropic-api").state == .partialOutage)
        #expect(try parse([AIStatusFixtures.claudeAPIErrors], "claude").state == .operational)
        #expect(try parse([AIStatusFixtures.claudeOperational], "claude-code").sentence(notYou: true) == "Anthropic’s status page reports no problems with Claude Code.")
    }

    @Test func openAIReadsItsFullComponentList() throws {
        // The summary alone lists only one of Codex's components (the desktop one); the full list has the CLI's.
        #expect(try parse([AIStatusFixtures.openaiSummary], "codex").state == .operational)
        let codex = try parse([AIStatusFixtures.openaiSummary, AIStatusFixtures.openaiComponentsCodexDown], "codex")
        #expect(codex.state == .partialOutage)
        #expect(codex.incident == nil)
        #expect(try parse([AIStatusFixtures.openaiSummary, AIStatusFixtures.openaiComponentsCodexDown], "chatgpt").state == .operational)
        #expect(try parse([AIStatusFixtures.openaiSummary, AIStatusFixtures.openaiComponentsCodexDown], "openai-api").state == .operational)
        // incident.io writes incidents without components, so a component that's down borrows the open incident's title.
        let titled = try parse([AIStatusFixtures.openaiSummaryIncident, AIStatusFixtures.openaiComponentsCodexDown], "codex")
        #expect(titled.incident == "Codex CLI requests failing")
        // A component list that doesn't arrive costs detail, never the answer.
        #expect(try parse([AIStatusFixtures.openaiSummary, "not json"], "codex").state == .operational)
    }

    @Test func copilotIsItsOwnComponent() throws {
        let copilot = try parse([AIStatusFixtures.githubCopilotDown], "copilot")
        #expect(copilot.state == .majorOutage)
        #expect(copilot.sentence(notYou: true) == "GitHub Copilot is down for everyone, not you — Copilot completions failing")
        #expect(try parse([AIStatusFixtures.githubCopilotDown], "github").state == .operational)
    }

    @Test func cursorThroughItsRedirect() throws {
        #expect(try parse([AIStatusFixtures.cursorOperational], "cursor").state == .operational)
        #expect(try parse([AIStatusFixtures.cursorOperational], "cursor-cli").state == .operational)
    }

    @Test func anIncidentWithNoImpactLeavesAGreenPageGreen() throws {
        #expect(try parse([AIStatusFixtures.fireworksNoImpact], "fireworks").state == .operational)
    }

    // MARK: Formats

    @Test func betterStack() throws {
        #expect(try parse([AIStatusFixtures.betterStackOperational], "huggingface").state == .operational)
        let down = try parse([AIStatusFixtures.betterStackDowntime], "huggingface")
        #expect(down.state == .partialOutage)
        #expect(down.incident == "Inference API returning 503s")
        #expect(throws: (any Error).self) { try parse([#"{"data":{"attributes":{"aggregate_state":"weird"}}}"#], "huggingface") }
    }

    @Test func instatus() throws {
        #expect(try parse([AIStatusFixtures.instatusUp], "zed").state == .operational)
        let issues = try parse([AIStatusFixtures.instatusIssues], "zed")
        #expect(issues.state == .degraded)
        #expect(issues.incident == "Collaboration server unreachable")
        #expect(issues.page.absoluteString == "https://status.zed.dev/incident/x6")
    }

    @Test func googleCloudByProduct() throws {
        let vertex = try parse([AIStatusFixtures.googleCloudIncidents], "vertex-ai")
        #expect(vertex.state > .operational)
        #expect(vertex.page.absoluteString.hasPrefix("https://status.cloud.google.com/incidents/"))
        #expect(vertex.owner == "Google Cloud")
        #expect(try parse([AIStatusFixtures.googleCloudIncidents], "gemini-code-assist").state == .operational)
    }

    // MARK: Agents and hosts

    @Test func agentsMapToTheComponentTheyUse() {
        func ids(_ app: AppTraffic) -> [String] { ServiceCatalog.services(for: app).map(\.id) }
        #expect(ids(AppTraffic(id: "process:claude", name: "claude")) == ["claude-code"])
        // Claude Code under node is still Claude Code, by the agent catalog.
        #expect(ids(AppTraffic(id: "process:node", name: "Claude Code")) == ["claude-code"])
        #expect(ids(AppTraffic(id: "process:codex", name: "codex")) == ["codex"])
        #expect(ids(AppTraffic(id: "process:gemini", name: "gemini")) == ["gemini-code-assist"])
        #expect(ids(AppTraffic(id: "process:cursor-agent", name: "cursor-agent")) == ["cursor-cli"])
        #expect(ids(AppTraffic(id: "com.openai.codex", name: "ChatGPT")) == ["chatgpt", "codex"])
        #expect(ids(AppTraffic(id: "process:aider", name: "aider")).isEmpty)
        #expect(ServiceCatalog.displayName(AppTraffic(id: "process:claude", name: "claude")) == "Claude Code")
    }

    @Test func theMostSpecificHostWins() {
        #expect(ServiceCatalog.services(forHost: "api.anthropic.com").map(\.id) == ["anthropic-api"])
        #expect(ServiceCatalog.services(forHost: "claude.ai").map(\.id) == ["claude"])
        #expect(ServiceCatalog.services(forHost: "www.anthropic.com").map(\.id) == ["claude"])
        #expect(ServiceCatalog.services(forHost: "api.openai.com").map(\.id) == ["openai-api"])
        #expect(ServiceCatalog.services(forHost: "chatgpt.com").map(\.id) == ["chatgpt"])
        #expect(ServiceCatalog.services(forHost: "api.githubcopilot.com").map(\.id) == ["copilot"])
        #expect(ServiceCatalog.services(forHost: "copilot-proxy.githubusercontent.com").map(\.id) == ["copilot"])
        #expect(ServiceCatalog.services(forHost: "raw.githubusercontent.com").map(\.id) == ["github"])
        #expect(ServiceCatalog.services(forHost: "api.mistral.ai").map(\.id) == ["mistral"])
        #expect(ServiceCatalog.services(forHost: "api.groq.com").map(\.id) == ["groq"])
        #expect(ServiceCatalog.services(forHost: "cloudcode-pa.googleapis.com").map(\.id) == ["gemini-code-assist"])
        #expect(ServiceCatalog.services(forHost: "generativelanguage.googleapis.com").isEmpty)
    }

    @Test func theWatchFollowsAgentsAndAnyAppTalkingToAProvider() {
        let apps = [AppTraffic(id: "process:claude", name: "claude"), AppTraffic(id: "dev.zed.Zed", name: "Zed"), AppTraffic(id: "process:aider", name: "aider"),
                    AppTraffic(id: "com.apple.Safari", name: "Safari")]
        let opening = ["process:claude": ["160.79.104.10"], "dev.zed.Zed": ["160.79.104.10", "160.79.104.10"], "process:aider": ["104.18.33.45"], "com.apple.Safari": []]
        let endpoints = ["160.79.104.10": ["anthropic-api"], "104.18.33.45": ["openai-api"]]
        let watched = ServiceTriggers.watched(apps: apps, opening: opening, endpoints: endpoints)
        #expect(watched["process:claude"]?.services.map(\.id) == ["claude-code"])
        #expect(watched["process:claude"]?.app == "Claude Code")
        #expect(watched["process:claude|anthropic-api"]?.count == 1)
        #expect(watched["dev.zed.Zed"]?.count == 2)
        #expect(watched["dev.zed.Zed|anthropic-api"]?.count == 2)
        #expect(watched["process:aider|openai-api"]?.app == "Aider")
        #expect(watched["process:aider"] == nil)
        #expect(watched["com.apple.Safari"] == nil)
    }

    @Test func alertsNameTheAgent() {
        func status(_ id: String, _ state: ServiceStatus.State) -> ServiceStatus {
            let service = service(id)
            return ServiceStatus(id: id, service: service.name, state: state, incident: "x", page: service.page, checked: now, owner: service.owner)
        }
        #expect(status("claude-code", .majorOutage).alertTitle(app: "Claude Code") == "Claude Code: Anthropic reports an outage — not your connection")
        #expect(status("anthropic-api", .partialOutage).alertTitle(app: "Zed") == "Zed: Anthropic reports a partial outage on Claude API — not your connection")
        #expect(status("codex", .degraded).alertTitle(app: "Codex") == "Codex: OpenAI reports problems — not your connection")
        #expect(status("slack", .majorOutage).alertTitle(app: "Slack") == "Slack is having an outage")
        #expect(status("slack", .degraded).alertTitle() == "Slack is having problems")
    }

    @Test func everyProviderIsInTheCatalog() {
        let ids = Set(ServiceCatalog.services.map(\.id))
        for id in ["claude", "claude-code", "anthropic-api", "chatgpt", "codex", "openai-api", "vertex-ai", "gemini-code-assist", "mistral", "groq", "cohere",
                   "fireworks", "huggingface", "together", "perplexity", "cursor", "cursor-cli", "windsurf", "replit", "lovable", "bolt", "v0", "zed", "warp", "copilot"] {
            #expect(ids.contains(id), "\(id) missing")
        }
        // Every component filter names something: no empty strings, no duplicates within a service.
        for service in ServiceCatalog.services { #expect(Set(service.components).count == service.components.count && !service.components.contains("")) }
    }
}
