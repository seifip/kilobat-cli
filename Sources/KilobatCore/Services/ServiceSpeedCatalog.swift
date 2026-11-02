import Foundation

/// A service whose big downloads Kilobat measures: GitHub, iCloud, Steam, npm. Found by the host a connection asked for,
/// the app that made it, or the network its address belongs to.
public struct SpeedService: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Domains, matched with their subdomains.
    public var hosts: [String] = []
    /// Bundle-ID prefixes and process:<name> IDs.
    public var apps: [String] = []
    /// Networks (`NetworkOwners` ids) that carry only this service.
    public var networks: [String] = []
    /// `ServiceCatalog`'s status page for it.
    public var status: String? = nil
    /// Video, music and calls send at the pace they play, not as fast as the line allows, so they're never measured.
    public var paced = false
}

/// What Kilobat measures, and the networks it names when it can't tell the service.
public enum ServiceSpeedCatalog {
    public static let services: [SpeedService] = [
        SpeedService(id: "github", name: "GitHub", hosts: ["github.com", "githubusercontent.com", "githubassets.com", "ghcr.io", "github.io", "githubcopilot.com"],
                     apps: ["com.github.GitHubClient"], networks: ["github"], status: "github"),
        SpeedService(id: "icloud", name: "iCloud", hosts: ["icloud.com", "icloud-content.com", "me.com", "apple-cloudkit.com", "icloud.com.cn"],
                     apps: ["process:bird", "process:cloudd", "process:fileproviderd", "com.apple.CloudDocs"], status: "icloud"),
        SpeedService(id: "apple", name: String(localized: "Apple downloads", comment: "Service speed: the App Store and software updates"),
                     hosts: ["swcdn.apple.com", "swdist.apple.com", "updates.cdn-apple.com", "cdn-apple.com", "mzstatic.com", "aaplimg.com", "osxapps.itunes.apple.com", "appldnld.apple.com"],
                     apps: ["com.apple.AppStore", "process:softwareupdated", "process:storedownloadd", "process:appstoreagent", "process:mobileassetd", "process:com.apple.Mobile"],
                     status: "app-store"),
        SpeedService(id: "dropbox", name: "Dropbox", hosts: ["dropbox.com", "dropboxapi.com", "dropboxusercontent.com", "dropboxstatic.com"],
                     apps: ["com.getdropbox.dropbox"], networks: ["dropbox"], status: "dropbox"),
        SpeedService(id: "google-drive", name: "Google Drive", hosts: ["drive.google.com", "drive.usercontent.google.com", "docs.googleusercontent.com"],
                     apps: ["com.google.drivefs"], status: "google-drive"),
        SpeedService(id: "onedrive", name: "OneDrive", hosts: ["onedrive.live.com", "onedrive.com", "1drv.ms", "storage.live.com"],
                     apps: ["com.microsoft.OneDrive"], status: "onedrive"),
        SpeedService(id: "steam", name: "Steam", hosts: ["steamcontent.com", "steampowered.com", "steamstatic.com", "steamserver.net", "steamusercontent.com", "valvesoftware.com"],
                     apps: ["com.valvesoftware.steam", "process:steam_osx", "process:steamwebhelper"], networks: ["valve"]),
        SpeedService(id: "epic", name: "Epic Games", hosts: ["epicgames.com", "epicgames-download1.akamaized.net", "fortnite.com", "unrealengine.com"], apps: ["com.epicgames."], status: "epic"),
        SpeedService(id: "battlenet", name: "Battle.net", hosts: ["battle.net", "blizzard.com", "blzddist1-a.akamaihd.net"], apps: ["net.battle."]),
        SpeedService(id: "npm", name: "npm", hosts: ["registry.npmjs.org", "npmjs.org", "npmjs.com", "yarnpkg.com"],
                     apps: ["process:npm", "process:pnpm", "process:yarn", "process:bun"], status: "npm"),
        SpeedService(id: "pypi", name: "PyPI", hosts: ["pypi.org", "pythonhosted.org"], apps: ["process:pip", "process:pip3", "process:uv"]),
        SpeedService(id: "docker", name: "Docker", hosts: ["docker.io", "docker.com"], apps: ["com.docker.docker", "process:com.docker.backend"], status: "docker"),
        SpeedService(id: "huggingface", name: "Hugging Face", hosts: ["huggingface.co", "hf.co"], status: "huggingface"),
        SpeedService(id: "microsoft", name: String(localized: "Microsoft downloads", comment: "Service speed: Office, Edge and other Microsoft installers and updates"),
                     hosts: ["officecdn.microsoft.com", "download.microsoft.com", "delivery.mp.microsoft.com", "onecdn.static.microsoft"], apps: ["com.microsoft.autoupdate"]),
        SpeedService(id: "zoom", name: "Zoom", hosts: ["zoom.us", "zoom.com"], apps: ["us.zoom."], networks: ["zoom"], status: "zoom", paced: true),
        // Played at their own pace.
        SpeedService(id: "youtube", name: "YouTube", hosts: ["googlevideo.com", "youtube.com", "ytimg.com", "youtube-nocookie.com"], paced: true),
        SpeedService(id: "netflix", name: "Netflix", hosts: ["nflxvideo.net", "netflix.com", "nflxso.net", "nflxext.com"], networks: ["netflix"], paced: true),
        SpeedService(id: "twitch", name: "Twitch", hosts: ["ttvnw.net", "twitch.tv", "jtvnw.net"], paced: true),
        SpeedService(id: "spotify", name: "Spotify", hosts: ["scdn.co", "spotify.com", "spotifycdn.com"], apps: ["com.spotify.client"], paced: true),
        SpeedService(id: "apple-media", name: "Apple Music and TV", hosts: ["aod.itunes.apple.com", "hls.itunes.apple.com", "play.itunes.apple.com", "tv.apple.com"],
                     apps: ["com.apple.Music", "com.apple.TV", "com.apple.podcasts"], paced: true),
        SpeedService(id: "disney", name: "Disney+", hosts: ["dssott.com", "disney-plus.net", "bamgrid.com", "disneyplus.com"], paced: true),
        SpeedService(id: "prime-video", name: "Prime Video", hosts: ["aiv-cdn.net", "aiv-delivery.net", "primevideo.com", "pv-cdn.net"], paced: true),
        SpeedService(id: "calls", name: "Calls", hosts: ["teams.microsoft.com", "meet.google.com", "discord.media", "slack-msgs.com"],
                     apps: ["com.apple.FaceTime", "process:avconferenced", "com.microsoft.teams", "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.cisco.webexmeetingsapp", "com.webex."], paced: true),
    ]

    /// Display names for the networks `NetworkOwners` knows.
    public static let networks: [String: String] = [
        "github": "GitHub", "cloudflare": "Cloudflare", "fastly": "Fastly", "google": "Google", "googlecloud": "Google Cloud",
        "cloudfront": "Amazon CloudFront", "aws": "Amazon Web Services", "apple": "Apple", "akamai": "Akamai", "microsoft": "Microsoft",
        "valve": "Valve", "dropbox": "Dropbox", "zoom": "Zoom", "netflix": "Netflix", "meta": "Meta",
    ]
    /// Reverse DNS names that tell the network when the address table doesn't: "a23-1-2-3.deploy.static.akamaitechnologies.com".
    static let reverseNetworks: [(suffix: String, network: String)] = [
        ("akamaitechnologies.com", "akamai"), ("akamaiedge.net", "akamai"), ("1e100.net", "google"), ("cloudfront.net", "cloudfront"),
        ("amazonaws.com", "aws"), ("github.com", "github"), ("aaplimg.com", "apple"), ("apple.com", "apple"), ("msedge.net", "microsoft"),
        ("fbcdn.net", "meta"), ("facebook.com", "meta"), ("valve.net", "valve"), ("steamcontent.com", "valve"),
    ]

    public static func service(_ id: String) -> SpeedService? { services.first { $0.id == id } }

    /// The service a host name belongs to; the longest matching domain wins.
    public static func service(forHost host: String) -> SpeedService? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return services.compactMap { service -> (SpeedService, Int)? in
            let best = service.hosts.filter { host == $0 || host.hasSuffix("." + $0) }.map(\.count).max()
            return best.map { (service, $0) }
        }.max { $0.1 < $1.1 }?.0
    }

    public static func service(forApp id: String) -> SpeedService? {
        services.first { service in service.apps.contains { $0.hasPrefix("process:") ? id.lowercased() == $0.lowercased() : id.hasPrefix($0) } }
    }

    /// The key a transfer is kept under: a service's id, `net:<network>` when only the network is known, or `other`.
    public static func name(of key: String) -> String {
        if key.hasPrefix("net:") { let network = String(key.dropFirst(4)); return networks[network] ?? network }
        if key == otherKey { return String(localized: "Other sites", comment: "Service speed: downloads Kilobat couldn't put a name to") }
        return service(key)?.name ?? key
    }
    public static let otherKey = "other"

    /// Who a connection belongs to: the host it asked for, the app, the network its address is in, its reverse DNS name.
    /// Nil when it's never measured: video, music and calls, which set their own pace.
    public static func attribute(host: String?, reverse: String?, app: String?, owner: String?) -> ServiceAttribution? {
        let byHost = host.flatMap(service(forHost:))
        if let byHost, byHost.paced { return nil }
        let byApp = app.flatMap(service(forApp:))
        if let byApp, byApp.paced { return nil }
        let byNetwork = owner.flatMap { network in services.first { $0.networks.contains(network) } }
        if let byNetwork, byNetwork.paced, byHost == nil { return nil }
        let byReverse = reverse.flatMap(service(forHost:)).flatMap { $0.paced ? nil : $0 }
        let network = owner ?? reverse.flatMap { name in
            let lower = name.lowercased()
            return reverseNetworks.first { lower == $0.suffix || lower.hasSuffix("." + $0.suffix) }?.network
        }
        let key = (byHost ?? byApp ?? byNetwork ?? byReverse)?.id ?? network.map { "net:" + $0 } ?? otherKey
        return ServiceAttribution(key: key, via: network, host: host, app: app)
    }
}

/// Where one connection's bytes are counted.
public struct ServiceAttribution: Sendable, Equatable {
    public let key: String
    /// The network its address belongs to, when known.
    public let via: String?
    public let host: String?
    public let app: String?
    public init(key: String, via: String?, host: String?, app: String?) { self.key = key; self.via = via; self.host = host; self.app = app }
}

/// A public file a service means to be downloaded, for Test this service: Kilobat fetches at most the first 25 MB of it,
/// only when the person asks, never on a metered network. Each was fetched with a range request on `ServiceSpeedTarget.checked`.
public struct ServiceSpeedTarget: Sendable, Equatable, Identifiable {
    public let id: String
    /// The `SpeedService` id or `net:` key its result is kept under.
    public let key: String
    public let name: String
    public let url: URL
    /// What it downloads, for the help text.
    public let file: String
    /// Asks for `bytes` of the file with ?bytes= instead of a Range header (Cloudflare's speed test endpoint).
    public var sized = false

    public static let checked = "2026-11-01"
    /// The most any one test downloads.
    public static let maximumBytes = 25_000_000

    public static let all: [ServiceSpeedTarget] = [
        ServiceSpeedTarget(id: "cloudflare", key: "net:cloudflare", name: "Cloudflare", url: URL(string: "https://speed.cloudflare.com/__down")!,
                           file: "Cloudflare’s speed test endpoint", sized: true),
        ServiceSpeedTarget(id: "github", key: "github", name: "GitHub", url: URL(string: "https://github.com/cli/cli/releases/download/v2.63.0/gh_2.63.0_macOS_universal.pkg")!,
                           file: "GitHub CLI 2.63.0 for macOS, a release download (26 MB)"),
        ServiceSpeedTarget(id: "apple", key: "apple", name: String(localized: "Apple downloads", comment: "Service speed: the App Store and software updates"),
                           url: URL(string: "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/UniversalMac_27.2_26B123_Restore.ipsw")!,
                           file: "the start of Apple’s public macOS 27.2 restore image"),
        ServiceSpeedTarget(id: "npm", key: "npm", name: "npm", url: URL(string: "https://registry.npmjs.org/@next/swc-darwin-arm64/-/swc-darwin-arm64-15.0.3.tgz")!,
                           file: "the @next/swc-darwin-arm64 15.0.3 package (41 MB)"),
        ServiceSpeedTarget(id: "pypi", key: "pypi", name: "PyPI", url: URL(string: "https://files.pythonhosted.org/packages/25/ca/1166b75c21abd1da445b97bf1fa2f14f423c6cfb4fc7c4ef31dccf9f6a94/numpy-2.1.3.tar.gz")!,
                           file: "the NumPy 2.1.3 source package (20 MB)"),
        ServiceSpeedTarget(id: "google", key: "net:google", name: "Google", url: URL(string: "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg")!,
                           file: "the start of the Chrome for Mac installer"),
        ServiceSpeedTarget(id: "microsoft", key: "microsoft", name: String(localized: "Microsoft downloads", comment: "Service speed: Office, Edge and other Microsoft installers and updates"),
                           url: URL(string: "https://go.microsoft.com/fwlink/?linkid=2069148")!, file: "the start of the Microsoft Edge for Mac installer"),
        ServiceSpeedTarget(id: "docker", key: "docker", name: "Docker", url: URL(string: "https://desktop.docker.com/mac/main/arm64/Docker.dmg")!,
                           file: "the start of the Docker Desktop installer"),
        ServiceSpeedTarget(id: "huggingface", key: "huggingface", name: "Hugging Face", url: URL(string: "https://huggingface.co/openai-community/gpt2/resolve/main/model.safetensors")!,
                           file: "the start of the public GPT-2 model file"),
        ServiceSpeedTarget(id: "zoom", key: "zoom", name: "Zoom", url: URL(string: "https://zoom.us/client/latest/Zoom.pkg")!, file: "the start of the Zoom for Mac installer"),
    ]

    public static func find(_ text: String) -> ServiceSpeedTarget? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == query || $0.key == query || $0.name.lowercased() == query }
    }
    /// The test for a row's key, when there is one.
    public static func target(forKey key: String) -> ServiceSpeedTarget? { all.first { $0.key == key } }
}
