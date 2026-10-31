import Foundation

public extension CallSamples {
    /// A stretch of a call when a Starlink dish was down or obstructed, in seconds from the call's start.
    struct Dish: Sendable, Equatable {
        public let at: Double
        public let seconds: Double
        /// obstructed, noSatellites, reboot or other.
        public let reason: String
        public init(at: Double, seconds: Double, reason: String) { self.at = at; self.seconds = seconds; self.reason = reason }

        /// From a status reading: its current outage, or a moment it saw an obstruction (status comes every two seconds).
        init?(status: StarlinkStatus, start: Date) {
            if let outage = status.outage {
                self.init(outage: outage, start: start)
            } else if status.currentlyObstructed == true {
                self.init(at: status.date.timeIntervalSince(start) - 2, seconds: 2, reason: "obstructed")
            } else { return nil }
        }
        /// From the dish's outage log.
        init?(outage: StarlinkOutage, start: Date) {
            let at = outage.start.timeIntervalSince(start)
            guard at + outage.seconds >= 0 else { return nil }
            self.init(at: at, seconds: max(1, outage.seconds), reason: Self.reason(outage.cause))
        }

        static func reason(_ cause: StarlinkOutage.Cause) -> String {
            switch cause {
            case .obstructed: "obstructed"
            case .noSatellites, .noSchedule, .noDownlink, .noPings: "noSatellites"
            case .booting, .skySearch: "reboot"
            default: "other"
            }
        }

        /// The dish stretch that overlaps a freeze the most, allowing two seconds for the ping to notice.
        static func overlapping(_ dish: [Dish], from start: Double, to end: Double) -> Dish? {
            func overlap(_ sample: Dish) -> Double { min(end + 1, sample.at + sample.seconds) - max(start - 2, sample.at) }
            return dish.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) }
        }

        /// Reads on from "3 freezes," like the other causes: "when trees or a roof blocked the Starlink dish".
        static func phrase(_ reason: String?) -> String {
            switch reason {
            case "obstructed": String(localized: "when something blocked the Starlink dish’s view of the sky", comment: "Call report: where a freeze came from")
            case "noSatellites": String(localized: "on Starlink’s side: no satellite in view", comment: "Call report: where a freeze came from")
            case "reboot": String(localized: "while the Starlink dish restarted", comment: "Call report: where a freeze came from")
            default: String(localized: "while the Starlink dish was offline", comment: "Call report: where a freeze came from")
            }
        }
        static func advice(_ reason: String?) -> String {
            switch reason {
            case "obstructed": String(localized: "Open Health › Starlink to see which way the sky is blocked, and move the dish clear of it.", comment: "Call report advice")
            case "noSatellites": String(localized: "That’s Starlink’s network, not your setup. If it keeps happening, the report for your provider includes the dish’s own log.", comment: "Call report advice")
            case "reboot": String(localized: "The dish restarts to install updates. Set its update window to the night in the Starlink app.", comment: "Call report advice")
            default: String(localized: "Health › Starlink shows what the dish reported, such as heat or power save.", comment: "Call report advice")
            }
        }
    }
}
