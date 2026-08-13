import XCTest
@testable import EzeestiLLM

final class TextTranslationParserTests: XCTestCase {
    func testParsesTranslationAndBreakdown() throws {
        let raw = """
        {"translation":"This year's Koplifest will have a folk theme.",
         "breakdown":[
           {"estonian":"Koplifest","english":"Koplifest","literal":"","note":"festival name, left as is"},
           {"estonian":"toimub","english":"takes place","literal":"","note":"present tense of toimuma"},
           {"estonian":"tänavu","english":"this year","literal":"","note":""},
           {"estonian":"rahvuslikus võtmes","english":"with a folk theme","literal":"in a national key","note":"võtmes is the inessive of võti; the phrase marks the theme"}
         ]}
        """
        let result = try XCTUnwrap(TextTranslationParser.parse(raw))
        XCTAssertEqual(result.translation, "This year's Koplifest will have a folk theme.")
        XCTAssertEqual(result.breakdown.count, 4)
        XCTAssertEqual(result.breakdown.last?.estonian, "rahvuslikus võtmes")
        XCTAssertEqual(result.breakdown.last?.english, "with a folk theme")
        XCTAssertEqual(result.breakdown.last?.literal, "in a national key")
    }

    func testDefaultsMissingBreakdownFields() throws {
        let raw = #"{"translation":"Hello","breakdown":[{"estonian":"Tere","english":"hello"}]}"#
        let result = try XCTUnwrap(TextTranslationParser.parse(raw))
        XCTAssertEqual(result.breakdown.first?.literal, "")
        XCTAssertEqual(result.breakdown.first?.note, "")
    }

    func testDropsHalfEmptyChunksAndRedundantLiteral() throws {
        let raw = """
        {"translation":"Good morning","breakdown":[
          {"estonian":"Tere","english":"hello","literal":"Hello","note":""},
          {"estonian":"","english":"nothing","literal":"","note":""},
          {"estonian":"hommikust","english":"","literal":"","note":""}
        ]}
        """
        let result = try XCTUnwrap(TextTranslationParser.parse(raw))
        XCTAssertEqual(result.breakdown.count, 1)
        XCTAssertEqual(result.breakdown.first?.literal, "")
    }

    func testParsesTranslationWithoutBreakdown() throws {
        let result = try XCTUnwrap(TextTranslationParser.parse(#"{"translation":"milk and bread"}"#))
        XCTAssertEqual(result.translation, "milk and bread")
        XCTAssertTrue(result.breakdown.isEmpty)
    }

    func testParsesFencedJSON() throws {
        let raw = """
        ```json
        {"translation":"Hello world"}
        ```
        """
        XCTAssertEqual(TextTranslationParser.parse(raw)?.translation, "Hello world")
    }

    func testParsesEmbeddedJSON() {
        XCTAssertEqual(
            TextTranslationParser.parse("Sure. {\"translation\":\"milk and bread\"} thanks")?.translation,
            "milk and bread"
        )
    }

    func testParsesPlainTextFallback() {
        XCTAssertEqual(
            TextTranslationParser.parse("Koplifest is held in a national key this year.")?.translation,
            "Koplifest is held in a national key this year."
        )
    }

    func testRejectsEmpty() {
        XCTAssertNil(TextTranslationParser.parse(""))
        XCTAssertNil(TextTranslationParser.parse(#"{"translation":"   "}"#))
    }
}
