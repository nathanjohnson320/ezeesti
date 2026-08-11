import Foundation

/// Pure decision for the launch screen.
///
/// RootView observes only `EngineHolder`. Nested `TutorEngine` / `LearningEngine`
/// `@Published` changes do **not** re-render that parent, so readiness must be a
/// flag on the holder itself (`isReady`), set after warmup completes — not
/// `tutor.isWarmupFinished` alone.
enum SetupPresentation: Equatable {
    case checking
    case failed(String)
    case warming
    case session

    static func screen(
        setupError: String?,
        hasTutor: Bool,
        holderReady: Bool,
        hasLearning: Bool
    ) -> SetupPresentation {
        if let setupError {
            return .failed(setupError)
        }
        guard hasTutor else {
            return .checking
        }
        // Intentionally ignores tutor.isWarmupFinished — see type comment.
        if holderReady, hasLearning {
            return .session
        }
        return .warming
    }
}
