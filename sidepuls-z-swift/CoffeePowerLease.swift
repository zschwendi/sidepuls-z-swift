/// The result of one observation or cleanup step for a Coffee power lease.
///
/// `releasing` is separate from `released`: a successful `disablesleep 0`
/// command still needs a later readback that reports `false` before the lease
/// gives up ownership.
enum CoffeePowerLeaseEvent: Equatable, Sendable {
    case externalProtection
    case awaitingState
    case applying
    case protected
    case failed
    case releasing
    case released
    case releaseFailed
    case idle
}

/// A small, side-effect-free state machine for Coffee's `SleepDisabled` bit.
///
/// The bit is global and macOS does not identify which process owns it.  The
/// lease therefore uses a baseline rule: it may claim ownership only after it
/// observes `false` and its own `setDisabled(true)` command succeeds.  A
/// concurrent application changing the same global setting cannot be
/// distinguished from an external change after that point.  `priorSleepDisabled`
/// is intentionally a non-optional `false`; this lease never restores an
/// already-disabled external baseline to `true`.
struct CoffeePowerLease: Sendable {
    private enum Phase: Sendable {
        case idle
        case applying
        case protected
        case failed
        case releasing
        case releaseFailed
    }

    /// True after Coffee successfully issued `disablesleep 1`, until a later
    /// cleanup readback proves that the bit is false.
    private(set) var ownsSleepDisable = false

    /// Coffee only acquires from a known false baseline and therefore never
    /// stores or restores a true prior value.
    private(set) var priorSleepDisabled = false

    /// True after a release command succeeds but before false is observed.
    private(set) var releasing = false

    private var phase: Phase = .idle
    private var pendingReadbacks = 0

    var isReleasing: Bool { releasing }

    init() {}

    /// Observe the current `SleepDisabled` value and, when safe, apply Coffee's
    /// setting.  A successful write reports `.applying`; only a later observed
    /// `true` reports `.protected`.
    mutating func observe(
        sleepDisabled: Bool?,
        setDisabled: (Bool) -> Bool
    ) -> CoffeePowerLeaseEvent {
        guard let sleepDisabled else {
            return .awaitingState
        }

        if sleepDisabled {
            if ownsSleepDisable {
                phase = .protected
                pendingReadbacks = 0
                releasing = false
                return .protected
            }

            phase = .idle
            releasing = false
            return .externalProtection
        }

        // A successful enable command is already in flight from the previous
        // observation.  Do not issue duplicate writes while its readback is
        // still false or unavailable to the caller.
        if ownsSleepDisable, phase == .applying {
            pendingReadbacks += 1
            if pendingReadbacks >= 8 { phase = .failed; return .failed }
            return .applying
        }
        if ownsSleepDisable, phase == .failed { return .failed }

        let commandSucceeded = setDisabled(true)
        guard commandSucceeded else {
            if ownsSleepDisable {
                phase = .failed
                releasing = false
            } else {
                phase = .failed
                priorSleepDisabled = false
            }
            return .failed
        }

        ownsSleepDisable = true
        priorSleepDisabled = false
        phase = .applying
        pendingReadbacks = 0
        releasing = false
        return .applying
    }

    /// Release only a lease owned by this state machine.
    ///
    /// A missing readback is left unresolved without a write.  When the bit is
    /// still true, `setDisabled(false)` may be retried by the caller at its
    /// normal bounded cadence.  Ownership is cleared only after observing
    /// `false`.
    mutating func cleanup(
        current: Bool?,
        setDisabled: (Bool) -> Bool
    ) -> CoffeePowerLeaseEvent {
        guard ownsSleepDisable else {
            return .idle
        }

        guard let current else {
            return .awaitingState
        }

        // A successful preference write can precede the registry update. If
        // Coffee is stopped during that interval, undo the pending preference
        // even though the registry still reads false.
        if !current && (phase == .applying || phase == .failed) {
            guard setDisabled(false) else { phase = .releaseFailed; return .releaseFailed }
            phase = .releasing
            releasing = true
            return .releasing
        }

        guard current else {
            ownsSleepDisable = false
            priorSleepDisabled = false
            releasing = false
            phase = .idle
            pendingReadbacks = 0
            return .released
        }

        guard setDisabled(false) else {
            phase = .releaseFailed
            releasing = false
            return .releaseFailed
        }

        // The command may have succeeded without changing the setting.  Keep
        // ownership until a subsequent cleanup call observes false.
        phase = .releasing
        releasing = true
        return .releasing
    }
}
