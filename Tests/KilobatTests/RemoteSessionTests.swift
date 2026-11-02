import Foundation
import Testing
@testable import KilobatCore

/// SSH, Mosh and remote desktop reports: which processes count, how lags are blamed, when Mosh is suggested, and when
/// the server itself is called slow. Processes and sockets come from recorded `ps` and `nettop` output; nothing connects.
struct RemoteSessionTests {
    // `ps -axww -o pid=,ppid=,tty=,args=` on a developer's Mac, hosts swapped for documentation names.
    static let ps = """
      410     1 ttys003  -zsh
      501   410 ttys003  ssh build.example.com
      502   410 ttys004  ssh -t me@build.example.com tmux attach
      490   410 ttys005  scp notes.txt build.example.com:/tmp
      503   490 ttys005  /usr/bin/ssh -x -oPermitLocalCommand=no -oClearAllForwardings=yes -oRemoteCommand=none -oRequestTTY=no -oForwardAgent=no -l me -- build.example.com scp -t /tmp
      491   410 ttys006  git fetch
      504   491 ttys006  /usr/bin/ssh -o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'org/repo.git'
      505   410 ttys007  ssh -N -L 5432:localhost:5432 db.example.com
      506     1 ??       ssh -fNL 8080:localhost:80 web.example.com
      507   501 ttys003  ssh -W [build.example.com]:22 bastion.example.com
      508   410 ttys009  sftp build.example.com
      509   508 ttys009  /usr/bin/ssh -oForwardX11 no -oPermitLocalCommand no -oClearAllForwardings yes -oForwardAgent no -l me -s -- build.example.com sftp
      492   410 ttys010  rsync -av site/ build.example.com:/srv/site
      510   492 ttys010  ssh -l me build.example.com rsync --server -vlogDtpre.iLsfxCIvu . /srv/site
      511     1 ??       ssh: /Users/me/.ssh/cm-ca984ac94d8e [mux]
      512    75 ??       /usr/bin/ssh -T -o BatchMode=yes -o ServerAliveInterval=15 agent.example.com sh -c true
      513   410 ttys011  ssh -l me -p 2222 build.example.com
      514   410 ttys012  ssh build.example.com uptime
      515   410 ttys013  ssh -O exit build.example.com
      516   410 ttys014  mosh-client -# build.example.com | 203.0.113.5 60001
    """
    private var processes: [Int32: RemoteSessionDetector.Process] {
        Dictionary(uniqueKeysWithValues: RemoteSessionDetector.linkParents(RemoteSessionDetector.parse(ps: Self.ps)).map { ($0.pid, $0) })
    }
    private func use(_ pid: Int32) -> RemoteSessionDetector.SSHUse { RemoteSessionDetector.classify(ssh: processes[pid]!) }

    // MARK: Detection

    @Test func tellsInteractiveSSHFromCopiesTunnelsAndGit() {
        #expect(use(501) == .interactive)
        #expect(use(502) == .interactive)
        #expect(use(513) == .interactive)
        #expect(use(503) == .transfer)
        #expect(use(509) == .transfer)
        #expect(use(510) == .transfer)
        #expect(use(504) == .git)
        #expect(use(505) == .tunnel)
        #expect(use(506) == .tunnel)
        #expect(use(507) == .proxy)
        #expect(use(511) == .multiplexMaster)
        #expect(use(512) == .command)
        #expect(use(514) == .command)
        #expect(use(515) == .control)
    }

    @Test func aTerminalAppParentCountsWhenTheTTYCantBeRead() {
        let typed = RemoteSessionDetector.Process(pid: 1, ppid: 0, name: "ssh", args: ["ssh", "build.example.com"], tty: false, parent: "zsh", app: "com.googlecode.iterm2")
        #expect(RemoteSessionDetector.classify(ssh: typed) == .interactive)
        // An editor's or agent's ssh with no terminal of its own is a command, whatever its parent.
        let headless = RemoteSessionDetector.Process(pid: 2, ppid: 0, name: "ssh", args: ["ssh", "build.example.com"], tty: false, parent: "node", app: "com.example.agent")
        #expect(RemoteSessionDetector.classify(ssh: headless) == .command)
        // git under GIT_SSH_COMMAND, without git as the parent, still reads as git from its remote command.
        let gitCommand = RemoteSessionDetector.Process(pid: 3, ppid: 0, name: "ssh", args: ["ssh", "git@github.com", "git-receive-pack", "'org/repo.git'"], tty: true, parent: "zsh")
        #expect(RemoteSessionDetector.classify(ssh: gitCommand) == .git)
    }

    @Test func readsTheHostAsTyped() {
        #expect(RemoteSessionDetector.destination(ssh: ["ssh", "-l", "me", "-p", "2222", "build.example.com"]) == "build.example.com")
        #expect(RemoteSessionDetector.destination(ssh: ["ssh", "-t", "me@build.example.com", "tmux", "attach"]) == "build.example.com")
        #expect(RemoteSessionDetector.destination(ssh: ["ssh", "-p2222", "-v", "ssh://me@build.example.com:2222"]) == "build.example.com")
        #expect(RemoteSessionDetector.destination(ssh: ["ssh", "-o", "ServerAliveInterval=15", "--", "build"]) == "build")
        let mosh = RemoteSessionDetector.mosh(processes[516]!.args)
        #expect(mosh.host == "build.example.com")
        #expect(mosh.address == "203.0.113.5")
        #expect(mosh.port == "60001")
    }

    // `nettop -L 1 -n -x -p <pid> -J bytes_in,bytes_out,rtt_avg`
    static let nettop = """
    ,bytes_in,bytes_out,rtt_avg,
    ssh.501,119613,19038,,
    tcp4 192.168.1.20:62745<->203.0.113.40:22,119613,19038,41.50 ms,
    tcp4 127.0.0.1:62746<->127.0.0.1:5432,100,100,0.05 ms,
    """

    @Test func findsTheHostFromTheSocketPeer() {
        let sockets = RemoteSessionDetector.sockets(nettop: Self.nettop)
        #expect(sockets.count == 1)
        let peer = RemoteSessionDetector.peer(.ssh, sockets: sockets)
        #expect(peer?.address == "203.0.113.40")
        #expect(peer?.port == "22")
        #expect(peer?.rtt == 41.5)
        #expect(peer?.pid == 501)
        // A session to this Mac (a VM or container on localhost) has no peer, so it isn't measured.
        #expect(RemoteSessionDetector.peer(.ssh, sockets: RemoteSessionDetector.sockets(nettop: ",bytes_in,bytes_out,rtt_avg,\nssh.9,1,1,\ntcp4 127.0.0.1:5000<->127.0.0.1:2222,10,10,0.04 ms,")) == nil)
        let mosh = RemoteSessionDetector.sockets(nettop: ",bytes_in,bytes_out,rtt_avg,\nmosh-client.516,1,1,\nudp4 192.168.1.20:60001<->203.0.113.5:60001,5000,4000,,")
        #expect(RemoteSessionDetector.peer(.mosh, sockets: mosh)?.address == "203.0.113.5")
        // nettop cuts a long round trip's unit short.
        #expect(RemoteSessionDetector.sockets(nettop: ",bytes_in,bytes_out,rtt_avg,\nssh.9,1,1,\ntcp4 172.20.10.2:65479<->203.0.113.40:22,369197,37742,2354.62 m,").first?.rtt == 2354.62)
        let screen = RemoteSessionDetector.sockets(nettop: ",bytes_in,bytes_out,rtt_avg,\nScreen Sharing.77,1,1,\ntcp4 192.168.1.20:5000<->17.253.1.1:443,90000,9000,30 ms,\ntcp4 192.168.1.20:5001<->192.0.2.10:5900,40000,3000,4 ms,")
        #expect(RemoteSessionDetector.peer(.screenSharing, sockets: screen)?.address == "192.0.2.10")
    }

    @Test func knowsTheRemoteDesktopApps() {
        #expect(RemoteSessionDetector.viewer(bundleID: "com.apple.ScreenSharing", process: nil) == .screenSharing)
        #expect(RemoteSessionDetector.viewer(bundleID: "tv.parsec.www", process: "parsecd") == .parsec)
        #expect(RemoteSessionDetector.viewer(bundleID: "com.microsoft.rdc.macos", process: nil) == .windowsApp)
        #expect(RemoteSessionDetector.viewer(bundleID: "com.p5sys.jump.mac.viewer.web", process: nil) == .jump)
        #expect(RemoteSessionDetector.viewer(bundleID: "com.google.Chrome", process: nil) == nil)
    }

    private func typing(_ count: Int, front: Bool = true, up: Double = 120, down: Double = 300) -> [RemoteSessionDetector.Second] {
        (0..<count).map { .init(at: Double($0), up: $0 % 2 == 0 ? up : 0, down: down, front: front) }
    }

    @Test func countsOnlySessionsTypedIntoForAMinute() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(RemoteSessionDetector.counts(.ssh, start: start, end: start.addingTimeInterval(300), seconds: typing(300)))
        #expect(!RemoteSessionDetector.counts(.ssh, start: start, end: start.addingTimeInterval(45), seconds: typing(45)))
        // A tunnel or a copy moves data with no terminal in front: no input.
        #expect(!RemoteSessionDetector.counts(.ssh, start: start, end: start.addingTimeInterval(300), seconds: typing(300, front: false, up: 900_000)))
        // A viewer receives the screen; one sending more than it gets is this Mac being shared out.
        #expect(RemoteSessionDetector.counts(.parsec, start: start, end: start.addingTimeInterval(300), seconds: typing(300, up: 2_000, down: 800_000)))
        #expect(!RemoteSessionDetector.counts(.teamViewer, start: start, end: start.addingTimeInterval(300), seconds: typing(300, up: 800_000, down: 2_000)))
    }

    // MARK: Reports

    private func pings(_ count: Int, base: Double, spikes: [Int: Double?] = [:]) -> [CallSamples.Ping] {
        (0..<count).map { i in .init(at: Double(i), ms: spikes.first { i >= $0.key && i < $0.key + 3 }.map(\.value) ?? base + Double(i % 3)) }
    }
    private func samples(_ seconds: Int = 600, remote: [CallSamples.Ping]? = nil, internet: [CallSamples.Ping]? = nil, router: [CallSamples.Ping]? = nil) -> RemoteSamples {
        var samples = RemoteSamples()
        samples.remote = remote ?? pings(seconds, base: 40)
        samples.line.internet = internet ?? pings(seconds, base: 20)
        samples.line.router = router ?? pings(seconds, base: 3)
        samples.seconds = typing(seconds)
        return samples
    }
    private func report(_ samples: RemoteSamples, seconds: Double = 600) -> RemoteSessionReport { report(.ssh, samples, seconds: seconds) }
    private func report(_ kind: RemoteSessionReport.Kind, _ samples: RemoteSamples, seconds: Double = 600) -> RemoteSessionReport {
        RemoteAnalysis.report(kind: kind, host: "build.example.com", address: "203.0.113.40", port: "22", start: Date(timeIntervalSince1970: 0),
                              end: Date(timeIntervalSince1970: seconds), network: nil, samples: samples)
    }

    @Test func aSteadyLineIsClean() {
        let card = report(samples())
        #expect(card.clean)
        #expect(card.measured == .host)
        #expect(card.verdict == "No lag")
        #expect(!card.suggestsMosh)
        #expect(report(.parsec, samples()).verdict == "No freezes")
    }

    @Test func blamesWiFiJitterAndSuggestsMoshForSSH() {
        let spikes: [Int: Double?] = [100: 600, 400: nil]
        let card = report(samples(remote: pings(600, base: 40, spikes: spikes), router: pings(600, base: 3, spikes: [100: 250, 400: nil])))
        #expect(card.lags.count == 2)
        #expect(card.lags.allSatisfy { $0.cause.kind == .wifi })
        #expect(card.verdict == "Typing lagged twice: jitter on your Wi-Fi or router (RTT to build.example.com swung 40→600 ms)")
        #expect(card.suggestsMosh)
        #expect(card.mosh?.contains("mosh build.example.com") == true)
        // Already Mosh, or a remote desktop: no suggestion.
        let mosh = report(.mosh, samples(remote: pings(600, base: 40, spikes: spikes), router: pings(600, base: 3, spikes: [100: 250, 400: nil])))
        #expect(!mosh.suggestsMosh && mosh.mosh == nil)
        #expect(!report(.parsec, samples(remote: pings(600, base: 40, spikes: spikes), router: pings(600, base: 3, spikes: [100: 250, 400: nil]))).suggestsMosh)
    }

    @Test func blamesAnUploadAndDoesntSuggestMoshForIt() {
        var line = samples(remote: pings(600, base: 18, spikes: [200: 420, 450: nil]))
        line.line.traffic = [.init(at: 199, app: "Dropbox", upload: 1_400_000, download: 0), .init(at: 450, app: "Dropbox", upload: 1_200_000, download: 0)]
        let desktop = report(.parsec, line)
        #expect(desktop.verdict == "Screen froze twice: your upload was saturated by Dropbox")
        #expect(desktop.advice == "Pause Dropbox while you work on build.example.com, or block it with a profile.")
        let ssh = report(.ssh, line)
        #expect(ssh.causes.first?.cause.kind == .app)
        #expect(!ssh.suggestsMosh)
    }

    @Test func tellsThePathToTheHostFromTheProvider() {
        // The host stalls while the internet answers on time: past the provider.
        let path = report(samples(remote: pings(600, base: 40, spikes: [300: nil])))
        #expect(path.lags.first?.cause.kind == .remotePath)
        #expect(path.verdict.hasPrefix("Typing lagged once: delay on the way to build.example.com, past your provider"))
        #expect(path.suggestsMosh)
        // Both stall together: the provider or beyond.
        let provider = report(samples(remote: pings(600, base: 40, spikes: [300: nil]), internet: pings(600, base: 20, spikes: [300: nil])))
        #expect(provider.lags.first?.cause.kind == .beyondRouter)
    }

    @Test func theSignInPageComesFirst() {
        // Logged out by a hotel's sign-in page: the router stalls too, but the page is the cause, and Mosh isn't the fix.
        var line = samples(remote: pings(600, base: 40, spikes: [300: nil]), router: pings(600, base: 3, spikes: [300: nil]))
        line.line.loggedOut = 299
        let card = report(line)
        #expect(card.lags.first?.cause.kind == .portal)
        #expect(card.verdict == "Typing lagged once: the Wi-Fi’s sign-in page logged you out")
        #expect(card.advice?.hasPrefix("Sign in again") == true)
        #expect(!card.suggestsMosh)
    }

    @Test func namesABusyPairedMac() {
        var line = samples(remote: pings(600, base: 40, spikes: [300: 700]))
        line.line.peers = [.init(at: 298, name: "Sam’s MacBook", upload: 30_000, download: 3_900_000, app: "Steam")]
        let card = report(line)
        #expect(card.lags.first?.cause.kind == .otherDevice)
        #expect(card.lags.first?.cause.unconfirmed == true)
        #expect(card.verdict == "Typing lagged once: Sam’s MacBook was downloading on your network (Steam)")
        #expect(card.needsStatusCheck)
        // Once the service's page reports an outage, the paired Mac's own word no longer names it.
        line.line.peersWithoutRouter = false
        #expect(report(line).lags.first?.cause.kind == .remotePath)
    }

    @Test func aServiceOutageIsTheirsAndNotForMosh() throws {
        var card = report(samples(remote: pings(600, base: 40, spikes: [300: nil])))
        #expect(card.needsStatusCheck && card.suggestsMosh)
        card.service = ServiceStatus(id: "tailscale", service: "Tailscale", state: .majorOutage, page: try #require(URL(string: "https://status.tailscale.com")), checked: Date())
        #expect(card.advice == "That was Tailscale’s own trouble, not your line, so there’s nothing to change here.")
        #expect(!card.suggestsMosh)
        #expect(RemoteAnalysis.services(host: "login.tailscale.com", app: nil).map(\.id) == ["tailscale"])
        #expect(RemoteAnalysis.services(host: "build.example.com", app: nil).isEmpty)
    }

    @Test func aFarHostIsAFindingEvenOnACleanLine() {
        let card = report(samples(remote: pings(600, base: 182)))
        #expect(card.far)
        #expect(!card.clean)
        #expect(card.lags.isEmpty)
        #expect(card.verdict == "Every keystroke waited about 183 ms: build.example.com is far away")
        #expect(card.suggestsMosh)
        #expect(!report(.parsec, samples(remote: pings(600, base: 182))).suggestsMosh)
    }

    @Test func aHostThatIgnoresPingIsMeasuredToTheInternet() {
        var line = samples(remote: (0..<600).map { .init(at: Double($0), ms: nil) })
        line.connection = [.init(at: 3, ms: 44), .init(at: 6, ms: 41), .init(at: 9, ms: 47)]
        let card = report(line)
        #expect(card.measured == .internet)
        #expect(card.lags.isEmpty)
        #expect(card.base == 41)
        #expect(card.lossPercent == 0)
    }

    @Test func lagsWhileNobodyTypedDontCount() {
        var line = samples(remote: pings(600, base: 40, spikes: [100: 600, 400: 600]), router: pings(600, base: 3, spikes: [100: 250, 400: 250]))
        // Typing only in the first two minutes.
        line.seconds = (0..<600).map { .init(at: Double($0), up: $0 < 120 && $0 % 2 == 0 ? 100 : 0, down: 300, front: true) }
        #expect(report(line).lags.count == 1)
        // A screen that freezes matters whether or not you were clicking.
        #expect(report(.parsec, line).lags.count == 2)
    }

    // MARK: The server itself

    /// Typed at `at`, `at + 1` and `at + 2` with nothing back until `at + 3`.
    private func stalled(at moments: [Int], seconds: Int = 600) -> [RemoteSessionDetector.Second] {
        (0..<seconds).map { i in
            let stalled = moments.contains { i >= $0 && i < $0 + 3 }
            return .init(at: Double(i), up: stalled || i % 2 == 0 ? 90 : 0, down: stalled ? 0 : 300, front: true)
        }
    }

    @Test func callsTheServerSlowOnlyWithEvidence() {
        var line = samples()
        line.seconds = stalled(at: [120, 360])
        let slow = report(line)
        #expect(slow.lags.count == 2)
        #expect(slow.lags.allSatisfy { $0.cause.kind == .remoteSlow && $0.peak == nil })
        #expect(slow.verdict == "Typing lagged twice: build.example.com was slow to answer, but your line was fine")
        #expect(!slow.suggestsMosh)
        // Once could be anything: nothing is claimed.
        line.seconds = stalled(at: [120])
        #expect(report(line).lags.isEmpty)
        // Not when the line to the host stalled too: that's the network, found as a lag of its own.
        var network = samples(remote: pings(600, base: 40, spikes: [120: nil, 360: nil]))
        network.seconds = stalled(at: [120, 360])
        #expect(!report(network).lags.contains { $0.cause.kind == .remoteSlow })
        // Never for Mosh or a remote desktop, whose traffic doesn't follow keystrokes.
        var desktop = samples(); desktop.seconds = stalled(at: [120, 360])
        #expect(report(.mosh, desktop).lags.isEmpty)
    }

    @Test func aQuietCommandAfterEnterIsNoStall() {
        // Enter, then 30 seconds of a build printing nothing, then output.
        let seconds = (0..<120).map { i in RemoteSessionDetector.Second(at: Double(i), up: i == 40 ? 60 : 0, down: (41..<71).contains(i) ? 0 : 200, front: true) }
        #expect(RemoteAnalysis.stalls(seconds).isEmpty)
        #expect(RemoteAnalysis.stalls(stalled(at: [10], seconds: 30)).count == 1)
    }

    @Test func usesTheConnectionsOwnRoundTripWhenTheHostIgnoresPing() {
        var line = samples(remote: (0..<600).map { .init(at: Double($0), ms: nil) })
        line.seconds = stalled(at: [120, 360])
        // No TCP round trip measured: no evidence, no claim.
        #expect(report(line).lags.isEmpty)
        line.connection = stride(from: 0, to: 600, by: 3).map { .init(at: Double($0), ms: 42) }
        #expect(report(line).lags.filter { $0.cause.kind == .remoteSlow }.count == 2)
        // A round trip that jumped during the stalls is the line, not the server.
        line.connection = stride(from: 0, to: 600, by: 3).map { .init(at: Double($0), ms: (117...126).contains($0) || (357...366).contains($0) ? 900 : 42) }
        #expect(report(line).lags.isEmpty)
    }

    @Test func aSessionThatWentQuietEndsAtItsLastInput() {
        // Measured for ten minutes, but the report ends at five: a lag after that isn't counted.
        let line = samples(remote: pings(600, base: 40, spikes: [450: nil]), router: pings(600, base: 3, spikes: [450: nil]))
        let card = report(line, seconds: 300)
        #expect(card.lags.isEmpty)
        #expect(card.seconds == 300)
    }

    @Test func reportsRoundTripThroughJSON() throws {
        let card = report(samples(remote: pings(600, base: 40, spikes: [100: 600]), router: pings(600, base: 3, spikes: [100: 250])))
        let decoded = try JSONDecoder().decode([RemoteSessionReport].self, from: JSONEncoder().encode([card]))
        #expect(decoded == [card])
        // The CLI and MCP add the sentences and findings; the stored report still reads back from that JSON.
        let exported = try JSONEncoder().encode([RemoteSessionReport.Exported(card)])
        let object = try #require((try JSONSerialization.jsonObject(with: exported) as? [[String: Any]])?.first)
        #expect(object["suggestsMosh"] as? Bool == true)
        #expect((object["verdict"] as? String)?.hasPrefix("Typing lagged once") == true)
        #expect(object["kind"] as? String == "ssh")
        #expect(try JSONDecoder().decode([RemoteSessionReport].self, from: exported) == [card])
    }

    // MARK: CLI

    @Test func parsesTheRemoteCommand() throws {
        #expect(try RemoteSessionQuery.parse(["remote"]) == RemoteSessionQuery())
        let query = try RemoteSessionQuery.parse(["remote", "--limit", "5", "--kind", "desktop", "--json"])
        #expect(query.limit == 5 && query.filter == .desktop && query.json)
        for bad in [["remote", "--limit", "0"], ["remote", "--limit"], ["remote", "--kind", "vnc"], ["remote", "--since"], ["remote", "ssh"]] {
            #expect(throws: RemoteSessionQuery.Invalid.self) { try RemoteSessionQuery.parse(bad) }
        }
        let reports = [report(.ssh, samples()), report(.parsec, samples()), report(.mosh, samples()), report(.ssh, samples())]
        #expect(query.select(reports).map(\.kind) == [.parsec])
        var ssh = RemoteSessionQuery(); ssh.filter = .ssh; ssh.limit = 1
        #expect(ssh.select(reports).count == 1)
        #expect(RemoteSessionQuery().select(reports).first?.kind == .ssh)
    }
}
