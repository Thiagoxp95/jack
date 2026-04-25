import Foundation

enum AppConfig {
    #if DEBUG
    static let clerkPublishableKey = "pk_test_YW1wbGUtbWluay04MC5jbGVyay5hY2NvdW50cy5kZXYk"
    static let convexDeploymentUrl = "https://judicious-ibex-936.convex.cloud"
    static let convexSiteUrl = "https://judicious-ibex-936.convex.site"
    #else
    static let clerkPublishableKey = "pk_live_Y2xlcmsuamFja2x5LmFwcCQ"
    static let convexDeploymentUrl = "https://striped-walrus-412.convex.cloud"
    static let convexSiteUrl = "https://striped-walrus-412.convex.site"
    #endif
}
