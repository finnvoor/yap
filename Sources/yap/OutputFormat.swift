import ArgumentParser
import CoreMedia
import Foundation

enum OutputFormat: String, EnumerableFlag {
    case txt
    case srt
    case vtt
    case json

    // MARK: Internal

    struct Segment {
        var timeRange: CMTimeRange
        var text: String
        var speaker: String?
        var words: [(text: String, timeRange: CMTimeRange)]?
    }

    var needsAudioTimeRange: Bool {
        switch self {
        case .txt: false
        case .srt, .vtt, .json: true
        }
    }

    /// Separator string between consecutive streaming segments, if any.
    var segmentSeparator: String? {
        switch self {
        case .srt, .vtt: "\n\n"
        case .json: ",\n"
        case .txt: nil
        }
    }

    /// Footer to print after all segments (closes the JSON structure).
    var footer: String? {
        switch self {
        case .json: "  ]\n}"
        default: nil
        }
    }

    // MARK: Streaming API (used by live commands)

    /// Header to print once before any segments.
    func header(locale: Locale? = nil, speakers: Set<String> = []) -> String? {
        switch self {
        case .vtt:
            return Self.vttHeader(speakers: speakers) + "\n"
        case .json:
            var metadata: [String: Any] = [:]
            if let locale {
                metadata["language"] = locale.identifier(.bcp47)
            }
            if !speakers.isEmpty {
                metadata["speakers"] = speakers.sorted()
            }
            metadata["created"] = ISO8601DateFormatter().string(from: Date())
            guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]),
                  let metadataStr = String(data: data, encoding: .utf8) else {
                return "{\n  \"metadata\" : {},\n  \"segments\" : ["
            }
            let indented = metadataStr.components(separatedBy: "\n").enumerated()
                .map { $0.offset == 0 ? $0.element : "  " + $0.element }
                .joined(separator: "\n")
            return "{\n  \"metadata\" : \(indented),\n  \"segments\" : ["
        default:
            return nil
        }
    }

    /// Format a single segment for immediate streaming output.
    /// - For SRT: numbered block with optional `Speaker: text` prefix
    /// - For VTT: numbered cue with optional `<v Speaker>text` voice tag
    /// - For JSON: single segment object
    func formatSegment(
        index: Int,
        timeRange: CMTimeRange,
        text: String,
        speaker: String? = nil,
        words: [(text: String, timeRange: CMTimeRange)]? = nil
    ) -> String {
        switch self {
        case .txt:
            return text
        case .srt:
            let content = speaker.map { "\($0): \(text)" } ?? text
            return "\(index)\n\(Self.srtTime(timeRange.start.seconds)) --> \(Self.srtTime(timeRange.end.seconds))\n\(content)"
        case .vtt:
            let content = speaker.map { "<v \($0)>\(text)" } ?? text
            return "\(index)\n\(Self.vttTime(timeRange.start.seconds)) --> \(Self.vttTime(timeRange.end.seconds))\n\(content)"
        case .json:
            var dict: [String: Any] = [
                "id": index,
                "start": Self.jsonTime(timeRange.start.seconds),
                "end": Self.jsonTime(timeRange.end.seconds),
                "text": text,
            ]
            if let speaker { dict["speaker"] = speaker }
            if let words {
                dict["words"] = words.map { word in
                    [
                        "text": word.text,
                        "start": Self.jsonTime(word.timeRange.start.seconds),
                        "end": Self.jsonTime(word.timeRange.end.seconds),
                    ] as [String: Any]
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
            }
            return "    {}"
        }
    }

    // MARK: Buffered API (used by transcribe command)

    func text(
        for transcript: AttributedString,
        maxLength: Int,
        speakerLabel: String? = nil,
        locale: Locale? = nil,
        wordTimestamps: Bool = false
    ) -> String {
        if self == .txt {
            return String(transcript.characters)
        }
        let allWords = wordTimestamps ? transcript.wordTimestamps() : nil
        let segments: [Segment] = transcript
            .sentences(maxLength: maxLength)
            .compactMap { sentence in
                guard let timeRange = sentence.audioTimeRange else { return nil }
                let words = allWords?.filter {
                    $0.timeRange.start.seconds >= timeRange.start.seconds
                        && $0.timeRange.end.seconds <= timeRange.end.seconds
                }
                return Segment(
                    timeRange: timeRange,
                    text: String(sentence.characters).trimmingCharacters(in: .whitespacesAndNewlines),
                    speaker: speakerLabel,
                    words: words
                )
            }
        return formatSegments(segments, locale: locale)
    }

    func formatSegments(
        _ segments: [Segment],
        locale: Locale? = nil
    ) -> String {
        switch self {
        case .txt:
            return segments.map(\.text).joined(separator: " ")
        case .srt:
            return segments.enumerated().map { i, seg in
                formatSegment(index: i + 1, timeRange: seg.timeRange, text: seg.text, speaker: seg.speaker)
            }.joined(separator: "\n\n")
        case .vtt:
            let speakers = Set(segments.compactMap(\.speaker))
            return ([Self.vttHeader(speakers: speakers)] + segments.enumerated().map { i, seg in
                formatSegment(index: i + 1, timeRange: seg.timeRange, text: seg.text, speaker: seg.speaker)
            }).joined(separator: "\n\n")
        case .json:
            return formatJSON(segments, locale: locale)
        }
    }

    // MARK: Private

    /// Round a time interval to millisecond precision using Decimal to avoid
    /// floating-point artifacts like 2.2200000000000002 in JSON output.
    private static func jsonTime(_ t: TimeInterval) -> Decimal {
        Decimal(Int(round(t * 1000))) / 1000
    }

    private static func vttHeader(speakers: Set<String> = []) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH:mm:ss"
        var header = "WEBVTT\n\nNOTE\nThis transcript was created on \(formatter.string(from: Date()))"
        if !speakers.isEmpty {
            header += "\nSpeakers: \(speakers.sorted().joined(separator: ", "))"
        }
        return header
    }

    private static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int(t.truncatingRemainder(dividingBy: 1) * 1000)
        let s = Int(t) % 60
        let m = (Int(t) / 60) % 60
        let h = Int(t) / 60 / 60
        return String(format: "%0.2d:%0.2d:%0.2d,%0.3d", h, m, s, ms)
    }

    private static func vttTime(_ t: TimeInterval) -> String {
        let ms = Int(t.truncatingRemainder(dividingBy: 1) * 1000)
        let s = Int(t) % 60
        let m = (Int(t) / 60) % 60
        let h = Int(t) / 60 / 60
        return String(format: "%0.2d:%0.2d:%0.2d.%0.3d", h, m, s, ms)
    }

    private func formatJSON(
        _ segments: [Segment],
        locale: Locale?
    ) -> String {
        var metadata: [String: Any] = [:]
        if let maxEnd = segments.map(\.timeRange.end.seconds).max() {
            metadata["duration"] = Self.jsonTime(maxEnd)
        }
        if let locale {
            metadata["language"] = locale.identifier(.bcp47)
        }
        let speakers = Set(segments.compactMap(\.speaker))
        if !speakers.isEmpty {
            metadata["speakers"] = speakers.sorted()
        }
        metadata["created"] = ISO8601DateFormatter().string(from: Date())

        let segmentDicts: [[String: Any]] = segments.enumerated().map { index, segment in
            var dict: [String: Any] = [
                "id": index + 1,
                "start": Self.jsonTime(segment.timeRange.start.seconds),
                "end": Self.jsonTime(segment.timeRange.end.seconds),
                "text": segment.text,
            ]
            if let speaker = segment.speaker {
                dict["speaker"] = speaker
            }
            if let words = segment.words {
                dict["words"] = words.map { word in
                    [
                        "text": word.text,
                        "start": Self.jsonTime(word.timeRange.start.seconds),
                        "end": Self.jsonTime(word.timeRange.end.seconds),
                    ] as [String: Any]
                }
            }
            return dict
        }

        let json: [String: Any] = [
            "metadata": metadata,
            "segments": segmentDicts,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
