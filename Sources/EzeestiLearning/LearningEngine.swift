import Foundation
import Observation
import EzeestiCore
import EzeestiASR
import EzeestiLLM
import EzeestiTTS

/// Coordinates Tutor-mode graded reading, passage generation, ASR grading, and vocab updates.
@Observable
@MainActor
public final class LearningEngine {
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

    /// Tutor sentences stay within A1–B2, matching Words-mode teaching.
    private static let maxPassageCEFR: CEFRLevel = .b2
    /// Minimum known+learning lemmas before Tutor can draft a sentence.
    public static let minimumTutorVocabCount = 1
    private static let tutorPracticedDefaultsKey = "ezeesti.tutor.practicedLemmas"

    public private(set) var phase: Phase = .idle
    public private(set) var selectedText: GradedText?
    public private(set) var familiarity: TextFamiliarityReport?
    public private(set) var flaggedTokenIndexes: Set<Int> = []
    public private(set) var selectedTokenIndex: Int?
    public private(set) var selectedWord: WordLookup?
    public private(set) var isGeneratingGloss: Bool = false
    public private(set) var isGeneratingPassage: Bool = false
    public private(set) var generationDetail: String = ""
    public private(set) var glossSource: String? = nil
    public private(set) var mustUseWords: [String] = []
    public private(set) var duePreview: [VocabCard] = []
    public private(set) var dueCount: Int = 0
    public private(set) var progress: LearnerProgress = .empty
    /// Known/learning lemmas not yet spoken successfully in Tutor (from Words or earlier).
    public private(set) var tutorQueue: [VocabCard] = []
    public private(set) var lastTranscript: String = ""
    public private(set) var lastSummaryFeedback: SpokenSummaryFeedback?
    public private(set) var speakPrompt: String = ""
    public private(set) var isSpeakingCorrection: Bool = false
    public private(set) var speakingDetail: String = ""
    public private(set) var lastASRError: String?
    /// Non-fatal TTS warmup failure surfaced for UI / later speak attempts.
    public private(set) var lastSpeakerError: String?

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
    private var tutorPracticedLemmas: Set<String> = []
    private let defaults: UserDefaults

    public init(
        vocab: VocabStore,
        recorder: MicrophoneRecorder? = nil,
        recognizer: (any SpeechRecognizing)? = nil,
        languageModel: (any LanguageModeling)? = nil,
        speaker: (any TextSpeaking)? = nil,
        modelPaths: ModelPaths? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        self.vocab = vocab
        self.recorder = recorder ?? MicrophoneRecorder()
        self.defaults = defaults
        self.tutorPracticedLemmas = Self.loadTutorPracticed(from: defaults)

        let paths: ModelPaths
        if let modelPaths {
            paths = modelPaths
        } else {
            paths = try ModelPaths.defaultApplicationSupport()
        }

        let omlx = OmlxConfig.fromEnvironment(modelPaths: paths)

        if let recognizer {
            self.recognizer = recognizer
        } else if paths.whisperReady {
            self.recognizer = ASRBackend.resolve(config: omlx)
        } else {
            throw EzeestiError.modelMissing(
                "Whisper MLX dir — run Scripts/fetch-models.sh then omlx serve --model-dir \"\(paths.modelsRoot.path)\""
            )
        }

        if let languageModel {
            self.languageModel = languageModel
        } else if paths.llmReady {
            self.languageModel = LLMBackend.resolve(config: omlx)
        } else {
            throw EzeestiError.modelMissing(
                "EstLLM MLX dir — run Scripts/fetch-models.sh then omlx serve --model-dir \"\(paths.modelsRoot.path)\""
            )
        }

        self.speaker = speaker ?? TTSBackend.resolve(modelPaths: paths)
    }

    /// Translates free-form Estonian text to English via EstLLM, with a phrase-by-phrase breakdown.
    public func translateEstonian(_ text: String) async throws -> TextTranslationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EzeestiError.invalidLessonData("Nothing to translate")
        }
        let prompt = TextTranslationPrompt(estonian: trimmed)
        let raw = try await languageModel.complete(
            system: prompt.system,
            user: prompt.user,
            maxTokens: 512
        )
        guard let translation = TextTranslationParser.parse(raw) else {
            throw EzeestiError.llmFailed("Could not parse translation")
        }
        return translation
    }

    /// True when Tutor has at least one known or learning lemma to practice.
    public var canStartTutor: Bool {
        progress.knownCount + progress.learningCount >= Self.minimumTutorVocabCount
    }

    /// Seeds lexicon/vocab cleanup, refreshes progress, and warms TTS (failures are recorded, not swallowed).
    public func bootstrap() async {
        do {
            LexiconCatalog.shared.loadBundledIfNeeded()
            WordGlossCatalog.loadBundledIfNeeded()
            _ = try await vocab.seedLexiconFromBundleIfNeeded()
            try await vocab.clearAssumedSeedVocabularyIfNeeded()
            try refreshProgress()
            if selectedText == nil, canStartTutor {
                continueRecommendedReading()
            } else if selectedText == nil {
                phase = .idle
            }
            do {
                try await speaker.prepare()
                lastSpeakerError = nil
            } catch {
                lastSpeakerError = error.localizedDescription
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    public func refreshProgress() throws {
        progress = try vocab.progressSnapshot()
        dueCount = progress.dueCount
        duePreview = try vocab.dueCards(limit: 8)
        tutorQueue = try buildTutorQueue()
    }

    /// Refresh familiarity for the current sentence against the latest known/learning set.
    public func refreshFamiliarity() {
        guard let text = selectedText else { return }
        do {
            try recomputeFamiliarity(for: text)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Draft a fresh sentence from known / learning / due lemmas (Tutor mode).
    public func continueRecommendedReading() {
        preferredDueFocus = []
        do {
            try refreshProgress()
        } catch {
            phase = .error(error.localizedDescription)
            return
        }
        guard canStartTutor else {
            selectedText = nil
            familiarity = nil
            phase = .idle
            return
        }
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
            try refreshProgress()
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
        generationDetail = "Picking a word you already know…"
        defer {
            isGeneratingPassage = false
            generationDetail = ""
        }

        do {
            let known = try vocab.knownLemmas()
            let learning = try vocab.learningLemmas()
            guard !known.isEmpty || !learning.isEmpty else {
                selectedText = nil
                familiarity = nil
                phase = .idle
                return
            }

            let preferDueFirst = !preferredDueFocus.isEmpty
            let dueLemmas: [String]
            if preferDueFirst {
                dueLemmas = preferredDueFocus
            } else {
                dueLemmas = try vocab.dueCards(limit: 8).map(\.lemma)
            }
            preferredDueFocus = []

            let targets = LearnerProgress.targetLemmasForTutor(
                workingLevel: progress.workingLevel,
                knownLemmas: known,
                learningLemmas: learning,
                dueLemmas: dueLemmas,
                alreadyFocused: sessionFocusedLemmas,
                tutorPracticedLemmas: tutorPracticedLemmas,
                preferDueFirst: preferDueFirst,
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

            // Prefer known content lemmas as glue so Tutor stays inside learned vocab.
            let knownHint = Array(known.prefix(24)).sorted().joined(separator: ", ")
            let cefr = passageGenerationLevel
            let prompt = PassageGenerationPrompt(
                cefr: cefr,
                focusLemmas: focus,
                focusGlosses: glosses,
                knownGlueHint: knownHint.isEmpty
                    ? "ma, sa, on, ja, ei, see, täna, tahan, lähen"
                    : knownHint
            )

            let text = try await generatePassage(prompt: prompt, focus: focus, cefr: cefr)
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

    /// Single EstLLM sample gated by local usability checks (no second-pass review).
    private func generatePassage(
        prompt: PassageGenerationPrompt,
        focus: [String],
        cefr: CEFRLevel
    ) async throws -> GradedText {
        if Task.isCancelled { throw CancellationError() }

        let raw = try await languageModel.complete(
            system: prompt.system,
            user: prompt.user,
            maxTokens: 220,
            temperature: 0.35
        )
        if let draft = PassageGenerationParser.parse(raw, requiredFocus: focus, cefr: cefr) {
            return draft
        }
        throw EzeestiError.llmFailed(
            "EstLLM could not write a usable sentence for “\(focus.joined(separator: ", "))”"
        )
    }

    /// Wipe known/learning progress and draft a fresh first sentence.
    public func resetProgress() {
        generationTask?.cancel()
        do {
            try vocab.resetProgress()
            sessionFocusedLemmas = []
            preferredDueFocus = []
            pendingAdvanceAfterPerfect = false
            tutorPracticedLemmas = []
            persistTutorPracticed()
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
            try refreshProgress()
            continueRecommendedReading()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Sidebar: practice a specific lemma from the shared Words+Tutor queue.
    public func startTutorFocus(lemma: String) {
        preferredDueFocus = [EstonianTokenizer.normalize(lemma)]
        generationTask?.cancel()
        generationTask = Task { await generateAndSelectNextPassage() }
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
        do {
            try recomputeFamiliarity(for: text)
            phase = .reading
        } catch {
            phase = .error(error.localizedDescription)
        }
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
            pos: entry?.pos
        )

        do {
            let raw = try await languageModel.complete(system: prompt.system, user: prompt.user)
            guard let gloss = WordGlossParser.parse(raw) else {
                if selectedTokenIndex == tokenIndex {
                    generationDetail = "Gloss parse failed for \(token.surface)"
                }
                return
            }
            let source = "estllm"
            try vocab.saveGloss(forSurface: token.surface, glossEnglish: gloss, source: source)
            guard selectedTokenIndex == tokenIndex else { return }
            selectedWord = lookup(token: token, tokenIndex: tokenIndex)
            glossSource = source
        } catch {
            guard selectedTokenIndex == tokenIndex else { return }
            selectedWord = lookup(token: token, tokenIndex: tokenIndex)
            lastSpeakerError = nil
            generationDetail = error.localizedDescription
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
        do {
            try refreshProgress()
        } catch {
            phase = .error(error.localizedDescription)
            return
        }
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

            try refreshProgress()
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
            if let lastSpeakerError {
                speakingDetail = "Voice warmup issue: \(lastSpeakerError). Retrying…"
            } else {
                speakingDetail = "Playing model answer…"
            }
            try await speaker.speak(correction, languageCode: "et-EE")
            lastSpeakerError = nil
        } catch {
            speakingDetail = error.localizedDescription
            lastSpeakerError = error.localizedDescription
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
        do {
            try refreshProgress()
        } catch {
            phase = .error(error.localizedDescription)
            return
        }
        if advance {
            continueRecommendedReading()
            return
        }
        if let text = selectedText {
            do {
                try recomputeFamiliarity(for: text)
                phase = .reading
            } catch {
                phase = .error(error.localizedDescription)
            }
        } else {
            continueRecommendedReading()
        }
    }

    private var passageGenerationLevel: CEFRLevel {
        let levels = CEFRLevel.allCases
        let workingIdx = levels.firstIndex(of: progress.workingLevel) ?? 0
        let maxIdx = levels.firstIndex(of: Self.maxPassageCEFR) ?? 1
        return levels[min(workingIdx, maxIdx)]
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
            markTutorPracticed(focus)
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
        // Map flagged surfaces onto focus lemmas with bounded near-match (not open-ended hasPrefix).
        let focusKeys = Set(text.focusWords.map { EstonianTokenizer.normalize($0) })
        if set.isEmpty { return set }
        var expanded = set
        for focus in focusKeys {
            if set.contains(where: { lemmasNearlyMatch($0, focus) }) {
                expanded.insert(focus)
            }
        }
        return expanded
    }

    /// Exact match, or short inflectional near-miss (length delta ≤ 2, stem ≥ 3).
    private func lemmasNearlyMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 3 else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) {
            return abs(a.count - b.count) <= 2
        }
        return false
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

    private func recomputeFamiliarity(for text: GradedText) throws {
        let known = try vocab.knownLemmas()
        let learning = try vocab.learningLemmas()
        familiarity = GradedTextCatalog.familiarity(
            text: text,
            knownLemmas: known,
            learningLemmas: learning
        )
    }

    private func buildTutorQueue() throws -> [VocabCard] {
        let practiced = tutorPracticedLemmas
        let learning = try vocab.cards(withFamiliarity: .learning, limit: 40)
        let known = try vocab.cards(withFamiliarity: .known, limit: 40)
        return (learning + known).filter { card in
            !practiced.contains(EstonianTokenizer.normalize(card.lemma))
        }
    }

    private func markTutorPracticed(_ lemmas: [String]) {
        for lemma in lemmas {
            tutorPracticedLemmas.insert(EstonianTokenizer.normalize(lemma))
        }
        persistTutorPracticed()
        tutorQueue = (try? buildTutorQueue()) ?? tutorQueue
    }

    private func persistTutorPracticed() {
        defaults.set(Array(tutorPracticedLemmas).sorted(), forKey: Self.tutorPracticedDefaultsKey)
    }

    private static func loadTutorPracticed(from defaults: UserDefaults) -> Set<String> {
        let raw = defaults.stringArray(forKey: tutorPracticedDefaultsKey) ?? []
        return Set(raw.map { EstonianTokenizer.normalize($0) }.filter { !$0.isEmpty })
    }
}
