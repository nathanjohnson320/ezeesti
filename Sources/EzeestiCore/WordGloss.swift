import Foundation
import os

/// Offline English glosses for common surfaces (MVP). Lexicon itself has no translations.
public enum WordGlossCatalog {
    private struct State: Sendable {
        var map: [String: String] = [:]
        var loaded = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Loads the bundled gloss map if needed. Failures leave the catalog unloaded so a later call can retry.
    public static func loadBundledIfNeeded() {
        if state.withLock(\.loaded) { return }
        do {
            try loadBundled()
        } catch {
            // Keep unloaded; callers that need hard failure should use `loadBundled()`.
        }
    }

    /// Loads the bundled gloss map, throwing on missing/invalid resources.
    public static func loadBundled() throws {
        try state.withLock { state in
            guard !state.loaded else { return }
            let url =
                Bundle.module.url(forResource: "word-glosses", withExtension: "json", subdirectory: "Lexicon")
                ?? Bundle.module.url(forResource: "word-glosses", withExtension: "json")
            guard let url else {
                throw EzeestiError.invalidLessonData("Missing word-glosses.json")
            }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            var normalized: [String: String] = [:]
            normalized.reserveCapacity(decoded.count)
            for (k, v) in decoded {
                normalized[EstonianTokenizer.normalize(k)] = v
            }
            state.map = normalized
            state.loaded = true
        }
    }

    public static func gloss(forSurface surface: String) -> String? {
        loadBundledIfNeeded()
        let key = EstonianTokenizer.normalize(surface)
        return state.withLock { $0.map[key] }
    }
}

/// UI lookup payload for a tapped token in a graded text.
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
