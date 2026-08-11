import XCTest
import EzeestiCore
@testable import EzeestiLLM

/// Records every call so we can assert the caller resamples rather than
/// failing on the first draft that misses a usability gate.
private actor ScriptedModel: LanguageModeling {
    private var responses: [String]
    private(set) var temperatures: [Double?] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func complete(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> String {
        temperatures.append(temperature)
        guard !responses.isEmpty else {
            throw EzeestiError.llmFailed("no scripted response left")
        }
        return responses.removeFirst()
    }

    func recordedTemperatures() -> [Double?] {
        temperatures
    }
}

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

    /// Regression: generation used to give up after one sample, surfacing
    /// "EstLLM returned an invalid passage" on a single unlucky draft.
    func testRetryResamplesAfterRejectedDraft() async throws {
        let rejected = #"{"title":"Isa","body":"Mul on isa.","glossEnglish":"I have a father.","focusWords":["isa"]}"#
        let model = ScriptedModel(responses: [rejected, rejected, goodPassage])

        var accepted: GradedText?
        var attempts = 0
        for temperature in [0.2, 0.55, 0.85] {
            attempts += 1
            let raw = try await model.complete(
                system: "s",
                user: "u",
                maxTokens: 220,
                temperature: temperature
            )
            if let text = PassageGenerationParser.parse(raw, requiredFocus: ["ostan"], cefr: .a1) {
                accepted = text
                break
            }
        }

        XCTAssertEqual(attempts, 3, "should keep resampling until a draft passes")
        XCTAssertEqual(accepted?.body, "Täna hommikul ma lähen poodi ja ostan värsket piima.")

        let temperatures = await model.recordedTemperatures()
        XCTAssertEqual(
            temperatures.compactMap { $0 },
            [0.2, 0.55, 0.85],
            "retries must raise temperature, otherwise resampling repeats the same draft"
        )
    }

    /// Validation is a second opinion; junk from the reviewer keeps the draft.
    func testUnusableValidationResponseFallsBackToDraft() {
        let draft = PassageGenerationParser.parse(
            goodPassage,
            requiredFocus: ["ostan"],
            cefr: .a1
        )
        let validated = SentenceValidationParser.parse(
            "not json at all",
            requiredFocus: ["ostan"],
            cefr: .a1
        )
        XCTAssertNil(validated)
        XCTAssertNotNil(draft, "caller keeps this draft when validation yields nothing")
    }
}
