import Foundation

/// Snapshot of launch readiness observed by `RootView` via `EngineHolder`.
struct SetupSnapshot: Equatable, Sendable {
    var setupFailure: SetupFailure?
    var hasTutor: Bool
    var holderReady: Bool
    var hasLearning: Bool
}

/// Setup failure retained for UI display plus a debug dump of the underlying error.
struct SetupFailure: Equatable, Sendable {
    let message: String
    let debugDescription: String

    init(message: String, debugDescription: String? = nil) {
        self.message = message
        self.debugDescription = debugDescription ?? message
    }

    init(from error: Error) {
        self.message = error.localizedDescription
        self.debugDescription = String(describing: error)
    }
}

/// Pure decision for the launch screen.
///
/// `RootView` observes `EngineHolder` via Observation. Nested `TutorEngine` /
/// `LearningEngine` property changes do **not** re-evaluate `SetupPresentation`
/// unless readiness is mirrored on the holder (`isReady`), set after warmup
/// completes — not `tutor.warmupState == .ready` alone.
enum SetupPresentation: Equatable {
    case checking
    case failed(SetupFailure)
    case warming
    case session

    /// Maps an `EngineHolder` readiness snapshot to the launch screen.
    static func screen(_ snapshot: SetupSnapshot) -> SetupPresentation {
        if let setupFailure = snapshot.setupFailure {
            return .failed(setupFailure)
        }
        guard snapshot.hasTutor else {
            return .checking
        }
        // Intentionally ignores tutor.isWarmupFinished — see type comment.
        if snapshot.holderReady, snapshot.hasLearning {
            return .session
        }
        return .warming
    }
}
