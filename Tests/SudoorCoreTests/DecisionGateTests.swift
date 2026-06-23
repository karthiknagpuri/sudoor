import XCTest
import SudoorCore

final class DecisionGateTests: XCTestCase {
    func testRunOnceExecutesOnce() {
        let gate = DecisionGate()
        var count = 0
        XCTAssertTrue(gate.runOnce { count += 1 })
        XCTAssertFalse(gate.runOnce { count += 1 })
        XCTAssertEqual(count, 1)
    }

    func testClampTimeoutDefaults() {
        XCTAssertEqual(clampTimeout(0), 30)
        XCTAssertEqual(clampTimeout(-5), 30)
        XCTAssertEqual(clampTimeout(.nan), 30)
        XCTAssertEqual(clampTimeout(15), 15)
        XCTAssertEqual(clampTimeout(999), 300)
    }

    func testSafeRunTokenRejectsShellMetacharacters() {
        XCTAssertEqual(safeRunToken("dev"), "dev")
        XCTAssertEqual(safeRunToken("my-script_v2"), "my-script_v2")
        XCTAssertNil(safeRunToken("dev; rm -rf /"))
        XCTAssertNil(safeRunToken("$(whoami)"))
        XCTAssertNil(safeRunToken(""))
    }
}
