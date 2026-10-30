import Foundation
import IOKit.ps

/// Tells when the Mac switches between the power adapter and its battery, from IOKit's own power-source
/// notification. It fires on the switch only, not on every change in charge, and nothing polls.
@MainActor public final class PowerSourceWatcher {
    nonisolated(unsafe) private var source: CFRunLoopSource?
    private let changed: @MainActor () -> Void

    public init?(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let watcher = Unmanaged<PowerSourceWatcher>.fromOpaque(context).takeUnretainedValue()
            // Scheduled on the main run loop, so this runs on the main thread.
            MainActor.assumeIsolated { watcher.changed() }
        }, context)?.takeRetainedValue() else { return nil }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    deinit { if let source { CFRunLoopSourceInvalidate(source) } }
}
