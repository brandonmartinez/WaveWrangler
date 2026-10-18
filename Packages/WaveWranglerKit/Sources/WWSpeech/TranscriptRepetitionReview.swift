import Foundation
import WWCore

/// A text-only review hint, never evidence of silence, incorrect speech, or permission to cut.
public enum TranscriptRepetitionReview {
    private struct Token {
        let text: String
        let word: Int
        let run: Int
    }

    public static func suspectWordIDs(in words: [TranscriptWord]) -> Set<UUID> {
        var tokens: [Token] = []
        var run = 0
        var previousTimed: Int?
        for index in words.indices {
            if words[index].alignedStart != nil || words[index].alignedEnd != nil {
                if let previousTimed, !continues(words[previousTimed], words[index]) { run += 1 }
                previousTimed = index
            }
            for text in words[index].text.lowercased().split(whereSeparator: {
                !$0.isLetter && !$0.isNumber && $0 != "'"
            }) {
                tokens.append(Token(text: String(text), word: index, run: run))
            }
        }
        var result: Set<UUID> = []
        var start = 0
        while start < tokens.count {
            var bestEnd = start
            for length in 1...4 {
                guard start + length <= tokens.count else { break }
                var end = start + length
                while end + length <= tokens.count {
                    let matches = (0..<length).allSatisfy {
                        tokens[end + $0].run == tokens[start].run
                            && tokens[end + $0].text == tokens[start + $0].text
                            && tokens[start + $0].run == tokens[start].run
                    }
                    if !matches { break }
                    end += length
                }
                // Ordinary "I, I" stutters and a few repeated fillers are not suspect.
                if (end - start) / length >= (length == 1 ? 6 : 4) { bestEnd = max(bestEnd, end) }
            }
            if bestEnd > start {
                for index in tokens[start].word...tokens[bestEnd - 1].word { result.insert(words[index].id) }
                start = bestEnd
            } else {
                start += 1
            }
        }
        return result
    }

    private static func continues(_ previous: TranscriptWord, _ next: TranscriptWord) -> Bool {
        switch (previous.alignedStart, previous.alignedEnd, next.alignedStart, next.alignedEnd) {
        case let (a?, b?, c?, d?):
            return [a, b, c, d].allSatisfy(\.isFinite) && b > a && d > c && c >= a && c - b <= 1
        case (nil, nil, nil, nil): return true
        default: return false
        }
    }
}
