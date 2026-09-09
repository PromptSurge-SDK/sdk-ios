import XCTest
@testable import PromptSurge

/// Card 349 phase 4 on iOS: the server owns which holdout group a device is in, and the SDK
/// adopts that answer for the NEXT session rather than the current one. Mirrors
/// `DeviceAssignmentTest` on Android.
///
/// THE DEFECT. The device id is SHA-256(vendor id + bundle id) and survives a reinstall on
/// purpose. The coin flip lives in `UserDefaults`, which an uninstall wipes - so a reinstalling
/// device flips again and is counted in both groups under one id. Measured on prod 2026-09-08:
/// 2 of Night Hunt's 276 devices, and 2 of the 25 devices seen in more than one calendar month.
///
/// These tests are written on a machine that cannot build them; they are here so the first run
/// on a Mac checks the behaviour rather than the intent.
final class HoldoutAssignmentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ps.holdout.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTheServersAnswerIsWrittenToDefaults() {
        defaults.set(false, forKey: "ps_holdout")
        let manager = HoldoutManager(defaults: defaults)

        manager.adoptFromServer(true)

        XCTAssertEqual(defaults.object(forKey: "ps_holdout") as? Bool, true)
        XCTAssertTrue(defaults.bool(forKey: "ps_holdout_from_server"))
    }

    func testTheRunningSessionKeepsTheGroupItStartedIn() {
        // The whole reason the adoption is deferred: `isHoldout` decides whether the pre-prompt
        // is shown, and flipping it mid-session would split one session across two experiences.
        defaults.set(false, forKey: "ps_holdout")
        let manager = HoldoutManager(defaults: defaults)
        XCTAssertFalse(manager.isHoldout)

        manager.adoptFromServer(true)

        XCTAssertFalse(manager.isHoldout, "the running session must not change group")
    }

    func testTheNextSessionPicksTheServersGroupUp() {
        defaults.set(false, forKey: "ps_holdout")
        let first = HoldoutManager(defaults: defaults)
        _ = first.isHoldout
        first.adoptFromServer(true)

        let next = HoldoutManager(defaults: defaults)

        XCTAssertTrue(next.isHoldout, "the next session must honour the server")
    }

    func testAReinstalledDeviceIsPutBackInItsFirstGroup() {
        // The defect itself, on this side of the wire. An uninstall clears the defaults; the
        // fresh install flips locally; the server still remembers the holdout assignment against
        // the surviving device id. The session after the first event is back where it belongs.
        let fresh = HoldoutManager(defaults: defaults)
        _ = fresh.isHoldout
        fresh.adoptFromServer(true)

        let afterRestart = HoldoutManager(defaults: defaults)

        XCTAssertTrue(afterRestart.isHoldout)
    }

    func testAFalseAssignmentIsAdoptedToo() {
        // The treatment group is the overwhelming majority, so `false` is the answer the SDK
        // will almost always receive. Ignoring it would leave every reinstalled treatment device
        // on its local flip and close nothing.
        defaults.set(true, forKey: "ps_holdout")
        let manager = HoldoutManager(defaults: defaults)

        manager.adoptFromServer(false)

        XCTAssertEqual(defaults.object(forKey: "ps_holdout") as? Bool, false)
        XCTAssertTrue(defaults.bool(forKey: "ps_holdout_from_server"))
    }

    func testAnUnseenDeviceLeavesNoServerMarker() {
        // A first session on a device the server has never seen still has to work, and it must
        // not leave a marker claiming the server spoke.
        let manager = HoldoutManager(defaults: defaults)

        _ = manager.isHoldout

        XCTAssertFalse(defaults.bool(forKey: "ps_holdout_from_server"))
    }

    // MARK: - The response model

    func testTheResponseModelReadsAnAssignment() throws {
        let json = Data(#"{"accepted":1,"skipped":0,"assignment":{"holdout":true}}"#.utf8)

        let decoded = try JSONDecoder().decode(EventBatchResponse.self, from: json)

        XCTAssertEqual(decoded.assignment?.holdout, true)
        XCTAssertEqual(decoded.accepted, 1)
    }

    func testAnOmittedAssignmentDecodesToNil() throws {
        // The server omits it for a batch carrying two devices, and for a write that failed.
        // Absent must mean "keep what you have", never "you are in the treatment group".
        let json = Data(#"{"accepted":2,"skipped":0}"#.utf8)

        let decoded = try JSONDecoder().decode(EventBatchResponse.self, from: json)

        XCTAssertNil(decoded.assignment)
    }

    func testAFieldTheServerAddsLaterDoesNotBreakDecoding() throws {
        let json = Data(#"{"assignment":{"holdout":true,"source":"ingest"},"newField":7}"#.utf8)

        let decoded = try JSONDecoder().decode(EventBatchResponse.self, from: json)

        XCTAssertEqual(decoded.assignment?.holdout, true)
    }

    func testAnUnparseableBodyIsNotAnAssignment() {
        let json = Data("<html>502 upstream</html>".utf8)

        XCTAssertNil(try? JSONDecoder().decode(EventBatchResponse.self, from: json))
    }
}
