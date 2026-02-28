import Foundation

enum SubtitleChunker {
    static func chunk(
        wordTimings: [WordTiming],
        maxWordsPerLine: Int = 10,
        pauseThreshold: TimeInterval = 0.3
    ) -> [SubtitleLine] {
        let filtered = wordTimings.filter { !$0.word.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !filtered.isEmpty else { return [] }

        var lines: [SubtitleLine] = []
        var currentWords: [SubtitleWord] = []

        for (index, timing) in filtered.enumerated() {
            let word = SubtitleWord(
                text: timing.word,
                startTime: timing.startTime,
                endTime: timing.endTime,
                confidence: timing.confidence
            )

            if !currentWords.isEmpty {
                let gap = timing.startTime - filtered[index - 1].endTime
                let atMaxWords = currentWords.count >= maxWordsPerLine
                let atPause = gap >= pauseThreshold

                if atMaxWords || atPause {
                    lines.append(SubtitleLine(words: currentWords))
                    currentWords = []
                }
            }

            currentWords.append(word)
        }

        if !currentWords.isEmpty {
            lines.append(SubtitleLine(words: currentWords))
        }

        return lines
    }
}
