import Foundation
import AppKit
import Darwin

public struct ProcessSelection: Identifiable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let started: String
}
public enum ProcessControl {
    public static func inspect(pid: Int32) async throws -> ProcessSelection {
        guard pid > 1, pid != getpid() else { throw DiagnosticError(String(localized: "This process cannot be stopped from Kilobat.")) }
        let result = await CommandRunner.run("/bin/ps", ["-p", String(pid), "-o", "uid=", "-o", "lstart=", "-o", "comm="], timeout: 3)
        let fields = result.output.split(whereSeparator: \.isWhitespace)
        guard result.status == 0, fields.count >= 7, UInt32(fields[0]) == getuid() else { throw DiagnosticError(String(localized: "Process has exited or belongs to another user.")) }
        return ProcessSelection(pid: pid, name: fields.dropFirst(6).joined(separator: " "), started: fields[1...5].joined(separator: " "))
    }
    @MainActor public static func terminate(_ selected: ProcessSelection, force: Bool) async throws {
        let current = try await inspect(pid: selected.pid)
        guard current.started == selected.started, current.name == selected.name else { throw DiagnosticError(String(localized: "Process identity changed. Refresh before trying again.")) }
        if let app = NSRunningApplication(processIdentifier: selected.pid) {
            guard force ? app.forceTerminate() : app.terminate() else { throw DiagnosticError(String(localized: "The application declined to quit.")) }
        } else {
            guard kill(selected.pid, force ? SIGKILL : SIGTERM) == 0 else { throw DiagnosticError(String(cString: strerror(errno))) }
        }
    }
}
