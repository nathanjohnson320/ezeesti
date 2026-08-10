import XCTest
@testable import EzeestiLLM
@testable import EzeestiCore

final class PassageGenerationParserTests: XCTestCase {
    func testParsesValidSentence() {
        let raw = """
        {"title":"Poes","body":"Täna hommikul ma lähen poodi ja ostan värsket piima.","glossEnglish":"This morning I go to the store and buy fresh milk.","focusWords":["ostan"]}
        """
        let text = PassageGenerationParser.parse(
            raw,
            requiredFocus: ["ostan"],
            cefr: .a1
        )
        XCTAssertEqual(text?.title, "Poes")
        XCTAssertTrue(text?.isGenerated == true)
        XCTAssertTrue(text?.body.contains("ostan") == true)
    }

    func testRejectsTooShortStub() {
        let raw = """
        {"title":"Ema","body":"Mul on ema.","glossEnglish":"I have a mother.","focusWords":["ema"]}
        """
        let text = PassageGenerationParser.parse(
            raw,
            requiredFocus: ["ema"],
            cefr: .a1
        )
        XCTAssertNil(text)
    }

    func testRejectsMultiSentenceBody() {
        let raw = """
        {"title":"Poes","body":"Täna ma lähen poodi. Ma ostan piima ja leiba.","glossEnglish":"Today I go to the store. I buy milk and bread.","focusWords":["lähen"]}
        """
        let text = PassageGenerationParser.parse(
            raw,
            requiredFocus: ["lähen"],
            cefr: .a1
        )
        XCTAssertNil(text)
    }

    func testRejectsPlaceholderEcho() {
        let raw = """
        {"title":"short Estonian title","body":"ONE grammatically and logically correct Estonian sentence","glossEnglish":"natural English translation of the whole body","focusWords":["lähen"]}
        """
        let text = PassageGenerationParser.parse(
            raw,
            requiredFocus: ["lähen"],
            cefr: .a1
        )
        XCTAssertNil(text)
    }

    func testHeuristicIncludesFocusWord() {
        let text = PassageGenerationParser.heuristic(
            requiredFocus: ["isa", "ema"],
            cefr: .a1,
            glosses: ["isa": "father", "ema": "mother"]
        )
        XCTAssertTrue(text.isGenerated)
        XCTAssertEqual(text.focusWords, ["isa"])
        XCTAssertTrue(text.body.contains("isa"))
        XCTAssertGreaterThanOrEqual(
            EstonianTokenizer.tokenize(text.body).filter(\.isWord).count,
            6
        )
        XCTAssertFalse(text.body.lowercased().contains("õpin uusi"))
        XCTAssertFalse(text.body.lowercased().contains("ma ütlen:"))
    }

    func testHeuristicBuildsSentenceForSingleNoun() {
        let text = PassageGenerationParser.heuristic(
            requiredFocus: ["raha"],
            cefr: .a1,
            glosses: ["raha": "money"]
        )
        XCTAssertTrue(text.body.contains("raha"))
        XCTAssertTrue(text.glossEnglish.lowercased().contains("money"))
        XCTAssertEqual(
            text.body.split { ".!?".contains($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count,
            1
        )
        XCTAssertGreaterThanOrEqual(
            EstonianTokenizer.tokenize(text.body).filter(\.isWord).count,
            6
        )
    }

    func testHeuristicUsesNaturalFrameForFunctionWord() {
        let text = PassageGenerationParser.heuristic(
            requiredFocus: ["kes"],
            cefr: .a1,
            glosses: ["kes": "who"]
        )
        XCTAssertEqual(text.focusWords, ["kes"])
        XCTAssertEqual(text.body, "Kes see mees seal ukse juures on?")
        XCTAssertTrue(text.glossEnglish.lowercased().contains("who"))
    }

    func testRejectsMetaWordListPassage() {
        let raw = """
        {"title":"Uued sõnad","body":"Täna ma õpin uusi sõnu.","glossEnglish":"Today I learn new words.","focusWords":["isa"]}
        """
        let text = PassageGenerationParser.parse(
            raw,
            requiredFocus: ["isa"],
            cefr: .a1
        )
        XCTAssertNil(text)
    }
}
