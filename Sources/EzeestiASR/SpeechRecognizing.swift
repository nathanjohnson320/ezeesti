import Foundation
import EzeestiCore

/// Offline speech-to-text used by tutoring and learning flows.
public protocol SpeechRecognizing: Sendable {
    /// - Parameter initialPrompt: Optional Whisper bias text (e.g. the expected Estonian sentence).
    func transcribe(audioURL: URL, initialPrompt: String?) async throws -> Transcript
    /// Load weights / prime kernels before the first real transcription.
    func warmup() async throws
    /// Unload native/Metal resources while the process is still healthy (e.g. app terminate).
    func shutdown() async
}

public extension SpeechRecognizing {
    func transcribe(audioURL: URL) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, initialPrompt: nil)
    }

    func warmup() async throws {}

    func shutdown() async {}
}

/// Microphone capture used before transcription.
public protocol AudioRecording: Sendable {
    var isRecording: Bool { get async }
    func requestPermission() async -> Bool
    func startRecording() async throws
    func stopRecording() async throws -> URL
}
