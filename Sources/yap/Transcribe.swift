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

    @Flag(
        help: "Include word-level timestamps in JSON output."
    ) var wordTimestamps: Bool = false

    mutating func run() async throws {
        guard FileManager.default.fileExists(atPath: inputFile.path) else {
            throw ValidationError("File not found: \(inputFile.path)")
        }

        let piped = isatty(STDOUT_FILENO) == 0
        struct DevNull: StandardPipelining { func write(content _: String) {} }
        let noora = if piped {
            Noora(standardPipelines: .init(output: DevNull()))
        } else {
            Noora()
        }

        guard SpeechTranscriber.isAvailable else {
            noora.error(.alert("SpeechTranscriber is not available on this device"))
            throw Error.speechTranscriberNotAvailable
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            noora.error(.alert("Locale \"\(locale.identifier)\" is not supported. Supported locales:\n\(supportedLocales.map(\.identifier))"))
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
        let installedLocales = await SpeechTranscriber.installedLocales
        if !installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await noora.progressBarStep(
                    message: "Downloading required assets…"
                ) { @Sendable progressCallback in
                    struct ReportProgress: @unchecked Sendable {
                        let callAsFunction: (Double) -> Void
                    }
                    let reportProgress = ReportProgress(callAsFunction: progressCallback)
                    try await withThrowingDiscardingTaskGroup { group in
                        group.addTask {
                            while !Task.isCancelled, !request.progress.isFinished {
                                reportProgress.callAsFunction(request.progress.fractionCompleted)
                                try await Task.sleep(for: .seconds(0.1))
                            }
                        }
                        try await request.downloadAndInstall()
                        group.cancelAll()
                    }
                }
            }
        }

        let analyzer = SpeechAnalyzer(modules: modules)

        let audioFile = try AVAudioFile(forReading: inputFile)
        let audioFileDuration: TimeInterval = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var transcript: AttributedString = ""

        var w = winsize()
        let terminalColumns = if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0 {
            max(Int(w.ws_col), 9)
        } else { 64 }

        let formatPrimary: @Sendable (String) -> String = { noora.format("\(.primary($0))") }
        let useOSCProgress = isatty(STDERR_FILENO) != 0
        try await noora.progressStep(
            message: "Transcribing audio using locale: \"\(locale.identifier)\"…",
            successMessage: "Audio transcribed using locale: \"\(locale.identifier)\"",
            errorMessage: "Failed to transcribe audio using locale: \"\(locale.identifier)\"",
            showSpinner: true
        ) { @Sendable progressHandler in
            for try await result in transcriber.results {
                await MainActor.run {
                    transcript += result.text
                }
                let progress = min(max(result.resultsFinalizationTime.seconds / audioFileDuration, 0), 1)
                let percent = Int(progress * 100)
                if useOSCProgress {
                    FileHandle.standardError.write(Data("\u{1b}]9;4;1;\(percent)\u{7}".utf8))
                }
                let preview = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                let message = "\(formatPrimary("[\(String(format: "%3d%%", percent))]")) \(preview.prefix(terminalColumns - "⠋ [100%] ".count))"
                progressHandler(message)
            }
        }
        if useOSCProgress {
            FileHandle.standardError.write(Data("\u{1b}]9;4;0\u{7}".utf8))
        }

        let output = outputFormat.text(for: transcript, maxLength: maxLength, locale: locale, wordTimestamps: wordTimestamps)
        if let outputFile {
            try output.write(
                to: outputFile,
                atomically: false,
                encoding: .utf8
            )
            noora.success(.alert("Transcription written to \(outputFile.path)"))
        }

        if piped || outputFile == nil {
            print(output)
        }
    }
}

// MARK: Transcribe.Error

extension Transcribe {
    enum Error: Swift.Error, LocalizedError {
        case unsupportedLocale
        case speechTranscriberNotAvailable

        // MARK: Internal

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale:
                "The specified locale is not supported for speech transcription."
            case .speechTranscriberNotAvailable:
                "SpeechTranscriber is not available on this device."
            }
        }
    }
}
