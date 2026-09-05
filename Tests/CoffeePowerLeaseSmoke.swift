@main
struct CoffeePowerLeaseSmoke {
    static func main() {
        testPreviousExternalTrueToFalseHandoff()
        testFailedVerifyAndNullReadback()
        testOffCleanupRetry()
        testPassiveExternalBaseline()
        testDuplicateWritesAvoided()
        testReacquireAfterForeignClear()
        testStopBeforeRegistryCatchesUp()
        testVerificationCannotWaitForever()
        print("CoffeePowerLeaseSmoke: PASS")
    }

    private static func testPreviousExternalTrueToFalseHandoff() {
        var lease = CoffeePowerLease()
        var writes: [Bool] = []

        expect(
            lease.observe(sleepDisabled: true) { writes.append($0); return true } == .externalProtection,
            "an already-disabled baseline is external protection"
        )
        expect(writes.isEmpty && !lease.ownsSleepDisable, "external protection must not be written or claimed")

        expect(
            lease.observe(sleepDisabled: false) { writes.append($0); return true } == .applying,
            "a later false baseline hands the bit to Coffee"
        )
        expect(lease.ownsSleepDisable && lease.priorSleepDisabled == false, "successful acquisition records a false baseline")
        expect(writes == [true], "handoff should issue exactly one enable command")
        expect(lease.observe(sleepDisabled: true) { writes.append($0); return true } == .protected,
               "readback true confirms protection")
    }

    private static func testFailedVerifyAndNullReadback() {
        var waitingLease = CoffeePowerLease()
        var waitingWrites: [Bool] = []
        expect(
            waitingLease.observe(sleepDisabled: nil) { waitingWrites.append($0); return true } == .awaitingState,
            "missing state must remain awaiting"
        )
        expect(waitingWrites.isEmpty && !waitingLease.ownsSleepDisable, "missing state must not write or claim ownership")

        expect(
            waitingLease.observe(sleepDisabled: false) { waitingWrites.append($0); return true } == .applying,
            "a known false state may start applying"
        )
        expect(
            waitingLease.observe(sleepDisabled: nil) { waitingWrites.append($0); return true } == .awaitingState,
            "a missing verification readback must not claim protection"
        )
        expect(waitingLease.ownsSleepDisable && waitingWrites == [true], "ownership survives an unavailable verification read")

        var failedLease = CoffeePowerLease()
        var failedWrites: [Bool] = []
        expect(
            failedLease.observe(sleepDisabled: false) { failedWrites.append($0); return false } == .failed,
            "a failed enable command reports failure"
        )
        expect(!failedLease.ownsSleepDisable && failedWrites == [true], "a failed enable command cannot create ownership")
    }

    private static func testOffCleanupRetry() {
        var lease = CoffeePowerLease()
        var writes: [Bool] = []
        expect(lease.observe(sleepDisabled: false) { writes.append($0); return true } == .applying,
               "setup should apply the lease")
        expect(lease.observe(sleepDisabled: true) { writes.append($0); return true } == .protected,
               "setup should verify the lease")

        var releaseAttempts = 0
        expect(
            lease.cleanup(current: true) {
                writes.append($0)
                releaseAttempts += 1
                return false
            } == .releaseFailed,
            "a failed release must be reported"
        )
        expect(lease.ownsSleepDisable && !lease.releasing, "failed release retains ownership")

        expect(
            lease.cleanup(current: true) {
                writes.append($0)
                releaseAttempts += 1
                return true
            } == .releasing,
            "a successful release command waits for readback"
        )
        expect(lease.ownsSleepDisable && lease.releasing, "release command success must retain ownership until verified")
        expect(
            lease.cleanup(current: false) { writes.append($0); return true } == .released,
            "false readback completes cleanup without another write"
        )
        expect(!lease.ownsSleepDisable && !lease.releasing && releaseAttempts == 2,
               "verified cleanup clears the lease after the retry")
        expect(writes == [true, false, false], "cleanup writes only the enable and bounded release attempts")
    }

    private static func testPassiveExternalBaseline() {
        var lease = CoffeePowerLease()
        var writes: [Bool] = []
        expect(lease.observe(sleepDisabled: true) { writes.append($0); return true } == .externalProtection,
               "external baseline remains passive")
        expect(lease.observe(sleepDisabled: true) { writes.append($0); return true } == .externalProtection,
               "repeated external baseline remains passive")
        expect(lease.cleanup(current: true) { writes.append($0); return true } == .idle,
               "cleanup cannot touch a lease it does not own")
        expect(writes.isEmpty && !lease.ownsSleepDisable, "passive external baseline must never be written")
    }

    private static func testDuplicateWritesAvoided() {
        var lease = CoffeePowerLease()
        var writes: [Bool] = []
        expect(lease.observe(sleepDisabled: false) { writes.append($0); return true } == .applying,
               "first false observation applies once")
        expect(lease.observe(sleepDisabled: false) { writes.append($0); return true } == .applying,
               "pending application remains applying")
        expect(writes == [true], "pending application must not duplicate enable writes")
        expect(lease.observe(sleepDisabled: true) { writes.append($0); return true } == .protected,
               "true readback confirms the pending application")
        expect(lease.observe(sleepDisabled: true) { writes.append($0); return true } == .protected,
               "repeated protection readback remains protected")
        expect(writes == [true], "protected readback must not duplicate enable writes")
    }

    private static func testReacquireAfterForeignClear() {
        var lease = CoffeePowerLease()
        var writes: [Bool] = []
        expect(lease.observe(sleepDisabled: false) { writes.append($0); return true } == .applying,
               "initial acquisition should apply")
        expect(lease.observe(sleepDisabled: true) { writes.append($0); return true } == .protected,
               "initial acquisition should verify")

        expect(
            lease.observe(sleepDisabled: false) { writes.append($0); return true } == .applying,
            "a foreign clear while Coffee is active should reacquire"
        )
        expect(lease.ownsSleepDisable && writes == [true, true], "reacquisition should issue one additional enable command")
        expect(lease.observe(sleepDisabled: true) { writes.append($0); return true } == .protected,
               "reacquisition should require fresh true readback")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { preconditionFailure(message) }
    }

    private static func testStopBeforeRegistryCatchesUp() {
        var lease = CoffeePowerLease()
        var writes: [Bool] = []
        _ = lease.observe(sleepDisabled: false) { writes.append($0); return true }
        expect(lease.cleanup(current: false) { writes.append($0); return true } == .releasing,
               "Stopping before enable readback must undo the pending persistent preference")
        expect(writes == [true, false] && lease.ownsSleepDisable, "Pending write cleanup remains owned")
        expect(lease.cleanup(current: false) { writes.append($0); return true } == .released,
               "A second false readback verifies cleanup")
    }

    private static func testVerificationCannotWaitForever() {
        var lease = CoffeePowerLease()
        var writes: [Bool] = []
        _ = lease.observe(sleepDisabled: false) { writes.append($0); return true }
        var event = CoffeePowerLeaseEvent.applying
        for _ in 0..<8 { event = lease.observe(sleepDisabled: false) { writes.append($0); return true } }
        expect(event == .failed && writes == [true], "Failed readback must report failure without a write storm")
    }
}
