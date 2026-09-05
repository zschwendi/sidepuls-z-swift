import Foundation
import IOKit.pwr_mgt

/// Idle prevention is process-owned. Closed-lid protection is a separate,
/// administrator-authorized session with verified power-state readback.
@MainActor
final class KeepAwakeController {
    private(set) var assertionIDs: [IOPMAssertionID] = []
    private(set) var errorMessage: String?
    private(set) var closedLidStatus = "Starting closed-lid support…"
    var onStatusChanged: (@MainActor @Sendable () -> Void)?
    private let controlsClosedLidSleep: Bool
    private var closedLidGuard: CoffeePowerProtect?
    private(set) var needsClosedLidAuthorization = false
    var isActive: Bool { !assertionIDs.isEmpty }

    var statusMessage: String {
        if let errorMessage { return errorMessage }
        guard isActive else {
            if closedLidStatus.hasPrefix("Restoring") || closedLidStatus.hasPrefix("Retrying") {
                return "Coffee off · \(closedLidStatus)"
            }
            return "Keep the Mac awake while SidePulse is running"
        }
        return "Coffee on · \(closedLidStatus)"
    }

    init(controlsClosedLidSleep: Bool = true) {
        self.controlsClosedLidSleep = controlsClosedLidSleep
    }

    deinit {
        for assertion in assertionIDs { IOPMAssertionRelease(assertion) }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            stop()
            return true
        }
        guard !isActive else { return true }
        errorMessage = nil
        let requests: [(CFString, String)] = [
            (kIOPMAssertPreventUserIdleSystemSleep as CFString, "SidePulse Coffee — keep Mac awake"),
        ]
        for (type, name) in requests {
            var assertion = IOPMAssertionID(kIOPMNullAssertionID)
            let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                   name as CFString, &assertion)
            guard result == kIOReturnSuccess else {
                stop()
                errorMessage = "macOS could not start Keep Awake (\(result))."
                return false
            }
            assertionIDs.append(assertion)
        }
        if controlsClosedLidSleep {
            if closedLidGuard == nil {
                closedLidGuard = CoffeePowerProtect { [weak self] status, needsAuthorization in
                    guard let self else { return }
                    self.closedLidStatus = status
                    self.needsClosedLidAuthorization = needsAuthorization
                    self.onStatusChanged?()
                }
            }
            closedLidGuard?.start()
        } else {
            closedLidStatus = "Idle sleep prevented"
        }
        return true
    }

    func authorizeClosedLidProtection() {
        guard isActive else { return }
        closedLidGuard?.start(allowAuthorization: true)
    }

    func stop() {
        let restoring = closedLidGuard?.stop() ?? false
        for assertion in assertionIDs { IOPMAssertionRelease(assertion) }
        assertionIDs.removeAll()
        errorMessage = nil
        needsClosedLidAuthorization = false
        closedLidStatus = restoring ? "Restoring normal sleep…" : "Starting closed-lid support…"
    }
}
