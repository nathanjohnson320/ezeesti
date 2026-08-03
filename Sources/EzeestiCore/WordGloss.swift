import Foundation

/// Offline English glosses for common surfaces (MVP). Lexicon itself has no translations.
public enum WordGlossCatalog {
    private static var map: [String: String] = [:]
    private static var loaded = false

    public static func loadBundledIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url =
            Bundle.module.url(forResource: "word-glosses", withExtension: "json", subdirectory: "Lexicon")
            ?? Bundle.module.url(forResource: "word-glosses", withExtension: "json")
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(decoded.count)
        for (k, v) in decoded {
            normalized[EstonianTokenizer.normalize(k)] = v
        }
        map = normalized
    }

    public static func gloss(forSurface surface: String) -> String? {
        loadBundledIfNeeded()
        return map[EstonianTokenizer.normalize(surface)]
    }
}

public struct WordLookup: Sendable, Equatable {
    public let surface: String
    public let lemma: String
    public let glossEnglish: String?
    public let cefr: CEFRLevel?
    public let pos: String
    public let learnerStatus: VocabFamiliarity?
    public let tokenIndex: Int

    public init(
        surface: String,
        lemma: String,
        glossEnglish: String?,
        cefr: CEFRLevel?,
        pos: String,
        learnerStatus: VocabFamiliarity?,
        tokenIndex: Int
    ) {
        self.surface = surface
        self.lemma = lemma
        self.glossEnglish = glossEnglish
        self.cefr = cefr
        self.pos = pos
        self.learnerStatus = learnerStatus
        self.tokenIndex = tokenIndex
    }

    public var subtitle: String {
        var parts: [String] = []
        if let cefr { parts.append(cefr.rawValue) }
        if !pos.isEmpty { parts.append(pos) }
        if let learnerStatus {
            parts.append(learnerStatus.rawValue)
        } else {
            parts.append("new")
        }
        return parts.joined(separator: " · ")
    }
}
