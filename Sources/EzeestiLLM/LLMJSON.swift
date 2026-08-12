import Foundation
import EzeestiCore

/// Shared helpers for EstLLM JSON replies (markdown fences + brace-balanced object slices).
enum LLMJSON {
    /// Removes a leading ``` / ```json fence and a matching trailing ``` fence.
    static func stripMarkdownFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasPrefix("```") else { return result }

        // Drop the opening fence line (``` or ```json).
        if let firstNewline = result.firstIndex(of: "\n") {
            result = String(result[result.index(after: firstNewline)...])
        } else {
            result.removeFirst(3)
            if result.lowercased().hasPrefix("json") {
                result = String(result.dropFirst(4))
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the first brace-balanced `{ ... }` slice, respecting string literals.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Decode `T` from raw model text: stripped body first, then embedded JSON object.
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let trimmed = stripMarkdownFences(raw)
        var lastError: Error?

        if let data = trimmed.data(using: .utf8) {
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                lastError = error
            }
        }

        if let slice = extractJSONObject(from: trimmed),
           let data = slice.data(using: .utf8) {
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? EzeestiError.llmFailed("Could not decode \(T.self) from model response")
    }

    /// Soft decode that returns `nil` when JSON is absent or invalid.
    static func decodeIfPresent<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        try? decode(type, from: raw)
    }
}
