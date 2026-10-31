import Darwin
import Foundation

/// Call mode: while a call is on, the apps that freeze calls — sync clients, backup tools, game launchers — are held.
/// Their processes are suspended so a transfer already running stops at once, the filter refuses their new
/// connections, and everything resumes when the call ends. Every suspended process is written down first, so a quit,
/// a crash or a three-hour limit always resumes it.
public enum CallMode {
    /// Apps that move a lot of data in the background and are safe to suspend for a while: they resume where they
    /// stopped. Bundle-ID prefixes and the name to show. Apple's own daemons (iCloud, Time Machine, software updates)
    /// aren't here: suspending system processes isn't safe, and updates already wait through the filter.
    public static let known: [(prefixes: [String], name: String)] = [
        (["com.getdropbox.dropbox"], "Dropbox"),
        (["com.google.drivefs"], "Google Drive"),
        (["com.microsoft.OneDrive"], "OneDrive"),
        (["com.box.desktop"], "Box"),
        (["com.backblaze."], "Backblaze"),
        (["com.haystacksoftware.Arq", "com.haystacksoftware.arq"], "Arq"),
        (["com.valvesoftware.steam"], "Steam"),
        (["com.epicgames.EpicGamesLauncher", "com.epicgames.launcher"], "Epic Games Launcher"),
        (["net.battle.app", "net.battle.bootstrapper"], "Battle.net"),
        (["com.adobe.acc."], "Creative Cloud"),
        (["com.transmissionbt.Transmission"], "Transmission"),
        (["org.qbittorrent.qBittorrent"], "qBittorrent"),
        (["com.synology.CloudStationUI", "com.synology.SynologyDrive"], "Synology Drive"),
        (["com.pcloud.pcloud.macos"], "pCloud"),
        (["io.mega.megasync", "mega.mac"], "MEGA"),
    ]

    public static func name(of bundleID: String) -> String? { known.first { $0.prefixes.contains { bundleID.hasPrefix($0) } }?.name }

    /// Game launchers own the games they start: suspending one mid-game breaks its DRM, overlay and voice chat. They're
    /// held only while they download and no game is in front.
    public static let launchers: Set<String> = ["Steam", "Epic Games Launcher", "Battle.net"]

    /// The frontmost app is a game, by its App Store category or because a launcher, Wine or CrossOver runs it.
    public static func gameInFront(bundleURL: URL?, executable: String?) -> Bool {
        if let executable, ["wine64-preloader", "wine-preloader", "wine64", "wine", "wineloader"].contains(executable) { return true }
        guard let bundleURL else { return false }
        if bundleURL.path.contains("/steamapps/") || bundleURL.path.contains("/CrossOver/") { return true }
        let category = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        return category?.hasPrefix("public.app-category.") == true && category!.contains("games")
    }

    /// The longest Kilobat holds anything, in case a call never seems to end.
    public static let limit: TimeInterval = 3 * 60 * 60

    /// Who holds a process: a call, or a Focus filter. Each lets go only of its own, and a process resumes once nobody holds it.
    public static let call = "call", focus = "focus"

    /// One suspended process, with its start time so a reused PID is never resumed by mistake.
    public struct Held: Codable, Sendable, Equatable {
        public let pid: Int32
        public let started: UInt64
        public let app: String
        /// Missing in ledgers written before Focus filters, when only calls held anything.
        public var owners: [String]?
        public var holders: [String] { owners ?? [CallMode.call] }
        public init(pid: Int32, started: UInt64, app: String, owners: [String]? = nil) {
            self.pid = pid; self.started = started; self.app = app; self.owners = owners
        }
    }

    public static var ledgerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kilobat/call-mode-held.json")
    }

    /// Suspends `pids` that belong to this user for `owner`, noting each before it stops. Returns what this owner now
    /// holds that it didn't: a process another owner already stopped is only noted as this one's too.
    public static func hold(_ pids: [Int32], app: String, owner: String = call, ledger: URL = ledgerURL) -> [Held] {
        var held = load(ledger)
        var now: [Held] = []
        for pid in Set(pids) where pid > 1 && pid != getpid() && owned(pid) {
            guard let started = startTime(pid) else { continue }
            if let index = held.firstIndex(where: { $0.pid == pid }) {
                if held[index].started == started {
                    guard !held[index].holders.contains(owner) else { continue }
                    held[index].owners = held[index].holders + [owner]; save(held, ledger)
                    now.append(held[index]); continue
                }
                // The PID was reused by a process nobody stopped; the old line is stale.
                held.remove(at: index); save(held, ledger)
            }
            let entry = Held(pid: pid, started: started, app: app, owners: [owner])
            held.append(entry); save(held, ledger)
            if kill(pid, SIGSTOP) == 0 { now.append(entry) } else { held.removeAll { $0.pid == pid }; save(held, ledger) }
        }
        return now
    }

    /// Lets go of what `owner` holds (or every owner's, with nil), of every app or only `app`. A process resumes when no
    /// owner holds it any more, and only if it's still the same process. Returns the processes resumed.
    @discardableResult public static func resume(app: String? = nil, owner: String? = nil, ledger: URL = ledgerURL) -> [Held] {
        var kept: [Held] = [], resumed: [Held] = []
        for var entry in load(ledger) {
            guard app == nil || entry.app == app, owner.map(entry.holders.contains) ?? true else { kept.append(entry); continue }
            let rest = owner.map { owner in entry.holders.filter { $0 != owner } } ?? []
            if rest.isEmpty { resumed.append(entry) } else { entry.owners = rest; kept.append(entry) }
        }
        for entry in resumed where startTime(entry.pid) == entry.started { kill(entry.pid, SIGCONT) }
        save(kept, ledger)
        return resumed
    }

    @MainActor private static var recovered = false
    /// Resumes everything a previous run left suspended, once per launch, before anything here holds again: whichever
    /// of call mode and Focus filters starts first runs it, so neither can resume what the other has just held.
    @MainActor public static func recoverAtLaunch(ledger: URL = ledgerURL) {
        guard !recovered else { return }
        recovered = true
        resume(ledger: ledger)
    }

    public static func held(ledger: URL = ledgerURL) -> [Held] { load(ledger) }

    static func load(_ url: URL) -> [Held] { (try? JSONDecoder().decode([Held].self, from: Data(contentsOf: url))) ?? [] }
    static func save(_ held: [Held], _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if held.isEmpty { try? FileManager.default.removeItem(at: url) } else { try? JSONEncoder().encode(held).write(to: url, options: .atomic) }
    }

    static func owned(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return false }
        return info.pbi_uid == getuid()
    }

    static func startTime(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}
