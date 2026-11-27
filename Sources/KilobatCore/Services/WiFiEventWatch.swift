import CoreWLAN
import Foundation

/// Tells when Wi-Fi is switched on or off, or joins or leaves a network, the moment CoreWLAN reports it, so the
/// connection icon changes with macOS's own rather than at the next reading of the radio.
public final class WiFiEventWatch: NSObject, CWEventDelegate, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private(set) var monitoring = false
    private var started = false
    public init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

    public func start() {
        guard !started else { return }
        started = true
        let client = CWWiFiClient.shared()
        client.delegate = self
        monitoring = true
        for event in [CWEventType.powerDidChange, .ssidDidChange, .linkDidChange] {
            do { try client.startMonitoringEvent(with: event) } catch { monitoring = false }
        }
    }

    public func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { onChange() }
    public func ssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange() }
    public func linkDidChangeForWiFiInterface(withName interfaceName: String) { onChange() }
}
