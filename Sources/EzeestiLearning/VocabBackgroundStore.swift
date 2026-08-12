import Foundation
import SwiftData
import EzeestiCore

/// Background SwiftData work (lexicon seed / bulk cleanup) on a dedicated model context.
///
/// UI-facing card/gloss reads stay on `VocabStore`'s main-actor context so `@Model`
/// instances are not passed across actors.
@ModelActor
public actor VocabBackgroundStore {
    /// Bundled top-10k seed is considered complete at this row count.
    private static let minimumSeededLexiconCount = 9_000

    /// Import bundled top-10k JSON into SQLite once (dictionary catalog, not “known”).
    @discardableResult
    public func seedLexiconFromBundleIfNeeded() throws -> Int {
        let existingCount = try modelContext.fetchCount(FetchDescriptor<LexiconWord>())
        if existingCount >= Self.minimumSeededLexiconCount {
            return existingCount
        }

        LexiconCatalog.shared.loadBundledIfNeeded()
        guard let file = LexiconCatalog.shared.file else {
            throw EzeestiError.invalidLessonData("Lexicon bundle unavailable for seeding")
        }

        try modelContext.delete(model: LexiconWord.self)

        for entry in file.words {
            let lemma = EstonianTokenizer.normalize(entry.lemma)
            modelContext.insert(
                LexiconWord(
                    lemma: lemma,
                    cefr: entry.cefr,
                    pos: entry.pos ?? "",
                    freqRank: entry.freqRank,
                    source: file.source
                )
            )
        }
        try modelContext.save()
        return file.words.count
    }

    /// One-time cleanup: early builds auto-inserted an A1 word list as "known".
    /// - Returns: `true` when the cleanup ran (caller should persist the defaults flag).
    @discardableResult
    public func clearAssumedSeedVocabularyIfNeeded(alreadyCleared: Bool) throws -> Bool {
        guard !alreadyCleared else { return false }

        let seed = GradedTextCatalog.loadSeedKnownLemmas()
        let knownRaw = VocabFamiliarity.known.rawValue
        let candidates = try modelContext.fetch(
            FetchDescriptor<VocabCard>(
                predicate: #Predicate { $0.familiarityRaw == knownRaw }
            )
        )
        for card in candidates {
            let looksLikeSeed =
                seed.contains(card.lemma)
                && card.contextSentence.isEmpty
                && card.lastReview == nil
                && card.scheduledDays >= 365
            if looksLikeSeed {
                modelContext.delete(card)
            }
        }
        try modelContext.save()
        return true
    }
}
