import Foundation
import Testing
@testable import KilobatCore

struct SteamLibraryTests {
    // The shape of a real manifest on a Mac with an update under way (Age of Empires II, 1030).
    let updating = """
    "AppState"
    {
    \t"appid"\t\t"813780"
    \t"name"\t\t"Age of Empires II: Definitive Edition"
    \t"StateFlags"\t\t"1030"
    \t"buildid"\t\t"25464371"
    \t"BytesToDownload"\t\t"133567248"
    \t"BytesDownloaded"\t\t"33567248"
    \t"TargetBuildID"\t\t"25500000"
    \t"InstalledDepots"
    \t{
    \t\t"813781"
    \t\t{
    \t\t\t"name"\t\t"not the game"
    \t\t}
    \t}
    }
    """

    @Test func readsAManifest() throws {
        let app = try #require(SteamLibrary.parse(updating))
        #expect(app.id == "813780" && app.name == "Age of Empires II: Definitive Edition" && app.targetBuild == "25500000")
        #expect(app.bytesLeft == 100_000_000 && app.updating)
        #expect(SteamLibrary.parse("nothing here") == nil)
    }

    @Test func onlyAnUpdateUnderWayCounts() {
        func app(_ flags: Int, left: UInt64 = 1000) -> SteamLibrary.App { .init(id: "1", name: "G", flags: flags, bytesToDownload: left, bytesDownloaded: 0, targetBuild: "") }
        #expect(app(1030).updating && app(1_048_580).updating)
        #expect(!app(4).updating, "installed, nothing to do")
        #expect(!app(6).updating, "needs an update, not started")
        #expect(!app(1540).updating, "paused")
        #expect(!app(1030, left: 0).updating, "finished")
        #expect(SteamLibrary.updating([app(4), app(1030, left: 5)])?.bytesLeft == 5)
    }

    @Test func otherLibrariesAndInstalledGames() {
        #expect(SteamLibrary.libraries("\"0\"\n{\n\t\"path\"\t\t\"/Volumes/Games/Steam\"\n\t\"label\"\t\t\"\"\n}") == ["/Volumes/Games/Steam"])
        let apps = [SteamLibrary.App(id: "730", name: "Counter-Strike 2", flags: 4, bytesToDownload: 0, bytesDownloaded: 0, targetBuild: ""),
                    SteamLibrary.App(id: "9", name: "Stardew Valley", flags: 4, bytesToDownload: 0, bytesDownloaded: 0, targetBuild: "")]
        #expect(SteamLibrary.installedGames(apps, table: .bundled).map(\.id) == ["cs2"])
    }

    @Test func warnsOnlyWhenItMatters() {
        #expect(SteamLibrary.meteredWarning(left: 34_000_000_000, metered: true, budgetLeft: 10_000_000_000))
        #expect(!SteamLibrary.meteredWarning(left: 1_000_000_000, metered: true, budgetLeft: 10_000_000_000), "fits")
        #expect(SteamLibrary.meteredWarning(left: 600_000_000, metered: true, budgetLeft: nil))
        #expect(!SteamLibrary.meteredWarning(left: 100_000_000, metered: true, budgetLeft: nil), "small")
        #expect(!SteamLibrary.meteredWarning(left: 34_000_000_000, metered: false, budgetLeft: nil), "not metered")
    }

    @Test func aGameLabelFitsTheMenuBar() {
        #expect(GameServerTable.bundled.shortLabel(for: "Counter-Strike 2") == "CS2")
        #expect(GameServerTable.bundled.shortLabel(for: "Age Of Empires II") == nil, "too long")
        #expect(GameServerTable.bundled.shortLabel(for: "Fortnite") == "FORTNITE")
        #expect(GameServerTable.bundled.shortLabel(for: nil) == nil)
    }
}
