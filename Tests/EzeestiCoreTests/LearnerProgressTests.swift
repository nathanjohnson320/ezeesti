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

    func testShouldGenerateWhenTextsTooFamiliar() {
        let texts = [
            GradedText(
                id: "easy",
                title: "Easy",
                cefr: .a1,
                body: "Ma joon kohvi.",
                glossEnglish: "I drink coffee.",
                focusWords: ["joon"]
            ),
        ]
        let known: Set<String> = ["ma", "joon", "kohvi"]
        XCTAssertTrue(
            LearnerProgress.shouldGenerateNewText(
                from: texts,
                workingLevel: .a1,
                knownLemmas: known
            )
        )
        XCTAssertFalse(
            LearnerProgress.shouldGenerateNewText(
                from: texts,
                workingLevel: .a1,
                knownLemmas: ["ma"]
            )
        )
    }

    func testTargetLemmasPreferUnknownHighFrequency() {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let targets = LearnerProgress.targetLemmasForPassage(
            workingLevel: .a1,
            knownLemmas: ["ma", "ja", "on", "ei"],
            alreadyFocused: ["isa"],
            limit: 5
        )
        XCTAssertFalse(targets.isEmpty)
        XCTAssertFalse(targets.contains(where: { EstonianTokenizer.normalize($0.lemma) == "ma" }))
        XCTAssertFalse(targets.contains(where: { EstonianTokenizer.normalize($0.lemma) == "isa" }))
        XCTAssertTrue(targets.allSatisfy(\.isPassageFocusCandidate))
    }

    func testTargetLemmasSkipFunctionWords() {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let targets = LearnerProgress.targetLemmasForPassage(
            workingLevel: .a1,
            knownLemmas: ["ma", "ja", "on", "ei"],
            limit: 8
        )
        let lemmas = Set(targets.map { EstonianTokenizer.normalize($0.lemma) })
        XCTAssertFalse(lemmas.contains("ära"))
        XCTAssertFalse(lemmas.contains("kõik"))
        XCTAssertFalse(lemmas.contains("kuidas"))
        XCTAssertTrue(targets.allSatisfy(\.isPassageFocusCandidate))
    }

    func testTargetLemmasSkipImmediatelyKnown() {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let known: Set<String> = ["ma", "ja", "on", "ei", "tere", "hommik"]
        let targets = LearnerProgress.targetLemmasForPassage(
            workingLevel: .a1,
            knownLemmas: known,
            limit: 10
        )
        for entry in targets {
            XCTAssertFalse(known.contains(EstonianTokenizer.normalize(entry.lemma)))
        }
    }
}
