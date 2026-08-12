import Foundation
import EzeestiCore

/// Prompt that asks EstLLM for a short English gloss of one Estonian surface.
public struct WordGlossPrompt {
    public let surface: String
    public let lemma: String
    public let contextSentence: String
    public let cefr: CEFRLevel?
    /// Coarse POS tag from the lexicon when known.
    public let pos: String?

    public init(
        surface: String,
        lemma: String,
        contextSentence: String,
        cefr: CEFRLevel?,
        pos: String?
    ) {
        self.surface = surface
        self.lemma = lemma
        self.contextSentence = contextSentence
        self.cefr = cefr
        self.pos = pos
    }

    public var system: String {
        """
        You are a concise Estonian–English dictionary for language learners.
        Always respond with ONLY valid JSON:
        {"gloss":"short English meaning of the word in this context"}
        Keep gloss under 12 words. Prefer the sense that fits the context sentence.
        Do not wrap the JSON in markdown fences. No other keys.
        """
    }

    public var user: String {
        var lines = [
            "Word: \(surface)",
            "Lemma: \(lemma)",
        ]
        if let cefr {
            lines.append("CEFR: \(cefr.rawValue)")
        }
        if let pos, !pos.isEmpty {
            lines.append("POS: \(pos)")
        }
        if !contextSentence.isEmpty {
            lines.append("Context sentence: \(contextSentence)")
        }
        lines.append("Give the English gloss for this Estonian word.")
        return lines.joined(separator: "\n")
    }
}

/// Parses `{"gloss":"..."}` from EstLLM; falls back to a short plain reply only when the text is not JSON-like.
public enum WordGlossParser {
    private struct Payload: Decodable {
        let gloss: String
    }

    public static func parse(_ raw: String) -> String? {
        if let payload = LLMJSON.decodeIfPresent(Payload.self, from: raw) {
            return clean(payload.gloss)
        }

        let trimmed = LLMJSON.stripMarkdownFences(raw)
        // Last resort: treat a short plain reply as the gloss when it clearly is not JSON.
        let looksLikeJSON = trimmed.contains("{") || trimmed.contains("}")
        if !looksLikeJSON, trimmed.count <= 80, !trimmed.isEmpty {
            return clean(trimmed)
        }
        return nil
    }

    private static func clean(_ gloss: String) -> String? {
        let g = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? nil : g
    }
}
