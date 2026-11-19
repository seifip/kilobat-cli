import Darwin
import Foundation
import Testing
@testable import KilobatCore

struct NetworkShareTests {
    @Test func orbStackStyleSharesAreNamedOnceAndNotKnockedOn() throws {
        let orb = try #require(NetworkShare.parse(type: "nfs", from: "OrbStack:/OrbStack", on: "/Users/me/OrbStack"))
        #expect(ShareCheck(share: orb, state: .silent).name == "OrbStack")
        #expect(ShareProbe.bareName("OrbStack"))
        #expect(!ShareProbe.bareName("nas.local") && !ShareProbe.bareName("192.168.1.20") && !ShareProbe.bareName("fd00::5") && !ShareProbe.bareName("localhost"))
    }

    @Test func readsSMBMountsAsTheMountTableListsThem() throws {
        // `mount` on macOS 27: user and domain before the host, a Bonjour name, a port, a percent-encoded share.
        let plain = try #require(NetworkShare.parse(type: "smbfs", from: "//philip@nas.local/Public", on: "/Volumes/Public"))
        #expect(plain.kind == .smb)
        #expect(plain.server == "nas.local")
        #expect(plain.share == "Public")
        #expect(plain.volume == "Public")
        #expect(plain.endpoint == .host("nas.local", port: 445))

        let bonjour = try #require(NetworkShare.parse(type: "smbfs", from: "//GUEST:@Synology._smb._tcp.local/Photo%20Library", on: "/Volumes/Photo Library"))
        #expect(bonjour.server == "Synology")
        #expect(bonjour.share == "Photo Library")
        #expect(bonjour.endpoint == .bonjour(name: "Synology", type: "_smb._tcp", domain: "local."))

        let domain = try #require(NetworkShare.parse(type: "smbfs", from: "//CORP;jane@fileserver.corp.example:1445/Projects", on: "/Volumes/Projects-1"))
        #expect(domain.server == "fileserver.corp.example")
        #expect(domain.endpoint == .host("fileserver.corp.example", port: 1445))
        #expect(domain.volume == "Projects-1")

        let address = try #require(NetworkShare.parse(type: "smbfs", from: "//192.168.1.20/backup", on: "/Volumes/backup"))
        #expect(address.endpoint == .host("192.168.1.20", port: 445))

        let ipv6 = try #require(NetworkShare.parse(type: "smbfs", from: "//[fd00::20]:445/media", on: "/Volumes/media"))
        #expect(ipv6.endpoint == .host("fd00::20", port: 445))
    }

    @Test func readsAFPNFSAndWebDAV() throws {
        let afp = try #require(NetworkShare.parse(type: "afpfs", from: "//admin@TimeCapsule._afpovertcp._tcp.local/Data", on: "/Volumes/Data"))
        #expect(afp.kind == .afp)
        #expect(afp.endpoint == .bonjour(name: "TimeCapsule", type: "_afpovertcp._tcp", domain: "local."))
        let afpHost = try #require(NetworkShare.parse(type: "afpfs", from: "//old-mac.local/Shared", on: "/Volumes/Shared"))
        #expect(afpHost.endpoint == .host("old-mac.local", port: 548))

        let nfs = try #require(NetworkShare.parse(type: "nfs", from: "truenas.lan:/mnt/tank/media", on: "/Users/me/media"))
        #expect(nfs.kind == .nfs)
        #expect(nfs.server == "truenas.lan")
        #expect(nfs.share == "/mnt/tank/media")
        #expect(nfs.endpoint == .host("truenas.lan", port: 2049))
        let nfs6 = try #require(NetworkShare.parse(type: "nfs", from: "[fd00::5]:/export", on: "/private/nfs"))
        #expect(nfs6.endpoint == .host("fd00::5", port: 2049))
        #expect(nfs6.share == "/export")

        let dav = try #require(NetworkShare.parse(type: "webdav", from: "https://cloud.example.org/remote.php/dav/files/me", on: "/Volumes/me"))
        #expect(dav.kind == .webdav)
        #expect(dav.endpoint == .host("cloud.example.org", port: 443))
        let plainDav = try #require(NetworkShare.parse(type: "webdav", from: "http://192.168.1.9:8080/dav", on: "/Volumes/dav"))
        #expect(plainDav.endpoint == .host("192.168.1.9", port: 8080))
    }

    @Test func ignoresLocalFileSystems() {
        #expect(NetworkShare.parse(type: "apfs", from: "/dev/disk3s1s1", on: "/") == nil)
        #expect(NetworkShare.parse(type: "devfs", from: "devfs", on: "/dev") == nil)
        #expect(NetworkShare.parse(type: "autofs", from: "map auto_home", on: "/System/Volumes/Data/home") == nil)
        #expect(NetworkShare.parse(type: "smbfs", from: "garbage", on: "/Volumes/x") == nil)
        #expect(NetworkShare.parse(type: "nfs", from: ":/nohost", on: "/x") == nil)
    }

    @Test func theRealMountTableReadsWithoutTouchingShares() {
        // Whatever is mounted on the Mac running the tests; this only reads the kernel's cached table.
        let shares = ShareProbe.mounted()
        #expect(shares.allSatisfy { !$0.server.isEmpty && !$0.mountPoint.isEmpty })
    }

    private let share = NetworkShare(kind: .smb, server: "nas.local", share: "Public", mountPoint: "/Volumes/Public", endpoint: .host("nas.local", port: 445))

    @Test func findingsSayWhatToDo() throws {
        let silent = try #require(ShareCheck(share: share, state: .silent).finding)
        #expect(silent.title == "Public on nas.local isn’t responding")
        #expect(silent.detail.contains("ejected"))
        #expect(silent.detail.contains("Finder"))
        #expect(silent.problem)
        let refused = try #require(ShareCheck(share: share, state: .refused).finding)
        #expect(!refused.problem)
        #expect(ShareCheck(share: share, state: .answering, milliseconds: 4).finding == nil)
        #expect(ShareCheck(share: share, state: .unknown).finding == nil)
        #expect(ShareCheck(share: share, state: .silent).ejectCommand == #"diskutil unmount force "/Volumes/Public""#)
    }

    @MainActor @Test func aShareIsGoneAfterTwoMissedChecksAndBackOnAnswer() {
        let watch = ShareWatch()
        var changes: [Bool] = []
        watch.onChange = { _, gone in changes.append(gone) }
        watch.apply([ShareCheck(share: share, state: .silent)])
        #expect(watch.gone.isEmpty)
        // Can't tell: the count stands.
        watch.apply([ShareCheck(share: share, state: .unknown)])
        #expect(watch.gone.isEmpty)
        watch.apply([ShareCheck(share: share, state: .silent)])
        #expect(watch.gone.map(\.id) == ["/Volumes/Public"])
        watch.apply([ShareCheck(share: share, state: .silent)])
        #expect(changes == [true])
        watch.apply([ShareCheck(share: share, state: .answering)])
        #expect(watch.gone.isEmpty)
        #expect(changes == [true, false])
        // Ejected while gone: it drops out without a "back" event.
        watch.apply([ShareCheck(share: share, state: .silent)]); watch.apply([ShareCheck(share: share, state: .silent)])
        watch.apply([])
        #expect(watch.gone.isEmpty)
        #expect(changes == [true, false, true])
    }

    /// A listening socket on the loopback address, and the port of one that's closed.
    private func loopback(listening: Bool) throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        if listening { try #require(listen(fd, 4) == 0) } else { close(fd) }
        return (fd, port)
    }

    @Test func knocksOnTheServersPortOnly() async throws {
        let (open, openPort) = try loopback(listening: true)
        defer { close(open) }
        let answering = await ShareProbe.knock(NetworkShare(kind: .smb, server: "127.0.0.1", share: "x", mountPoint: "/Volumes/x", endpoint: .host("127.0.0.1", port: openPort)), timeout: 2)
        #expect(answering.state == .answering)
        #expect(answering.milliseconds != nil)
        let (_, closedPort) = try loopback(listening: false)
        let refused = await ShareProbe.knock(NetworkShare(kind: .smb, server: "127.0.0.1", share: "y", mountPoint: "/Volumes/y", endpoint: .host("127.0.0.1", port: closedPort)), timeout: 2)
        #expect(refused.state == .refused)
    }
}
