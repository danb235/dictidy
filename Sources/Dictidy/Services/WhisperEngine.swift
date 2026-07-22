import Foundation
import whisper

/// `whisper_full` is synchronous, so Swift task cancellation cannot interrupt it by itself. This
/// lock-protected flag is read by whisper.cpp's abort callback from its compute thread.
private final class WhisperCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Off-main actor wrapping the whisper.cpp C API. Loads the GGML model once and transcribes
/// 16 kHz mono Float32 samples. Actor isolation serializes calls — a whisper context is not
/// reentrant, so two overlapping `transcribe` calls must not share one context.
actor WhisperEngine {
    enum EngineError: LocalizedError {
        case modelLoadFailed(String)
        case transcriptionFailed
        case emptyTranscription

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path): return "Couldn't load the speech model at \(path)."
            case .transcriptionFailed: return "Transcription failed."
            case .emptyTranscription: return "No speech detected."
            }
        }
    }

    private let ctx: OpaquePointer

    /// Loads the model. Heavy (~1.6 GB) — construct from a background task, not the main actor.
    init(modelURL: URL) throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let ctx = modelURL.path.withCString({ whisper_init_from_file_with_params($0, cparams) }) else {
            throw EngineError.modelLoadFailed(modelURL.path)
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// Transcribes 16 kHz mono Float32 samples to text. `language: nil` auto-detects.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { throw EngineError.emptyTranscription }

        let cancellation = WhisperCancellationFlag()
        return try await withTaskCancellationHandler {
            try transcribe(samples, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func transcribe(_ samples: [Float], cancellation: WhisperCancellationFlag) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))
        params.abort_callback = { context in
            guard let context else { return false }
            return Unmanaged<WhisperCancellationFlag>.fromOpaque(context)
                .takeUnretainedValue().isCancelled
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()

        // "auto" lets whisper detect the language (Auto Clean keeps the original language).
        // The C string only needs to outlive the synchronous whisper_full call.
        let result: Int32 = "auto".withCString { lang in
            params.language = lang
            return samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard result == 0 else { throw EngineError.transcriptionFailed }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let segment = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segment)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.emptyTranscription }
        return trimmed
    }
}
