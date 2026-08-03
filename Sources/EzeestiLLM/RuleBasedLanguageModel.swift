import Foundation
import EzeestiCore

/// Heuristic tutor used when EstLLM weights / native libs are not present yet.
public struct RuleBasedLanguageModel: LanguageModeling {
    public init() {}

    public func complete(system: String, user: String) async throws -> String {
        try await Task.sleep(nanoseconds: 250_000_000)

        if system.contains("Estonian–English dictionary") || system.contains("\"gloss\"") {
            let word = extractField("Word:", from: user) ?? "word"
            if let bundled = WordGlossCatalog.gloss(forSurface: word) {
                return #"{"gloss":"\#(escapeJSON(bundled))"}"#
            }
            return #"{"gloss":"(EstLLM not installed — run fetch-models.sh)"}"#
        }

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

    private func escapeJSON(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
