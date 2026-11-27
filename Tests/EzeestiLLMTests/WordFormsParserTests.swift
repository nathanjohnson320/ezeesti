import XCTest
@testable import EzeestiLLM
@testable import EzeestiCore

final class WordFormsParserTests: XCTestCase {
    private let drillsJSON = """
    {"lemma":"ema","glossEnglish":"mother","commonForms":[{"surface":"ema","label":"nimetav ainsus (nominative singular)","cloze":"___ on väga hea inimene.","clozeEnglish":"Mother is a very good person.","reason":"Subject of the sentence → nimetav ainsus.","distractors":["emat","emad"]},{"surface":"ema","label":"omastav ainsus (genitive singular)","cloze":"See on ___ raamat.","clozeEnglish":"This is mother's book.","reason":"Possessor before a noun uses omastav ainsus.","distractors":["emale","emas"]},{"surface":"emat","label":"osastav ainsus (partitive singular)","cloze":"Ma näen ___ tänaval.","clozeEnglish":"I see mother on the street.","reason":"näen takes an osastav object.","distractors":["emaga","emad"]}],"extraForms":[{"surface":"emade","label":"omastav mitmus (genitive plural)","cloze":"Nende ___ on väga toredad.","clozeEnglish":"Their mothers are very nice.","reason":"nende ('their') requires omastav mitmus of the possessed noun.","distractors":["emad","emasid"]}]}
    """

    private let paradigmJSON = """
    {"lemma":"ema","paradigm":{"kind":"cases","rows":[{"nameEt":"nimetav","nameEn":"nominative","singular":"ema","plural":"emad"},{"nameEt":"omastav","nameEn":"genitive","singular":"ema","plural":"emade"},{"nameEt":"osastav","nameEn":"partitive","singular":"ema","plural":"emasid"}]}}
    """

    func testParsesDrills() {
        let pack = WordFormsParser.parseDrills(drillsJSON, expectedLemma: "ema")
        XCTAssertEqual(pack?.lemma, "ema")
        XCTAssertEqual(pack?.commonForms.count, 3)
        XCTAssertEqual(pack?.extraForms.count, 1)
        XCTAssertNil(pack?.paradigm)
        XCTAssertEqual(pack?.extraForms.first?.label, "omastav mitmus (genitive plural)")
    }

    func testParsesParadigm() {
        let paradigm = WordFormsParser.parseParadigm(paradigmJSON, expectedLemma: "ema")
        XCTAssertEqual(paradigm?.kind, "cases")
        XCTAssertEqual(paradigm?.rows.count, 3)
        XCTAssertEqual(paradigm?.rows.first?.singular, "ema")
    }

    func testCanonicalizesGarbledCaseNames() {
        let raw = """
        {"lemma":"mees","paradigm":{"kind":"cases","rows":[{"nameEt":"seesüĝtlev","nameEn":"inessive","singular":"mehes","plural":"meestes"},{"nameEt":"seestüĝtlev","nameEn":"elative","singular":"mehest","plural":"meestest"},{"nameEt":"alaleüĝtlev","nameEn":"allative","singular":"mehele","plural":"meestele"}]}}
        """
        let paradigm = WordFormsParser.parseParadigm(raw, expectedLemma: "mees")
        XCTAssertEqual(paradigm?.rows.map(\.nameEt), ["seesütlev", "seestütlev", "alaleütlev"])
        XCTAssertEqual(paradigm?.rows.map(\.nameEn), ["inessive", "elative", "allative"])
    }

    func testRejectsWrongLemmaDrills() {
        XCTAssertNil(WordFormsParser.parseDrills(drillsJSON, expectedLemma: "isa"))
    }

    func testRejectsMissingBlank() {
        let raw = """
        {"lemma":"ema","glossEnglish":"mother","commonForms":[{"surface":"ema","label":"nom","cloze":"Ema on hea.","clozeEnglish":"Mother is good.","distractors":["emat"]}],"extraForms":[]}
        """
        XCTAssertNil(WordFormsParser.parseDrills(raw, expectedLemma: "ema"))
    }

    func testMakeDrillQueueIncludesCommonThenExtra() {
        let pack = WordFormsParser.parseDrills(drillsJSON, expectedLemma: "ema")!
        let drills = WordFormsParser.makeDrillQueue(from: pack)
        XCTAssertGreaterThanOrEqual(drills.count, 3)
        XCTAssertLessThanOrEqual(drills.count, 6)
        XCTAssertTrue(drills.contains(where: { $0.modality == .chips }))
        XCTAssertTrue(drills.contains(where: { !$0.chipOptions.isEmpty || $0.modality != .chips }))
    }

    func testAnswersMatchSoftDiacriticsAndSpeech() {
        XCTAssertTrue(WordFormsParser.answersMatch("Ema", expected: "ema"))
        XCTAssertTrue(WordFormsParser.answersMatch("kool", expected: "kool"))
        XCTAssertTrue(WordFormsParser.answersMatch("Ma näen ema tänaval", expected: "ema"))
        XCTAssertFalse(WordFormsParser.answersMatch("isa", expected: "ema"))
    }

    func testWithParadigmMerges() {
        let drills = WordFormsParser.parseDrills(drillsJSON, expectedLemma: "ema")!
        let paradigm = WordFormsParser.parseParadigm(paradigmJSON, expectedLemma: "ema")
        let merged = drills.withParadigm(paradigm)
        XCTAssertEqual(merged.commonForms.count, 3)
        XCTAssertEqual(merged.paradigm?.rows.count, 3)
    }
}
