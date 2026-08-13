import SwiftUI
import SwiftData
import EzeestiCore
import EzeestiASR
import EzeestiLLM
import EzeestiTTS
import EzeestiTutor
import EzeestiLearning

/// App root: boots shared native models, shows warmup, then the learning session.
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
                if let learning = engines.learning {
                    TabView {
                        LearningSessionView(learning: learning)
                            .tabItem {
                                Label("Learn", systemImage: "text.bubble")
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

    /// Builds the shared native stack, boots learning, and warms tutor models once.
    func start(modelContext: ModelContext) async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            let paths = try ModelPaths.defaultApplicationSupport()
            guard paths.whisperNativeReady,
                  let whisperModel = paths.whisperGGML,
                  let whisperLib = paths.whisperLibDir
            else {
                throw EzeestiError.modelMissing("Whisper weights or libEzeestiWhisper.dylib")
            }
            guard paths.llamaNativeReady,
                  let llamaModel = paths.estLLMGGUF,
                  let llamaLib = paths.llamaLibDir
            else {
                throw EzeestiError.modelMissing("EstLLM weights or libEzeestiLlama.dylib")
            }
            guard let neurokone = paths.neurokoneBinary,
                  FileManager.default.isExecutableFile(atPath: neurokone.path)
            else {
                throw EzeestiError.modelMissing("neurokone-cli. Run Scripts/setup-neurokone.sh")
            }

            // One shared native stack for tutor + learning (avoid double Metal residency).
            let whisper = WhisperCppService(modelPath: whisperModel, libDir: whisperLib)
            let llama = LlamaCppService(modelPath: llamaModel, libDir: llamaLib)
            let speaker = NeurokoneTTSService(binaryPath: neurokone)

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
            self.tutor = tutor
            self.learning = learning
            await learning.bootstrap()
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

/// Free-form Estonian → English translation via EstLLM.
private struct TranslateView: View {
    var learning: LearningEngine
    @State private var input = ""
    @State private var result: TextTranslationResult?
    @State private var errorMessage: String?
    @State private var isTranslating = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Translate")
            .onAppear { inputFocused = true }
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
            result = try await learning.translateEstonian(source)
        } catch {
            errorMessage = error.localizedDescription
        }
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

                Section("Needs review") {
                    if learning.dueCount == 0 {
                        Text("Nothing due — keep reading.")
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
                    }
                }
            }
            .navigationTitle("ezeesti")
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
                         ? "Drafting and checking one short sentence around the next word."
                         : learning.generationDetail)
                }
            case .reading, .speakingSummary, .recordingSummary, .transcribing, .grading, .summaryFeedback, .completed:
                ReadingDetailView(learning: learning)
            case .error(let message):
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(message))
            default:
                ContentUnavailableView(
                    "Read → look up → speak",
                    systemImage: "text.bubble",
                    description: Text("Tap a word for its meaning. Flag ones you need help with, then read the sentence aloud.")
                )
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

                        Text("Built around one word you still need")
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
