import AVFoundation

// MARK: - TranscriptionAudioFile

/// An audio file prepared for `SpeechAnalyzer`.
///
/// Some MP3 files report one more packet than they can decode. Passing one of
/// those files directly to `SpeechAnalyzer` ends with `eofErr`, so malformed
/// MP3s are first normalized to an M4A file.
struct TranscriptionAudioFile {
    let audioFile: AVAudioFile

    private let temporaryURL: URL?

    static func prepare(_ url: URL) async throws -> Self {
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEGLayer3,
              try hasMissingFrames(at: url, expectedLength: audioFile.length)
        else {
            return Self(audioFile: audioFile, temporaryURL: nil)
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "yap-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        do {
            let asset = AVURLAsset(url: url)
            guard let exportSession = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw TranscriptionError.audioConversionFailed
            }

            try await exportSession.export(to: temporaryURL, as: .m4a)
            return Self(
                audioFile: try AVAudioFile(forReading: temporaryURL),
                temporaryURL: temporaryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func removeTemporaryFile() {
        guard let temporaryURL else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    private static func hasMissingFrames(
        at url: URL,
        expectedLength: AVAudioFramePosition
    ) throws -> Bool {
        let frameCount = AVAudioFrameCount(min(expectedLength, 4_096))
        guard frameCount > 0 else { return false }

        // Use a separate file because probing changes the decoder's position.
        let probe = try AVAudioFile(forReading: url)
        probe.framePosition = expectedLength - AVAudioFramePosition(frameCount)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: probe.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw TranscriptionError.audioConversionFailed
        }

        do {
            try probe.read(into: buffer, frameCount: frameCount)
            return buffer.frameLength < frameCount
        } catch {
            return true
        }
    }
}
