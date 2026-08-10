import XCTest
@testable import EzeestiLLM

final class SpokenSummaryFeedbackParserTests: XCTestCase {
    func testParsesRealFeedback() {
        let raw = """
        {"verdict":"correct","correction":"Ma joon piima.","explanation":"Nice — all required words.","retryPrompt":"Next text.","usedRequiredWords":["joon","piima"],"missingRequiredWords":[]}
        """
        let feedback = SpokenSummaryFeedbackParser.parse(
            raw,
            mustUse: ["joon", "piima"],
            transcript: "Ma joon piima.",
            sourceBody: "Ma joon piima."
        )
        XCTAssertEqual(feedback.verdict, .correct)
        XCTAssertEqual(feedback.explanation, "Nice — all required words.")
        XCTAssertEqual(feedback.correction, "Ma joon piima.")
    }

    func testRejectsSchemaPlaceholderEcho() {
        let raw = """
        {"verdict":"correct","correction":"a good spoken Estonian summary using the required words","explanation":"one short English tip","retryPrompt":"what to say next","usedRequiredWords":["joon"],"missingRequiredWords":[]}
        """
        let transcript = "Ma joon kohvi ja söön leiba. Ma tahan piima ja teed."
        let source = "Ma joon kohvi ja söön leiba. Ma tahan piima ja teed."
        let feedback = SpokenSummaryFeedbackParser.parse(
            raw,
            mustUse: ["joon", "söön", "piima", "teed"],
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .correct)
        XCTAssertEqual(feedback.correction, source)
        XCTAssertFalse(SpokenSummaryFeedbackParser.looksLikePlaceholder(feedback))
    }

    func testHeuristicMarksMissingWords() {
        let feedback = SpokenSummaryFeedbackParser.heuristic(
            mustUse: ["joon", "teed"],
            transcript: "Ma joon kohvi.",
            sourceBody: "Ma joon kohvi ja teed."
        )
        XCTAssertEqual(feedback.verdict, .close)
        XCTAssertEqual(feedback.missingRequiredWords, ["teed"])
        XCTAssertEqual(feedback.usedRequiredWords, ["joon"])
        XCTAssertTrue(feedback.explanation.lowercased().contains("teed"), feedback.explanation)
    }

    func testHeuristicFlagsMisheardContentEvenWhenRequiredWordsPresent() {
        let source = "Täna ma õpin uusi sõnu. Ma ütlen: et, kui, kas, mis, aga, oma, siis, nii. See on hea harjutus."
        let transcript = "Täna ma õpin üksi sünni. Ma ütlen, et kui kas, mis aga oma, siis nii. See on hea harjutus."
        let mustUse = ["et", "kui", "kas", "mis", "aga", "oma", "siis", "nii"]
        let feedback = SpokenSummaryFeedbackParser.heuristic(
            mustUse: mustUse,
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .close)
        XCTAssertTrue(feedback.missingRequiredWords.isEmpty)
        XCTAssertEqual(feedback.correction, source)
        XCTAssertTrue(
            feedback.explanation.lowercased().contains("üksi")
                || feedback.explanation.lowercased().contains("uusi")
                || feedback.explanation.lowercased().contains("sünni")
                || feedback.explanation.lowercased().contains("sõnu"),
            feedback.explanation
        )
    }

    func testHeuristicSurfacesSubstitutionsAlongsideMissingRequired() {
        let source = "Täna ma õpin uusi sõnu. Ma ütlen: ära, kõik, kes, kuidas, ka, mitte, välja, tema. See on hea harjutus."
        let transcript = "Täna ma ütlen üsi sõnu. Ma ütlen, aga kõik kes kuidas ka mitte välja teema. See on hea harjutus."
        let mustUse = ["ära", "kõik", "kes", "kuidas", "ka", "mitte", "välja", "tema"]
        let feedback = SpokenSummaryFeedbackParser.heuristic(
            mustUse: mustUse,
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .close)
        XCTAssertTrue(feedback.missingRequiredWords.contains("ära"), "\(feedback.missingRequiredWords)")
        let explanation = feedback.explanation.lowercased()
        XCTAssertTrue(
            explanation.contains("ütlen") && explanation.contains("õpin"),
            "Expected ütlen→õpin tip, got: \(feedback.explanation)"
        )
        XCTAssertTrue(
            explanation.contains("üsi") && explanation.contains("uusi"),
            "Expected üsi→uusi tip, got: \(feedback.explanation)"
        )
    }

    func testReconcileDowngradesCorrectWhenFidelityLow() {
        let source = "Täna ma õpin uusi sõnu."
        let transcript = "Täna ma õpin üksi sünni."
        let lenient = SpokenSummaryFeedback(
            verdict: .correct,
            correction: transcript,
            explanation: "You used the new words. Nice speaking!",
            retryPrompt: "Next.",
            usedRequiredWords: ["et"],
            missingRequiredWords: []
        )
        let feedback = SpokenSummaryFeedbackParser.reconcile(
            lenient,
            mustUse: ["et"],
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .close)
        XCTAssertEqual(feedback.correction, source)
    }
}
