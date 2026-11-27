import Foundation
@preconcurrency import AVFoundation
import EzeestiCore

/// TalTech Whisper via a required local OMLX server (`POST /v1/audio/transcriptions`).
public actor OmlxSpeechRecognizer: SpeechRecognizing {
    private static let sampleRate: Double = 16_000
    private static let minimumSampleCount = 8_000 // 0.5s at 16 kHz
    private static let minimumRMS: Float = 0.004

    public let client: OmlxClient
    /// Whisper language code (default Estonian).
    public let language: String

    public init(client: OmlxClient, language: String = "et") {
        self.client = client
        self.language = language
    }

    public init(config: OmlxConfig, language: String = "et") {
        self.client = OmlxClient(config: config)
        self.language = language
    }

    public func warmup() async throws {
        try await client.checkReady()
        let ids = try await client.listModelIDs()
        let wanted = await client.config.sttModelID
        guard ids.contains(where: { $0 == wanted || $0.hasSuffix("/\(wanted)") || $0.hasSuffix(wanted) })
        else {
            let available = ids.isEmpty ? "(none)" : ids.joined(separator: ", ")
            throw EzeestiError.modelMissing(
                "OMLX STT model '\(wanted)' not listed. Available: \(available). Run Scripts/fetch-models.sh and restart OMLX."
            )
        }
    }

    public func shutdown() async {}

    public func transcribe(audioURL: URL, initialPrompt: String?) async throws -> Transcript {
        let started = Date()
        var samples = try Self.loadPCM16kMono(url: audioURL)
        samples = Self.trimSilence(samples)
        let durationSeconds = Double(samples.count) / Self.sampleRate

        if samples.count < Self.minimumSampleCount {
            throw EzeestiError.transcriptionFailed(
                "Audio too short (\(String(format: "%.1f", durationSeconds))s) — speak a full sentence before stopping."
            )
        }

        let rms = Self.rms(samples)
        if rms < Self.minimumRMS {
            throw EzeestiError.transcriptionFailed(
                "Audio is nearly silent — check the mic input and try again."
            )
        }

        let promptHint = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = try await client.transcribe(
            fileURL: audioURL,
            language: language,
            prompt: promptHint
        )

        let cleaned = TranscriptCleaner.clean(text)
        var usable = cleaned.isEmpty
            ? TranscriptCleaner.collapseRepeatedWords(text.trimmingCharacters(in: .whitespacesAndNewlines))
            : cleaned
        if let expected = promptHint, !expected.isEmpty {
            usable = TranscriptCleaner.align(toExpected: expected, transcript: usable)
        }
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

    /// Drop leading/trailing near-silence so ASR is less likely to invent filler after speech.
    private static func trimSilence(
        _ samples: [Float],
        threshold: Float = 0.012,
        padSamples: Int = 2_400 // 150ms at 16kHz
    ) -> [Float] {
        guard samples.count > padSamples * 2 else { return samples }
        var start = 0
        while start < samples.count, abs(samples[start]) < threshold {
            start += 1
        }
        var end = samples.count - 1
        while end > start, abs(samples[end]) < threshold {
            end -= 1
        }
        start = max(0, start - padSamples)
        end = min(samples.count - 1, end + padSamples)
        guard end > start else { return samples }
        return Array(samples[start...end])
    }

    private static func loadPCM16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw EzeestiError.transcriptionFailed("Could not allocate audio buffer")
        }
        try file.read(into: buffer)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw EzeestiError.transcriptionFailed("Could not create 16 kHz mono float format")
        }
        if format.sampleRate == sampleRate, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 {
            let n = Int(buffer.frameLength)
            guard let ch = buffer.floatChannelData?[0] else {
                throw EzeestiError.transcriptionFailed("Missing float channel data")
            }
            return Array(UnsafeBufferPointer(start: ch, count: n))
        }

        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw EzeestiError.transcriptionFailed("Could not create audio converter")
        }
        let ratio = sampleRate / format.sampleRate
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

/// Always resolves to the OMLX STT backend (required; no in-process fallback).
public enum ASRBackend {
    public static func resolve(config: OmlxConfig = .fromEnvironment()) -> any SpeechRecognizing {
        OmlxSpeechRecognizer(config: config)
    }
}
