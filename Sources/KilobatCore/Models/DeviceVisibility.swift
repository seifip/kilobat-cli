import Foundation

/// "Why can't I see my device?": what the Mac can observe about whether this Wi-Fi lets devices reach each other, from
/// the casting check's signals (Bonjour, the neighbour cache after a sweep, pings to a few neighbours, proxy ARP) and,
/// when the person is looking for one, whether that device answered. It says how sure it is, because none of these can
/// prove client isolation: devices sleep, ignore ping or don't announce themselves.
public struct DeviceVisibility: Equatable, Sendable {
    public enum Verdict: String, Sendable {
        /// Other devices answer: the network lets devices talk.
        case visible
        /// Devices answer when asked directly, but none announce themselves: discovery (mDNS/Bonjour) may be filtered.
        case discoveryFiltered
        /// Signs of client isolation: other addresses answer as the router (proxy ARP) and nothing else answers.
        case mayIsolate
        /// Nothing answered and nothing points either way.
        case unclear
        /// macOS's Local Network access is off for Kilobat.
        case noAccess
        case offline
    }
    public enum Confidence: String, Sendable { case likely, possible, unknown }
    /// One thing Kilobat checked, and what it saw: true answered, false didn't, nil couldn't check.
    public struct Signal: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case router, peers, discovery, proxyARP, device }
        public var id: Kind { kind }
        public let kind: Kind
        public let ok: Bool?
        public let text: String
    }
    public enum Fix: String, Sendable, CaseIterable { case sameDevice, hotspot, direct, venue, address, localNetwork, wake }

    public let verdict: Verdict
    public let confidence: Confidence
    public let signals: [Signal]
    public let fixes: [Fix]

    /// `target` is the device being looked for, if any: whether it answered on any port or ping (nil, not checked).
    public static func judge(_ check: LocalReachCheck?, routerAnswered: Bool?, target: (name: String, answered: Bool?)? = nil) -> DeviceVisibility {
        guard let check, check.connected else { return DeviceVisibility(verdict: .offline, confidence: .unknown, signals: [], fixes: []) }
        if check.access == .denied {
            return DeviceVisibility(verdict: .noAccess, confidence: .likely, signals: [], fixes: [.localNetwork])
        }
        let peers = check.peers
        let announced = peers.bonjourDevices > 0 || !check.targets.isEmpty
        var signals: [Signal] = []
        if let routerAnswered {
            signals.append(Signal(kind: .router, ok: routerAnswered, text: routerAnswered ? String(localized: "The router answers.", comment: "Why can't I see my device: a signal")
                                                                                              : String(localized: "The router didn’t answer a ping.", comment: "Why can't I see my device: a signal")))
        }
        if peers.pinged > 0 || peers.neighbours > 0 {
            signals.append(Signal(kind: .peers, ok: peers.answered > 0 ? true : peers.pinged > 0 ? false : nil,
                                  text: peers.answered > 0 ? String(localized: "\(peers.answered) of \(peers.pinged) other devices answered a ping.", comment: "Why can't I see my device: a signal; the arguments are numbers")
                                      : peers.pinged > 0 ? String(localized: "None of \(peers.pinged) other devices answered a ping.", comment: "Why can't I see my device: a signal; the argument is a number")
                                      : String(localized: "\(peers.neighbours) other devices are on this network.", comment: "Why can't I see my device: a signal; the argument is a number")))
        } else if peers.swept {
            signals.append(Signal(kind: .peers, ok: nil, text: String(localized: "No other device showed up on this network.", comment: "Why can't I see my device: a signal")))
        }
        signals.append(Signal(kind: .discovery, ok: announced,
                              text: announced ? String(localized: "Devices announce themselves (Bonjour).", comment: "Why can't I see my device: a signal")
                                              : String(localized: "No device announced itself (Bonjour).", comment: "Why can't I see my device: a signal")))
        if peers.proxyARP {
            signals.append(Signal(kind: .proxyARP, ok: false, text: String(localized: "\(peers.routerAliases) addresses answer with the router’s own hardware address (proxy ARP).", comment: "Why can't I see my device: a signal; the argument is a number")))
        }
        if let target, let answered = target.answered {
            signals.append(Signal(kind: .device, ok: answered, text: answered ? String(localized: "\(target.name) answers.", comment: "Why can't I see my device: a signal; the argument is a device")
                                                                              : String(localized: "\(target.name) didn’t answer.", comment: "Why can't I see my device: a signal; the argument is a device")))
        }

        let heard = peers.answered > 0 || announced
        if peers.proxyARP && !heard {
            return DeviceVisibility(verdict: .mayIsolate, confidence: .possible, signals: signals, fixes: [.hotspot, .direct, .venue])
        }
        if peers.answered > 0 && !announced && peers.answered >= 2 {
            return DeviceVisibility(verdict: .discoveryFiltered, confidence: .possible, signals: signals, fixes: [.address, .hotspot, .venue])
        }
        if heard {
            return DeviceVisibility(verdict: .visible, confidence: .likely, signals: signals, fixes: target?.answered == false ? [.wake, .sameDevice] : [])
        }
        return DeviceVisibility(verdict: .unclear, confidence: .unknown, signals: signals, fixes: [.wake, .sameDevice, .hotspot])
    }

    public var headline: String {
        switch verdict {
        case .visible: String(localized: "Devices here can reach each other", comment: "Why can't I see my device: verdict")
        case .discoveryFiltered: String(localized: "This Wi-Fi may hide devices from discovery", comment: "Why can't I see my device: verdict")
        case .mayIsolate: String(localized: "This Wi-Fi may keep devices apart", comment: "Why can't I see my device: verdict")
        case .unclear: String(localized: "Kilobat can’t tell whether this Wi-Fi keeps devices apart", comment: "Why can't I see my device: verdict")
        case .noAccess: String(localized: "Kilobat needs Local Network access to check", comment: "Why can't I see my device: verdict")
        case .offline: String(localized: "Not on a network", comment: "Why can't I see my device: verdict")
        }
    }

    public var detail: String {
        switch verdict {
        case .visible:
            String(localized: "Other devices answer, so the network isn’t keeping devices apart. If yours still doesn’t show, it may be asleep, on another Wi-Fi or band, or not answering.", comment: "Why can't I see my device: verdict detail")
        case .discoveryFiltered:
            String(localized: "Devices answer when asked directly, but none announce themselves. Some networks filter Bonjour (mDNS), so apps that search for a device find nothing even though its address works. It may also be that nothing here announces itself.", comment: "Why can't I see my device: verdict detail")
        case .mayIsolate:
            String(localized: "No other device answered, and other addresses answer with the router’s own hardware address. Hotel, office and guest Wi-Fi often do this to keep devices apart (client isolation), but ordinary routing can look the same, so it isn’t proof.", comment: "Why can't I see my device: verdict detail")
        case .unclear:
            String(localized: "No other device answered, but nothing points to the network blocking them either. Devices may be asleep, ignore pings or not announce themselves.", comment: "Why can't I see my device: verdict detail")
        case .noAccess:
            String(localized: "macOS stops Kilobat from looking for devices until Local Network access is on.", comment: "Why can't I see my device: verdict detail")
        case .offline:
            String(localized: "Join a network, then check again.", comment: "Local network check")
        }
    }

    public var confidenceTitle: String {
        switch confidence {
        case .likely: String(localized: "Likely", comment: "Why can't I see my device: how sure the verdict is")
        case .possible: String(localized: "Possible", comment: "Why can't I see my device: how sure the verdict is")
        case .unknown: String(localized: "Uncertain", comment: "Why can't I see my device: how sure the verdict is")
        }
    }

    public static func text(_ fix: Fix) -> String {
        switch fix {
        case .sameDevice: String(localized: "Check the device is on and joined to this Wi-Fi, on the same band if the router splits them.", comment: "Why can't I see my device: a fix")
        case .hotspot: String(localized: "Turn on your phone’s hotspot and join it with the Mac and the device: devices on a phone’s hotspot can see each other.", comment: "Why can't I see my device: a fix")
        case .direct: String(localized: "Connect to the device directly: many cameras, drones, robots and printers have their own Wi-Fi or a setup mode.", comment: "Why can't I see my device: a fix")
        case .venue: String(localized: "Ask the venue whether this Wi-Fi uses client or AP isolation, and whether there’s a network for devices.", comment: "Why can't I see my device: a fix")
        case .address: String(localized: "Open the device by its address instead of searching for it, from its app or a browser.", comment: "Why can't I see my device: a fix")
        case .localNetwork: String(localized: "Turn on Kilobat in System Settings › Privacy & Security › Local Network, then check again.", comment: "Local network check")
        case .wake: String(localized: "Wake the device, or restart it, and check again.", comment: "Why can't I see my device: a fix")
        }
    }
}
