import Foundation

enum FloatingIndicatorPosition: String, CaseIterable, Identifiable {
    case centerLeft
    case centerTop
    case centerRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .centerLeft:
            return "Center Left"
        case .centerTop:
            return "Center Top"
        case .centerRight:
            return "Center Right"
        case .bottomLeft:
            return "Bottom Left"
        case .bottomCenter:
            return "Bottom Center"
        case .bottomRight:
            return "Bottom Right"
        }
    }
}
