import Foundation
import EzeestiCore

public struct WordGlossPrompt {
    public let surface: String
    public let lemma: String
    public let contextSentence: String
    public let cefr: CEFRLevel?
    public let pos: String

    public init(
        surface: String,
        lemma: String,
        contextSentence: String,
        cefr: CEFRLevel?,
        pos: String
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
        if !pos.isEmpty {
            lines.append("POS: \(pos)")
        }
        if !contextSentence.isEmpty {
            lines.append("Context sentence: \(contextSentence)")
        }
        lines.append("Give the English gloss for this Estonian word.")
        return lines.joined(separator: "\n")
    }
}

public enum WordGlossParser {
    private struct Payload: Decodable {
        let gloss: String
    }

    public static func parse(_ raw: String) -> String? {
        let trimmed = stripMarkdownFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return clean(payload.gloss)
        }
        if let slice = extractJSONObject(from: trimmed),
           let data = slice.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return clean(payload.gloss)
        }
        // Last resort: treat a short plain reply as the gloss.
        if trimmed.count <= 80, !trimmed.contains("{"), !trimmed.isEmpty {
            return clean(trimmed)
        }
        return nil
    }

    private static func clean(_ gloss: String) -> String? {
        let g = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? nil : g
    }

    private static func stripMarkdownFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: "```json", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return String(text[start...end])
    }
}
