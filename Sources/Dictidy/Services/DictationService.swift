import AVFoundation

/// Captures microphone audio and converts it to the 16 kHz mono Float32 stream whisper.cpp needs.
/// Tap-to-toggle: `start()` records, `stopAndCollect()` returns the accumulated samples. The audio
/// tap runs on a realtime thread, so captured samples are guarded by a lock and no main-actor state
/// is touched from the tap. Audio lives only in memory — it is never written to disk.
final class DictationService {
    static let shared = DictationService()
    private init() {}

    enum CaptureError: LocalizedError {
        case converterUnavailable
        var errorDescription: String? { "Couldn't set up audio capture." }
    }

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRunning = false

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Stops recording and returns the captured 16 kHz mono samples.
    func stopAndCollect() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        lock.lock(); let out = samples; samples.removeAll(); lock.unlock()
        return out
    }

    /// Stops and discards (e.g. when the app quits or a recording is abandoned).
    func cancel() {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        converter = nil
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    // MARK: - Audio thread

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
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
