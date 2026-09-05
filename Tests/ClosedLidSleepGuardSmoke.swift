import Foundation

@main
struct ClosedLidSleepGuardSmoke {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--mock-guardian" {
            ClosedLidSleepGuardGuardian(system: MockSystem()).run(lockPath: CommandLine.arguments[2])
            return
        }
        testAcquireAndRestoreKnownBaseline()
        testPreDisabledAndAmbiguousStatesStayPassive()
        testWaitsForCausesSleepToBecomeEnabled()
        testCleanupPreservesExternalChanges()
        testCleanupAfterOurOwnLidStateChange()
        testGuardianPipeCleanup()
        print("ClosedLidSleepGuardSmoke: PASS")
    }

    private static func testAcquireAndRestoreKnownBaseline() {
        let baseline = ClosedLidSleepGuardState(
            clamshellCausesSleep: true,
            sleepDisabled: false,
            activeLidCloseAssertions: false,
            externalDisplayConnected: false,
            acPowerConnected: true
        )
        var writes: [Bool] = []
        var lease = ClosedLidSleepGuardLease()

        expect(
            lease.observe(state: baseline) { enabled in
                writes.append(enabled)
                return true
            } == .acquired,
            "known enabled baseline should acquire"
        )
        expect(writes == [true], "acquisition should issue exactly one write")

        expect(
            lease.cleanup(currentState: baseline) { enabled in
                writes.append(enabled)
                return true
            } == .restored,
            "unchanged baseline should restore"
        )
        expect(writes == [true, false], "cleanup should issue the matching release")
        expect(!lease.ownsClamshellMask, "lease should be cleared after restore")
    }

    private static func testPreDisabledAndAmbiguousStatesStayPassive() {
        let preDisabled = ClosedLidSleepGuardState(
            clamshellCausesSleep: true,
            sleepDisabled: true
        )
        let ambiguous = ClosedLidSleepGuardState(
            clamshellCausesSleep: nil,
            sleepDisabled: nil
        )
        var writes: [Bool] = []
        var lease = ClosedLidSleepGuardLease()

        expect(
            lease.observe(state: preDisabled) { enabled in
                writes.append(enabled)
                return true
            } == .waiting(reason: "sleep_disabled_externally"),
            "an existing global disable must remain passive"
        )
        expect(
            lease.observe(state: ambiguous) { enabled in
                writes.append(enabled)
                return true
            } == .waiting(reason: "clamshell_causes_sleep_unavailable"),
            "ambiguous settings must remain passive"
        )
        expect(writes.isEmpty, "passive observations must not call selector 12")
    }

    private static func testWaitsForCausesSleepToBecomeEnabled() {
        let disabled = ClosedLidSleepGuardState(clamshellCausesSleep: false, sleepDisabled: false)
        let enabled = ClosedLidSleepGuardState(clamshellCausesSleep: true, sleepDisabled: false,
            activeLidCloseAssertions: false, externalDisplayConnected: false, acPowerConnected: true)
        var writes: [Bool] = []
        var lease = ClosedLidSleepGuardLease()

        expect(
            lease.observe(state: disabled) { enabled in
                writes.append(enabled)
                return true
            } == .waiting(reason: "lid_sleep_disabled_externally"),
            "external desktop mode should be observed without a write"
        )
        expect(
            lease.observe(state: enabled) { value in
                writes.append(value)
                return true
            } == .acquired,
            "the lease should acquire once the known baseline is enabled"
        )
        expect(writes == [true], "only the transition to a known enabled baseline writes")
    }

    private static func testCleanupPreservesExternalChanges() {
        let baseline = ClosedLidSleepGuardState(
            clamshellCausesSleep: true,
            sleepDisabled: false,
            activeLidCloseAssertions: false,
            externalDisplayConnected: false,
            acPowerConnected: true
        )
        let changed = ClosedLidSleepGuardState(
            clamshellCausesSleep: true,
            sleepDisabled: true,
            activeLidCloseAssertions: true,
            externalDisplayConnected: true,
            acPowerConnected: true
        )
        var writes: [Bool] = []
        var lease = ClosedLidSleepGuardLease()
        _ = lease.observe(state: baseline) { enabled in
            writes.append(enabled)
            return true
        }

        expect(
            lease.cleanup(currentState: changed) { enabled in
                writes.append(enabled)
                return true
            } == .restoreSkipped(reason: "sleep_disabled_externally"),
            "cleanup must preserve an external global disable"
        )
        expect(writes == [true], "preserved external state must not receive a release")
        expect(lease.ownsClamshellMask, "Guardian must retain responsibility while release is unsafe")
        expect(lease.cleanup(currentState: baseline) { writes.append($0); return true } == .restored,
               "Guardian must release its change once the external session ends")
        expect(writes == [true, false], "Deferred cleanup must eventually release")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { preconditionFailure(message) }
    }

    private static func testCleanupAfterOurOwnLidStateChange() {
        let baseline = ClosedLidSleepGuardState(clamshellCausesSleep: true, sleepDisabled: false,
            activeLidCloseAssertions: false, externalDisplayConnected: false, acPowerConnected: true)
        var lease = ClosedLidSleepGuardLease()
        var writes: [Bool] = []
        _ = lease.observe(state: baseline) { writes.append($0); return true }
        var afterLidClose = baseline
        afterLidClose.clamshellCausesSleep = false
        afterLidClose.acPowerConnected = false
        expect(lease.cleanup(currentState: afterLidClose) { writes.append($0); return true } == .restored,
               "Our own bit changes the published lid state; closing/opening the lid and unplugging must not strand it")
        expect(writes == [true, false], "Own change must be released after a lid event")
    }

    private final class MockSystem: ClosedLidSleepGuardSystemIO {
        var enabled = false
        var releaseAttempts = 0
        func readState() -> ClosedLidSleepGuardState {
            ClosedLidSleepGuardState(clamshellCausesSleep: !enabled, sleepDisabled: false,
                activeLidCloseAssertions: false, externalDisplayConnected: false, acPowerConnected: true)
        }
        func setClamshellSleepState(_ value: Bool) -> Bool {
            if !value {
                releaseAttempts += 1
                if releaseAttempts == 1 {
                    try? FileHandle.standardOutput.write(contentsOf: Data("RELEASE TEMPORARILY FAILED\n".utf8))
                    return false
                }
            }
            enabled = value
            try? FileHandle.standardOutput.write(contentsOf: Data("WRITE \(value ? 1 : 0)\n".utf8))
            return true
        }
    }

    private static func testGuardianPipeCleanup() {
        let input = Pipe(), output = Pipe(), child = Process()
        let lockPath = "/tmp/sidepulse-coffee-test-\(UUID().uuidString).lock"
        defer { try? FileManager.default.removeItem(atPath: lockPath) }
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--mock-guardian", lockPath]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = output
        try! child.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        let first = output.fileHandleForReading.availableData
        expect(String(decoding: first, as: UTF8.self).contains("WRITE 1"), "Mock guardian must acquire its lease")
        input.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(3)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning { child.terminate(); preconditionFailure("Guardian did not exit on parent pipe EOF") }
        let rest = output.fileHandleForReading.readDataToEndOfFile()
        let transcript = String(decoding: first + rest, as: UTF8.self)
        expect(child.terminationStatus == 0 && transcript.contains("WRITE 0"), "Parent EOF must restore the owned change")
        expect(transcript.contains("restored"), "Guardian must report successful cleanup")
        expect(transcript.contains("RELEASE TEMPORARILY FAILED"), "Retry test must exercise a failed release")
    }
}
