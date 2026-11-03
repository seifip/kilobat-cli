import Foundation

/// Categories come from the curated catalog, never hostname guesses or a risk score.
public enum ExplainerHostSymbol {
    public static func symbol(_ category: String?) -> String {
        switch category {
        case "ai": "sparkles"
        case "developer", "development": "chevron.left.forwardslash.chevron.right"
        case "authentication", "security": "key"
        case "finance": "creditcard"
        case "network": "network"
        case "sync": "arrow.triangle.2.circlepath"
        case "updates": "arrow.down.circle"
        case "telemetry": "chart.bar"
        case "apps": "app"
        case "services": "server.rack"
        default: "globe"
        }
    }
}
