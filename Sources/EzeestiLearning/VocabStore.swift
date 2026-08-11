import Foundation
import SwiftData
import EzeestiCore

/// Static dictionary row (not learner progress). Seeded once from bundled top-10k JSON into SwiftData/SQLite.
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
        LexiconEntry(lemma: lemma, cefr: cefr, pos: pos, freqRank: freqRank)
    }

    public init(lemma: String, cefr: CEFRLevel?, pos: String, freqRank: Int?, source: String = "estonian-top10k") {
        self.lemma = lemma
        self.cefrRaw = cefr?.rawValue
        self.pos = pos
        self.freqRank = freqRank
        self.source = source
    }
}

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

    public var familiarity: VocabFamiliarity {
        get { VocabFamiliarity(rawValue: familiarityRaw) ?? .learning }
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

@MainActor
public final class VocabStore: ObservableObject {
    public let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
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
    public func seedLexiconFromBundleIfNeeded() throws -> Int {
        let existing = try modelContext.fetch(FetchDescriptor<LexiconWord>())
        if existing.count >= 9000 {
            return existing.count
        }

        LexiconCatalog.shared.loadBundledIfNeeded()
        guard let file = LexiconCatalog.shared.file else { return existing.count }

        for row in existing {
            modelContext.delete(row)
        }

        for entry in file.words {
            let lemma = EstonianTokenizer.normalize(entry.lemma)
            modelContext.insert(
                LexiconWord(
                    lemma: lemma,
                    cefr: entry.cefr,
                    pos: entry.pos,
                    freqRank: entry.freqRank,
                    source: file.source
                )
            )
        }
        try modelContext.save()
        return file.words.count
    }

    public func lexiconCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<LexiconWord>())
    }

    public func lexiconEntry(forSurface surface: String) throws -> LexiconEntry? {
        let lemma = EstonianTokenizer.normalize(surface)
        var descriptor = FetchDescriptor<LexiconWord>(
            predicate: #Predicate { $0.lemma == lemma }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.asEntry
    }

    /// One-time cleanup: early builds auto-inserted an A1 word list as "known".
    public func clearAssumedSeedVocabularyIfNeeded() throws {
        let key = "ezeesti.clearedAssumedSeedVocab.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let seed = GradedTextCatalog.loadSeedKnownLemmas()
        let all = try fetchAll()
        for card in all {
            let looksLikeSeed =
                card.familiarity == .known
                && seed.contains(card.lemma)
                && card.contextSentence.isEmpty
                && card.lastReview == nil
                && card.scheduledDays >= 365
            if looksLikeSeed {
                modelContext.delete(card)
            }
        }
        try modelContext.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    public func fetchAll() throws -> [VocabCard] {
        try modelContext.fetch(FetchDescriptor<VocabCard>(sortBy: [SortDescriptor(\.lemma)]))
    }

    /// Delete all learner vocab cards (known/learning/due). Lexicon and gloss cache stay.
    public func resetProgress() throws {
        for card in try fetchAll() {
            modelContext.delete(card)
        }
        try modelContext.save()
    }

    public func knownLemmas() throws -> Set<String> {
        Set(try fetchAll().filter { $0.familiarity == .known }.map(\.lemma))
    }

    public func card(forSurface surface: String) throws -> VocabCard? {
        let lemma = EstonianTokenizer.normalize(surface)
        return try fetchAll().first(where: { $0.lemma == lemma })
    }

    public func cachedGloss(forSurface surface: String) throws -> String? {
        let lemma = EstonianTokenizer.normalize(surface)
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
        guard !gloss.isEmpty else { return }

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
        let all = try fetchAll()
        let known = Set(all.filter { $0.familiarity == .known }.map(\.lemma))
        let learning = all.filter { $0.familiarity == .learning }.count
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
        let due = try fetchAll().filter { $0.due <= now }
        return Array(due.sorted { $0.due < $1.due }.prefix(limit))
    }

    public func dueCount(now: Date = Date()) throws -> Int {
        try dueCards(now: now, limit: 10_000).count
    }

    @discardableResult
    public func flagWord(
        surface: String,
        contextSentence: String,
        glossEnglish: String = ""
    ) throws -> VocabCard {
        let lemma = EstonianTokenizer.normalize(surface)
        if let existing = try fetchAll().first(where: { $0.lemma == lemma }) {
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
        let all = try fetchAll()
        for lemma in lemmas {
            let key = EstonianTokenizer.normalize(lemma)
            if let existing = all.first(where: { $0.lemma == key }), existing.familiarity == .known {
                try recordReviewSuccess(existing, now: now)
                continue
            }

            let card: VocabCard
            if let existing = all.first(where: { $0.lemma == key }) {
                card = existing
            } else {
                card = VocabCard(
                    lemma: key,
                    surfaceForm: lemma,
                    familiarity: .known
                )
                modelContext.insert(card)
            }
            card.familiarity = .known
            card.scheduledDays = ExponentialBackoff.initialIntervalDays
            card.due = ExponentialBackoff.dueDate(from: now, intervalDays: card.scheduledDays)
            card.lastReview = now
            card.reps = max(card.reps, 1)
            card.updatedAt = now
        }
        try modelContext.save()
    }

    /// Flagged or incorrect: keep learning and make due immediately.
    public func markLearningDueSoon(_ lemmas: [String], now: Date = Date()) throws {
        let all = try fetchAll()
        for lemma in lemmas {
            let key = EstonianTokenizer.normalize(lemma)
            let card: VocabCard
            if let existing = all.first(where: { $0.lemma == key }) {
                card = existing
            } else {
                card = VocabCard(
                    lemma: key,
                    surfaceForm: lemma,
                    familiarity: .learning
                )
                modelContext.insert(card)
            }
            card.familiarity = .learning
            card.scheduledDays = ExponentialBackoff.initialIntervalDays
            card.due = now
            card.lapses += 1
            card.lastReview = now
            card.updatedAt = now
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
}
