import XCTest
@testable import EzeestiLLM
@testable import EzeestiCore

final class SentenceValidationParserTests: XCTestCase {
    func testParsesApprovedSentence() {
        let raw = """
        {"ok":true,"title":"Poes","body":"Täna hommikul ma lähen poodi ja ostan värsket piima.","glossEnglish":"This morning I go to the store and buy fresh milk.","focusWords":["ostan"],"reason":"Clear and natural."}
        """
        let text = SentenceValidationParser.parse(
            raw,
            requiredFocus: ["ostan"],
            cefr: .a1
        )
        XCTAssertEqual(text?.body, "Täna hommikul ma lähen poodi ja ostan värsket piima.")
        XCTAssertEqual(text?.title, "Poes")
    }

    func testParsesRewriteWhenDraftWasBad() {
        let raw = """
        {"ok":false,"title":"Kes","body":"Kes see mees seal ukse juures on?","glossEnglish":"Who is that man there by the door?","focusWords":["kes"],"reason":"Draft was nonsense; rewrote."}
        """
        let text = SentenceValidationParser.parse(
            raw,
            requiredFocus: ["kes"],
            cefr: .a1
        )
        XCTAssertEqual(text?.body, "Kes see mees seal ukse juures on?")
    }

    func testRejectsValidationThatStillMissesFocus() {
        let raw = """
        {"ok":true,"title":"Kodu","body":"Ma olen kodus.","glossEnglish":"I am at home.","focusWords":["kodu"],"reason":"ok"}
        """
        let text = SentenceValidationParser.parse(
            raw,
            requiredFocus: ["kes"],
            cefr: .a1
        )
        XCTAssertNil(text)
    }

    func testHeuristicKeepsUsableDraft() {
        let draft = PassageDraft(
            title: "Isa",
            body: "Mul on isa kodus ja ta loeb ajalehte.",
            glossEnglish: "I have a father at home and he reads the newspaper.",
            focusWords: ["isa"]
        )
        let text = SentenceValidationParser.heuristic(
            draft: draft,
            requiredFocus: ["isa"],
            cefr: .a1,
            glosses: ["isa": "father"]
        )
        XCTAssertEqual(text.body, "Mul on isa kodus ja ta loeb ajalehte.")
    }

    func testHeuristicReplacesUnusableDraft() {
        let draft = PassageDraft(
            title: "Bad",
            body: "Mul on kes , kuidas ja ka .",
            glossEnglish: "I have who, how and also.",
            focusWords: ["kes"]
        )
        let text = SentenceValidationParser.heuristic(
            draft: draft,
            requiredFocus: ["kes"],
            cefr: .a1,
            glosses: ["kes": "who"]
        )
        XCTAssertEqual(text.body, "Kes see mees seal ukse juures on?")
        XCTAssertEqual(text.focusWords, ["kes"])
    }
}
