import SwiftUI
import EzeestiCore
import EzeestiTutor

public struct RootView: View {
    @StateObject private var engine = TutorEngine()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { engine.selectedPack?.id },
                set: { id in
                    if let pack = engine.packs.first(where: { $0.id == id }) {
                        engine.selectPack(pack)
                    }
                }
            )) {
                Section("Lessons") {
                    ForEach(engine.packs) { pack in
                        NavigationLink(value: pack.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pack.title)
                                    .font(.headline)
                                Text("\(pack.cefr.rawValue) · \(pack.items.count) sentences")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(pack.id)
                    }
                }

                Section("Models") {
                    Label(
                        engine.useMockASR ? "ASR: mock (run fetch-models.sh)" : "ASR: TalTech Whisper",
                        systemImage: engine.useMockASR ? "exclamationmark.triangle" : "waveform"
                    )
                    Label(
                        engine.useRuleTutor ? "Tutor: rules (run fetch-models.sh)" : "Tutor: EstLLM",
                        systemImage: engine.useRuleTutor ? "exclamationmark.triangle" : "brain"
                    )
                }
            }
            .navigationTitle("ezeesti")
            .frame(minWidth: 240)
        } detail: {
            if engine.selectedPack != nil {
                PracticeView(engine: engine)
            } else {
                ContentUnavailableView(
                    "Choose a lesson",
                    systemImage: "character.book.closed",
                    description: Text("Pick an A1–A2 pattern on the left.")
                )
            }
        }
        .onAppear { engine.loadLessons() }
    }
}

public struct PracticeView: View {
    @ObservedObject var engine: TutorEngine

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let pack = engine.selectedPack, let item = engine.currentItem {
                header(pack: pack, item: item)
                tipCard(pack: pack, item: item)
                transcriptAndFeedback
                controls
                Spacer()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func header(pack: LessonPack, item: LessonItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pack.title)
                .font(.title2.weight(.semibold))
            Text("Sentence \(engine.itemIndex + 1) of \(pack.items.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(item.targetEstonian)
                .font(.largeTitle.weight(.bold))
                .textSelection(.enabled)
            Text(item.glossEnglish)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tipCard(pack: LessonPack, item: LessonItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(item.focusTip ?? pack.focusTip)
                .font(.body)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var transcriptAndFeedback: some View {
        if !engine.lastTranscript.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("You said")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(engine.lastTranscript)
                    .font(.title3)
            }
        }

        if let feedback = engine.lastFeedback {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verdictLabel(feedback.verdict))
                        .font(.headline)
                    Spacer()
                }
                Text(feedback.explanation)
                Text("Try: \(feedback.correction)")
                    .font(.title3.weight(.semibold))
                Text(feedback.retryPrompt)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(feedbackBackground(feedback.verdict), in: RoundedRectangle(cornerRadius: 12))
        }

        if case .error(let message) = engine.phase {
            Text(message)
                .foregroundStyle(.red)
        } else if engine.phase != .idle && engine.phase != .feedback && engine.phase != .completedItem && engine.phase != .recording {
            ProgressView(statusText)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            if engine.phase == .recording {
                Button("Stop & check") {
                    Task { await engine.stopAndEvaluate() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if engine.phase == .completedItem {
                Button("Next sentence") {
                    engine.advanceToNextItem()
                }
                .buttonStyle(.borderedProminent)
                Button("Practice again") {
                    engine.retryCurrent()
                }
            } else if engine.phase == .feedback {
                Button("Try again") {
                    engine.retryCurrent()
                }
                .buttonStyle(.borderedProminent)
                Button("Skip") {
                    engine.advanceToNextItem()
                }
            } else if engine.phase == .idle || isError {
                Button("Record") {
                    Task { await engine.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                Button("Hear target") {
                    Task { await engine.speakTarget() }
                }
            }
        }
    }

    private var isError: Bool {
        if case .error = engine.phase { return true }
        return false
    }

    private var statusText: String {
        switch engine.phase {
        case .transcribing: return "Transcribing…"
        case .tutoring: return "Checking grammar…"
        case .speaking: return "Playing correction…"
        default: return "Working…"
        }
    }

    private func verdictLabel(_ verdict: TutorVerdict) -> String {
        switch verdict {
        case .correct: return "Correct"
        case .close: return "Close"
        case .incorrect: return "Not quite"
        }
    }

    private func feedbackBackground(_ verdict: TutorVerdict) -> Color {
        switch verdict {
        case .correct: return Color.green.opacity(0.15)
        case .close: return Color.orange.opacity(0.15)
        case .incorrect: return Color.red.opacity(0.12)
        }
    }
}
