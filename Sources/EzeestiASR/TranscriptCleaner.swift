import Foundation
import EzeestiCore

/// Strip Whisper hallucinations common on short Estonian clips
/// (trailing politeness, prompt echo, filler loops, and invented extra sentences).
///
/// Caseless `enum` is the standard Swift namespace pattern for pure static helpers.
public enum TranscriptCleaner {
    private static let minSentenceOverlapRatio = 0.4
    private static let repetitionMinTokens = 6
    private static let repetitionMaxCount = 5
    private static let repetitionRatioMinTokens = 10
    private static let repetitionMaxRatio = 0.35
    private static let lowDiversityMinTokens = 12
    private static let lowDiversityMaxUnique = 5

    private static let trailingHallucinations: [String] = [
        "thank you for watching",
        "thanks for watching",
        "thank you.",
        "thank you",
        "thanks.",
        "thanks",
        "subscribe",
        "aitäh.",
        "aitäh",
        "tänan.",
        "tänan",
        "subtitl",
        "www.",
        // Common Estonian Whisper fillers on trailing silence / short clips.
        "lähme lähme.",
        "lähme lähme",
        "läheme läheme.",
        "läheme läheme",
        "lähme.",
        "lähme",
        "läheme.",
        "läheme",
        "tere tere.",
        "tere tere",
        "jah jah.",
        "noh noh",
    ]

    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["Eestikeelne kõne. Lühikesed laused.", "Eestikeelne kõne."] {
            let lower = text.lowercased()
            let prefixLower = prefix.lowercased()
            if lower.hasPrefix(prefixLower) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            for phrase in trailingHallucinations {
                if lower.hasSuffix(phrase) {
                    text = String(text.dropLast(phrase.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
                    changed = true
                    break
                }
            }
        }

        if let range = text.range(of: #"[\.!?]\s+(Thank|Thanks|Please|Subscribe|Hello)\b"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]) + "."
        }

        text = stripTrailingRepeatedSentences(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeRepetitionHallucination(text) {
            return ""
        }

        return collapseRepeatedWords(text)
    }

    /// Drop trailing invented sentences/words that do not belong to the expected read-aloud target.
    /// Example: "Muul on ima. Lähme. Lähme." → "Muul on ima." when expected is "Mul on ema."
    public static func align(toExpected expected: String, transcript: String) -> String {
        let cleaned = clean(transcript)
        let expectedTrimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !expectedTrimmed.isEmpty else { return cleaned }

        let expectedLemmas = Set(EstonianTokenizer.wordLemmas(in: expectedTrimmed))
        guard !expectedLemmas.isEmpty else { return cleaned }

        let sentences = splitSentences(cleaned)
        guard !sentences.isEmpty else { return cleaned }

        var kept: [String] = []
        for sentence in sentences {
            let lemmas = EstonianTokenizer.wordLemmas(in: sentence)
            if lemmas.isEmpty { continue }
            let hits = lemmas.filter { lemma in
                expectedLemmas.contains(lemma)
                    || expectedLemmas.contains(where: { softMatch($0, lemma) })
            }.count
            // Keep the first sentence always; later sentences need clear overlap.
            if kept.isEmpty {
                kept.append(sentence)
            } else {
                let ratio = Double(hits) / Double(lemmas.count)
                if ratio >= minSentenceOverlapRatio {
                    kept.append(sentence)
                } else {
                    break
                }
            }
        }

        var result = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        result = trimTrailingUnmatchedTokens(result, expectedLemmas: expectedLemmas)
        return result.isEmpty ? cleaned : result
    }

    static func collapseRepeatedWords(_ text: String) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return text }

        var result: [String] = []
        var previousNormalized = ""
        var streak = 0

        for token in tokens {
            let normalized = normalizeToken(token)
            if !normalized.isEmpty, normalized == previousNormalized {
                streak += 1
                if streak <= 2 {
                    result.append(token)
                }
            } else {
                previousNormalized = normalized
                streak = 1
                result.append(token)
            }
        }

        return result.joined(separator: " ")
    }

    private static func looksLikeRepetitionHallucination(_ text: String) -> Bool {
        let tokens = text
            .split(whereSeparator: \.isWhitespace)
            .map { normalizeToken(String($0)) }
            .filter { !$0.isEmpty }

        guard tokens.count >= repetitionMinTokens else { return false }

        var counts: [String: Int] = [:]
        for token in tokens {
            counts[token, default: 0] += 1
        }

        let maxCount = counts.values.max() ?? 0
        if maxCount >= repetitionMaxCount { return true }

        let ratio = Double(maxCount) / Double(tokens.count)
        if tokens.count >= repetitionRatioMinTokens, ratio > repetitionMaxRatio { return true }

        if tokens.count >= lowDiversityMinTokens, counts.count <= lowDiversityMaxUnique { return true }

        return false
    }

    /// "Lähme. Lähme." / duplicated trailing clauses.
    private static func stripTrailingRepeatedSentences(_ text: String) -> String {
        var sentences = splitSentences(text)
        while sentences.count >= 2 {
            let last = normalizeSentence(sentences[sentences.count - 1])
            let prev = normalizeSentence(sentences[sentences.count - 2])
            if !last.isEmpty, last == prev {
                sentences.removeLast()
                continue
            }
            break
        }
        return sentences.joined(separator: " ")
    }

    private static func trimTrailingUnmatchedTokens(_ text: String, expectedLemmas: Set<String>) -> String {
        var tokens = EstonianTokenizer.tokenize(text).filter(\.isWord)
        while let last = tokens.last {
            let key = last.normalized
            let matches = expectedLemmas.contains(key)
                || expectedLemmas.contains(where: { softMatch($0, key) })
            if matches { break }
            // Only strip a short unmatched tail (1–2 tokens), not the whole utterance.
            if tokens.count <= 2 { break }
            tokens.removeLast()
        }
        // Rebuild from original word surfaces with simple spacing.
        return tokens.map(\.surface).joined(separator: " ")
    }

    private static func splitSentences(_ text: String) -> [String] {
        var parts: [String] = []
        var sentenceStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index)
            if ".!?".contains(ch) {
                let trimmed = text[sentenceStart..<next].trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
                sentenceStart = next
            }
            index = next
        }

        let tail = text[sentenceStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append(tail)
        }
        return parts
    }

    private static func normalizeSentence(_ text: String) -> String {
        EstonianTokenizer.wordLemmas(in: text).joined(separator: " ")
    }

    private static func softMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.hasPrefix(b) || b.hasPrefix(a) { return abs(a.count - b.count) <= 2 }
        // Cheap near-miss for ASR (muul≈mul, ima≈ema).
        guard a.count >= 3, b.count >= 3 else { return false }
        return levenshtein(a, b) <= 1
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

    private static func normalizeToken(_ token: String) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
