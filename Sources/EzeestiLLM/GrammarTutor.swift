import Foundation
import EzeestiCore

public protocol LanguageModeling: Sendable {
    /// - Parameter temperature: Overrides the model default; used to resample
    ///   when a first, low-temperature draft fails validation.
    func complete(
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> String
    /// Optional preload / prime so the first completion is faster.
    func warmup() async throws
    /// Unload native/Metal resources while the process is still healthy (e.g. app terminate).
    func shutdown() async
}

public extension LanguageModeling {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, temperature: nil)
    }

    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, maxTokens: 160, temperature: nil)
    }

    func warmup() async throws {}

    func shutdown() async {}
}

/// Prompt that asks EstLLM to grade a lesson-item transcript as JSON `TutorFeedback`.
public struct GrammarTutorPrompt {
    public let target: LessonItem
    public let pack: LessonPack
    public let transcript: String

    public init(target: LessonItem, pack: LessonPack, transcript: String) {
        self.target = target
        self.pack = pack
        self.transcript = transcript
    }

    public var system: String {
        """
        You are a patient Estonian language tutor for CEFR \(pack.cefr.rawValue) learners.
        Speak simply. Explain at most ONE mistake. Prefer short English explanations with Estonian examples.
        Always respond with ONLY valid JSON matching this schema:
        {
          "verdict": "correct" | "close" | "incorrect",
          "correction": "corrected Estonian sentence",
          "explanation": "one short teacher explanation",
          "retryPrompt": "short instruction telling the learner what to say next"
        }
        Do not wrap the JSON in markdown fences.
        """
    }

    public var user: String {
        let tip = target.focusTip ?? pack.focusTip
        return """
        Lesson focus: \(pack.title)
        Pattern: \(pack.patternExplanation)
        Tip: \(tip)
        Target sentence: \(target.targetEstonian)
        English gloss: \(target.glossEnglish)
        Learner said (ASR transcript): \(transcript)

        Compare the learner transcript to the target. Be lenient with punctuation and capitalization.
        If the grammar/case pattern is right, verdict=correct even if wording differs slightly.
        If close (wrong case but intent clear), verdict=close.
        """
    }
}

/// Decodes tutor grading JSON from EstLLM (throws when the reply is not usable feedback).
public enum TutorFeedbackParser {
    public static func parse(_ raw: String) throws -> TutorFeedback {
        try LLMJSON.decode(TutorFeedback.self, from: raw)
    }
}
