import Foundation
import Network

public final class NetworkStatus: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    public init() {}
    public func start(onChange: @escaping @Sendable (Bool, Bool, String) -> Void) {
        monitor.pathUpdateHandler = { path in
            let kind = path.usesInterfaceType(.wifi) ? String(localized: "Wi-Fi") : path.usesInterfaceType(.wiredEthernet) ? String(localized: "Ethernet") : path.usesInterfaceType(.cellular) ? String(localized: "Cellular") : String(localized: "Network")
            onChange(path.status == .satisfied, path.isExpensive, kind)
        }
        monitor.start(queue: DispatchQueue(label: "co.seifi.kilobat.network"))
    }
    deinit { monitor.cancel() }
}
