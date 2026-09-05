import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

/// The values that are relevant to the closed-lid lease.  The optional fields
/// are intentionally fail-closed: a missing powerd value is not permission to
/// change a global power mask.
struct ClosedLidSleepGuardState: Equatable, Sendable {
    var clamshellCausesSleep: Bool?
    var sleepDisabled: Bool?
    var activeLidCloseAssertions: Bool?
    var externalDisplayConnected: Bool?
    var acPowerConnected: Bool?

    init(
        clamshellCausesSleep: Bool?,
        sleepDisabled: Bool?,
        activeLidCloseAssertions: Bool? = nil,
        externalDisplayConnected: Bool? = nil,
        acPowerConnected: Bool? = nil
    ) {
        self.clamshellCausesSleep = clamshellCausesSleep
        self.sleepDisabled = sleepDisabled
        self.activeLidCloseAssertions = activeLidCloseAssertions
        self.externalDisplayConnected = externalDisplayConnected
        self.acPowerConnected = acPowerConnected
    }
}

enum ClosedLidSleepGuardDecision: Equatable, Sendable {
    case acquire
    case passive(reason: String)
}

/// Policy is kept independent from IOKit so a smoke test can prove ownership
/// and restoration without touching the host's actual clamshell state.
enum ClosedLidSleepGuardPolicy {
    static func acquisitionDecision(for state: ClosedLidSleepGuardState) -> ClosedLidSleepGuardDecision {
        if state.clamshellCausesSleep == false {
            return .passive(reason: "lid_sleep_disabled_externally")
        }
        guard state.clamshellCausesSleep == true else {
            return .passive(reason: "clamshell_causes_sleep_unavailable")
        }
        guard state.sleepDisabled == false else {
            return .passive(reason: "sleep_disabled_externally")
        }
        guard state.activeLidCloseAssertions == false,
              let external = state.externalDisplayConnected,
              let ac = state.acPowerConnected else {
            return .passive(reason: "clamshell_causes_sleep_unavailable")
        }
        if external && ac { return .passive(reason: "lid_sleep_disabled_externally") }
        return .acquire
    }

    static func mayRestore(
        ownershipIsOurs: Bool,
        prior: ClosedLidSleepGuardState,
        current: ClosedLidSleepGuardState
    ) -> Bool {
        guard ownershipIsOurs,
              prior.clamshellCausesSleep == true,
              prior.sleepDisabled == false,
              current.sleepDisabled == false else {
            return false
        }

        // Our own bit makes AppleClamshellCausesSleep false after a lid event.
        // That is expected, not an external owner. Preserve currently active
        // system assertions or an AC-powered desktop configuration instead.
        guard current.activeLidCloseAssertions == false,
              let external = current.externalDisplayConnected,
              let ac = current.acPowerConnected else { return false }
        guard !(external && ac) else { return false }
        return true
    }

    static func restoreReason(
        prior: ClosedLidSleepGuardState,
        current: ClosedLidSleepGuardState
    ) -> String {
        if current.sleepDisabled == true { return "sleep_disabled_externally" }
        if !knownValueUnchanged(prior.activeLidCloseAssertions, current.activeLidCloseAssertions) {
            return "lid_close_assertions_changed"
        }
        if !knownValueUnchanged(prior.externalDisplayConnected, current.externalDisplayConnected) {
            return "external_display_state_changed"
        }
        if !knownValueUnchanged(prior.acPowerConnected, current.acPowerConnected) {
            return "ac_power_state_changed"
        }
        return "ownership_or_state_ambiguous"
    }

    private static func knownValueUnchanged(_ prior: Bool?, _ current: Bool?) -> Bool {
        guard let prior else { return true }
        guard let current else { return false }
        return prior == current
    }
}

enum ClosedLidSleepGuardLeaseEvent: Equatable, Sendable {
    case waiting(reason: String)
    case acquired
    case acquireFailed
    case restored
    case restoreSkipped(reason: String)
    case restoreFailed
    case idle
}

/// A tiny ownership state machine.  The production guardian supplies the
/// selector-12 closure; tests supply a recording closure instead.
struct ClosedLidSleepGuardLease: Sendable {
    private(set) var priorState: ClosedLidSleepGuardState?
    private(set) var ownsClamshellMask = false

    mutating func observe(
        state: ClosedLidSleepGuardState,
        setClamshellSleepState: (Bool) -> Bool
    ) -> ClosedLidSleepGuardLeaseEvent {
        if ownsClamshellMask {
            // Powerd can rewrite this shared runtime bit after a power-source
            // or display change. Refresh only a change we originally acquired.
            return setClamshellSleepState(true) ? .acquired : .acquireFailed
        }

        switch ClosedLidSleepGuardPolicy.acquisitionDecision(for: state) {
        case .passive(let reason):
            return .waiting(reason: reason)
        case .acquire:
            // Record the known-enabled baseline immediately before the only
            // write.  A failed write never creates a lease.
            priorState = state
            guard setClamshellSleepState(true) else {
                priorState = nil
                return .acquireFailed
            }
            ownsClamshellMask = true
            return .acquired
        }
    }

    mutating func cleanup(
        currentState: ClosedLidSleepGuardState,
        setClamshellSleepState: (Bool) -> Bool
    ) -> ClosedLidSleepGuardLeaseEvent {
        guard ownsClamshellMask, let priorState else {
            return .idle
        }
        guard ClosedLidSleepGuardPolicy.mayRestore(
            ownershipIsOurs: true,
            prior: priorState,
            current: currentState
        ) else {
            return .restoreSkipped(
                reason: ClosedLidSleepGuardPolicy.restoreReason(prior: priorState, current: currentState)
            )
        }

        guard setClamshellSleepState(false) else { return .restoreFailed }
        self.priorState = nil
        self.ownsClamshellMask = false
        return .restored
    }
}

private struct ClosedLidSleepGuardStatusLine: Codable {
    var status: String
    var active: Bool
    var reason: String
}

private final class ClosedLidSleepGuardLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(path: String) -> ClosedLidSleepGuardLock? {
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return nil }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (info.st_mode & mode_t(0o777)) == mode_t(0o600),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return ClosedLidSleepGuardLock(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

protocol ClosedLidSleepGuardSystemIO {
    func readState() -> ClosedLidSleepGuardState
    func setClamshellSleepState(_ enabled: Bool) -> Bool
}

private struct LiveClosedLidSleepGuardSystemIO: ClosedLidSleepGuardSystemIO {
    private static let rootDomainName = "IOPMrootDomain"
    private static let sleepDisabledKey = "SleepDisabled"
    private static let appliesOnLidCloseKey = "AppliesOnLidClose"
    private static let assertionLevelKey = "AssertLevel"
    private static let selector: UInt32 = 12

    func readState() -> ClosedLidSleepGuardState {
        let settings = Self.copyCurrentPowerSettings()
        return ClosedLidSleepGuardState(
            clamshellCausesSleep: Self.boolValue(settings?[kAppleClamshellCausesSleepKey]),
            sleepDisabled: Self.boolValue(settings?[Self.sleepDisabledKey]),
            activeLidCloseAssertions: Self.activeLidCloseAssertions(),
            externalDisplayConnected: Self.externalDisplayConnected(),
            acPowerConnected: Self.acPowerConnected()
        )
    }

    func setClamshellSleepState(_ enabled: Bool) -> Bool {
        let matching = IOServiceMatching(Self.rootDomainName)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return false
        }
        defer { IOServiceClose(connection) }

        var input = UInt64(enabled ? 1 : 0)
        return IOConnectCallScalarMethod(connection, Self.selector, &input, 1, nil, nil) == KERN_SUCCESS
    }

    private static func copyCurrentPowerSettings() -> [String: Any]? {
        copyRootDomainProperties()
    }

    private static func copyRootDomainProperties() -> [String: Any]? {
        let matching = IOServiceMatching(rootDomainName)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties else {
            return nil
        }
        let dictionary = properties.takeRetainedValue() as NSDictionary
        return dictionary as? [String: Any]
    }

    private static func activeLidCloseAssertions() -> Bool? {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let assertions else {
            return nil
        }

        let byProcess = assertions.takeRetainedValue() as NSDictionary
        for case let (_, rawList) in byProcess {
            guard let list = rawList as? NSArray else { return nil }
            for rawAssertion in list {
                guard let assertion = rawAssertion as? NSDictionary else { return nil }
                guard boolValue(assertion[appliesOnLidCloseKey]) == true else { continue }
                let level = intValue(assertion[assertionLevelKey]) ?? 0
                if level > 0 { return true }
            }
        }
        return false
    }

    private static func externalDisplayConnected() -> Bool? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            return nil
        }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private static func acPowerConnected() -> Bool? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return nil }
        return (source as String) == "AC Power"
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

final class ClosedLidSleepGuardGuardian {
    private let system: ClosedLidSleepGuardSystemIO
    private var lease = ClosedLidSleepGuardLease()
    private var lastWaitingReason: String?
    private var lastReportedEvent: ClosedLidSleepGuardLeaseEvent?
    private var wantsActive = true
    private var parentEnded = false

    init() { self.system = LiveClosedLidSleepGuardSystemIO() }

    init(system: ClosedLidSleepGuardSystemIO) {
        self.system = system
    }

    func run(lockPath: String = "/tmp/sidepulse-coffee-guardian-\(getuid()).lock") {
        guard let lock = ClosedLidSleepGuardLock.acquire(path: lockPath) else {
            emit(status: "passive", active: false, reason: "already_running")
            return
        }

        withExtendedLifetime(lock) {
            setStandardInputNonBlocking()

            while true {
                if !parentEnded, parentPipeClosed() {
                    parentEnded = true
                    wantsActive = false
                }

                let event: ClosedLidSleepGuardLeaseEvent
                if wantsActive {
                    event = lease.observe(state: system.readState()) { [system] enabled in
                        system.setClamshellSleepState(enabled)
                    }
                } else if lease.ownsClamshellMask {
                    // Keep responsibility on transient read/write errors or
                    // while another power setting makes release unsafe.
                    event = lease.cleanup(currentState: system.readState()) { [system] enabled in
                        system.setClamshellSleepState(enabled)
                    }
                } else {
                    event = .idle
                }
                report(event)
                if parentEnded, !lease.ownsClamshellMask { return }
                if parentEnded {
                    Thread.sleep(forTimeInterval: 1)
                } else if !waitForParentTick() {
                    parentEnded = true
                    wantsActive = false
                }
            }
        }
    }

    private func report(_ event: ClosedLidSleepGuardLeaseEvent) {
        guard event != lastReportedEvent else { return }
        lastReportedEvent = event
        switch event {
        case .waiting(let reason):
            guard lastWaitingReason != reason else { return }
            lastWaitingReason = reason
            emit(status: "passive", active: false, reason: reason)
        case .acquired:
            lastWaitingReason = nil
            emit(status: "active", active: true, reason: "clamshell_sleep_mask_owned")
        case .acquireFailed:
            lastWaitingReason = "acquire_failed"
            emit(status: "passive", active: false, reason: "clamshell_mask_unavailable")
        case .restored:
            emit(status: "stopped", active: false, reason: "restored")
        case .restoreSkipped(let reason):
            emit(status: "stopped", active: false, reason: "preserved_\(reason)")
        case .restoreFailed:
            emit(status: "stopped", active: false, reason: "restore_failed")
        case .idle:
            emit(status: "stopped", active: false, reason: "passive")
        }
    }

    private func emit(status: String, active: Bool, reason: String) {
        let line = ClosedLidSleepGuardStatusLine(status: status, active: active, reason: reason)
        guard let encoded = try? JSONEncoder().encode(line) else { return }
        var data = encoded
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private func setStandardInputNonBlocking() {
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)
    }

    private func parentPipeClosed() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL), revents: 0)
        let result = poll(&descriptor, 1, 0)
        guard result > 0 else { return false }
        return consumeParentPipe(descriptor.revents)
    }

    private func waitForParentTick() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL), revents: 0)
        while true {
            let result = poll(&descriptor, 1, 1000)
            if result == 0 { return true }
            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            return !consumeParentPipe(descriptor.revents)
        }
    }

    private func consumeParentPipe(_ events: Int16) -> Bool {
        if events & Int16(POLLNVAL) != 0 { return true }
        if events & Int16(POLLIN | POLLHUP | POLLERR) == 0 { return false }

        var bytes = [UInt8](repeating: 0, count: 256)
        let count = read(STDIN_FILENO, &bytes, bytes.count)
        if count == 0 { return true }
        if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK { return true }
        if count > 0 {
            // Each command is one byte, so split/coalesced pipe reads cannot
            // lose the last requested state. EOF always means release.
            for byte in bytes.prefix(count) {
                if byte == 49 { wantsActive = true }
                if byte == 48 { wantsActive = false }
            }
        }
        return false
    }
}

/// Parent-side controller.  It starts a helper process whose stdin is a
/// liveness pipe; closing that pipe is the helper's cleanup signal.
@MainActor
final class ClosedLidSleepGuard {
    typealias StatusHandler = @MainActor @Sendable (String) -> Void

    private static let guardianArgument = "--sidepulse-coffee-guardian"
    private static let expectedBundleIdentifier = "com.zephyrstudiosllc.sidepulse-z"

    private let onStatus: StatusHandler
    private let executableOverride: URL?
    private let allowNonAppExecutable: Bool
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var wantsActive = false

    private(set) var isActive = false

    init(
        onStatus: @escaping StatusHandler,
        executableOverride: URL? = nil,
        allowNonAppExecutable: Bool = false
    ) {
        self.onStatus = onStatus
        self.executableOverride = executableOverride
        self.allowNonAppExecutable = allowNonAppExecutable
    }

    func start() {
        wantsActive = true
        guard !isActive else { return }

        if let process, process.isRunning {
            sendControl(enabled: true)
            isActive = true
            return
        }
        launchIfValid()
    }

    func stop() {
        wantsActive = false
        retryTask?.cancel()
        retryTask = nil
        sendControl(enabled: false)
        isActive = false
    }

    private func launchIfValid() {
        guard wantsActive else { return }
        guard let executableURL = executableURLIfAllowed() else {
            emitParentStatus("{\"status\":\"passive\",\"active\":false,\"reason\":\"guardian_launch_rejected\"}")
            return
        }

        let input = Pipe()
        let output = Pipe()
        let child = Process()
        child.executableURL = executableURL
        child.arguments = [Self.guardianArgument]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = output
        child.terminationHandler = { [weak self, weak child] _ in
            Task { @MainActor [weak self, weak child] in
                guard let self else { return }
                self.handleTermination(child)
            }
        }

        do {
            try child.run()
        } catch {
            emitParentStatus("{\"status\":\"passive\",\"active\":false,\"reason\":\"guardian_launch_failed\"}")
            return
        }

        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        process = child
        inputPipe = input
        outputPipe = output
        isActive = true
        readTask = readStatuses(from: output.fileHandleForReading)
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            // The guardian polls its liveness pipe at most once per second.
            // Give the old child a bounded chance to observe EOF before
            // trying to start a replacement.
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.wantsActive else { return }
                if !(self.process?.isRunning ?? false) {
                    self.retryTask = nil
                    self.launchIfValid()
                    return
                }
            }
            self?.retryTask = nil
        }
    }

    private func sendControl(enabled: Bool) {
        guard let inputPipe else { return }
        try? inputPipe.fileHandleForWriting.write(contentsOf: Data(enabled ? [49] : [48]))
    }

    private func readStatuses(from handle: FileHandle) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    guard let self else { return }
                    self.emitParentStatus(line)
                }
            } catch {
                // Child cleanup remains owned by its stdin EOF path.
            }
        }
    }

    private func emitParentStatus(_ status: String) {
        guard let data = status.data(using: .utf8),
              let value = try? JSONDecoder().decode(ClosedLidSleepGuardStatusLine.self, from: data)
        else { return }
        let message: String
        switch value.reason {
        case "clamshell_sleep_mask_owned": message = "Lid sleep prevented"
        case "sleep_disabled_externally", "lid_sleep_disabled_externally":
            message = "Idle sleep prevented; existing lid-sleep state preserved"
        case "already_running": message = "Waiting for the previous Coffee session to close"
        case "guardian_launch_rejected", "guardian_launch_failed", "clamshell_mask_unavailable", "clamshell_causes_sleep_unavailable":
            message = "Idle sleep prevented; closed-lid support unavailable"
        case "restore_failed": message = "Retrying release of the lid-sleep change"
        default: return
        }
        onStatus(message)
    }

    private func handleTermination(_ terminatedChild: Process?) {
        guard terminatedChild === process else { return }
        isActive = false
        process = nil
        inputPipe = nil
        outputPipe = nil
        readTask = nil
        if wantsActive { scheduleRetry() }
    }

    private func executableURLIfAllowed() -> URL? {
        let bundle = Bundle.main
        let executable = executableOverride ?? bundle.executableURL
        guard let executable,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            return nil
        }

        if allowNonAppExecutable { return executable }
        guard bundle.bundleIdentifier == Self.expectedBundleIdentifier,
              bundle.bundleURL.pathExtension == "app",
              let bundledExecutable = bundle.executableURL,
              bundledExecutable.standardizedFileURL == executable.standardizedFileURL,
              executable.path.hasPrefix(bundle.bundleURL.standardizedFileURL.path + "/") else {
            return nil
        }
        return executable
    }

    deinit {
        readTask?.cancel()
        retryTask?.cancel()
        inputPipe?.fileHandleForWriting.closeFile()
    }
}

extension ClosedLidSleepGuard {
    /// Returns true only when the process was the explicitly requested helper.
    /// The caller should return from its entry point after this returns.
    @discardableResult
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == ClosedLidSleepGuardGuardianArgument.value else {
            return false
        }
        signal(SIGPIPE, SIG_IGN)
        ClosedLidSleepGuardGuardian().run()
        return true
    }
}

private enum ClosedLidSleepGuardGuardianArgument {
    static let value = "--sidepulse-coffee-guardian"
}
