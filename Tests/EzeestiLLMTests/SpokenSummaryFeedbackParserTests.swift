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
        let source = "Täna ma õpin uusi sõnu."
        let transcript = "Täna ma õpin üksi sünni."
        let mustUse = ["õpin", "uusi"]
        let feedback = SpokenSummaryFeedbackParser.heuristic(
            mustUse: mustUse,
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .close)
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
        let source = "Täna ma õpin uusi sõnu."
        let transcript = "Täna ma ütlen üsi sõnu."
        let mustUse = ["õpin", "uusi"]
        let feedback = SpokenSummaryFeedbackParser.heuristic(
            mustUse: mustUse,
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .close)
        let explanation = feedback.explanation.lowercased()
        XCTAssertTrue(
            explanation.contains("ütlen") && explanation.contains("õpin"),
            "Expected ütlen→õpin tip, got: \(feedback.explanation)"
        )
    }

    func testNearMissLahkeNotReportedAsMissingVaga() {
        let source = "Minu ema on väga lahke."
        let transcript = "Minu ema on väga lakk."
        let raw = """
        {"verdict":"close","correction":"Minu ema on väga lahke.","explanation":"Missing words.","retryPrompt":"Try again.","usedRequiredWords":[],"missingRequiredWords":["väga","lahke"]}
        """
        let feedback = SpokenSummaryFeedbackParser.parse(
            raw,
            mustUse: ["lahke"],
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .close)
        XCTAssertTrue(feedback.missingRequiredWords.isEmpty, "\(feedback.missingRequiredWords)")
        let explanation = feedback.explanation.lowercased()
        XCTAssertTrue(explanation.contains("lakk") && explanation.contains("lahke"), feedback.explanation)
        XCTAssertTrue(
            explanation.contains("close") || explanation.contains("sounds") || explanation.contains("different word") || explanation.contains("needs"),
            feedback.explanation
        )
        XCTAssertFalse(explanation.contains("väga"), "Should not claim väga is missing: \(feedback.explanation)")
        XCTAssertFalse(explanation.contains("still need"), feedback.explanation)
    }

    func testExplainsBlurredMeesOnPhrase() {
        let source = "See mees on väga tark."
        let transcript = "See me som väga tark."
        let feedback = SpokenSummaryFeedbackParser.heuristic(
            mustUse: ["mees"],
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .close)
        let explanation = feedback.explanation.lowercased()
        XCTAssertTrue(explanation.contains("me"), feedback.explanation)
        XCTAssertTrue(explanation.contains("mees"), feedback.explanation)
        XCTAssertTrue(
            explanation.contains("blurred")
                || explanation.contains("meaning")
                || explanation.contains("needs")
                || explanation.contains("separate"),
            feedback.explanation
        )
        XCTAssertFalse(explanation.hasPrefix("close — you said"), feedback.explanation)
    }

    func testReconcileIgnoresInventedMissingWords() {
        let source = "Minu ema on väga lahke."
        let transcript = "Minu ema on väga lahke."
        let lenient = SpokenSummaryFeedback(
            verdict: .close,
            correction: source,
            explanation: "Still need: väga",
            retryPrompt: "Try again.",
            usedRequiredWords: [],
            missingRequiredWords: ["väga"]
        )
        let feedback = SpokenSummaryFeedbackParser.reconcile(
            lenient,
            mustUse: ["lahke"],
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .correct)
        XCTAssertTrue(feedback.missingRequiredWords.isEmpty)
    }

    func testReconcileDowngradesCorrectWhenFidelityLow() {
        let source = "Täna ma õpin uusi sõnu."
        let transcript = "Täna ma õpin üksi sünni."
        let lenient = SpokenSummaryFeedback(
            verdict: .correct,
            correction: transcript,
            explanation: "Clear reading — nice work!",
            retryPrompt: "Next.",
            usedRequiredWords: ["õpin"],
            missingRequiredWords: []
        )
        let feedback = SpokenSummaryFeedbackParser.reconcile(
            lenient,
            mustUse: ["õpin"],
            transcript: transcript,
            sourceBody: source
        )
        XCTAssertEqual(feedback.verdict, .close)
        XCTAssertEqual(feedback.correction, source)
    }
}
