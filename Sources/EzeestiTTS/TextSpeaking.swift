import AVFoundation
import Foundation
import EzeestiCore
import ObjectiveC

public protocol TextSpeaking: Sendable {
    func speak(_ text: String, languageCode: String) async throws
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

/// Offline Neurokõne via local CLI (TransformerTTS + HiFi-GAN).
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

    public func speak(_ text: String, languageCode: String) async throws {
        _ = languageCode
        guard FileManager.default.isExecutableFile(atPath: binaryPath.path) else {
            throw EzeestiError.modelMissing("neurokone-cli at \(binaryPath.path). Run Scripts/setup-neurokone.sh")
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezeesti-nk-\(UUID().uuidString).wav")

        _ = try await ProcessRunner.run(
            executable: binaryPath,
            arguments: [
                "--text", text,
                "--out", outURL.path,
                "--speaker", speaker,
                "--speed", String(speed),
            ]
        )

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw EzeestiError.ttsFailed("Neurokõne produced no audio file")
        }

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

enum ProcessRunner {
    static func run(executable: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    try process.run()
                    process.waitUntilExit()

                    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if process.terminationStatus != 0 {
                        continuation.resume(
                            throwing: EzeestiError.ttsFailed(err.isEmpty ? "neurokone-cli exit \(process.terminationStatus)" : err)
                        )
                        return
                    }
                    continuation.resume(returning: out.isEmpty ? err : out)
                } catch {
                    continuation.resume(throwing: error)
                }
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
