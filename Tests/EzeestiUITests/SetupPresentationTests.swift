import XCTest
@testable import EzeestiUI

final class SetupPresentationTests: XCTestCase {
    func testStartsCheckingUntilTutorIsAttached() {
        XCTAssertEqual(
            SetupPresentation.screen(
                SetupSnapshot(
                    setupFailure: nil,
                    hasTutor: false,
                    holderReady: false,
                    hasLearning: false
                )
            ),
            .checking
        )
    }

    func testShowsFailureWhenSetupErrors() {
        let failure = SetupFailure(message: "Model missing", debugDescription: "EzeestiError.modelMissing")
        XCTAssertEqual(
            SetupPresentation.screen(
                SetupSnapshot(
                    setupFailure: failure,
                    hasTutor: false,
                    holderReady: false,
                    hasLearning: false
                )
            ),
            .failed(failure)
        )
        XCTAssertEqual(failure.message, "Model missing")
        XCTAssertEqual(failure.debugDescription, "EzeestiError.modelMissing")
    }

    /// Regression: WarmupView can show "Ready" once TutorEngine publishes
    /// `.ready`, but RootView only observes EngineHolder. Leaving warmup must
    /// wait for `holderReady` (set after warmup returns inside `start`).
    func testTutorWarmupFinishedAloneDoesNotLeaveWarmupScreen() {
        XCTAssertEqual(
            SetupPresentation.screen(
                SetupSnapshot(
                    setupFailure: nil,
                    hasTutor: true,
                    holderReady: false,
                    hasLearning: true
                )
            ),
            .warming,
            "Nested tutor readiness must not drive RootView; use EngineHolder.isReady"
        )
    }

    func testHolderReadyWithLearningEntersSession() {
        XCTAssertEqual(
            SetupPresentation.screen(
                SetupSnapshot(
                    setupFailure: nil,
                    hasTutor: true,
                    holderReady: true,
                    hasLearning: true
                )
            ),
            .session
        )
    }

    func testHolderReadyWithoutLearningStaysWarming() {
        XCTAssertEqual(
            SetupPresentation.screen(
                SetupSnapshot(
                    setupFailure: nil,
                    hasTutor: true,
                    holderReady: true,
                    hasLearning: false
                )
            ),
            .warming
        )
    }
}

@MainActor
final class EngineHolderTests: XCTestCase {
    func testInitialHolderState() {
        let holder = EngineHolder()
        XCTAssertFalse(holder.isReady)
        XCTAssertNil(holder.tutor)
        XCTAssertNil(holder.learning)
        XCTAssertNil(holder.setupFailure)
        XCTAssertEqual(holder.snapshot.hasTutor, false)
        XCTAssertEqual(SetupPresentation.screen(holder.snapshot), .checking)
    }
}
