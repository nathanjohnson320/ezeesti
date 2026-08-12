import Foundation
import os

/// One lemma from the bundled Estonian frequency/CEFR lexicon.
public struct LexiconEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { lemma }
    public let lemma: String
    public let cefr: CEFRLevel?
    /// Coarse POS tags from the source lexicon (comma-separated). `nil` when unknown.
    public let pos: String?
    public let freqRank: Int?
    /// Nouns, verbs, and adjectives — good for building a short reading scene.
    public let isPassageFocusCandidate: Bool

    public init(lemma: String, cefr: CEFRLevel?, pos: String?, freqRank: Int?) {
        self.lemma = lemma
        self.cefr = cefr
        self.pos = pos
        self.freqRank = freqRank
        self.isPassageFocusCandidate = Self.focusCandidate(pos: pos)
    }

    private static func focusCandidate(pos: String?) -> Bool {
        guard let pos, !pos.isEmpty else { return false }
        let tags = pos.lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let primary = tags.first else { return false }
        return primary == "s" || primary == "v" || primary == "adj" || primary == "adjg"
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
        let decodedPOS = try c.decodeIfPresent(String.self, forKey: .pos)
        pos = decodedPOS?.isEmpty == true ? nil : decodedPOS
        freqRank = try c.decodeIfPresent(Int.self, forKey: .freqRank)
        isPassageFocusCandidate = Self.focusCandidate(pos: pos)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lemma, forKey: .lemma)
        try c.encodeIfPresent(cefr?.rawValue, forKey: .cefr)
        try c.encodeIfPresent(pos, forKey: .pos)
        try c.encodeIfPresent(freqRank, forKey: .freqRank)
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

/// Process-wide bundled lexicon. Load is idempotent; failed loads leave the catalog unloaded so callers can retry.
///
/// Mutable load state is guarded by `OSAllocatedUnfairLock`. After a successful load the maps are treated as
/// an immutable snapshot for the process lifetime.
public final class LexiconCatalog: @unchecked Sendable {
    public static let shared = LexiconCatalog()

    private struct State: Sendable {
        var entriesByLemma: [String: LexiconEntry] = [:]
        var entriesByCEFR: [CEFRLevel: [LexiconEntry]] = [:]
        var file: LexiconFile?
        var loaded = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    /// Loads the bundled lexicon if needed. Failures leave `loaded == false` so a later call can retry.
    public func loadBundledIfNeeded() {
        if state.withLock(\.loaded) { return }
        do {
            try loadBundled()
        } catch {
            // Keep unloaded; callers that need hard failure should use `loadBundled()`.
        }
    }

    /// Loads the bundled lexicon, throwing on missing/invalid resources.
    public func loadBundled() throws {
        try state.withLock { state in
            guard !state.loaded else { return }

            let url =
                Bundle.module.url(forResource: "estonian-top10k", withExtension: "json", subdirectory: "Lexicon")
                ?? Bundle.module.url(forResource: "estonian-top10k", withExtension: "json")

            guard let url else {
                throw EzeestiError.invalidLessonData("Missing estonian-top10k.json")
            }

            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(LexiconFile.self, from: data)

            var map: [String: LexiconEntry] = [:]
            map.reserveCapacity(file.words.count)
            var byCEFR: [CEFRLevel: [LexiconEntry]] = [:]
            for entry in file.words {
                map[EstonianTokenizer.normalize(entry.lemma)] = entry
                if let cefr = entry.cefr {
                    byCEFR[cefr, default: []].append(entry)
                }
            }
            for level in byCEFR.keys {
                byCEFR[level]?.sort { $0.lemma < $1.lemma }
            }

            state.file = file
            state.entriesByLemma = map
            state.entriesByCEFR = byCEFR
            state.loaded = true
        }
    }

    public var file: LexiconFile? {
        state.withLock(\.file)
    }

    public var count: Int {
        state.withLock { $0.entriesByLemma.count }
    }

    /// Returns the lexicon entry for `surface`, loading the bundle on first use.
    public func entry(forSurface surface: String) -> LexiconEntry? {
        loadBundledIfNeeded()
        let key = EstonianTokenizer.normalize(surface)
        return state.withLock { $0.entriesByLemma[key] }
    }

    /// Lemmas tagged at `cefr`, sorted by lemma. Loads the bundle on first use.
    public func lemmas(at cefr: CEFRLevel) -> [LexiconEntry] {
        loadBundledIfNeeded()
        return state.withLock { $0.entriesByCEFR[cefr] ?? [] }
    }
}
