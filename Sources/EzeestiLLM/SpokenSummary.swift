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
        "the clear target Estonian sentence",
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
        let mismatches = likelyMismatches(sourceBody: sourceBody, transcript: transcript)
        let coverage = requiredCoverage(mustUse: mustUse, transcript: transcript, mismatches: mismatches)
        let modelAnswer = sourceBody.isEmpty
            ? "Proovi öelda midagi nende sõnadega: \(mustUse.joined(separator: ", "))."
            : sourceBody

        let fidelity = contentFidelity(sourceBody: sourceBody, transcript: transcript)
        let explanation = buildExplanation(
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
        let mismatches = likelyMismatches(sourceBody: sourceBody, transcript: transcript)
        let coverage = requiredCoverage(mustUse: mustUse, transcript: transcript, mismatches: mismatches)
        let used = coverage.used
        let missing = coverage.missing

        let fidelity = contentFidelity(sourceBody: sourceBody, transcript: transcript)

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

    /// Classify focus/required words as used, near-miss (misheard), or truly missing.
    public static func requiredCoverage(
        mustUse: [String],
        transcript: String,
        mismatches: [String] = []
    ) -> (used: [String], missing: [String]) {
        let said = EstonianTokenizer.wordLemmas(in: transcript)
        let saidSet = Set(said)
        let nearMissExpected = expectedWordsCoveredByMismatches(mismatches)

        var used: [String] = []
        var missing: [String] = []
        for word in mustUse {
            let key = EstonianTokenizer.normalize(word)
            if saidSet.contains(key) || saidSet.contains(where: { fuzzyMatch($0, key) }) {
                used.append(word)
                continue
            }
            // Said something close (e.g. lakk ≈ lahke) — tip already covers it; not "missing".
            if nearMissExpected.contains(key)
                || said.contains(where: { isNearMiss($0, key) }) {
                continue
            }
            missing.append(word)
        }
        return (used, missing)
    }

    /// Share of source content lemmas that appear (exact or prefix) in the transcript.
    public static func contentFidelity(sourceBody: String, transcript: String) -> Double {
        let source = contentLemmas(in: sourceBody)
        guard !source.isEmpty else { return 1 }
        let said = Set(EstonianTokenizer.wordLemmas(in: transcript))
        var hit = 0
        for lemma in source {
            if said.contains(lemma) || said.contains(where: { fuzzyMatch($0, lemma) || isNearMiss($0, lemma) }) {
                hit += 1
            }
        }
        return Double(hit) / Double(source.count)
    }

    /// Word-level coaching tips via sequence alignment (catches lakk→lahke, me som→mees on).
    public static func likelyMismatches(sourceBody: String, transcript: String) -> [String] {
        diagnose(sourceBody: sourceBody, transcript: transcript).map(\.explanation)
    }

    /// Structured word issues used for coverage + explanations.
    public static func diagnose(sourceBody: String, transcript: String) -> [WordIssue] {
        let sourceTokens = EstonianTokenizer.tokenize(sourceBody).filter(\.isWord)
        let saidTokens = EstonianTokenizer.tokenize(transcript).filter(\.isWord)
        guard !sourceTokens.isEmpty, !saidTokens.isEmpty else { return [] }

        let sourceNorm = sourceTokens.map(\.normalized)
        let saidNorm = saidTokens.map(\.normalized)
        let ops = wordEditScript(source: sourceNorm, said: saidNorm)

        var pairs: [(heard: String, expected: String, heardNorm: String, expectedNorm: String)] = []
        var seenExpected = Set<String>()
        for op in ops {
            guard case let .substitute(saidIndex, sourceIndex) = op else { continue }
            let expected = sourceNorm[sourceIndex]
            let heard = saidNorm[saidIndex]
            if expected.count < 2 { continue }
            // Skip tiny glue only when it was essentially correct.
            if contentIgnore.contains(expected), isNearMiss(heard, expected) {
                continue
            }
            if seenExpected.contains(expected) { continue }
            seenExpected.insert(expected)
            pairs.append((
                heard: saidTokens[saidIndex].surface,
                expected: sourceTokens[sourceIndex].surface,
                heardNorm: heard,
                expectedNorm: expected
            ))
            if pairs.count >= 5 { break }
        }

        return coalesceIssues(pairs)
    }

    public struct WordIssue: Equatable, Sendable {
        public let heard: String
        public let expected: String
        public let explanation: String

        public init(heard: String, expected: String, explanation: String) {
            self.heard = heard
            self.expected = expected
            self.explanation = explanation
        }
    }

    private static func coalesceIssues(
        _ pairs: [(heard: String, expected: String, heardNorm: String, expectedNorm: String)]
    ) -> [WordIssue] {
        guard !pairs.isEmpty else { return [] }
        var issues: [WordIssue] = []
        var i = 0
        while i < pairs.count {
            // Merge adjacent substitutions into one phrase tip (me+som vs mees+on).
            if i + 1 < pairs.count {
                let a = pairs[i]
                let b = pairs[i + 1]
                let heardPhrase = "\(a.heard) \(b.heard)"
                let expectedPhrase = "\(a.expected) \(b.expected)"
                let blurred = looksBlurredTogether(heard: a.heardNorm + b.heardNorm, expected: a.expectedNorm + b.expectedNorm)
                    || looksBlurredTogether(heard: a.heardNorm, expected: a.expectedNorm)
                if blurred || (a.heardNorm.count <= 3 && b.heardNorm.count <= 3) {
                    issues.append(
                        WordIssue(
                            heard: heardPhrase,
                            expected: expectedPhrase,
                            explanation: phraseExplanation(heard: heardPhrase, expected: expectedPhrase)
                        )
                    )
                    i += 2
                    continue
                }
            }
            let pair = pairs[i]
            issues.append(
                WordIssue(
                    heard: pair.heard,
                    expected: pair.expected,
                    explanation: wordExplanation(heard: pair.heard, expected: pair.expected, heardNorm: pair.heardNorm, expectedNorm: pair.expectedNorm)
                )
            )
            i += 1
        }
        return Array(issues.prefix(3))
    }

    private static func wordExplanation(
        heard: String,
        expected: String,
        heardNorm: String,
        expectedNorm: String
    ) -> String {
        if isNearMiss(heardNorm, expectedNorm) {
            return "You said “\(heard)”, but it should be “\(expected)”. That is close — the sounds are slightly off, so listen for the full word “\(expected)”."
        }
        if heardNorm.count + 1 < expectedNorm.count {
            return "You said “\(heard)”, but the sentence needs “\(expected)”. It sounded cut short; pronounce the whole word “\(expected)”."
        }
        return "You said “\(heard)”, but the sentence needs “\(expected)”. That is a different word, so the meaning changes — aim for “\(expected)” here."
    }

    private static func phraseExplanation(heard: String, expected: String) -> String {
        "You said “\(heard)” where the sentence has “\(expected)”. Those words blurred together or split oddly, so the meaning is unclear. Say “\(expected)” as separate clear words."
    }

    private static func looksBlurredTogether(heard: String, expected: String) -> Bool {
        guard heard.count >= 3, expected.count >= 3 else { return false }
        return levenshtein(heard, expected) <= max(2, expected.count / 3)
    }

    private static func buildExplanation(
        missingRequired: [String],
        mismatches: [String],
        fidelity: Double
    ) -> String {
        var parts: [String] = []
        if !mismatches.isEmpty {
            parts.append(contentsOf: mismatches.prefix(2))
        }
        if !missingRequired.isEmpty {
            let list = missingRequired.joined(separator: ", ")
            parts.append("Also, “\(list)” did not come through clearly — include \(missingRequired.count == 1 ? "that word" : "those words") when you read.")
        }
        if parts.isEmpty {
            if fidelity < 0.7 {
                return "Several words did not match the target sentence. Hear the model, then read it again more slowly."
            }
            return "Clear reading — nice work!"
        }
        return parts.joined(separator: " ")
    }

    /// Expected surfaces already explained by a substitution tip (normalized).
    private static func expectedWordsCoveredByMismatches(_ mismatches: [String]) -> Set<String> {
        var set = Set<String>()
        for tip in mismatches {
            // Prefer explicit “needs “X”” / “has “X”” / “for “X”” / “try “X””.
            for marker in ["needs “", "has “", " for “", " — try “", "word “"] {
                var search = tip[...]
                while let range = search.range(of: marker) {
                    let after = search[range.upperBound...]
                    if let end = after.firstIndex(of: "”") {
                        let word = String(after[..<end])
                        for part in word.split(separator: " ") {
                            set.insert(EstonianTokenizer.normalize(String(part)))
                        }
                        search = after[end...]
                    } else {
                        break
                    }
                }
            }
        }
        return set
    }

    /// True when heard ≈ expected (ASR near-miss / slight mispronunciation).
    private static func isNearMiss(_ heard: String, _ expected: String) -> Bool {
        if heard == expected { return true }
        if fuzzyMatch(heard, expected) { return true }
        let a = heard
        let b = expected
        guard a.count >= 3, b.count >= 3 else { return false }
        let distance = levenshtein(a, b)
        let limit = max(1, min(2, max(a.count, b.count) / 3))
        return distance <= limit
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev = Array(0...m)
        var cur = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[m]
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
        // Avoid treating short stems as equal ("me"≈"mees") — that hides real misreads.
        if min(a.count, b.count) < 3 { return false }
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
