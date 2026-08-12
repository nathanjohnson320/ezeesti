import Foundation
import EzeestiCore

/// Prompt that asks EstLLM to grade a read-aloud ASR transcript against a target sentence.
public struct SpokenSummaryPrompt {
    public let text: GradedText
    public let mustUseWords: [String]
    public let transcript: String

    public init(text: GradedText, mustUseWords: [String], transcript: String) {
        self.text = text
        self.mustUseWords = mustUseWords
        self.transcript = transcript
    }

    public var system: String {
        """
        You are a patient Estonian speaking tutor for CEFR \(text.cefr.rawValue) learners.
        The learner read a target sentence aloud. Grade from the ASR transcript.
        Always respond with ONLY valid JSON. Keys and meaning:
        - verdict: "correct" | "close" | "incorrect"
        - correction: the clear target Estonian sentence (or a minor natural fix) — never echo a garbled transcript
        - explanation: 1–3 English sentences that (1) quote what they said wrong, (2) say the intended word/phrase, and (3) briefly explain why it is wrong (pronunciation, wrong word, meaning change, or words blurred together). Do NOT only say "try X".
        - retryPrompt: brief next instruction for the learner
        - usedRequiredWords: focus words that appear in the transcript
        - missingRequiredWords: focus words that do not appear

        Grading rules:
        - Compare the transcript to the target sentence word-by-word.
        - Focus/required words must appear (allow light inflection).
        - If content words are wrong, swapped, or sound like ASR mishears, verdict is close or incorrect — even if required words are present.
        - verdict=correct only when the reading clearly matches the target sentence.
        - Be lenient with punctuation and filler; do not ignore wrong content words.

        Example shape (replace every string with content for THIS learner; never copy example wording):
        {"verdict":"close","correction":"See mees on väga tark.","explanation":"You said “me som” where the sentence has “mees on”. Those words blurred together, so it no longer means “this man is”. Say “mees” then “on” clearly.","retryPrompt":"Read the sentence again more clearly.","usedRequiredWords":["mees"],"missingRequiredWords":[]}

        Do not wrap JSON in markdown fences.
        """
    }

    public var user: String {
        """
        Target sentence:
        \(text.body)

        English gloss:
        \(text.glossEnglish)

        Focus words to cover:
        \(mustUseWords.joined(separator: ", "))

        Learner said (ASR transcript):
        \(transcript)
        """
    }
}

/// Graded read-aloud feedback (model JSON or heuristic fallback).
public struct SpokenSummaryFeedback: Codable, Sendable, Hashable {
    public let verdict: TutorVerdict
    public let correction: String
    public let explanation: String
    public let retryPrompt: String
    public let usedRequiredWords: [String]
    public let missingRequiredWords: [String]

    public init(
        verdict: TutorVerdict,
        correction: String,
        explanation: String,
        retryPrompt: String,
        usedRequiredWords: [String] = [],
        missingRequiredWords: [String] = []
    ) {
        self.verdict = verdict
        self.correction = correction
        self.explanation = explanation
        self.retryPrompt = retryPrompt
        self.usedRequiredWords = usedRequiredWords
        self.missingRequiredWords = missingRequiredWords
    }
}

/// Parses EstLLM grading JSON and reconciles it with transcript heuristics.
public enum SpokenSummaryFeedbackParser {
    public static func parse(
        _ raw: String,
        mustUse: [String],
        transcript: String,
        sourceBody: String = ""
    ) -> SpokenSummaryFeedback {
        if let feedback = LLMJSON.decodeIfPresent(SpokenSummaryFeedback.self, from: raw),
           !SpokenSummaryHeuristics.looksLikePlaceholder(feedback) {
            return reconcile(feedback, mustUse: mustUse, transcript: transcript, sourceBody: sourceBody)
        }
        return heuristic(mustUse: mustUse, transcript: transcript, sourceBody: sourceBody)
    }

    public static func heuristic(
        mustUse: [String],
        transcript: String,
        sourceBody: String = ""
    ) -> SpokenSummaryFeedback {
        let mismatches = SpokenSummaryAlignment.likelyMismatches(sourceBody: sourceBody, transcript: transcript)
        let coverage = SpokenSummaryHeuristics.requiredCoverage(
            mustUse: mustUse,
            transcript: transcript,
            mismatches: mismatches
        )
        // Correction is the real target sentence — never invent canned Estonian.
        let modelAnswer = sourceBody

        let fidelity = SpokenSummaryHeuristics.contentFidelity(sourceBody: sourceBody, transcript: transcript)
        let explanation = SpokenSummaryHeuristics.buildExplanation(
            missingRequired: coverage.missing,
            mismatches: mismatches,
            fidelity: fidelity
        )

        if !coverage.missing.isEmpty {
            return SpokenSummaryFeedback(
                verdict: .close,
                correction: modelAnswer,
                explanation: explanation,
                retryPrompt: "Read again and include: \(coverage.missing.joined(separator: ", "))",
                usedRequiredWords: coverage.used,
                missingRequiredWords: coverage.missing
            )
        }

        if !sourceBody.isEmpty, fidelity < 0.7 || !mismatches.isEmpty {
            return SpokenSummaryFeedback(
                verdict: .close,
                correction: modelAnswer,
                explanation: explanation,
                retryPrompt: "Read the sentence again, closer to the target.",
                usedRequiredWords: coverage.used,
                missingRequiredWords: []
            )
        }

        return SpokenSummaryFeedback(
            verdict: .correct,
            correction: modelAnswer,
            explanation: explanation,
            retryPrompt: "Ready for the next sentence.",
            usedRequiredWords: coverage.used,
            missingRequiredWords: []
        )
    }

    /// Downgrade overly lenient LLM verdicts when transcript diverges from the source.
    public static func reconcile(
        _ feedback: SpokenSummaryFeedback,
        mustUse: [String],
        transcript: String,
        sourceBody: String
    ) -> SpokenSummaryFeedback {
        var verdict = feedback.verdict
        var explanation = feedback.explanation
        var correction = feedback.correction

        // Always recompute coverage from the transcript — models invent missing words
        // (e.g. claiming "väga" is missing when it was said clearly).
        let mismatches = SpokenSummaryAlignment.likelyMismatches(sourceBody: sourceBody, transcript: transcript)
        let coverage = SpokenSummaryHeuristics.requiredCoverage(
            mustUse: mustUse,
            transcript: transcript,
            mismatches: mismatches
        )
        let used = coverage.used
        let missing = coverage.missing

        let fidelity = SpokenSummaryHeuristics.contentFidelity(sourceBody: sourceBody, transcript: transcript)

        if !missing.isEmpty, verdict == .correct {
            verdict = .close
        }
        if verdict == .correct, !sourceBody.isEmpty, (fidelity < 0.7 || !mismatches.isEmpty) {
            verdict = .close
        }
        // Upgrade false "close" when coverage + alignment are actually fine.
        if verdict != .incorrect, missing.isEmpty, mismatches.isEmpty, fidelity >= 0.7 {
            verdict = .correct
        }

        // Prefer concrete pronunciation tips over vague LLM praise.
        if !mismatches.isEmpty || !missing.isEmpty {
            explanation = SpokenSummaryHeuristics.buildExplanation(
                missingRequired: missing,
                mismatches: mismatches,
                fidelity: fidelity
            )
        } else if SpokenSummaryHeuristics.looksLikePlaceholder(
            SpokenSummaryFeedback(
                verdict: verdict,
                correction: correction,
                explanation: explanation,
                retryPrompt: feedback.retryPrompt,
                usedRequiredWords: used,
                missingRequiredWords: missing
            )
        ) {
            explanation = SpokenSummaryHeuristics.buildExplanation(
                missingRequired: missing,
                mismatches: mismatches,
                fidelity: fidelity
            )
        }

        if SpokenSummaryHeuristics.looksLikePlaceholder(
            SpokenSummaryFeedback(
                verdict: verdict,
                correction: correction,
                explanation: explanation,
                retryPrompt: feedback.retryPrompt,
                usedRequiredWords: used,
                missingRequiredWords: missing
            )
        ) || correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || correction == transcript {
            correction = sourceBody.isEmpty ? correction : sourceBody
        }

        let retry: String
        if !missing.isEmpty {
            retry = "Read again and include: \(missing.joined(separator: ", "))"
        } else if !mismatches.isEmpty {
            retry = "Read the sentence again, closer to the target."
        } else {
            retry = feedback.retryPrompt
        }

        return SpokenSummaryFeedback(
            verdict: verdict,
            correction: correction,
            explanation: explanation,
            retryPrompt: retry,
            usedRequiredWords: used,
            missingRequiredWords: missing
        )
    }

    /// Test / diagnostic access to placeholder detection.
    static func looksLikePlaceholder(_ feedback: SpokenSummaryFeedback) -> Bool {
        SpokenSummaryHeuristics.looksLikePlaceholder(feedback)
    }
}
