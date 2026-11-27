import XCTest
import EzeestiCore
@testable import EzeestiLLM

final class PassageRetryTests: XCTestCase {
    private let goodPassage = """
    {"title":"Poes","body":"Täna hommikul ma lähen poodi ja ostan värsket piima.","glossEnglish":"This morning I go to the store and buy fresh milk.","focusWords":["ostan"]}
    """

    /// A 2–4 word stub trips the word-count gate; it must not reach the learner.
    func testStubDraftIsRejected() {
        XCTAssertNil(
            PassageGenerationParser.parse(
                #"{"title":"Isa","body":"Mul on isa.","glossEnglish":"I have a father.","focusWords":["isa"]}"#,
                requiredFocus: ["isa"],
                cefr: .a1
            )
        )
    }

    func testUsableDraftIsAccepted() {
        let text = PassageGenerationParser.parse(
            goodPassage,
            requiredFocus: ["ostan"],
            cefr: .a1
        )
        XCTAssertEqual(text?.body, "Täna hommikul ma lähen poodi ja ostan värsket piima.")
    }
}
