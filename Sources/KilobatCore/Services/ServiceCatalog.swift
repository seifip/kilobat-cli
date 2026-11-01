import Foundation

/// A service with a public status page, and how an app or a site maps to it.
public struct StatusService: Sendable, Identifiable, Equatable {
    public enum Feed: Sendable, Equatable {
        /// Atlassian Statuspage's /api/v2/summary.json, which incident.io pages also serve. `components` is the page's
        /// /api/v2/components.json, for pages whose summary lists only some components (incident.io's lists 25).
        case statuspage(URL, incidentsOnly: Bool = false, components: URL? = nil)
        case slack
        /// Google Workspace's incidents, for these products.
        case google([String])
        /// Google Cloud's incidents, the same format, for these products.
        case googleCloud([String])
        /// Apple System Status, for these service names ("iCloud*" for every name that starts so).
        case apple([String])
        /// Microsoft's consumer services, for these workload names.
        case microsoft([String])
        /// Status.io's public status API.
        case statusIO(URL)
        /// Better Stack status pages' /index.json.
        case betterStack(URL)
        /// Instatus pages' /summary.json.
        case instatus(URL)

        /// The first answers for the state; any others add detail (a page's full component list).
        public var urls: [URL] {
            switch self {
            case .statuspage(let url, _, let components): [url] + (components.map { [$0] } ?? [])
            case .statusIO(let url), .betterStack(let url), .instatus(let url): [url]
            case .slack: [URL(string: "https://slack-status.com/api/v2.0.0/current")!]
            case .google: [URL(string: "https://www.google.com/appsstatus/dashboard/incidents.json")!]
            case .googleCloud: [URL(string: "https://status.cloud.google.com/incidents.json")!]
            case .apple: [URL(string: "https://www.apple.com/support/systemstatus/data/system_status_en_US.js")!]
            case .microsoft: [URL(string: "https://status.cloud.microsoft/api/posts/m365Consumer")!]
            }
        }
        public var url: URL { urls[0] }
        public var format: String {
            switch self {
            case .statuspage: "statuspage"
            case .slack: "slack"
            case .google: "google-workspace"
            case .googleCloud: "google-cloud"
            case .apple: "apple"
            case .microsoft: "microsoft-consumer"
            case .statusIO: "status.io"
            case .betterStack: "better-stack"
            case .instatus: "instatus"
            }
        }
    }
    public let id: String
    public let name: String
    public let feed: Feed
    /// The page a person reads.
    public let page: URL
    /// Bundle-ID prefixes and process:<name> IDs whose traffic is this service's.
    public let apps: [String]
    /// Domains, matched with their subdomains; the longest match wins, so api.anthropic.com is the API, not claude.ai.
    public let hosts: [String]
    /// Whose status page it is, when that isn't the service itself.
    public var owner: String? = nil
    /// The page's components this service is, by name or name prefix ("Claude Code", "Claude API"). Empty: the whole page.
    /// When none of them is on the page, the whole page counts.
    public var components: [String] = []
    /// Services that share a page answer to its name too: `kilobat down claude` is claude.ai, Claude Code and the API.
    public var group: String? = nil
    /// API hostnames whose addresses Kilobat looks up, so any app's failing connections to them are noticed.
    public var endpoints: [String] = []

    public func covers(app id: String) -> Bool {
        apps.contains { $0.hasPrefix("process:") ? id.lowercased() == $0.lowercased() : id.hasPrefix($0) }
    }
    public func covers(host: String) -> Bool { match(host) != nil }
    /// How specific the domain is that this host matched, or nil.
    func match(_ host: String) -> Int? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (hosts + endpoints).filter { host == $0 || host.hasSuffix("." + $0) }.map(\.count).max()
    }
}

/// The status pages Kilobat knows. Each endpoint was fetched and parsed on 31 October 2026 (`checked`); a page that
/// moves or changes format reads as "couldn't read", never as an outage.
///
/// Left out, and why (31 Oct 2026): Webex's page needs a token; Microsoft Teams for work or school, Outlook for work and
/// AWS's per-account health are only shown to signed-in admins, and AWS's public feed is per region, so it can't say
/// whether an app is affected; Fastly's API refuses non-browser requests; Zendesk's API shape couldn't be checked
/// without a live incident; Twilio's page always lists carrier incidents in some country; Steam, Spotify, WhatsApp,
/// Telegram and Signal have no public feed; PlayStation and Xbox do, but there was no incident to check the format against.
/// AI providers left out: status.x.ai refuses non-browser requests (its compatible feed serves Cursor's page, not Grok's);
/// DeepSeek's page has no JSON feed; OpenRouter's feed answers 403; Replicate's status now lives inside Cloudflare's page;
/// JetBrains' page is HTML only; Kiro's and Amazon Q's status sit behind an AWS sign-in; Google AI Studio's Gemini API
/// page draws in the browser only. Ollama and LM Studio run locally. Aider, OpenCode and Goose use whichever provider
/// they're set up with, so they're matched by the hosts they connect to, not by name.
public enum ServiceCatalog {
    public static let checked = "2026-10-31"

    private static func statuspage(_ id: String, _ name: String, _ host: String, page: String? = nil, apps: [String] = [], hosts: [String], incidentsOnly: Bool = false,
                                   allComponents: Bool = false, owner: String? = nil, components: [String] = [], group: String? = nil, endpoints: [String] = []) -> StatusService {
        StatusService(id: id, name: name, feed: .statuspage(URL(string: "https://\(host)/api/v2/summary.json")!, incidentsOnly: incidentsOnly,
                                                             components: allComponents ? URL(string: "https://\(host)/api/v2/components.json")! : nil),
                      page: URL(string: page ?? "https://\(host)")!, apps: apps, hosts: hosts, owner: owner, components: components, group: group, endpoints: endpoints)
    }
    private static let googleCloudPage = URL(string: "https://status.cloud.google.com/")!

    /// Agents Kilobat recognises by process or name (AgentCatalog) and the services they use, when that's fixed. Aider,
    /// OpenCode, Goose and the like talk to whichever provider they're set up with, so only their connections tell.
    static let agentServices: [String: [String]] = [
        "Claude Code": ["claude-code"], "Codex": ["codex"], "Cursor Agent": ["cursor-cli"], "Gemini CLI": ["gemini-code-assist"], "Copilot CLI": ["copilot"],
    ]
    private static let googlePage = URL(string: "https://www.google.com/appsstatus/dashboard/")!
    private static let applePage = URL(string: "https://www.apple.com/support/systemstatus/")!
    private static let microsoftPage = URL(string: "https://status.cloud.microsoft/")!

    // Bundle IDs were read from installed copies, or are ones Kilobat already knew (call detection, call mode); the rest,
    // from each vendor's app as distributed: Perplexity, Trello, Canva, Miro, GoTo, Postman, Docker, GitHub Desktop, Grammarly, Proton.
    public static let services: [StatusService] = [
        // Calls and chat
        statuspage("zoom", "Zoom", "status.zoom.us", page: "https://www.zoomstatus.com", apps: ["us.zoom."], hosts: ["zoom.us", "zoom.com", "zoomgov.com"]),
        StatusService(id: "slack", name: "Slack", feed: .slack, page: URL(string: "https://slack-status.com")!, apps: ["com.tinyspeck.slackmacgap"],
                      hosts: ["slack.com", "slack-edge.com", "slack-msgs.com", "slack-files.com", "slack-imgs.com"]),
        // Teams for work or school reports to admins only; the public page covers the free, personal Teams.
        StatusService(id: "teams", name: "Microsoft Teams Free", feed: .microsoft(["TeamsforLife"]), page: microsoftPage, apps: ["com.microsoft.teams"], hosts: ["teams.live.com"], owner: "Microsoft"),
        StatusService(id: "meet", name: "Google Meet", feed: .google(["Google Meet"]), page: googlePage, apps: [], hosts: ["meet.google.com"], owner: "Google"),
        statuspage("discord", "Discord", "discordstatus.com", apps: ["com.hnc.Discord"], hosts: ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media"]),
        statuspage("goto", "GoTo Meeting", "status.goto.com", apps: ["com.logmein.GoToMeeting"], hosts: ["goto.com", "gotomeeting.com"]),
        StatusService(id: "facetime", name: "FaceTime", feed: .apple(["FaceTime"]), page: applePage, apps: ["com.apple.FaceTime", "process:avconferenced"], hosts: [], owner: "Apple"),
        StatusService(id: "imessage", name: "iMessage", feed: .apple(["iMessage"]), page: applePage, apps: ["com.apple.MobileSMS"], hosts: [], owner: "Apple"),
        // Mail, files and documents
        StatusService(id: "gmail", name: "Gmail", feed: .google(["Gmail"]), page: googlePage, apps: [], hosts: ["mail.google.com", "gmail.com"], owner: "Google"),
        StatusService(id: "google-drive", name: "Google Drive", feed: .google(["Google Drive"]), page: googlePage, apps: ["com.google.drivefs"], hosts: ["drive.google.com"], owner: "Google"),
        StatusService(id: "google-docs", name: "Google Docs", feed: .google(["Google Docs", "Google Sheets", "Google Slides", "Google Forms"]), page: googlePage, apps: [], hosts: ["docs.google.com"], owner: "Google"),
        StatusService(id: "google-calendar", name: "Google Calendar", feed: .google(["Google Calendar"]), page: googlePage, apps: [], hosts: ["calendar.google.com"], owner: "Google"),
        StatusService(id: "google-chat", name: "Google Chat", feed: .google(["Google Chat"]), page: googlePage, apps: [], hosts: ["chat.google.com"], owner: "Google"),
        StatusService(id: "outlook", name: "Outlook.com", feed: .microsoft(["Outlook.com"]), page: microsoftPage, apps: [], hosts: ["outlook.live.com", "outlook.com", "hotmail.com"], owner: "Microsoft"),
        StatusService(id: "onedrive", name: "OneDrive", feed: .microsoft(["OneDriveConsumer"]), page: microsoftPage, apps: ["com.microsoft.OneDrive"], hosts: ["onedrive.live.com", "onedrive.com", "1drv.ms"], owner: "Microsoft"),
        StatusService(id: "icloud", name: "iCloud", feed: .apple(["iCloud*", "Photos", "Mail Drop"]), page: applePage, apps: ["process:bird", "process:cloudd"],
                      hosts: ["icloud.com", "icloud-content.com", "me.com"], owner: "Apple"),
        statuspage("dropbox", "Dropbox", "status.dropbox.com", apps: ["com.getdropbox.dropbox"], hosts: ["dropbox.com", "dropboxapi.com", "dropboxusercontent.com"]),
        statuspage("box", "Box", "status.box.com", apps: ["com.box.desktop"], hosts: ["box.com"]),
        statuspage("notion", "Notion", "www.notion-status.com", apps: ["notion.id", "com.cron.electron"], hosts: ["notion.so", "notion.com", "notion.site"]),
        statuspage("airtable", "Airtable", "status.airtable.com", apps: ["com.FormaGrid.Airtable"], hosts: ["airtable.com"]),
        statuspage("proton", "Proton", "status.proton.me", apps: ["ch.protonmail.", "ch.protonvpn.", "me.proton."], hosts: ["proton.me", "protonmail.com"]),
        statuspage("1password", "1Password", "status.1password.com", apps: ["com.1password."], hosts: ["1password.com", "1password.eu", "1password.ca"]),
        // Design and planning
        statuspage("figma", "Figma", "status.figma.com", apps: ["com.figma.Desktop"], hosts: ["figma.com"]),
        statuspage("canva", "Canva", "www.canvastatus.com", apps: ["com.canva.CanvaDesktop"], hosts: ["canva.com"]),
        statuspage("miro", "Miro", "status.miro.com", apps: ["com.electron.realtimeboard"], hosts: ["miro.com"]),
        statuspage("linear", "Linear", "linearstatus.com", apps: ["com.linear"], hosts: ["linear.app"]),
        statuspage("asana", "Asana", "status.asana.com", hosts: ["asana.com"]),
        // Jira and Confluence share atlassian.net, so a site there names both.
        statuspage("jira", "Jira", "jira-software.status.atlassian.com", hosts: ["atlassian.net"]),
        statuspage("confluence", "Confluence", "confluence.status.atlassian.com", hosts: ["atlassian.net"]),
        statuspage("trello", "Trello", "trello.status.atlassian.com", apps: ["com.fogcreek.trello"], hosts: ["trello.com"]),
        statuspage("grammarly", "Grammarly", "status.grammarly.com", apps: ["com.grammarly."], hosts: ["grammarly.com"]),
        // AI apps, agents and model providers. Pages split by component map each to the one it uses, so a claude.ai outage
        // doesn't blame Claude Code, and the other way round.
        statuspage("claude", "Claude", "status.claude.com", apps: ["com.anthropic.claudefordesktop"], hosts: ["claude.ai", "claude.com", "anthropic.com"],
                   owner: "Anthropic", components: ["claude.ai"], group: "claude", endpoints: ["claude.ai"]),
        statuspage("claude-code", "Claude Code", "status.claude.com", apps: ["process:claude"], hosts: [], owner: "Anthropic", components: ["Claude Code"], group: "claude"),
        statuspage("anthropic-api", "Claude API", "status.claude.com", hosts: ["api.anthropic.com", "platform.claude.com", "console.anthropic.com"],
                   owner: "Anthropic", components: ["Claude API", "Claude Console"], group: "claude", endpoints: ["api.anthropic.com"]),
        // OpenAI's summary lists 25 of its 37 components, so its full list is read too. "Login" is in two groups and left out.
        statuspage("chatgpt", "ChatGPT", "status.openai.com", apps: ["com.openai.chat", "com.openai.codex"], hosts: ["chatgpt.com", "openai.com", "oaiusercontent.com", "oaistatic.com"],
                   allComponents: true, owner: "OpenAI",
                   components: ["Conversations", "ChatGPT Work", "Search", "File uploads", "Voice mode", "GPTs", "Image Generation", "Deep Research", "Agent", "Connectors/Apps", "ChatGPT Atlas"],
                   group: "openai", endpoints: ["chatgpt.com"]),
        statuspage("codex", "Codex", "status.openai.com", apps: ["process:codex", "com.openai.codex"], hosts: [], allComponents: true, owner: "OpenAI",
                   components: ["Codex Web", "Codex API", "CLI", "VS Code extension", "Codex in ChatGPT Desktop"], group: "openai"),
        statuspage("openai-api", "OpenAI API", "status.openai.com", hosts: ["api.openai.com", "platform.openai.com"], allComponents: true, owner: "OpenAI",
                   components: ["Chat Completions", "Responses", "Agents", "Embeddings", "Realtime", "Batch", "Files", "Audio", "Images", "Moderations", "Fine-tuning"],
                   group: "openai", endpoints: ["api.openai.com"]),
        // Google AI Studio's Gemini API status page draws in the browser only; Google Cloud's feed covers Vertex AI and Gemini
        // Code Assist, which the Gemini CLI uses when you sign in with Google.
        StatusService(id: "vertex-ai", name: "Vertex AI", feed: .googleCloud(["Vertex Gemini API", "Vertex AI Online Prediction", "Vertex AI Batch Prediction", "Vertex AI Agent Engine", "Agent Platform Model Garden"]),
                      page: googleCloudPage, apps: [], hosts: ["aiplatform.googleapis.com"], owner: "Google Cloud", group: "gemini"),
        StatusService(id: "gemini-code-assist", name: "Gemini Code Assist", feed: .googleCloud(["Gemini Code Assist"]), page: googleCloudPage, apps: ["process:gemini"],
                      hosts: ["cloudcode-pa.googleapis.com"], owner: "Google Cloud", group: "gemini", endpoints: ["cloudcode-pa.googleapis.com"]),
        statuspage("mistral", "Mistral", "status.mistral.ai", apps: ["process:vibe"], hosts: ["mistral.ai"], endpoints: ["api.mistral.ai"]),
        statuspage("groq", "Groq", "groqstatus.com", hosts: ["groq.com"], endpoints: ["api.groq.com"]),
        statuspage("cohere", "Cohere", "status.cohere.com", hosts: ["cohere.com", "cohere.ai"], endpoints: ["api.cohere.com", "api.cohere.ai"]),
        statuspage("fireworks", "Fireworks AI", "status.fireworks.ai", hosts: ["fireworks.ai"], endpoints: ["api.fireworks.ai"]),
        StatusService(id: "huggingface", name: "Hugging Face", feed: .betterStack(URL(string: "https://status.huggingface.co/index.json")!), page: URL(string: "https://status.huggingface.co")!,
                      apps: [], hosts: ["huggingface.co", "hf.co"], endpoints: ["huggingface.co"]),
        StatusService(id: "together", name: "Together AI", feed: .betterStack(URL(string: "https://status.together.ai/index.json")!), page: URL(string: "https://status.together.ai")!,
                      apps: [], hosts: ["together.ai", "together.xyz"], endpoints: ["api.together.xyz"]),
        statuspage("perplexity", "Perplexity", "status.perplexity.com", apps: ["ai.perplexity."], hosts: ["perplexity.ai"], endpoints: ["api.perplexity.ai"]),
        // status.cursor.com forwards to the page's feed on status.x.ai.
        statuspage("cursor", "Cursor", "status.cursor.com", apps: ["com.todesktop.230313mzl4w4u92"], hosts: ["cursor.com", "cursor.sh", "cursorapi.com"],
                   components: ["IDE", "Cloud Agents", "cursor.com"], group: "cursor", endpoints: ["api2.cursor.sh"]),
        statuspage("cursor-cli", "Cursor CLI", "status.cursor.com", apps: ["process:cursor-agent"], hosts: [], owner: "Cursor", components: ["CLI"], group: "cursor"),
        statuspage("windsurf", "Windsurf", "status.windsurf.com", apps: ["com.exafunction.windsurf"], hosts: ["windsurf.com", "codeium.com"],
                   components: ["Cascade", "Windsurf Tab"], endpoints: ["server.codeium.com"]),
        statuspage("replit", "Replit", "status.replit.com", hosts: ["replit.com", "replit.app", "repl.co"]),
        statuspage("lovable", "Lovable", "status.lovable.dev", hosts: ["lovable.dev", "lovable.app"]),
        statuspage("bolt", "Bolt", "status.bolt.new", hosts: ["bolt.new", "stackblitz.com"]),
        statuspage("v0", "v0", "v0-status.com", hosts: ["v0.dev", "v0.app"]),
        StatusService(id: "zed", name: "Zed", feed: .instatus(URL(string: "https://status.zed.dev/summary.json")!), page: URL(string: "https://status.zed.dev")!,
                      apps: ["dev.zed.Zed"], hosts: ["zed.dev"]),
        statuspage("warp", "Warp", "status.warp.dev", apps: ["dev.warp.Warp-"], hosts: ["warp.dev"]),
        // Developers
        statuspage("github", "GitHub", "www.githubstatus.com", apps: ["com.github.GitHubClient"], hosts: ["github.com", "githubusercontent.com", "githubassets.com", "ghcr.io", "github.dev"],
                   components: ["Git Operations", "API Requests", "Webhooks", "Issues", "Pull Requests", "Actions", "Packages", "Pages", "Codespaces"], group: "github"),
        // Copilot talks to its own hosts from VS Code, JetBrains IDEs, Xcode and the CLI, so it's found by connection.
        statuspage("copilot", "GitHub Copilot", "www.githubstatus.com", apps: ["process:copilot"], hosts: ["githubcopilot.com", "copilot-proxy.githubusercontent.com"],
                   owner: "GitHub", components: ["Copilot"], group: "github", endpoints: ["api.githubcopilot.com", "api.individual.githubcopilot.com"]),
        StatusService(id: "gitlab", name: "GitLab", feed: .statusIO(URL(string: "https://status.gitlab.com/1.0/status/5b36dc6502d06804c08349f7")!), page: URL(string: "https://status.gitlab.com")!,
                      apps: [], hosts: ["gitlab.com"]),
        statuspage("bitbucket", "Bitbucket", "bitbucket.status.atlassian.com", hosts: ["bitbucket.org"]),
        statuspage("npm", "npm", "status.npmjs.org", apps: ["process:npm"], hosts: ["npmjs.org", "npmjs.com"]),
        statuspage("docker", "Docker", "www.dockerstatus.com", apps: ["com.docker.docker"], hosts: ["docker.com", "docker.io"]),
        statuspage("postman", "Postman", "status.postman.com", apps: ["com.postmanlabs.mac"], hosts: ["postman.com", "getpostman.com"]),
        statuspage("vercel", "Vercel", "www.vercel-status.com", hosts: ["vercel.com", "vercel.app"]),
        statuspage("netlify", "Netlify", "www.netlifystatus.com", hosts: ["netlify.com", "netlify.app"]),
        statuspage("supabase", "Supabase", "status.supabase.com", hosts: ["supabase.co", "supabase.com"]),
        // Cloudflare's indicator is never green: some of its hundreds of data centers are always rerouted. Only incidents count.
        statuspage("cloudflare", "Cloudflare", "www.cloudflarestatus.com", apps: ["com.cloudflare.1dot1dot1dot1"],
                   hosts: ["cloudflare.com", "cloudflare-dns.com", "one.one.one.one", "workers.dev", "pages.dev"], incidentsOnly: true),
        statuspage("tailscale", "Tailscale", "status.tailscale.com", apps: ["io.tailscale.ipn."], hosts: ["tailscale.com"]),
        // Apple's stores and media
        StatusService(id: "app-store", name: "App Store", feed: .apple(["Mac App Store", "App Store"]), page: applePage, apps: ["com.apple.AppStore"], hosts: [], owner: "Apple"),
        StatusService(id: "apple-music", name: "Apple Music", feed: .apple(["Apple Music", "Apple Music Subscriptions", "Apple Music radio"]), page: applePage,
                      apps: ["com.apple.Music"], hosts: ["music.apple.com"], owner: "Apple"),
        StatusService(id: "apple-tv", name: "Apple TV", feed: .apple(["Apple TV", "Apple TV Channels"]), page: applePage, apps: ["com.apple.TV"], hosts: ["tv.apple.com"], owner: "Apple"),
        // Games and the rest
        statuspage("epic", "Epic Games", "status.epicgames.com", apps: ["com.epicgames."], hosts: ["epicgames.com", "fortnite.com"]),
        statuspage("reddit", "Reddit", "www.redditstatus.com", hosts: ["reddit.com", "redd.it", "redditmedia.com"]),
    ]

    public static func services(forApp id: String) -> [StatusService] { services.filter { $0.covers(app: id) } }
    /// The services whose most specific domain matches: api.anthropic.com is the Claude API, claude.ai is Claude.
    public static func services(forHost host: String) -> [StatusService] {
        let matches = services.compactMap { service in service.match(host).map { (service, $0) } }
        guard let best = matches.map(\.1).max() else { return [] }
        return matches.filter { $0.1 == best }.map(\.0)
    }
    /// An app as Kilobat counts it: by its ID, and for a coding agent by the agent it is (Claude Code under node, say).
    public static func services(for app: AppTraffic) -> [StatusService] {
        var found = services(forApp: app.id)
        if let agent = AgentCatalog.agent(for: app) {
            for id in agentServices[agent] ?? [] { if let service = services.first(where: { $0.id == id }), !found.contains(service) { found.append(service) } }
        }
        return found
    }
    /// The display name an alert uses for an app: the agent's name for a coding agent, otherwise the app's.
    public static func displayName(_ app: AppTraffic) -> String { AgentCatalog.agent(for: app) ?? app.name }

    /// A calling app as call reports name it ("Zoom", "Microsoft Teams") to its service, through the call detector's bundle IDs.
    public static func services(forCallApp name: String) -> [StatusService] {
        guard let entry = CallDetector.apps.first(where: { $0.name == name && !$0.browser }) else { return [] }
        var found: [StatusService] = []
        for prefix in entry.prefixes { for service in services(forApp: prefix) where !found.contains(service) { found.append(service) } }
        return found
    }

    public struct Unknown: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The services `kilobat down` and the MCP tool check: every one with `all`, those named, or those of the running apps.
    public static func pick(_ names: [String], all: Bool, running: [String]) throws -> [StatusService] {
        if all {
            guard names.isEmpty else { throw Unknown(message: "Use --all on its own, or name services.") }
            return services
        }
        var found: [StatusService] = []
        if names.isEmpty {
            for id in running { for service in services(forApp: id) where !found.contains(service) { found.append(service) } }
            return found
        }
        for name in names {
            let matches = find(name)
            guard !matches.isEmpty else { throw Unknown(message: "Kilobat doesn’t know a status page for “\(name)”. See kilobat down --list.") }
            for service in matches where !found.contains(service) { found.append(service) }
        }
        return found
    }

    /// What a person types: an id (slack), a name (google meet), a host or URL (github.com), or a bundle ID.
    public static func find(_ text: String) -> [StatusService] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        // "claude" is claude.ai, Claude Code and the API; "openai" ChatGPT, Codex and the API.
        let group = services.filter { $0.group == query }
        if !group.isEmpty { return group }
        if let exact = services.first(where: { $0.id == query || $0.name.lowercased() == query }) { return [exact] }
        let host = URL(string: query.contains("://") ? query : "https://" + query)?.host ?? query
        if host.contains(".") {
            let byHost = services(forHost: host)
            if !byHost.isEmpty { return byHost }
            let byApp = services(forApp: text.trimmingCharacters(in: .whitespacesAndNewlines))
            if !byApp.isEmpty { return byApp }
        }
        // "teams", "chatgpt", "openai", "icloud drive": a word of the name, or the page's owner.
        return services.filter { service in
            let words = (service.name + " " + (service.owner ?? "")).lowercased()
            return words.split(separator: " ").contains { $0 == query } || words.hasPrefix(query)
        }
    }
}
