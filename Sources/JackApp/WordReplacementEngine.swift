import Foundation

enum WordReplacementEngine {
    /// Applies all word replacements to the given text using case-insensitive whole-word matching.
    static func apply(_ replacements: [WordReplacement], to text: String) -> String {
        guard !replacements.isEmpty else { return text }

        var result = text
        for replacement in replacements {
            let escaped = NSRegularExpression.escapedPattern(for: replacement.original)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.replacement)
            )
        }
        return result
    }
}
