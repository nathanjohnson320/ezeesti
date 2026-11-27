import Foundation

/// Learner familiarity for a lemma surface.
public enum VocabFamiliarity: String, Codable, Sendable, CaseIterable {
    case unknown
    case learning
    case known
}

/// A short graded reading passage (bundled or LLM-generated).
public struct GradedText: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let cefr: CEFRLevel
    public let body: String
    public let glossEnglish: String
    public let focusWords: [String]

    public init(
        id: String,
        title: String,
        cefr: CEFRLevel,
        body: String,
        glossEnglish: String,
        focusWords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.cefr = cefr
        self.body = body
        self.glossEnglish = glossEnglish
        self.focusWords = focusWords
    }

    public var isGenerated: Bool {
        id.hasPrefix("gen-")
    }

    public static func makeGeneratedID() -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "gen-\(stamp)-\(suffix)"
    }
}

/// Token-level known/unknown breakdown for a graded text against a lemma set.
public struct TextFamiliarityReport: Sendable {
    public let tokens: [TextToken]
    public let knownCount: Int
    public let wordCount: Int
    public let predictedUnknown: Set<Int>

    /// Fraction of word tokens marked known. Empty text returns `0` (not vacuous 100%).
    public var knownRatio: Double {
        guard wordCount > 0 else { return 0 }
        return Double(knownCount) / Double(wordCount)
    }

    public var percentKnown: Int {
        Int((knownRatio * 100).rounded())
    }
}

/// Bundled graded texts helpers and A1 seed lemmas.
public enum GradedTextCatalog {
    /// High-frequency glue / closed-class words that should not be passage focus targets.
    public static let baselineFunctionWords: Set<String> = [
        "ma", "sa", "ta", "me", "te", "nad", "ja", "on", "ei", "jah",
        "tere", "palun", "aitäh", "hommikust", "head", "aega",
        "lähen", "tahan", "teen", "söön", "joon", "olen",
        "see", "seal", "siin", "nüüd", "täna", "homme",
        "suur", "väike", "hea", "ilus", "uus",
        "maja", "kool", "pood", "kodu", "töö", "auto", "buss",
        "kohv", "tee", "vesi", "leib", "piim",
        "üks", "kaks", "kolm", "neli", "viis",
    ]

    /// Loads the bundled A1 seed lemma list. Returns `[]` if the resource is missing or invalid.
    public static func loadSeedKnownLemmas() -> Set<String> {
        (try? loadSeedKnownLemmasThrowing()) ?? []
    }

    /// Throwing variant for callers that want load failures to surface.
    public static func loadSeedKnownLemmasThrowing() throws -> Set<String> {
        let url =
            Bundle.module.url(forResource: "a1-seed-known", withExtension: "json", subdirectory: "Texts")
            ?? Bundle.module.url(forResource: "a1-seed-known", withExtension: "json")
        guard let url else {
            throw EzeestiError.invalidLessonData("Missing a1-seed-known.json")
        }
        let data = try Data(contentsOf: url)
        let words = try JSONDecoder().decode([String].self, from: data)
        return Set(words.map { EstonianTokenizer.normalize($0) })
    }

    public static func familiarity(
        text: GradedText,
        knownLemmas: Set<String>,
        learningLemmas: Set<String> = [],
        lexicon: LexiconCatalog = .shared
    ) -> TextFamiliarityReport {
        lexicon.loadBundledIfNeeded()
        let recognized = knownLemmas.union(learningLemmas)
        let tokens = EstonianTokenizer.tokenize(text.body)
        var known = 0
        var words = 0
        var predicted = Set<Int>()
        for token in tokens where token.isWord {
            words += 1
            if matchesFamiliar(token: token, lemmas: knownLemmas, lexicon: lexicon) {
                known += 1
            } else if matchesFamiliar(token: token, lemmas: recognized, lexicon: lexicon) {
                // Learning words are not "new" — leave unhighlighted, don't count as known %.
            } else {
                predicted.insert(token.index)
            }
        }
        return TextFamiliarityReport(
            tokens: tokens,
            knownCount: known,
            wordCount: words,
            predictedUnknown: predicted
        )
    }

    /// True when the token surface matches a lemma exactly, via lexicon lookup, or short inflection.
    private static func matchesFamiliar(
        token: TextToken,
        lemmas: Set<String>,
        lexicon: LexiconCatalog
    ) -> Bool {
        guard !lemmas.isEmpty else { return false }
        if lemmas.contains(token.normalized) { return true }
        if let entry = lexicon.entry(forSurface: token.surface)
            ?? lexicon.entry(forSurface: token.normalized) {
            let key = EstonianTokenizer.normalize(entry.lemma)
            if lemmas.contains(key) { return true }
        }
        for lemma in lemmas {
            if nearlyMatches(token.normalized, lemma) { return true }
        }
        return false
    }

    private static func nearlyMatches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 3 else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) {
            return abs(a.count - b.count) <= 2
        }
        return false
    }
}
