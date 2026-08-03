import XCTest
@testable import EzeestiCore

final class LearnerProgressTests: XCTestCase {
    func testStartsAtA1WhenEmpty() {
        let progress = LearnerProgress.estimate(
            knownLemmas: [],
            learningCount: 0,
            dueCount: 0,
            lexiconByLevel: [
                .a1: ["ma", "ja", "on", "tere"],
                .a2: ["buss", "homme"],
            ]
        )
        XCTAssertEqual(progress.workingLevel, .a1)
        XCTAssertTrue(progress.levelLabel.contains("A1"))
    }

    func testAdvancesWhenA1MostlyKnown() {
        let a1 = Set(["ma", "ja", "on", "tere", "kohv", "tee", "pood", "kodu", "hea", "väike"])
        let progress = LearnerProgress.estimate(
            knownLemmas: a1,
            learningCount: 2,
            dueCount: 1,
            lexiconByLevel: [
                .a1: a1,
                .a2: ["buss", "homme", "saiake"],
            ],
            mastery: 0.7
        )
        XCTAssertEqual(progress.workingLevel, .a2)
        XCTAssertEqual(progress.knownCount, a1.count)
        XCTAssertEqual(progress.dueCount, 1)
    }

    func testWordGlossCatalogLoadsBundled() {
        WordGlossCatalog.loadBundledIfNeeded()
        XCTAssertEqual(WordGlossCatalog.gloss(forSurface: "saiake"), "pastry / bun")
        XCTAssertEqual(WordGlossCatalog.gloss(forSurface: "Joon"), "I drink")
    }

    func testRecommendPrefersWorkingLevel() {
        let texts = [
            GradedText(id: "a1", title: "A1", cefr: .a1, body: "Ma joon kohvi.", glossEnglish: "I drink coffee."),
            GradedText(id: "a2", title: "A2", cefr: .a2, body: "Homme ma lähen linna.", glossEnglish: "Tomorrow I go to town."),
        ]
        let pick = LearnerProgress.recommendText(
            from: texts,
            workingLevel: .a1,
            knownLemmas: ["ma"]
        )
        XCTAssertEqual(pick?.id, "a1")
    }
}
