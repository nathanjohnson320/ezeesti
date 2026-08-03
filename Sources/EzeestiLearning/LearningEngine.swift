import Foundation
import EzeestiCore
import EzeestiASR
import EzeestiLLM
import EzeestiTTS

@MainActor
public final class LearningEngine: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case reviewing
        case recordingReview
        case reading
        case speakingSummary
        case recordingSummary
        case transcribing
        case grading
        case summaryFeedback
        case completed
        case error(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var texts: [GradedText] = []
    @Published public private(set) var selectedText: GradedText?
    @Published public private(set) var familiarity: TextFamiliarityReport?
    @Published public private(set) var flaggedTokenIndexes: Set<Int> = []
    @Published public private(set) var selectedTokenIndex: Int?
    @Published public private(set) var selectedWord: WordLookup?
    @Published public private(set) var isGeneratingGloss: Bool = false
    @Published public private(set) var glossSource: String? = nil
    @Published public private(set) var mustUseWords: [String] = []
    @Published public private(set) var dueQueue: [VocabCard] = []
    @Published public private(set) var duePreview: [VocabCard] = []
    @Published public private(set) var currentReview: VocabCard?
    @Published public private(set) var dueCount: Int = 0
    @Published public private(set) var progress: LearnerProgress = .empty
    @Published public private(set) var lastTranscript: String = ""
    @Published public private(set) var lastSummaryFeedback: SpokenSummaryFeedback?
    @Published public private(set) var speakPrompt: String = ""
    @Published public private(set) var lexiconCount: Int = 0

    public let vocab: VocabStore
    public let recorder: MicrophoneRecorder

    private var recognizer: any SpeechRecognizing
    private var languageModel: any LanguageModeling
    private var speaker: any TextSpeaking

    public init(
        vocab: VocabStore,
        recorder: MicrophoneRecorder? = nil,
        recognizer: (any SpeechRecognizing)? = nil,
        languageModel: (any LanguageModeling)? = nil,
        speaker: (any TextSpeaking)? = nil,
        modelPaths: ModelPaths? = nil
    ) {
        self.vocab = vocab
        self.recorder = recorder ?? MicrophoneRecorder()

        let paths = modelPaths ?? ((try? ModelPaths.defaultApplicationSupport()) ?? ModelPaths())

        if let recognizer {
            self.recognizer = recognizer
        } else if paths.whisperNativeReady, let model = paths.whisperGGML, let lib = paths.whisperLibDir {
            self.recognizer = WhisperCppService(modelPath: model, libDir: lib)
        } else {
            self.recognizer = MockSpeechRecognizer(cannedText: "Ma joon kohvi ja lähen poodi.")
        }

        if let languageModel {
            self.languageModel = languageModel
        } else if paths.llamaNativeReady, let model = paths.estLLMGGUF, let lib = paths.llamaLibDir {
            self.languageModel = LlamaCppService(modelPath: model, libDir: lib)
        } else {
            self.languageModel = RuleBasedLanguageModel()
        }

        if let speaker {
            self.speaker = speaker
        } else if let cli = paths.neurokoneBinary,
                  FileManager.default.isExecutableFile(atPath: cli.path) {
            self.speaker = NeurokoneTTSService(binaryPath: cli)
        } else {
            self.speaker = SystemSpeechSynthesizer()
        }
    }

    public func bootstrap() {
        do {
            LexiconCatalog.shared.loadBundledIfNeeded()
            WordGlossCatalog.loadBundledIfNeeded()
            let seeded = try vocab.seedLexiconFromBundleIfNeeded()
            lexiconCount = (try? vocab.lexiconCount()) ?? seeded
            try vocab.clearAssumedSeedVocabularyIfNeeded()
            texts = try GradedTextCatalog.loadBundled()
            refreshProgress()
            if selectedText == nil {
                continueRecommendedReading()
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func refreshProgress() {
        progress = (try? vocab.progressSnapshot()) ?? .empty
        dueCount = progress.dueCount
        duePreview = (try? vocab.dueCards(limit: 8)) ?? []
    }

    public func refreshDueCount() {
        refreshProgress()
    }

    public func continueRecommendedReading() {
        let known = (try? vocab.knownLemmas()) ?? []
        let next = LearnerProgress.recommendText(
            from: texts,
            workingLevel: progress.workingLevel,
            knownLemmas: known
        )
        selectText(next)
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

        // Someone else may have filled cache since tap.
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
            let source = (languageModel is RuleBasedLanguageModel) ? "fallback" : "estllm"
            try vocab.saveGloss(forSurface: token.surface, glossEnglish: gloss, source: source)
            guard selectedTokenIndex == tokenIndex else { return }
            selectedWord = lookup(token: token, tokenIndex: tokenIndex)
            glossSource = source
        } catch {
            // Keep inspector usable without a gloss if EstLLM is busy/unavailable.
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

    public func commitFlagsAndStartSpeaking() {
        guard let text = selectedText, let familiarity else { return }
        var words: [String] = []
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
                words.append(token.surface)
            } catch {
                phase = .error(error.localizedDescription)
                return
            }
        }
        // Also include focus words if user flagged nothing — nudge n+1 practice.
        if words.isEmpty {
            words = text.focusWords
            for w in words {
                let gloss =
                    WordGlossCatalog.gloss(forSurface: w)
                    ?? (try? vocab.cachedGloss(forSurface: w))
                    ?? ""
                _ = try? vocab.flagWord(surface: w, contextSentence: text.body, glossEnglish: gloss)
            }
        }
        mustUseWords = words
        speakPrompt = "Speak a short Estonian summary. Use: \(words.joined(separator: ", "))"
        lastSummaryFeedback = nil
        lastTranscript = ""
        refreshProgress()
        phase = .speakingSummary
    }

    public func startFSRSReview(preferringLemma lemma: String? = nil) {
        do {
            var queue = try vocab.dueCards(limit: 15)
            if let lemma {
                let key = EstonianTokenizer.normalize(lemma)
                if let match = queue.first(where: { $0.lemma == key }) {
                    queue.removeAll { $0.lemma == key }
                    queue.insert(match, at: 0)
                }
            }
            dueQueue = queue
            dueCount = queue.count
            guard let first = queue.first else {
                phase = selectedText == nil ? .idle : .reading
                return
            }
            presentReview(first)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func startRecordingForReview() async {
        await beginRecording(next: .recordingReview)
    }

    public func startRecordingForSummary() async {
        await beginRecording(next: .recordingSummary)
    }

    public func stopReviewAndGrade(rating: FSRSRating) async {
        guard let card = currentReview else { return }
        // Optional: still capture speech for practice feel.
        if phase == .recordingReview {
            _ = try? recorder.stopRecording()
        }
        do {
            try vocab.applyRating(card, rating: rating)
            dueQueue.removeAll { $0.lemma == card.lemma }
            if let next = dueQueue.first {
                presentReview(next)
            } else {
                currentReview = nil
                refreshProgress()
                if selectedText != nil {
                    phase = .reading
                } else {
                    continueRecommendedReading()
                }
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func stopSummaryAndGrade() async {
        guard let text = selectedText else { return }
        do {
            let audioURL = try recorder.stopRecording()
            phase = .transcribing
            let transcript = try await recognizer.transcribe(audioURL: audioURL)
            lastTranscript = transcript.text

            phase = .grading
            let prompt = SpokenSummaryPrompt(
                text: text,
                mustUseWords: mustUseWords,
                transcript: transcript.text
            )

            let feedback: SpokenSummaryFeedback
            do {
                let raw = try await languageModel.complete(system: prompt.system, user: prompt.user)
                feedback = SpokenSummaryFeedbackParser.parse(
                    raw,
                    mustUse: mustUseWords,
                    transcript: transcript.text
                )
            } catch {
                feedback = SpokenSummaryFeedbackParser.heuristic(
                    mustUse: mustUseWords,
                    transcript: transcript.text
                )
            }

            lastSummaryFeedback = feedback

            if feedback.missingRequiredWords.isEmpty {
                try vocab.markProducedSuccessfully(feedback.usedRequiredWords)
            } else {
                try vocab.markProducedWeakly(feedback.missingRequiredWords)
                if !feedback.usedRequiredWords.isEmpty {
                    try vocab.markProducedSuccessfully(feedback.usedRequiredWords)
                }
            }
            refreshProgress()
            phase = feedback.verdict == .correct ? .completed : .summaryFeedback
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func speakCorrection() async {
        guard let correction = lastSummaryFeedback?.correction else { return }
        try? await speaker.speak(correction, languageCode: "et-EE")
    }

    public func speakReviewPrompt() async {
        guard let card = currentReview else { return }
        try? await speaker.speak(card.surfaceForm, languageCode: "et-EE")
    }

    public func retrySummary() {
        lastSummaryFeedback = nil
        lastTranscript = ""
        phase = .speakingSummary
    }

    public func finishToReading() {
        lastSummaryFeedback = nil
        lastTranscript = ""
        flaggedTokenIndexes = []
        selectedTokenIndex = nil
        selectedWord = nil
        isGeneratingGloss = false
        glossSource = nil
        refreshProgress()
        if let text = selectedText {
            recomputeFamiliarity(for: text)
            phase = .reading
        } else {
            continueRecommendedReading()
        }
    }

    private func presentReview(_ card: VocabCard) {
        currentReview = card
        speakPrompt = "Say a sentence with: \(card.surfaceForm)"
        if !card.glossEnglish.isEmpty {
            speakPrompt += "\n(\(card.glossEnglish))"
        }
        if !card.contextSentence.isEmpty {
            speakPrompt += "\nContext: \(card.contextSentence)"
        }
        phase = .reviewing
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

    private func beginRecording(next: Phase) async {
        let permitted = await recorder.requestPermission()
        guard permitted else {
            phase = .error("Microphone permission denied")
            return
        }
        do {
            try recorder.startRecording()
            phase = next
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func recomputeFamiliarity(for text: GradedText) {
        let known = (try? vocab.knownLemmas()) ?? GradedTextCatalog.loadSeedKnownLemmas()
        familiarity = GradedTextCatalog.familiarity(text: text, knownLemmas: known)
    }
}
