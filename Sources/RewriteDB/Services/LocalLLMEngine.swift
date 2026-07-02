import Foundation
import llama

/// Off-main actor wrapping the llama.cpp C API. Loads a GGUF model once and rewrites text with a
/// system prompt. Actor isolation serializes calls — a llama context is not reentrant, and we clear
/// the KV cache between rewrites so each call is independent. Mirrors `WhisperEngine`.
actor LocalLLMEngine {
    enum EngineError: LocalizedError {
        case modelLoadFailed(String)
        case contextCreationFailed
        case tokenizeFailed
        case textTooLong
        case generationFailed
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path): return "Couldn't load the local model at \(path)."
            case .contextCreationFailed:     return "Couldn't initialize the local model."
            case .tokenizeFailed:            return "Couldn't process the text for the local model."
            case .textTooLong:               return "That selection is too long for the local model."
            case .generationFailed:          return "The local model failed while generating text."
            case .emptyResult:               return "The local model returned nothing."
            }
        }
    }

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let nCtx: Int32

    /// llama.cpp global backend init — safe/cheap, do it once per process.
    private static let backendInitialized: Void = {
        // Silence llama.cpp's stderr logging (model load prints dozens of lines otherwise).
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    /// Loads the model. Heavy (~2.5 GB) — construct from a background task, not the main actor.
    init(modelURL: URL) throws {
        _ = Self.backendInitialized

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999            // offload all layers to Metal (falls back to CPU if unavailable)

        guard let model = modelURL.path.withCString({ llama_model_load_from_file($0, mparams) }) else {
            throw EngineError.modelLoadFailed(modelURL.path)
        }
        self.model = model

        var cparams = llama_context_default_params()
        cparams.n_ctx = 4096                  // in + out budget; long selections are rejected up front
        cparams.n_batch = 4096                // allow the whole prompt in one decode
        cparams.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))
        cparams.n_threads_batch = cparams.n_threads

        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw EngineError.contextCreationFailed
        }
        self.ctx = ctx
        self.vocab = llama_model_get_vocab(model)
        self.nCtx = Int32(llama_n_ctx(ctx))
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    /// Rewrites `text` under `systemPrompt` and returns the model's full response.
    func rewrite(text: String, systemPrompt: String) throws -> String {
        // Fresh KV cache per call so rewrites don't bleed into one another.
        llama_memory_clear(llama_get_memory(ctx), true)

        let prompt = formatChat(system: systemPrompt, user: text)
        var tokens = try tokenize(prompt)
        guard tokens.count < Int(nCtx) - 8 else { throw EngineError.textTooLong }
        let maxNew = min(Int(nCtx) - tokens.count - 8, 2048)

        // Sampling: Qwen3 non-thinking recommended settings (temp 0.7 / top-p 0.8 / top-k 20),
        // fixed seed for reproducible rewrites.
        let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.8, 1))
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(1234))

        // Evaluate the prompt in one batch.
        let promptOK = tokens.withUnsafeMutableBufferPointer { buf -> Bool in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
        }
        guard promptOK else { throw EngineError.generationFailed }

        var output = ""
        var generated = 0
        while generated < maxNew {
            var token = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += piece(token)
            generated += 1
            let stepOK = withUnsafeMutablePointer(to: &token) { p -> Bool in
                llama_decode(ctx, llama_batch_get_one(p, 1)) == 0
            }
            if !stepOK { break }
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.emptyResult }
        return trimmed
    }

    // MARK: - Helpers

    /// Formats a system+user chat using the model's built-in template (from GGUF metadata), with a
    /// ChatML fallback if the model ships no template.
    private func formatChat(system: String, user: String) -> String {
        let roleSys = strdup("system"), contentSys = strdup(system)
        let roleUsr = strdup("user"), contentUsr = strdup(user)
        defer { free(roleSys); free(contentSys); free(roleUsr); free(contentUsr) }

        let messages = [
            llama_chat_message(role: UnsafePointer(roleSys), content: UnsafePointer(contentSys)),
            llama_chat_message(role: UnsafePointer(roleUsr), content: UnsafePointer(contentUsr)),
        ]
        let tmpl = llama_model_chat_template(model, nil)   // nil → default template

        if tmpl != nil {
            var size = (system.utf8.count + user.utf8.count) * 2 + 512
            for _ in 0..<2 {
                var buf = [CChar](repeating: 0, count: size)
                let n = messages.withUnsafeBufferPointer { m in
                    llama_chat_apply_template(tmpl, m.baseAddress, m.count, true, &buf, Int32(size))
                }
                if n < 0 { break }               // template failed → fall through to ChatML
                if Int(n) <= size {
                    return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                size = Int(n) + 1                 // buffer too small → grow to exact size and retry
            }
        }
        // ChatML fallback (Qwen uses this format anyway).
        return "<|im_start|>system\n\(system)<|im_end|>\n"
             + "<|im_start|>user\n\(user)<|im_end|>\n"
             + "<|im_start|>assistant\n"
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let len = Int32(text.utf8.count)
        // First pass with a nil buffer returns the negative token count needed.
        let needed = llama_tokenize(vocab, text, len, nil, 0, true, true)
        let count = Int(-needed)
        guard count > 0 else { throw EngineError.tokenizeFailed }
        var tokens = [llama_token](repeating: 0, count: count)
        let written = llama_tokenize(vocab, text, len, &tokens, Int32(count), true, true)
        guard written >= 0 else { throw EngineError.tokenizeFailed }
        return Array(tokens.prefix(Int(written)))
    }

    private func piece(_ token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        guard n > 0 else { return "" }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
