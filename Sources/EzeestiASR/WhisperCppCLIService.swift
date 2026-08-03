import Foundation
import EzeestiCore

/// Offline ASR via whisper.cpp CLI (`whisper-cli`) + TalTech GGML weights.
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
        // Bias toward short Estonian learner utterances; suppress English closers.
        let initialPrompt = "Eestikeelne kõne. Lühikesed laused."

        let output = try await ProcessRunner.run(
            executable: binaryPath,
            arguments: [
                "-m", modelPath.path,
                "-f", audioURL.path,
                "-l", language,
                "-nt",
                "-np",
                "-sns",
                "-nth", "0.75",
                "-tp", "0",
                "--prompt", initialPrompt,
            ]
        )

        let raw = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("whisper_") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let text = TranscriptCleaner.clean(raw)

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

/// Strip Whisper hallucinations common on short Estonian clips (trailing English / politeness).
public enum TranscriptCleaner {
    private static let trailingHallucinations: [String] = [
        "thank you for watching",
        "thanks for watching",
        "thank you.",
        "thank you",
        "thanks.",
        "thanks",
        "subscribe",
        "aitäh.",
        "aitäh",
        "tänan.",
        "tänan",
        "subtitl",
        "www.",
    ]

    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop the Estonian prompt echo if the model regurgitates it.
        for prefix in ["Eestikeelne kõne. Lühikesed laused.", "Eestikeelne kõne."] {
            if text.lowercased().hasPrefix(prefix.lowercased()) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Repeatedly strip known trailing hallucinations (English or Estonian fillers).
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            for phrase in trailingHallucinations {
                if lower.hasSuffix(phrase) {
                    text = String(text.dropLast(phrase.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Also trim leftover punctuation/spaces before the hallucination.
                    while text.last == "." || text.last == "," || text.last == " " {
                        if text.count <= 1 { break }
                        // Keep a single sentence-final period if the Estonian sentence had one
                        // and we only removed an extra English clause.
                        break
                    }
                    text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
                    changed = true
                    break
                }
            }
        }

        // If an English sentence was appended after Estonian (capital Thank...), cut at that boundary.
        if let range = text.range(of: #"[\.!?]\s+(Thank|Thanks|Please|Subscribe|Hello)\b"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]) + "."
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text.last != ".", text.last != "!", text.last != "?" {
            // leave as-spoken; don't force punctuation
        }
        return text
    }
}

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
