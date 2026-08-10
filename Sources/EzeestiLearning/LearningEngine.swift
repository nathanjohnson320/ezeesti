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
    @Published public private(set) var dueQueue: [VocabCard] = []
    @Published public private(set) var duePreview: [VocabCard] = []
    @Published public private(set) var currentReview: VocabCard?
    @Published public private(set) var dueCount: Int = 0
    @Published public private(set) var progress: LearnerProgress = .empty
    @Published public private(set) var lastTranscript: String = ""
    @Published public private(set) var lastSummaryFeedback: SpokenSummaryFeedback?
    @Published public private(set) var speakPrompt: String = ""
    @Published public private(set) var lexiconCount: Int = 0
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

    public func refreshDueCount() {
        refreshProgress()
    }

    /// Always draft a fresh passage from the next high-frequency unknown lemmas.
    public func continueRecommendedReading() {
        refreshProgress()
        generationTask?.cancel()
        generationTask = Task { await generateAndSelectNextPassage() }
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
            let targets = LearnerProgress.targetLemmasForPassage(
                workingLevel: progress.workingLevel,
                knownLemmas: known,
                learningLemmas: learning,
                alreadyFocused: sessionFocusedLemmas,
                limit: 2
            )

            guard !targets.isEmpty else {
                selectedText = nil
                familiarity = nil
                phase = .idle
                return
            }

            let focus = targets.map(\.lemma)
            generationDetail = "Writing a passage with: \(focus.prefix(4).joined(separator: ", "))…"

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

            let text: GradedText
            do {
                let raw = try await languageModel.complete(
                    system: prompt.system,
                    user: prompt.user,
                    maxTokens: 320
                )
                if Task.isCancelled { return }
                text = PassageGenerationParser.parse(raw, requiredFocus: focus, cefr: cefr)
                    ?? PassageGenerationParser.heuristic(requiredFocus: focus, cefr: cefr, glosses: glosses)
            } catch {
                if Task.isCancelled { return }
                text = PassageGenerationParser.heuristic(requiredFocus: focus, cefr: cefr, glosses: glosses)
            }

            for lemma in focus {
                sessionFocusedLemmas.insert(EstonianTokenizer.normalize(lemma))
            }
            selectText(text)
        } catch {
            if Task.isCancelled { return }
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

    /// Commits flagged (or focus) words and starts recording in one step —
    /// reading → record → grade, with no idle "tap Record again" screen.
    public func commitFlagsAndStartSpeaking() async {
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
        lastASRError = nil
        refreshProgress()
        await beginRecording(next: .recordingSummary)
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
            lastASRError = nil
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
                    transcript: transcript.text,
                    sourceBody: text.body
                )
            } catch {
                feedback = SpokenSummaryFeedbackParser.heuristic(
                    mustUse: mustUseWords,
                    transcript: transcript.text,
                    sourceBody: text.body
                )
            }

            lastSummaryFeedback = feedback

            if feedback.verdict == .correct, feedback.missingRequiredWords.isEmpty {
                try vocab.markKnownImmediate(mustUseWords)
                pendingAdvanceAfterPerfect = true
            } else {
                if !feedback.missingRequiredWords.isEmpty {
                    try vocab.markProducedWeakly(feedback.missingRequiredWords)
                }
                if !feedback.usedRequiredWords.isEmpty {
                    try vocab.markProducedSuccessfully(feedback.usedRequiredWords)
                }
                pendingAdvanceAfterPerfect = false
            }
            refreshProgress()
            phase = feedback.verdict == .correct ? .completed : .summaryFeedback
        } catch {
            // Keep the speak loop usable — hard Error screen used to strand the learner.
            lastASRError = error.localizedDescription
            lastTranscript = ""
            phase = .speakingSummary
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

    public func speakReviewPrompt() async {
        guard let card = currentReview else { return }
        try? await speaker.speak(card.surfaceForm, languageCode: "et-EE")
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
        // Don't fight Neurokõne / system playback for the mic.
        isSpeakingCorrection = false
        speakingDetail = ""
        lastASRError = nil

        let permitted = await recorder.requestPermission()
        guard permitted else {
            phase = .error("Microphone permission denied")
            return
        }
        do {
            try recorder.startRecording()
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

    private func recomputeFamiliarity(for text: GradedText) {
        let known = (try? vocab.knownLemmas()) ?? GradedTextCatalog.loadSeedKnownLemmas()
        familiarity = GradedTextCatalog.familiarity(text: text, knownLemmas: known)
    }
}
