import XCTest
@testable import EzeestiLLM
@testable import EzeestiCore

final class PassageGenerationParserTests: XCTestCase {
    func testParsesValidPassage() {
        let raw = """
        {"title":"Poes","body":"Täna ma lähen poodi. Ma ostan piima ja leiba.","glossEnglish":"Today I go to the store. I buy milk and bread.","focusWords":["lähen","ostan","piima"]}
        """
        let text = PassageGenerationParser.parse(
            raw,
            requiredFocus: ["lähen", "ostan", "piima"],
            cefr: .a1
        )
        XCTAssertEqual(text?.title, "Poes")
        XCTAssertTrue(text?.isGenerated == true)
        XCTAssertTrue(text?.body.contains("piima") == true)
    }

    func testRejectsPlaceholderEcho() {
        let raw = """
        {"title":"short Estonian title","body":"3–5 short Estonian sentences everyday","glossEnglish":"natural English translation of the whole body","focusWords":["lähen"]}
        """
        let text = PassageGenerationParser.parse(
            raw,
            requiredFocus: ["lähen", "ostan"],
            cefr: .a1
        )
        XCTAssertNil(text)
    }

    func testHeuristicIncludesFocusWords() {
        let text = PassageGenerationParser.heuristic(
            requiredFocus: ["isa", "ema"],
            cefr: .a1,
            glosses: ["isa": "father", "ema": "mother"]
        )
        XCTAssertTrue(text.isGenerated)
        XCTAssertTrue(text.body.contains("isa"))
        XCTAssertTrue(text.body.contains("ema"))
        XCTAssertEqual(text.focusWords, ["isa", "ema"])
        XCTAssertFalse(text.body.lowercased().contains("õpin uusi"))
        XCTAssertFalse(text.body.lowercased().contains("ma ütlen:"))
    }

    func testHeuristicBuildsSceneForSingleNoun() {
        let text = PassageGenerationParser.heuristic(
            requiredFocus: ["raha"],
            cefr: .a1,
            glosses: ["raha": "money"]
        )
        XCTAssertTrue(text.body.contains("raha"))
        XCTAssertTrue(text.glossEnglish.lowercased().contains("money"))
        XCTAssertFalse(text.body.contains(","))
    }

    func testRejectsMetaWordListPassage() {
        let raw = """
        {"title":"Uued sõnad","body":"Täna ma õpin uusi sõnu. Ma ütlen: isa, ema. See on hea harjutus.","glossEnglish":"Today I learn new words. I say: father, mother. This is good practice.","focusWords":["isa","ema"]}
        """
        let text = PassageGenerationParser.parse(
            raw,
            requiredFocus: ["isa", "ema"],
            cefr: .a1
        )
        XCTAssertNil(text)
    }
}
