import AVFoundation
import Speech

// MARK: - TranscriptionEngine

enum TranscriptionEngine {
    struct Options: Sendable {
        var locale: Locale = .init(identifier: Locale.current.identifier)
        var censor: Bool = false
        var outputFormat: OutputFormat = .txt
        var maxLength: Int = 40
    }

    static func transcribe(
        file: URL,
        options: Options = .init()
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw TranscriptionError.fileNotFound(file.path)
        }

        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.speechTranscriberNotAvailable
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier(.bcp47) == options.locale.identifier(.bcp47) }) else {
            throw TranscriptionError.unsupportedLocale(options.locale.identifier)
        }

        for locale in await AssetInventory.reservedLocales {
            await AssetInventory.release(reservedLocale: locale)
        }
        try await AssetInventory.reserve(locale: options.locale)

        let transcriber = SpeechTranscriber(
            locale: options.locale,
            transcriptionOptions: options.censor ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: options.outputFormat.needsAudioTimeRange ? [.audioTimeRange] : []
        )
        let modules: [any SpeechModule] = [transcriber]

        let installedLocales = await SpeechTranscriber.installedLocales
        if !installedLocales.contains(where: { $0.identifier(.bcp47) == options.locale.identifier(.bcp47) }) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        let audioFile = try AVAudioFile(forReading: file)
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var transcript: AttributedString = ""
        for try await result in transcriber.results {
            transcript += result.text
        }

        return options.outputFormat.text(for: transcript, maxLength: options.maxLength)
    }
}

// MARK: - TranscriptionError

enum TranscriptionError: Error, LocalizedError {
    case fileNotFound(String)
    case speechTranscriberNotAvailable
    case unsupportedLocale(String)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            "File not found: \(path)"
        case .speechTranscriberNotAvailable:
            "SpeechTranscriber is not available on this device."
        case let .unsupportedLocale(identifier):
            "Locale \"\(identifier)\" is not supported for speech transcription."
        }
    }
}
