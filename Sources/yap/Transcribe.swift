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
        if let outputLocale {
            transcript = try await translateTranscript(
                transcript,
                from: locale,
                to: outputLocale,
                noora: noora
            )
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

    // MARK: Private

    private func translateTranscript(
        _ transcript: AttributedString,
        from sourceLocale: Locale,
        to targetLocale: Locale,
        noora: Noora
    ) async throws -> AttributedString {
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
        
        // Try to preserve sentence structure with time ranges for SRT format
        let sentencesWithTimeRanges = transcript.sentences()
        
        // If we have sentences with time ranges (needed for SRT), translate them individually
        if !sentencesWithTimeRanges.isEmpty {
            var translatedSentences: [AttributedString] = []
            
            // Store session reference for the closure
            nonisolated(unsafe) let translationSession = session
            
            do {
                try await noora.progressStep(
                    message: "Translating from \(sourceLanguage.maximalIdentifier) to \(targetLanguage.maximalIdentifier)…",
                    successMessage: "Translation completed: \(sourceLanguage.maximalIdentifier) → \(targetLanguage.maximalIdentifier)",
                    errorMessage: "Failed to translate from \(sourceLanguage.maximalIdentifier) to \(targetLanguage.maximalIdentifier)",
                    showSpinner: true
                ) { @Sendable progressHandler in
                    for (index, sentence) in sentencesWithTimeRanges.enumerated() {
                        let text = String(sentence.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        
                        let request = TranslationSession.Request(sourceText: text)
                        let responses = try await translationSession.translations(from: [request])
                        
                        if let response = responses.first {
                            var translatedSentence = AttributedString(response.targetText)
                            // Preserve audio time range from original sentence
                            if let timeRange = sentence.audioTimeRange {
                                translatedSentence[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = timeRange
                            }
                            await MainActor.run {
                                translatedSentences.append(translatedSentence)
                            }
                        }
                        
                        let progress = Double(index + 1) / Double(sentencesWithTimeRanges.count)
                        let percent = progress.formatted(.percent.precision(.fractionLength(0)))
                        progressHandler("[\(percent)] Translated \(index + 1)/\(sentencesWithTimeRanges.count) segments")
                    }
                }
            } catch {
                noora.error(.alert("Translation failed: \(error.localizedDescription)"))
                throw Error.unsupportedTranslation
            }
            
            // Combine translated sentences preserving attributes
            var result = AttributedString()
            for sentence in translatedSentences {
                result += sentence
            }
            return result
        }
        
        // Fallback: For plain text (TXT format), translate without time ranges
        let fullText = String(transcript.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            noora.error(.alert("No text to translate."))
            throw Error.unsupportedTranslation
        }
        
        // Split into sentences for progress tracking and better translation quality
        let sentences = fullText.split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { $0.split(separator: "。", omittingEmptySubsequences: true) }
            .flatMap { $0.split(separator: ". ", omittingEmptySubsequences: true) }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        let chunksToTranslate = sentences.isEmpty ? [fullText] : sentences
        var translatedTexts: [String] = []
        
        // Store session reference for the closure
        nonisolated(unsafe) let translationSession = session
        
        do {
            try await noora.progressStep(
                message: "Translating from \(sourceLanguage.maximalIdentifier) to \(targetLanguage.maximalIdentifier)…",
                successMessage: "Translation completed: \(sourceLanguage.maximalIdentifier) → \(targetLanguage.maximalIdentifier)",
                errorMessage: "Failed to translate from \(sourceLanguage.maximalIdentifier) to \(targetLanguage.maximalIdentifier)",
                showSpinner: true
            ) { @Sendable progressHandler in
                for (index, text) in chunksToTranslate.enumerated() {
                    let request = TranslationSession.Request(sourceText: text)
                    do {
                        let responses = try await translationSession.translations(from: [request])
                        
                        if let response = responses.first {
                            await MainActor.run {
                                translatedTexts.append(response.targetText)
                            }
                        }
                    } catch {
                        // Log the actual error for debugging
                        print("Translation error for chunk \(index): \(error)")
                        throw error
                    }
                    
                    let progress = Double(index + 1) / Double(chunksToTranslate.count)
                    let percent = progress.formatted(.percent.precision(.fractionLength(0)))
                    progressHandler("[\(percent)] Translated \(index + 1)/\(chunksToTranslate.count) segments")
                }
            }
        } catch {
            noora.error(.alert("Translation failed: \(error.localizedDescription)"))
            throw Error.unsupportedTranslation
        }
        
        // Combine translated texts back into a single AttributedString
        let combinedText = translatedTexts.joined(separator: " ")
        let result = AttributedString(combinedText)
        
        return result
    }
}

// MARK: Transcribe.Error

extension Transcribe {
    enum Error: Swift.Error {
        case unsupportedLocale
        case unsupportedTranslation
    }
}
