import SwiftUI
import SwiftData
import EzeestiCore
import EzeestiTutor
import EzeestiLearning

public struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var tutor = TutorEngine()
    @StateObject private var learningHolder = LearningHolder()

    public init() {}

    public var body: some View {
        Group {
            if tutor.isWarmupFinished {
                if let learning = learningHolder.engine {
                    LearningSessionView(learning: learning)
                } else {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                WarmupView(engine: tutor)
            }
        }
        .task {
            if learningHolder.engine == nil {
                let store = VocabStore(modelContext: modelContext)
                learningHolder.attach(LearningEngine(vocab: store))
            }
            learningHolder.engine?.bootstrap()
            // Primes Metal/Whisper/EstLLM paths used by Learn as well.
            await tutor.warmupModels()
        }
    }
}

@MainActor
final class LearningHolder: ObservableObject {
    @Published var engine: LearningEngine?

    func attach(_ engine: LearningEngine) {
        self.engine = engine
    }
}

public struct LearningSessionView: View {
    @ObservedObject var learning: LearningEngine

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
                }

                Section("Needs review") {
                    if learning.dueCount == 0 {
                        Text("Nothing due — keep reading.")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            learning.startFSRSReview()
                        } label: {
                            Label("Review \(learning.dueCount) word\(learning.dueCount == 1 ? "" : "s")", systemImage: "mic.fill")
                        }
                        ForEach(learning.duePreview, id: \.lemma) { card in
                            Button {
                                learning.startFSRSReview(preferringLemma: card.lemma)
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

                Section("Continue reading") {
                    if let text = learning.selectedText, let report = learning.familiarity {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(text.title).font(.headline)
                                Text("\(text.cefr.rawValue) · ~\(report.percentKnown)% known in text")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "text.book.closed.fill")
                        }
                    }
                    Button("Pick best next text") {
                        learning.continueRecommendedReading()
                    }
                }

                DisclosureGroup("All texts") {
                    ForEach(learning.texts) { text in
                        Button {
                            learning.selectText(text)
                        } label: {
                            HStack {
                                Text(text.title)
                                Spacer()
                                Text(text.cefr.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("ezeesti")
            .frame(minWidth: 260)
        } detail: {
            switch learning.phase {
            case .reviewing, .recordingReview:
                ReviewDetailView(learning: learning)
            case .reading:
                ReadingDetailView(learning: learning)
            case .speakingSummary, .recordingSummary, .transcribing, .grading, .summaryFeedback, .completed:
                SummaryDetailView(learning: learning)
            case .error(let message):
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(message))
            default:
                ContentUnavailableView(
                    "Read → look up → speak",
                    systemImage: "text.book.closed",
                    description: Text("Tap a word for its meaning. Flag ones you need help with, then speak a summary.")
                )
            }
        }
    }
}

private struct WarmupView: View {
    @ObservedObject var engine: TutorEngine

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
    @ObservedObject var learning: LearningEngine

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

                        Text("Tap a word for its meaning. Orange = likely new. Flag words you need help with.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TokenFlowView(
                            tokens: report.tokens,
                            predictedUnknown: report.predictedUnknown,
                            flagged: learning.flaggedTokenIndexes,
                            selected: learning.selectedTokenIndex,
                            onTap: { learning.selectWord(tokenIndex: $0) }
                        )

                        Text(text.glossEnglish)
                            .foregroundStyle(.secondary)

                        Button("Speak summary with flagged words") {
                            learning.commitFlagsAndStartSpeaking()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let word = learning.selectedWord {
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
}

private struct WordInspectorView: View {
    let word: WordLookup
    let isFlagged: Bool
    let isGeneratingGloss: Bool
    let glossSource: String?
    let onToggleFlag: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(word.surface)
                        .font(.title2.weight(.bold))
                    if EstonianTokenizer.normalize(word.lemma) != EstonianTokenizer.normalize(word.surface) {
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
        case "fallback": return "gloss · offline fallback"
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

private struct ReviewDetailView: View {
    @ObservedObject var learning: LearningEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("FSRS review").font(.title2.weight(.semibold))
            if let card = learning.currentReview {
                Text(card.surfaceForm).font(.largeTitle.weight(.bold))
                if !card.glossEnglish.isEmpty {
                    Text(card.glossEnglish).font(.title3).foregroundStyle(.secondary)
                }
                if !card.contextSentence.isEmpty {
                    Text(card.contextSentence).foregroundStyle(.secondary)
                }
                Text(learning.speakPrompt).font(.callout)
                HStack {
                    Button("Hear") { Task { await learning.speakReviewPrompt() } }
                    if learning.phase == .recordingReview {
                        Button("Stop") { Task { await learning.stopReviewAndGrade(rating: .good) } }
                            .buttonStyle(.borderedProminent).tint(.red)
                    } else {
                        Button("Record") { Task { await learning.startRecordingForReview() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                HStack {
                    Button("Again") { Task { await learning.stopReviewAndGrade(rating: .again) } }
                    Button("Hard") { Task { await learning.stopReviewAndGrade(rating: .hard) } }
                    Button("Good") { Task { await learning.stopReviewAndGrade(rating: .good) } }
                    Button("Easy") { Task { await learning.stopReviewAndGrade(rating: .easy) } }
                }
            }
            Spacer()
        }
        .padding(32)
    }
}

private struct SummaryDetailView: View {
    @ObservedObject var learning: LearningEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Speak your summary").font(.title2.weight(.semibold))
            Text(learning.speakPrompt).font(.title3)
            if let text = learning.selectedText {
                Text(text.body).font(.callout).foregroundStyle(.secondary)
            }
            if !learning.lastTranscript.isEmpty {
                Text("You said: \(learning.lastTranscript)").font(.title3)
            }
            if let feedback = learning.lastSummaryFeedback {
                VStack(alignment: .leading, spacing: 8) {
                    Text(feedback.verdict == .correct ? "Correct" : "Keep going").font(.headline)
                    Text(feedback.explanation)
                    if !feedback.missingRequiredWords.isEmpty {
                        Text("Missing: \(feedback.missingRequiredWords.joined(separator: ", "))")
                            .foregroundStyle(.orange)
                    }
                    Text(feedback.correction).font(.title3.weight(.semibold))
                }
                .padding()
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 12) {
                switch learning.phase {
                case .recordingSummary:
                    Button("Stop & grade") { Task { await learning.stopSummaryAndGrade() } }
                        .buttonStyle(.borderedProminent).tint(.red)
                case .transcribing, .grading:
                    ProgressView("Grading…")
                case .summaryFeedback:
                    Button("Try again") { learning.retrySummary() }.buttonStyle(.borderedProminent)
                    Button("Hear model") { Task { await learning.speakCorrection() } }
                    Button("Back") { learning.finishToReading() }
                case .completed:
                    Button("Done") { learning.finishToReading() }.buttonStyle(.borderedProminent)
                    Button("Hear model") { Task { await learning.speakCorrection() } }
                default:
                    Button("Record summary") { Task { await learning.startRecordingForSummary() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .padding(32)
    }
}

