#if canImport(UIKit)
import UIKit
import XCTest
@testable import PromptSurge

/// Card 615: the App Store shows the rating sheet at most three times in 365 days per app per
/// device, and says nothing when it declines. Both stores warn against a button that leads to the
/// review API for that reason: the tap can be answered by nothing. So the SDK records every native
/// request it makes and, once it has made three inside 365 days, shows no pre-prompt and makes no
/// native call until the oldest of them is a year old.
///
/// The holdout and warm-up paths ask iOS directly and are held to the same rule, so both arms of
/// the experiment skip under the same condition.
///
/// Written on a machine that cannot build them, like the rest of this target; CI runs them with
/// `gh workflow run ios-build.yml --ref <branch>`.
final class ReviewQuotaTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// The test clock. Every `RateLimiter` built here reads it, so time moves when a test says so.
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    /// How often the SDK asked "iOS" (the stubbed `nativeReviewRequest`).
    private var systemRequests = 0

    private let day: TimeInterval = 24 * 3600

    override func setUp() {
        super.setUp()
        suiteName = "ps.quota.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        systemRequests = 0
        StubURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeLimiter() -> RateLimiter {
        RateLimiter(defaults: defaults, now: { [unowned self] in self.clock })
    }

    // MARK: - The rule itself

    func testTheRuleIsAppleSThreeIn365Days() {
        XCTAssertEqual(ReviewQuota.appStore.limit, 3)
        XCTAssertEqual(ReviewQuota.appStore.window, 365 * day)
    }

    func testUnderTheLimitNothingIsBlocked() {
        let now = clock.timeIntervalSince1970
        let next = ReviewQuota.appStore.nextPossibleRequest(requests: [now - 10 * day, now - 5 * day], now: now)

        XCTAssertNil(next)
    }

    func testAtTheLimitTheBlockLastsUntilTheOldestIsAYearOld() {
        let now = clock.timeIntervalSince1970
        let oldest = now - 100 * day
        let next = ReviewQuota.appStore.nextPossibleRequest(requests: [now - 1 * day, oldest, now - 50 * day], now: now)

        XCTAssertEqual(next, oldest + 365 * day, "the input order must not matter")
    }

    func testARequestOlderThan365DaysNoLongerCounts() {
        let now = clock.timeIntervalSince1970
        let next = ReviewQuota.appStore.nextPossibleRequest(requests: [now - 366 * day, now - 200 * day, now - 1 * day], now: now)

        XCTAssertNil(next)
    }

    func testWithFourRecentRequestsTheSecondOldestHasToAgeOut() {
        // Four inside the window (possible when a host app's own calls are not the SDK's, or a
        // clock moved): the count only drops to two once the SECOND oldest is a year old.
        let now = clock.timeIntervalSince1970
        let next = ReviewQuota.appStore.nextPossibleRequest(
            requests: [now - 300 * day, now - 200 * day, now - 100 * day, now - 1 * day],
            now: now
        )

        XCTAssertEqual(next, now - 200 * day + 365 * day)
    }

    // MARK: - RateLimiter, on its own defaults and clock

    func testTwoRecordedRequestsLeaveTheQuotaOpen() {
        let limiter = makeLimiter()
        limiter.recordNativeRequest()
        clock += 30 * day
        limiter.recordNativeRequest()

        XCTAssertNil(limiter.quotaBlockedUntil)
    }

    func testTheThirdRecordedRequestClosesIt() {
        let limiter = makeLimiter()
        let first = clock
        limiter.recordNativeRequest()
        clock += 90 * day
        limiter.recordNativeRequest()
        clock += 90 * day
        limiter.recordNativeRequest()

        XCTAssertEqual(limiter.quotaBlockedUntil, first.addingTimeInterval(365 * day))
    }

    func testTheQuotaReopensWhenTheOldestRequestTurnsAYearOld() {
        let limiter = makeLimiter()
        let first = clock
        limiter.recordNativeRequest()
        clock += 90 * day
        limiter.recordNativeRequest()
        clock += 90 * day
        limiter.recordNativeRequest()

        clock = first.addingTimeInterval(365 * day - 1)
        XCTAssertNotNil(limiter.quotaBlockedUntil, "one second short of a year is still inside the window")

        clock = first.addingTimeInterval(365 * day)
        XCTAssertNil(limiter.quotaBlockedUntil)
    }

    func testOnlyTheLastFewRequestsAreKept() {
        let limiter = makeLimiter()
        for _ in 0..<8 {
            limiter.recordNativeRequest()
            clock += 1 * day
        }

        XCTAssertEqual(limiter.nativeRequests.count, RateLimiter.maxStoredRequests)
        XCTAssertEqual(limiter.nativeRequests.last, clock.timeIntervalSince1970 - 1 * day, "the newest entry survives the cap")
        XCTAssertNotNil(defaults.array(forKey: RateLimiter.nativeRequestsKey), "stored next to the cooldown keys")
    }

    func testRecordingARequestDoesNotStartTheCooldown() {
        // The two are separate gates: fireNativeReview decides about the cooldown itself.
        let limiter = makeLimiter()
        limiter.recordNativeRequest()

        XCTAssertTrue(limiter.canShow)
    }

    // MARK: - The paths that reach StoreKit

    private func makeSDK(holdout: Bool, limiter: RateLimiter) -> PromptSurge {
        defaults.set(holdout, forKey: "ps_holdout")
        let holdoutManager = HoldoutManager(defaults: defaults)
        let base = "https://stub.promptsurge.test"
        let session = StubURLProtocol.session()
        let sessionId = UUID().uuidString
        let sdk = PromptSurge(
            repository: PromptTextRepository(
                apiKey: "ps_live_test", apiBaseUrl: base, sessionId: sessionId,
                defaults: defaults, session: session
            ),
            telemetry: Telemetry(
                apiKey: "ps_live_test", apiBaseUrl: base, sessionId: sessionId,
                holdoutManager: holdoutManager, defaults: defaults, session: session
            ),
            rateLimiter: limiter,
            holdoutManager: holdoutManager
        )
        sdk.nativeReviewRequest = { [unowned self] _ in
            self.systemRequests += 1
            return true
        }
        return sdk
    }

    /// Spins the main run loop until `condition` holds, for the paths that fetch first.
    private func spin(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testAHoldoutDeviceRecordsItsNativeRequest() {
        let limiter = makeLimiter()
        let sdk = makeSDK(holdout: true, limiter: limiter)

        sdk.showDialog(from: UIViewController())

        XCTAssertEqual(systemRequests, 1, "a holdout device asks iOS directly")
        XCTAssertEqual(limiter.nativeRequests.count, 1, "and that request is on the quota record")
        XCTAssertEqual(StubURLProtocol.promptRequests, 0, "a holdout device never fetches a prompt")
    }

    func testAHoldoutDeviceAtTheQuotaMakesNoNativeCall() {
        // The control arm skips under the same rule as the treatment arm. iOS would have shown
        // nothing for a fourth request, so the native-only arm must not be credited with one.
        let limiter = makeLimiter()
        for _ in 0..<3 {
            limiter.recordNativeRequest()
            clock += 1 * day
        }
        let sdk = makeSDK(holdout: true, limiter: limiter)

        sdk.showDialog(from: UIViewController())

        XCTAssertEqual(systemRequests, 0)
        XCTAssertEqual(limiter.nativeRequests.count, 3, "a skipped call is not a request")
    }

    func testAWarmUpResponseRecordsItsNativeRequest() {
        StubURLProtocol.promptBody = Data(
            #"{"locale":"en","title":"A quick favor","body":"A short review helps other people discover apps like this.","ctaConfirm":"Sure","ctaDismiss":"Not now","warmup":true}"#.utf8
        )
        let limiter = makeLimiter()
        let sdk = makeSDK(holdout: false, limiter: limiter)
        let asked = expectation(description: "the warm-up path asks iOS")
        sdk.nativeReviewRequest = { _ in
            asked.fulfill()
            return true
        }

        sdk.showDialog(from: UIViewController())
        wait(for: [asked], timeout: 5)

        XCTAssertEqual(limiter.nativeRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.promptRequests, 1)
    }

    func testATreatmentDeviceUnderTheLimitGoesOnToItsPrompt() {
        StubURLProtocol.promptBody = Data(
            #"{"locale":"en","title":"A quick favor","body":"A short review helps other people discover apps like this.","ctaConfirm":"Sure","ctaDismiss":"Not now"}"#.utf8
        )
        let limiter = makeLimiter()
        limiter.recordNativeRequest()
        limiter.recordNativeRequest()
        let sdk = makeSDK(holdout: false, limiter: limiter)

        sdk.showDialog(from: UIViewController())

        XCTAssertTrue(spin { StubURLProtocol.promptRequests == 1 }, "two requests in a year leave room for the dialog")
        XCTAssertEqual(systemRequests, 0, "a treatment device reaches iOS only through the dialog")
    }

    func testATreatmentDeviceAtTheLimitIsNotShownAPrePrompt() {
        let limiter = makeLimiter()
        for _ in 0..<3 {
            limiter.recordNativeRequest()
            clock += 1 * day
        }
        let sdk = makeSDK(holdout: false, limiter: limiter)

        sdk.showDialog(from: UIViewController())
        // Nothing is asynchronous on this path, but give a stray fetch the chance to show itself.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(StubURLProtocol.promptRequests, 0, "no prompt fetched, so no dialog can appear")
        XCTAssertEqual(systemRequests, 0)
    }
}

/// Answers the SDK's two endpoints without a network: `/v1/prompts` with `promptBody`, and
/// `/v1/events` with an accepted batch.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedBody = Data()
    private static var storedPromptRequests = 0

    static var promptBody: Data {
        get { lock.lock(); defer { lock.unlock() }; return storedBody }
        set { lock.lock(); storedBody = newValue; lock.unlock() }
    }

    static var promptRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return storedPromptRequests
    }

    static func reset() {
        lock.lock()
        storedBody = Data()
        storedPromptRequests = 0
        lock.unlock()
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: Data
        if url.path.hasSuffix("/v1/prompts") {
            StubURLProtocol.lock.lock()
            StubURLProtocol.storedPromptRequests += 1
            body = StubURLProtocol.storedBody
            StubURLProtocol.lock.unlock()
        } else {
            body = Data(#"{"accepted":1,"skipped":0}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
