import Foundation

enum SubtitleChunker {

    /// Merges sub-word BPE tokens into complete words.
    /// FluidAudio's TokenTiming uses SentencePiece tokenization where tokens
    /// starting with a space indicate a new word, and tokens without a leading
    /// space are continuations of the previous word.
    static func mergeTokensIntoWords(_ timings: [WordTiming]) -> [WordTiming] {
        guard !timings.isEmpty else { return [] }

        var merged: [WordTiming] = []
        var currentWord = ""
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        var currentConfidence: Float = 0
        var tokenCount: Int = 0

        for timing in timings {
            let token = timing.word
            let isNewWord = token.hasPrefix(" ") || token.hasPrefix("\u{2581}") || merged.isEmpty && tokenCount == 0

            if isNewWord && tokenCount > 0 {
                // Flush the accumulated word
                let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    merged.append(WordTiming(
                        word: trimmed,
                        startTime: currentStart,
                        endTime: currentEnd,
                        confidence: currentConfidence / Float(tokenCount)
                    ))
                }
                currentWord = ""
                tokenCount = 0
            }

            if tokenCount == 0 {
                currentStart = timing.startTime
                currentConfidence = 0
            }

            // Strip the word boundary marker and append
            let stripped = token
                .replacingOccurrences(of: "\u{2581}", with: "")
                .replacingOccurrences(of: " ", with: "", options: .anchored) // only leading space
            currentWord += stripped
            currentEnd = timing.endTime
            currentConfidence += timing.confidence
            tokenCount += 1
        }

        // Flush last word
        if tokenCount > 0 {
            let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                merged.append(WordTiming(
                    word: trimmed,
                    startTime: currentStart,
                    endTime: currentEnd,
                    confidence: currentConfidence / Float(tokenCount)
                ))
            }
        }

        return merged
    }

    /// Groups word timings into display lines.
    /// First merges sub-word tokens into complete words, then breaks at pauses
    /// or when word count reaches `maxWordsPerLine`.
    static func chunk(
        wordTimings: [WordTiming],
        maxWordsPerLine: Int = 10,
        pauseThreshold: TimeInterval = 0.3
    ) -> [SubtitleLine] {
        let words = mergeTokensIntoWords(wordTimings)
        guard !words.isEmpty else { return [] }

        var lines: [SubtitleLine] = []
        var currentWords: [SubtitleWord] = []

        for (index, timing) in words.enumerated() {
            let word = SubtitleWord(
                text: timing.word,
                startTime: timing.startTime,
                endTime: timing.endTime,
                confidence: timing.confidence
            )

            if !currentWords.isEmpty {
                let gap = timing.startTime - words[index - 1].endTime
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
