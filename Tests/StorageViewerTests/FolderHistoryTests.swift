import StorageViewerCore
import XCTest

final class FolderHistoryTests: XCTestCase {
    func testBackIsDisabledAtTheStart() {
        var history = FolderHistory<String>()
        history.reset(to: "root")
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.back())
        XCTAssertEqual(history.current, "root")
    }

    func testDrillThenBackThenForward() {
        var history = FolderHistory<String>()
        history.reset(to: "root")
        history.push("alpha")
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.back(), "root")
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.forward(), "alpha")
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.current, "alpha")
    }

    func testNewPlaceAfterBackDropsTheForwardTrail() {
        var history = FolderHistory<String>()
        history.reset(to: "root")
        history.push("alpha")
        history.push("beta")
        XCTAssertEqual(history.back(), "alpha")
        history.push("gamma")
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.current, "gamma")
        XCTAssertEqual(history.back(), "alpha")
        XCTAssertEqual(history.back(), "root")
        XCTAssertNil(history.back())
        XCTAssertEqual(history.forward(), "alpha")
        XCTAssertEqual(history.forward(), "gamma")
        XCTAssertNil(history.forward())
    }

    func testRepeatingTheCurrentPlaceDoesNotPush() {
        var history = FolderHistory<String>()
        history.reset(to: "root")
        history.push("root")
        XCTAssertFalse(history.canGoBack)
        history.push("alpha")
        history.push("alpha")
        XCTAssertEqual(history.back(), "root")
        XCTAssertEqual(history.forward(), "alpha")
    }
}
