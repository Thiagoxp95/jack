import AppKit
import CoreText
import Foundation

// MARK: - SubtitleRenderer

enum SubtitleRenderer {

    /// Renders a subtitle line into a CGImage with per-word karaoke coloring.
    /// Words with startTime <= currentTime are rendered in activeColor, others in inactiveColor.
    static func renderLine(
        _ line: SubtitleLine,
        currentTime: TimeInterval,
        canvasSize: CGSize,
        config: SubtitleConfiguration
    ) -> CGImage? {
        let words = line.words
        guard !words.isEmpty else { return nil }

        // Build attributed string with per-word coloring
        let attributed = NSMutableAttributedString()
        let font = NSFont(name: config.fontFamily, size: config.fontSize)
            ?? NSFont.systemFont(ofSize: config.fontSize, weight: .semibold)

        for (index, word) in words.enumerated() {
            let isActive = currentTime >= word.startTime
            let color = isActive
                ? NSColor(hex: config.activeColor) ?? .white
                : NSColor(hex: config.inactiveColor) ?? .gray

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]

            if index > 0 {
                attributed.append(NSAttributedString(string: " ", attributes: attrs))
            }
            attributed.append(NSAttributedString(string: word.text, attributes: attrs))
        }

        // Measure text size
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = canvasSize.width * 0.85
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, attributed.length),
            nil,
            CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            nil
        )

        let padding: CGFloat = config.backgroundEnabled ? 12 : 0
        let imgWidth = Int(ceil(textSize.width + padding * 2))
        let imgHeight = Int(ceil(textSize.height + padding * 2))
        guard imgWidth > 0, imgHeight > 0 else { return nil }

        // Create bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: imgWidth,
            height: imgHeight,
            bitsPerComponent: 8,
            bytesPerRow: imgWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // Draw background box
        if config.backgroundEnabled {
            let bgColor = NSColor(hex: config.backgroundColor) ?? NSColor.black.withAlphaComponent(0.5)
            ctx.setFillColor(bgColor.cgColor)
            let bgRect = CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight)
            let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.addPath(bgPath)
            ctx.fillPath()
        }

        // Draw text (Core Text draws from bottom-left origin)
        let textRect = CGRect(x: padding, y: padding, width: textSize.width, height: textSize.height)
        let path = CGMutablePath()
        path.addRect(textRect)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attributed.length), path, nil)
        CTFrameDraw(frame, ctx)

        return ctx.makeImage()
    }

    /// Returns the Y offset (from top) for subtitle placement.
    static func verticalOffset(position: SubtitlePosition, textHeight: CGFloat, canvasHeight: CGFloat) -> CGFloat {
        let margin: CGFloat = 40
        switch position {
        case .top:
            return margin
        case .middle:
            return (canvasHeight - textHeight) / 2
        case .bottom:
            return canvasHeight - textHeight - margin
        }
    }
}

// MARK: - NSColor hex initializer

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        if length == 8 {
            self.init(
                red: CGFloat((rgb >> 24) & 0xFF) / 255,
                green: CGFloat((rgb >> 16) & 0xFF) / 255,
                blue: CGFloat((rgb >> 8) & 0xFF) / 255,
                alpha: CGFloat(rgb & 0xFF) / 255
            )
        } else if length == 6 {
            self.init(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1.0
            )
        } else {
            return nil
        }
    }
}
