import SwiftUI

enum EditorColors {
    static let background = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let card = Color(red: 0.173, green: 0.173, blue: 0.18)
    static let secondary = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let divider = Color.primary.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.05)
    static let subtleStroke = Color.primary.opacity(0.15)

    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.369, green: 0.361, blue: 0.902), Color(red: 0, green: 0.478, blue: 1)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Timeline-specific
    static let trackBackground = Color(red: 0.173, green: 0.173, blue: 0.18)
    static let playhead = Color.white
    static let cutRegion = Color.red.opacity(0.25)
    static let cutRegionBorder = Color.red.opacity(0.6)
    static let zoomBlock = LinearGradient(
        colors: [Color(red: 0.369, green: 0.361, blue: 0.902).opacity(0.35), Color(red: 0, green: 0.478, blue: 1).opacity(0.35)],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let disabledSegment = Color.gray.opacity(0.15)
    static let selectedSegmentBorder = LinearGradient(
        colors: [Color(red: 0.369, green: 0.361, blue: 0.902), Color(red: 0, green: 0.478, blue: 1)],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let bladeIndicator = Color.red
    static let micWaveform = Color(red: 0, green: 0.478, blue: 1)
    static let systemWaveform = Color.green
}
