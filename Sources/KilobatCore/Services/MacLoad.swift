import Darwin
import Foundation
import IOKit

/// How hard the Mac itself is working: a call can freeze on a clean line when the CPU is maxed out, memory runs out,
/// the Mac slows itself down because it's hot, or the GPU is saturated. Read without any permission.
public struct MacLoad: Codable, Sendable, Equatable {
    /// All cores together, 0–100.
    public var cpu: Double
    /// The process using the most CPU, read only when the CPU is busy.
    public var top: String?
    /// macOS memory pressure: 1 normal, 2 warning, 4 critical.
    public var memory: Int
    /// `ProcessInfo.ThermalState`: 0 nominal … 3 critical.
    public var thermal: Int
    /// GPU utilization, 0–100, where the GPU reports it.
    public var gpu: Double?
    public init(cpu: Double, top: String? = nil, memory: Int = 1, thermal: Int = 0, gpu: Double? = nil) {
        self.cpu = cpu; self.top = top; self.memory = memory; self.thermal = thermal; self.gpu = gpu
    }

    /// Busy enough to freeze a call's video or audio.
    public var cpuMaxed: Bool { cpu >= 90 }
    public var memoryOut: Bool { memory >= 4 }
    public var throttled: Bool { thermal >= 2 }
    public var gpuMaxed: Bool { (gpu ?? 0) >= 90 }

    /// CPU ticks since boot, to measure the share busy between two samples.
    public struct Ticks: Sendable { let busy: UInt64, total: UInt64 }

    public static func ticks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        guard status == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return Ticks(busy: user + system + nice, total: user + system + idle + nice)
    }

    /// A sample since `previous`; the hungriest process is looked up only when the CPU is busy.
    public static func sample(since previous: Ticks) async -> (load: MacLoad, ticks: Ticks)? {
        guard let now = ticks(), now.total > previous.total else { return nil }
        let cpu = Double(now.busy - previous.busy) / Double(now.total - previous.total) * 100
        var level: Int32 = 1, size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        var load = MacLoad(cpu: cpu, memory: Int(level), thermal: ProcessInfo.processInfo.thermalState.rawValue, gpu: gpuUtilization())
        if load.cpuMaxed { load.top = topProcess(await CommandRunner.run("/bin/ps", ["-Aceo", "pcpu=,comm=", "-r"], timeout: 3).output) }
        return (load, now)
    }

    /// The first process in `ps -Aceo pcpu=,comm= -r`, skipping ps itself.
    public static func topProcess(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            if name != "ps", !name.isEmpty { return name }
        }
        return nil
    }

    /// The busiest GPU's "Device Utilization %" from its performance statistics in the I/O Registry.
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }
}
