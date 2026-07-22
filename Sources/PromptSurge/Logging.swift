import Foundation
import os.log

/// Diagnostic verbosity for the PromptSurge SDK.
///
/// Errors and warnings are emitted regardless of this setting — a rejected API key or a
/// suppressed dialog must never be silent. This only controls the informational output.
public enum PromptSurgeLogLevel: Int, Comparable {
    /// Errors and warnings only (the default).
    case quiet = 0
    /// Adds one line per lifecycle decision: fetch outcome, why a dialog was suppressed.
    case info = 1
    /// Adds per-event delivery results. Useful while wiring the SDK up, noisy in production.
    case debug = 2

    public static func < (lhs: PromptSurgeLogLevel, rhs: PromptSurgeLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// SDK-internal logger.
///
/// Everything goes to the unified log under subsystem `com.promptsurge.sdk`, so an
/// integrator can filter for it in Console.app or with
/// `log stream --predicate 'subsystem == "com.promptsurge.sdk"'`.
enum PSLog {
    private static let osLog = OSLog(subsystem: "com.promptsurge.sdk", category: "PromptSurge")

    /// Informational verbosity. Set via `PromptSurge.setLogLevel(_:)`.
    static var level: PromptSurgeLogLevel = .quiet

    static func error(_ message: @autoclosure () -> String) {
        emit(message(), type: .error)
    }

    static func warning(_ message: @autoclosure () -> String) {
        emit(message(), type: .default)
    }

    static func info(_ message: @autoclosure () -> String) {
        guard level >= .info else { return }
        emit(message(), type: .info)
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard level >= .debug else { return }
        emit(message(), type: .debug)
    }

    private static func emit(_ message: String, type: OSLogType) {
        os_log("%{public}@", log: osLog, type: type, "[PromptSurge] " + message)
    }
}
