import XCTest
import Combine
@testable import EzeestiUI

final class SetupPresentationTests: XCTestCase {
    func testStartsCheckingUntilTutorIsAttached() {
        XCTAssertEqual(
            SetupPresentation.screen(
                setupError: nil,
                hasTutor: false,
                holderReady: false,
                hasLearning: false
            ),
            .checking
        )
    }

    func testShowsFailureWhenSetupErrors() {
        XCTAssertEqual(
            SetupPresentation.screen(
                setupError: "Model missing",
                hasTutor: false,
                holderReady: false,
                hasLearning: false
            ),
            .failed("Model missing")
        )
    }

    /// Regression: WarmupView can show "Ready" once TutorEngine publishes
    /// `.ready`, but RootView only observes EngineHolder. Leaving warmup must
    /// wait for `holderReady` (set via `markReady()` after warmup returns).
    func testTutorWarmupFinishedAloneDoesNotLeaveWarmupScreen() {
        XCTAssertEqual(
            SetupPresentation.screen(
                setupError: nil,
                hasTutor: true,
                holderReady: false,
                hasLearning: true
            ),
            .warming,
            "Nested tutor readiness must not drive RootView; use EngineHolder.isReady"
        )
    }

    func testHolderReadyWithLearningEntersSession() {
        XCTAssertEqual(
            SetupPresentation.screen(
                setupError: nil,
                hasTutor: true,
                holderReady: true,
                hasLearning: true
            ),
            .session
        )
    }

    func testHolderReadyWithoutLearningStaysWarming() {
        XCTAssertEqual(
            SetupPresentation.screen(
                setupError: nil,
                hasTutor: true,
                holderReady: true,
                hasLearning: false
            ),
            .warming
        )
    }
}

@MainActor
final class EngineHolderTests: XCTestCase {
    func testMarkReadyPublishesOnHolder() {
        let holder = EngineHolder()
        XCTAssertFalse(holder.isReady)

        var didPublish = false
        let observation = holder.objectWillChange.sink { _ in
            didPublish = true
        }

        holder.markReady()

        XCTAssertTrue(holder.isReady)
        XCTAssertTrue(didPublish, "RootView must see objectWillChange from the holder")
        _ = observation
    }
}
