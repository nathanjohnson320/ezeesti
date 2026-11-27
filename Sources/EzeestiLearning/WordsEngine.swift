import Foundation
import Observation
import EzeestiCore
import EzeestiASR
import EzeestiLLM

/// Speakly-style Words mode: reveal a lemma, then mixed form drills (chips / type / speak).
@Observable
@MainActor
public final class WordsEngine {
    public enum Phase: Equatable {
        case idle
        case loading
        case reveal
        case drilling
        case recording
        case grading
        case itemFeedback
        case wordComplete
        case error(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var progress: LearnerProgress = .empty
    public private(set) var dueCount: Int = 0
    public private(set) var learningCards: [VocabCard] = []
    public private(set) var knownCards: [VocabCard] = []
    public private(set) var entry: LexiconEntry?
    public private(set) var glossEnglish: String = ""
    public private(set) var pack: WordFormsPack?
    public private(set) var drills: [WordDrillItem] = []
    public private(set) var drillIndex: Int = 0
    public private(set) var correctCount: Int = 0
    public private(set) var attemptedCount: Int = 0
    public private(set) var lastAnswerCorrect: Bool?
    public private(set) var lastTranscript: String = ""
    public private(set) var lastASRError: String?
    public private(set) var statusDetail: String = ""
    public private(set) var typedAnswer: String = ""
    public private(set) var isLoadingParadigm = false
    public private(set) var isLoadingDrills = false

    public let vocab: VocabStore
    public let recorder: MicrophoneRecorder

    private var languageModel: any LanguageModeling
    private var recognizer: any SpeechRecognizing
    private var loadTask: Task<Void, Never>?
    private var sessionFocusedLemmas: Set<String> = []
    /// When set, the next load uses this lemma instead of picking a new teachable word.
    private var preferredLemma: String?

    public var currentDrill: WordDrillItem? {
        guard drills.indices.contains(drillIndex) else { return nil }
        return drills[drillIndex]
    }

    public var wordsLevel: CEFRLevel {
        LearnerProgress.wordsWorkingLevel(from: progress)
    }

    public var canPractice: Bool {
        guard let pack else { return false }
        return !isLoadingDrills && pack.commonForms.count >= 2
    }

    public init(
        vocab: VocabStore,
        recorder: MicrophoneRecorder? = nil,
        recognizer: any SpeechRecognizing,
        languageModel: any LanguageModeling
    ) {
        self.vocab = vocab
        self.recorder = recorder ?? MicrophoneRecorder()
        self.recognizer = recognizer
        self.languageModel = languageModel
    }

    public func refreshProgress() throws {
        progress = try vocab.progressSnapshot()
        dueCount = progress.dueCount
        learningCards = try vocab.cards(withFamiliarity: .learning)
        knownCards = try vocab.cards(withFamiliarity: .known)
    }

    /// Start (or restart) a Words session on the next teachable lemma.
    public func startNextWord() {
        preferredLemma = nil
        loadTask?.cancel()
        loadTask = Task { await loadNextWord() }
    }

    /// Reopen form practice for a known or learning lemma from the sidebar.
    public func practiceWord(_ lemma: String) {
        let key = EstonianTokenizer.normalize(lemma)
        guard !key.isEmpty else { return }
        preferredLemma = key
        loadTask?.cancel()
        loadTask = Task { await loadNextWord() }
    }

    public func resetProgress() {
        loadTask?.cancel()
        do {
            try vocab.resetProgress()
            sessionFocusedLemmas = []
            preferredLemma = nil
            clearSession(keepProgress: false)
            try refreshProgress()
            startNextWord()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// After reveal, build drills and begin the first item.
    public func beginDrills() {
        guard canPractice, let pack else { return }
        drills = WordFormsParser.makeDrillQueue(from: pack)
        drillIndex = 0
        correctCount = 0
        attemptedCount = 0
        lastAnswerCorrect = nil
        lastTranscript = ""
        lastASRError = nil
        typedAnswer = ""
        phase = drills.isEmpty ? .wordComplete : .drilling
    }

    public func setTypedAnswer(_ value: String) {
        typedAnswer = value
    }

    public func submitChip(_ option: String) {
        guard let drill = currentDrill, drill.modality == .chips else { return }
        finishItem(correct: WordFormsParser.answersMatch(option, expected: drill.form.surface))
    }

    public func submitTyped() {
        guard let drill = currentDrill, drill.modality == .type else { return }
        finishItem(correct: WordFormsParser.answersMatch(typedAnswer, expected: drill.form.surface))
    }

    public func startSpeaking() async {
        guard let drill = currentDrill, drill.modality == .speak else { return }
        lastASRError = nil
        lastTranscript = ""
        let permitted = await recorder.requestPermission()
        guard permitted else {
            phase = .error("Microphone permission denied")
            return
        }
        do {
            try await recorder.startRecording()
            phase = .recording
        } catch {
            lastASRError = error.localizedDescription
            phase = .drilling
        }
    }

    public func stopSpeakingAndGrade() async {
        guard let drill = currentDrill else { return }
        do {
            phase = .grading
            let audioURL = try await recorder.stopRecording()
            let prompt = "\(drill.form.surface). \(drill.form.cloze.replacingOccurrences(of: "___", with: drill.form.surface))"
            let transcript = try await recognizer.transcribe(audioURL: audioURL, initialPrompt: prompt)
            let said = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lastTranscript = said
            let correct = WordFormsParser.answersMatch(said, expected: drill.form.surface)
            finishItem(correct: correct)
        } catch {
            lastASRError = error.localizedDescription
            phase = .drilling
        }
    }

    public func continueAfterFeedback() {
        guard phase == .itemFeedback else { return }
        typedAnswer = ""
        lastTranscript = ""
        lastASRError = nil
        lastAnswerCorrect = nil
        let next = drillIndex + 1
        if next >= drills.count {
            finalizeWord()
        } else {
            drillIndex = next
            phase = .drilling
        }
    }

    public var wordPassed: Bool {
        attemptedCount > 0 && Double(correctCount) / Double(attemptedCount) >= 0.7
    }

    public func continueAfterWordComplete() {
        startNextWord()
    }

    /// Retry form drills for the current lemma after a failed run (reuses the loaded pack).
    public func retryCurrentWord() {
        if canPractice {
            beginDrills()
            return
        }
        guard let lemma = entry?.lemma else {
            startNextWord()
            return
        }
        practiceWord(lemma)
    }

    private func loadNextWord() async {
        phase = .loading
        statusDetail = "Picking the next word…"
        clearSession(keepProgress: true)

        do {
            try refreshProgress()
            let level = LearnerProgress.wordsWorkingLevel(from: progress)
            let forced = preferredLemma
            preferredLemma = nil

            let next: LexiconEntry
            if let forced {
                statusDetail = "Opening \(forced)…"
                next = try resolveEntry(for: forced, level: level)
            } else {
                let known = try vocab.knownLemmas()
                let learning = try vocab.learningLemmas()
                let due = try vocab.dueCards(limit: 3).map(\.lemma)
                guard let picked = LearnerProgress.targetLemmaForWords(
                    workingLevel: level,
                    knownLemmas: known,
                    learningLemmas: learning,
                    dueLemmas: due,
                    alreadyFocused: sessionFocusedLemmas
                ) else {
                    phase = .idle
                    statusDetail = ""
                    return
                }
                next = picked
            }

            entry = next
            let existingCard = try vocab.card(forSurface: next.lemma)
            glossEnglish =
                (existingCard?.glossEnglish).flatMap { $0.isEmpty ? nil : $0 }
                ?? WordGlossCatalog.gloss(forSurface: next.lemma)
                ?? (try? vocab.cachedGloss(forSurface: next.lemma))
                ?? ""

            // Show the word immediately; fill paradigm + drills via two smaller EstLLM calls.
            phase = .reveal
            statusDetail = "Loading forms…"
            isLoadingDrills = true
            isLoadingParadigm = true

            if existingCard?.familiarity != .known {
                _ = try vocab.flagWord(
                    surface: next.lemma,
                    contextSentence: next.lemma,
                    glossEnglish: glossEnglish
                )
            }
            sessionFocusedLemmas.insert(EstonianTokenizer.normalize(next.lemma))
            try refreshProgress()

            let context = WordFormsContext(
                lemma: next.lemma,
                glossEnglish: glossEnglish.isEmpty ? nil : glossEnglish,
                pos: next.pos,
                cefr: next.cefr ?? level
            )

            // Two smaller calls: case table first (visible on reveal), then drills.
            // Sequential keeps a single OMLX model from jamming on concurrent chats.
            do {
                if let cached = try vocab.cachedParadigm(forSurface: next.lemma) {
                    if Task.isCancelled { return }
                    applyParadigm(cached)
                } else {
                    statusDetail = "Loading case table…"
                    let table = try await fetchParadigm(context: context)
                    if Task.isCancelled { return }
                    if let table {
                        try? vocab.saveParadigm(forSurface: next.lemma, paradigm: table)
                    }
                    applyParadigm(table)
                }
            } catch {
                if Task.isCancelled { return }
                // Still try drills so Practice can unlock without a table.
                isLoadingParadigm = false
            }

            do {
                statusDetail = "Preparing drills…"
                let drills = try await fetchDrills(context: context)
                if Task.isCancelled { return }
                applyDrills(drills, existingCard: existingCard)
            } catch {
                if Task.isCancelled { return }
                isLoadingDrills = false
                isLoadingParadigm = false
                phase = .error(error.localizedDescription)
                statusDetail = ""
                return
            }
        } catch {
            if Task.isCancelled { return }
            phase = .error(error.localizedDescription)
            statusDetail = ""
            isLoadingDrills = false
            isLoadingParadigm = false
        }
    }

    private func fetchDrills(context: WordFormsContext) async throws -> WordFormsPack {
        let prompt = WordDrillFormsPrompt(context: context)
        let raw = try await languageModel.complete(
            system: prompt.system,
            user: prompt.user,
            maxTokens: 650,
            temperature: 0.3
        )
        guard let parsed = WordFormsParser.parseDrills(raw, expectedLemma: context.lemma) else {
            throw EzeestiError.llmFailed("Could not parse drills for \(context.lemma)")
        }
        return parsed
    }

    private func fetchParadigm(context: WordFormsContext) async throws -> WordParadigm? {
        let prompt = WordParadigmPrompt(context: context)
        let raw = try await languageModel.complete(
            system: prompt.system,
            user: prompt.user,
            maxTokens: 900,
            temperature: 0.2
        )
        return WordFormsParser.parseParadigm(raw, expectedLemma: context.lemma)
    }

    private func applyDrills(_ drills: WordFormsPack, existingCard: VocabCard?) {
        if glossEnglish.isEmpty {
            glossEnglish = drills.glossEnglish
        }
        if let existing = pack?.paradigm {
            pack = drills.withParadigm(existing)
        } else {
            pack = drills
        }
        isLoadingDrills = false
        statusDetail = ""

        if existingCard?.familiarity == .known,
           !glossEnglish.isEmpty,
           existingCard?.glossEnglish.isEmpty == true {
            existingCard?.glossEnglish = glossEnglish
        }
    }

    private func applyParadigm(_ paradigm: WordParadigm?) {
        if let paradigm {
            if let current = pack {
                pack = current.withParadigm(paradigm)
            } else if let lemma = entry?.lemma {
                pack = WordFormsPack(
                    lemma: lemma,
                    glossEnglish: glossEnglish,
                    paradigm: paradigm,
                    commonForms: [],
                    extraForms: []
                )
            }
        }
        isLoadingParadigm = false
        if isLoadingDrills {
            statusDetail = "Preparing drills…"
        } else {
            statusDetail = ""
        }
    }

    private func resolveEntry(for lemma: String, level: CEFRLevel) throws -> LexiconEntry {
        LexiconCatalog.shared.loadBundledIfNeeded()
        if let entry = LexiconCatalog.shared.entry(forSurface: lemma) {
            return entry
        }
        if let entry = try vocab.lexiconEntry(forSurface: lemma) {
            return entry
        }
        return LexiconEntry(lemma: lemma, cefr: level, pos: nil, freqRank: nil)
    }

    private func finishItem(correct: Bool) {
        lastAnswerCorrect = correct
        attemptedCount += 1
        if correct { correctCount += 1 }
        phase = .itemFeedback
    }

    private func finalizeWord() {
        guard let lemma = entry?.lemma else {
            phase = .idle
            return
        }
        do {
            let ratio = attemptedCount == 0 ? 0.0 : Double(correctCount) / Double(attemptedCount)
            if ratio >= 0.7 {
                try vocab.markKnownWithBackoff([lemma])
            } else {
                try vocab.markLearningDueSoon([lemma])
            }
            try refreshProgress()
            phase = .wordComplete
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func clearSession(keepProgress: Bool) {
        entry = nil
        glossEnglish = ""
        pack = nil
        drills = []
        drillIndex = 0
        correctCount = 0
        attemptedCount = 0
        lastAnswerCorrect = nil
        lastTranscript = ""
        lastASRError = nil
        typedAnswer = ""
        isLoadingParadigm = false
        isLoadingDrills = false
        statusDetail = ""
        if !keepProgress {
            progress = .empty
            dueCount = 0
            learningCards = []
            knownCards = []
        }
    }
}
