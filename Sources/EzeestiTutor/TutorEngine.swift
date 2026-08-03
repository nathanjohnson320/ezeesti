import Foundation
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

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var packs: [LessonPack] = []
    @Published public private(set) var selectedPack: LessonPack?
    @Published public private(set) var itemIndex: Int = 0
    @Published public private(set) var lastTranscript: String = ""
    @Published public private(set) var lastFeedback: TutorFeedback?
    @Published public private(set) var useMockASR: Bool = true
    @Published public private(set) var useRuleTutor: Bool = true
    @Published public private(set) var hasEstonianTTS: Bool = false
    @Published public private(set) var ttsVoiceName: String? = nil

    public let recorder: MicrophoneRecorder

    private var recognizer: any SpeechRecognizing
    private var languageModel: any LanguageModeling
    private var speaker: any TextSpeaking
    private let modelPaths: ModelPaths

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
    ) {
        let paths = modelPaths ?? ((try? ModelPaths.defaultApplicationSupport()) ?? ModelPaths())
        self.modelPaths = paths
        self.recorder = recorder ?? MicrophoneRecorder()

        let whisperReady = paths.whisperGGML.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let whisperBinReady = paths.whisperBinary.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        let llmReady = paths.estLLMGGUF.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let llamaBinReady = paths.llamaBinary.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false

        if let recognizer {
            self.recognizer = recognizer
            self.useMockASR = false
        } else if whisperReady, whisperBinReady, let model = paths.whisperGGML, let bin = paths.whisperBinary {
            self.recognizer = WhisperCppCLIService(modelPath: model, binaryPath: bin)
            self.useMockASR = false
        } else {
            self.recognizer = MockSpeechRecognizer()
            self.useMockASR = true
        }

        if let languageModel {
            self.languageModel = languageModel
            self.useRuleTutor = false
        } else if llmReady, llamaBinReady, let model = paths.estLLMGGUF, let bin = paths.llamaBinary {
            self.languageModel = LlamaCppCLIService(modelPath: model, binaryPath: bin)
            self.useRuleTutor = false
        } else {
            self.languageModel = RuleBasedLanguageModel()
            self.useRuleTutor = true
        }

        if let speaker {
            self.speaker = speaker
        } else if let cli = paths.neurokoneBinary,
                  FileManager.default.isExecutableFile(atPath: cli.path) {
            self.speaker = NeurokoneTTSService(binaryPath: cli)
        } else {
            self.speaker = SystemSpeechSynthesizer()
        }

        switch VoiceAvailability.current(neurokoneCLI: paths.neurokoneBinary) {
        case .neurokoneCLI:
            self.hasEstonianTTS = true
            self.ttsVoiceName = "Neurokõne (mari)"
        case .estonianSystemVoice(let name):
            self.hasEstonianTTS = true
            self.ttsVoiceName = name
        case .unavailable:
            self.hasEstonianTTS = false
            self.ttsVoiceName = nil
        }
    }

    public func loadLessons() {
        do {
            packs = try LessonCatalog.loadBundled()
            if selectedPack == nil {
                selectedPack = packs.first
                itemIndex = 0
            }
        } catch {
            packs = [LessonCatalog.fallbackMinemaLesson]
            selectedPack = packs.first
            phase = .error(error.localizedDescription)
        }
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
            try recorder.startRecording()
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
            let audioURL = try recorder.stopRecording()
            phase = .transcribing
            let transcript = try await recognizer.transcribe(audioURL: audioURL)
            lastTranscript = transcript.text

            phase = .tutoring
            let prompt = GrammarTutorPrompt(target: item, pack: pack, transcript: transcript.text)

            let feedback: TutorFeedback
            do {
                let raw = try await languageModel.complete(system: prompt.system, user: prompt.user)
                feedback = try TutorFeedbackParser.parse(raw)
            } catch {
                // Fall back to fast rules if EstLLM OOMs / crashes (common after Neurokõne).
                let fallback = RuleBasedLanguageModel()
                let raw = try await fallback.complete(system: prompt.system, user: prompt.user)
                feedback = try TutorFeedbackParser.parse(raw)
            }

            lastFeedback = feedback
            // Do NOT auto-play Neurokõne here — loading TF+vocoder after Whisper/LLM is what
            // makes the loop extremely slow and can kill llama (exit 9 / HALC overload).
            // User can tap "Hear target" / a dedicated hear-correction control.
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
