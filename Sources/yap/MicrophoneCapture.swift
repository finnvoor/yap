@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Speech

// MARK: - MicrophoneCapture

/// Captures the default input device and streams converted buffers to a `SpeechAnalyzer`.
///
/// Microphone capture has to keep working while other apps (video calls in particular) use the
/// same device. Two things go wrong with a plain `AVAudioEngine` in that situation:
///
/// - When another app enables voice processing (echo cancellation) on the mic, or the default
///   input device / its format changes, the engine posts `AVAudioEngineConfigurationChange` and
///   stops. It never restarts on its own, so capture silently goes dead.
/// - While another app has voice processing enabled, a non-voice-processing client only receives
///   the raw, unprocessed mic array channels, which are ~30-40 dB quieter than normal and too
///   quiet to transcribe.
///
/// To handle both, this enables voice processing on our own input node (which yields properly
/// processed, gain-controlled audio and coexists with other voice-processing clients), restarts
/// or rebuilds the engine when the configuration or default input device changes, and runs a
/// watchdog that rebuilds the engine whenever buffers stop arriving for any reason.
final class MicrophoneCapture: @unchecked Sendable {
    // MARK: Lifecycle

    init(targetFormat: AVAudioFormat, inputContinuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        self.targetFormat = targetFormat
        self.inputContinuation = inputContinuation
        try queue.sync {
            active = try makeEngine(voiceProcessing: true)
        }
    }

    deinit {
        removeDefaultInputListener()
    }

    // MARK: Internal

    let targetFormat: AVAudioFormat
    let inputContinuation: AsyncStream<AnalyzerInput>.Continuation

    func start() throws {
        try queue.sync {
            guard let active else { throw DictateError.microphonePermissionDenied }
            do {
                try active.engine.start()
            } catch {
                throw DictateError.microphonePermissionDenied
            }
            activate(active)
            isStarted = true
            addDefaultInputListener()
            startWatchdog()
        }
    }

    func stop() {
        queue.sync {
            isStopped = true
            watchdog?.cancel()
            watchdog = nil
            removeDefaultInputListener()
            lock.withLock { activeGeneration = -1 }
            teardown(active)
            active = nil
        }
        inputContinuation.finish()
    }

    // MARK: Private

    private struct Engine {
        let engine: AVAudioEngine
        let generation: Int
        let inputDevice: AudioDeviceID
        let configurationObserver: NSObjectProtocol
    }

    private let queue = DispatchQueue(label: "yap.microphone-capture")
    private let lock = NSLock()

    // Owned by `queue`.
    private var active: Engine?
    private var nextGeneration = 0
    private var isStarted = false
    private var isStopped = false
    private var rebuildPending = false
    private var consecutiveFailures = 0
    private var watchdog: DispatchSourceTimer?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    // Shared with the audio thread, guarded by `lock`.
    private var activeGeneration = -1
    private var lastBufferUptime: UInt64 = 0
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var timelineStartHostTime: UInt64?
    private var framesEmitted: Int64 = 0

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Rebuild the engine if no buffers arrive for this long (buffers normally arrive every ~100ms).
    private static let stallTimeout: UInt64 = 1_000_000_000
    /// Re-anchor the analyzer timeline when capture falls behind wall-clock time by more than this.
    private static let timelineGapThreshold: Double = 0.25

    private static func currentDefaultInputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    // MARK: Engine lifecycle (on `queue`)

    /// Builds a new, not yet started engine with a tap installed. Its buffers are ignored until
    /// it is activated, so it can be prepared while the previous engine keeps capturing.
    private func makeEngine(voiceProcessing: Bool) throws -> Engine {
        let inputDevice = Self.currentDefaultInputDevice()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if voiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            } catch {
                // Fall back to unprocessed input.
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw DictateError.microphonePermissionDenied
        }

        nextGeneration += 1
        let generation = nextGeneration
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
            self?.handleBuffer(buffer, time: time, generation: generation)
        }

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.handleConfigurationChange(generation: generation) }
        }

        return Engine(
            engine: engine,
            generation: generation,
            inputDevice: inputDevice,
            configurationObserver: observer
        )
    }

    private func activate(_ engine: Engine) {
        lock.withLock {
            activeGeneration = engine.generation
            converter = nil
            monoFormat = nil
            lastBufferUptime = DispatchTime.now().uptimeNanoseconds
        }
    }

    private func teardown(_ engine: Engine?) {
        guard let engine else { return }
        NotificationCenter.default.removeObserver(engine.configurationObserver)
        engine.engine.inputNode.removeTap(onBus: 0)
        engine.engine.stop()
    }

    /// `AVAudioEngineConfigurationChange` fires both for real changes (another app enabling voice
    /// processing, format changes) and as a side effect of setting up voice processing ourselves,
    /// so rebuilding on every notification can loop forever. Instead, leave a running engine
    /// alone and restart a stopped one, rebuilding only if that fails. The watchdog covers the
    /// case where the engine claims to be running but no longer delivers audio.
    private func handleConfigurationChange(generation: Int) {
        guard isStarted, !isStopped, let active, active.generation == generation else { return }
        guard !active.engine.isRunning else { return }
        do {
            try active.engine.start()
            lock.withLock { lastBufferUptime = DispatchTime.now().uptimeNanoseconds }
        } catch {
            scheduleRebuild()
        }
    }

    private func scheduleRebuild(after delay: DispatchTimeInterval = .milliseconds(100)) {
        guard isStarted, !isStopped, !rebuildPending else { return }
        rebuildPending = true
        // Changes tend to arrive in bursts; coalesce them.
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            rebuildPending = false
            rebuild()
        }
    }

    /// Replaces the active engine. The old engine keeps capturing until the new one is running
    /// (setting up voice processing can take several seconds), so a working microphone is never
    /// interrupted by a rebuild.
    private func rebuild() {
        guard isStarted, !isStopped else { return }

        // If voice processing keeps failing on this device, alternate with plain capture so we
        // always end up with some working input.
        let voiceProcessing = consecutiveFailures < 2 || consecutiveFailures.isMultiple(of: 2)

        var candidate: Engine?
        do {
            candidate = try makeEngine(voiceProcessing: voiceProcessing)
            try candidate!.engine.start()
        } catch {
            teardown(candidate)
            consecutiveFailures += 1
            // The device may be mid-switch; keep retrying with backoff until it comes back.
            let delay = min(250 * (1 << min(consecutiveFailures, 4)), 4000)
            scheduleRebuild(after: .milliseconds(delay))
            return
        }

        guard isStarted, !isStopped, let candidate else {
            teardown(candidate)
            return
        }
        let previous = active
        active = candidate
        activate(candidate)
        teardown(previous)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, isStarted, !isStopped, !rebuildPending else { return }
            let last = lock.withLock { lastBufferUptime }
            let silentFor = DispatchTime.now().uptimeNanoseconds &- last
            if silentFor > Self.stallTimeout {
                consecutiveFailures += 1
                rebuild()
            } else if silentFor < Self.stallTimeout / 2 {
                consecutiveFailures = 0
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func addDefaultInputListener() {
        guard defaultInputListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Runs on `queue`. Only rebuild if the default input really moved to another device.
            guard let self, isStarted, !isStopped,
                  Self.currentDefaultInputDevice() != active?.inputDevice else { return }
            consecutiveFailures = 0
            // Give the new device a moment to settle; engines started mid-switch can come up silent.
            scheduleRebuild(after: .milliseconds(500))
        }
        var address = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        )
        if status == noErr {
            defaultInputListener = listener
        }
    }

    private func removeDefaultInputListener() {
        guard let listener = defaultInputListener else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        )
        defaultInputListener = nil
    }

    // MARK: Audio thread

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, generation: Int) {
        guard buffer.frameLength > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        guard generation == activeGeneration else { return }
        lastBufferUptime = DispatchTime.now().uptimeNanoseconds

        // Voice processing delivers the processed signal duplicated across every channel, and raw
        // multi-channel input has a usable mic on channel 0, so take the first channel only.
        guard let source = firstChannel(of: buffer) else { return }

        if converter == nil || converter?.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: targetFormat)
        }
        guard let converter else { return }

        let frameCapacity = AVAudioFrameCount(
            ceil(Double(source.frameLength) * targetFormat.sampleRate / source.format.sampleRate)
        ) + 32
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let sourceBuffer = source
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, error == nil else {
            // Drop the converter so the next buffer gets a fresh one.
            self.converter = nil
            return
        }
        guard convertedBuffer.frameLength > 0 else { return }

        let startTime = timelineStartTime(for: time)
        framesEmitted += Int64(convertedBuffer.frameLength)
        inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer, bufferStartTime: startTime))
    }

    /// Keeps the analyzer timeline aligned with wall-clock time across interruptions, so
    /// timestamps stay correct (and in sync with system audio) after a gap. Returns `nil` while
    /// buffers are contiguous. Must be called with `lock` held.
    private func timelineStartTime(for time: AVAudioTime) -> CMTime? {
        guard time.isHostTimeValid else { return nil }
        guard let start = timelineStartHostTime else {
            timelineStartHostTime = time.hostTime
            return nil
        }
        guard time.hostTime > start else { return nil }

        let elapsed = AVAudioTime.seconds(forHostTime: time.hostTime - start)
        let emitted = Double(framesEmitted) / targetFormat.sampleRate
        guard elapsed - emitted > Self.timelineGapThreshold else { return nil }

        framesEmitted = Int64(elapsed * targetFormat.sampleRate)
        return CMTime(value: framesEmitted, timescale: CMTimeScale(targetFormat.sampleRate))
    }

    /// Returns a mono buffer containing the first channel of `buffer`. Must be called with `lock` held.
    private func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        if format.channelCount == 1 { return buffer }

        guard format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData else {
            // Unusual format; let the converter downmix it.
            return buffer
        }

        if monoFormat?.sampleRate != format.sampleRate {
            monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: 1,
                interleaved: false
            )
        }
        guard let monoFormat,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?[0] else { return nil }

        let frames = Int(buffer.frameLength)
        if format.isInterleaved {
            let stride = Int(format.channelCount)
            let source = channels[0]
            for i in 0 ..< frames {
                destination[i] = source[i * stride]
            }
        } else {
            destination.update(from: channels[0], count: frames)
        }
        mono.frameLength = buffer.frameLength
        return mono
    }
}
