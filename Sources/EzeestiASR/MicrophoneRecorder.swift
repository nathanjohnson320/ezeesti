import AVFoundation
import Foundation
import EzeestiCore

@MainActor
public final class MicrophoneRecorder: AudioRecording {
    public private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    public init() {}

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func startRecording() throws {
        guard !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezeesti-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder.isMeteringEnabled = true
        guard audioRecorder.prepareToRecord(), audioRecorder.record() else {
            throw EzeestiError.recordingFailed("Could not start AVAudioRecorder")
        }

        recorder = audioRecorder
        outputURL = url
        isRecording = true
    }

    public func stopRecording() throws -> URL {
        guard isRecording, let recorder, let outputURL else {
            throw EzeestiError.recordingFailed("Not currently recording")
        }

        recorder.stop()
        self.recorder = nil
        isRecording = false
        return outputURL
    }
}
