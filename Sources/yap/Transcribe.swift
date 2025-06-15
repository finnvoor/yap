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
    ) var locale: Locale = .current

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
            noora.error(.alert("Locale \(locale.identifier) is not supported"))
            throw Error.unsupportedLocale
        }

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

        let analyzer = SpeechAnalyzer(modules: modules)

        let audioFile = try AVAudioFile(forReading: inputFile)
        let audioFileDuration: TimeInterval = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var transcript: AttributedString = ""

        var w = winsize()
        let terminalColumns = if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0 {
            max(Int(w.ws_col), 9)
        } else { 64 }

        try await noora.progressStep(
            message: "Transcribing audio…",
            successMessage: "Audio transcribed",
            errorMessage: "Failed to transcribe audio",
            showSpinner: true
        ) { @Sendable progressHandler in
            for try await result in transcriber.results {
                await MainActor.run {
                    transcript += result.text
                }
                let progress = result.resultsFinalizationTime.seconds / audioFileDuration
                var percent = progress.formatted(.percent.precision(.fractionLength(0)))
                percent = String(String(repeating: " ", count: 4 - percent.count)) + percent
                let message = "[\(percent)] \(String(result.text.characters).trimmingCharacters(in: .whitespaces).prefix(terminalColumns - 9))"
                progressHandler(message)
            }
        }

        if let outputFile {
            try outputFormat.text(for: transcript).write(
                to: outputFile,
                atomically: false,
                encoding: .utf8
            )
            noora.success(.alert("Transcription written to \(outputFile.path)"))
        }

        if piped || outputFile == nil {
            print(outputFormat.text(for: transcript))
        }
    }
}

// MARK: Transcribe.Error

extension Transcribe {
    enum Error: Swift.Error {
        case unsupportedLocale
    }
}
