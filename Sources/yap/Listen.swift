import ArgumentParser
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import Noora
import ScreenCaptureKit
import Speech

// MARK: - Listen

struct Listen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe live system audio in real time."
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
            throw ListenError.noCompatibleAudioFormat
        }

        // Set up ScreenCaptureKit for system audio capture
        // Requires Screen Recording permission for the terminal app
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
        streamConfig.sampleRate = Int(targetFormat.sampleRate)
        streamConfig.channelCount = Int(targetFormat.channelCount)
        streamConfig.excludesCurrentProcessAudio = true
        // Minimal video settings since we only need audio
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let streamDelegate = AudioStreamDelegate(
            targetFormat: targetFormat,
            inputContinuation: inputContinuation
        )

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try stream.addStreamOutput(streamDelegate, type: .audio, sampleHandlerQueue: .global())
        do {
            try await stream.startCapture()
        } catch {
            throw ListenError.screenRecordingPermissionDenied
        }

        // Start the analyzer with streaming input
        try await analyzer.start(inputSequence: inputSequence)

        signal(SIGINT) { _ in
            _exit(0)
        }

        if isatty(STDERR_FILENO) != 0 {
            FileHandle.standardError.write(Data("Listening… Press Ctrl+C to stop.\n".utf8))
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

// MARK: - AudioStreamDelegate

private final class AudioStreamDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    // MARK: Lifecycle

    init(targetFormat: AVAudioFormat, inputContinuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.targetFormat = targetFormat
        self.inputContinuation = inputContinuation
    }

    // MARK: Internal

    let targetFormat: AVAudioFormat
    let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    var converter: AVAudioConverter?

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        guard let formatDescription = sampleBuffer.formatDescription,
              let sourceStreamDescription = formatDescription.audioStreamBasicDescription else { return }

        guard let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceStreamDescription.mSampleRate,
            channels: sourceStreamDescription.mChannelsPerFrame
        ) else { return }

        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }

        guard let converter else { return }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let sourcePCMBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    bufferListNoCopy: audioBufferList.unsafePointer
                ) else { return }

                let frameCapacity = AVAudioFrameCount(
                    ceil(Double(sourcePCMBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate)
                )
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

                var error: NSError?
                nonisolated(unsafe) var consumed = false
                nonisolated(unsafe) let sourceBuffer = sourcePCMBuffer
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
        } catch {
            // Skip malformed audio buffers
        }
    }
}

// MARK: - ListenError

enum ListenError: Swift.Error, LocalizedError {
    case screenRecordingPermissionDenied
    case noCompatibleAudioFormat

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            "Screen Recording permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Screen Recording, then restart the terminal."
        case .noCompatibleAudioFormat:
            "No compatible audio format available for speech recognition."
        }
    }
}
