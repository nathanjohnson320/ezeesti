import AVFoundation
import Foundation
import EzeestiCore

/// Captures 16 kHz mono PCM via `AVAudioRecorder` for Whisper transcription.
public actor MicrophoneRecorder: AudioRecording {
    /// Minimum usable clip length before stop rejects the recording.
    private static let minimumDurationSeconds: TimeInterval = 0.6
    /// Peak power below this (0 dB = full scale, -160 = silence) usually means no voice.
    private static let minimumPeakPowerDecibels: Float = -45

    public private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var startedAt: Date?

    public init() {}

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func startRecording() async throws {
        guard !isRecording else {
            throw EzeestiError.recordingFailed("Already recording")
        }

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
        guard audioRecorder.prepareToRecord() else {
            throw EzeestiError.recordingFailed("Could not prepare AVAudioRecorder")
        }
        guard audioRecorder.record() else {
            throw EzeestiError.recordingFailed("Could not start AVAudioRecorder")
        }

        recorder = audioRecorder
        outputURL = url
        startedAt = Date()
        isRecording = true
    }

    public func stopRecording() async throws -> URL {
        guard isRecording, let recorder, let outputURL else {
            throw EzeestiError.recordingFailed("Not currently recording")
        }

        recorder.updateMeters()
        let peak = recorder.peakPower(forChannel: 0)
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        recorder.stop()
        self.recorder = nil
        isRecording = false
        startedAt = nil

        if duration < Self.minimumDurationSeconds {
            throw EzeestiError.recordingFailed(
                "Recording was too short (\(String(format: "%.1f", duration))s) — hold Record while you speak, then Stop."
            )
        }
        if peak < Self.minimumPeakPowerDecibels {
            throw EzeestiError.recordingFailed(
                "Mic captured almost no sound — check the input device and speak closer to the microphone."
            )
        }

        return outputURL
    }
}
