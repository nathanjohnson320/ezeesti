import AVFoundation
import Foundation
import EzeestiCore
import ObjectiveC

public protocol TextSpeaking: Sendable {
    func speak(_ text: String, languageCode: String) async throws
}

/// macOS fallback TTS (system voice). Neurokõne replaces this when models are integrated.
public struct SystemSpeechSynthesizer: TextSpeaking {
    public init() {}

    public func speak(_ text: String, languageCode: String) async throws {
        try await speakOnMain(text, languageCode: languageCode)
    }

    @MainActor
    private func speakOnMain(_ text: String, languageCode: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
                ?? AVSpeechSynthesisVoice(language: "et")
                ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9

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

/// Placeholder for Tartu Neurokõne FastSpeech2 / TFLite integration.
public struct NeurokoneTTSService: TextSpeaking {
    public let modelDirectory: URL
    private let fallback: SystemSpeechSynthesizer

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
        self.fallback = SystemSpeechSynthesizer()
    }

    public func speak(_ text: String, languageCode: String) async throws {
        _ = modelDirectory
        try await fallback.speak(text, languageCode: languageCode)
    }
}
