import Foundation
import AVFoundation
import EzeestiCore
import Darwin

/// In-process TalTech Whisper via `libEzeestiWhisper.dylib` (dlopen, RTLD_LOCAL).
public final class WhisperCppService: SpeechRecognizing, @unchecked Sendable {
    public let modelPath: URL
    public let libDir: URL
    public let language: String

    private let lock = NSLock()
    private var dylib: UnsafeMutableRawPointer?
    private var loadFn: LoadFn?
    private var unloadFn: UnloadFn?
    private var transcribeFn: TranscribeFn?
    private var loadedModel = false

    private typealias LoadFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32) -> Int32
    private typealias UnloadFn = @convention(c) () -> Void
    private typealias TranscribeFn = @convention(c) (
        UnsafePointer<Float>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafeMutablePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32
    ) -> Int32

    public init(modelPath: URL, libDir: URL, language: String = "et") {
        self.modelPath = modelPath
        self.libDir = libDir
        self.language = language
    }

    deinit {
        shutdown()
    }

    /// Free Whisper context and unload Metal-backed dylibs while the process is still healthy.
    /// Call from app terminate — otherwise ggml Metal asserts during `exit` teardown.
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        unloadFn?()
        loadedModel = false
        loadFn = nil
        unloadFn = nil
        transcribeFn = nil
        if let handle = dylib {
            dylib = nil
            dlclose(handle)
        }
    }

    /// Load Whisper weights + Metal shaders, and run a tiny silent decode so first real ASR is warm.
    public func warmup() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.ensureLoaded()
                    // ~0.25s silence primes encoder/decoder kernels without needing a mic clip.
                    let samples = [Float](repeating: 0, count: 4_000)
                    _ = try? self.runTranscribe(samples: samples)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func transcribe(audioURL: URL) async throws -> Transcript {
        let started = Date()
        try ensureLoaded()
        let samples = try Self.loadPCM16kMono(url: audioURL)
        let durationSeconds = Double(samples.count) / 16_000.0

        if samples.count < 8_000 {
            throw EzeestiError.transcriptionFailed(
                "Audio too short (\(String(format: "%.1f", durationSeconds))s) — speak a full sentence before stopping."
            )
        }

        let rms = Self.rms(samples)
        if rms < 0.004 {
            throw EzeestiError.transcriptionFailed(
                "Audio is nearly silent — check the mic input and try again."
            )
        }

        let text: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runTranscribe(samples: samples)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let cleaned = TranscriptCleaner.clean(text)
        let usable = cleaned.isEmpty ? TranscriptCleaner.collapseRepeatedWords(text.trimmingCharacters(in: .whitespacesAndNewlines)) : cleaned
        guard !usable.isEmpty else {
            throw EzeestiError.transcriptionFailed(
                "No clear speech detected — speak louder/closer and try the sentence again."
            )
        }

        return Transcript(
            text: usable,
            languageHint: language,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    private func ensureLoaded() throws {
        lock.lock()
        defer { lock.unlock() }

        if loadedModel { return }

        let dylibURL = libDir.appendingPathComponent("libEzeestiWhisper.dylib")
        guard FileManager.default.fileExists(atPath: dylibURL.path) else {
            throw EzeestiError.modelMissing("libEzeestiWhisper.dylib — run Scripts/fetch-models.sh")
        }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw EzeestiError.modelMissing(modelPath.lastPathComponent)
        }

        guard let handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = String(cString: dlerror())
            throw EzeestiError.transcriptionFailed("dlopen whisper: \(message)")
        }

        guard
            let loadSym = dlsym(handle, "ezeesti_whisper_load"),
            let unloadSym = dlsym(handle, "ezeesti_whisper_unload"),
            let transcribeSym = dlsym(handle, "ezeesti_whisper_transcribe")
        else {
            dlclose(handle)
            throw EzeestiError.transcriptionFailed("Missing ezeesti_whisper_* symbols")
        }

        let load = unsafeBitCast(loadSym, to: LoadFn.self)
        let unload = unsafeBitCast(unloadSym, to: UnloadFn.self)
        let transcribe = unsafeBitCast(transcribeSym, to: TranscribeFn.self)

        var err = [CChar](repeating: 0, count: 1024)
        let rc = modelPath.path.withCString { modelC in
            libDir.path.withCString { libC in
                load(libC, modelC, &err, Int32(err.count))
            }
        }
        if rc != 0 {
            dlclose(handle)
            throw EzeestiError.transcriptionFailed(String(cString: err))
        }

        dylib = handle
        loadFn = load
        unloadFn = unload
        transcribeFn = transcribe
        loadedModel = true
    }

    private func runTranscribe(samples: [Float]) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let transcribeFn else {
            throw EzeestiError.transcriptionFailed("whisper not loaded")
        }

        var out = [CChar](repeating: 0, count: 16_384)
        var err = [CChar](repeating: 0, count: 1024)
        let prompt = "Eestikeelne kõne. Lühikesed laused."

        let rc = samples.withUnsafeBufferPointer { buf in
            language.withCString { langC in
                prompt.withCString { promptC in
                    transcribeFn(
                        buf.baseAddress,
                        Int32(buf.count),
                        langC,
                        promptC,
                        &out,
                        Int32(out.count),
                        &err,
                        Int32(err.count)
                    )
                }
            }
        }
        if rc != 0 {
            throw EzeestiError.transcriptionFailed(String(cString: err))
        }
        return String(cString: out)
    }

    private static func loadPCM16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw EzeestiError.transcriptionFailed("Could not allocate audio buffer")
        }
        try file.read(into: buffer)

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        if format.sampleRate == 16_000, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 {
            let n = Int(buffer.frameLength)
            guard let ch = buffer.floatChannelData?[0] else {
                throw EzeestiError.transcriptionFailed("Missing float channel data")
            }
            return Array(UnsafeBufferPointer(start: ch, count: n))
        }

        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw EzeestiError.transcriptionFailed("Could not create audio converter")
        }
        let ratio = 16_000 / format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            throw EzeestiError.transcriptionFailed("Could not allocate converted buffer")
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            throw EzeestiError.transcriptionFailed(error.localizedDescription)
        }

        let n = Int(outBuffer.frameLength)
        guard let ch = outBuffer.floatChannelData?[0] else {
            throw EzeestiError.transcriptionFailed("Missing converted float data")
        }
        return Array(UnsafeBufferPointer(start: ch, count: n))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }
}
