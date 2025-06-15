import ArgumentParser
import CoreMedia
import Foundation

enum OutputFormat: String, EnumerableFlag {
    case txt
    case srt

    // MARK: Internal

    var needsAudioTimeRange: Bool {
        switch self {
        case .srt: true
        default: false
        }
    }

    func text(for transcript: AttributedString) -> String {
        switch self {
        case .txt:
            return String(transcript.characters)
        case .srt:
            func format(_ timeInterval: TimeInterval) -> String {
                let ms = Int(timeInterval.truncatingRemainder(dividingBy: 1) * 1000)
                let s = Int(timeInterval) % 60
                let m = (Int(timeInterval) / 60) % 60
                let h = Int(timeInterval) / 60 / 60
                return String(format: "%0.2d:%0.2d:%0.2d,%0.3d", h, m, s, ms)
            }

            return transcript.sentences(maxLength: 40).compactMap { (sentence: AttributedString) -> (CMTimeRange, String)? in
                guard let timeRange = sentence.audioTimeRange else { return nil }
                return (timeRange, String(sentence.characters))
            }.enumerated().map { index, run in
                let (timeRange, text) = run
                return """

                \(index + 1)
                \(format(timeRange.start.seconds)) --> \(format(timeRange.end.seconds))
                \(text.trimmingCharacters(in: .whitespacesAndNewlines))

                """
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
