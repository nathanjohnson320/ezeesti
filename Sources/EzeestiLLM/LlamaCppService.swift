import Foundation
import EzeestiCore
import Darwin

/// In-process EstLLM via `libEzeestiLlama.dylib` (dlopen, RTLD_LOCAL).
/// Unloads weights after each completion to leave RAM/GPU for Whisper / Neurokõne.
///
/// Actor isolation serializes dylib/Metal access (one completion at a time).
/// Call `shutdown()` explicitly on app terminate — do not rely on deinit for Metal teardown.
public actor LlamaCppService: LanguageModeling {
    /// Path to the EstLLM GGUF weights.
    public let modelPath: URL
    /// Directory containing `libEzeestiLlama.dylib` and deps.
    public let libDir: URL
    /// llama.cpp context size passed to `ezeesti_llama_load`.
    public let contextSize: Int
    /// Default sampling temperature when callers omit an override.
    public let temperature: Double

    private var dylib: UnsafeMutableRawPointer?
    private var loadFn: LoadFn?
    private var unloadFn: UnloadFn?
    private var completeFn: CompleteFn?

    // C ABI must match `native/llama` exports; dlsym cannot verify signatures at runtime.
    private typealias LoadFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32) -> Int32
    private typealias UnloadFn = @convention(c) () -> Void
    private typealias CompleteFn = @convention(c) (
        UnsafePointer<CChar>?, Int32, Float, UnsafeMutablePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32
    ) -> Int32

    public init(
        modelPath: URL,
        libDir: URL,
        contextSize: Int = 2048,
        temperature: Double = 0.2
    ) {
        self.modelPath = modelPath
        self.libDir = libDir
        self.contextSize = contextSize
        self.temperature = temperature
    }

    public func complete(
        system: String,
        user: String,
        maxTokens: Int = 160,
        temperature: Double? = nil
    ) async throws -> String {
        try ensureSymbols()

        let prompt = """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        \(system)<|eot_id|><|start_header_id|>user<|end_header_id|>

        \(user)<|eot_id|><|start_header_id|>assistant<|end_header_id|>

        """

        defer { unloadFn?() }

        guard let loadFn, let completeFn else {
            throw EzeestiError.llmFailed("llama symbols missing")
        }

        var err = [CChar](repeating: 0, count: 1024)
        let loadRC = modelPath.path.withCString { modelC in
            libDir.path.withCString { libC in
                loadFn(libC, modelC, Int32(contextSize), &err, Int32(err.count))
            }
        }
        if loadRC != 0 {
            throw EzeestiError.llmFailed(Self.stringFromCBuffer(err))
        }

        let tokenBudget = max(32, min(maxTokens, 512))
        let samplingTemperature = Float(temperature ?? self.temperature)
        var out = [CChar](repeating: 0, count: 32_768)
        let rc = prompt.withCString { promptC in
            completeFn(
                promptC,
                Int32(tokenBudget),
                samplingTemperature,
                &out,
                Int32(out.count),
                &err,
                Int32(err.count)
            )
        }
        if rc != 0 {
            throw EzeestiError.llmFailed(Self.stringFromCBuffer(err))
        }

        let raw = Self.stringFromCBuffer(out)
        let cleaned = raw
            .components(separatedBy: "<|eot_id|>")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw

        guard !cleaned.isEmpty else {
            throw EzeestiError.llmFailed("Empty response from EstLLM")
        }
        return cleaned
    }

    /// Load EstLLM into GPU once, then unload weights (dylib stays) so first tutoring is faster.
    public func warmup() async throws {
        try ensureSymbols()
        guard let loadFn else {
            throw EzeestiError.llmFailed("llama symbols missing")
        }
        var err = [CChar](repeating: 0, count: 1024)
        let rc = modelPath.path.withCString { modelC in
            libDir.path.withCString { libC in
                loadFn(libC, modelC, Int32(contextSize), &err, Int32(err.count))
            }
        }
        if rc != 0 {
            throw EzeestiError.llmFailed(Self.stringFromCBuffer(err))
        }
        // Drop weights again so RAM is free for practice; OS/Metal caches stay hot.
        unloadFn?()
    }

    /// Drop model weights (also called after each completion). Keeps dylib loaded.
    public func unload() {
        unloadFn?()
    }

    /// Free model + close llama/ggml dylibs while Metal is still usable (app terminate).
    public func shutdown() {
        unloadFn?()
        loadFn = nil
        unloadFn = nil
        completeFn = nil
        if let handle = dylib {
            dylib = nil
            dlclose(handle)
        }
    }

    private func ensureSymbols() throws {
        if dylib != nil { return }

        let dylibURL = libDir.appendingPathComponent("libEzeestiLlama.dylib")
        guard FileManager.default.fileExists(atPath: dylibURL.path) else {
            throw EzeestiError.modelMissing("libEzeestiLlama.dylib — run Scripts/fetch-models.sh")
        }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw EzeestiError.modelMissing(modelPath.lastPathComponent)
        }

        guard let handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = String(cString: dlerror())
            throw EzeestiError.llmFailed("dlopen llama: \(message)")
        }

        guard
            let loadSym = dlsym(handle, "ezeesti_llama_load"),
            let unloadSym = dlsym(handle, "ezeesti_llama_unload"),
            let completeSym = dlsym(handle, "ezeesti_llama_complete")
        else {
            dlclose(handle)
            throw EzeestiError.llmFailed("Missing ezeesti_llama_* symbols")
        }

        dylib = handle
        loadFn = unsafeBitCast(loadSym, to: LoadFn.self)
        unloadFn = unsafeBitCast(unloadSym, to: UnloadFn.self)
        completeFn = unsafeBitCast(completeSym, to: CompleteFn.self)
    }

    /// Decodes a zero-filled CChar buffer without reading past the first NUL or buffer end.
    private static func stringFromCBuffer(_ buffer: [CChar]) -> String {
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
