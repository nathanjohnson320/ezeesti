import Foundation

public struct LexiconEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { lemma }
    public let lemma: String
    public let cefr: CEFRLevel?
    public let pos: String
    public let freqRank: Int?

    public init(lemma: String, cefr: CEFRLevel?, pos: String, freqRank: Int?) {
        self.lemma = lemma
        self.cefr = cefr
        self.pos = pos
        self.freqRank = freqRank
    }

    private enum CodingKeys: String, CodingKey {
        case lemma, cefr, pos, freqRank
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lemma = try c.decode(String.self, forKey: .lemma)
        if let raw = try c.decodeIfPresent(String.self, forKey: .cefr) {
            cefr = CEFRLevel(rawValue: raw)
        } else {
            cefr = nil
        }
        pos = try c.decodeIfPresent(String.self, forKey: .pos) ?? ""
        freqRank = try c.decodeIfPresent(Int.self, forKey: .freqRank)
    }
}

public struct LexiconFile: Codable, Sendable {
    public let source: String
    public let license: String
    public let attribution: [String]
    public let selection: String
    public let count: Int
    public let cefrCounts: [String: Int]
    public let words: [LexiconEntry]
}

public final class LexiconCatalog: @unchecked Sendable {
    public static let shared = LexiconCatalog()

    private var entriesByLemma: [String: LexiconEntry] = [:]
    private(set) public var file: LexiconFile?
    private var loaded = false

    private init() {}

    public func loadBundledIfNeeded() {
        guard !loaded else { return }
        loaded = true

        let url =
            Bundle.module.url(forResource: "estonian-top10k", withExtension: "json", subdirectory: "Lexicon")
            ?? Bundle.module.url(forResource: "estonian-top10k", withExtension: "json")

        guard let url,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(LexiconFile.self, from: data) else {
            return
        }
        self.file = file
        var map: [String: LexiconEntry] = [:]
        map.reserveCapacity(file.words.count)
        for entry in file.words {
            map[EstonianTokenizer.normalize(entry.lemma)] = entry
        }
        entriesByLemma = map
    }

    public var count: Int { entriesByLemma.count }

    public func entry(forSurface surface: String) -> LexiconEntry? {
        loadBundledIfNeeded()
        return entriesByLemma[EstonianTokenizer.normalize(surface)]
    }

    public func lemmas(at cefr: CEFRLevel) -> [LexiconEntry] {
        loadBundledIfNeeded()
        return entriesByLemma.values.filter { $0.cefr == cefr }.sorted { $0.lemma < $1.lemma }
    }
}
