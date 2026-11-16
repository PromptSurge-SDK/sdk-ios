import XCTest
import UIKit
@testable import PromptSurge

/// Card 833: "announce only" and the time-away measurement after a rating-sheet request.
final class NoticeModeTests: XCTestCase {

    // MARK: - Wire and cache

    private func api(mode: String?) throws -> APIPromptResponse {
        var json = #"{"locale":"de","title":"T","body":"B","ctaConfirm":"Weiter","ctaDismiss":"x""#
        if let mode { json += #","mode":"\#(mode)""# }
        json += "}"
        return try JSONDecoder().decode(APIPromptResponse.self, from: Data(json.utf8))
    }

    func testModeNoticeMapsToTheNotice() throws {
        XCTAssertTrue(mapAPIResponse(try api(mode: "notice")).isNotice)
        XCTAssertFalse(mapAPIResponse(try api(mode: "ask")).isNotice)
        XCTAssertFalse(mapAPIResponse(try api(mode: nil)).isNotice, "older servers omit mode: that is the ask")
    }

    func testACacheWrittenBy130StillDecodes() throws {
        // 1.3.0 wrote PromptResponse without `notice`. Failing to decode it would throw away
        // every warm cache on update.
        let old = #"{"text":{"title":"T","body":"B","positiveButton":"P","negativeButton":"N","locale":"en"},"warmup":false}"#
        let decoded = try JSONDecoder().decode(PromptResponse.self, from: Data(old.utf8))
        XCTAssertFalse(decoded.isNotice)
    }

    func testTheNoticeSurvivesTheCacheRoundTrip() throws {
        let response = mapAPIResponse(try api(mode: "notice"))
        let data = try JSONEncoder().encode(response)
        XCTAssertTrue(try JSONDecoder().decode(PromptResponse.self, from: data).isNotice)
    }

    func testSheetClosedPayloadCarriesAwayMsAndSource() throws {
        var payload = EventPayload(promptId: "p1", resolvedLocale: "de", servedPromptNumber: nil)
        payload.awayMs = 4210
        payload.source = "notice"
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertTrue(json.contains(#""awayMs":4210"#), json)
        XCTAssertTrue(json.contains(#""source":"notice""#), json)
        let plain = String(decoding: try JSONEncoder().encode(EventPayload()), as: UTF8.self)
        XCTAssertFalse(plain.contains("awayMs"), "other events must not carry a null awayMs: \(plain)")
    }

    // MARK: - Time away

    private final class Harness {
        let center = NotificationCenter()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var timers: [() -> Void] = []
        var reports: [Int] = []
        lazy var watcher = SheetAwayWatcher(
            center: center,
            now: { [unowned self] in self.now },
            after: { [unowned self] _, block in self.timers.append(block) }
        )
        func start() { watcher.watch { [unowned self] in self.reports.append($0) } }
        func post(_ name: Notification.Name) { center.post(name: name, object: nil) }
    }

    func testTheSheetOnScreenIsTimedFromResignToActive() {
        let h = Harness()
        h.start()
        h.now += 0.2
        h.post(UIApplication.willResignActiveNotification)
        h.now += 4.5
        h.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(h.reports, [4500])
        h.timers.forEach { $0() } // the timeout firing later must not report again
        XCTAssertEqual(h.reports, [4500])
    }

    func testNoResignBeforeTheTimeoutMeansNothingWasShown() {
        let h = Harness()
        h.start()
        h.timers.forEach { $0() }
        XCTAssertEqual(h.reports, [0])
        h.post(UIApplication.willResignActiveNotification)
        h.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(h.reports, [0], "a later trip to the background is not the sheet")
    }

    func testANewRequestClosesTheOpenWatchFirst() {
        let h = Harness()
        h.start()
        h.start()
        XCTAssertEqual(h.reports, [0])
        h.timers[0]() // the first request's timeout must not end the second watch
        XCTAssertEqual(h.reports, [0])
        h.post(UIApplication.willResignActiveNotification)
        h.now += 2
        h.post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(h.reports, [0, 2000])
    }

    // MARK: - Dialog

    func testTheNoticeDrawsOneButton() {
        let text = PromptText(title: "T", body: "B", positiveButton: "Weiter", negativeButton: "Nicht jetzt", locale: "de")
        let notice = PromptResponse(promptId: nil, appPromptNumber: nil, text: text, theme: nil, imageUrl: nil, warmup: false, notice: true)
        let ask = PromptResponse(promptId: nil, appPromptNumber: nil, text: text, theme: nil, imageUrl: nil, warmup: false)
        XCTAssertEqual(buttonTitles(notice), ["Weiter"])
        XCTAssertEqual(buttonTitles(ask), ["Nicht jetzt", "Weiter"])
    }

    private func buttonTitles(_ response: PromptResponse) -> [String] {
        let vc = PrePromptViewController(promptResponse: response, onAccept: {}, onDismiss: {})
        vc.loadViewIfNeeded()
        var titles: [String] = []
        func walk(_ v: UIView) {
            if let stack = v as? UIStackView, stack.axis == .horizontal {
                titles += stack.arrangedSubviews.compactMap { ($0 as? UIButton)?.title(for: .normal) }
            }
            v.subviews.forEach(walk)
        }
        walk(vc.view)
        return titles
    }
}
