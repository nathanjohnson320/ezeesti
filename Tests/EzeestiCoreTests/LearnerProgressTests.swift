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

    func testTargetLemmasPreferDueFirst() {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let targets = LearnerProgress.targetLemmasForPassage(
            workingLevel: .a1,
            knownLemmas: ["ma", "ja", "on", "ei", "tere"],
            dueLemmas: ["tere"],
            limit: 1
        )
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(EstonianTokenizer.normalize(targets[0].lemma), "tere")
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

    func testWordsWorkingLevelCapsAtB2() {
        let progress = LearnerProgress(
            knownCount: 10,
            learningCount: 0,
            dueCount: 0,
            workingLevel: .c1,
            levelLabel: "C1",
            coverageByLevel: [:],
            knownByLevel: [:],
            lexiconByLevel: [:]
        )
        XCTAssertEqual(LearnerProgress.wordsWorkingLevel(from: progress), .b2)
    }

    func testTutorTargetsOnlyKnownOrLearning() {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let known: Set<String> = ["ema", "isa", "ma", "ja", "on"]
        let targets = LearnerProgress.targetLemmasForTutor(
            workingLevel: .a1,
            knownLemmas: known,
            learningLemmas: ["tere"],
            dueLemmas: ["tere"],
            limit: 3
        )
        XCTAssertFalse(targets.isEmpty)
        for entry in targets {
            let key = EstonianTokenizer.normalize(entry.lemma)
            XCTAssertTrue(known.contains(key) || key == "tere")
        }
    }

    func testTutorReturnsEmptyWithoutVocab() {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let targets = LearnerProgress.targetLemmasForTutor(
            workingLevel: .a1,
            knownLemmas: [],
            learningLemmas: [],
            limit: 3
        )
        XCTAssertTrue(targets.isEmpty)
    }

    func testTutorPrefersWordsOnlyLemmasOverAlreadySpokenDue() {
        LexiconCatalog.shared.loadBundledIfNeeded()
        // "ema" known from Words but never spoken in Tutor; "mees" is due/learning but already spoken.
        let targets = LearnerProgress.targetLemmasForTutor(
            workingLevel: .a1,
            knownLemmas: ["ema", "mees"],
            learningLemmas: ["mees"],
            dueLemmas: ["mees"],
            tutorPracticedLemmas: ["mees"],
            preferDueFirst: false,
            limit: 1
        )
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(EstonianTokenizer.normalize(targets[0].lemma), "ema")
    }

    func testTutorPreferDueFirstHonorsReview() {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let targets = LearnerProgress.targetLemmasForTutor(
            workingLevel: .a1,
            knownLemmas: ["ema", "mees"],
            learningLemmas: ["mees"],
            dueLemmas: ["mees"],
            tutorPracticedLemmas: ["mees"],
            preferDueFirst: true,
            limit: 1
        )
        XCTAssertEqual(EstonianTokenizer.normalize(targets[0].lemma), "mees")
    }

    func testTargetLemmasDefaultLimitIsOne() {
        LexiconCatalog.shared.loadBundledIfNeeded()
        let targets = LearnerProgress.targetLemmasForPassage(
            workingLevel: .a1,
            knownLemmas: ["ma", "ja", "on", "ei"]
        )
        XCTAssertEqual(targets.count, 1)
    }
}
