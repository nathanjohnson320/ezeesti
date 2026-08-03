import Foundation
import EzeestiCore

public struct SpokenSummaryPrompt {
    public let text: GradedText
    public let mustUseWords: [String]
    public let transcript: String

    public init(text: GradedText, mustUseWords: [String], transcript: String) {
        self.text = text
        self.mustUseWords = mustUseWords
        self.transcript = transcript
    }

    public var system: String {
        """
        You are a patient Estonian speaking tutor for CEFR \(text.cefr.rawValue) learners.
        The learner spoke a short summary of a text. Grade whether they used the required new words and if grammar is OK.
        Always respond with ONLY valid JSON:
        {
          "verdict": "correct" | "close" | "incorrect",
          "correction": "a good spoken Estonian summary using the required words",
          "explanation": "one short English tip",
          "retryPrompt": "what to say next",
          "usedRequiredWords": ["word", "..."],
          "missingRequiredWords": ["word", "..."]
        }
        Do not wrap JSON in markdown fences.
        Be lenient with punctuation and filler. Focus on required words + clear meaning.
        """
    }

    public var user: String {
        """
        Source text:
        \(text.body)

        English gloss:
        \(text.glossEnglish)

        Required words the learner must use:
        \(mustUseWords.joined(separator: ", "))

        Learner said (ASR transcript):
        \(transcript)
        """
    }
}

public struct SpokenSummaryFeedback: Codable, Sendable, Hashable {
    public let verdict: TutorVerdict
    public let correction: String
    public let explanation: String
    public let retryPrompt: String
    public let usedRequiredWords: [String]
    public let missingRequiredWords: [String]

    public init(
        verdict: TutorVerdict,
        correction: String,
        explanation: String,
        retryPrompt: String,
        usedRequiredWords: [String] = [],
        missingRequiredWords: [String] = []
    ) {
        self.verdict = verdict
        self.correction = correction
        self.explanation = explanation
        self.retryPrompt = retryPrompt
        self.usedRequiredWords = usedRequiredWords
        self.missingRequiredWords = missingRequiredWords
    }

    public var asTutorFeedback: TutorFeedback {
        TutorFeedback(
            verdict: verdict,
            correction: correction,
            explanation: explanation,
            retryPrompt: retryPrompt
        )
    }
}

public enum SpokenSummaryFeedbackParser {
    public static func parse(_ raw: String, mustUse: [String], transcript: String) -> SpokenSummaryFeedback {
        let trimmed = strip(raw)
        if let data = trimmed.data(using: .utf8),
           let feedback = try? JSONDecoder().decode(SpokenSummaryFeedback.self, from: data) {
            return feedback
        }
        if let slice = extractJSON(trimmed),
           let data = slice.data(using: .utf8),
           let feedback = try? JSONDecoder().decode(SpokenSummaryFeedback.self, from: data) {
            return feedback
        }
        return heuristic(mustUse: mustUse, transcript: transcript)
    }

    public static func heuristic(mustUse: [String], transcript: String) -> SpokenSummaryFeedback {
        let said = Set(EstonianTokenizer.wordLemmas(in: transcript))
        var used: [String] = []
        var missing: [String] = []
        for word in mustUse {
            let key = EstonianTokenizer.normalize(word)
            if said.contains(key) || said.contains(where: { $0.hasPrefix(key) || key.hasPrefix($0) }) {
                used.append(word)
            } else {
                missing.append(word)
            }
        }

        if missing.isEmpty {
            return SpokenSummaryFeedback(
                verdict: .correct,
                correction: transcript,
                explanation: "You used the new words. Nice speaking!",
                retryPrompt: "Ready for the next text.",
                usedRequiredWords: used,
                missingRequiredWords: []
            )
        }

        return SpokenSummaryFeedback(
            verdict: .close,
            correction: "Proovi öelda midagi nende sõnadega: \(mustUse.joined(separator: ", ")).",
            explanation: "Missing: \(missing.joined(separator: ", ")). Say a short summary that includes them.",
            retryPrompt: "Speak again and use: \(missing.joined(separator: ", "))",
            usedRequiredWords: used,
            missingRequiredWords: missing
        )
    }

    private static func strip(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: "```json", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSON(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return String(text[start...end])
    }
}
