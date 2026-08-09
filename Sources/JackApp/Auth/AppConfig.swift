import Foundation

/// Backend configuration for sync/cloud features (Convex).
///
/// Forks should point these at their own Convex deployment. Each value can be
/// overridden at runtime, in order of precedence:
///
/// 1. Environment variables: `JACK_CONVEX_URL`, `JACK_CONVEX_SITE_URL`.
/// 2. Info.plist keys: `JackConvexURL`, `JackConvexSiteURL`.
/// 3. The hardcoded defaults below (the upstream Jack deployment).
enum AppConfig {
    #if DEBUG
    private static let defaultConvexDeploymentUrl = "https://judicious-ibex-936.convex.cloud"
    private static let defaultConvexSiteUrl = "https://judicious-ibex-936.convex.site"
    #else
    private static let defaultConvexDeploymentUrl = "https://striped-walrus-412.convex.cloud"
    private static let defaultConvexSiteUrl = "https://striped-walrus-412.convex.site"
    #endif

    static let convexDeploymentUrl = resolve(
        env: "JACK_CONVEX_URL",
        plist: "JackConvexURL",
        default: defaultConvexDeploymentUrl
    )

    static let convexSiteUrl = resolve(
        env: "JACK_CONVEX_SITE_URL",
        plist: "JackConvexSiteURL",
        default: defaultConvexSiteUrl
    )

    private static func resolve(env envKey: String, plist plistKey: String, default defaultValue: String) -> String {
        if let value = ProcessInfo.processInfo.environment[envKey],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return defaultValue
    }
}
