import Foundation
import EzeestiCore

/// Second-pass check: confirm a draft sentence is grammatical, logical, and useful before showing it.
public struct SentenceValidationPrompt {
    public let cefr: CEFRLevel
    public let focusLemmas: [String]
    public let focusGlosses: [String: String]
    public let draft: PassageDraft

    public init(
        cefr: CEFRLevel,
        focusLemmas: [String],
        focusGlosses: [String: String] = [:],
        draft: PassageDraft
    ) {
        self.cefr = cefr
        self.focusLemmas = focusLemmas
        self.focusGlosses = focusGlosses
        self.draft = draft
    }

    public var system: String {
        """
        You are a strict Estonian editor for CEFR \(cefr.rawValue) learner sentences.
        Always respond with ONLY valid JSON. Keys:
        - ok: true if the draft is already a good learner sentence; false if you had to fix it
        - title: short Estonian title (1–3 words)
        - body: ONE grammatically and logically correct Estonian sentence
        - glossEnglish: natural English translation of body
        - focusWords: the focus lemma(s) that appear in body
        - reason: short English note (why it was ok, or what you fixed)

        Validation rules:
        - body must be exactly one useful everyday sentence (not nonsense word salad).
        - Grammar must be correct Estonian at \(cefr.rawValue).
        - Meaning must be clear and natural for a learner to say aloud.
        - Every focus lemma must appear (same form or clear inflection).
        - Prefer 8–16 Estonian words. If the draft is only a 2–5 word stub, expand it into a fuller everyday sentence while keeping the focus word.
        - Keep body under 20 Estonian words.
        - If the draft fails any rule, rewrite body/title/glossEnglish so they pass — do not leave a bad sentence.
        - Do not wrap JSON in markdown fences.
        - FORBIDDEN in body: vocabulary lists, meta learning talk, "Ma ütlen:", "Täna ma õpin uusi sõnu".

        Example shape:
        {"ok":false,"title":"Poes","body":"Täna hommikul ma lähen poodi ja ostan värsket piima.","glossEnglish":"This morning I go to the store and buy fresh milk.","focusWords":["ostan"],"reason":"Draft was too short; expanded around the focus word."}
        """
    }

    public var user: String {
        var lines: [String] = [
            "CEFR level: \(cefr.rawValue)",
            "Focus lemma(s) that must appear:",
            focusLemmas.joined(separator: ", "),
            "Draft title: \(draft.title)",
            "Draft body: \(draft.body)",
            "Draft English gloss: \(draft.glossEnglish)",
        ]
        if !focusGlosses.isEmpty {
            lines.append("English glosses for focus lemmas:")
            for lemma in focusLemmas {
                if let gloss = focusGlosses[lemma], !gloss.isEmpty {
                    lines.append("- \(lemma): \(gloss)")
                }
            }
        }
        lines.append("Validate or rewrite. Return JSON only.")
        return lines.joined(separator: "\n")
    }
}

public struct SentenceValidationResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let title: String
    public let body: String
    public let glossEnglish: String
    public let focusWords: [String]
    public let reason: String

    public init(
        ok: Bool,
        title: String,
        body: String,
        glossEnglish: String,
        focusWords: [String],
        reason: String
    ) {
        self.ok = ok
        self.title = title
        self.body = body
        self.glossEnglish = glossEnglish
        self.focusWords = focusWords
        self.reason = reason
    }

}

public enum SentenceValidationParser {
    public static func parse(
        _ raw: String,
        requiredFocus: [String],
        cefr: CEFRLevel
    ) -> GradedText? {
        guard let result = decode(raw) else { return nil }
        let draft = PassageDraft(
            title: result.title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: result.body.trimmingCharacters(in: .whitespacesAndNewlines),
            glossEnglish: result.glossEnglish.trimmingCharacters(in: .whitespacesAndNewlines),
            focusWords: result.focusWords.isEmpty ? requiredFocus : result.focusWords
        )
        // Reuse generation usability gates on the validated/repaired draft.
        return PassageGenerationParser.parse(
            encode(draft),
            requiredFocus: requiredFocus,
            cefr: cefr
        )
    }

    public static func decode(_ raw: String) -> SentenceValidationResult? {
        let trimmed = strip(raw)
        if let data = trimmed.data(using: .utf8),
           let result = try? JSONDecoder().decode(SentenceValidationResult.self, from: data) {
            return result
        }
        if let slice = extractJSON(trimmed),
           let data = slice.data(using: .utf8),
           let result = try? JSONDecoder().decode(SentenceValidationResult.self, from: data) {
            return result
        }
        return nil
    }

    private static func encode(_ draft: PassageDraft) -> String {
        let data = (try? JSONEncoder().encode(draft)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
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
