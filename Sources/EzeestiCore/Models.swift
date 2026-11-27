import Foundation
import Darwin

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

/// Physical RAM via `hw.memsize` (file-level so default args can reference it).
public func ezeestiPhysicalMemoryBytes() -> UInt64 {
    var size: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    let result = sysctlbyname("hw.memsize", &size, &len, nil, 0)
    return result == 0 ? size : 0
}

/// Known EstLLM MLX variants, ordered by quality (higher priority wins when RAM allows).
///
/// `directoryName` is both the on-disk folder under `Models/llm/` and the default OMLX model id.
public struct EstLLMVariant: Sendable, Hashable, Identifiable {
    public let id: String
    /// Hugging Face source repo used by `Scripts/fetch-models.sh`.
    public let hfRepo: String
    /// Directory name under Application Support / OMLX model id after MLX conversion.
    public let directoryName: String
    /// Minimum physical RAM recommended before selecting this variant automatically.
    public let minMemoryBytes: UInt64
    /// Higher = preferred when installed and memory allows.
    public let priority: Int

    public init(
        id: String,
        hfRepo: String,
        directoryName: String,
        minMemoryBytes: UInt64,
        priority: Int
    ) {
        self.id = id
        self.hfRepo = hfRepo
        self.directoryName = directoryName
        self.minMemoryBytes = minMemoryBytes
        self.priority = priority
    }

    /// 70B instruct 4-bit MLX — best tutoring quality; needs ~48 GiB unified memory.
    public static let seventyB = EstLLMVariant(
        id: "70b",
        hfRepo: "tartuNLP/Llama-3.1-EstLLM-70B-Instruct-0826",
        directoryName: "Llama-3.1-EstLLM-70B-Instruct-0826-4bit",
        minMemoryBytes: 48 * 1024 * 1024 * 1024,
        priority: 200
    )

    /// 8B instruct 4-bit MLX — default for smaller Apple Silicon Macs.
    public static let eightB = EstLLMVariant(
        id: "8b",
        hfRepo: "tartuNLP/Llama-3.1-EstLLM-8B-Instruct-1125",
        directoryName: "Llama-3.1-EstLLM-8B-Instruct-1125-4bit",
        minMemoryBytes: 8 * 1024 * 1024 * 1024,
        priority: 100
    )

    public static let all: [EstLLMVariant] = [.seventyB, .eightB]

    /// Best variant for the current machine's physical RAM (ignores what is installed).
    public static func recommended(forMemoryBytes memory: UInt64 = ezeestiPhysicalMemoryBytes()) -> EstLLMVariant {
        all
            .filter { memory >= $0.minMemoryBytes }
            .max(by: { $0.priority < $1.priority })
            ?? .eightB
    }
}

/// Locations of on-disk MLX model dirs / Neurokõne under Application Support.
/// Prefer the `defaultApplicationSupport()` factory (creates the Models root) over manual path plumbing.
///
/// Pass the Models root to `omlx serve --model-dir`.
public struct ModelPaths: Sendable {
    /// Root directory passed to `omlx serve --model-dir`.
    public let modelsRoot: URL
    /// Converted TalTech Whisper MLX directory (served by OMLX STT).
    public let whisperDirectory: URL?
    /// Converted EstLLM MLX directory (served by OMLX chat).
    public let estLLMDirectory: URL?
    public let neurokoneBinary: URL?

    public static let defaultWhisperDirectoryName = "whisper-large-v3-turbo-et-verbatim-2604-mlx"

    public init(
        modelsRoot: URL,
        whisperDirectory: URL? = nil,
        estLLMDirectory: URL? = nil,
        neurokoneBinary: URL? = nil
    ) {
        self.modelsRoot = modelsRoot
        self.whisperDirectory = whisperDirectory
        self.estLLMDirectory = estLLMDirectory
        self.neurokoneBinary = neurokoneBinary
    }

    /// True when the Whisper MLX conversion directory exists and looks non-empty.
    public var whisperReady: Bool {
        guard let dir = whisperDirectory else { return false }
        return Self.isModelDirectoryReady(dir)
    }

    /// True when the EstLLM MLX conversion directory exists and looks non-empty.
    public var llmReady: Bool {
        guard let dir = estLLMDirectory else { return false }
        return Self.isModelDirectoryReady(dir)
    }

    /// Creates `Application Support/Ezeesti/Models` if needed and returns conventional MLX paths.
    public static func defaultApplicationSupport() throws -> ModelPaths {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Ezeesti/Models", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let llmParent = root.appendingPathComponent("llm", isDirectory: true)
        try FileManager.default.createDirectory(at: llmParent, withIntermediateDirectories: true)
        let whisperParent = root.appendingPathComponent("whisper", isDirectory: true)
        try FileManager.default.createDirectory(at: whisperParent, withIntermediateDirectories: true)

        let estLLM = resolveEstLLMDirectory(in: llmParent)
            ?? llmParent.appendingPathComponent(EstLLMVariant.recommended().directoryName, isDirectory: true)

        let whisper = whisperParent.appendingPathComponent(defaultWhisperDirectoryName, isDirectory: true)

        return ModelPaths(
            modelsRoot: root,
            whisperDirectory: whisper,
            estLLMDirectory: estLLM,
            neurokoneBinary: root.appendingPathComponent("bin/neurokone-cli")
        )
    }

    /// Pick the best installed EstLLM MLX directory for this Mac.
    ///
    /// Order: `EZEESTI_LLM_DIR` override → highest-priority installed variant that fits RAM →
    /// largest installed variant (undersized-RAM fallback) → `nil` if nothing is on disk.
    public static func resolveEstLLMDirectory(
        in llmParent: URL,
        memoryBytes: UInt64 = ezeestiPhysicalMemoryBytes(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["EZEESTI_LLM_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if isModelDirectoryReady(url) { return url }
        }

        let installed = EstLLMVariant.all.compactMap { variant -> (EstLLMVariant, URL)? in
            let url = llmParent.appendingPathComponent(variant.directoryName, isDirectory: true)
            guard isModelDirectoryReady(url) else { return nil }
            return (variant, url)
        }

        guard !installed.isEmpty else { return nil }

        if let fit = installed
            .filter({ memoryBytes >= $0.0.minMemoryBytes })
            .max(by: { $0.0.priority < $1.0.priority })
        {
            return fit.1
        }

        // Force-converted larger model on a smaller Mac — still try it.
        return installed.max(by: { $0.0.priority < $1.0.priority })?.1
    }

    public static func physicalMemoryBytes() -> UInt64 {
        ezeestiPhysicalMemoryBytes()
    }

    /// A converted MLX model dir is ready when it exists and contains any file.
    public static func isModelDirectoryReady(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
        else { return false }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return !contents.isEmpty
    }
}

/// User-facing failures from recording, models, and bundled content.
public enum EzeestiError: Error, LocalizedError, Sendable {
    case modelMissing(String)
    case omlxUnavailable(String)
    case recordingFailed(String)
    case transcriptionFailed(String)
    case llmFailed(String)
    case ttsFailed(String)
    case invalidLessonData(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let name):
            return "Model missing: \(name). Run Scripts/fetch-models.sh then start OMLX."
        case .omlxUnavailable(let reason):
            return "OMLX unavailable: \(reason)"
        case .recordingFailed(let reason): return "Recording failed: \(reason)"
        case .transcriptionFailed(let reason): return "Transcription failed: \(reason)"
        case .llmFailed(let reason): return "Tutor model failed: \(reason)"
        case .ttsFailed(let reason): return "Speech synthesis failed: \(reason)"
        case .invalidLessonData(let reason): return "Invalid lesson data: \(reason)"
        }
    }
}
