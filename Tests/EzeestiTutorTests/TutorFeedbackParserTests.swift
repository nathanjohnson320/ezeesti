import XCTest
@testable import EzeestiLLM
@testable import EzeestiCore

final class TutorFeedbackParserTests: XCTestCase {
    func testParsesPlainJSON() throws {
        let raw = """
        {"verdict":"close","correction":"Ma lähen poodi.","explanation":"Use illative.","retryPrompt":"Say Ma lähen poodi."}
        """
        let feedback = try TutorFeedbackParser.parse(raw)
        XCTAssertEqual(feedback.verdict, .close)
        XCTAssertEqual(feedback.correction, "Ma lähen poodi.")
    }

    func testParsesFencedJSON() throws {
        let raw = """
        ```json
        {"verdict":"correct","correction":"Tere!","explanation":"Good.","retryPrompt":"Next."}
        ```
        """
        let feedback = try TutorFeedbackParser.parse(raw)
        XCTAssertEqual(feedback.verdict, .correct)
    }
}
