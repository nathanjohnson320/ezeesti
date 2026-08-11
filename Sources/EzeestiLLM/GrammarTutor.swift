import Foundation
import EzeestiCore

public protocol LanguageModeling: Sendable {
    /// - Parameter temperature: Overrides the model default; used to resample
    ///   when a first, low-temperature draft fails validation.
    func complete(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> String
}

public extension LanguageModeling {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, temperature: nil)
    }

    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, maxTokens: 160, temperature: nil)
    }
}

public struct GrammarTutorPrompt {
    public let target: LessonItem
    public let pack: LessonPack
    public let transcript: String

    public init(target: LessonItem, pack: LessonPack, transcript: String) {
        self.target = target
        self.pack = pack
        self.transcript = transcript
    }

    public var system: String {
        """
        You are a patient Estonian language tutor for CEFR \(pack.cefr.rawValue) learners.
        Speak simply. Explain at most ONE mistake. Prefer short English explanations with Estonian examples.
        Always respond with ONLY valid JSON matching this schema:
        {
          "verdict": "correct" | "close" | "incorrect",
          "correction": "corrected Estonian sentence",
          "explanation": "one short teacher explanation",
          "retryPrompt": "short instruction telling the learner what to say next"
        }
        Do not wrap the JSON in markdown fences.
        """
    }

    public var user: String {
        let tip = target.focusTip ?? pack.focusTip
        return """
        Lesson focus: \(pack.title)
        Pattern: \(pack.patternExplanation)
        Tip: \(tip)
        Target sentence: \(target.targetEstonian)
        English gloss: \(target.glossEnglish)
        Learner said (ASR transcript): \(transcript)

        Compare the learner transcript to the target. Be lenient with punctuation and capitalization.
        If the grammar/case pattern is right, verdict=correct even if wording differs slightly.
        If close (wrong case but intent clear), verdict=close.
        """
    }
}

public enum TutorFeedbackParser {
    public static func parse(_ raw: String) throws -> TutorFeedback {
        let trimmed = stripMarkdownFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let feedback = try? JSONDecoder().decode(TutorFeedback.self, from: data) {
            return feedback
        }

        if let jsonSlice = extractJSONObject(from: trimmed),
           let data = jsonSlice.data(using: .utf8),
           let feedback = try? JSONDecoder().decode(TutorFeedback.self, from: data) {
            return feedback
        }

        // Fallback when the model ignores JSON.
        return TutorFeedback(
            verdict: .close,
            correction: trimmed,
            explanation: trimmed,
            retryPrompt: "Try saying the corrected sentence again."
        )
    }

    private static func stripMarkdownFences(_ text: String) -> String {
        var result = text
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: "```json", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        return result
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return String(text[start...end])
    }
}
