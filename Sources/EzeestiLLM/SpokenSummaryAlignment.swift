import Foundation
import EzeestiCore

/// Word-level alignment between a target sentence and an ASR transcript.
enum SpokenSummaryAlignment {
    struct WordIssue: Equatable, Sendable {
        let heard: String
        let expected: String
        let explanation: String
    }

    /// Word-level coaching tips via sequence alignment (catches lakk→lahke, me som→mees on).
    static func likelyMismatches(sourceBody: String, transcript: String) -> [String] {
        diagnose(sourceBody: sourceBody, transcript: transcript).map(\.explanation)
    }

    /// Structured word issues used for coverage + explanations.
    static func diagnose(sourceBody: String, transcript: String) -> [WordIssue] {
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
            if SpokenSummaryHeuristics.contentIgnore.contains(expected),
               SpokenSummaryHeuristics.isNearMiss(heard, expected) {
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

    static func levenshtein(_ a: String, _ b: String) -> Int {
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
                let cost = SpokenSummaryHeuristics.wordsMatch(source[i - 1], said[j - 1]) ? 0 : 1
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
            if i > 0, j > 0, SpokenSummaryHeuristics.wordsMatch(source[i - 1], said[j - 1]) {
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
                    explanation: wordExplanation(
                        heard: pair.heard,
                        expected: pair.expected,
                        heardNorm: pair.heardNorm,
                        expectedNorm: pair.expectedNorm
                    )
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
        if SpokenSummaryHeuristics.isNearMiss(heardNorm, expectedNorm) {
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
}
