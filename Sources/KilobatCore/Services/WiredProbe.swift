import Foundation
import IOKit
import SystemConfiguration

/// Reads every Ethernet port on this Mac: `ifconfig` for the negotiated link, System Configuration for its network
/// service, and the IORegistry for what the adapter is. Read-only: it never changes a service or an interface.
public enum WiredProbe {
    public static func read(now: Date = Date()) async -> WiredReport {
        let ifconfig = await CommandRunner.run("/sbin/ifconfig", ["-v", "-m", "-a"], timeout: 5)
        let readings = WiredLink.parseIfconfig(ifconfig.output)
        let interfaces = systemInterfaces(), services = systemServices()
        let registry = registryChains()
        var adapters: [WiredAdapter] = []
        for (bsd, chain) in registry.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) where bsd.hasPrefix("en") {
            guard WiredIdentity.skip(chain) == nil else { continue }
            // System Configuration knows Wi-Fi, bridges and Thunderbolt IP by type: only Ethernet is reported.
            if let type = interfaces[bsd]?.type, type != (kSCNetworkInterfaceTypeEthernet as String) { continue }
            let name = interfaces[bsd]?.name ?? bsd
            if ["iPhone", "iPad"].contains(where: name.contains) { continue }
            let service = services[bsd]
            adapters.append(WiredAdapter(interface: bsd, name: name, identity: WiredIdentity.read(chain), reading: readings[bsd],
                                         service: service?.name, serviceEnabled: service?.enabled))
        }
        return WiredReport(date: now, adapters: adapters, missingDrivers: missingDrivers())
    }

    // MARK: System Configuration

    private struct Interface { let name: String; let type: String? }
    private static func systemInterfaces() -> [String: Interface] {
        var result: [String: Interface] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            result[bsd] = Interface(name: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsd,
                                    type: SCNetworkInterfaceGetInterfaceType(interface) as String?)
        }
        return result
    }

    /// The current location's services, by the interface each sits on.
    private static func systemServices() -> [String: (name: String, enabled: Bool)] {
        guard let preferences = SCPreferencesCreate(nil, "Kilobat" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return [:] }
        var result: [String: (name: String, enabled: Bool)] = [:]
        for service in services {
            guard let interface = SCNetworkServiceGetInterface(service), let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let name = SCNetworkServiceGetName(service) as String? ?? bsd
            // A second service on the same port counts if either is on.
            let enabled = SCNetworkServiceGetEnabled(service) || result[bsd]?.enabled == true
            result[bsd] = (name, enabled)
        }
        return result
    }

    // MARK: IORegistry

    /// Each Ethernet interface's path up the service plane, interface first, as plain values.
    static func registryChains() -> [String: [RegistryNode]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEthernetInterface"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: [RegistryNode]] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var chain: [RegistryNode] = []
            var current = entry
            for _ in 0..<12 {
                chain.append(node(current))
                var parent: io_registry_entry_t = 0
                let found = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS && parent != 0
                if current != entry { IOObjectRelease(current) }
                guard found else { current = 0; break }
                current = parent
            }
            if current != 0 && current != entry { IOObjectRelease(current) }
            if let bsd = chain.first?.strings["BSD Name"] { result[bsd] = chain }
            IOObjectRelease(entry)
        }
        return result
    }

    private static let stringKeys = ["BSD Name", "IOUserClass", "CFBundleIdentifier", "IOUserServerName", "IOVendor", "IOModel",
                                     "USB Vendor Name", "USB Product Name", "kUSBVendorString", "kUSBProductString"]
    private static let numberKeys = ["idVendor", "idProduct", "USBSpeed", "UsbLinkSpeed", "Device Speed", "locationID"]

    private static func node(_ entry: io_registry_entry_t) -> RegistryNode {
        var className = [CChar](repeating: 0, count: 128), name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &className)
        IORegistryEntryGetName(entry, &name)
        var strings: [String: String] = [:], numbers: [String: Int] = [:]
        for key in stringKeys {
            if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { strings[key] = value }
        }
        for key in numberKeys {
            if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber { numbers[key] = value.intValue }
        }
        return RegistryNode(className: String(cString: className), name: String(cString: name), strings: strings, numbers: numbers)
    }

    /// USB devices Kilobat knows as Ethernet adapters with no Ethernet interface under them.
    static func missingDrivers() -> [WiredMissingDriver] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [WiredMissingDriver] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            let info = node(device)
            guard let vendor = info.numbers["idVendor"], let product = info.numbers["idProduct"],
                  let chip = WiredLink.chip(vendor: vendor, product: product), !hasEthernetInterface(below: device) else { continue }
            result.append(WiredMissingDriver(vendorID: vendor, productID: product, chip: chip.name,
                                             product: info.strings["USB Product Name"] ?? info.strings["kUSBProductString"], location: info.numbers["locationID"]))
        }
        return result
    }

    private static func hasEthernetInterface(below device: io_registry_entry_t) -> Bool {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return true }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOEthernetInterface") != 0 { return true }
        }
        return false
    }
}
