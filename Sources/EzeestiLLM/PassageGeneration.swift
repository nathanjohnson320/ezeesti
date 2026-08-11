import Foundation
import EzeestiCore

public struct PassageGenerationPrompt {
    public let cefr: CEFRLevel
    public let focusLemmas: [String]
    public let focusGlosses: [String: String]
    public let knownGlueHint: String

    public init(
        cefr: CEFRLevel,
        focusLemmas: [String],
        focusGlosses: [String: String] = [:],
        knownGlueHint: String = "ma, sa, on, ja, ei, see, täna, tahan, lähen"
    ) {
        self.cefr = cefr
        self.focusLemmas = focusLemmas
        self.focusGlosses = focusGlosses
        self.knownGlueHint = knownGlueHint
    }

    public var system: String {
        """
        You write one graded Estonian sentence for CEFR \(cefr.rawValue) learners to read aloud.
        Always respond with ONLY valid JSON. Keys:
        - title: short Estonian title (1–3 words)
        - body: ONE grammatically and logically correct Estonian sentence
        - glossEnglish: natural English translation of that sentence
        - focusWords: the required focus lemma that appears in body (same form or a clear inflection)

        Rules:
        - Exactly ONE sentence in body (one terminal . ! or ?).
        - Teach ONE focus word in a natural, useful everyday context — the sentence must make real sense.
        - Use the focus lemma at least once — woven naturally, never listed or defined.
        - Prefer simple grammar at \(cefr.rawValue). You may use common glue words (\(knownGlueHint)).
        - Aim for 8–16 Estonian words (not a 2–4 word stub). Give enough context to say aloud comfortably.
        - Keep body under 20 Estonian words.
        - Do not wrap JSON in markdown fences.
        - Never copy example wording; invent a new everyday sentence.
        - FORBIDDEN: vocabulary lists, multi-sentence scenes, nonsense combinations, "Ma ütlen: …", "Täna ma õpin uusi sõnu", "This is good practice", or meta text about learning words.

        Example shape:
        {"title":"Poes","body":"Täna hommikul ma lähen poodi ja ostan värsket piima.","glossEnglish":"This morning I go to the store and buy fresh milk.","focusWords":["ostan"]}
        """
    }

    public var user: String {
        var lines: [String] = [
            "CEFR level: \(cefr.rawValue)",
            "Write one useful Estonian sentence (about 8–16 words) that naturally teaches this focus lemma:",
            focusLemmas.joined(separator: ", "),
        ]
        if !focusGlosses.isEmpty {
            lines.append("English gloss for the focus lemma:")
            for lemma in focusLemmas {
                if let gloss = focusGlosses[lemma], !gloss.isEmpty {
                    lines.append("- \(lemma): \(gloss)")
                }
            }
        }
        lines.append("Return JSON only. Do not list the word — use it in one real sentence.")
        return lines.joined(separator: "\n")
    }
}

public struct PassageDraft: Codable, Sendable, Equatable {
    public let title: String
    public let body: String
    public let glossEnglish: String
    public let focusWords: [String]

    public init(title: String, body: String, glossEnglish: String, focusWords: [String]) {
        self.title = title
        self.body = body
        self.glossEnglish = glossEnglish
        self.focusWords = focusWords
    }
}

public enum PassageGenerationParser {
    private static let placeholderFragments: [String] = [
        "short Estonian title",
        "3–5 short Estonian sentences",
        "2–4 short Estonian sentences",
        "ONE grammatically",
        "natural English translation",
        "required focus lemmas",
        "never copy example",
        "example shape",
    ]

    private static let metaListFragments: [String] = [
        "õpin uusi sõnu",
        "ma ütlen:",
        "hea harjutus",
        "today i learn new words",
        "i say:",
        "this is good practice",
        "uusi sõnu. ma ütlen",
    ]

    public static func parse(
        _ raw: String,
        requiredFocus: [String],
        cefr: CEFRLevel
    ) -> GradedText? {
        guard let draft = decode(raw), isUsable(draft, requiredFocus: requiredFocus) else {
            return nil
        }
        return makeText(from: draft, requiredFocus: requiredFocus, cefr: cefr)
    }

    private static func decode(_ raw: String) -> PassageDraft? {
        let trimmed = strip(raw)
        if let data = trimmed.data(using: .utf8),
           let draft = try? JSONDecoder().decode(PassageDraft.self, from: data) {
            return draft
        }
        if let slice = extractJSON(trimmed),
           let data = slice.data(using: .utf8),
           let draft = try? JSONDecoder().decode(PassageDraft.self, from: data) {
            return draft
        }
        return nil
    }

    private static let nonPossessableFocus: Set<String> = [
        "kes", "kuidas", "ka", "mitte", "ära", "kõik", "välja", "tema",
        "mis", "kas", "kui", "et", "aga", "oma", "siis", "nii", "ja", "ei",
    ]

    private static func isUsable(_ draft: PassageDraft, requiredFocus: [String]) -> Bool {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let gloss = draft.glossEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2, body.count >= 8, gloss.count >= 6 else { return false }
        if looksLikePlaceholder(title) || looksLikePlaceholder(body) || looksLikePlaceholder(gloss) {
            return false
        }
        if looksLikeMetaWordList(body) || looksLikeMetaWordList(gloss) {
            return false
        }
        if sentenceCount(in: body) > 1 {
            return false
        }
        let wordCount = EstonianTokenizer.tokenize(body).filter(\.isWord).count
        // Prefer speakable sentences; reject tiny stubs like "Mul on ema."
        if wordCount < 6 || wordCount > 20 {
            return false
        }
        if looksLikeNonsensePossession(body: body, gloss: gloss, requiredFocus: requiredFocus) {
            return false
        }
        let bodyLemmas = Set(EstonianTokenizer.wordLemmas(in: body))
        let hits = requiredFocus.filter { focus in
            let key = EstonianTokenizer.normalize(focus)
            return bodyLemmas.contains(key)
                || bodyLemmas.contains(where: { $0.hasPrefix(key) || key.hasPrefix($0) })
                || body.lowercased().contains(focus.lowercased())
        }
        // Require the focus word for single-word practice.
        let need = max(1, requiredFocus.count)
        return hits.count >= need
    }

    /// Catch frames like "Mul on kes" / "I have who" that are grammatical-ish but useless.
    private static func looksLikeNonsensePossession(
        body: String,
        gloss: String,
        requiredFocus: [String]
    ) -> Bool {
        let focusKeys = requiredFocus.map { EstonianTokenizer.normalize($0) }
        let focusIsFunction = focusKeys.contains(where: { nonPossessableFocus.contains($0) })
        guard focusIsFunction else { return false }

        let bodyLower = body.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if bodyLower.hasPrefix("mul on ") || bodyLower.hasPrefix("mul on") {
            return true
        }
        let glossLower = gloss.lowercased()
        if glossLower.hasPrefix("i have ") || glossLower.contains("i have who")
            || glossLower.contains("i have how") || glossLower.contains("i have also") {
            return true
        }
        return false
    }

    private static func sentenceCount(in body: String) -> Int {
        let parts = body
            .split { ".!?".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return max(parts.count, body.isEmpty ? 0 : 1)
    }

    private static func makeText(
        from draft: PassageDraft,
        requiredFocus: [String],
        cefr: CEFRLevel
    ) -> GradedText {
        let focus = draft.focusWords.isEmpty ? requiredFocus : draft.focusWords
        return GradedText(
            id: GradedText.makeGeneratedID(),
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            cefr: cefr,
            body: draft.body.trimmingCharacters(in: .whitespacesAndNewlines),
            glossEnglish: draft.glossEnglish.trimmingCharacters(in: .whitespacesAndNewlines),
            focusWords: focus
        )
    }

    private static func looksLikePlaceholder(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return placeholderFragments.contains { lowered.contains($0.lowercased()) }
    }

    private static func looksLikeMetaWordList(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return metaListFragments.contains { lowered.contains($0) }
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
