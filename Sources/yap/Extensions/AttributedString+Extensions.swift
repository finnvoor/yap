import CoreMedia
import Foundation
import NaturalLanguage

extension AttributedString {
    func wordTimestamps() -> [(text: String, timeRange: CMTimeRange)] {
        let tokenizer = NLTokenizer(unit: .word)
        let string = String(characters)
        tokenizer.string = string
        return tokenizer.tokens(for: string.startIndex..<string.endIndex).compactMap { wordRange in
            guard let attrStart = AttributedString.Index(wordRange.lowerBound, within: self),
                  let attrEnd = AttributedString.Index(wordRange.upperBound, within: self) else { return nil }
            let wordSlice = self[attrStart..<attrEnd]
            let text = String(wordSlice.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let timeRanges = wordSlice.runs.compactMap(\.audioTimeRange)
            guard let first = timeRanges.first, let last = timeRanges.last else { return nil }
            return (text, CMTimeRange(start: first.start, end: last.end))
        }
    }

    /// Split this attributed string at points where consecutive timed runs have
    /// a gap exceeding the given threshold. This prevents merging segments that
    /// are separated by a long pause (e.g. another speaker talking in between).
    func splitAtTimeGaps(threshold: TimeInterval) -> [AttributedString] {
        var splitPoints: [AttributedString.Index] = []
        var previousEndTime: TimeInterval?
        for run in runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let text = String(self[run.range].characters)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let prevEnd = previousEndTime,
               timeRange.start.seconds - prevEnd > threshold {
                splitPoints.append(run.range.lowerBound)
            }
            previousEndTime = timeRange.end.seconds
        }
        guard !splitPoints.isEmpty else { return [self] }
        var pieces: [AttributedString] = []
        var start = startIndex
        for point in splitPoints {
            if start < point {
                pieces.append(AttributedString(self[start..<point]))
            }
            start = point
        }
        if start < endIndex {
            pieces.append(AttributedString(self[start..<endIndex]))
        }
        return pieces
    }

    func sentences(maxLength: Int? = nil) -> [AttributedString] {
        let tokenizer = NLTokenizer(unit: .sentence)
        let string = String(characters)
        tokenizer.string = string
        let sentenceRanges = tokenizer.tokens(for: string.startIndex..<string.endIndex).map {
            (
                $0,
                AttributedString.Index($0.lowerBound, within: self)!
                    ..<
                    AttributedString.Index($0.upperBound, within: self)!
            )
        }
        let ranges = sentenceRanges.flatMap { sentenceStringRange, sentenceRange in
            let sentence = self[sentenceRange]
            guard let maxLength, sentence.characters.count > maxLength else {
                return [sentenceRange]
            }

            let wordTokenizer = NLTokenizer(unit: .word)
            wordTokenizer.string = string
            var wordRanges = wordTokenizer.tokens(for: sentenceStringRange).map {
                AttributedString.Index($0.lowerBound, within: self)!
                    ..<
                    AttributedString.Index($0.upperBound, within: self)!
            }
            guard !wordRanges.isEmpty else { return [sentenceRange] }
            wordRanges[0] = sentenceRange.lowerBound..<wordRanges[0].upperBound
            wordRanges[wordRanges.count - 1] = wordRanges[wordRanges.count - 1].lowerBound..<sentenceRange.upperBound

            var ranges: [Range<AttributedString.Index>] = []
            for wordRange in wordRanges {
                if let lastRange = ranges.last,
                   self[lastRange].characters.count + self[wordRange].characters.count <= maxLength {
                    ranges[ranges.count - 1] = lastRange.lowerBound..<wordRange.upperBound
                } else {
                    ranges.append(wordRange)
                }
            }

            return ranges
        }

        return ranges.compactMap { range in
            let audioTimeRanges = self[range].runs.filter {
                !String(self[$0.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.compactMap(\.audioTimeRange)
            guard let first = audioTimeRanges.first,
                  let last = audioTimeRanges.last else { return nil }
            var attributes = AttributeContainer()
            attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = CMTimeRange(
                start: first.start,
                end: last.end
            )
            return AttributedString(self[range].characters, attributes: attributes)
        }
    }
}
