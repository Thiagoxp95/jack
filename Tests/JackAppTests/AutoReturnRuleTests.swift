import XCTest
@testable import JackApp

final class AutoReturnRuleTests: XCTestCase {
    private let slack = AutoReturnApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    func testPressesReturnForListedApp() {
        XCTAssertTrue(AutoReturnRule.shouldPressReturn(
            enabled: true,
            didPaste: true,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            apps: [slack]
        ))
    }

    func testUnlistedAppIsLeftAlone() {
        XCTAssertFalse(AutoReturnRule.shouldPressReturn(
            enabled: true,
            didPaste: true,
            frontmostBundleID: "com.apple.dt.Xcode",
            apps: [slack]
        ))
    }

    func testDisabledNeverFires() {
        XCTAssertFalse(AutoReturnRule.shouldPressReturn(
            enabled: false,
            didPaste: true,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            apps: [slack]
        ))
    }

    /// A suppressed paste (Silky frontmost, or no Accessibility) left the text
    /// on the clipboard and nowhere else — a Return would submit whatever the
    /// field already held.
    func testNoReturnWhenPasteDidNotHappen() {
        XCTAssertFalse(AutoReturnRule.shouldPressReturn(
            enabled: true,
            didPaste: false,
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            apps: [slack]
        ))
    }

    func testUnknownFrontmostAppDoesNotMatch() {
        XCTAssertFalse(AutoReturnRule.shouldPressReturn(
            enabled: true,
            didPaste: true,
            frontmostBundleID: nil,
            apps: [slack]
        ))
    }

    func testBundleIDMatchingIsCaseInsensitive() {
        XCTAssertTrue(AutoReturnRule.shouldPressReturn(
            enabled: true,
            didPaste: true,
            frontmostBundleID: "com.TinySpeck.SlackMacGap",
            apps: [slack]
        ))
    }
}
