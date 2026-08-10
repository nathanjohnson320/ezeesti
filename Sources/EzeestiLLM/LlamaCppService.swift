import Foundation
import EzeestiCore
import Darwin

/// In-process EstLLM via `libEzeestiLlama.dylib` (dlopen, RTLD_LOCAL).
/// Unloads weights after each completion to leave RAM/GPU for Whisper / Neurokõne.
public final class LlamaCppService: LanguageModeling, @unchecked Sendable {
    public let modelPath: URL
    public let libDir: URL
    public let contextSize: Int
    public let temperature: Double

    private let lock = NSLock()
    private var dylib: UnsafeMutableRawPointer?
    private var loadFn: LoadFn?
    private var unloadFn: UnloadFn?
    private var completeFn: CompleteFn?

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

    deinit {
        shutdown()
    }

    public func complete(system: String, user: String, maxTokens: Int = 160) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try self.completeSync(system: system, user: user, maxTokens: maxTokens)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Load EstLLM into GPU once, then unload weights (dylib stays) so first tutoring is faster.
    public func warmup() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.ensureSymbols()
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    guard let loadFn = self.loadFn else {
                        throw EzeestiError.llmFailed("llama symbols missing")
                    }
                    var err = [CChar](repeating: 0, count: 1024)
                    let rc = self.modelPath.path.withCString { modelC in
                        self.libDir.path.withCString { libC in
                            loadFn(libC, modelC, Int32(self.contextSize), &err, Int32(err.count))
                        }
                    }
                    if rc != 0 {
                        throw EzeestiError.llmFailed(String(cString: err))
                    }
                    // Drop weights again so RAM is free for practice; OS/Metal caches stay hot.
                    self.unloadFn?()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Drop model weights (also called after each completion). Keeps dylib loaded.
    public func unload() {
        lock.lock()
        unloadFn?()
        lock.unlock()
    }

    /// Free model + close llama/ggml dylibs while Metal is still usable (app terminate).
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        unloadFn?()
        loadFn = nil
        unloadFn = nil
        completeFn = nil
        if let handle = dylib {
            dylib = nil
            dlclose(handle)
        }
    }

    private func completeSync(system: String, user: String, maxTokens: Int) throws -> String {
        try ensureSymbols()

        let prompt = """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        \(system)<|eot_id|><|start_header_id|>user<|end_header_id|>

        \(user)<|eot_id|><|start_header_id|>assistant<|end_header_id|>

        """

        lock.lock()
        defer {
            unloadFn?()
            lock.unlock()
        }

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
            throw EzeestiError.llmFailed(String(cString: err))
        }

        let tokenBudget = max(32, min(maxTokens, 512))
        var out = [CChar](repeating: 0, count: 32_768)
        let rc = prompt.withCString { promptC in
            completeFn(
                promptC,
                Int32(tokenBudget),
                Float(temperature),
                &out,
                Int32(out.count),
                &err,
                Int32(err.count)
            )
        }
        if rc != 0 {
            throw EzeestiError.llmFailed(String(cString: err))
        }

        let raw = String(cString: out)
        let cleaned = raw
            .components(separatedBy: "<|eot_id|>")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw

        guard !cleaned.isEmpty else {
            throw EzeestiError.llmFailed("Empty response from EstLLM")
        }
        return cleaned
    }

    private func ensureSymbols() throws {
        lock.lock()
        defer { lock.unlock() }
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
}
