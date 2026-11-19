import Foundation
import Darwin

/// MDM installs this non-secret marker as root. It restricts enrolment to one designated macOS account;
/// a hardware/asset identifier alone never recovers a credential. Other users must not allocate another seat.
public struct TeamsMachineOwnership: Codable, Sendable {
    public let installationId: String
    public let primaryUid: UInt32
    public static let path = "/Library/Application Support/Kilobat/Teams/installation.json"
    public enum Failure: Error { case missingOrUntrusted, secondaryUser }
    private static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0 && errno == EINVAL
    }
    public static func load(path: String = Self.path, uid: UInt32 = getuid()) throws -> Self {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw Failure.missingOrUntrusted }
        let parts = path.split(separator: "/").map(String.init)
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.missingOrUntrusted }
        defer { close(directory) }
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.missingOrUntrusted }
            var status = stat()
            guard fstat(next, &status) == 0, status.st_uid == 0, status.st_mode & 0o022 == 0, status.st_mode & S_IFMT == S_IFDIR, hasNoExtendedACL(next) else { close(next); throw Failure.missingOrUntrusted }
            close(directory); directory = next
        }
        guard let name = parts.last else { throw Failure.missingOrUntrusted }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.missingOrUntrusted }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == 0, status.st_mode & 0o022 == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size > 0, status.st_size <= 4096, hasNoExtendedACL(descriptor) else { throw Failure.missingOrUntrusted }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let bytes = try handle.read(upToCount: 4097), bytes.count <= 4096 else { throw Failure.missingOrUntrusted }
        let marker = try TeamsJSON.decoder().decode(Self.self, from: bytes)
        guard UUID(uuidString: marker.installationId) != nil, marker.primaryUid >= 501 else { throw Failure.missingOrUntrusted }
        guard marker.primaryUid == uid else { throw Failure.secondaryUser }
        return marker
    }
}
