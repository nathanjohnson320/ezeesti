import SwiftUI
import SwiftData
import EzeestiCore
import EzeestiASR
import EzeestiLLM
import EzeestiTTS
import EzeestiTutor
import EzeestiLearning

/// App root: boots shared OMLX backends, shows warmup, then the learning session.
public struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var engines = EngineHolder()

    public init() {}

    public var body: some View {
        Group {
            switch SetupPresentation.screen(engines.snapshot) {
            case .failed(let failure):
                VStack(spacing: 12) {
                    Text("Setup failed")
                        .font(.title.bold())
                    Text(failure.message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text("Run the setup commands in README.md, then relaunch Ezeesti.")
                        .font(.callout)
                    #if DEBUG
                    Text(failure.debugDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            case .session:
                if let learning = engines.learning, let words = engines.words {
                    TabView {
                        WordsSessionView(words: words)
                            .tabItem {
                                Label("Words", systemImage: "textformat.abc")
                            }
                        LearningSessionView(learning: learning)
                            .tabItem {
                                Label("Tutor", systemImage: "text.bubble")
                            }
                        TranslateView(learning: learning)
                            .tabItem {
                                Label("Translate", systemImage: "globe")
                            }
                    }
                } else {
                    ProgressView("Checking setup…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .warming:
                if let tutor = engines.tutor {
                    WarmupView(engine: tutor)
                } else {
                    ProgressView("Checking setup…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .checking:
                ProgressView("Checking setup…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await engines.start(modelContext: modelContext)
        }
    }
}

/// Owns tutor/learning engines and launch readiness for `RootView` observation.
@Observable
@MainActor
final class EngineHolder {
    private(set) var tutor: TutorEngine?
    private(set) var learning: LearningEngine?
    private(set) var words: WordsEngine?
    private(set) var setupFailure: SetupFailure?
    /// Mirrors the tutor's warmup completion: nested engine observation does not
    /// automatically drive `SetupPresentation` unless readiness lives on this holder.
    private(set) var isReady = false
    private var hasStarted = false

    var snapshot: SetupSnapshot {
        SetupSnapshot(
            setupFailure: setupFailure,
            hasTutor: tutor != nil,
            holderReady: isReady,
            hasLearning: learning != nil
        )
    }

    /// Builds the shared OMLX clients, boots learning, and warms tutor models once.
    func start(modelContext: ModelContext) async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            let paths = try ModelPaths.defaultApplicationSupport()
            guard paths.whisperReady else {
                throw EzeestiError.modelMissing(
                    "Whisper MLX — run Scripts/fetch-models.sh then: omlx serve --model-dir \"\(paths.modelsRoot.path)\""
                )
            }
            guard paths.llmReady else {
                throw EzeestiError.modelMissing(
                    "EstLLM MLX — run Scripts/fetch-models.sh then: omlx serve --model-dir \"\(paths.modelsRoot.path)\""
                )
            }

            let omlx = OmlxConfig.fromEnvironment(modelPaths: paths)
            // One HTTP client for tutor + learning (same server / model IDs).
            let client = OmlxClient(config: omlx)
            let whisper = OmlxSpeechRecognizer(client: client)
            let llama = OmlxLanguageModel(client: client)
            // Neurokõne when available; otherwise macOS system speech (no gated HF access needed).
            let speaker = TTSBackend.resolve(modelPaths: paths)

            let tutor = try TutorEngine(
                modelPaths: paths,
                recognizer: whisper,
                languageModel: llama,
                speaker: speaker
            )
            let store = VocabStore(modelContext: modelContext)
            let learning = try LearningEngine(
                vocab: store,
                recognizer: whisper,
                languageModel: llama,
                speaker: speaker,
                modelPaths: paths
            )
            let words = WordsEngine(
                vocab: store,
                recognizer: whisper,
                languageModel: llama
            )
            self.tutor = tutor
            self.learning = learning
            self.words = words
            await learning.bootstrap()
            try words.refreshProgress()
            words.startNextWord()
            try await tutor.warmupModels()
            isReady = true
        } catch {
            let failure = SetupFailure(from: error)
            #if DEBUG
            print("EngineHolder setup failure: \(failure.debugDescription)")
            #endif
            setupFailure = failure
        }
    }
}

/// Words mode: reveal a lemma, then mixed form drills.
private struct WordsSessionView: View {
    var words: WordsEngine
    @State private var confirmReset = false
    @State private var knownFilter = ""
    @FocusState private var typeFocused: Bool

    private var filteredKnownCards: [VocabCard] {
        let query = knownFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return words.knownCards }
        return words.knownCards.filter { card in
            card.lemma.lowercased().contains(query)
                || card.surfaceForm.lowercased().contains(query)
                || card.glossEnglish.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("You") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(words.progress.levelLabel)
                            .font(.title3.weight(.semibold))
                        Text("\(words.progress.knownCount) known · \(words.progress.learningCount) learning")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Words · \(words.wordsLevel.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)

                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("Reset progress", systemImage: "arrow.counterclockwise")
                    }
                }

                Section("Learning") {
                    if words.learningCards.isEmpty {
                        Text("Nothing in learning yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(words.learningCards) { card in
                            Button {
                                words.practiceWord(card.lemma)
                            } label: {
                                vocabRow(card)
                            }
                        }
                    }
                }

                Section("Known") {
                    if words.knownCards.count > 8 {
                        TextField("Search known…", text: $knownFilter)
                    }
                    if words.knownCards.isEmpty {
                        Text("No known words yet — finish a form drill.")
                            .foregroundStyle(.secondary)
                    } else if filteredKnownCards.isEmpty {
                        Text("No matches.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredKnownCards) { card in
                            Button {
                                words.practiceWord(card.lemma)
                            } label: {
                                vocabRow(card)
                            }
                        }
                    }
                }

                Section("Session") {
                    if let entry = words.entry {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.lemma).font(.headline)
                                Text(words.glossEnglish.isEmpty ? (entry.cefr?.rawValue ?? "") : words.glossEnglish)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "textformat")
                        }
                    }

                    if words.phase == .loading || words.isLoadingDrills || words.isLoadingParadigm {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(words.statusDetail.isEmpty ? "Loading…" : words.statusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if words.phase != .loading {
                        Button("Next word") {
                            words.startNextWord()
                        }
                        .disabled(words.isLoadingDrills || words.isLoadingParadigm)
                    }
                }
            }
            .navigationTitle("Words")
            .frame(minWidth: 260)
            .confirmationDialog(
                "Reset all progress?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset progress", role: .destructive) {
                    words.resetProgress()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears known and learning words and starts again from zero. This cannot be undone.")
            }
        } detail: {
            wordsDetail
        }
        .onAppear {
            try? words.refreshProgress()
        }
    }

    private func vocabRow(_ card: VocabCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.surfaceForm.isEmpty ? card.lemma : card.surfaceForm)
                .font(.headline)
            if !card.glossEnglish.isEmpty {
                Text(card.glossEnglish)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var wordsDetail: some View {
        switch words.phase {
        case .loading:
            ContentUnavailableView {
                Label("Preparing forms", systemImage: "textformat.abc")
            } description: {
                Text(words.statusDetail.isEmpty
                     ? "Asking EstLLM for the common forms of the next word."
                     : words.statusDetail)
            }
        case .reveal:
            if let entry = words.entry {
                revealView(entry: entry)
            }
        case .drilling, .recording, .grading, .itemFeedback:
            drillView
        case .wordComplete:
            wordCompleteView
        case .error(let message):
            ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(message))
        case .idle:
            ContentUnavailableView(
                "No more words here",
                systemImage: "checkmark.circle",
                description: Text("You’ve covered the current band, or the lexicon is empty. Try Tutor with what you know.")
            )
        }
    }

    private func revealView(entry: LexiconEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(entry.lemma)
                    .font(.largeTitle.weight(.bold))
                if !words.glossEnglish.isEmpty {
                    Text(words.glossEnglish)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let cefr = entry.cefr {
                        Text(cefr.rawValue)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    if let pos = entry.posDisplayLabel {
                        Text(pos)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let paradigm = words.pack?.paradigm, !paradigm.rows.isEmpty {
                    paradigmTable(paradigm)
                } else if words.isLoadingParadigm {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading case table…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Text("You’ll practice the most common forms of this word — chips, typing, and speaking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    words.beginDrills()
                } label: {
                    if words.isLoadingDrills {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Preparing drills…")
                        }
                    } else {
                        Text("Practice forms")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!words.canPractice)
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func paradigmTable(_ paradigm: WordParadigm) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(paradigm.isVerb ? "Pööramine" : "Käänded")
                .font(.headline)
            Text(paradigm.isVerb ? "Conjugation" : "All 14 cases · ainsus / mitmus")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Kääne")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(paradigm.isVerb ? "Vorm" : "Ainsus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if paradigm.isCases {
                        Text("Mitmus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(paradigm.rows) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.nameEt)
                                .font(.callout.weight(.medium))
                            if !row.nameEn.isEmpty {
                                Text(row.nameEn)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(row.singular.isEmpty ? "—" : row.singular)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        if paradigm.isCases {
                            Text(row.plural.isEmpty ? "—" : row.plural)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var drillView: some View {
        if let drill = words.currentDrill {
            VStack(alignment: .leading, spacing: 20) {
                Text("Form \(words.drillIndex + 1) of \(words.drills.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(drill.form.label)
                    .font(.headline)
                Text(drill.form.cloze)
                    .font(.title2.weight(.semibold))
                Text(drill.form.clozeEnglish)
                    .foregroundStyle(.secondary)

                if words.phase == .itemFeedback {
                    feedbackBlock(for: drill)
                } else {
                    modalityControls(for: drill)
                }
                Spacer()
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("No drills", systemImage: "questionmark.circle")
        }
    }

    @ViewBuilder
    private func modalityControls(for drill: WordDrillItem) -> some View {
        switch drill.modality {
        case .chips:
            Text("Pick the form that fills the blank.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                ForEach(drill.chipOptions, id: \.self) { option in
                    Button(option) {
                        words.submitChip(option)
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .type:
            Text("Type the missing form.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("form", text: Binding(
                get: { words.typedAnswer },
                set: { words.setTypedAnswer($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .focused($typeFocused)
            .onAppear { typeFocused = true }
            .onSubmit { words.submitTyped() }
            Button("Check") {
                words.submitTyped()
            }
            .buttonStyle(.borderedProminent)
            .disabled(words.typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .speak:
            Text("Say the missing form (or the whole sentence).")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let asrError = words.lastASRError {
                Text(asrError)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            switch words.phase {
            case .recording:
                Button("Stop & check") {
                    Task { await words.stopSpeakingAndGrade() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            case .grading:
                ProgressView("Listening…")
            default:
                Button("Speak") {
                    Task { await words.startSpeaking() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func feedbackBlock(for drill: WordDrillItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(words.lastAnswerCorrect == true ? "Correct" : "Not quite")
                .font(.headline)
                .foregroundStyle(words.lastAnswerCorrect == true ? Color.green : Color.orange)
            Text("Answer: \(drill.form.surface)")
                .font(.title3.weight(.semibold))
            if !drill.form.reason.isEmpty {
                Text(drill.form.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !words.lastTranscript.isEmpty {
                Text("You said: \(words.lastTranscript)")
                    .foregroundStyle(.secondary)
            }
            Button("Continue") {
                words.continueAfterFeedback()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (words.lastAnswerCorrect == true ? Color.green : Color.orange).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var wordCompleteView: some View {
        let passed = words.wordPassed
        return VStack(spacing: 16) {
            Image(systemName: passed ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(passed ? Color.green : Color.orange)
            Text(words.entry?.lemma ?? "Word")
                .font(.largeTitle.weight(.bold))
            Text("\(words.correctCount) / \(words.attemptedCount) forms correct")
                .foregroundStyle(.secondary)
            Text(passed
                  ? "Marked known — keep going."
                  : "Stays in learning for more practice.")
                .font(.callout)
            if passed {
                Button("Next word") {
                    words.continueAfterWordComplete()
                }
                .buttonStyle(.borderedProminent)
                Button("Retry") {
                    words.retryCurrentWord()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Retry") {
                    words.retryCurrentWord()
                }
                .buttonStyle(.borderedProminent)
                Button("Skip to next word") {
                    words.continueAfterWordComplete()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// One past Translate session shown in the sidebar.
private struct TranslationHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let source: String
    let result: TextTranslationResult
    let createdAt: Date

    init(id: UUID = UUID(), source: String, result: TextTranslationResult, createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.result = result
        self.createdAt = createdAt
    }

    var previewSource: String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 48 { return trimmed }
        return String(trimmed.prefix(45)) + "…"
    }

    var previewEnglish: String {
        let trimmed = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 56 { return trimmed }
        return String(trimmed.prefix(53)) + "…"
    }
}

/// Free-form Estonian → English translation via EstLLM.
private struct TranslateView: View {
    private static let historyDefaultsKey = "ezeesti.translate.history"
    private static let maxHistoryCount = 40

    var learning: LearningEngine
    @State private var input = ""
    @State private var result: TextTranslationResult?
    @State private var errorMessage: String?
    @State private var isTranslating = false
    @State private var history: [TranslationHistoryEntry] = []
    @State private var selectedHistoryID: UUID?
    @State private var confirmClearHistory = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedHistoryID) {
                Section("History") {
                    if history.isEmpty {
                        Text("No translations yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(history) { entry in
                            Button {
                                restore(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.previewSource)
                                        .font(.headline)
                                        .lineLimit(2)
                                    Text(entry.previewEnglish)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .tag(entry.id)
                        }
                        .onDelete(perform: deleteHistory)
                    }
                }

                if !history.isEmpty {
                    Section {
                        Button("Clear history", role: .destructive) {
                            confirmClearHistory = true
                        }
                    }
                }
            }
            .navigationTitle("Translate")
            .frame(minWidth: 260)
            .confirmationDialog(
                "Clear translation history?",
                isPresented: $confirmClearHistory,
                titleVisibility: .visible
            ) {
                Button("Clear history", role: .destructive) {
                    history = []
                    selectedHistoryID = nil
                    persistHistory()
                }
                Button("Cancel", role: .cancel) {}
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Paste or type Estonian text. EstLLM translates it and explains each phrase.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $input)
                        .font(.title3)
                        .focused($inputFocused)
                        .frame(minHeight: 120, maxHeight: 220)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )

                    controls

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let result {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("English")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(result.translation)
                                .font(.title3)
                                .textSelection(.enabled)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                        if !result.breakdown.isEmpty {
                            BreakdownView(chunks: result.breakdown)
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onAppear { inputFocused = true }
        }
        .onAppear {
            loadHistory()
        }
    }

    private var hasContent: Bool {
        !input.isEmpty || result != nil || errorMessage != nil
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await translate() }
            } label: {
                if isTranslating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 8)
                } else {
                    Text("Translate")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isTranslating || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Clear") {
                input = ""
                result = nil
                errorMessage = nil
                selectedHistoryID = nil
                inputFocused = true
            }
            .disabled(isTranslating || !hasContent)
        }
    }

    @MainActor
    private func translate() async {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        isTranslating = true
        errorMessage = nil
        result = nil
        defer { isTranslating = false }
        do {
            let translation = try await learning.translateEstonian(source)
            result = translation
            remember(source: source, result: translation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remember(source: String, result: TextTranslationResult) {
        let normalized = EstonianTokenizer.normalize(source)
        history.removeAll {
            EstonianTokenizer.normalize($0.source) == normalized
                && $0.result.translation == result.translation
        }
        let entry = TranslationHistoryEntry(source: source, result: result)
        history.insert(entry, at: 0)
        if history.count > Self.maxHistoryCount {
            history = Array(history.prefix(Self.maxHistoryCount))
        }
        selectedHistoryID = entry.id
        persistHistory()
    }

    private func restore(_ entry: TranslationHistoryEntry) {
        selectedHistoryID = entry.id
        input = entry.source
        result = entry.result
        errorMessage = nil
        inputFocused = false
    }

    private func deleteHistory(at offsets: IndexSet) {
        let removedIDs = Set(offsets.map { history[$0].id })
        history.remove(atOffsets: offsets)
        if let selectedHistoryID, removedIDs.contains(selectedHistoryID) {
            self.selectedHistoryID = nil
        }
        persistHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyDefaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([TranslationHistoryEntry].self, from: data) {
            history = decoded
        }
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyDefaultsKey)
    }
}

/// Phrase-by-phrase gloss of a translated sentence.
private struct BreakdownView: View {
    let chunks: [TranslationChunk]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Word by word")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(chunk.estonian)
                            .font(.headline)
                        Text("—")
                            .foregroundStyle(.tertiary)
                        Text(chunk.english)
                            .font(.body)
                    }
                    if !chunk.literal.isEmpty {
                        Text("literally: \(chunk.literal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !chunk.note.isEmpty {
                        Text(chunk.note)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Sidebar + detail learning UI driven by `LearningEngine`.
public struct LearningSessionView: View {
    var learning: LearningEngine
    @State private var confirmReset = false

    public var body: some View {
        NavigationSplitView {
            List {
                Section("You") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(learning.progress.levelLabel)
                            .font(.title3.weight(.semibold))
                        Text("\(learning.progress.knownCount) known · \(learning.progress.learningCount) learning")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("Reset progress", systemImage: "arrow.counterclockwise")
                    }
                }

                Section("Speak next") {
                    if !learning.canStartTutor {
                        Text("Learn words first in Words mode.")
                            .foregroundStyle(.secondary)
                    } else if learning.tutorQueue.isEmpty {
                        Text("All current words have been spoken here.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("From Words + learning — not spoken in Tutor yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(learning.tutorQueue.prefix(12)) { card in
                            Button {
                                learning.startTutorFocus(lemma: card.lemma)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.surfaceForm.isEmpty ? card.lemma : card.surfaceForm)
                                        .font(.headline)
                                    if !card.glossEnglish.isEmpty {
                                        Text(card.glossEnglish)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Needs review") {
                    if !learning.canStartTutor {
                        Text("Learn words first in Words mode.")
                            .foregroundStyle(.secondary)
                    } else if learning.dueCount == 0 {
                        Text("Nothing due — keep speaking.")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            learning.startDueReview()
                        } label: {
                            Label("Review \(learning.dueCount) word\(learning.dueCount == 1 ? "" : "s")", systemImage: "mic.fill")
                        }
                        ForEach(learning.duePreview) { card in
                            Button {
                                learning.startDueReview(preferringLemma: card.lemma)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.surfaceForm).font(.headline)
                                    if !card.glossEnglish.isEmpty {
                                        Text(card.glossEnglish)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Practice") {
                    if let text = learning.selectedText, let report = learning.familiarity {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(text.title).font(.headline)
                                Text("\(text.cefr.rawValue) · ~\(report.percentKnown)% known in sentence")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "text.bubble.fill")
                        }
                    }
                    if learning.isGeneratingPassage {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(learning.generationDetail.isEmpty
                                 ? "Writing next sentence…"
                                 : learning.generationDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("New sentence") {
                            learning.continueRecommendedReading()
                        }
                        .disabled(!learning.canStartTutor)
                    }
                }
            }
            .navigationTitle("Tutor")
            .frame(minWidth: 260)
            .confirmationDialog(
                "Reset all progress?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset progress", role: .destructive) {
                    learning.resetProgress()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears known and learning words and starts again from zero. This cannot be undone.")
            }
        } detail: {
            switch learning.phase {
            case .generatingPassage:
                ContentUnavailableView {
                    Label("Writing your next sentence", systemImage: "text.badge.plus")
                } description: {
                    Text(learning.generationDetail.isEmpty
                         ? "Drafting one short sentence around a word you already know."
                         : learning.generationDetail)
                }
            case .reading, .speakingSummary, .recordingSummary, .transcribing, .grading, .summaryFeedback, .completed:
                ReadingDetailView(learning: learning)
            case .error(let message):
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(message))
            default:
                if learning.canStartTutor {
                    ContentUnavailableView(
                        "Speak what you know",
                        systemImage: "text.bubble",
                        description: Text("Tutor builds a simple sentence from words you’ve learned in Words mode. Tap a word for its meaning, then read aloud.")
                    )
                } else {
                    ContentUnavailableView(
                        "Learn a few words first",
                        systemImage: "textformat.abc",
                        description: Text("Switch to Words to learn lemmas and forms. Tutor unlocks once you have vocabulary to speak.")
                    )
                }
            }
        }
        .onAppear {
            try? learning.refreshProgress()
            learning.refreshFamiliarity()
            if learning.selectedText == nil, learning.canStartTutor, !learning.isGeneratingPassage {
                learning.continueRecommendedReading()
            }
        }
    }
}

private struct WarmupView: View {
    var engine: TutorEngine

    var body: some View {
        VStack(spacing: 20) {
            Text("ezeesti")
                .font(.largeTitle.weight(.bold))
            ProgressView()
                .controlSize(.large)
            Text(engine.warmupDetail)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct ReadingDetailView: View {
    var learning: LearningEngine

    private var isPracticeActive: Bool {
        switch learning.phase {
        case .speakingSummary, .recordingSummary, .transcribing, .grading, .summaryFeedback, .completed:
            return true
        default:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let text = learning.selectedText, let report = learning.familiarity {
                        Text(text.title).font(.title2.weight(.semibold))
                        HStack {
                            Text("~\(report.percentKnown)% words known")
                                .foregroundStyle(report.percentKnown >= 90 ? Color.green : Color.orange)
                            Spacer()
                            Text("\(learning.flaggedTokenIndexes.count) for review")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)

                        Text("Built around a word you already know")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        if !isPracticeActive {
                            Text("Tap a word for its meaning. Orange = likely new. Flag words you need help with, then read aloud.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        TokenFlowView(
                            tokens: report.tokens,
                            predictedUnknown: report.predictedUnknown,
                            flagged: learning.flaggedTokenIndexes,
                            selected: isPracticeActive ? nil : learning.selectedTokenIndex,
                            onTap: { index in
                                guard !isPracticeActive else { return }
                                learning.selectWord(tokenIndex: index)
                            }
                        )

                        Text(text.glossEnglish)
                            .foregroundStyle(.secondary)

                        if !isPracticeActive {
                            if !learning.flaggedTokenIndexes.isEmpty {
                                let flagged = learning.flaggedTokenIndexes.sorted().compactMap { idx in
                                    wordSurface(in: report, at: idx)
                                }
                                if !flagged.isEmpty {
                                    Text("Flagged (stay in learning): \(flagged.joined(separator: ", "))")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Read the sentence aloud. Unflagged focus words become known when you read it correctly.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        practiceControls
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isPracticeActive, let word = learning.selectedWord {
                WordInspectorView(
                    word: word,
                    isFlagged: learning.flaggedTokenIndexes.contains(word.tokenIndex),
                    isGeneratingGloss: learning.isGeneratingGloss,
                    glossSource: learning.glossSource,
                    onToggleFlag: { learning.toggleFlagOnSelectedWord() }
                )
            }
        }
    }

    /// Returns the surface for a word token at `index`, or `nil` when out of bounds / non-word.
    private func wordSurface(in report: TextFamiliarityReport, at index: Int) -> String? {
        guard report.tokens.indices.contains(index) else { return nil }
        let token = report.tokens[index]
        guard token.isWord else { return nil }
        return token.surface
    }

    @ViewBuilder
    private var practiceControls: some View {
        if let asrError = learning.lastASRError {
            Text(asrError)
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }

        if !learning.lastTranscript.isEmpty {
            Text("You said: \(learning.lastTranscript)")
                .font(.title3)
        }

        if let feedback = learning.lastSummaryFeedback {
            VStack(alignment: .leading, spacing: 8) {
                Text(feedback.verdict == .correct ? "Correct" : "Keep going")
                    .font(.headline)
                if !feedback.explanation.isEmpty {
                    Text(feedback.explanation)
                }
                if !feedback.missingRequiredWords.isEmpty {
                    Text("Still need: \(feedback.missingRequiredWords.joined(separator: ", "))")
                        .foregroundStyle(.orange)
                }
                Text("Model sentence").font(.caption).foregroundStyle(.secondary)
                Text(feedback.correction).font(.title3.weight(.semibold))
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }

        if learning.isSpeakingCorrection {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(learning.speakingDetail.isEmpty ? "Playing…" : learning.speakingDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        HStack(spacing: 12) {
            switch learning.phase {
            case .reading:
                Button("Read aloud") {
                    Task { await learning.commitFlagsAndStartSpeaking() }
                }
                .buttonStyle(.borderedProminent)
            case .recordingSummary:
                Button("Stop & grade") {
                    Task { await learning.stopSummaryAndGrade() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            case .transcribing, .grading:
                ProgressView("Grading…")
            case .summaryFeedback:
                Button("Try again") {
                    Task { await learning.retrySummaryAndRecord() }
                }
                .buttonStyle(.borderedProminent)
                Button("Hear model") {
                    Task { await learning.speakCorrection() }
                }
                .disabled(learning.isSpeakingCorrection)
                Button("Back") { learning.finishToReading() }
            case .completed:
                Button("Done") { learning.finishToReading() }
                    .buttonStyle(.borderedProminent)
                Button("Hear model") {
                    Task { await learning.speakCorrection() }
                }
                .disabled(learning.isSpeakingCorrection)
            case .speakingSummary:
                Button("Record") {
                    Task { await learning.startRecordingForSummary() }
                }
                .buttonStyle(.borderedProminent)
            default:
                EmptyView()
            }
        }
    }
}

private struct WordInspectorView: View {
    let word: WordLookup
    let isFlagged: Bool
    let isGeneratingGloss: Bool
    let glossSource: String?
    let onToggleFlag: () -> Void

    private var lemmaDiffersFromSurface: Bool {
        EstonianTokenizer.normalize(word.lemma) != EstonianTokenizer.normalize(word.surface)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(word.surface)
                        .font(.title2.weight(.bold))
                    if lemmaDiffersFromSurface {
                        Text("lemma: \(word.lemma)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(word.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let gloss = word.glossEnglish {
                        Text(gloss)
                            .font(.title3)
                        if let glossSource {
                            Text(sourceLabel(glossSource))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else if isGeneratingGloss {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Asking EstLLM for a gloss…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No English gloss yet — flag it to review in context.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(isFlagged ? "Remove flag" : "Flag for review") {
                    onToggleFlag()
                }
                .buttonStyle(.borderedProminent)
                .tint(isFlagged ? .orange : .accentColor)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
        }
        .background(.bar)
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "estllm": return "gloss · EstLLM"
        case "cache": return "gloss · saved"
        default: return "gloss · \(source)"
        }
    }
}

private struct TokenFlowView: View {
    let tokens: [TextToken]
    let predictedUnknown: Set<Int>
    let flagged: Set<Int>
    let selected: Int?
    let onTap: (Int) -> Void

    var body: some View {
        TokenWrap(spacing: 4) {
            ForEach(tokens) { token in
                if token.isWord {
                    Button { onTap(token.index) } label: {
                        Text(token.surface)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(bg(token), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(selected == token.index ? Color.accentColor : .clear, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(token.surface)
                }
            }
        }
        .font(.title3)
    }

    private func bg(_ token: TextToken) -> Color {
        if flagged.contains(token.index) { return Color.accentColor.opacity(0.35) }
        if predictedUnknown.contains(token.index) { return Color.orange.opacity(0.18) }
        return .clear
    }
}

private struct TokenWrap: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 480
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
