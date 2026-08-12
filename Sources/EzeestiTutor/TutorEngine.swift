import Foundation
import AppKit
import EzeestiCore
import EzeestiASR
import EzeestiLLM
import EzeestiTTS

@MainActor
public final class TutorEngine: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case tutoring
        case feedback
        case speaking
        case completedItem
        case error(String)
    }

    public enum WarmupState: Equatable {
        case pending
        case loadingWhisper
        case loadingTutor
        case ready
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var warmupState: WarmupState = .pending
    @Published public private(set) var warmupDetail: String = "Starting…"
    @Published public private(set) var packs: [LessonPack] = []
    @Published public private(set) var selectedPack: LessonPack?
    @Published public private(set) var itemIndex: Int = 0
    @Published public private(set) var lastTranscript: String = ""
    @Published public private(set) var lastFeedback: TutorFeedback?
    public var isWarmupFinished: Bool {
        warmupState == .ready
    }

    public let recorder: MicrophoneRecorder

    private var recognizer: any SpeechRecognizing
    private var languageModel: any LanguageModeling
    private var speaker: any TextSpeaking
    private let modelPaths: ModelPaths
    private var terminateObserver: NSObjectProtocol?

    public var currentItem: LessonItem? {
        guard let pack = selectedPack, pack.items.indices.contains(itemIndex) else { return nil }
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
    public func shutdownNativeModels() async {
        await recognizer.shutdown()
        await languageModel.shutdown()
    }

    public func loadLessons() {
        do {
            packs = try LessonCatalog.loadBundled()
            if selectedPack == nil {
                selectedPack = packs.first
                itemIndex = 0
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Preload Whisper (kept warm) and prime EstLLM (load then unload) before practice.
    public func warmupModels() async throws {
        warmupState = .loadingWhisper
        warmupDetail = "Loading Whisper on GPU…"
        try await recognizer.warmup()

        warmupState = .loadingTutor
        warmupDetail = "Priming EstLLM…"
        try await languageModel.warmup()

        warmupState = .loadingTutor
        warmupDetail = "Loading Neurokõne voice (once)…"
        try await speaker.prepare()

        warmupDetail = "Ready"
        warmupState = .ready
    }

    public func selectPack(_ pack: LessonPack) {
        selectedPack = pack
        itemIndex = 0
        lastFeedback = nil
        lastTranscript = ""
        phase = .idle
    }

    public func startRecording() async {
        let permitted = await recorder.requestPermission()
        guard permitted else {
            phase = .error("Microphone permission denied")
            return
        }
        do {
            try await recorder.startRecording()
            phase = .recording
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func stopAndEvaluate() async {
        guard let pack = selectedPack, let item = currentItem else {
            phase = .error("No lesson selected")
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
            phase = .error(error.localizedDescription)
        }
    }

    public func speakCorrection() async {
        guard let correction = lastFeedback?.correction else { return }
        do {
            phase = .speaking
            try await speaker.speak(correction, languageCode: "et-EE")
            phase = lastFeedback?.verdict == .correct ? .completedItem : .feedback
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func advanceToNextItem() {
        guard let pack = selectedPack else { return }
        if itemIndex + 1 < pack.items.count {
            itemIndex += 1
        } else {
            itemIndex = 0
        }
        lastFeedback = nil
        lastTranscript = ""
        phase = .idle
    }

    public func retryCurrent() {
        lastFeedback = nil
        lastTranscript = ""
        phase = .idle
    }

    public func speakTarget() async {
        guard let item = currentItem else { return }
        do {
            phase = .speaking
            try await speaker.speak(item.targetEstonian, languageCode: "et-EE")
            phase = .idle
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
