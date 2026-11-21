import ArgumentParser
@preconcurrency import AVFoundation
@preconcurrency import Noora
import Speech

private nonisolated(unsafe) var dictateSignalWriteFD: Int32 = -1

// MARK: - Dictate

struct Dictate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe live microphone input in real time."
    )

    @Option(
        name: .shortAndLong,
        help: "(default: current)",
        transform: Locale.init(identifier:)
    ) var locale: Locale = .init(identifier: Locale.current.identifier)

    @Flag(
        help: "Replaces certain words and phrases with a redacted form."
    ) var censor: Bool = false

    @Flag(
        help: "Output format for the transcription."
    ) var outputFormat: OutputFormat = .txt

    @Option(
        name: .shortAndLong,
        help: "Maximum sentence length in characters for timed output formats."
    ) var maxLength: Int = 40

    @Flag(
        help: "Include word-level timestamps in JSON output."
    ) var wordTimestamps: Bool = false

    @MainActor mutating func run() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw Transcribe.Error.speechTranscriberNotAvailable
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw Transcribe.Error.unsupportedLocale
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
            let piped = isatty(STDOUT_FILENO) == 0
            struct DevNull: StandardPipelining { func write(content _: String) {} }
            let noora = if piped {
                Noora(standardPipelines: .init(output: DevNull()))
            } else {
                Noora()
            }
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

        // Set up streaming input
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // Get target audio format from the analyzer
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw DictateError.noCompatibleAudioFormat
        }

        // Set up AVAudioEngine for microphone capture
        let capture = try MicrophoneCapture(
            targetFormat: targetFormat,
            inputContinuation: inputContinuation
        )
        try capture.start()

        // Start the analyzer with streaming input
        try await analyzer.start(inputSequence: inputSequence)

        // Set up graceful shutdown
        var signalPipe: [Int32] = [0, 0]
        pipe(&signalPipe)
        let signalReadFD = signalPipe[0]
        dictateSignalWriteFD = signalPipe[1]

        // Suppress ^C echo
        var originalTermios = termios()
        let hasTerminal = isatty(STDIN_FILENO) != 0
        if hasTerminal {
            tcgetattr(STDIN_FILENO, &originalTermios)
            var raw = originalTermios
            raw.c_lflag &= ~UInt(ECHOCTL)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }

        signal(SIGINT) { _ in
            _ = write(dictateSignalWriteFD, "x", 1)
        }

        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("Dictating… Press Ctrl+C to stop.\n".utf8))
        }

        // Wait for SIGINT in background, then gracefully shut down
        nonisolated(unsafe) var savedTermios = originalTermios
        let restoreTerminal = hasTerminal
        Task.detached {
            var buf: UInt8 = 0
            _ = read(signalReadFD, &buf, 1)
            close(signalReadFD)
            close(dictateSignalWriteFD)
            if restoreTerminal {
                tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
            }
            capture.stop()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // Stream results as they arrive
        let format = outputFormat
        let sentenceMaxLength = maxLength
        if format == .txt {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print(text, terminator: "")
                    fflush(stdout)
                }
            }
            print()
        } else {
            if let header = format.header(locale: locale) {
                print(header)
            }
            let includeWords = wordTimestamps
            var segmentIndex = 0
            for try await result in transcriber.results {
                for chunk in result.text.splitAtTimeGaps(threshold: 1.5) {
                    let allWords = includeWords ? chunk.wordTimestamps() : nil
                    for sentence in chunk.sentences(maxLength: sentenceMaxLength) {
                        guard let timeRange = sentence.audioTimeRange else { continue }
                        let text = String(sentence.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let words = allWords?.filter {
                            $0.timeRange.start.seconds >= timeRange.start.seconds
                                && $0.timeRange.end.seconds <= timeRange.end.seconds
                        }
                        if segmentIndex > 0, let sep = format.segmentSeparator {
                            print(sep, terminator: "")
                        }
                        segmentIndex += 1
                        print(format.formatSegment(index: segmentIndex, timeRange: timeRange, text: text, words: words), terminator: "")
                        fflush(stdout)
                    }
                }
            }
            if segmentIndex > 0 { print() }
            if let footer = format.footer {
                print(footer)
            }
        }
    }
}

// MARK: - DictateError

enum DictateError: Swift.Error, LocalizedError {
    case microphonePermissionDenied
    case noCompatibleAudioFormat

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Microphone, then restart the terminal."
        case .noCompatibleAudioFormat:
            "No compatible audio format available for speech recognition."
        }
    }
}
