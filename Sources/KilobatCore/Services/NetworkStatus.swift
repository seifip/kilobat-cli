import Foundation
import Network

public final class NetworkStatus: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    public func start(onChange: @escaping @Sendable (Bool, Bool, String) -> Void) {
        monitor.pathUpdateHandler = { path in
            let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : path.usesInterfaceType(.cellular) ? "Cellular" : "Network"
            onChange(path.status == .satisfied, path.isExpensive, kind)
        }
        monitor.start(queue: DispatchQueue(label: "co.seifi.kilobat.network"))
    }
    deinit { monitor.cancel() }
}
