import Foundation
import EzeestiCore

/// Offline LLM via llama.cpp CLI (`llama-cli`) + EstLLM GGUF.
public struct LlamaCppCLIService: LanguageModeling {
    public let modelPath: URL
    public let binaryPath: URL
    public let contextSize: Int
    public let temperature: Double

    public init(
        modelPath: URL,
        binaryPath: URL,
        contextSize: Int = 4096,
        temperature: Double = 0.2
    ) {
        self.modelPath = modelPath
        self.binaryPath = binaryPath
        self.contextSize = contextSize
        self.temperature = temperature
    }

    public func complete(system: String, user: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw EzeestiError.modelMissing(modelPath.lastPathComponent)
        }
        guard FileManager.default.isExecutableFile(atPath: binaryPath.path) else {
            throw EzeestiError.modelMissing("llama-cli at \(binaryPath.path)")
        }

        let prompt = """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        \(system)<|eot_id|><|start_header_id|>user<|end_header_id|>

        \(user)<|eot_id|><|start_header_id|>assistant<|end_header_id|>

        """

        let output = try await LlamaProcessRunner.run(
            executable: binaryPath,
            arguments: [
                "-m", modelPath.path,
                "-n", "128",
                "-c", "2048",
                "--temp", "\(temperature)",
                "-no-cnv",
                "--no-display-prompt",
                "-p", prompt,
            ]
        )

        let cleaned = output
            .components(separatedBy: "<|eot_id|>")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? output

        guard !cleaned.isEmpty else {
            throw EzeestiError.llmFailed("Empty response from llama-cli")
        }
        return cleaned
    }
}

/// Heuristic tutor used when EstLLM weights are not present yet.
public struct RuleBasedLanguageModel: LanguageModeling {
    public init() {}

    public func complete(system: String, user: String) async throws -> String {
        _ = system
        try await Task.sleep(nanoseconds: 250_000_000)

        let target = extractField("Target sentence:", from: user) ?? ""
        let said = extractField("Learner said (ASR transcript):", from: user) ?? ""

        let normalizedTarget = normalize(target)
        let normalizedSaid = normalize(said)

        let feedback: TutorFeedback
        if normalizedSaid == normalizedTarget || normalizedSaid.hasPrefix(normalizedTarget.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            feedback = TutorFeedback(
                verdict: .correct,
                correction: target,
                explanation: "Nice — that matches the pattern.",
                retryPrompt: "Great. Try the next example."
            )
        } else if looksLikeWrongCase(said: said, target: target) {
            feedback = TutorFeedback(
                verdict: .close,
                correction: target,
                explanation: "Close! After minema, the destination usually takes the illative. Try: \(target)",
                retryPrompt: "Say: \(target)"
            )
        } else {
            feedback = TutorFeedback(
                verdict: .incorrect,
                correction: target,
                explanation: "Not quite. Aim for: \(target)",
                retryPrompt: "Repeat: \(target)"
            )
        }

        let data = try JSONEncoder().encode(feedback)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func extractField(_ label: String, from text: String) -> String? {
        guard let range = text.range(of: label) else { return nil }
        let after = text[range.upperBound...]
        let line = after.prefix(while: { $0 != "\n" })
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeWrongCase(said: String, target: String) -> Bool {
        let saidTokens = normalize(said).split(separator: " ")
        let targetTokens = normalize(target).split(separator: " ")
        guard saidTokens.count >= 2, targetTokens.count >= 2 else { return false }
        return saidTokens.prefix(2) == targetTokens.prefix(2) && saidTokens.last != targetTokens.last
    }
}

enum LlamaProcessRunner {
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
                        let message: String
                        if process.terminationStatus == 9 {
                            message = "Tutor model was killed (exit 9) — usually out of memory after TTS. Try again without Hear target first, or close other heavy apps."
                        } else {
                            message = err.isEmpty ? "exit \(process.terminationStatus)" : err
                        }
                        continuation.resume(throwing: EzeestiError.llmFailed(message))
                        return
                    }
                    // llama-cli often prints prompt echo; keep the last non-empty block.
                    continuation.resume(returning: out.isEmpty ? err : out)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
