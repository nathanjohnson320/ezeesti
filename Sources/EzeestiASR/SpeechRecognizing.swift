import Foundation
import EzeestiCore

public protocol SpeechRecognizing: Sendable {
    /// - Parameter initialPrompt: Optional Whisper bias text (e.g. the expected Estonian sentence).
    func transcribe(audioURL: URL, initialPrompt: String?) async throws -> Transcript
}

public extension SpeechRecognizing {
    func transcribe(audioURL: URL) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, initialPrompt: nil)
    }
}

@MainActor
public protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    func requestPermission() async -> Bool
    func startRecording() throws
    func stopRecording() throws -> URL
}
