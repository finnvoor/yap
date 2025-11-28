import ArgumentParser
import NaturalLanguage
@preconcurrency import Noora
import Speech
@preconcurrency import Translation

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

    @Option(
        name: .customLong("output-locale"),
        help: "Locale to translate the transcription to (e.g., de_DE, fr_FR, es_ES). Use -ol as shorthand.",
        transform: Locale.init(identifier:)
    ) var outputLocale: Locale?

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
            message: "Transcribing audio using locale: \"\(locale.identifier)\"…",
            successMessage: "Audio transcribed using locale: \"\(locale.identifier)\"",
            errorMessage: "Failed to transcribe audio using locale: \"\(locale.identifier)\"",
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

        // Translate if output locale is specified
        var translatedSentencesForSRT: [AttributedString]? = nil
        if let outputLocale {
            let result = try await translateTranscript(
                transcript,
                from: locale,
                to: outputLocale,
                outputFormat: outputFormat,
                maxLength: maxLength,
                noora: noora
            )
            transcript = result.transcript
            translatedSentencesForSRT = result.preservedSentences
        }

        let outputText: String
        if let translatedSentencesForSRT, outputFormat == .srt {
            // Use preserved sentences directly for SRT to maintain exact timestamps
            outputText = formatSRTFromSentences(translatedSentencesForSRT)
        } else {
            outputText = outputFormat.text(for: transcript, maxLength: maxLength)
        }
        
        if let outputFile {
            try outputText.write(
                to: outputFile,
                atomically: false,
                encoding: .utf8
            )
            noora.success(.alert("Transcription written to \(outputFile.path)"))
        }

        if piped || outputFile == nil {
            print(outputText)
        }
    }

    // MARK: Private
    
    private func formatSRTFromSentences(_ sentences: [AttributedString]) -> String {
        func format(_ timeInterval: TimeInterval) -> String {
            let ms = Int(timeInterval.truncatingRemainder(dividingBy: 1) * 1000)
            let s = Int(timeInterval) % 60
            let m = (Int(timeInterval) / 60) % 60
            let h = Int(timeInterval) / 60 / 60
            return String(format: "%0.2d:%0.2d:%0.2d,%0.3d", h, m, s, ms)
        }
        
        let entries = sentences.compactMap { sentence -> (timeRange: CMTimeRange, text: String)? in
            guard let timeRange = sentence.audioTimeRange else { return nil }
            let text = String(sentence.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (timeRange, text)
        }
        
        return entries.enumerated().map { index, entry in
            """
            
            \(index + 1)
            \(format(entry.timeRange.start.seconds)) --> \(format(entry.timeRange.end.seconds))
            \(entry.text)
            
            """
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func translateTranscript(
        _ transcript: AttributedString,
        from sourceLocale: Locale,
        to targetLocale: Locale,
        outputFormat: OutputFormat,
        maxLength: Int,
        noora: Noora
    ) async throws -> (transcript: AttributedString, preservedSentences: [AttributedString]?) {
        let sourceLanguage = sourceLocale.language
        let targetLanguage = targetLocale.language
        
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        
        switch status {
        case .unsupported:
            noora.error(.alert("Translation from \(sourceLanguage.maximalIdentifier) to \(targetLanguage.maximalIdentifier) is not supported."))
            throw Error.unsupportedTranslation
        case .supported:
            noora.error(.alert("Translation model not installed. Please install \(sourceLanguage.maximalIdentifier) → \(targetLanguage.maximalIdentifier) translation in System Settings > General > Language & Region > Translation Languages."))
            throw Error.unsupportedTranslation
        case .installed:
            break
        @unknown default:
            noora.error(.alert("Unknown translation status for \(sourceLanguage.maximalIdentifier) → \(targetLanguage.maximalIdentifier)."))
            throw Error.unsupportedTranslation
        }
        
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        
        // Get original sentences with time ranges - use maxLength to match original transcription
        let originalSentences = transcript.sentences(maxLength: maxLength)
        
        guard !originalSentences.isEmpty else {
            noora.error(.alert("No sentences to translate."))
            throw Error.unsupportedTranslation
        }
        
        var translatedSentences: [AttributedString] = []
        
        // Store session reference for the closure
        nonisolated(unsafe) let translationSession = session
        
        try await noora.progressStep(
            message: "Translating from \(sourceLanguage.maximalIdentifier) to \(targetLanguage.maximalIdentifier)…",
            successMessage: "Translation completed: \(sourceLanguage.maximalIdentifier) → \(targetLanguage.maximalIdentifier)",
            errorMessage: "Failed to translate from \(sourceLanguage.maximalIdentifier) to \(targetLanguage.maximalIdentifier)",
            showSpinner: true
        ) { @Sendable progressHandler in
            for (index, sentence) in originalSentences.enumerated() {
                let text = String(sentence.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                
                let request = TranslationSession.Request(sourceText: text)
                let responses = try await translationSession.translations(from: [request])
                
                if let response = responses.first {
                    var translatedSentence = AttributedString(response.targetText)
                    // Keep EXACT same time range from original
                    if let timeRange = sentence.audioTimeRange {
                        translatedSentence[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = timeRange
                    }
                    await MainActor.run {
                        translatedSentences.append(translatedSentence)
                    }
                }
                
                let progress = Double(index + 1) / Double(originalSentences.count)
                let percent = progress.formatted(.percent.precision(.fractionLength(0)))
                progressHandler("[\(percent)] Translated \(index + 1)/\(originalSentences.count) segments")
            }
        }
        
        // Combine translated sentences
        var combined = AttributedString()
        for sentence in translatedSentences {
            combined += sentence
            combined += AttributedString(" ")
        }
        
        // For SRT: return preserved sentences to output directly with exact timestamps
        // For TXT: just return combined text
        if outputFormat == .srt {
            return (transcript: combined, preservedSentences: translatedSentences)
        } else {
            return (transcript: combined, preservedSentences: nil)
        }
    }
}

// MARK: Transcribe.Error

extension Transcribe {
    enum Error: Swift.Error {
        case unsupportedLocale
        case unsupportedTranslation
    }
}
