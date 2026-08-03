import Foundation
import EzeestiCore

public protocol SpeechRecognizing: Sendable {
    func transcribe(audioURL: URL) async throws -> Transcript
}

@MainActor
public protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    func requestPermission() async -> Bool
    func startRecording() throws
    func stopRecording() throws -> URL
}
