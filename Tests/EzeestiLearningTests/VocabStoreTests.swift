import XCTest
@testable import EzeestiLearning
@testable import EzeestiCore
import SwiftData

final class VocabStoreTests: XCTestCase {
    @MainActor
    func testFlagAndDue() throws {
        let schema = Schema([VocabCard.self, LexiconWord.self, CachedGloss.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = VocabStore(modelContext: container.mainContext)
        XCTAssertTrue(try store.knownLemmas().isEmpty)
        let card = try store.flagWord(surface: "saiake", contextSentence: "Palun üks saiake.")
        XCTAssertEqual(card.familiarity, .learning)
        XCTAssertTrue(try store.knownLemmas().isEmpty)
        let due = try store.dueCards()
        XCTAssertTrue(due.contains(where: { $0.lemma == "saiake" }))
    }

    @MainActor
    func testLexiconSeedIntoSQLite() throws {
        let schema = Schema([VocabCard.self, LexiconWord.self, CachedGloss.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = VocabStore(modelContext: container.mainContext)
        let count = try store.seedLexiconFromBundleIfNeeded()
        XCTAssertGreaterThanOrEqual(count, 1000)
        XCTAssertGreaterThanOrEqual(try store.lexiconCount(), 1000)
        // Progress table still empty — lexicon ≠ known.
        XCTAssertTrue(try store.knownLemmas().isEmpty)
    }

    @MainActor
    func testCachedGlossPersists() throws {
        let schema = Schema([VocabCard.self, LexiconWord.self, CachedGloss.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = VocabStore(modelContext: container.mainContext)
        try store.saveGloss(forSurface: "värsket", glossEnglish: "fresh", source: "estllm")
        XCTAssertEqual(try store.cachedGloss(forSurface: "Värsket"), "fresh")
    }

    @MainActor
    func testMarkKnownWithBackoffSchedulesFutureDue() throws {
        let schema = Schema([VocabCard.self, LexiconWord.self, CachedGloss.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = VocabStore(modelContext: container.mainContext)
        let now = Date()

        _ = try store.flagWord(surface: "kohvi", contextSentence: "Ma joon kohvi.")
        try store.markKnownWithBackoff(["kohvi", "piima"], now: now)

        let known = try store.knownLemmas()
        XCTAssertTrue(known.contains("kohvi"))
        XCTAssertTrue(known.contains("piima"))
        XCTAssertFalse(try store.dueCards(now: now).contains(where: { $0.lemma == "kohvi" }))

        let later = now.addingTimeInterval(2 * 86_400)
        XCTAssertTrue(try store.dueCards(now: later).contains(where: { $0.lemma == "kohvi" }))

        LexiconCatalog.shared.loadBundledIfNeeded()
        let targets = LearnerProgress.targetLemmasForPassage(
            workingLevel: .a1,
            knownLemmas: known,
            limit: 20
        )
        XCTAssertFalse(targets.contains(where: { EstonianTokenizer.normalize($0.lemma) == "kohvi" }))
        XCTAssertFalse(targets.contains(where: { EstonianTokenizer.normalize($0.lemma) == "piima" }))
    }

    @MainActor
    func testReviewSuccessDoublesInterval() throws {
        let schema = Schema([VocabCard.self, LexiconWord.self, CachedGloss.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = VocabStore(modelContext: container.mainContext)
        let now = Date()
        try store.markKnownWithBackoff(["tee"], now: now)
        let card = try XCTUnwrap(store.card(forSurface: "tee"))
        XCTAssertEqual(card.scheduledDays, 1, accuracy: 0.001)

        try store.recordReviewSuccess(card, now: now)
        XCTAssertEqual(card.scheduledDays, 2, accuracy: 0.001)
        XCTAssertEqual(card.familiarity, .known)
    }

    @MainActor
    func testMarkLearningDueSoonResetsKnown() throws {
        let schema = Schema([VocabCard.self, LexiconWord.self, CachedGloss.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = VocabStore(modelContext: container.mainContext)
        let now = Date()
        try store.markKnownWithBackoff(["leib"], now: now)
        try store.markLearningDueSoon(["leib"], now: now)
        let card = try XCTUnwrap(store.card(forSurface: "leib"))
        XCTAssertEqual(card.familiarity, .learning)
        XCTAssertTrue(try store.dueCards(now: now).contains(where: { $0.lemma == "leib" }))
    }

    @MainActor
    func testResetProgressClearsCardsKeepsGlosses() throws {
        let schema = Schema([VocabCard.self, LexiconWord.self, CachedGloss.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = VocabStore(modelContext: container.mainContext)
        try store.markKnownWithBackoff(["kohvi"])
        _ = try store.flagWord(surface: "tee", contextSentence: "Ma joon teed.")
        try store.saveGloss(forSurface: "kohvi", glossEnglish: "coffee", source: "test")

        try store.resetProgress()

        XCTAssertTrue(try store.knownLemmas().isEmpty)
        XCTAssertTrue(try store.fetchAll().isEmpty)
        XCTAssertEqual(try store.cachedGloss(forSurface: "kohvi"), "coffee")
    }
}
