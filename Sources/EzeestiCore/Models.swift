import Foundation

/// Common European Framework proficiency band used throughout the app.
public enum CEFRLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case a1 = "A1"
    case a2 = "A2"
    case b1 = "B1"
    case b2 = "B2"
    case c1 = "C1"

    public var id: String { rawValue }
}

public struct LessonPack: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let cefr: CEFRLevel
    public let focusTip: String
    public let patternExplanation: String
    public let items: [LessonItem]

    public init(
        id: String,
        title: String,
        cefr: CEFRLevel,
        focusTip: String,
        patternExplanation: String,
        items: [LessonItem]
    ) {
        self.id = id
        self.title = title
        self.cefr = cefr
        self.focusTip = focusTip
        self.patternExplanation = patternExplanation
        self.items = items
    }
}

public struct LessonItem: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let targetEstonian: String
    public let glossEnglish: String
    public let focusTip: String?

    public init(id: String, targetEstonian: String, glossEnglish: String, focusTip: String? = nil) {
        self.id = id
        self.targetEstonian = targetEstonian
        self.glossEnglish = glossEnglish
        self.focusTip = focusTip
    }
}

public struct Transcript: Sendable, Hashable {
    public let text: String
    public let languageHint: String
    public let durationSeconds: TimeInterval

    public init(text: String, languageHint: String = "et", durationSeconds: TimeInterval = 0) {
        self.text = text
        self.languageHint = languageHint
        self.durationSeconds = durationSeconds
    }
}

public enum TutorVerdict: String, Codable, Sendable {
    case correct
    case close
    case incorrect
}

public struct TutorFeedback: Codable, Sendable, Hashable {
    public let verdict: TutorVerdict
    public let correction: String
    public let explanation: String
    public let retryPrompt: String

    public init(verdict: TutorVerdict, correction: String, explanation: String, retryPrompt: String) {
        self.verdict = verdict
        self.correction = correction
        self.explanation = explanation
        self.retryPrompt = retryPrompt
    }
}

/// Locations of on-disk Whisper / EstLLM / Neurokõne artifacts under Application Support.
/// Prefer the `defaultApplicationSupport()` factory (creates the Models root) over manual path plumbing.
public struct ModelPaths: Sendable {
    public let whisperGGML: URL?
    public let estLLMGGUF: URL?
    /// Directory containing `libEzeestiWhisper.dylib` (+ whisper/ggml deps).
    public let whisperLibDir: URL?
    /// Directory containing `libEzeestiLlama.dylib` (+ llama/ggml deps).
    public let llamaLibDir: URL?
    public let neurokoneBinary: URL?

    public init(
        whisperGGML: URL? = nil,
        estLLMGGUF: URL? = nil,
        whisperLibDir: URL? = nil,
        llamaLibDir: URL? = nil,
        neurokoneBinary: URL? = nil
    ) {
        self.whisperGGML = whisperGGML
        self.estLLMGGUF = estLLMGGUF
        self.whisperLibDir = whisperLibDir
        self.llamaLibDir = llamaLibDir
        self.neurokoneBinary = neurokoneBinary
    }

    public var whisperNativeReady: Bool {
        guard let model = whisperGGML, let lib = whisperLibDir else { return false }
        let dylib = lib.appendingPathComponent("libEzeestiWhisper.dylib")
        return Self.isReachable(model) && Self.isReachable(dylib)
    }

    public var llamaNativeReady: Bool {
        guard let model = estLLMGGUF, let lib = llamaLibDir else { return false }
        let dylib = lib.appendingPathComponent("libEzeestiLlama.dylib")
        return Self.isReachable(model) && Self.isReachable(dylib)
    }

    /// Creates `Application Support/Ezeesti/Models` if needed and returns the conventional artifact paths.
    public static func defaultApplicationSupport() throws -> ModelPaths {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Ezeesti/Models", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        return ModelPaths(
            whisperGGML: root.appendingPathComponent("whisper/ggml-model.bin"),
            estLLMGGUF: root.appendingPathComponent("llm/Llama-3.1-EstLLM-8B-Instruct-1125.Q4_K_M.gguf"),
            whisperLibDir: root.appendingPathComponent("native/whisper/lib", isDirectory: true),
            llamaLibDir: root.appendingPathComponent("native/llama/lib", isDirectory: true),
            neurokoneBinary: root.appendingPathComponent("bin/neurokone-cli")
        )
    }

    private static func isReachable(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true
    }
}

/// User-facing failures from recording, models, and bundled content.
public enum EzeestiError: Error, LocalizedError, Sendable {
    case modelMissing(String)
    case recordingFailed(String)
    case transcriptionFailed(String)
    case llmFailed(String)
    case ttsFailed(String)
    case invalidLessonData(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let name): return "Model missing: \(name). Run Scripts/fetch-models.sh"
        case .recordingFailed(let reason): return "Recording failed: \(reason)"
        case .transcriptionFailed(let reason): return "Transcription failed: \(reason)"
        case .llmFailed(let reason): return "Tutor model failed: \(reason)"
        case .ttsFailed(let reason): return "Speech synthesis failed: \(reason)"
        case .invalidLessonData(let reason): return "Invalid lesson data: \(reason)"
        }
    }
}
