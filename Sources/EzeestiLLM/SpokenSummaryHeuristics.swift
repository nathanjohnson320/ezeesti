import Foundation
import EzeestiCore

/// Coverage, fidelity, and coaching-copy helpers for spoken-summary grading.
enum SpokenSummaryHeuristics {
    /// Schema / instructional strings models sometimes echo instead of real feedback.
    /// Kept long enough to avoid accidental matches in real learner explanations.
    private static let placeholderFragments: [String] = [
        "one short English tip",
        "a good spoken Estonian summary using the required words",
        "the clear target Estonian sentence",
        "what to say next",
        "one short teacher explanation",
        "corrected Estonian sentence",
        "short instruction telling the learner",
        "replace every string",
    ]

    private static let minimumPlaceholderFragmentLength = 16

    /// Short glue / high-frequency words ignored when scoring content fidelity to the source.
    static let contentIgnore: Set<String> = [
        "ma", "sa", "ta", "me", "te", "nad", "ja", "on", "ei", "jah",
        "see", "need", "siin", "seal", "nüüd", "siis", "nii", "ka", "kui", "et",
        "kas", "mis", "aga", "oma", "või", "ning", "sest",
    ]

    /// Classify focus/required words as used, near-miss (misheard), or truly missing.
    static func requiredCoverage(
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
    static func contentFidelity(sourceBody: String, transcript: String) -> Double {
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

    static func buildExplanation(
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

    static func looksLikePlaceholder(_ feedback: SpokenSummaryFeedback) -> Bool {
        [feedback.explanation, feedback.correction, feedback.retryPrompt]
            .contains { text in
                let lowered = text.lowercased()
                return placeholderFragments.contains { fragment in
                    fragment.count >= minimumPlaceholderFragmentLength
                        && lowered.contains(fragment.lowercased())
                }
            }
    }

    /// True when heard ≈ expected (ASR near-miss / slight mispronunciation).
    static func isNearMiss(_ heard: String, _ expected: String) -> Bool {
        if heard == expected { return true }
        if fuzzyMatch(heard, expected) { return true }
        let a = heard
        let b = expected
        guard a.count >= 3, b.count >= 3 else { return false }
        let distance = SpokenSummaryAlignment.levenshtein(a, b)
        let limit = max(1, min(2, max(a.count, b.count) / 3))
        return distance <= limit
    }

    static func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.hasPrefix(b) || b.hasPrefix(a) { return abs(a.count - b.count) <= 2 }
        return false
    }

    static func wordsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Avoid treating short stems as equal ("me"≈"mees") — that hides real misreads.
        if min(a.count, b.count) < 3 { return false }
        return fuzzyMatch(a, b)
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

    private static func contentLemmas(in text: String) -> [String] {
        EstonianTokenizer.wordLemmas(in: text).filter { lemma in
            lemma.count >= 3 && !contentIgnore.contains(lemma)
        }
    }
}
