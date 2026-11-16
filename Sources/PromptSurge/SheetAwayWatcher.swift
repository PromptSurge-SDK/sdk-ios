import UIKit

/// Measures how long the app was away after the SDK asked iOS for the rating sheet (card 833).
///
/// StoreKit's request has no completion and never says whether a sheet appeared, was rated or
/// was closed. What the app CAN see is its own activity: the system sheet makes the app resign
/// active, and it becomes active again when the sheet is gone. So after a request:
/// - resign active within `resignTimeout` -> wait for become active, report the time between;
/// - no resign within `resignTimeout` -> iOS showed nothing, report 0.
/// Exactly one report per request. Main-queue only, like the rest of the request path.
final class SheetAwayWatcher {
    /// How long to wait for the sheet to take over after the request before calling it "nothing shown".
    static let resignTimeout: TimeInterval = 3

    private let center: NotificationCenter
    private let now: () -> Date
    private let after: (TimeInterval, @escaping () -> Void) -> Void

    private var tokens: [NSObjectProtocol] = []
    private var resignedAt: Date?
    private var report: ((Int) -> Void)?
    /// Bumped per watch, so a timeout left over from an earlier request cannot end a newer one.
    private var generation = 0

    init(
        center: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init,
        after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        }
    ) {
        self.center = center
        self.now = now
        self.after = after
    }

    /// Starts watching for one request. A watch still running is finished first with what it has.
    func watch(report: @escaping (_ awayMs: Int) -> Void) {
        finish(awayMs: 0)
        self.report = report
        resignedAt = nil
        generation += 1
        let mine = generation
        tokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, self.report != nil, self.resignedAt == nil else { return }
            self.resignedAt = self.now()
        })
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, let resignedAt = self.resignedAt else { return }
            let ms = Int((self.now().timeIntervalSince(resignedAt) * 1000).rounded())
            self.finish(awayMs: max(ms, 0))
        })
        after(Self.resignTimeout) { [weak self] in
            guard let self, self.generation == mine, self.report != nil, self.resignedAt == nil else { return }
            self.finish(awayMs: 0)
        }
    }

    private func finish(awayMs: Int) {
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
        resignedAt = nil
        let pending = report
        report = nil
        pending?(awayMs)
    }
}
