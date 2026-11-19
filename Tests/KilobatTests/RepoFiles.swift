import Foundation
@testable import KilobatCore

/// The repository the tests run from. The public CLI repo (script/sync_cli_mirror.sh) has the core and its tests but not
/// the app, the site or Assets/, so a test that checks those is skipped there, and data files come from the bundle.
enum RepoFiles {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func has(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
    /// A data file from Assets/, or the copy the core carries as a resource in the public CLI repo.
    static func data(_ asset: String) throws -> Data {
        if has(asset) { return try Data(contentsOf: root.appendingPathComponent(asset)) }
        let name = (asset as NSString).lastPathComponent
        guard let url = GeoIP.resources.map({ $0.appendingPathComponent(name) }).first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: url)
    }
}
