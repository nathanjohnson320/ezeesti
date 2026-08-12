import Foundation
import Observation
import SwiftData
import EzeestiCore

/// Static dictionary row (not learner progress). Seeded once from bundled top-10k JSON into SwiftData/SQLite.
/// Stored properties stay writable for SwiftData persistence; mutate learner state through `VocabStore`.
@Model
public final class LexiconWord {
    @Attribute(.unique) public var lemma: String
    public var cefrRaw: String?
    public var pos: String
    public var freqRank: Int?
    public var source: String

    public var cefr: CEFRLevel? {
        get { cefrRaw.flatMap(CEFRLevel.init(rawValue:)) }
        set { cefrRaw = newValue?.rawValue }
    }

    public var asEntry: LexiconEntry {
        LexiconEntry(lemma: lemma, cefr: cefr, pos: pos.isEmpty ? nil : pos, freqRank: freqRank)
    }

    public init(lemma: String, cefr: CEFRLevel?, pos: String, freqRank: Int?, source: String = "estonian-top10k") {
        self.lemma = lemma
        self.cefrRaw = cefr?.rawValue
        self.pos = pos
        self.freqRank = freqRank
        self.source = source
    }
}

/// Cached EstLLM / offline English gloss for a lemma.
@Model
public final class CachedGloss {
    @Attribute(.unique) public var lemma: String
    public var glossEnglish: String
    public var source: String
    public var updatedAt: Date

    public init(lemma: String, glossEnglish: String, source: String) {
        self.lemma = lemma
        self.glossEnglish = glossEnglish
        self.source = source
        self.updatedAt = Date()
    }
}

/// Learner SRS card for one lemma (known / learning / due schedule).
@Model
public final class VocabCard {
    @Attribute(.unique) public var lemma: String
    public var surfaceForm: String
    public var contextSentence: String
    public var glossEnglish: String
    public var familiarityRaw: String

    public var stability: Double
    public var difficulty: Double
    public var elapsedDays: Double
    public var scheduledDays: Double
    public var reps: Int
    public var lapses: Int
    public var stateRaw: Int
    public var due: Date
    public var lastReview: Date?
    public var createdAt: Date
    public var updatedAt: Date

    /// Invalid persisted raw values are treated as `.unknown` (not `.learning`) so bad data is visible.
    public var familiarity: VocabFamiliarity {
        get { VocabFamiliarity(rawValue: familiarityRaw) ?? .unknown }
        set { familiarityRaw = newValue.rawValue }
    }

    public init(
        lemma: String,
        surfaceForm: String,
        contextSentence: String = "",
        glossEnglish: String = "",
        familiarity: VocabFamiliarity = .learning
    ) {
        self.lemma = lemma
        self.surfaceForm = surfaceForm
        self.contextSentence = contextSentence
        self.glossEnglish = glossEnglish
        self.familiarityRaw = familiarity.rawValue
        self.stability = 0
        self.difficulty = 0
        self.elapsedDays = 0
        self.scheduledDays = ExponentialBackoff.initialIntervalDays
        self.reps = 0
        self.lapses = 0
        self.stateRaw = 0
        self.due = Date()
        self.lastReview = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// SwiftData-backed vocab / lexicon / gloss store used by `LearningEngine`.
///
/// Interactive card/gloss APIs stay on the main actor (UI holds `@Model` instances).
/// Heavy seed/cleanup runs on `VocabBackgroundStore` (`@ModelActor`).
@Observable
@MainActor
public final class VocabStore {
    private static let clearedAssumedSeedKey = "ezeesti.clearedAssumedSeedVocab.v1"

    private let modelContext: ModelContext
    private let defaults: UserDefaults
    private let background: VocabBackgroundStore

    public init(modelContext: ModelContext, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.defaults = defaults
        self.background = VocabBackgroundStore(modelContainer: modelContext.container)
    }

    public static func makeContainer() throws -> ModelContainer {
        let schema = Schema([VocabCard.self, LexiconWord.self, CachedGloss.self])
        let config = ModelConfiguration(
            "EzeestiStore",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Import bundled top-10k JSON into SQLite once (dictionary catalog, not “known”).
    @discardableResult
    public func seedLexiconFromBundleIfNeeded() async throws -> Int {
        try await background.seedLexiconFromBundleIfNeeded()
    }

    public func lexiconCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<LexiconWord>())
    }

    public func lexiconEntry(forSurface surface: String) throws -> LexiconEntry? {
        let lemma = EstonianTokenizer.normalize(surface)
        guard !lemma.isEmpty else { return nil }
        var descriptor = FetchDescriptor<LexiconWord>(
            predicate: #Predicate { $0.lemma == lemma }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.asEntry
    }

    /// One-time cleanup: early builds auto-inserted an A1 word list as "known".
    public func clearAssumedSeedVocabularyIfNeeded() async throws {
        let alreadyCleared = defaults.bool(forKey: Self.clearedAssumedSeedKey)
        let didClear = try await background.clearAssumedSeedVocabularyIfNeeded(alreadyCleared: alreadyCleared)
        if didClear {
            defaults.set(true, forKey: Self.clearedAssumedSeedKey)
        }
    }

    public func fetchAll() throws -> [VocabCard] {
        try modelContext.fetch(FetchDescriptor<VocabCard>(sortBy: [SortDescriptor(\.lemma)]))
    }

    /// Delete all learner vocab cards (known/learning/due). Lexicon and gloss cache stay.
    public func resetProgress() throws {
        try modelContext.delete(model: VocabCard.self)
        try modelContext.save()
    }

    public func knownLemmas() throws -> Set<String> {
        let knownRaw = VocabFamiliarity.known.rawValue
        let cards = try modelContext.fetch(
            FetchDescriptor<VocabCard>(
                predicate: #Predicate { $0.familiarityRaw == knownRaw }
            )
        )
        return Set(cards.map(\.lemma))
    }

    public func learningLemmas() throws -> Set<String> {
        let learningRaw = VocabFamiliarity.learning.rawValue
        let cards = try modelContext.fetch(
            FetchDescriptor<VocabCard>(
                predicate: #Predicate { $0.familiarityRaw == learningRaw }
            )
        )
        return Set(cards.map(\.lemma))
    }

    public func card(forSurface surface: String) throws -> VocabCard? {
        let lemma = EstonianTokenizer.normalize(surface)
        guard !lemma.isEmpty else { return nil }
        var descriptor = FetchDescriptor<VocabCard>(
            predicate: #Predicate { $0.lemma == lemma }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    public func cachedGloss(forSurface surface: String) throws -> String? {
        let lemma = EstonianTokenizer.normalize(surface)
        guard !lemma.isEmpty else { return nil }
        var descriptor = FetchDescriptor<CachedGloss>(
            predicate: #Predicate { $0.lemma == lemma }
        )
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first,
              !row.glossEnglish.isEmpty else { return nil }
        return row.glossEnglish
    }

    public func saveGloss(
        forSurface surface: String,
        glossEnglish: String,
        source: String
    ) throws {
        let lemma = EstonianTokenizer.normalize(surface)
        let gloss = glossEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lemma.isEmpty else {
            throw EzeestiError.invalidLessonData("Cannot save gloss for empty surface")
        }
        guard !gloss.isEmpty else {
            throw EzeestiError.invalidLessonData("Cannot save empty gloss for \(lemma)")
        }

        var descriptor = FetchDescriptor<CachedGloss>(
            predicate: #Predicate { $0.lemma == lemma }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.glossEnglish = gloss
            existing.source = source
            existing.updatedAt = Date()
        } else {
            modelContext.insert(CachedGloss(lemma: lemma, glossEnglish: gloss, source: source))
        }

        // Keep cards in sync when the learner already flagged this word.
        if let card = try card(forSurface: surface), card.glossEnglish.isEmpty {
            card.glossEnglish = gloss
            card.updatedAt = Date()
        }
        try modelContext.save()
    }

    public func progressSnapshot(now: Date = Date()) throws -> LearnerProgress {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let known = try knownLemmas()
        let learning = try learningLemmas().count
        let due = try dueCount(now: now)

        var byLevel: [CEFRLevel: Set<String>] = [:]
        for level in CEFRLevel.allCases {
            byLevel[level] = Set(
                LexiconCatalog.shared.lemmas(at: level).map { EstonianTokenizer.normalize($0.lemma) }
            )
        }

        return LearnerProgress.estimate(
            knownLemmas: known,
            learningCount: learning,
            dueCount: due,
            lexiconByLevel: byLevel
        )
    }

    public func dueCards(now: Date = Date(), limit: Int = 20) throws -> [VocabCard] {
        var descriptor = FetchDescriptor<VocabCard>(
            predicate: #Predicate { $0.due <= now },
            sortBy: [SortDescriptor(\.due)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try modelContext.fetch(descriptor)
    }

    public func dueCount(now: Date = Date()) throws -> Int {
        try modelContext.fetchCount(
            FetchDescriptor<VocabCard>(
                predicate: #Predicate { $0.due <= now }
            )
        )
    }

    @discardableResult
    public func flagWord(
        surface: String,
        contextSentence: String,
        glossEnglish: String = ""
    ) throws -> VocabCard {
        let lemma = EstonianTokenizer.normalize(surface)
        guard !lemma.isEmpty else {
            throw EzeestiError.invalidLessonData("Cannot flag empty surface")
        }

        if let existing = try card(forSurface: surface) {
            existing.surfaceForm = surface
            existing.contextSentence = contextSentence
            existing.familiarity = .learning
            existing.scheduledDays = ExponentialBackoff.initialIntervalDays
            existing.due = Date()
            existing.updatedAt = Date()
            if !glossEnglish.isEmpty, existing.glossEnglish.isEmpty {
                existing.glossEnglish = glossEnglish
            }
            try modelContext.save()
            return existing
        }

        let card = VocabCard(
            lemma: lemma,
            surfaceForm: surface,
            contextSentence: contextSentence,
            glossEnglish: glossEnglish,
            familiarity: .learning
        )
        modelContext.insert(card)
        try modelContext.save()
        return card
    }

    /// Correct read-aloud of an unflagged word: mark known and schedule exponential review.
    public func markKnownWithBackoff(_ lemmas: [String], now: Date = Date()) throws {
        let keys = normalizedUniqueKeys(lemmas)
        guard !keys.isEmpty else {
            throw EzeestiError.invalidLessonData("No lemmas to mark known")
        }

        for key in keys {
            if let existing = try card(forSurface: key), existing.familiarity == .known {
                try recordReviewSuccess(existing, now: now)
                continue
            }

            let target: VocabCard
            if let existing = try card(forSurface: key) {
                target = existing
            } else {
                target = VocabCard(
                    lemma: key,
                    surfaceForm: key,
                    familiarity: .known
                )
                modelContext.insert(target)
            }
            target.familiarity = .known
            target.scheduledDays = ExponentialBackoff.initialIntervalDays
            target.due = ExponentialBackoff.dueDate(from: now, intervalDays: target.scheduledDays)
            target.lastReview = now
            target.reps = max(target.reps, 1)
            target.updatedAt = now
        }
        try modelContext.save()
    }

    /// Flagged or incorrect: keep learning and make due immediately.
    public func markLearningDueSoon(_ lemmas: [String], now: Date = Date()) throws {
        let keys = normalizedUniqueKeys(lemmas)
        guard !keys.isEmpty else {
            throw EzeestiError.invalidLessonData("No lemmas to mark learning")
        }

        for key in keys {
            let target: VocabCard
            if let existing = try card(forSurface: key) {
                target = existing
            } else {
                target = VocabCard(
                    lemma: key,
                    surfaceForm: key,
                    familiarity: .learning
                )
                modelContext.insert(target)
            }
            target.familiarity = .learning
            target.scheduledDays = ExponentialBackoff.initialIntervalDays
            target.due = now
            target.lapses += 1
            target.lastReview = now
            target.updatedAt = now
        }
        try modelContext.save()
    }

    public func recordReviewSuccess(_ card: VocabCard, now: Date = Date()) throws {
        let next = ExponentialBackoff.nextSuccessInterval(currentDays: card.scheduledDays)
        card.familiarity = .known
        card.scheduledDays = next
        card.due = ExponentialBackoff.dueDate(from: now, intervalDays: next)
        card.reps += 1
        card.lastReview = now
        card.updatedAt = now
        try modelContext.save()
    }

    private func normalizedUniqueKeys(_ lemmas: [String]) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for lemma in lemmas {
            let key = EstonianTokenizer.normalize(lemma)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            keys.append(key)
        }
        return keys
    }
}
