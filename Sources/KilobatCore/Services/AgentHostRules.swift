import Foundation

/// The curated lists behind the flags and the names. Small on purpose: the services agents use every day, and the
/// handful of paste, file-share, tunnel and request-catcher services where data commonly leaves.
public enum AgentHostRules {
    public static let largeUpload: UInt64 = 10_000_000

    /// Hosts agents and package managers use every day. Kilobat resolves these on this Mac to name their addresses,
    /// and never calls them new.
    public static let wellKnown: [String] = [
        "registry.npmjs.org", "registry.yarnpkg.com", "pypi.org", "files.pythonhosted.org", "github.com", "api.github.com", "codeload.github.com",
        "objects.githubusercontent.com", "raw.githubusercontent.com", "release-assets.githubusercontent.com", "ghcr.io", "pkg-containers.githubusercontent.com",
        "gitlab.com", "bitbucket.org", "crates.io", "static.crates.io", "index.crates.io", "proxy.golang.org", "sum.golang.org", "rubygems.org",
        "index.rubygems.org", "formulae.brew.sh", "registry-1.docker.io", "auth.docker.io", "production.cloudflare.docker.com", "nodejs.org", "bun.sh",
        "deno.land", "jsr.io", "repo.maven.apache.org", "repo1.maven.org", "pub.dev", "cdn.cocoapods.org",
        "api.anthropic.com", "statsig.anthropic.com", "claude.ai", "api.openai.com", "chatgpt.com", "generativelanguage.googleapis.com",
        "cloudcode-pa.googleapis.com", "oauth2.googleapis.com", "api2.cursor.sh", "api3.cursor.sh", "marketplace.cursorapi.com",
        "server.codeium.com", "api.githubcopilot.com"]

    /// Each agent's own service: large uploads there are the agent sending its context, which is how it works.
    static let ownService: [String: [String]] = [
        "claude": ["anthropic.com", "claude.ai", "claude.com"], "claude-desktop": ["anthropic.com", "claude.ai", "claude.com"],
        "codex": ["openai.com", "chatgpt.com"], "chatgpt": ["openai.com", "chatgpt.com", "oaiusercontent.com"],
        "gemini": ["googleapis.com", "google.com"], "cursor": ["cursor.sh", "cursor.com", "cursorapi.com"], "cursor-agent": ["cursor.sh", "cursor.com"],
        "windsurf": ["codeium.com", "windsurf.com"], "copilot": ["githubcopilot.com", "github.com"], "amp": ["ampcode.com", "sourcegraph.com"]]

    /// Paste sites, file shares, tunnels and request catchers, by domain.
    static let shares: [(suffix: String, kind: String)] = {
        let paste = ["pastebin.com", "paste.ee", "hastebin.com", "dpaste.org", "dpaste.com", "termbin.com", "ix.io", "sprunge.us", "paste.rs", "rentry.co", "privatebin.net", "justpaste.it"]
        let files = ["transfer.sh", "file.io", "0x0.st", "temp.sh", "catbox.moe", "gofile.io", "wetransfer.com", "we.tl", "sendspace.com", "mega.nz", "mega.io",
                     "filebin.net", "oshi.at", "bashupload.com", "uguu.se", "pixeldrain.com"]
        let tunnels = ["ngrok.io", "ngrok.app", "ngrok-free.app", "ngrok.dev", "ngrok-free.dev", "trycloudflare.com", "loca.lt", "localtunnel.me", "serveo.net",
                       "localhost.run", "lhr.life", "pinggy.io", "pinggy.link", "bore.pub", "playit.gg"]
        let catchers = ["webhook.site", "requestbin.com", "pipedream.net", "beeceptor.com", "requestcatcher.com", "interact.sh", "oast.pro", "oast.live",
                        "oast.site", "oast.online", "oast.fun", "oast.me", "oastify.com", "burpcollaborator.net", "canarytokens.com", "dnslog.cn"]
        return paste.map { ($0, "paste site") } + files.map { ($0, "file share") } + tunnels.map { ($0, "tunnel") } + catchers.map { ($0, "request catcher") }
    }()

    static func matches(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

    /// "paste site", "file share", "tunnel" or "request catcher".
    public static func share(_ host: String) -> String? {
        let host = host.lowercased()
        return shares.first { matches(host, $0.suffix) }?.kind
    }
    public static func ownService(_ host: String, agent: String) -> Bool {
        let host = host.lowercased()
        return (ownService[agent] ?? []).contains { matches(host, $0) }
    }
    public static func isWellKnown(_ host: String) -> Bool { wellKnown.contains(host.lowercased()) }

    /// Hosts in a command's URLs, never their paths, queries or credentials: `curl https://user:token@bun.sh/install` gives bun.sh.
    public static func hosts(inArguments arguments: [String]) -> [String] {
        var hosts: [String] = []
        for argument in arguments.prefix(64) {
            for scheme in ["https://", "http://", "git+https://", "ssh://"] {
                guard let range = argument.range(of: scheme) else { continue }
                var rest = argument[range.upperBound...]
                if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<end] }
                if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
                if rest.hasPrefix("[") { continue }
                if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
                let host = rest.lowercased()
                if host.contains("."), host.count <= 253, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
                   !host.allSatisfy({ $0.isNumber || $0 == "." }), !hosts.contains(host) { hosts.append(host) }
            }
        }
        return hosts
    }
}
