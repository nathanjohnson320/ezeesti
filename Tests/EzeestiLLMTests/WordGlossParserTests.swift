import XCTest
@testable import EzeestiLLM

final class WordGlossParserTests: XCTestCase {
    func testParsesJSON() {
        XCTAssertEqual(WordGlossParser.parse(#"{"gloss":"fresh bread"}"#), "fresh bread")
    }

    func testParsesFencedJSON() {
        let raw = """
        ```json
        {"gloss":"by bus"}
        ```
        """
        XCTAssertEqual(WordGlossParser.parse(raw), "by bus")
    }

    func testParsesEmbeddedJSON() {
        XCTAssertEqual(
            WordGlossParser.parse("Sure. {\"gloss\":\"milk (partitive)\"} thanks"),
            "milk (partitive)"
        )
    }
}
