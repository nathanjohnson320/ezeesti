import Foundation

public enum VocabFamiliarity: String, Codable, Sendable, CaseIterable {
    case unknown
    case learning
    case known
}

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

public struct TextFamiliarityReport: Sendable {
    public let tokens: [TextToken]
    public let knownCount: Int
    public let wordCount: Int
    public let predictedUnknown: Set<Int>

    public var knownRatio: Double {
        guard wordCount > 0 else { return 1 }
        return Double(knownCount) / Double(wordCount)
    }

    public var percentKnown: Int {
        Int((knownRatio * 100).rounded())
    }
}

public enum GradedTextCatalog {
    public static func loadBundled() throws -> [GradedText] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Texts")
            ?? Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil)
            ?? []

        let textURLs = urls.filter { $0.lastPathComponent.hasPrefix("text-") }
        let decoder = JSONDecoder()
        var texts: [GradedText] = []
        for url in textURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            texts.append(try decoder.decode(GradedText.self, from: Data(contentsOf: url)))
        }
        if texts.isEmpty {
            texts = Self.fallbackTexts
        }
        return texts
    }

    public static func loadSeedKnownLemmas() -> Set<String> {
        let candidates = [
            Bundle.module.url(forResource: "a1-seed-known", withExtension: "json", subdirectory: "Texts"),
            Bundle.module.url(forResource: "a1-seed-known", withExtension: "json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first,
              let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([String].self, from: data) else {
            return Set(fallbackSeed)
        }
        return Set(words.map { EstonianTokenizer.normalize($0) })
    }

    public static func familiarity(
        text: GradedText,
        knownLemmas: Set<String>
    ) -> TextFamiliarityReport {
        let tokens = EstonianTokenizer.tokenize(text.body)
        var known = 0
        var words = 0
        var predicted = Set<Int>()
        for token in tokens where token.isWord {
            words += 1
            if knownLemmas.contains(token.normalized) {
                known += 1
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

    public static let fallbackSeed: [String] = [
        "ma", "sa", "ta", "me", "te", "nad", "ja", "on", "ei", "jah",
        "tere", "palun", "aitäh", "hommikust", "head", "aega",
        "lähen", "tahan", "teen", "söön", "joon", "olen",
        "see", "see", "seal", "siin", "nüüd", "täna", "homme",
        "suur", "väike", "hea", "ilus", "uus",
        "maja", "kool", "pood", "kodu", "töö", "auto", "buss",
        "kohv", "tee", "vesi", "leib", "piim",
        "üks", "kaks", "kolm", "neli", "viis",
    ]

    public static let fallbackTexts: [GradedText] = [
        GradedText(
            id: "text-a1-hommik",
            title: "Hommik kodus",
            cefr: .a1,
            body: "Tere hommikust! Ma joon kohvi ja söön leiba. Täna ma lähen poodi. Ma tahan piima ja teed.",
            glossEnglish: "Good morning! I drink coffee and eat bread. Today I'm going to the store. I want milk and tea.",
            focusWords: ["joon", "söön", "piima", "teed"]
        ),
        GradedText(
            id: "text-a2-linn",
            title: "Linnas",
            cefr: .a2,
            body: "Homme ma lähen linna. Ma sõidan bussiga kooli juurde. Pärast tunde ma ostan poest värsket leiba. Õhtul ma lähen koju ja joon teed.",
            glossEnglish: "Tomorrow I'm going to town. I take the bus near the school. After classes I buy fresh bread at the store. In the evening I go home and drink tea.",
            focusWords: ["sõidan", "bussiga", "ostan", "värsket", "õhtul"]
        ),
    ]
}
