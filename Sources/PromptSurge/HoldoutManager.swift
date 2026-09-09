import Foundation

/// Which A/B group this device is in: the holdout group never sees a pre-prompt, so its native
/// review rate is the baseline the dashboard compares against.
///
/// Card 349 phase 4: THE SERVER IS THE AUTHORITY FROM THE SECOND SESSION ONWARDS.
/// `UserDefaults` does not survive an uninstall but the device id (SHA-256 of vendor id +
/// bundle id) does, so a local-only coin flip re-rolls a reinstalling device into a new group
/// and counts one device in both. `POST /v1/events` answers with the group the server remembers
/// against that device id, and `adoptFromServer(_:)` persists that answer over the local flip.
///
/// The answer applies to the NEXT session, never this one - see `isHoldout`. Mirrors Android's
/// `Telemetry` holdout block and Unity's `HoldoutManager`.
final class HoldoutManager {
    private static let prefsKey = "ps_holdout"

    /// Written the first time the server answers with an assignment, and never cleared. The SDK
    /// does not read it: it exists so a support session looking at a device's defaults can tell
    /// a locally flipped coin from the server's memory. Mirrors Android's `holdout_from_server`.
    private static let fromServerKey = "ps_holdout_from_server"

    private let defaults: UserDefaults

    /// Fixed for the life of this instance, on purpose. The server's answer arrives on an event
    /// response, which can land at any moment; adopting it in place would let one session show
    /// the pre-prompt before that response and skip it afterwards, and the events either side
    /// would describe two different experiences under one session id. Caching costs one session
    /// of staleness and keeps every session internally coherent.
    private var cached: Bool?
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // Returns the same answer for the life of this instance; 10% of devices are in holdout.
    var isHoldout: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        if let stored = defaults.object(forKey: Self.prefsKey) as? Bool {
            cached = stored
            return stored
        }
        let assigned = Double.random(in: 0..<1) < 0.10
        defaults.set(assigned, forKey: Self.prefsKey)
        cached = assigned
        return assigned
    }

    /// Persists the group the SERVER remembers for this device. Deliberately does not touch
    /// `cached`: the running session keeps the group it was served under, and the next launch
    /// reads this value from `UserDefaults`.
    ///
    /// Writes only on a change, so a stable device stops touching the defaults after the first
    /// answer.
    func adoptFromServer(_ holdout: Bool) {
        let alreadyFromServer = defaults.bool(forKey: Self.fromServerKey)
        let stored = defaults.object(forKey: Self.prefsKey) as? Bool
        if alreadyFromServer, stored == holdout {
            return
        }
        defaults.set(holdout, forKey: Self.prefsKey)
        defaults.set(true, forKey: Self.fromServerKey)
        PSLog.debug("Holdout group adopted from server: \(holdout) (applies next session).")
    }
}
