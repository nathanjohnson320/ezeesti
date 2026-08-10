import Foundation
import EzeestiCore

/// Heuristic tutor used when EstLLM weights / native libs are not present yet.
public struct RuleBasedLanguageModel: LanguageModeling {
    public init() {}

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        _ = maxTokens
        try await Task.sleep(nanoseconds: 250_000_000)

        if system.contains("Estonian–English dictionary") || system.contains("\"gloss\"") {
            let word = extractField("Word:", from: user) ?? "word"
            if let bundled = WordGlossCatalog.gloss(forSurface: word) {
                return #"{"gloss":"\#(escapeJSON(bundled))"}"#
            }
            return #"{"gloss":"(EstLLM not installed — run fetch-models.sh)"}"#
        }

        if system.contains("graded Estonian reading passages")
            || system.contains("one short graded Estonian sentence")
            || user.contains("Write one new passage that teaches these focus lemmas:")
            || user.contains("Write one short scene that naturally uses these focus lemma")
            || user.contains("Write one short, coherent Estonian sentence that naturally uses these focus lemma")
            || user.contains("Write one short, useful Estonian sentence that naturally teaches this focus lemma")
            || user.contains("Write one useful Estonian sentence (about 8–16 words) that naturally teaches this focus lemma") {
            return try makePassageJSON(from: user)
        }

        if system.contains("strict Estonian editor")
            || user.contains("Validate or rewrite. Return JSON only.") {
            return try makeValidationJSON(from: user)
        }

        let said = extractField("Learner said (ASR transcript):", from: user) ?? ""

        if system.contains("spoken summary")
            || system.contains("read a target sentence aloud")
            || user.contains("Required words the learner must use:")
            || user.contains("Focus words to cover:") {
            let requiredLine =
                extractField("Focus words to cover:", from: user)
                ?? extractField("Required words the learner must use:", from: user)
                ?? ""
            let mustUse = requiredLine
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let source = extractBlock(after: "Target sentence:", until: "English gloss:", from: user)
                ?? extractBlock(after: "Source text:", until: "English gloss:", from: user)
                ?? extractField("Target sentence:", from: user)
                ?? extractField("Source text:", from: user)
                ?? ""
            let feedback = SpokenSummaryFeedbackParser.heuristic(
                mustUse: mustUse,
                transcript: said,
                sourceBody: source
            )
            let data = try JSONEncoder().encode(feedback)
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        let target = extractField("Target sentence:", from: user) ?? ""

        let normalizedTarget = normalize(target)
        let normalizedSaid = normalize(said)

        let feedback: TutorFeedback
        if normalizedSaid == normalizedTarget || normalizedSaid.hasPrefix(normalizedTarget.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            feedback = TutorFeedback(
                verdict: .correct,
                correction: target,
                explanation: "Nice — that matches the pattern.",
                retryPrompt: "Great. Try the next example."
            )
        } else if looksLikeWrongCase(said: said, target: target) {
            feedback = TutorFeedback(
                verdict: .close,
                correction: target,
                explanation: "Close! After minema, the destination usually takes the illative. Try: \(target)",
                retryPrompt: "Say: \(target)"
            )
        } else {
            feedback = TutorFeedback(
                verdict: .incorrect,
                correction: target,
                explanation: "Not quite. Aim for: \(target)",
                retryPrompt: "Repeat: \(target)"
            )
        }

        let data = try JSONEncoder().encode(feedback)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func makePassageJSON(from user: String) throws -> String {
        let cefrRaw = extractField("CEFR level:", from: user) ?? "A1"
        let cefr = CEFRLevel(rawValue: cefrRaw) ?? .a1
        let lemmas = extractFocusLemmas(from: user)
        var glosses: [String: String] = [:]
        for lemma in lemmas {
            if let gloss = WordGlossCatalog.gloss(forSurface: lemma) {
                glosses[lemma] = gloss
            }
        }
        let text = PassageGenerationParser.heuristic(
            requiredFocus: lemmas,
            cefr: cefr,
            glosses: glosses
        )
        let draft = PassageDraft(
            title: text.title,
            body: text.body,
            glossEnglish: text.glossEnglish,
            focusWords: text.focusWords
        )
        let data = try JSONEncoder().encode(draft)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func makeValidationJSON(from user: String) throws -> String {
        let cefrRaw = extractField("CEFR level:", from: user) ?? "A1"
        let cefr = CEFRLevel(rawValue: cefrRaw) ?? .a1
        let focusLine = extractField("Focus lemma(s) that must appear:", from: user) ?? ""
        let lemmas = focusLine
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let focus = lemmas.isEmpty ? extractFocusLemmas(from: user) : lemmas

        var glosses: [String: String] = [:]
        for lemma in focus {
            if let gloss = WordGlossCatalog.gloss(forSurface: lemma) {
                glosses[lemma] = gloss
            }
        }

        let draftBody = extractField("Draft body:", from: user) ?? ""
        let draftTitle = extractField("Draft title:", from: user) ?? "Täna"
        let draftGloss = extractField("Draft English gloss:", from: user) ?? ""
        let draft = PassageDraft(
            title: draftTitle,
            body: draftBody,
            glossEnglish: draftGloss,
            focusWords: focus
        )

        let validated = SentenceValidationParser.heuristic(
            draft: draft,
            requiredFocus: focus,
            cefr: cefr,
            glosses: glosses
        )
        let ok = EstonianTokenizer.normalize(validated.body)
            == EstonianTokenizer.normalize(draftBody)
        let result = SentenceValidationResult(
            ok: ok,
            title: validated.title,
            body: validated.body,
            glossEnglish: validated.glossEnglish,
            focusWords: validated.focusWords,
            reason: ok ? "Draft passed offline checks." : "Rewrote draft with offline heuristic."
        )
        let data = try JSONEncoder().encode(result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func extractFocusLemmas(from user: String) -> [String] {
        let markers = [
            "Write one useful Estonian sentence (about 8–16 words) that naturally teaches this focus lemma:",
            "Write one short, useful Estonian sentence that naturally teaches this focus lemma:",
            "Focus lemma(s) that must appear:",
            "Write one short, coherent Estonian sentence that naturally uses these focus lemma(s):",
            "Write one short scene that naturally uses these focus lemma(s) in context:",
            "Write one new passage that teaches these focus lemmas:",
        ]
        for marker in markers {
            guard let range = user.range(of: marker) else { continue }
            let after = user[range.upperBound...]
            let line = after.prefix(while: { $0 != "\n" })
            let lemmas = line
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !lemmas.isEmpty { return lemmas }
        }
        return ["lähen", "tahan"]
    }

    private func escapeJSON(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func extractField(_ label: String, from text: String) -> String? {
        guard let range = text.range(of: label) else { return nil }
        let after = text[range.upperBound...]
        let line = after.prefix(while: { $0 != "\n" })
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractBlock(after startLabel: String, until endLabel: String, from text: String) -> String? {
        guard let start = text.range(of: startLabel) else { return nil }
        let afterStart = text[start.upperBound...]
        let body: Substring
        if let end = afterStart.range(of: endLabel) {
            body = afterStart[..<end.lowerBound]
        } else {
            body = afterStart
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeWrongCase(said: String, target: String) -> Bool {
        let saidTokens = normalize(said).split(separator: " ")
        let targetTokens = normalize(target).split(separator: " ")
        guard saidTokens.count >= 2, targetTokens.count >= 2 else { return false }
        return saidTokens.prefix(2) == targetTokens.prefix(2) && saidTokens.last != targetTokens.last
    }
}
