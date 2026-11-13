import AVFoundation

/// Captures microphone audio and converts it to the 16 kHz mono Float32 stream whisper.cpp needs.
/// Tap-to-toggle: `start()` records, `stopAndCollect()` returns the accumulated samples. The audio
/// tap runs on a realtime thread, so captured samples are guarded by a lock and no main-actor state
/// is touched from the tap. Audio lives only in memory. It is never written to disk.
///
/// Each recording builds a fresh `AVAudioEngine` and reads the input hardware format immediately
/// before installing the tap. A long-lived engine caches the format of the device it first saw, so
/// after the input changes (AirPods switching between 24 kHz call mode and 48 kHz, a USB mic being
/// plugged in) `installTap` raises an Objective-C "Format mismatch" exception. AppKit swallows that
/// exception, which left every later dictation silently doing nothing until the app was relaunched.
final class DictationService {
    static let shared = DictationService()
    private init() {}

    enum CaptureError: LocalizedError {
        case noInputDevice
        case converterUnavailable
        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone is available. Connect or select an input device in System Settings → Sound, then try again."
            case .converterUnavailable:
                return "Couldn't set up audio capture."
            }
        }
    }

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    /// Read on the realtime tap thread and replaced on the main thread, so it is guarded by `lock`.
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRunning = false

    func start() throws {
        teardownEngine()
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        try startEngine()
        isRunning = true
    }

    /// Stops recording and returns the captured 16 kHz mono samples.
    func stopAndCollect() -> [Float] {
        guard isRunning else { return [] }
        teardownEngine()
        isRunning = false
        lock.lock(); let out = samples; samples.removeAll(); lock.unlock()
        return out
    }

    /// Stops and discards (e.g. when the app quits or a recording is abandoned).
    func cancel() {
        teardownEngine()
        isRunning = false
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    // MARK: - Engine lifecycle

    /// Builds a new engine bound to the current default input and starts capturing from it.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The hardware format as it is right now. A zero rate or channel count means there is no
        // usable input device, and installing a tap with it would raise an uncatchable exception.
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        lock.lock(); self.converter = converter; lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); self.converter = nil; lock.unlock()
            throw error
        }
        self.engine = engine

        // The engine stops itself when the input device or its format changes mid-recording.
        // Rebuild on the new device so the dictation continues, keeping the samples captured so far.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        teardownEngine()
        do {
            try startEngine()
        } catch {
            // No usable input remains. Keep what was captured; stopAndCollect() still returns it.
            teardownEngine()
        }
    }

    private func teardownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        lock.lock(); converter = nil; lock.unlock()
    }

    // MARK: - Audio thread

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let converter = self.converter; lock.unlock()
        guard let converter, buffer.format.sampleRate > 0 else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.floatChannelData else { return }

        let count = Int(out.frameLength)
        guard count > 0 else { return }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
        lock.unlock()
    }
}
