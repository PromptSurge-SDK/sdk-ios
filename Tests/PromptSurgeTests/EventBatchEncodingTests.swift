import XCTest
@testable import PromptSurge

/// The wire contract for the verify token, mirrored from `EventBusTest` on Android.
///
/// The server declares `verifyToken` as `.optional()`, which rejects an explicit `null` -
/// a batch that carries the key with a null value is a 400 for every event in it. So the
/// property must be OMITTED when unset, and Swift's synthesized `Encodable` is trusted to do
/// that via `encodeIfPresent`. These tests are what make that trust checkable: if a future
/// hand-written `encode(to:)` or encoder setting ever starts emitting `"verifyToken":null`,
/// this fails in CI rather than in an integrator's dashboard.
final class EventBatchEncodingTests: XCTestCase {
    private func encode(_ batch: EventBatch) throws -> String {
        let data = try JSONEncoder().encode(batch)
        return String(decoding: data, as: UTF8.self)
    }

    func testVerifyTokenIsOmittedFromTheBatchWhenUnset() throws {
        let json = try encode(EventBatch(events: [], verifyToken: nil))
        XCTAssertFalse(
            json.contains("verifyToken"),
            "batch must not carry a null verifyToken: \(json)"
        )
    }

    func testVerifyTokenRidesAlongWithTheBatchWhenSet() throws {
        let json = try encode(EventBatch(events: [], verifyToken: "vt_abc123"))
        XCTAssertTrue(
            json.contains("\"verifyToken\":\"vt_abc123\""),
            "expected verifyToken in \(json)"
        )
    }
}
