import Foundation
import EzeestiCore

/// Prompt that asks EstLLM to translate Estonian text into natural English
/// and explain it one phrase group at a time.
public struct TextTranslationPrompt {
    public let estonian: String

    public init(estonian: String) {
        self.estonian = estonian
    }

    public var system: String {
        """
        You are an Estonian→English translator and tutor who writes the way a native English speaker would.
        Always respond with ONLY valid JSON. Keys:
        - translation: natural English translation of the whole input
        - breakdown: array covering the input in order, one entry per phrase group. Each entry:
          - estonian: the word or phrase exactly as it appears in the input
          - english: what that piece means here
          - literal: the word-by-word sense, only when it differs from english; "" otherwise
          - note: one short clause of case/ending/idiom help; "" when there is nothing useful

        Rules:
        - Group words that work together (verb + object, noun + its case ending), 1–4 words per entry.
        - Every word of the input appears in exactly one entry, in the original order.
        - Translate meaning, not words. Estonian metaphors become the equivalent English
          expression, never a word-by-word calque:
          - "millegi võtmes" is not "in the key of something" — võtmes is the inessive of
            võti (key), and the phrase means the event has that theme, flavour, or spirit.
          - "toimub" is usually "takes place" / "is held", or fold it into the English subject.
        - In note, name the case or the metaphor rather than restating the translation.
        - Keep personal and place names as written unless a standard English form exists.
        - Assume the input may have typos or wrong diacritics (o/ō for õ); read through them.

        Example shape (replace every string with content for THIS input; never copy example wording):
        {"translation":"I went to the market yesterday.","breakdown":[{"estonian":"Ma käisin","english":"I went","literal":"","note":"käisin is past tense of käima, to go somewhere and come back"},{"estonian":"eile","english":"yesterday","literal":"","note":""},{"estonian":"turul","english":"at the market","literal":"market-at","note":"adessive -l carries 'at', so no separate preposition"}]}

        Do not wrap the JSON in markdown fences. No other keys. No commentary.
        """
    }

    public var user: String {
        """
        Estonian text:
        \(estonian)

        Translate into English, then break it down.
        """
    }
}

/// One phrase group of a translation, with optional literal sense and a learner note.
public struct TranslationChunk: Codable, Sendable, Hashable {
    public let estonian: String
    public let english: String
    /// Word-by-word sense when it differs from `english` (empty when it does not).
    public let literal: String
    /// Short case / ending / idiom hint (empty when the model had nothing useful).
    public let note: String

    public init(estonian: String, english: String, literal: String = "", note: String = "") {
        self.estonian = estonian
        self.english = english
        self.literal = literal
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        estonian = try container.decode(String.self, forKey: .estonian)
        english = try container.decode(String.self, forKey: .english)
        literal = try container.decodeIfPresent(String.self, forKey: .literal) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// English translation plus the phrase-by-phrase breakdown shown under it.
public struct TextTranslationResult: Codable, Sendable, Hashable {
    public let translation: String
    public let breakdown: [TranslationChunk]

    public init(translation: String, breakdown: [TranslationChunk] = []) {
        self.translation = translation
        self.breakdown = breakdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translation = try container.decode(String.self, forKey: .translation)
        breakdown = try container.decodeIfPresent([TranslationChunk].self, forKey: .breakdown) ?? []
    }
}

/// Parses translation JSON from EstLLM; falls back to a plain reply when the text is not JSON-like.
public enum TextTranslationParser {
    public static func parse(_ raw: String) -> TextTranslationResult? {
        if let payload = LLMJSON.decodeIfPresent(TextTranslationResult.self, from: raw) {
            return clean(payload)
        }

        let trimmed = LLMJSON.stripMarkdownFences(raw)
        let looksLikeJSON = trimmed.contains("{") || trimmed.contains("}")
        if !looksLikeJSON, !trimmed.isEmpty {
            return clean(TextTranslationResult(translation: trimmed))
        }
        return nil
    }

    /// Trims every field and drops breakdown entries the model left half-empty.
    private static func clean(_ result: TextTranslationResult) -> TextTranslationResult? {
        let translation = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else { return nil }

        let breakdown = result.breakdown.compactMap { chunk -> TranslationChunk? in
            let estonian = chunk.estonian.trimmingCharacters(in: .whitespacesAndNewlines)
            let english = chunk.english.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !estonian.isEmpty, !english.isEmpty else { return nil }
            var literal = chunk.literal.trimmingCharacters(in: .whitespacesAndNewlines)
            if literal.caseInsensitiveCompare(english) == .orderedSame {
                literal = ""
            }
            return TranslationChunk(
                estonian: estonian,
                english: english,
                literal: literal,
                note: chunk.note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return TextTranslationResult(translation: translation, breakdown: breakdown)
    }
}
