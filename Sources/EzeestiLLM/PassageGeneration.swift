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
        You write short graded Estonian reading passages for CEFR \(cefr.rawValue) learners.
        Always respond with ONLY valid JSON. Keys:
        - title: short Estonian title (2–4 words)
        - body: 2–4 short Estonian sentences about ONE everyday scene
        - glossEnglish: natural English translation of the whole body
        - focusWords: the required focus lemmas that appear in body (same forms or clear inflected forms)

        Rules:
        - Build a real miniature story (home, shop, school, morning, friend) that USES each focus lemma in context.
        - Use EVERY focus lemma at least once in body — woven into sentences, never listed.
        - Prefer simple grammar at \(cefr.rawValue). You may use common glue words (\(knownGlueHint)).
        - Keep body under 45 Estonian words.
        - Do not wrap JSON in markdown fences.
        - Never copy example wording; invent a new everyday scene.
        - FORBIDDEN: vocabulary lists, "Ma ütlen: …", "Täna ma õpin uusi sõnu", "This is good practice", comma-separated word drills, or meta text about learning words.

        Example shape:
        {"title":"Poes","body":"Täna ma lähen poodi. Ma ostan piima ja leiba.","glossEnglish":"Today I go to the store. I buy milk and bread.","focusWords":["lähen","ostan","piima"]}
        """
    }

    public var user: String {
        var lines: [String] = [
            "CEFR level: \(cefr.rawValue)",
            "Write one short scene that naturally uses these focus lemma(s) in context:",
            focusLemmas.joined(separator: ", "),
        ]
        if !focusGlosses.isEmpty {
            lines.append("English glosses for focus lemmas:")
            for lemma in focusLemmas {
                if let gloss = focusGlosses[lemma], !gloss.isEmpty {
                    lines.append("- \(lemma): \(gloss)")
                }
            }
        }
        lines.append("Return JSON only. Do not list the words — use them in sentences.")
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

    /// Offline fallback: a tiny everyday scene around 1–2 focus words (never a vocabulary list).
    public static func heuristic(
        requiredFocus: [String],
        cefr: CEFRLevel,
        glosses: [String: String] = [:]
    ) -> GradedText {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let words = Array((requiredFocus.isEmpty ? ["isa"] : requiredFocus).prefix(2))
        let scene = buildScene(focus: words, glosses: glosses)
        return GradedText(
            id: GradedText.makeGeneratedID(),
            title: scene.title,
            cefr: cefr,
            body: scene.body,
            glossEnglish: scene.gloss,
            focusWords: words
        )
    }

    private static func buildScene(
        focus: [String],
        glosses: [String: String]
    ) -> (title: String, body: String, gloss: String) {
        let primary = focus[0]
        let primaryEntry = LexiconCatalog.shared.entry(forSurface: primary)
        let primaryGloss = cleanGloss(glosses[primary] ?? primary)
        let primaryPOS = primaryEntry?.pos ?? ""

        if focus.count >= 2 {
            let secondary = focus[1]
            let secondaryGloss = cleanGloss(glosses[secondary] ?? secondary)
            let secondaryPOS = LexiconCatalog.shared.entry(forSurface: secondary)?.pos ?? ""
            return twoWordScene(
                a: primary, aGloss: primaryGloss, aPOS: primaryPOS,
                b: secondary, bGloss: secondaryGloss, bPOS: secondaryPOS
            )
        }

        return oneWordScene(word: primary, gloss: primaryGloss, pos: primaryPOS)
    }

    private static func oneWordScene(
        word: String,
        gloss: String,
        pos: String
    ) -> (title: String, body: String, gloss: String) {
        switch primaryPOS(pos) {
        case .verb:
            return (
                "Homme",
                "Homme ma hakkan \(word). Siis ma tulen koju.",
                "Tomorrow I start to \(gloss). Then I come home."
            )
        case .adjective:
            return (
                "Hea päev",
                "Täna on \(word) päev. Ma olen rõõmus.",
                "Today is a \(gloss) day. I am happy."
            )
        case .noun:
            return (
                capitalize(word),
                "Mul on \(word). \(capitalize(word)) on kodus.",
                "I have \(gloss). \(capitalize(gloss)) is at home."
            )
        case .other:
            return (
                "Täna",
                "Täna ma räägin sõbraga. \(capitalize(word)) on oluline.",
                "Today I talk with a friend. \(capitalize(gloss)) is important."
            )
        }
    }

    private static func twoWordScene(
        a: String, aGloss: String, aPOS: String,
        b: String, bGloss: String, bPOS: String
    ) -> (title: String, body: String, gloss: String) {
        let aKind = primaryPOS(aPOS)
        let bKind = primaryPOS(bPOS)

        switch (aKind, bKind) {
        case (.noun, .noun):
            return (
                "Kodus",
                "Mul on \(a) ja \(b). Nad on kodus.",
                "I have \(aGloss) and \(bGloss). They are at home."
            )
        case (.verb, .noun), (.verb, .other):
            return (
                "Täna",
                "Täna ma hakkan \(a). Ma võtan \(b).",
                "Today I start to \(aGloss). I take \(bGloss)."
            )
        case (.noun, .verb), (.other, .verb):
            return (
                capitalize(a),
                "Mul on \(a). Ma hakkan \(b).",
                "I have \(aGloss). I start to \(bGloss)."
            )
        case (.adjective, .noun), (.adjective, .other):
            return (
                "Hea asi",
                "See \(b) on \(a). Ma tahan seda.",
                "This \(bGloss) is \(aGloss). I want it."
            )
        case (.noun, .adjective), (.other, .adjective):
            return (
                capitalize(a),
                "Mu \(a) on \(b). See on tore.",
                "My \(aGloss) is \(bGloss). That is nice."
            )
        case (.verb, .verb):
            return (
                "Homme",
                "Homme ma hakkan \(a). Pärast ma hakkan \(b).",
                "Tomorrow I start to \(aGloss). Later I start to \(bGloss)."
            )
        case (.adjective, .verb):
            return (
                "Hea plaan",
                "See plaan on \(a). Ma hakkan \(b).",
                "This plan is \(aGloss). I start to \(bGloss)."
            )
        case (.verb, .adjective):
            return (
                "Täna",
                "Täna ma hakkan \(a). See on \(b).",
                "Today I start to \(aGloss). That is \(bGloss)."
            )
        default:
            return (
                "Kodus",
                "Ma räägin \(a)st. Siis ma näen \(b).",
                "I talk about \(aGloss). Then I see \(bGloss)."
            )
        }
    }

    private enum POSKind {
        case noun, verb, adjective, other
    }

    private static func primaryPOS(_ pos: String) -> POSKind {
        let tags = pos.lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = tags.first else { return .other }
        switch first {
        case "s": return .noun
        case "v": return .verb
        case "adj", "adjg": return .adjective
        default: return .other
        }
    }

    private static func cleanGloss(_ gloss: String) -> String {
        let trimmed = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.split(separator: "/").first {
            return slash.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.isEmpty ? gloss : trimmed
    }

    private static func capitalize(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
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

    private static func isUsable(_ draft: PassageDraft, requiredFocus: [String]) -> Bool {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let gloss = draft.glossEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2, body.count >= 12, gloss.count >= 8 else { return false }
        if looksLikePlaceholder(title) || looksLikePlaceholder(body) || looksLikePlaceholder(gloss) {
            return false
        }
        if looksLikeMetaWordList(body) || looksLikeMetaWordList(gloss) {
            return false
        }
        let bodyLemmas = Set(EstonianTokenizer.wordLemmas(in: body))
        let hits = requiredFocus.filter { focus in
            let key = EstonianTokenizer.normalize(focus)
            return bodyLemmas.contains(key)
                || bodyLemmas.contains(where: { $0.hasPrefix(key) || key.hasPrefix($0) })
                || body.lowercased().contains(focus.lowercased())
        }
        // Require at least half of the focus set (models often drop 1–2).
        let need = max(1, (requiredFocus.count + 1) / 2)
        return hits.count >= need
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
