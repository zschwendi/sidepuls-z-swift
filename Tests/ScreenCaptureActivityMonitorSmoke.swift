import Foundation

@main
enum ScreenCaptureActivityMonitorSmoke {
    @MainActor
    static func main() {
        assertAccessibilityClassification()
        assertNativeMarkerMatching()
        print("Screen capture monitor smoke passed: availability and native marker classification")
    }

    @MainActor
    private static func assertAccessibilityClassification() {
        let denied = ScreenCaptureActivityMonitor.snapshot(
            accessibilityTrusted: false,
            stopButtonFound: nil
        )
        precondition(!denied.isAvailable && !denied.isRecording)
        precondition(denied.detail.contains("Accessibility access is required"))

        let unreadable = ScreenCaptureActivityMonitor.snapshot(
            accessibilityTrusted: true,
            stopButtonFound: nil
        )
        precondition(!unreadable.isAvailable && !unreadable.isRecording)
        precondition(unreadable.detail == "Recording status could not be read.")

        let inactive = ScreenCaptureActivityMonitor.snapshot(
            accessibilityTrusted: true,
            stopButtonFound: false
        )
        precondition(inactive.isAvailable && !inactive.isRecording)
        precondition(inactive.detail == "macOS Screenshot is not recording.")

        let active = ScreenCaptureActivityMonitor.snapshot(
            accessibilityTrusted: true,
            stopButtonFound: true
        )
        precondition(active.isAvailable && active.isRecording)
        precondition(active.detail == "Screen recording is active in macOS Screenshot.")

        precondition(ScreenCaptureSnapshot.unavailable.detail == "Recording status could not be read.")
    }

    @MainActor
    private static func assertNativeMarkerMatching() {
        precondition(
            ScreenCaptureActivityMonitor.matchesStopRecordingControl(
                identifier: "stop.circle.fill",
                description: nil
            )
        )
        precondition(
            ScreenCaptureActivityMonitor.matchesStopRecordingControl(
                identifier: nil,
                description: "Stop Screen Recording"
            )
        )
        precondition(
            ScreenCaptureActivityMonitor.matchesStopRecordingControl(
                identifier: "stop.circle.fill",
                description: "Unrelated description"
            )
        )
        precondition(
            !ScreenCaptureActivityMonitor.matchesStopRecordingControl(
                identifier: "stop.circle",
                description: "Stop Screen Recording Now"
            )
        )
    }
}
