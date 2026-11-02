import Foundation
import CryptoKit

/// Household Macs: Macs running Kilobat on the same home network, paired by the person, that tell each other what
/// they are moving right now so a frozen call can name the Mac behind it. Everything here is pure, so the wire
/// format, the authentication and the pairing can be tested without a network. RESEARCH-DECISIONS has the threat model.

/// What one Mac tells the Macs paired with it: its name, its rates, its three busiest apps by name and whether it is
/// on a call, with the time it was taken. No hosts it talks to, no history.
public struct HouseholdSummary: Codable, Sendable, Equatable {
    public static let version = 1
    public static let maxApps = 3
    public var v = HouseholdSummary.version
    public var id: String
    public var name: String
    /// Bytes a second, everything the Mac moves.
    public var down: Double
    public var up: Double
    /// The busiest apps by rate, busiest first, names only.
    public var apps: [String]
    public var call: Bool
    public var at: Date

    public init(id: String, name: String, down: Double, up: Double, apps: [String], call: Bool, at: Date) {
        self.id = id; self.name = name; self.down = down; self.up = up; self.apps = apps; self.call = call; self.at = at
    }

    /// The summary of this Mac from the live traffic: helpers grouped under their app, proxies and VPN tunnels left out
    /// (their traffic is other apps'), and an app only when it moves at least 2 KB a second.
    public static func make(id: String, name: String, download: Double, upload: Double, apps: [AppTraffic], onCall: Bool, now: Date = Date()) -> HouseholdSummary {
        let busiest = AppTrafficGroup.make(apps.filter { !$0.carrier }, grouped: true).map(\.summary)
            .filter { $0.rate >= 2_000 }.sorted { $0.rate > $1.rate }.prefix(maxApps).map { HouseholdNames.clean($0.name) }.filter { !$0.isEmpty }
        return HouseholdSummary(id: id, name: HouseholdNames.clean(name), down: max(0, download), up: max(0, upload), apps: Array(busiest), call: onCall, at: now)
    }

    /// Enough to freeze a call on a shared line, the same bar as another app on this Mac.
    public var busy: Bool { up >= CallAnalysis.uploadLoad || down >= CallAnalysis.downloadLoad }
    public var uploading: Bool { up / CallAnalysis.uploadLoad >= down / CallAnalysis.downloadLoad }
    /// Checks a summary that came over the wire before it is shown anywhere.
    var valid: Bool {
        v == Self.version && HouseholdBook.validID(id) && !name.isEmpty && name.count <= HouseholdNames.limit && down.isFinite && up.isFinite && down >= 0 && up >= 0
            && apps.count <= Self.maxApps && apps.allSatisfy { !$0.isEmpty && $0.count <= HouseholdNames.limit }
    }
}

/// A peer's latest summary as this Mac received it.
public struct HouseholdLive: Codable, Sendable, Equatable {
    /// Older than this, by this Mac's clock, and a summary says nothing about now.
    public static let maxAge: TimeInterval = 12
    /// A summary whose own time is further than this from this Mac's clock is ignored too: an old one, or a peer whose clock is wrong.
    public static let skew: TimeInterval = 30
    public var summary: HouseholdSummary
    public var received: Date
    /// The address the peer answered from, to find it among the devices on the network.
    public var address: String?
    public init(summary: HouseholdSummary, received: Date, address: String? = nil) { self.summary = summary; self.received = received; self.address = address }
    public func fresh(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(received)
        return age <= Self.maxAge && age >= -1 && abs(now.timeIntervalSince(summary.at)) <= Self.skew
    }
}

/// A Mac this one is paired with. The shared key lives in the Keychain, never in this record.
public struct HouseholdPeer: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The home network it was paired on, as this Mac knows it (`networkKey`); the pair works there only.
    public var network: String
    public var networkName: String
    public var paired: Date
    public init(id: String, name: String, network: String, networkName: String, paired: Date) {
        self.id = id; self.name = name; self.network = network; self.networkName = networkName; self.paired = paired
    }
}

/// household.json: this Mac's identity and name, whether it shares, and the Macs it is paired with. No keys.
public struct HouseholdBook: Codable, Sendable, Equatable {
    /// This Mac's random identity, 32 hex characters; peers know it by this, never by a hardware address.
    public var me: String
    /// The name the person gave this Mac; nil uses the computer's name.
    public var name: String?
    /// Off by default: this Mac answers paired Macs only once the person turns sharing on.
    public var sharing = false
    public var peers: [HouseholdPeer] = []
    public static let limit = 16

    public init(me: String = HouseholdBook.newID()) { self.me = me }
    public static func newID() -> String { householdRandom(16).map { String(format: "%02x", $0) }.joined() }
    public static func validID(_ id: String) -> Bool { id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    public func peer(_ id: String) -> HouseholdPeer? { peers.first { $0.id == id } }
    public func peers(on network: String) -> [HouseholdPeer] { peers.filter { $0.network == network } }
    /// Adds a newly paired Mac, replacing an earlier pairing with it; the oldest pairing goes past the limit.
    public mutating func add(_ peer: HouseholdPeer) {
        peers.removeAll { $0.id == peer.id }
        peers.append(peer)
        if peers.count > Self.limit { peers.removeFirst(peers.count - Self.limit) }
    }
    @discardableResult public mutating func remove(_ id: String) -> Bool {
        let count = peers.count; peers.removeAll { $0.id == id }; return peers.count != count
    }
    /// Keeps a peer's name in step with what it calls itself now.
    public mutating func rename(peer id: String, to name: String) {
        let clean = HouseholdNames.clean(name)
        guard !clean.isEmpty, let index = peers.firstIndex(where: { $0.id == id }), peers[index].name != clean else { return }
        peers[index].name = clean
    }
}

public enum HouseholdNames {
    public static let limit = 64
    /// One line of printable text, at most 64 characters.
    public static func clean(_ text: String) -> String {
        let printable = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        return String(String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces).prefix(limit))
    }
}

/// One message on the wire. Pairing and requests share the shape; each kind uses the fields it needs.
public struct HouseholdMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Pairing, in order: hello (initiator's key), commit (responder's key and a commitment to its nonce),
        /// nonce (initiator's), reveal (responder's), then a confirm from each side once its person compared the codes.
        case hello, commit, nonce, reveal, confirm, cancel
        /// A paired Mac asks for the summary; the answer is sealed for it alone.
        case request, response
        /// Said instead of an answer: not paired, sharing off, not this network, busy.
        case refused
    }
    public var kind: Kind
    public var v = 1
    /// The sender's identity.
    public var id: String? = nil
    /// The sender's name, while pairing.
    public var name: String? = nil
    /// An X25519 public key, while pairing.
    public var key: Data? = nil
    public var nonce: Data? = nil
    public var commit: Data? = nil
    /// The Mac a request is for.
    public var to: String? = nil
    /// When a request was made, in milliseconds since 1970.
    public var at: Int64? = nil
    public var mac: Data? = nil
    /// The sealed summary of a response.
    public var box: Data? = nil
    public var reason: String? = nil
    public init(kind: Kind, id: String? = nil, name: String? = nil, key: Data? = nil, nonce: Data? = nil, commit: Data? = nil, to: String? = nil,
                at: Int64? = nil, mac: Data? = nil, box: Data? = nil, reason: String? = nil) {
        self.kind = kind; self.id = id; self.name = name; self.key = key; self.nonce = nonce; self.commit = commit
        self.to = to; self.at = at; self.mac = mac; self.box = box; self.reason = reason
    }
}

/// Frames on a TCP stream: a 4-byte big-endian length, then the message as JSON.
public enum HouseholdWire {
    public static let service = "_kilobat._tcp"
    public static let maxFrame = 16 * 1024
    public struct Malformed: Error, Equatable { public let reason: String }

    public static func frame(_ message: HouseholdMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= maxFrame else { throw Malformed(reason: "too large") }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Takes one complete message off the front of `buffer`; nil until one has arrived. Throws on a frame that is too
    /// large or isn't a message, after which the connection is closed.
    public static func unframe(_ buffer: inout Data) throws -> HouseholdMessage? {
        guard buffer.count >= 4 else { return nil }
        let bytes = [UInt8](buffer.prefix(4))
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, length <= maxFrame else { throw Malformed(reason: "frame length \(length)") }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
        buffer = Data(buffer.dropFirst(4 + length))
        do { return try JSONDecoder().decode(HouseholdMessage.self, from: body) } catch { throw Malformed(reason: "not a message") }
    }

    static let summaryEncoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]; return encoder }()
    static let summaryDecoder: JSONDecoder = { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder }()
}

@usableFromInline func householdRandom(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return Data(bytes)
}

/// Requests carry an HMAC-SHA256 under the pair's key over who asks, whom, when and a fresh nonce; answers are sealed
/// with ChaCha20-Poly1305 and bound to that request's nonce, so neither can be replayed or read by anyone else on the network.
public enum HouseholdCrypto {
    /// A request this far from the answering Mac's clock is refused.
    public static let window: TimeInterval = 30

    static func subkey(_ key: SymmetricKey, _ label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data("kilobat-household".utf8), info: Data(label.utf8), outputByteCount: 32)
    }
    static func requestBytes(from: String, to: String, at: Int64, nonce: Data) -> Data {
        Data("kilobat-request-v1|\(from)|\(to)|\(at)|".utf8) + nonce
    }
    static func responseContext(from: String, to: String, nonce: Data) -> Data {
        Data("kilobat-response-v1|\(from)|\(to)|".utf8) + nonce
    }

    /// `from` asks `to` for its summary.
    public static func request(from: String, to: String, key: SymmetricKey, now: Date = Date(), nonce: Data = householdRandom(16)) -> HouseholdMessage {
        let at = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let mac = Data(HMAC<SHA256>.authenticationCode(for: requestBytes(from: from, to: to, at: at, nonce: nonce), using: subkey(key, "request")))
        return HouseholdMessage(kind: .request, id: from, nonce: nonce, to: to, at: at, mac: mac)
    }

    public enum Verdict: String, Equatable, Sendable { case ok, malformed, notPaired, stale, badMAC, replayed }

    /// Whether `me` should answer this request. A nonce is remembered only once the MAC checks out, so a stranger can't fill the memory.
    public static func check(_ message: HouseholdMessage, me: String, key: (String) -> SymmetricKey?, replay: inout HouseholdReplayGuard, now: Date = Date()) -> Verdict {
        guard message.kind == .request, message.v == 1, let from = message.id, HouseholdBook.validID(from), message.to == me,
              let at = message.at, let nonce = message.nonce, nonce.count == 16, let mac = message.mac, mac.count == 32 else { return .malformed }
        guard let key = key(from) else { return .notPaired }
        guard abs(now.timeIntervalSince1970 - Double(at) / 1000) <= window else { return .stale }
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: requestBytes(from: from, to: me, at: at, nonce: nonce), using: subkey(key, "request")) else { return .badMAC }
        guard replay.admit(nonce, now: now) else { return .replayed }
        return .ok
    }

    /// `me`'s answer to a request that passed `check`.
    public static func response(_ summary: HouseholdSummary, to request: HouseholdMessage, me: String, key: SymmetricKey) throws -> HouseholdMessage {
        guard let from = request.id, let nonce = request.nonce else { throw HouseholdWire.Malformed(reason: "no request") }
        let body = try HouseholdWire.summaryEncoder.encode(summary)
        let sealed = try ChaChaPoly.seal(body, using: subkey(key, "response"), authenticating: responseContext(from: me, to: from, nonce: nonce))
        return HouseholdMessage(kind: .response, id: me, box: sealed.combined)
    }

    /// The summary in an answer to `request`, which this Mac sent to `peer`. Throws when it was sealed for another
    /// request or with another key, or doesn't hold a valid summary from that peer.
    public static func open(_ response: HouseholdMessage, for request: HouseholdMessage, peer: String, key: SymmetricKey) throws -> HouseholdSummary {
        guard response.kind == .response, response.id == peer, let box = response.box, let me = request.id, let nonce = request.nonce else {
            throw HouseholdWire.Malformed(reason: response.kind == .refused ? (response.reason ?? "refused") : "not a response")
        }
        let body = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: box), using: subkey(key, "response"), authenticating: responseContext(from: peer, to: me, nonce: nonce))
        let summary = try HouseholdWire.summaryDecoder.decode(HouseholdSummary.self, from: body)
        guard summary.valid, summary.id == peer else { throw HouseholdWire.Malformed(reason: "bad summary") }
        return summary
    }
}

/// The nonces of requests answered in the last minute: a captured request sent again is refused.
public struct HouseholdReplayGuard: Sendable {
    private var seen: [Data: Date] = [:]
    public static let capacity = 4096
    public init() {}
    public mutating func admit(_ nonce: Data, now: Date = Date()) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) <= HouseholdCrypto.window * 2 }
        guard seen[nonce] == nil, seen.count < Self.capacity else { return false }
        seen[nonce] = now
        return true
    }
}

/// Pairing two Macs, as Bluetooth's numeric comparison does it: each side sends an ephemeral X25519 key, the responder
/// commits to its nonce before it sees the initiator's, and both show a six-digit code from both keys and both nonces.
/// The person checks the codes match and confirms on each Mac. Someone in between would need the two codes to agree,
/// a one-in-a-million chance per try they can't improve, since each side's nonce is fixed before the other's is known.
/// The shared secret becomes a 256-bit key for the pair, and each side proves it has the same key before either keeps it.
public struct HouseholdPairing: Sendable {
    public enum Role: String, Sendable { case initiator, responder }
    public enum State: Equatable, Sendable {
        case awaitingHello, awaitingCommit, awaitingNonce, awaitingReveal
        /// The code is shown; waiting for this Mac's person.
        case comparing
        /// This Mac's person confirmed; waiting for the other's.
        case confirmed
        case paired
        case failed(Failure)
    }
    public enum Failure: String, Sendable { case malformed, outOfOrder, badCommitment, badConfirmation, cancelled }

    public let role: Role
    public let me: String
    public let myName: String
    private let secret: Curve25519.KeyAgreement.PrivateKey
    private let myNonce: Data
    public private(set) var state: State
    public private(set) var peer: String?
    public private(set) var peerName: String?
    private var peerKey: Data?
    private var peerNonce: Data?
    private var peerCommit: Data?
    private var key: SymmetricKey?
    private var transcript: Data?
    private var peerConfirmed = false
    /// The six digits both Macs show, such as "482 913", once both nonces are known.
    public private(set) var code: String?

    init(role: Role, me: String, name: String, secret: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data = householdRandom(16)) {
        self.role = role; self.me = me; self.myName = HouseholdNames.clean(name); self.secret = secret; self.myNonce = nonce
        state = role == .initiator ? .awaitingCommit : .awaitingHello
    }
    /// Starts pairing with a Mac found on the network; send the hello.
    public static func initiator(me: String, name: String) -> (HouseholdPairing, HouseholdMessage) {
        let session = HouseholdPairing(role: .initiator, me: me, name: name)
        return (session, session.hello)
    }
    /// Answers a Mac that asked to pair with this one.
    public static func responder(me: String, name: String) -> HouseholdPairing { HouseholdPairing(role: .responder, me: me, name: name) }

    var hello: HouseholdMessage { HouseholdMessage(kind: .hello, id: me, name: myName, key: secret.publicKey.rawRepresentation) }
    private var myKey: Data { secret.publicKey.rawRepresentation }
    /// The key for the pair, once both people confirmed and both Macs proved they hold it.
    public var pairKey: SymmetricKey? { state == .paired ? key : nil }
    public var finished: Bool { if case .failed = state { return true }; return state == .paired }

    static func commitment(key: Data, peerKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("kilobat-commit-v1".utf8) + key + peerKey + nonce))
    }
    static func code(initiatorKey: Data, responderKey: Data, initiatorNonce: Data, responderNonce: Data) -> String {
        let digest = [UInt8](SHA256.hash(data: Data("kilobat-code-v1".utf8) + initiatorKey + responderKey + initiatorNonce + responderNonce))
        let value = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let digits = String(format: "%06u", value)
        return digits.prefix(3) + " " + digits.suffix(3)
    }

    /// Handles the other Mac's message and returns what to send back. A message out of turn or one that doesn't check
    /// out ends the pairing, and the other Mac is told.
    public mutating func receive(_ message: HouseholdMessage) -> [HouseholdMessage] {
        if message.kind == .cancel { if !finished { state = .failed(.cancelled) }; return [] }
        guard !finished else { return [] }
        switch (state, message.kind) {
        case (.awaitingHello, .hello):
            guard let id = message.id, HouseholdBook.validID(id), id != me, let key = message.key, Self.validKey(key) else { return fail(.malformed) }
            peer = id; peerName = HouseholdNames.clean(message.name ?? ""); peerKey = key
            state = .awaitingNonce
            return [HouseholdMessage(kind: .commit, id: me, name: myName, key: myKey, commit: Self.commitment(key: myKey, peerKey: key, nonce: myNonce))]
        case (.awaitingCommit, .commit):
            guard let id = message.id, HouseholdBook.validID(id), id != me, let key = message.key, Self.validKey(key), key != myKey,
                  let commit = message.commit, commit.count == 32 else { return fail(.malformed) }
            peer = id; peerName = HouseholdNames.clean(message.name ?? ""); peerKey = key; peerCommit = commit
            state = .awaitingReveal
            return [HouseholdMessage(kind: .nonce, nonce: myNonce)]
        case (.awaitingNonce, .nonce):
            guard let nonce = message.nonce, nonce.count == 16 else { return fail(.malformed) }
            peerNonce = nonce
            guard derive() else { return fail(.malformed) }
            state = .comparing
            return [HouseholdMessage(kind: .reveal, nonce: myNonce)]
        case (.awaitingReveal, .reveal):
            guard let nonce = message.nonce, nonce.count == 16, let peerKey, let peerCommit else { return fail(.malformed) }
            guard Self.commitment(key: peerKey, peerKey: myKey, nonce: nonce) == peerCommit else { return fail(.badCommitment) }
            peerNonce = nonce
            guard derive() else { return fail(.malformed) }
            state = .comparing
            return []
        case (.comparing, .confirm), (.confirmed, .confirm):
            guard let mac = message.mac, let key, let transcript,
                  HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Self.confirmBytes(role: role == .initiator ? .responder : .initiator, transcript: transcript), using: key)
            else { return fail(.badConfirmation) }
            peerConfirmed = true
            if state == .confirmed { state = .paired }
            return []
        default:
            return fail(.outOfOrder)
        }
    }

    /// This Mac's person saw the same code on both Macs.
    public mutating func confirm() -> [HouseholdMessage] {
        guard state == .comparing, let key, let transcript else { return [] }
        state = peerConfirmed ? .paired : .confirmed
        return [HouseholdMessage(kind: .confirm, mac: Data(HMAC<SHA256>.authenticationCode(for: Self.confirmBytes(role: role, transcript: transcript), using: key)))]
    }

    public mutating func cancel() -> [HouseholdMessage] {
        guard !finished else { return [] }
        state = .failed(.cancelled)
        return [HouseholdMessage(kind: .cancel, reason: "cancelled")]
    }

    private mutating func fail(_ failure: Failure) -> [HouseholdMessage] {
        state = .failed(failure)
        return [HouseholdMessage(kind: .cancel, reason: failure.rawValue)]
    }

    static func validKey(_ data: Data) -> Bool { data.count == 32 && (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)) != nil }
    static func confirmBytes(role: Role, transcript: Data) -> Data { Data("kilobat-confirm-v1|\(role.rawValue)|".utf8) + transcript }

    /// The code, the pair's key and the transcript both confirmations cover.
    private mutating func derive() -> Bool {
        guard let peer, let peerKey, let peerNonce, let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey),
              let shared = try? secret.sharedSecretFromKeyAgreement(with: publicKey) else { return false }
        let initiator = role == .initiator
        let (idA, idB) = initiator ? (me, peer) : (peer, me)
        let (keyA, keyB) = initiator ? (myKey, peerKey) : (peerKey, myKey)
        let (nonceA, nonceB) = initiator ? (myNonce, peerNonce) : (peerNonce, myNonce)
        code = Self.code(initiatorKey: keyA, responderKey: keyB, initiatorNonce: nonceA, responderNonce: nonceB)
        key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonceA + nonceB, sharedInfo: Data("kilobat-household-v1|\(idA)|\(idB)".utf8), outputByteCount: 32)
        transcript = Data(SHA256.hash(data: keyA + keyB + nonceA + nonceB + Data("|\(idA)|\(idB)".utf8)))
        return true
    }
}

/// `kilobat household`: paired Macs and what each is doing now. Pairing happens in the app, where both people can see the code.
public enum HouseholdCommand: Equatable, Sendable {
    case list(json: Bool)
    public static let usage = "Use household [--json]. Pairing, sharing and unpairing are in the app: Kilobat › Settings › Household Macs."

    /// `args` starts with "household".
    public static func parse(_ args: [String]) throws -> HouseholdCommand {
        let rest = Array(args.dropFirst())
        if let word = rest.first(where: { ["pair", "unpair", "share", "sharing", "name", "rename"].contains($0.lowercased()) }) {
            throw DiagnosticError("Kilobat pairs Macs only in the app, where both Macs show the code to compare: open Kilobat › Settings › Household Macs (\(word) isn't a CLI command).")
        }
        guard rest.allSatisfy({ $0 == "--json" }) else { throw DiagnosticError(usage) }
        return .list(json: rest.contains("--json"))
    }
}

/// What `kilobat household --json` and MCP `get_household` return.
public struct HouseholdReport: Codable, Sendable, Equatable {
    public struct Peer: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var network: String
        public var pairedAt: Date
        /// Paired on the network this Mac is on now; only such peers are asked.
        public var onThisNetwork: Bool
        /// Whether it answered the last time it was asked; nil when it wasn't asked.
        public var reachable: Bool?
        /// It answered that it doesn't know this Mac any more, or doesn't share on this network.
        public var refused: String?
        /// Its fresh summary; nil when there is none, or without Kilobat Pro in the app.
        public var live: HouseholdSummary?
        public var ageSeconds: Double?
        public var busy: Bool?
        public init(id: String, name: String, network: String, pairedAt: Date, onThisNetwork: Bool, reachable: Bool? = nil, refused: String? = nil,
                    live: HouseholdSummary? = nil, ageSeconds: Double? = nil, busy: Bool? = nil) {
            self.id = id; self.name = name; self.network = network; self.pairedAt = pairedAt; self.onThisNetwork = onThisNetwork
            self.reachable = reachable; self.refused = refused; self.live = live; self.ageSeconds = ageSeconds; self.busy = busy
        }
    }
    public var name: String
    public var sharing: Bool
    /// Whether this Mac answers its paired Macs right now: sharing on, on a network marked home.
    public var answering: Bool?
    public var network: String?
    public var home: Bool?
    public var appRunning: Bool
    /// Whether the app has Kilobat Pro, which reading other Macs' usage needs; nil when the app isn't running.
    public var pro: Bool?
    /// allowed, denied or unknown: macOS's Local Network permission for the app.
    public var localNetwork: String?
    public var peers: [Peer]
    public init(name: String, sharing: Bool, answering: Bool? = nil, network: String? = nil, home: Bool? = nil, appRunning: Bool, pro: Bool? = nil,
                localNetwork: String? = nil, peers: [Peer]) {
        self.name = name; self.sharing = sharing; self.answering = answering; self.network = network; self.home = home; self.appRunning = appRunning
        self.pro = pro; self.localNetwork = localNetwork; self.peers = peers
    }
}
