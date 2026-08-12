import Foundation
import Observation
import AppKit
import EzeestiCore
import EzeestiASR
import EzeestiLLM
import EzeestiTTS

/// Coordinates lesson practice: record → Whisper → EstLLM feedback → optional Neurokõne.
@Observable
@MainActor
public final class TutorEngine {
    /// User-visible practice phase. Errors keep a display message plus a debug dump of the underlying failure.
    public enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case tutoring
        case feedback
        case speaking
        case completedItem
        case error(PhaseFailure)
    }

    /// Structured phase failure so UI can show `message` while logs retain type info.
    public struct PhaseFailure: Equatable, Sendable {
        public let message: String
        public let debugDescription: String

        public init(message: String, debugDescription: String? = nil) {
            self.message = message
            self.debugDescription = debugDescription ?? message
        }

        public init(from error: Error) {
            self.message = error.localizedDescription
            self.debugDescription = String(describing: error)
        }
    }

    public enum WarmupState: Equatable {
        case pending
        case loadingWhisper
        case loadingTutor
        case loadingVoice
        case ready
    }

    private static let speechLanguageCode = "et-EE"

    public private(set) var phase: Phase = .idle
    public private(set) var warmupState: WarmupState = .pending
    public private(set) var warmupDetail: String = "Starting…"
    public private(set) var packs: [LessonPack] = []
    public private(set) var selectedPack: LessonPack?
    public private(set) var itemIndex: Int = 0
    public private(set) var lastTranscript: String = ""
    public private(set) var lastFeedback: TutorFeedback?
    public var isWarmupFinished: Bool {
        warmupState == .ready
    }

    public let recorder: MicrophoneRecorder

    private var recognizer: any SpeechRecognizing
    private var languageModel: any LanguageModeling
    private var speaker: any TextSpeaking
    private let modelPaths: ModelPaths
    /// Ignored by Observation; `deinit` removes the token without a MainActor hop.
    @ObservationIgnored
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

    public var currentItem: LessonItem? {
        guard let pack = selectedPack else { return nil }
        guard itemIndex >= 0, itemIndex < pack.items.count else { return nil }
        return pack.items[itemIndex]
    }

    public init(
        modelPaths: ModelPaths? = nil,
        recorder: MicrophoneRecorder? = nil,
        recognizer: (any SpeechRecognizing)? = nil,
        languageModel: (any LanguageModeling)? = nil,
        speaker: (any TextSpeaking)? = nil
    ) throws {
        let paths: ModelPaths
        if let modelPaths {
            paths = modelPaths
        } else {
            paths = try ModelPaths.defaultApplicationSupport()
        }
        self.modelPaths = paths
        self.recorder = recorder ?? MicrophoneRecorder()

        if let recognizer {
            self.recognizer = recognizer
        } else if paths.whisperNativeReady, let model = paths.whisperGGML, let lib = paths.whisperLibDir {
            self.recognizer = WhisperCppService(modelPath: model, libDir: lib)
        } else {
            throw EzeestiError.modelMissing("Whisper weights or libEzeestiWhisper.dylib")
        }

        if let languageModel {
            self.languageModel = languageModel
        } else if paths.llamaNativeReady, let model = paths.estLLMGGUF, let lib = paths.llamaLibDir {
            self.languageModel = LlamaCppService(modelPath: model, libDir: lib)
        } else {
            throw EzeestiError.modelMissing("EstLLM weights or libEzeestiLlama.dylib")
        }

        if let speaker {
            self.speaker = speaker
        } else if let cli = paths.neurokoneBinary,
                  FileManager.default.isExecutableFile(atPath: cli.path) {
            self.speaker = NeurokoneTTSService(binaryPath: cli)
        } else {
            throw EzeestiError.modelMissing("neurokone-cli. Run Scripts/setup-neurokone.sh")
        }

        // Free Metal-backed models before process teardown (avoids ggml residency-set assert).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.shutdownNativeModels()
            }
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    /// Unload in-process Whisper / EstLLM before Metal / process teardown.
    func shutdownNativeModels() async {
        await recognizer.shutdown()
        await languageModel.shutdown()
    }

    /// Load bundled lesson packs and select the first pack when none is selected.
    public func loadLessons() {
        do {
            packs = try LessonCatalog.loadBundled()
            if selectedPack == nil {
                selectedPack = packs.first
                itemIndex = 0
            }
        } catch {
            fail(error)
        }
    }

    /// Preload Whisper (kept warm), prime EstLLM, then warm Neurokõne before practice.
    public func warmupModels() async throws {
        warmupState = .loadingWhisper
        warmupDetail = "Loading Whisper on GPU…"
        try await recognizer.warmup()

        warmupState = .loadingTutor
        warmupDetail = "Priming EstLLM…"
        try await languageModel.warmup()

        warmupState = .loadingVoice
        warmupDetail = "Loading Neurokõne voice (once)…"
        try await speaker.prepare()

        warmupDetail = "Ready"
        warmupState = .ready
    }

    /// Switch the active lesson pack and reset item progress.
    public func selectPack(_ pack: LessonPack) {
        selectedPack = pack
        itemIndex = 0
        lastFeedback = nil
        lastTranscript = ""
        phase = .idle
    }

    /// Request mic permission and begin recording the current item.
    public func startRecording() async {
        let permitted = await recorder.requestPermission()
        guard permitted else {
            fail("Microphone permission denied")
            return
        }
        do {
            try await recorder.startRecording()
            phase = .recording
        } catch {
            fail(error)
        }
    }

    /// Stop recording, transcribe, and ask EstLLM for tutoring feedback.
    public func stopAndEvaluate() async {
        guard let pack = selectedPack, let item = currentItem else {
            fail("No lesson selected")
            return
        }

        do {
            let audioURL = try await recorder.stopRecording()
            phase = .transcribing
            let transcript = try await recognizer.transcribe(audioURL: audioURL)
            lastTranscript = transcript.text

            phase = .tutoring
            let prompt = GrammarTutorPrompt(target: item, pack: pack, transcript: transcript.text)

            let raw = try await languageModel.complete(system: prompt.system, user: prompt.user)
            let feedback = try TutorFeedbackParser.parse(raw)

            lastFeedback = feedback
            // Do NOT auto-play Neurokõne here — loading TF+vocoder while Whisper is warm
            // is slow and memory-heavy. EstLLM already unloads after each tutoring turn.
            // User can tap "Hear target" / hear-correction explicitly.
            phase = feedback.verdict == .correct ? .completedItem : .feedback
        } catch {
            fail(error)
        }
    }

    /// Speak the last correction via Neurokõne.
    public func speakCorrection() async {
        guard let correction = lastFeedback?.correction else { return }
        do {
            phase = .speaking
            try await speaker.speak(correction, languageCode: Self.speechLanguageCode)
            phase = lastFeedback?.verdict == .correct ? .completedItem : .feedback
        } catch {
            fail(error)
        }
    }

    /// Advance to the next lesson item (wraps to the first item after the last).
    public func advanceToNextItem() {
        guard let pack = selectedPack, !pack.items.isEmpty else { return }
        itemIndex = (itemIndex + 1) % pack.items.count
        lastFeedback = nil
        lastTranscript = ""
        phase = .idle
    }

    /// Clear the last attempt and return to idle for the current item.
    public func retryCurrent() {
        lastFeedback = nil
        lastTranscript = ""
        phase = .idle
    }

    /// Speak the current target sentence via Neurokõne.
    public func speakTarget() async {
        guard let item = currentItem else { return }
        do {
            phase = .speaking
            try await speaker.speak(item.targetEstonian, languageCode: Self.speechLanguageCode)
            phase = .idle
        } catch {
            fail(error)
        }
    }

    private func fail(_ message: String) {
        let failure = PhaseFailure(message: message)
        #if DEBUG
        print("TutorEngine failure: \(failure.debugDescription)")
        #endif
        phase = .error(failure)
    }

    private func fail(_ error: Error) {
        let failure = PhaseFailure(from: error)
        #if DEBUG
        print("TutorEngine failure: \(failure.debugDescription)")
        #endif
        phase = .error(failure)
    }
}
