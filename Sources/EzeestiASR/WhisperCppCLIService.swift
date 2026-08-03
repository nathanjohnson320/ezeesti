import Foundation
import EzeestiCore

/// Offline ASR via whisper.cpp CLI (`whisper-cli`) + TalTech GGML weights.
/// Embedding the XCFramework can replace this Process bridge later without changing TutorEngine.
public struct WhisperCppCLIService: SpeechRecognizing {
    public let modelPath: URL
    public let binaryPath: URL
    public let language: String

    public init(modelPath: URL, binaryPath: URL, language: String = "et") {
        self.modelPath = modelPath
        self.binaryPath = binaryPath
        self.language = language
    }

    public func transcribe(audioURL: URL) async throws -> Transcript {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw EzeestiError.modelMissing(modelPath.lastPathComponent)
        }
        guard FileManager.default.isExecutableFile(atPath: binaryPath.path) else {
            throw EzeestiError.modelMissing("whisper-cli at \(binaryPath.path)")
        }

        let started = Date()
        let output = try await ProcessRunner.run(
            executable: binaryPath,
            arguments: [
                "-m", modelPath.path,
                "-f", audioURL.path,
                "-l", language,
                "-nt",
                "-np",
            ]
        )

        let text = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("whisper_") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw EzeestiError.transcriptionFailed("Empty transcript from whisper-cli")
        }

        return Transcript(
            text: text,
            languageHint: language,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }
}

/// Deterministic stub for UI development when models are not downloaded yet.
public struct MockSpeechRecognizer: SpeechRecognizing {
    public var cannedText: String

    public init(cannedText: String = "Ma lähen pood.") {
        self.cannedText = cannedText
    }

    public func transcribe(audioURL: URL) async throws -> Transcript {
        _ = audioURL
        try await Task.sleep(nanoseconds: 400_000_000)
        return Transcript(text: cannedText, languageHint: "et", durationSeconds: 0.4)
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

                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        continuation.resume(
                            throwing: EzeestiError.transcriptionFailed(
                                err.isEmpty ? "exit \(process.terminationStatus)" : err
                            )
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
