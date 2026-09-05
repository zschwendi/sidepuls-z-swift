import Foundation
import IOKit.pwr_mgt

@main
enum KeepAwakeSmoke {
    @MainActor
    static func main() {
        let controller = KeepAwakeController(controlsClosedLidSleep: false)
        precondition(!controller.isActive)
        precondition(controller.setEnabled(true))
        precondition(controller.isActive && controller.assertionIDs.count == 1)
        let ids = controller.assertionIDs
        precondition(controller.setEnabled(true) && controller.assertionIDs == ids,
                     "Repeated enable must not leak duplicate assertions")
        for id in ids {
            let properties = IOPMAssertionCopyProperties(id)!.takeRetainedValue() as NSDictionary
            precondition(properties[kIOPMAssertionTypeKey] as? String == "PreventUserIdleSystemSleep")
            precondition(properties[kIOPMAssertionLevelKey] as? Int == Int(kIOPMAssertionLevelOn))
        }
        controller.stop()
        precondition(!controller.isActive)
        for id in ids { precondition(IOPMAssertionCopyProperties(id) == nil) }
        controller.stop()
        precondition(controller.setEnabled(true))
        precondition(controller.setEnabled(false) && !controller.isActive)
        print("Keep awake smoke passed: native assertion activation, deduplication, release and re-enable")
    }
}
