import AVFoundation
import ArgumentParser
import NaturalLanguage
@preconcurrency import Noora
import Speech

// MARK: - Transcribe

@MainActor struct Transcribe: AsyncParsableCommand {
    @Option(
        name: .shortAndLong,
        help: "(default: current)",
        transform: Locale.init(identifier:)
    ) var locale: Locale = .init(identifier: Locale.current.identifier)

    @Flag(
        help: "Replaces certain words and phrases with a redacted form."
    ) var censor: Bool = false

    @Argument(
        help: "Path to an audio or video file to transcribe.",
        transform: URL.init(fileURLWithPath:)
    ) var inputFile: URL

    @Flag(
        help: "Output format for the transcription.",
    ) var outputFormat: OutputFormat = .txt

    @Option(
        name: .shortAndLong,
        help: "Path to save the transcription output. If not provided, output will be printed to stdout.",
        transform: URL.init(fileURLWithPath:)
    ) var outputFile: URL?

    @Option(
        name: .shortAndLong,
        help: "Maximum sentence length in characters. If not provided, it will be set to 40.",
    ) var maxLength: Int = 40

    mutating func run() async throws {
        let piped = isatty(STDOUT_FILENO) == 0
        struct DevNull: StandardPipelining { func write(content _: String) {} }
        let noora = if piped {
            Noora(standardPipelines: .init(output: DevNull()))
        } else {
            Noora()
        }

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else {
            noora.error(.alert("Locale \"\(locale.identifier)\" is not supported. Supported locales:\n\(supported.map(\.identifier))"))
            throw Error.unsupportedLocale
        }

        for locale in await AssetInventory.reservedLocales {
            await AssetInventory.release(reservedLocale: locale)
        }
        try await AssetInventory.reserve(locale: locale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censor ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: outputFormat.needsAudioTimeRange ? [.audioTimeRange] : []
        )
        let modules: [any SpeechModule] = [transcriber]
        let installed = await Set(SpeechTranscriber.installedLocales)
        if !installed.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await noora.progressBarStep(
                    message: "Downloading required assets…"
                ) { @Sendable progressCallback in
                    struct ProgressCallback: @unchecked Sendable {
                        let callback: (Double) -> Void
                    }
                    let progressCallback = ProgressCallback(callback: progressCallback)
                    Task {
                        while !request.progress.isFinished {
                            progressCallback.callback(request.progress.fractionCompleted)
                            try? await Task.sleep(for: .seconds(0.1))
                        }
                    }
                    try await request.downloadAndInstall()
                }
            }
        }
        func isNilError(_ error: Swift.Error) -> Bool {
            if String(describing: error) == "nilError" {
                return true
            }
            let nsError = error as NSError
            return nsError.domain == "Foundation._GenericObjCError" && nsError.code == 0
        }

        func offsetAudioTimeRanges(in transcript: AttributedString, by offset: TimeInterval) -> AttributedString {
            guard outputFormat.needsAudioTimeRange, offset != 0 else { return transcript }
            var adjusted = transcript
            let offsetTime = CMTime(seconds: offset, preferredTimescale: 600)
            for run in adjusted.runs {
                guard let timeRange = run.audioTimeRange else { continue }
                let start = CMTimeAdd(timeRange.start, offsetTime)
                let end = CMTimeAdd(timeRange.end, offsetTime)
                adjusted[run.range].audioTimeRange = CMTimeRange(start: start, end: end)
            }
            return adjusted
        }

        func transcribeFile(_ fileURL: URL, label: String? = nil, timeOffset: TimeInterval = 0) async throws -> AttributedString {
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: censor ? [.etiquetteReplacements] : [],
                reportingOptions: [],
                attributeOptions: outputFormat.needsAudioTimeRange ? [.audioTimeRange] : []
            )
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let audioFile = try AVAudioFile(forReading: fileURL)
            let audioFileDuration: TimeInterval = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

            var transcript: AttributedString = ""
            let labelSuffix = label.map { " (\($0))" } ?? ""

            var w = winsize()
            let terminalColumns = if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0 {
                max(Int(w.ws_col), 9)
            } else { 64 }

            try await noora.progressStep(
                message: "Transcribing audio\(labelSuffix) using locale: \"\(locale.identifier)\"…",
                successMessage: "Audio transcribed\(labelSuffix) using locale: \"\(locale.identifier)\"",
                errorMessage: "Failed to transcribe audio\(labelSuffix) using locale: \"\(locale.identifier)\"",
                showSpinner: true
            ) { @Sendable progressHandler in
                for try await result in transcriber.results {
                    await MainActor.run {
                        transcript += result.text
                    }
                    let progress = max(min(result.resultsFinalizationTime.seconds / audioFileDuration, 1), 0)
                    var percent = progress.formatted(.percent.precision(.fractionLength(0)))
                    let oneHundredPercent = 1.0.formatted(.percent.precision(.fractionLength(0)))
                    percent = String(String(repeating: " ", count: max(oneHundredPercent.count - percent.count, 0))) + percent
                    let message = "[\(percent)] \(String(result.text.characters).trimmingCharacters(in: .whitespaces).prefix(terminalColumns - "⠋ [\(oneHundredPercent)] ".count))"
                    progressHandler(message)
                }
            }

            return offsetAudioTimeRanges(in: transcript, by: timeOffset)
        }

        func exportChunk(from asset: AVAsset, timeRange: CMTimeRange, to outputURL: URL) async throws {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw Error.audioExportSessionUnavailable
            }
            exportSession.timeRange = timeRange
            try await exportSession.export(to: outputURL, as: .m4a)
        }

        func transcribeInChunks(from fileURL: URL) async throws -> AttributedString {
            let asset = AVURLAsset(url: fileURL)
            let duration = try await asset.load(.duration)
            let totalSeconds = duration.seconds
            let chunkDuration: TimeInterval = 30 * 60
            let chunkCount = Int(ceil(totalSeconds / chunkDuration))
            var transcript: AttributedString = ""
            var chunkIndex = 1
            var startSeconds: TimeInterval = 0
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("yap-chunks-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            while startSeconds < totalSeconds {
                let endSeconds = min(startSeconds + chunkDuration, totalSeconds)
                let preferredScale = duration.timescale == 0 ? CMTimeScale(600) : duration.timescale
                let startTime = CMTime(seconds: startSeconds, preferredTimescale: preferredScale)
                let endTime = CMTime(seconds: endSeconds, preferredTimescale: preferredScale)
                let timeRange = CMTimeRange(start: startTime, end: endTime)
                let chunkURL = tempDir.appendingPathComponent("chunk-\(chunkIndex).m4a")
                try await exportChunk(from: asset, timeRange: timeRange, to: chunkURL)
                let chunkTranscript = try await transcribeFile(
                    chunkURL,
                    label: "chunk \(chunkIndex)/\(chunkCount)",
                    timeOffset: startSeconds
                )
                transcript += chunkTranscript
                startSeconds = endSeconds
                chunkIndex += 1
            }

            return transcript
        }

        let transcript: AttributedString
        do {
            transcript = try await transcribeFile(inputFile)
        } catch {
            if isNilError(error) {
                noora.error(.alert("Speech framework returned nilError; retrying in chunks…"))
                transcript = try await transcribeInChunks(from: inputFile)
            } else {
                throw error
            }
        }

        if let outputFile {
            try outputFormat.text(for: transcript, maxLength: maxLength).write(
                to: outputFile,
                atomically: false,
                encoding: .utf8
            )
            noora.success(.alert("Transcription written to \(outputFile.path)"))
        }

        if piped || outputFile == nil {
            print(outputFormat.text(for: transcript, maxLength: maxLength))
        }
    }
}

// MARK: Transcribe.Error

extension Transcribe {
    enum Error: Swift.Error {
        case audioExportSessionUnavailable
        case unsupportedLocale
    }
}
