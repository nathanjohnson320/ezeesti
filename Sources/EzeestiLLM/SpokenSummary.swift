import Foundation
import EzeestiCore

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
        The learner spoke a short summary of a reading text. Grade from the ASR transcript.
        Always respond with ONLY valid JSON. Keys and meaning:
        - verdict: "correct" | "close" | "incorrect"
        - correction: a clear spoken Estonian model answer (usually close to the source text) that includes every required word — never echo a garbled transcript
        - explanation: short English tip naming specific wrong/misheard words when possible (e.g. "You said 'üksi sünni' — try 'uusi sõnu'")
        - retryPrompt: brief next instruction for the learner
        - usedRequiredWords: required words that appear in the transcript
        - missingRequiredWords: required words that do not appear

        Grading rules:
        - Required words must appear (allow light inflection).
        - Also compare meaning to the source text. If content words are wrong, swapped, or sound like ASR mishears of the source, verdict is close or incorrect — even if required words are present.
        - verdict=correct only when required words are used AND the summary clearly matches the source meaning.
        - Be lenient with punctuation and filler; do not ignore wrong content words.

        Example shape (replace every string with content for THIS learner; never copy example wording):
        {"verdict":"close","correction":"Täna ma õpin uusi sõnu.","explanation":"You said 'üksi sünni' — try 'uusi sõnu'.","retryPrompt":"Say the summary again more clearly.","usedRequiredWords":["et","kui"],"missingRequiredWords":[]}

        Do not wrap JSON in markdown fences.
        """
    }

    public var user: String {
        """
        Source text:
        \(text.body)

        English gloss:
        \(text.glossEnglish)

        Required words the learner must use:
        \(mustUseWords.joined(separator: ", "))

        Learner said (ASR transcript):
        \(transcript)
        """
    }
}

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

    public var asTutorFeedback: TutorFeedback {
        TutorFeedback(
            verdict: verdict,
            correction: correction,
            explanation: explanation,
            retryPrompt: retryPrompt
        )
    }
}

public enum SpokenSummaryFeedbackParser {
    /// Schema / instructional strings models sometimes echo instead of real feedback.
    private static let placeholderFragments: [String] = [
        "one short English tip",
        "a good spoken Estonian summary using the required words",
        "what to say next",
        "one short teacher explanation",
        "corrected Estonian sentence",
        "short instruction telling the learner",
        "replace every string",
        "<1 sentence",
        "<natural Estonian",
    ]

    /// Short glue / high-frequency words ignored when scoring content fidelity to the source.
    private static let contentIgnore: Set<String> = [
        "ma", "sa", "ta", "me", "te", "nad", "ja", "on", "ei", "jah", "ei",
        "see", "need", "siin", "seal", "nüüd", "siis", "nii", "ka", "kui", "et",
        "kas", "mis", "aga", "oma", "või", "ning", "sest", "et",
    ]

    public static func parse(
        _ raw: String,
        mustUse: [String],
        transcript: String,
        sourceBody: String = ""
    ) -> SpokenSummaryFeedback {
        let trimmed = strip(raw)
        if let data = trimmed.data(using: .utf8),
           let feedback = try? JSONDecoder().decode(SpokenSummaryFeedback.self, from: data),
           !looksLikePlaceholder(feedback) {
            return reconcile(feedback, mustUse: mustUse, transcript: transcript, sourceBody: sourceBody)
        }
        if let slice = extractJSON(trimmed),
           let data = slice.data(using: .utf8),
           let feedback = try? JSONDecoder().decode(SpokenSummaryFeedback.self, from: data),
           !looksLikePlaceholder(feedback) {
            return reconcile(feedback, mustUse: mustUse, transcript: transcript, sourceBody: sourceBody)
        }
        return heuristic(mustUse: mustUse, transcript: transcript, sourceBody: sourceBody)
    }

    public static func heuristic(
        mustUse: [String],
        transcript: String,
        sourceBody: String = ""
    ) -> SpokenSummaryFeedback {
        let said = Set(EstonianTokenizer.wordLemmas(in: transcript))
        var used: [String] = []
        var missing: [String] = []
        for word in mustUse {
            let key = EstonianTokenizer.normalize(word)
            if said.contains(key) || said.contains(where: { $0.hasPrefix(key) || key.hasPrefix($0) }) {
                used.append(word)
            } else {
                missing.append(word)
            }
        }

        let modelAnswer = sourceBody.isEmpty
            ? "Proovi öelda midagi nende sõnadega: \(mustUse.joined(separator: ", "))."
            : sourceBody

        let mismatches = likelyMismatches(sourceBody: sourceBody, transcript: transcript)
        let fidelity = contentFidelity(sourceBody: sourceBody, transcript: transcript)
        let explanation = buildExplanation(missingRequired: missing, mismatches: mismatches, fidelity: fidelity)

        if !missing.isEmpty {
            return SpokenSummaryFeedback(
                verdict: .close,
                correction: modelAnswer,
                explanation: explanation,
                retryPrompt: "Speak again and use: \(missing.joined(separator: ", "))",
                usedRequiredWords: used,
                missingRequiredWords: missing
            )
        }

        if !sourceBody.isEmpty, fidelity < 0.55 || !mismatches.isEmpty {
            return SpokenSummaryFeedback(
                verdict: .close,
                correction: modelAnswer,
                explanation: explanation,
                retryPrompt: "Say the summary again, closer to the reading text.",
                usedRequiredWords: used,
                missingRequiredWords: []
            )
        }

        return SpokenSummaryFeedback(
            verdict: .correct,
            correction: modelAnswer,
            explanation: explanation,
            retryPrompt: "Ready for the next text.",
            usedRequiredWords: used,
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
        var missing = feedback.missingRequiredWords
        var used = feedback.usedRequiredWords

        // Recompute required-word coverage if the model left lists empty/wrong.
        if used.isEmpty && missing.isEmpty && !mustUse.isEmpty {
            let said = Set(EstonianTokenizer.wordLemmas(in: transcript))
            for word in mustUse {
                let key = EstonianTokenizer.normalize(word)
                if said.contains(key) || said.contains(where: { $0.hasPrefix(key) || key.hasPrefix($0) }) {
                    used.append(word)
                } else {
                    missing.append(word)
                }
            }
        }

        let fidelity = contentFidelity(sourceBody: sourceBody, transcript: transcript)
        let mismatches = likelyMismatches(sourceBody: sourceBody, transcript: transcript)

        if !missing.isEmpty, verdict == .correct {
            verdict = .close
        }
        if verdict == .correct, !sourceBody.isEmpty, (fidelity < 0.55 || !mismatches.isEmpty) {
            verdict = .close
        }

        // Prefer concrete word-level tips over vague LLM praise when we can detect issues.
        if !mismatches.isEmpty || !missing.isEmpty {
            explanation = buildExplanation(
                missingRequired: missing,
                mismatches: mismatches,
                fidelity: fidelity
            )
        } else if looksLikePlaceholder(
            SpokenSummaryFeedback(
                verdict: verdict,
                correction: correction,
                explanation: explanation,
                retryPrompt: feedback.retryPrompt,
                usedRequiredWords: used,
                missingRequiredWords: missing
            )
        ) {
            explanation = buildExplanation(missingRequired: missing, mismatches: mismatches, fidelity: fidelity)
        }

        if looksLikePlaceholder(
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

        return SpokenSummaryFeedback(
            verdict: verdict,
            correction: correction,
            explanation: explanation,
            retryPrompt: feedback.retryPrompt,
            usedRequiredWords: used,
            missingRequiredWords: missing
        )
    }

    /// Share of source content lemmas that appear (exact or prefix) in the transcript.
    public static func contentFidelity(sourceBody: String, transcript: String) -> Double {
        let source = contentLemmas(in: sourceBody)
        guard !source.isEmpty else { return 1 }
        let said = Set(EstonianTokenizer.wordLemmas(in: transcript))
        var hit = 0
        for lemma in source {
            if said.contains(lemma) || said.contains(where: { fuzzyMatch($0, lemma) }) {
                hit += 1
            }
        }
        return Double(hit) / Double(source.count)
    }

    /// Word-level “you said X — try Y” tips via sequence alignment (catches substitutions like ütlen→õpin).
    public static func likelyMismatches(sourceBody: String, transcript: String) -> [String] {
        let sourceTokens = EstonianTokenizer.tokenize(sourceBody).filter(\.isWord)
        let saidTokens = EstonianTokenizer.tokenize(transcript).filter(\.isWord)
        guard !sourceTokens.isEmpty, !saidTokens.isEmpty else { return [] }

        let sourceNorm = sourceTokens.map(\.normalized)
        let saidNorm = saidTokens.map(\.normalized)
        let ops = wordEditScript(source: sourceNorm, said: saidNorm)

        var hints: [String] = []
        var seenExpected = Set<String>()
        for op in ops {
            guard case let .substitute(saidIndex, sourceIndex) = op else { continue }
            let expected = sourceNorm[sourceIndex]
            if contentIgnore.contains(expected) || expected.count < 3 { continue }
            if seenExpected.contains(expected) { continue }
            seenExpected.insert(expected)
            let expectedSurface = sourceTokens[sourceIndex].surface
            let heardSurface = saidTokens[saidIndex].surface
            hints.append("you said “\(heardSurface)” — try “\(expectedSurface)”")
            if hints.count >= 4 { break }
        }
        return hints
    }

    private static func buildExplanation(
        missingRequired: [String],
        mismatches: [String],
        fidelity: Double
    ) -> String {
        var parts: [String] = []
        if !mismatches.isEmpty {
            parts.append(mismatches.prefix(3).joined(separator: "; "))
        }
        if !missingRequired.isEmpty {
            parts.append("also include: \(missingRequired.joined(separator: ", "))")
        }
        if parts.isEmpty {
            if fidelity < 0.55 {
                return "Required words are there, but the summary does not match the text well. Hear the model and try again."
            }
            return "You used the new words. Nice speaking!"
        }
        // Capitalize first letter for display.
        let joined = parts.joined(separator: ". ")
        guard let first = joined.first else { return joined }
        return String(first).uppercased() + joined.dropFirst() + "."
    }

    private enum WordEdit {
        case substitute(saidIndex: Int, sourceIndex: Int)
        case delete(sourceIndex: Int)
        case insert(saidIndex: Int)
    }

    /// Align transcript words to source words; prefer substitutions over delete+insert.
    private static func wordEditScript(source: [String], said: [String]) -> [WordEdit] {
        let n = source.count
        let m = said.count
        var dist = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dist[i][0] = i }
        for j in 0...m { dist[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                let cost = wordsMatch(source[i - 1], said[j - 1]) ? 0 : 1
                dist[i][j] = min(
                    dist[i - 1][j] + 1,
                    dist[i][j - 1] + 1,
                    dist[i - 1][j - 1] + cost
                )
            }
        }

        var ops: [WordEdit] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, wordsMatch(source[i - 1], said[j - 1]) {
                i -= 1
                j -= 1
            } else if i > 0, j > 0, dist[i][j] == dist[i - 1][j - 1] + 1 {
                ops.append(.substitute(saidIndex: j - 1, sourceIndex: i - 1))
                i -= 1
                j -= 1
            } else if j > 0, dist[i][j] == dist[i][j - 1] + 1 {
                ops.append(.insert(saidIndex: j - 1))
                j -= 1
            } else if i > 0 {
                ops.append(.delete(sourceIndex: i - 1))
                i -= 1
            } else {
                break
            }
        }
        return ops.reversed()
    }

    private static func wordsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return fuzzyMatch(a, b)
    }

    static func looksLikePlaceholder(_ feedback: SpokenSummaryFeedback) -> Bool {
        [feedback.explanation, feedback.correction, feedback.retryPrompt]
            .contains { text in
                let lowered = text.lowercased()
                return placeholderFragments.contains { lowered.contains($0.lowercased()) }
            }
    }

    private static func contentLemmas(in text: String) -> [String] {
        EstonianTokenizer.wordLemmas(in: text).filter { lemma in
            lemma.count >= 3 && !contentIgnore.contains(lemma)
        }
    }

    private static func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.hasPrefix(b) || b.hasPrefix(a) { return abs(a.count - b.count) <= 2 }
        return false
    }

    private static func strip(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: "```json", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSON(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return String(text[start...end])
    }
}
