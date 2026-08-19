import Speech

enum TranscriptionLocale {
    static func resolve(explicitLocale: Locale?) async -> Locale? {
        guard let explicitLocale else {
            return await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        return supportedLocales.first {
            $0.identifier(.bcp47) == explicitLocale.identifier(.bcp47)
        }
    }
}
