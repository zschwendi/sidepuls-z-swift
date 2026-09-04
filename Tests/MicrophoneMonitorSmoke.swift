import CoreAudio
import Foundation

@MainActor
final class MicrophoneSnapshotRecorder {
    var snapshots: [MicrophoneSnapshot] = []
}

@main
enum MicrophoneMonitorSmoke {
    @MainActor
    static func main() {
        let builtIn = MicrophoneDeviceState(
            deviceName: "Built-in Microphone",
            isRunning: false,
            hardwareMuted: false
        )
        let usbMuted = MicrophoneDeviceState(
            deviceName: "USB Microphone",
            isRunning: true,
            hardwareMuted: true
        )
        let unknown = MicrophoneDeviceState(
            deviceName: "Continuity Microphone",
            isRunning: true,
            hardwareMuted: nil
        )
        let unmuted = MicrophoneDeviceState(
            deviceName: "USB Microphone (unmuted)",
            isRunning: true,
            hardwareMuted: false
        )
        let outputOnlyProcess = MicrophoneProcessState(
            isRunningInput: false,
            inputDeviceIDs: [42]
        )
        let inputProcess = MicrophoneProcessState(
            isRunningInput: true,
            inputDeviceIDs: [7]
        )

        let idle = MicrophoneActivityMonitor.reduce([builtIn])
        precondition(idle.activity == .idle)
        precondition(idle.deviceName == "Built-in Microphone")
        precondition(idle.hardwareMuteAvailable)

        let muted = MicrophoneActivityMonitor.reduce([builtIn, usbMuted])
        precondition(muted.activity == .muted)
        precondition(muted.deviceName == "USB Microphone")

        let inUse = MicrophoneActivityMonitor.reduce([usbMuted, unknown])
        precondition(inUse.activity == .inUse)
        precondition(inUse.deviceName == "USB Microphone, Continuity Microphone")
        precondition(inUse.detail.contains("unavailable"))

        let unmutedWins = MicrophoneActivityMonitor.reduce([usbMuted, unmuted])
        precondition(unmutedWins.activity == .inUse)
        precondition(unmutedWins.detail.contains("off"))

        precondition(
            MicrophoneActivityMonitor.activeInputDeviceIDs(from: [outputOnlyProcess]).isEmpty
        )
        precondition(
            MicrophoneActivityMonitor.activeInputDeviceIDs(from: [outputOnlyProcess, inputProcess]) == Set([AudioObjectID(7)])
        )

        let unavailable = MicrophoneActivityMonitor.reduce([])
        precondition(unavailable == .unavailable)

        let noMute = MicrophoneActivityMonitor.reduce([
            MicrophoneDeviceState(deviceName: "", isRunning: false, hardwareMuted: nil)
        ])
        precondition(noMute.activity == .idle)
        precondition(noMute.deviceName == "Microphone")
        precondition(!noMute.hardwareMuteAvailable)

        let recorder = MicrophoneSnapshotRecorder()
        let monitor = MicrophoneActivityMonitor { snapshot in
            recorder.snapshots.append(snapshot)
        }
        monitor.start()
        precondition(recorder.snapshots.count == 1)
        monitor.start()
        precondition(recorder.snapshots.count == 1)
        monitor.stop()

        print("Microphone monitor smoke passed: read-only aggregation preserves active unknown mute as in use")
    }
}
