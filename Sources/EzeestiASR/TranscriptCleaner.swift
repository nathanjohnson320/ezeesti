import Foundation
import EzeestiCore

/// Strip Whisper hallucinations common on short Estonian clips
/// (trailing politeness, prompt echo, and token-repetition loops).
public enum TranscriptCleaner {
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
    ]

    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["Eestikeelne kõne. Lühikesed laused.", "Eestikeelne kõne."] {
            if text.lowercased().hasPrefix(prefix.lowercased()) {
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

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeRepetitionHallucination(text) {
            return ""
        }

        return collapseRepeatedWords(text)
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

    static func looksLikeRepetitionHallucination(_ text: String) -> Bool {
        let tokens = text
            .split(whereSeparator: \.isWhitespace)
            .map { normalizeToken(String($0)) }
            .filter { !$0.isEmpty }

        guard tokens.count >= 6 else { return false }

        var counts: [String: Int] = [:]
        for token in tokens {
            counts[token, default: 0] += 1
        }

        let maxCount = counts.values.max() ?? 0
        if maxCount >= 5 { return true }

        let ratio = Double(maxCount) / Double(tokens.count)
        if tokens.count >= 10, ratio > 0.35 { return true }

        if tokens.count >= 12, counts.count <= 5 { return true }

        return false
    }

    private static func normalizeToken(_ token: String) -> String {
        token
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}

public struct MockSpeechRecognizer: SpeechRecognizing {
    public var cannedText: String

    public init(cannedText: String = "Ma lähen pood.") {
        self.cannedText = cannedText
    }

    public func transcribe(audioURL: URL) async throws -> Transcript {
        _ = audioURL
        try await Task.sleep(nanoseconds: 400_000_000)
        return Transcript(text: cannedText, languageHint: "et", durationSeconds: 0.4)
    }
}
