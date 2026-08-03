import Foundation

public struct TextToken: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let surface: String
    public let normalized: String
    public let isWord: Bool

    public init(index: Int, surface: String, normalized: String, isWord: Bool) {
        self.index = index
        self.surface = surface
        self.normalized = normalized
        self.isWord = isWord
    }
}

public enum EstonianTokenizer {
    /// Split text into word / non-word tokens. Lemma ≈ lowercased surface (Vabamorf later).
    public static func tokenize(_ text: String) -> [TextToken] {
        var tokens: [TextToken] = []
        var index = 0
        var current = ""
        var currentIsWord: Bool?

        func flush() {
            guard !current.isEmpty, let isWord = currentIsWord else { return }
            let surface = current
            let normalized = normalize(surface)
            tokens.append(TextToken(index: index, surface: surface, normalized: normalized, isWord: isWord))
            index += 1
            current = ""
            currentIsWord = nil
        }

        for ch in text {
            let isWordChar = ch.isLetter || ch == "'" || ch == "-" || ch == "’"
            if currentIsWord == nil {
                currentIsWord = isWordChar
                current.append(ch)
            } else if currentIsWord == isWordChar {
                current.append(ch)
            } else {
                flush()
                currentIsWord = isWordChar
                current.append(ch)
            }
        }
        flush()
        return tokens
    }

    public static func normalize(_ surface: String) -> String {
        surface
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "«»\"“”„"))
    }

    public static func wordLemmas(in text: String) -> [String] {
        tokenize(text).filter(\.isWord).map(\.normalized)
    }
}
