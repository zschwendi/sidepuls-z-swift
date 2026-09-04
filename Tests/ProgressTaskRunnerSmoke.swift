import Foundation
import Darwin

@MainActor
private final class ProgressSnapshotProbe {
    var snapshots: [ProgressTaskSnapshot] = []
}

@main
enum ProgressTaskRunnerSmoke {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidepulse-progress-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try testSuccessfulProgress(runningIn: directory)
        try testFailureExitCode(runningIn: directory)
        try testFastExit(runningIn: directory)
        try testOwnedCancellation(runningIn: directory)
        try testReadOnlyWatch(runningIn: directory)
        try testChildCancellation(runningIn: directory)
        try testVerboseAndPartialOutput(runningIn: directory)
        try testInheritedPipes(runningIn: directory)

        print("Progress task runner smoke passed: progress parsing, bounded logs, child cancellation, shutdown, failure status, and read-only watching work")
    }

    @MainActor
    private static func testSuccessfulProgress(runningIn directory: URL) throws {
        let probe = ProgressSnapshotProbe()
        let runner = ProgressTaskRunner { snapshot in probe.snapshots.append(snapshot) }
        try runner.run(
            command: "printf 'starting\\nSIDEPULSE_PROGRESS=25\\n'; sleep 0.7; printf 'SIDEPULSE_PROGRESS=100\\n'",
            directory: directory
        )

        waitUntil(timeout: 1.5, label: "initial progress") {
            probe.snapshots.contains { $0.phase == .running && $0.fraction == 0.25 }
        }
        waitUntil(timeout: 3, label: "successful completion") { runner.snapshot.phase == .completed }
        precondition(runner.snapshot.exitCode == 0)
        precondition(runner.snapshot.fraction == 1)

        let logURL = runner.snapshot.logURL!
        let log = try String(contentsOf: logURL, encoding: .utf8)
        precondition(log.contains("starting"))
        precondition(log.contains("SIDEPULSE_PROGRESS=25"))
        precondition(log.contains("SIDEPULSE_PROGRESS=100"))
        let logSize = (try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue ?? 0
        precondition(logSize <= 2 * 1024 * 1024)
        runner.clear()
        precondition(runner.snapshot == .idle)
    }

    @MainActor
    private static func testFailureExitCode(runningIn directory: URL) throws {
        let runner = ProgressTaskRunner { _ in }
        try runner.run(command: "printf 'failure\\n' >&2; exit 7", directory: directory)
        waitUntil(timeout: 3, label: "failure completion") { runner.snapshot.phase == .failed }
        precondition(runner.snapshot.exitCode == 7)
        precondition(runner.snapshot.fraction == nil)
        precondition(runner.snapshot.logURL != nil)
        runner.clear()
        precondition(runner.snapshot == .idle)
    }

    @MainActor
    private static func testOwnedCancellation(runningIn directory: URL) throws {
        let runner = ProgressTaskRunner { _ in }
        try runner.run(command: "sleep 10", directory: directory)
        runner.cancel()
        waitUntil(timeout: 3, label: "owned cancellation") { runner.snapshot.phase == .cancelled && runner.snapshot.exitCode != nil }
        precondition(runner.snapshot.detail.contains("Cancelled"))
        runner.clear()
        precondition(runner.snapshot == .idle)
    }

    @MainActor
    private static func testFastExit(runningIn directory: URL) throws {
        let runner = ProgressTaskRunner { _ in }
        try runner.run(command: "exit 0", directory: directory)
        waitUntil(timeout: 3, label: "fast completion") { runner.snapshot.phase == .completed }
        precondition(runner.snapshot.exitCode == 0)
        runner.clear()
        precondition(runner.snapshot == .idle)
    }

    @MainActor
    private static func testReadOnlyWatch(runningIn directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "sleep 0.35"]
        process.currentDirectoryURL = directory
        try process.run()

        let runner = ProgressTaskRunner { _ in }
        try runner.watch(pid: process.processIdentifier)
        precondition(runner.snapshot.phase == .running)
        runner.cancel()
        precondition(runner.snapshot.phase == .cancelled)
        precondition(process.isRunning, "Cancelling a watcher must leave the watched process running")
        try runner.watch(pid: process.processIdentifier)
        runner.shutdown()
        precondition(process.isRunning, "Shutdown must leave a watched process running")
        process.waitUntilExit()
        runner.clear()
        precondition(runner.snapshot == .idle)

        let secondProcess = Process()
        secondProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        secondProcess.arguments = ["-lc", "sleep 0.2"]
        secondProcess.currentDirectoryURL = directory
        try secondProcess.run()

        try runner.watch(pid: secondProcess.processIdentifier)
        waitUntil(timeout: 2, label: "watch completion") { runner.snapshot.phase == .completed }
        precondition(runner.snapshot.exitCode == nil)
        precondition(runner.snapshot.detail.contains("exit status unavailable"))
        secondProcess.waitUntilExit()
        runner.clear()
    }

    @MainActor
    private static func testChildCancellation(runningIn directory: URL) throws {
        for shutdown in [false, true] {
            let pidURL = directory.appendingPathComponent("child.pid")
            try? FileManager.default.removeItem(at: pidURL)
            let runner = ProgressTaskRunner { _ in }
            try runner.run(command: "trap 'exit 0' TERM; (trap '' TERM; while :; do sleep 30; done) & echo $! > child.pid; wait", directory: directory)
            waitUntil(timeout: 2, label: "child started") {
                FileManager.default.fileExists(atPath: pidURL.path)
            }
            let childPID = Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            precondition(processIsRunning(childPID))
            if shutdown { runner.shutdown() } else { runner.cancel() }
            waitUntil(timeout: 2, label: "child stopped") { !processIsRunning(childPID) }
            if !shutdown {
                waitUntil(timeout: 2, label: "cancel reaped") { runner.snapshot.exitCode != nil }
            }
            runner.clear()
        }
    }

    @MainActor
    private static func testVerboseAndPartialOutput(runningIn directory: URL) throws {
        let probe = ProgressSnapshotProbe()
        let runner = ProgressTaskRunner { probe.snapshots.append($0) }
        try runner.run(command: #"/usr/bin/yes noise | /usr/bin/head -c 2200000; printf '\n'; /usr/bin/head -c 20000 /dev/zero | /usr/bin/tr '\0' x; printf 'SIDEPULSE_PROGRESS=99\n'; printf 'SIDEPULSE_PROGRESS=88\n' >&2; printf 'SIDEPULSE_PRO'; sleep 0.2; printf 'GRESS=42'"#, directory: directory)
        waitUntil(timeout: 5, label: "verbose completion") { runner.snapshot.phase == .completed }
        precondition(runner.snapshot.fraction == 0.42)
        precondition(!probe.snapshots.contains { $0.fraction == 0.99 || $0.fraction == 0.88 })
        let bytes = try FileManager.default.attributesOfItem(atPath: runner.snapshot.logURL!.path)[.size] as! NSNumber
        precondition(bytes.intValue == 2 * 1024 * 1024, "Log should stop at its limit while parsing continues")
        runner.clear()
    }

    @MainActor
    private static func testInheritedPipes(runningIn directory: URL) throws {
        let runner = ProgressTaskRunner { _ in }
        try runner.run(command: "(sleep 2) & printf 'done\\n'", directory: directory)
        waitUntil(timeout: 1.8, label: "completion despite inherited pipes") { runner.snapshot.phase == .completed }
        runner.clear()
    }

    private static func processIsRunning(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != UInt32(SZOMB)
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval, label: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(condition(), "Timed out waiting for \(label)")
    }
}
