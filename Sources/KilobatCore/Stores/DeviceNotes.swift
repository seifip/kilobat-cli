import Foundation
import Observation
import Security

/// A device the person keeps notes on: its own Wi-Fi, where to reach it, and what it is. The Wi-Fi password lives in
/// the Keychain, never in the notes.
public struct DeviceNote: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: SetupDeviceKind
    /// The device's own Wi-Fi name.
    public var ssid: String?
    public var address: String?
    /// Its web page, such as http://192.168.12.1.
    public var webURL: String?
    public var notes: String?
    public var created: Date
    public init(id: UUID = UUID(), name: String, kind: SetupDeviceKind, ssid: String? = nil, address: String? = nil, webURL: String? = nil, notes: String? = nil, created: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.ssid = ssid; self.address = address; self.webURL = webURL; self.notes = notes; self.created = created
    }

    /// Trimmed fields, empty ones gone, and a web address with a scheme. Nil when it has no name.
    public func cleaned() -> DeviceNote? {
        func tidy(_ text: String?) -> String? { text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        guard let name = tidy(name) else { return nil }
        var note = self
        note.name = String(name.prefix(60)); note.ssid = tidy(ssid).map { String($0.prefix(32)) }; note.address = tidy(address); note.notes = tidy(notes)
        note.webURL = tidy(webURL).map { $0.contains("://") ? $0 : "http://" + $0 }
        return note
    }

    /// A web address to open: the one saved, or the device's address over http.
    public var openURL: URL? {
        if let webURL, let url = URL(string: webURL), ["http", "https"].contains(url.scheme?.lowercased()) { return url }
        return address.flatMap { PortScan.ipv4($0) != nil ? URL(string: "http://\($0)") : nil }
    }
}

/// The saved devices, in UserDefaults (`deviceNotes`) as JSON; their Wi-Fi passwords in the Keychain.
@MainActor @Observable public final class DeviceNotesStore {
    nonisolated public static let key = "deviceNotes"
    public private(set) var notes: [DeviceNote] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let keychain: DevicePasswords

    public init(defaults: UserDefaults = .standard, keychain: DevicePasswords = .live) {
        self.defaults = defaults; self.keychain = keychain
        notes = Self.load(defaults)
    }

    nonisolated public static func load(_ defaults: UserDefaults = .standard) -> [DeviceNote] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([DeviceNote].self, from: $0) } ?? []
    }

    /// The saved devices by Wi-Fi name, for telling a device's own network from an outage.
    nonisolated public static func networks(_ defaults: UserDefaults = .standard) -> [String: (kind: SetupDeviceKind, name: String)] {
        var out: [String: (kind: SetupDeviceKind, name: String)] = [:]
        for note in load(defaults) { if let ssid = note.ssid { out[ssid] = (note.kind, note.name) } }
        return out
    }

    public private(set) var keychainError: String?

    private func check(_ status: OSStatus) -> Bool {
        keychainError = status == errSecSuccess ? nil : NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
        return status == errSecSuccess
    }

    public func note(ssid: String?) -> DeviceNote? { ssid.flatMap { ssid in notes.first { $0.ssid == ssid } } }

    /// Saves `note` (new or edited). `password`: nil leaves the saved one as it is, empty removes it.
    @discardableResult public func save(_ note: DeviceNote, password: String?) -> Bool {
        guard let clean = note.cleaned() else { return false }
        if let password, !check(password.isEmpty ? keychain.remove(clean.id) : keychain.set(password, clean.id)) { return false }
        if let index = notes.firstIndex(where: { $0.id == clean.id }) { notes[index] = clean } else { notes.append(clean) }
        notes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        return true
    }

    @discardableResult public func delete(_ id: UUID) -> Bool {
        guard check(keychain.remove(id)) else { return false }
        notes.removeAll { $0.id == id }
        persist(); return true
    }

    public func password(_ id: UUID) -> String? { keychain.get(id) }
    public func hasPassword(_ id: UUID) -> Bool { keychain.get(id) != nil }

    private func persist() {
        if notes.isEmpty { defaults.removeObject(forKey: Self.key) }
        else if let data = try? JSONEncoder().encode(notes) { defaults.set(data, forKey: Self.key) }
    }
}

/// A saved device's Wi-Fi password, as a generic Keychain item (service `co.seifi.kilobat.device-wifi`, account the
/// note's ID), readable only on this Mac and only while it's unlocked.
public struct DevicePasswords: Sendable {
    public let get: @Sendable (UUID) -> String?
    public let set: @Sendable (String, UUID) -> OSStatus
    public let remove: @Sendable (UUID) -> OSStatus
    public init(get: @escaping @Sendable (UUID) -> String?, set: @escaping @Sendable (String, UUID) -> OSStatus, remove: @escaping @Sendable (UUID) -> OSStatus) {
        self.get = get; self.set = set; self.remove = remove
    }

    static let service = "co.seifi.kilobat.device-wifi"
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    public static let live = DevicePasswords(
        get: { id in
            var query = DevicePasswords.query(id)
            query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        },
        set: { password, id in
            let data = Data(password.utf8)
            let status = SecItemUpdate(DevicePasswords.query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = DevicePasswords.query(id)
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                item[kSecAttrLabel as String] = "Kilobat device Wi-Fi"
                return SecItemAdd(item as CFDictionary, nil)
            }
            return status
        },
        remove: { id in
            let status = SecItemDelete(DevicePasswords.query(id) as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        })

    /// In memory, for tests and screenshots.
    public static func memory() -> DevicePasswords {
        final class Box: @unchecked Sendable { var values: [UUID: String] = [:]; let lock = NSLock() }
        let box = Box()
        return DevicePasswords(get: { id in box.lock.withLock { box.values[id] } },
                               set: { password, id in box.lock.withLock { box.values[id] = password; return errSecSuccess } },
                               remove: { id in box.lock.withLock { box.values.removeValue(forKey: id); return errSecSuccess } })
    }
}
