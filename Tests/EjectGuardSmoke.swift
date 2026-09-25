import Foundation

@main
enum EjectGuardSmoke {
    static func main() throws {
        let sidePulsePro = SidePulseEjectGuard.DiskDescription(
            deviceProtocol: "Secure Digital",
            deviceModel: "Apple SDXC Reader",
            isInternal: true,
            volumeName: "SidePulse Pro",
            volumePathName: "SidePulse Pro"
        )
        precondition(sidePulsePro.shouldProtect)

        var genericSDCard = sidePulsePro
        genericSDCard.volumeName = "CAMERA"
        genericSDCard.volumePathName = "CAMERA"
        precondition(!genericSDCard.shouldProtect)

        var externalReader = sidePulsePro
        externalReader.isInternal = false
        precondition(!externalReader.shouldProtect)

        var unknownReader = sidePulsePro
        unknownReader.isInternal = nil
        precondition(!unknownReader.shouldProtect)

        let sidePulseDot = SidePulseEjectGuard.DiskDescription(
            deviceProtocol: "USB",
            deviceModel: "SidePulse Dot",
            isInternal: false,
            volumeName: "SidePulse Dot",
            volumePathName: "SidePulse Dot"
        )
        precondition(!sidePulseDot.shouldProtect)

        var volumePathFallback = sidePulsePro
        volumePathFallback.volumeName = nil
        volumePathFallback.volumePathName = "SidePulse"
        precondition(volumePathFallback.shouldProtect)

        var checkedServiceTargets: [String] = []
        let staleHelperIsIgnored = SidePulseEjectGuard.runningExternalHelperExists(
            currentUserID: 502
        ) { target in
            checkedServiceTargets.append(target)
            return false
        }
        precondition(!staleHelperIsIgnored)
        precondition(checkedServiceTargets == [
            "gui/502/io.sidepulse.sdejectguard",
            "system/io.sidepulse.sdejectguard",
        ])
        precondition(
            SidePulseEjectGuard.runningExternalHelperExists(currentUserID: 502) {
                $0 == "gui/502/io.sidepulse.sdejectguard"
            }
        )

        var reenteredRunLoop = false
        let pendingStartupWork = Timer(fire: .distantPast, interval: 0, repeats: false) { _ in
            reenteredRunLoop = true
        }
        RunLoop.main.add(pendingStartupWork, forMode: .default)
        _ = SidePulseEjectGuard.runningExternalHelperExists()
        pendingStartupWork.invalidate()
        precondition(!reenteredRunLoop, "Helper detection must not reenter the startup run loop")

        let ejectGuard = SidePulseEjectGuard()
        try ejectGuard.start()
        precondition(ejectGuard.isRunning)
        ejectGuard.stop()
        precondition(!ejectGuard.isRunning)

        print("Eject guard smoke passed: native session starts and only protects SidePulse Pro in the built-in SD reader")
    }
}
