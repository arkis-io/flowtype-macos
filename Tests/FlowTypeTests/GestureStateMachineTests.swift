import XCTest
@testable import FlowType

final class GestureStateMachineTests: XCTestCase {
    private let config = AppConfig.defaultConfig.gestures

    private var legacyConfig: GestureConfig {
        var value = config
        value.hybridPrimaryHotkey = false
        return value
    }

    func testHeldPressStartsThenStopsOnRelease() {
        var machine = GestureStateMachine()

        XCTAssertEqual(
            machine.handle(.hotkeyDown(at: 10), config: config),
            [.startRecording, .showHeldMode]
        )
        XCTAssertEqual(
            machine.handle(.hotkeyUp(at: 11), config: config),
            [.stopAndProcess]
        )
        XCTAssertEqual(machine.phase, .processing)
    }

    func testQuickTapKeepsSameRecordingRunningHandsFree() {
        var machine = GestureStateMachine()

        _ = machine.handle(.hotkeyDown(at: 10), config: config)
        XCTAssertEqual(
            machine.handle(.hotkeyUp(at: 10.1), config: config),
            [.showHandsFreeMode]
        )
        XCTAssertEqual(machine.phase, .handsFree(startedAt: 10))

        XCTAssertEqual(machine.handle(.hotkeyDown(at: 12), config: config), [.stopAndProcess])
        XCTAssertEqual(machine.phase, .processing)
    }

    func testLegacyDoubleTapStillConvertsSameRecordingToHandsFree() {
        var machine = GestureStateMachine()
        let config = legacyConfig

        _ = machine.handle(.hotkeyDown(at: 10), config: config)
        XCTAssertEqual(
            machine.handle(.hotkeyUp(at: 10.1), config: config),
            [.scheduleDoubleTapExpiry(after: config.doubleTapInterval)]
        )
        XCTAssertEqual(
            machine.handle(.hotkeyDown(at: 10.2), config: config),
            [.cancelDoubleTapExpiry, .showHandsFreeMode]
        )
        XCTAssertEqual(machine.handle(.hotkeyUp(at: 10.25), config: config), [])
    }

    func testDedicatedToggleStartsAndStopsHandsFree() {
        var machine = GestureStateMachine()
        let config = legacyConfig

        XCTAssertEqual(
            machine.handle(.toggleHotkeyDown(at: 10), config: config),
            [.startRecording, .showHandsFreeMode]
        )
        XCTAssertEqual(machine.phase, .handsFree(startedAt: 10))
        XCTAssertEqual(
            machine.handle(.toggleHotkeyDown(at: 12), config: config),
            [.stopAndProcess]
        )
        XCTAssertEqual(machine.phase, .processing)
    }

    func testQuickSingleTapStopsAfterDoubleTapWindow() {
        var machine = GestureStateMachine()
        let config = legacyConfig

        _ = machine.handle(.hotkeyDown(at: 1), config: config)
        _ = machine.handle(.hotkeyUp(at: 1.1), config: config)

        XCTAssertEqual(machine.handle(.doubleTapWindowExpired(at: 1.2), config: config), [])
        XCTAssertEqual(
            machine.handle(.doubleTapWindowExpired(at: 1.42), config: config),
            [.stopAndProcess]
        )
    }

    func testEscapeCancelsRecordingAndProcessing() {
        var machine = GestureStateMachine()

        _ = machine.handle(.hotkeyDown(at: 1), config: config)
        XCTAssertEqual(
            machine.handle(.escape, config: config),
            [.cancelDoubleTapExpiry, .cancel, .hide]
        )
        XCTAssertEqual(machine.phase, .idle)

        _ = machine.handle(.hotkeyDown(at: 2), config: config)
        _ = machine.handle(.hotkeyUp(at: 3), config: config)
        XCTAssertEqual(machine.phase, .processing)
        XCTAssertEqual(
            machine.handle(.escape, config: config),
            [.cancelDoubleTapExpiry, .cancel, .hide]
        )
        XCTAssertEqual(machine.phase, .idle)
    }

    func testAutoStopWorksInHandsFreeMode() {
        var machine = GestureStateMachine()

        _ = machine.handle(.hotkeyDown(at: 1), config: config)
        _ = machine.handle(.hotkeyUp(at: 1.1), config: config)

        XCTAssertEqual(
            machine.handle(.autoStop, config: config),
            [.cancelDoubleTapExpiry, .stopAndProcess]
        )
        XCTAssertEqual(machine.phase, .processing)
    }
}
