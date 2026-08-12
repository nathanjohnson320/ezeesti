import Foundation
import EzeestiCore
import EzeestiASR
import EzeestiLLM
import EzeestiTTS

@MainActor
public final class LearningEngine: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case reading
        case generatingPassage
        case speakingSummary
        case recordingSummary
        case transcribing
        case grading
        case summaryFeedback
        case completed
        case error(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var selectedText: GradedText?
    @Published public private(set) var familiarity: TextFamiliarityReport?
    @Published public private(set) var flaggedTokenIndexes: Set<Int> = []
    @Published public private(set) var selectedTokenIndex: Int?
    @Published public private(set) var selectedWord: WordLookup?
    @Published public private(set) var isGeneratingGloss: Bool = false
    @Published public private(set) var isGeneratingPassage: Bool = false
    @Published public private(set) var generationDetail: String = ""
    @Published public private(set) var glossSource: String? = nil
    @Published public private(set) var mustUseWords: [String] = []
    @Published public private(set) var duePreview: [VocabCard] = []
    @Published public private(set) var dueCount: Int = 0
    @Published public private(set) var progress: LearnerProgress = .empty
    @Published public private(set) var lastTranscript: String = ""
    @Published public private(set) var lastSummaryFeedback: SpokenSummaryFeedback?
    @Published public private(set) var speakPrompt: String = ""
    @Published public private(set) var isSpeakingCorrection: Bool = false
    @Published public private(set) var speakingDetail: String = ""
    @Published public private(set) var lastASRError: String?

    public let vocab: VocabStore
    public let recorder: MicrophoneRecorder

    private var recognizer: any SpeechRecognizing
    private var languageModel: any LanguageModeling
    private var speaker: any TextSpeaking
    private var generationTask: Task<Void, Never>?
    /// Focus lemmas used in this session so consecutive generations do not repeat immediately.
    private var sessionFocusedLemmas: Set<String> = []
    private var pendingAdvanceAfterPerfect = false
    /// When set, next generation prefers these due lemmas as focus words.
    private var preferredDueFocus: [String] = []

    public init(
        vocab: VocabStore,
        recorder: MicrophoneRecorder? = nil,
        recognizer: (any SpeechRecognizing)? = nil,
        languageModel: (any LanguageModeling)? = nil,
        speaker: (any TextSpeaking)? = nil,
        modelPaths: ModelPaths? = nil
    ) throws {
        self.vocab = vocab
        self.recorder = recorder ?? MicrophoneRecorder()

        let paths: ModelPaths
        if let modelPaths {
            paths = modelPaths
        } else {
            paths = try ModelPaths.defaultApplicationSupport()
        }

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
    }

    public func bootstrap() {
        do {
            LexiconCatalog.shared.loadBundledIfNeeded()
            WordGlossCatalog.loadBundledIfNeeded()
            _ = try vocab.seedLexiconFromBundleIfNeeded()
            try vocab.clearAssumedSeedVocabularyIfNeeded()
            refreshProgress()
            if selectedText == nil {
                continueRecommendedReading()
            }
            Task { try? await speaker.prepare() }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func refreshProgress() {
        progress = (try? vocab.progressSnapshot()) ?? .empty
        dueCount = progress.dueCount
        duePreview = (try? vocab.dueCards(limit: 8)) ?? []
    }

    /// Draft a fresh sentence from the next unknown / due lemmas.
    public func continueRecommendedReading() {
        preferredDueFocus = []
        refreshProgress()
        generationTask?.cancel()
        generationTask = Task { await generateAndSelectNextPassage() }
    }

    /// Sidebar review: generate a sentence around due words and use the same read-aloud path.
    public func startDueReview(preferringLemma lemma: String? = nil) {
        do {
            var due = try vocab.dueCards(limit: 15).map(\.lemma)
            if let lemma {
                let key = EstonianTokenizer.normalize(lemma)
                due.removeAll { EstonianTokenizer.normalize($0) == key }
                due.insert(key, at: 0)
            }
            preferredDueFocus = Array(due.prefix(1))
            refreshProgress()
            generationTask?.cancel()
            generationTask = Task { await generateAndSelectNextPassage() }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func generateAndSelectNextPassage() async {
        guard !isGeneratingPassage else { return }
        isGeneratingPassage = true
        phase = .generatingPassage
        generationDetail = "Picking leftover \(progress.workingLevel.rawValue) words…"
        defer {
            isGeneratingPassage = false
            generationDetail = ""
        }

        do {
            let known = try vocab.knownLemmas()
            let learning = Set(
                try vocab.fetchAll()
                    .filter { $0.familiarity == .learning }
                    .map(\.lemma)
            )
            let dueLemmas: [String]
            if preferredDueFocus.isEmpty {
                dueLemmas = try vocab.dueCards(limit: 1).map(\.lemma)
            } else {
                dueLemmas = preferredDueFocus
            }
            preferredDueFocus = []

            let targets = LearnerProgress.targetLemmasForPassage(
                workingLevel: progress.workingLevel,
                knownLemmas: known,
                learningLemmas: learning,
                dueLemmas: dueLemmas,
                alreadyFocused: sessionFocusedLemmas,
                limit: 1
            )

            guard !targets.isEmpty else {
                selectedText = nil
                familiarity = nil
                phase = .idle
                return
            }

            let focus = targets.map(\.lemma)
            generationDetail = "Writing a sentence with: \(focus.joined(separator: ", "))…"

            var glosses: [String: String] = [:]
            for lemma in focus {
                if let gloss = WordGlossCatalog.gloss(forSurface: lemma) {
                    glosses[lemma] = gloss
                }
            }

            let cefr: CEFRLevel = progress.workingLevel == .a1 ? .a1 : .a2
            let prompt = PassageGenerationPrompt(
                cefr: cefr,
                focusLemmas: focus,
                focusGlosses: glosses
            )

            let draft = try await generatePassage(prompt: prompt, focus: focus, cefr: cefr)
            if Task.isCancelled { return }

            generationDetail = "Checking the sentence…"
            let text = try await validateSentence(
                draft,
                focus: focus,
                glosses: glosses,
                cefr: cefr
            )
            if Task.isCancelled { return }

            for lemma in focus {
                sessionFocusedLemmas.insert(EstonianTokenizer.normalize(lemma))
            }
            selectText(text)
        } catch {
            if Task.isCancelled { return }
            phase = .error(error.localizedDescription)
        }
    }

    /// A single low-temperature sample often trips one of the passage gates, so
    /// resample at rising temperature before giving up on the model.
    private func generatePassage(
        prompt: PassageGenerationPrompt,
        focus: [String],
        cefr: CEFRLevel
    ) async throws -> GradedText {
        var lastError: Error?

        for (attempt, temperature) in Self.passageRetryTemperatures.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            if attempt > 0 {
                generationDetail = "Rewriting the sentence (attempt \(attempt + 1))…"
            }

            do {
                let raw = try await languageModel.complete(
                    system: prompt.system,
                    user: prompt.user,
                    maxTokens: 220,
                    temperature: temperature
                )
                if let draft = PassageGenerationParser.parse(raw, requiredFocus: focus, cefr: cefr) {
                    return draft
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw EzeestiError.llmFailed(
            "EstLLM could not write a usable sentence for “\(focus.joined(separator: ", "))” after \(Self.passageRetryTemperatures.count) attempts"
        )
    }

    private static let passageRetryTemperatures: [Double] = [0.2, 0.55, 0.85]

    /// Feed the draft back through the model; accept a rewrite if the draft is weak.
    private func validateSentence(
        _ draft: GradedText,
        focus: [String],
        glosses: [String: String],
        cefr: CEFRLevel
    ) async throws -> GradedText {
        let passageDraft = PassageDraft(
            title: draft.title,
            body: draft.body,
            glossEnglish: draft.glossEnglish,
            focusWords: draft.focusWords.isEmpty ? focus : draft.focusWords
        )
        let prompt = SentenceValidationPrompt(
            cefr: cefr,
            focusLemmas: focus,
            focusGlosses: glosses,
            draft: passageDraft
        )

        let raw = try await languageModel.complete(
            system: prompt.system,
            user: prompt.user,
            maxTokens: 220
        )
        // The draft already cleared the generation gates; an unusable review
        // response means the reviewer failed, not the sentence.
        return SentenceValidationParser.parse(raw, requiredFocus: focus, cefr: cefr) ?? draft
    }

    /// Wipe known/learning progress and draft a fresh first sentence.
    public func resetProgress() {
        generationTask?.cancel()
        do {
            try vocab.resetProgress()
            sessionFocusedLemmas = []
            preferredDueFocus = []
            pendingAdvanceAfterPerfect = false
            selectedText = nil
            familiarity = nil
            flaggedTokenIndexes = []
            selectedTokenIndex = nil
            selectedWord = nil
            isGeneratingGloss = false
            glossSource = nil
            mustUseWords = []
            lastSummaryFeedback = nil
            lastTranscript = ""
            lastASRError = nil
            speakPrompt = ""
            refreshProgress()
            continueRecommendedReading()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func selectText(_ text: GradedText?) {
        selectedText = text
        flaggedTokenIndexes = []
        selectedTokenIndex = nil
        selectedWord = nil
        isGeneratingGloss = false
        glossSource = nil
        mustUseWords = []
        lastSummaryFeedback = nil
        lastTranscript = ""
        pendingAdvanceAfterPerfect = false
        guard let text else {
            familiarity = nil
            phase = .idle
            return
        }
        recomputeFamiliarity(for: text)
        phase = .reading
    }

    /// Tap a word to inspect definition; does not add to review.
    public func selectWord(tokenIndex: Int) {
        guard let familiarity, familiarity.tokens.indices.contains(tokenIndex) else { return }
        let token = familiarity.tokens[tokenIndex]
        guard token.isWord else { return }
        selectedTokenIndex = tokenIndex
        glossSource = nil
        selectedWord = lookup(token: token, tokenIndex: tokenIndex)
        if selectedWord?.glossEnglish == nil {
            Task { await generateGlossIfNeeded(tokenIndex: tokenIndex) }
        }
    }

    public func generateGlossIfNeeded(tokenIndex: Int) async {
        guard let familiarity, familiarity.tokens.indices.contains(tokenIndex) else { return }
        let token = familiarity.tokens[tokenIndex]
        guard token.isWord else { return }

        let current = lookup(token: token, tokenIndex: tokenIndex)
        if current.glossEnglish != nil {
            if selectedTokenIndex == tokenIndex {
                selectedWord = current
                glossSource = "cache"
            }
            return
        }

        isGeneratingGloss = true
        defer {
            if selectedTokenIndex == tokenIndex {
                isGeneratingGloss = false
            }
        }

        let entry =
            (try? vocab.lexiconEntry(forSurface: token.surface))
            ?? LexiconCatalog.shared.entry(forSurface: token.surface)
        let prompt = WordGlossPrompt(
            surface: token.surface,
            lemma: entry?.lemma ?? EstonianTokenizer.normalize(token.surface),
            contextSentence: selectedText?.body ?? "",
            cefr: entry?.cefr,
            pos: entry?.pos ?? ""
        )

        do {
            let raw = try await languageModel.complete(system: prompt.system, user: prompt.user)
            guard let gloss = WordGlossParser.parse(raw) else { return }
            let source = "estllm"
            try vocab.saveGloss(forSurface: token.surface, glossEnglish: gloss, source: source)
            guard selectedTokenIndex == tokenIndex else { return }
            selectedWord = lookup(token: token, tokenIndex: tokenIndex)
            glossSource = source
        } catch {
            guard selectedTokenIndex == tokenIndex else { return }
            selectedWord = lookup(token: token, tokenIndex: tokenIndex)
        }
    }

    public func toggleFlagOnSelectedWord() {
        guard let index = selectedTokenIndex else { return }
        if flaggedTokenIndexes.contains(index) {
            flaggedTokenIndexes.remove(index)
        } else {
            flaggedTokenIndexes.insert(index)
        }
        if let token = familiarity?.tokens[index] {
            selectedWord = lookup(token: token, tokenIndex: index)
        }
    }

    /// Commits flagged words (only) and starts recording the read-aloud.
    public func commitFlagsAndStartSpeaking() async {
        guard let text = selectedText, let familiarity else { return }
        for index in flaggedTokenIndexes.sorted() {
            let token = familiarity.tokens[index]
            let gloss =
                WordGlossCatalog.gloss(forSurface: token.surface)
                ?? (try? vocab.cachedGloss(forSurface: token.surface))
                ?? ""
            do {
                _ = try vocab.flagWord(
                    surface: token.surface,
                    contextSentence: text.body,
                    glossEnglish: gloss
                )
            } catch {
                phase = .error(error.localizedDescription)
                return
            }
        }
        mustUseWords = text.focusWords
        speakPrompt = "Read the sentence aloud."
        lastSummaryFeedback = nil
        lastTranscript = ""
        lastASRError = nil
        refreshProgress()
        await beginRecording(next: .recordingSummary)
    }

    public func startRecordingForSummary() async {
        await beginRecording(next: .recordingSummary)
    }

    public func stopSummaryAndGrade() async {
        guard let text = selectedText else { return }
        do {
            lastASRError = nil
            let audioURL = try await recorder.stopRecording()
            phase = .transcribing
            let transcript = try await recognizer.transcribe(
                audioURL: audioURL,
                initialPrompt: text.body
            )
            let said = TranscriptCleaner.align(toExpected: text.body, transcript: transcript.text)
            lastTranscript = said

            phase = .grading
            let focus = text.focusWords.isEmpty ? mustUseWords : text.focusWords
            mustUseWords = focus
            let prompt = SpokenSummaryPrompt(
                text: text,
                mustUseWords: focus,
                transcript: said
            )

            let raw = try await languageModel.complete(system: prompt.system, user: prompt.user)
            let feedback = SpokenSummaryFeedbackParser.parse(
                raw,
                mustUse: focus,
                transcript: said,
                sourceBody: text.body
            )

            lastSummaryFeedback = feedback
            try applyVocabOutcome(feedback: feedback, text: text)

            refreshProgress()
            phase = feedback.verdict == .correct ? .completed : .summaryFeedback
        } catch {
            lastASRError = error.localizedDescription
            lastTranscript = ""
            phase = .error(error.localizedDescription)
        }
    }

    public func speakCorrection() async {
        guard let correction = lastSummaryFeedback?.correction, !correction.isEmpty else { return }
        isSpeakingCorrection = true
        speakingDetail = "Preparing voice…"
        defer {
            isSpeakingCorrection = false
            speakingDetail = ""
        }
        do {
            speakingDetail = "Playing model answer…"
            try await speaker.speak(correction, languageCode: "et-EE")
        } catch {
            speakingDetail = error.localizedDescription
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    public func retrySummary() {
        pendingAdvanceAfterPerfect = false
        lastSummaryFeedback = nil
        lastTranscript = ""
        lastASRError = nil
        phase = .speakingSummary
    }

    /// Clears prior attempt and starts recording immediately.
    public func retrySummaryAndRecord() async {
        retrySummary()
        await beginRecording(next: .recordingSummary)
    }

    private func beginRecording(next: Phase) async {
        isSpeakingCorrection = false
        speakingDetail = ""
        lastASRError = nil

        let permitted = await recorder.requestPermission()
        guard permitted else {
            phase = .error("Microphone permission denied")
            return
        }
        do {
            try await recorder.startRecording()
            phase = next
        } catch {
            if next == .recordingSummary {
                lastASRError = error.localizedDescription
                phase = .speakingSummary
            } else {
                phase = .error(error.localizedDescription)
            }
        }
    }

    /// Unload shared native recognizer/LLM if this engine owns distinct instances.
    public func shutdownNativeModels() async {
        await recognizer.shutdown()
        await languageModel.shutdown()
    }

    public func finishToReading() {
        let advance = pendingAdvanceAfterPerfect
        pendingAdvanceAfterPerfect = false
        lastSummaryFeedback = nil
        lastTranscript = ""
        flaggedTokenIndexes = []
        selectedTokenIndex = nil
        selectedWord = nil
        isGeneratingGloss = false
        glossSource = nil
        mustUseWords = []
        refreshProgress()
        if advance {
            continueRecommendedReading()
            return
        }
        if let text = selectedText {
            recomputeFamiliarity(for: text)
            phase = .reading
        } else {
            continueRecommendedReading()
        }
    }

    private func applyVocabOutcome(feedback: SpokenSummaryFeedback, text: GradedText) throws {
        let focus = text.focusWords.isEmpty ? mustUseWords : text.focusWords
        let flaggedLemmas = flaggedFocusLemmas(in: text)
        let unflagged = focus.filter { !flaggedLemmas.contains(EstonianTokenizer.normalize($0)) }
        let flagged = focus.filter { flaggedLemmas.contains(EstonianTokenizer.normalize($0)) }

        if feedback.verdict == .correct, feedback.missingRequiredWords.isEmpty {
            if !unflagged.isEmpty {
                try vocab.markKnownWithBackoff(unflagged)
            }
            if !flagged.isEmpty {
                try vocab.markLearningDueSoon(flagged)
            }
            pendingAdvanceAfterPerfect = true
        } else {
            var weak = Set(feedback.missingRequiredWords.map { EstonianTokenizer.normalize($0) })
            for word in flagged {
                weak.insert(EstonianTokenizer.normalize(word))
            }
            for word in focus where feedback.verdict != .correct {
                // Incorrect/close overall: keep focus words in learning until a clean read.
                weak.insert(EstonianTokenizer.normalize(word))
            }
            if !weak.isEmpty {
                try vocab.markLearningDueSoon(Array(weak))
            }
            pendingAdvanceAfterPerfect = false
        }
    }

    private func flaggedFocusLemmas(in text: GradedText) -> Set<String> {
        guard let familiarity else { return [] }
        var set = Set<String>()
        for index in flaggedTokenIndexes {
            guard familiarity.tokens.indices.contains(index) else { continue }
            let token = familiarity.tokens[index]
            guard token.isWord else { continue }
            set.insert(EstonianTokenizer.normalize(token.surface))
        }
        // Also match focus lemmas if the flagged surface is an inflection.
        let focusKeys = Set(text.focusWords.map { EstonianTokenizer.normalize($0) })
        if set.isEmpty { return set }
        var expanded = set
        for focus in focusKeys {
            if set.contains(where: { $0.hasPrefix(focus) || focus.hasPrefix($0) || $0 == focus }) {
                expanded.insert(focus)
            }
        }
        return expanded
    }

    private func lookup(token: TextToken, tokenIndex: Int) -> WordLookup {
        let lemma = EstonianTokenizer.normalize(token.surface)
        let entry =
            (try? vocab.lexiconEntry(forSurface: token.surface))
            ?? LexiconCatalog.shared.entry(forSurface: token.surface)
        let card = try? vocab.card(forSurface: token.surface)
        let gloss =
            (card?.glossEnglish).flatMap { $0.isEmpty ? nil : $0 }
            ?? WordGlossCatalog.gloss(forSurface: token.surface)
            ?? (try? vocab.cachedGloss(forSurface: token.surface))
        return WordLookup(
            surface: token.surface,
            lemma: entry?.lemma ?? lemma,
            glossEnglish: gloss,
            cefr: entry?.cefr,
            pos: entry?.pos ?? "",
            learnerStatus: card?.familiarity,
            tokenIndex: tokenIndex
        )
    }

    private func recomputeFamiliarity(for text: GradedText) {
        let known = (try? vocab.knownLemmas()) ?? GradedTextCatalog.loadSeedKnownLemmas()
        familiarity = GradedTextCatalog.familiarity(text: text, knownLemmas: known)
    }
}
