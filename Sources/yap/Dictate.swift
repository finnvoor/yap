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
            attributeOptions: []
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

        signal(SIGINT) { _ in
            _ = write(dictateSignalWriteFD, "x", 1)
        }

        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("Dictating… Press Ctrl+C to stop.\n".utf8))
        }

        // Wait for SIGINT in background, then gracefully shut down
        Task.detached {
            var buf: UInt8 = 0
            _ = read(signalReadFD, &buf, 1)
            close(signalReadFD)
            close(dictateSignalWriteFD)
            capture.stop()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // Print results as they arrive
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print(text, terminator: "")
                fflush(stdout)
            }
        }
    }
}

// MARK: - MicrophoneCapture

private final class MicrophoneCapture: @unchecked Sendable {
    let audioEngine: AVAudioEngine
    let converter: AVAudioConverter
    let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    let targetFormat: AVAudioFormat

    init(targetFormat: AVAudioFormat, inputContinuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        self.targetFormat = targetFormat
        self.inputContinuation = inputContinuation
        self.audioEngine = AVAudioEngine()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw DictateError.microphonePermissionDenied
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw DictateError.noCompatibleAudioFormat
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [self] buffer, _ in
            handleBuffer(buffer)
        }
    }

    func stop() {
        audioEngine.stop()
        inputContinuation.finish()
    }

    func start() throws {
        do {
            try audioEngine.start()
        } catch {
            throw DictateError.microphonePermissionDenied
        }
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetFormat.sampleRate / converter.inputFormat.sampleRate)
        )
        guard frameCapacity > 0 else { return }
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let sourceBuffer = buffer
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if error == nil, convertedBuffer.frameLength > 0 {
            inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
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
