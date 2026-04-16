@preconcurrency import AVFoundation

// MARK: - AudioExtractor

enum AudioExtractor {
    static func extractAudio(from asset: AVURLAsset, to outputURL: URL) async throws {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw Error.noAudioTrack
        }

        // SpeechAnalyzer requires uncompressed PCM — M4A/AAC from AVAssetExportSession
        // produces avfaudio error -50 (kAudio_ParamError). Use AVAssetReader/Writer to
        // transcode directly to 16-bit mono 16 kHz Linear PCM WAV.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        reader.add(readerOutput)

        let writer = try AVAssetWriter(url: outputURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // AVAssetWriter/AVAssetWriterInput/AVAssetReaderTrackOutput don't formally adopt
        // Sendable, but are safe to use from a dispatch queue.
        struct Context: @unchecked Sendable {
            let writerInput: AVAssetWriterInput
            let readerOutput: AVAssetReaderTrackOutput
            let writer: AVAssetWriter
        }
        let ctx = Context(writerInput: writerInput, readerOutput: readerOutput, writer: writer)

        // Use a serial queue: requestMediaDataWhenReady can fire the callback multiple
        // times on a concurrent queue, causing a race where finishWriting is called twice
        // (crash: "Cannot call method when status is 1").
        let queue = DispatchQueue(label: "yap.audio-extractor")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            ctx.writerInput.requestMediaDataWhenReady(on: queue) {
                while ctx.writerInput.isReadyForMoreMediaData {
                    if let buffer = ctx.readerOutput.copyNextSampleBuffer() {
                        ctx.writerInput.append(buffer)
                    } else {
                        ctx.writerInput.markAsFinished()
                        ctx.writer.finishWriting {
                            if ctx.writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: ctx.writer.error ?? Error.failed)
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}

// MARK: AudioExtractor.Error

extension AudioExtractor {
    enum Error: Swift.Error, LocalizedError {
        case noAudioTrack
        case failed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "The file does not contain an audio track."
            case .failed: "Audio extraction failed."
            }
        }
    }
}
