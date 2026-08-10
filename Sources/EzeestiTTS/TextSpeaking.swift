import AVFoundation
import Foundation
import EzeestiCore
import ObjectiveC

public protocol TextSpeaking: Sendable {
    func speak(_ text: String, languageCode: String) async throws
    /// Prefetch models / start persistent worker so the first hear is not a 30s cold start.
    func prepare() async throws
}

extension TextSpeaking {
    public func prepare() async throws {}
}

public enum VoiceAvailability: Sendable {
    case neurokoneCLI
    case estonianSystemVoice(name: String)
    case unavailable

    public static func current(neurokoneCLI: URL? = nil) -> VoiceAvailability {
        if let cli = neurokoneCLI ?? defaultNeurokoneCLI(),
           FileManager.default.isExecutableFile(atPath: cli.path) {
            return .neurokoneCLI
        }
        if let voice = EstonianVoice.bestAvailable() {
            return .estonianSystemVoice(name: voice.name)
        }
        return .unavailable
    }

    public static func defaultNeurokoneCLI() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ezeesti/Models/bin/neurokone-cli")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

enum EstonianVoice {
    static func bestAvailable() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            let lang = $0.language.lowercased()
            return lang == "et" || lang.hasPrefix("et-")
        }
        return voices.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: "et-EE")
            ?? AVSpeechSynthesisVoice(language: "et")
    }
}

/// Keeps one Neurokõne Python process alive so TensorFlow/HiFi-GAN load once per app launch.
actor NeurokoneSession {
    static let shared = NeurokoneSession()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var binaryPath: URL?
    private var defaultSpeaker = "mari"
    private var ready = false

    func prepare(binaryPath: URL, speaker: String = "mari") async throws {
        defaultSpeaker = speaker
        if ready, self.binaryPath == binaryPath, process?.isRunning == true {
            try await ping()
            return
        }
        try await start(binaryPath: binaryPath, speaker: speaker)
    }

    func synthesize(text: String, outURL: URL, speaker: String?, speed: Double) async throws {
        guard let binaryPath else {
            throw EzeestiError.ttsFailed("Neurokõne session not prepared")
        }
        if !ready || process?.isRunning != true {
            try await start(binaryPath: binaryPath, speaker: defaultSpeaker)
        }

        let payload: [String: Any] = [
            "text": text,
            "out": outURL.path,
            "speaker": speaker ?? defaultSpeaker,
            "speed": speed,
        ]
        let line = try JSONSerialization.data(withJSONObject: payload)
        guard var request = String(data: line, encoding: .utf8) else {
            throw EzeestiError.ttsFailed("Could not encode Neurokõne request")
        }
        request += "\n"
        guard let stdinHandle, let data = request.data(using: .utf8) else {
            throw EzeestiError.ttsFailed("Neurokõne stdin unavailable")
        }
        try stdinHandle.write(contentsOf: data)

        let response = try await readJSONLine()
        guard (response["ok"] as? Bool) == true else {
            let message = (response["error"] as? String) ?? "Neurokõne synthesize failed"
            throw EzeestiError.ttsFailed(message)
        }
        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw EzeestiError.ttsFailed("Neurokõne produced no audio file")
        }
    }

    private func ping() async throws {
        let payload = #"{"cmd":"ping"}"# + "\n"
        guard let stdinHandle, let data = payload.data(using: .utf8) else {
            throw EzeestiError.ttsFailed("Neurokõne stdin unavailable")
        }
        try stdinHandle.write(contentsOf: data)
        let response = try await readJSONLine()
        guard (response["ok"] as? Bool) == true else {
            throw EzeestiError.ttsFailed("Neurokõne ping failed")
        }
    }

    private func start(binaryPath: URL, speaker: String) async throws {
        stop()
        self.binaryPath = binaryPath
        defaultSpeaker = speaker

        guard FileManager.default.isExecutableFile(atPath: binaryPath.path) else {
            throw EzeestiError.modelMissing("neurokone-cli at \(binaryPath.path). Run Scripts/setup-neurokone.sh")
        }

        let process = Process()
        process.executableURL = binaryPath
        process.arguments = ["--serve", "--speaker", speaker]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading

        // Wait until models are loaded ("READY\n"), reading stderr for progress.
        try await waitUntilReady(stdout: stdout, stderr: stderr, process: process)
        ready = true
    }

    private func waitUntilReady(stdout: Pipe, stderr: Pipe, process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                let deadline = Date().addingTimeInterval(180)
                while process.isRunning, Date() < deadline {
                    // Non-blocking-ish drain so stderr does not fill the pipe.
                    let errChunk = stderr.fileHandleForReading.availableData
                    _ = errChunk

                    let chunk = stdout.fileHandleForReading.availableData
                    if chunk.isEmpty {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    buffer.append(chunk)
                    if let text = String(data: buffer, encoding: .utf8),
                       text.split(whereSeparator: \.isNewline).contains(where: { $0 == "READY" }) {
                        continuation.resume()
                        return
                    }
                }
                let err = String(data: stderr.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                continuation.resume(
                    throwing: EzeestiError.ttsFailed(
                        err.isEmpty ? "Neurokõne worker exited before READY" : err
                    )
                )
            }
        }
    }

    private func readJSONLine() async throws -> [String: Any] {
        guard let stdoutHandle else {
            throw EzeestiError.ttsFailed("Neurokõne stdout unavailable")
        }
        let processRef = process
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk = stdoutHandle.availableData
                    if chunk.isEmpty {
                        if processRef?.isRunning != true {
                            continuation.resume(throwing: EzeestiError.ttsFailed("Neurokõne worker died"))
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.02)
                        continue
                    }
                    buffer.append(chunk)
                    if let text = String(data: buffer, encoding: .utf8),
                       let newline = text.firstIndex(of: "\n") {
                        let line = String(text[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                        // Skip leftover READY if any
                        if line == "READY" || line.isEmpty {
                            let rest = String(text[text.index(after: newline)...])
                            buffer = Data(rest.utf8)
                            continue
                        }
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continuation.resume(throwing: EzeestiError.ttsFailed("Bad Neurokõne response: \(line)"))
                            return
                        }
                        continuation.resume(returning: obj)
                        return
                    }
                }
            }
        }
    }

    private func stop() {
        ready = false
        try? stdinHandle?.close()
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
    }
}

/// Offline Neurokõne via persistent local CLI worker (TransformerTTS + HiFi-GAN).
public struct NeurokoneTTSService: TextSpeaking {
    public let binaryPath: URL
    public let speaker: String
    public let speed: Double

    public init(
        binaryPath: URL,
        speaker: String = "mari",
        speed: Double = 1.0
    ) {
        self.binaryPath = binaryPath
        self.speaker = speaker
        self.speed = speed
    }

    public func prepare() async throws {
        try await NeurokoneSession.shared.prepare(binaryPath: binaryPath, speaker: speaker)
    }

    public func speak(_ text: String, languageCode: String) async throws {
        _ = languageCode
        try await NeurokoneSession.shared.prepare(binaryPath: binaryPath, speaker: speaker)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezeesti-nk-\(UUID().uuidString).wav")

        try await NeurokoneSession.shared.synthesize(
            text: text,
            outURL: outURL,
            speaker: speaker,
            speed: speed
        )

        try await WavPlayer.play(url: outURL)
        try? FileManager.default.removeItem(at: outURL)
    }
}

/// macOS system TTS — Estonian only (Apple does not currently ship et voices on most Macs).
public struct SystemSpeechSynthesizer: TextSpeaking {
    public init() {}

    public func speak(_ text: String, languageCode: String) async throws {
        try await speakOnMain(text, languageCode: languageCode)
    }

    @MainActor
    private func speakOnMain(_ text: String, languageCode: String) async throws {
        guard let voice = EstonianVoice.bestAvailable() else {
            throw EzeestiError.ttsFailed(
                "No Estonian TTS available. Run Scripts/setup-neurokone.sh (Apple does not ship an Estonian system voice)."
            )
        }
        _ = languageCode

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85

            let synthesizer = AVSpeechSynthesizer()
            let delegate = SpeakDelegate { result in
                continuation.resume(with: result)
            }
            objc_setAssociatedObject(synthesizer, &SpeakDelegate.assocKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            SpeakDelegate.retained.append(synthesizer)
            synthesizer.delegate = delegate
            synthesizer.speak(utterance)
        }
    }
}

enum WavPlayer {
    @MainActor
    static func play(url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                let delegate = AudioPlayerDelegate { result in
                    continuation.resume(with: result)
                }
                objc_setAssociatedObject(player, &AudioPlayerDelegate.assocKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                AudioPlayerDelegate.retained.append(player)
                player.delegate = delegate
                guard player.play() else {
                    throw EzeestiError.ttsFailed("AVAudioPlayer failed to start")
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class SpeakDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static var assocKey: UInt8 = 0
    static var retained: [AVSpeechSynthesizer] = []

    private let completion: @Sendable (Result<Void, Error>) -> Void
    private var finished = false

    init(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(synthesizer, .success(()))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(synthesizer, .failure(EzeestiError.ttsFailed("Speech cancelled")))
    }

    private func finish(_ synthesizer: AVSpeechSynthesizer, _ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        SpeakDelegate.retained.removeAll { $0 === synthesizer }
        completion(result)
    }
}

private final class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    static var assocKey: UInt8 = 0
    static var retained: [AVAudioPlayer] = []

    private let completion: @Sendable (Result<Void, Error>) -> Void
    private var finished = false

    init(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(player, flag ? .success(()) : .failure(EzeestiError.ttsFailed("Playback failed")))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(player, .failure(error ?? EzeestiError.ttsFailed("Decode error")))
    }

    private func finish(_ player: AVAudioPlayer, _ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        AudioPlayerDelegate.retained.removeAll { $0 === player }
        completion(result)
    }
}
