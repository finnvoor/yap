import ArgumentParser
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import Noora
import ScreenCaptureKit
import Speech

private nonisolated(unsafe) var listenAndDictateSignalWriteFD: Int32 = -1

// MARK: - ListenAndDictate

struct ListenAndDictate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "listen-and-dictate",
        abstract: "Transcribe live microphone and system audio simultaneously."
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

    @Option(
        help: "Speaker label for microphone audio in timed output formats."
    ) var micLabel: String = "Mic"

    @Option(
        help: "Speaker label for system audio in timed output formats."
    ) var systemLabel: String = "System"

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

        let transcriptionOptions: Set<SpeechTranscriber.TranscriptionOption> = censor ? [.etiquetteReplacements] : []
        let attributeOptions: Set<SpeechTranscriber.ResultAttributeOption> = outputFormat.needsAudioTimeRange ? [.audioTimeRange] : []

        let micTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: transcriptionOptions,
            reportingOptions: [],
            attributeOptions: attributeOptions
        )
        let sysTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: transcriptionOptions,
            reportingOptions: [],
            attributeOptions: attributeOptions
        )
        let modules: [any SpeechModule] = [micTranscriber, sysTranscriber]

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

        // Set up microphone pipeline
        let micAnalyzer = SpeechAnalyzer(modules: [micTranscriber])
        let (micInputSequence, micInputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        guard let micFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [micTranscriber]
        ) else {
            throw DictateError.noCompatibleAudioFormat
        }

        let capture = try MicrophoneCapture(
            targetFormat: micFormat,
            inputContinuation: micInputContinuation
        )
        try capture.start()
        try await micAnalyzer.start(inputSequence: micInputSequence)

        // Set up system audio pipeline
        let sysAnalyzer = SpeechAnalyzer(modules: [sysTranscriber])
        let (sysInputSequence, sysInputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        guard let sysFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [sysTranscriber]
        ) else {
            throw ListenError.noCompatibleAudioFormat
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ListenError.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else {
            throw ListenError.screenRecordingPermissionDenied
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.sampleRate = Int(sysFormat.sampleRate)
        streamConfig.channelCount = Int(sysFormat.channelCount)
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let streamDelegate = AudioStreamDelegate(
            targetFormat: sysFormat,
            inputContinuation: sysInputContinuation
        )

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try stream.addStreamOutput(streamDelegate, type: .audio, sampleHandlerQueue: .global())
        do {
            try await stream.startCapture()
        } catch {
            throw ListenError.screenRecordingPermissionDenied
        }

        try await sysAnalyzer.start(inputSequence: sysInputSequence)

        // Set up graceful shutdown
        var signalPipe: [Int32] = [0, 0]
        pipe(&signalPipe)
        let signalReadFD = signalPipe[0]
        listenAndDictateSignalWriteFD = signalPipe[1]

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
            _ = write(listenAndDictateSignalWriteFD, "x", 1)
        }

        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("Listening and dictating… Press Ctrl+C to stop.\n".utf8))
        }

        // Wait for SIGINT in background, then gracefully shut down both pipelines
        nonisolated(unsafe) let streamToStop = stream
        nonisolated(unsafe) var savedTermios = originalTermios
        let restoreTerminal = hasTerminal
        Task.detached {
            var buf: UInt8 = 0
            _ = read(signalReadFD, &buf, 1)
            close(signalReadFD)
            close(listenAndDictateSignalWriteFD)
            if restoreTerminal {
                tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
            }
            capture.stop()
            try? await streamToStop.stopCapture()
            sysInputContinuation.finish()
            try? await micAnalyzer.finalizeAndFinishThroughEndOfInput()
            try? await sysAnalyzer.finalizeAndFinishThroughEndOfInput()
        }

        // Stream results as they arrive
        let format = outputFormat
        let sentenceMaxLength = maxLength
        if format == .txt {
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask {
                    for try await result in micTranscriber.results {
                        let text = String(result.text.characters)
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            print(text, terminator: "")
                            fflush(stdout)
                        }
                    }
                }
                group.addTask {
                    for try await result in sysTranscriber.results {
                        let text = String(result.text.characters)
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            print(text, terminator: "")
                            fflush(stdout)
                        }
                    }
                }
            }
            print()
        } else {
            let micSpeaker = micLabel
            let sysSpeaker = systemLabel
            if let header = format.header(locale: locale, speakers: [micSpeaker, sysSpeaker]) {
                print(header)
            }

            // Merge both transcriber outputs into a single stream for serialized output
            enum TaggedResult: Sendable {
                case mic(AttributedString)
                case sys(AttributedString)
            }
            let (mergedStream, mergedContinuation) = AsyncStream.makeStream(of: TaggedResult.self)

            Task {
                try? await withThrowingDiscardingTaskGroup { group in
                    group.addTask {
                        for try await result in micTranscriber.results {
                            mergedContinuation.yield(.mic(result.text))
                        }
                    }
                    group.addTask {
                        for try await result in sysTranscriber.results {
                            mergedContinuation.yield(.sys(result.text))
                        }
                    }
                }
                mergedContinuation.finish()
            }

            let includeWords = wordTimestamps
            var segmentIndex = 0
            for await tagged in mergedStream {
                let (attributedText, speaker): (AttributedString, String) = switch tagged {
                case let .mic(t): (t, micSpeaker)
                case let .sys(t): (t, sysSpeaker)
                }
                for chunk in attributedText.splitAtTimeGaps(threshold: 1.5) {
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
                        print(format.formatSegment(index: segmentIndex, timeRange: timeRange, text: text, speaker: speaker, words: words), terminator: "")
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
