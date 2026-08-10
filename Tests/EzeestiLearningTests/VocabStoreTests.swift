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
    func testMarkKnownImmediateExcludesFromDueAndTargets() throws {
        let schema = Schema([VocabCard.self, LexiconWord.self, CachedGloss.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let store = VocabStore(modelContext: container.mainContext)

        _ = try store.flagWord(surface: "kohvi", contextSentence: "Ma joon kohvi.")
        try store.markKnownImmediate(["kohvi", "piima"])

        let known = try store.knownLemmas()
        XCTAssertTrue(known.contains("kohvi"))
        XCTAssertTrue(known.contains("piima"))
        XCTAssertFalse(try store.dueCards().contains(where: { $0.lemma == "kohvi" }))

        LexiconCatalog.shared.loadBundledIfNeeded()
        let targets = LearnerProgress.targetLemmasForPassage(
            workingLevel: .a1,
            knownLemmas: known,
            limit: 20
        )
        XCTAssertFalse(targets.contains(where: { EstonianTokenizer.normalize($0.lemma) == "kohvi" }))
        XCTAssertFalse(targets.contains(where: { EstonianTokenizer.normalize($0.lemma) == "piima" }))
    }
}
