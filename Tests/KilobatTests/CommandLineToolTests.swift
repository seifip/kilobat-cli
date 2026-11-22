import Foundation
import Testing
@testable import KilobatCore

struct CommandLineToolTests {
    @Test func tellsTheAppsCopyFromHomebrewAndOthers() {
        #expect(CommandLineTool.source(resolved: "/Applications/Kilobat.app/Contents/Helpers/kilobat") == .app)
        #expect(CommandLineTool.source(resolved: "/opt/homebrew/Cellar/kilobat/0.20.0/bin/kilobat") == .homebrew)
        #expect(CommandLineTool.source(resolved: "/usr/local/bin/kilobat") == .other)
    }

    @Test func readsAndComparesVersions() {
        #expect(CommandLineTool.parseVersion("Kilobat 0.48.0\n") == "0.48.0")
        #expect(CommandLineTool.parseVersion("garbage") == nil)
        #expect(CommandLineTool.older("0.20.0", than: "0.48.0"))
        #expect(CommandLineTool.older("0.9.0", than: "0.10.0"))
        #expect(!CommandLineTool.older("0.48.0", than: "0.48.0"))
        #expect(!CommandLineTool.older("1.0", than: "0.48.0"))
        #expect(CommandLineTool.older(nil, than: "0.48.0"))
        #expect(!CommandLineTool.older("0.48.0", than: nil))
    }

    @Test func linksKilobatAndKbToTheAppsCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("kilobat").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: old))
        // A dangling kb link from an app copy that moved is replaced too.
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("kb").path, withDestinationPath: "/nowhere/Kilobat.app/Contents/Helpers/kilobat")
        let helper = "/Applications/Kilobat.app/Contents/Helpers/kilobat"
        let used = try await CommandLineTool.link(to: helper, replacing: CommandLineTool(path: old, source: .other, version: "0.20.0"))
        #expect(used == folder.path)
        for name in ["kilobat", "kb"] {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent(name).path) == helper)
        }
    }

    @Test func quotesPathsForTheAdministratorPrompt() {
        #expect(CommandLineTool.shellQuoted("/a b/it's") == "'/a b/it'\\''s'")
        #expect(CommandLineTool.appleScriptEscaped("say \"hi\" \\") == "say \\\"hi\\\" \\\\")
    }
}
