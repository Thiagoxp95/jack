import Foundation

enum AppConfig {
    #if DEBUG
    static let clerkPublishableKey = "pk_test_YW1wbGUtbWluay04MC5jbGVyay5hY2NvdW50cy5kZXYk"
    static let convexDeploymentUrl = "https://cheery-gull-259.convex.cloud"
    static let convexSiteUrl = "https://cheery-gull-259.convex.site"
    #else
    static let clerkPublishableKey = "pk_live_Y2xlcmsuYWN0aW9uZnkuY29tJA"
    static let convexDeploymentUrl = "https://judicious-pony-481.convex.cloud"
    static let convexSiteUrl = "https://judicious-pony-481.convex.site"
    #endif
}
