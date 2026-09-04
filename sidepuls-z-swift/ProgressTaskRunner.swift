import Foundation
import Darwin

enum ProgressTaskPhase: String, Codable, Sendable {
    case idle
    case running
    case completed
    case failed
    case cancelled
}

struct ProgressTaskSnapshot: Equatable, Sendable {
    let phase: ProgressTaskPhase
    let title: String
    let fraction: Double?
    let exitCode: Int32?
    let detail: String
    let logURL: URL?

    static let idle = ProgressTaskSnapshot(
        phase: .idle,
        title: "",
        fraction: nil,
        exitCode: nil,
        detail: "",
        logURL: nil
    )
}

enum ProgressTaskRunnerError: LocalizedError, Equatable {
    case emptyCommand
    case invalidDirectory(URL)
    case alreadyRunning
    case invalidPID(Int32)
    case processNotFound(Int32)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Enter a command to run."
        case .invalidDirectory(let directory):
            return "The working directory does not exist: \(directory.path)"
        case .alreadyRunning:
            return "A progress task is already running."
        case .invalidPID(let pid):
            return "The process ID is invalid: \(pid)"
        case .processNotFound(let pid):
            return "The process could not be found: \(pid)"
        case .launchFailed(let reason):
            return "The progress task could not start: \(reason)"
        }
    }
}

@MainActor
final class ProgressTaskRunner {
    typealias ChangeHandler = @MainActor @Sendable (ProgressTaskSnapshot) -> Void

    private struct ProcessIdentity: Equatable, Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct SpawnedProcess {
        let pid: pid_t
        let stdout: FileHandle
        let stderr: FileHandle
        let processGroupID: pid_t?
        let initialExitCode: Int32?
    }

    private enum ActiveTask {
        case owned(id: UUID, pid: pid_t, identity: ProcessIdentity?, processGroupID: pid_t?)
        case watched(id: UUID, identity: ProcessIdentity)

        var id: UUID {
            switch self {
            case .owned(let id, _, _, _), .watched(let id, _):
                return id
            }
        }

    }

    private let onChange: ChangeHandler
    private(set) var snapshot = ProgressTaskSnapshot.idle

    private var activeTask: ActiveTask?
    private var outputCapture: ProgressOutputCapture?
    private var processPollTask: Task<Void, Never>?
    private var watchPollTask: Task<Void, Never>?
    private var processExitCode: Int32?
    private var cancellationRequested = false

    init(onChange: @escaping ChangeHandler) {
        self.onChange = onChange
        onChange(.idle)
    }

    func run(command: String, directory: URL) throws {
        guard activeTask == nil else { throw ProgressTaskRunnerError.alreadyRunning }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw ProgressTaskRunnerError.emptyCommand }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ProgressTaskRunnerError.invalidDirectory(directory)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProgressTaskRunnerError.invalidDirectory(directory)
        }

        resetFinishedTask()

        let taskID = UUID()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidepulse-progress-\(taskID.uuidString)")
            .appendingPathExtension("log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw ProgressTaskRunnerError.launchFailed("Could not create a temporary log file.")
        }

        let spawned: SpawnedProcess
        do {
            spawned = try spawnOwnedProcess(command: command, directory: directory)
        } catch let error as ProgressTaskRunnerError {
            try? FileManager.default.removeItem(at: logURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: logURL)
            throw ProgressTaskRunnerError.launchFailed(error.localizedDescription)
        }

        let capture: ProgressOutputCapture
        do {
            capture = try ProgressOutputCapture(
                logURL: logURL,
                stdout: spawned.stdout,
                stderr: spawned.stderr,
                onProgress: { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.receiveProgress(value, taskID: taskID)
                    }
                },
                onFinished: { [weak self] finalProgress in
                    Task { @MainActor [weak self] in
                        self?.finishOutput(taskID: taskID, finalProgress: finalProgress)
                    }
                }
            )
        } catch {
            terminateSpawnedProcess(spawned)
            try? FileManager.default.removeItem(at: logURL)
            throw ProgressTaskRunnerError.launchFailed(error.localizedDescription)
        }

        activeTask = .owned(
            id: taskID,
            pid: spawned.pid,
            identity: processIdentity(for: spawned.pid),
            processGroupID: spawned.processGroupID
        )
        outputCapture = capture
        cancellationRequested = false
        processExitCode = spawned.initialExitCode
        capture.start()
        publish(
            ProgressTaskSnapshot(
                phase: .running,
                title: command,
                fraction: nil,
                exitCode: nil,
                detail: "Running in \(directory.path)",
                logURL: logURL
            )
        )
        startProcessPolling(taskID: taskID)
    }

    func watch(pid: Int32) throws {
        guard activeTask == nil else { throw ProgressTaskRunnerError.alreadyRunning }
        guard pid > 0 else { throw ProgressTaskRunnerError.invalidPID(pid) }
        guard let identity = processIdentity(for: pid) else {
            throw ProgressTaskRunnerError.processNotFound(pid)
        }

        resetFinishedTask()
        let taskID = UUID()
        activeTask = .watched(id: taskID, identity: identity)
        cancellationRequested = false
        processExitCode = nil
        publish(
            ProgressTaskSnapshot(
                phase: .running,
                title: "Process \(pid)",
                fraction: nil,
                exitCode: nil,
                detail: "Watching process \(pid)",
                logURL: nil
            )
        )
        startWatchPolling(taskID: taskID)
    }

    func cancel() {
        guard let activeTask else { return }
        switch activeTask {
        case .watched:
            watchPollTask?.cancel()
            watchPollTask = nil
            self.activeTask = nil
            publish(
                ProgressTaskSnapshot(
                    phase: .cancelled,
                    title: snapshot.title,
                    fraction: snapshot.fraction,
                    exitCode: nil,
                    detail: "Watch cancelled; the process was left running.",
                    logURL: snapshot.logURL
                )
            )
        case .owned(_, let pid, _, let processGroupID):
            cancellationRequested = true
            publish(ProgressTaskSnapshot(
                phase: .cancelled, title: snapshot.title, fraction: snapshot.fraction,
                exitCode: snapshot.exitCode, detail: "Cancelling…", logURL: snapshot.logURL
            ))
            // Signal before polling can reap the owned group leader. Retaining
            // our child PID until waitpid prevents its ID from being reused.
            signalOwnedProcess(pid: pid, processGroupID: processGroupID)
        }
    }

    func clear() {
        if case .owned = activeTask {
            cancel()
            return
        }

        stopTimers()
        outputCapture?.stop()
        outputCapture = nil
        activeTask = nil
        processExitCode = nil
        cancellationRequested = false
        if let logURL = snapshot.logURL {
            try? FileManager.default.removeItem(at: logURL)
        }
        publish(.idle)
    }

    /// Stops a command started by SidePulse before the app exits. A watched
    /// process is only detached from observation and is never signaled.
    func shutdown() {
        guard let activeTask else { return }
        switch activeTask {
        case .watched:
            stopTimers()
            self.activeTask = nil
        case .owned(_, let pid, _, let processGroupID):
            signalOwnedProcess(pid: pid, processGroupID: processGroupID)
            if processExitCode == nil {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
            stopTimers()
            outputCapture?.stop()
            outputCapture = nil
            self.activeTask = nil
            processExitCode = nil
            cancellationRequested = false
        }
    }

    private func startProcessPolling(taskID: UUID) {
        processPollTask?.cancel()
        processPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.activeTask?.id == taskID else { return }
                guard case .owned(_, let pid, let identity, let processGroupID) = self.activeTask else { return }
                if let knownExitCode = self.processExitCode {
                    self.processPollTask = nil
                    self.outputCapture?.markProcessExited()
                    self.processExitCode = knownExitCode
                    self.scheduleBoundedOutputFinish(taskID: taskID)
                    return
                }
                if identity == nil, let refreshedIdentity = self.processIdentity(for: pid) {
                    self.activeTask = .owned(id: taskID, pid: pid, identity: refreshedIdentity, processGroupID: processGroupID)
                }
                var waitStatus: Int32 = 0
                let waitResult = waitpid(pid, &waitStatus, WNOHANG)
                guard waitResult != 0 else { continue }
                self.processPollTask = nil
                if waitResult < 0 && errno == EINTR { continue }
                self.processExitCode = waitResult == pid ? Self.exitCode(from: waitStatus) : 127
                self.outputCapture?.markProcessExited()
                self.scheduleBoundedOutputFinish(taskID: taskID)
                return
            }
        }
    }

    private func startWatchPolling(taskID: UUID) {
        watchPollTask?.cancel()
        watchPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.activeTask?.id == taskID else { return }
                guard case .watched(_, let identity) = self.activeTask else { return }
                guard let currentIdentity = self.processIdentity(for: identity.pid), currentIdentity == identity else {
                    self.watchPollTask = nil
                    self.activeTask = nil
                    self.publish(
                        ProgressTaskSnapshot(
                            phase: .completed,
                            title: self.snapshot.title,
                            fraction: nil,
                            exitCode: nil,
                            detail: "Process \(identity.pid) exited; exit status unavailable.",
                            logURL: nil
                        )
                    )
                    return
                }
            }
        }
    }

    private func receiveProgress(_ value: Int, taskID: UUID) {
        guard activeTask?.id == taskID, (snapshot.phase == .running || snapshot.phase == .cancelled) else { return }
        publish(
            ProgressTaskSnapshot(
                phase: snapshot.phase,
                title: snapshot.title,
                fraction: Double(value) / 100,
                exitCode: snapshot.exitCode,
                detail: snapshot.detail,
                logURL: snapshot.logURL
            )
        )
    }

    private func finishOutput(taskID: UUID, finalProgress: Int?) {
        guard activeTask?.id == taskID else { return }
        guard case .owned = activeTask else { return }
        let exitCode = processExitCode
        guard let exitCode else { return }
        let phase: ProgressTaskPhase
        let detail: String
        if cancellationRequested {
            phase = .cancelled
            detail = "Cancelled (exit status \(exitCode))."
        } else if exitCode == 0 {
            phase = .completed
            detail = "Completed successfully."
        } else {
            phase = .failed
            detail = "Exited with status \(exitCode)."
        }
        let taskSnapshot = ProgressTaskSnapshot(
            phase: phase,
            title: snapshot.title,
            fraction: finalProgress.map { Double($0) / 100 } ?? snapshot.fraction,
            exitCode: exitCode,
            detail: detail,
            logURL: snapshot.logURL
        )
        stopTimers()
        outputCapture?.stop()
        outputCapture = nil
        activeTask = nil
        processExitCode = nil
        cancellationRequested = false
        publish(taskSnapshot)
    }

    private func scheduleBoundedOutputFinish(taskID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.activeTask?.id == taskID else { return }
            self.outputCapture?.forceFinish()
        }
    }

    private func resetFinishedTask() {
        stopTimers()
        outputCapture?.stop()
        outputCapture = nil
        if let logURL = snapshot.logURL {
            try? FileManager.default.removeItem(at: logURL)
        }
        snapshot = .idle
        processExitCode = nil
        cancellationRequested = false
    }

    private func stopTimers() {
        processPollTask?.cancel()
        processPollTask = nil
        watchPollTask?.cancel()
        watchPollTask = nil
    }

    private func publish(_ next: ProgressTaskSnapshot) {
        snapshot = next
        onChange(next)
    }

    private func spawnOwnedProcess(command: String, directory: URL) throws -> SpawnedProcess {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closePipeHandles(stdoutPipe, stderrPipe)
            throw ProgressTaskRunnerError.launchFailed("Could not prepare output pipes.")
        }
        defer { _ = posix_spawn_file_actions_destroy(&actions) }

        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor
        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutRead),
            posix_spawn_file_actions_addclose(&actions, stderrRead),
        ]
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            closePipeHandles(stdoutPipe, stderrPipe)
            throw ProgressTaskRunnerError.launchFailed("Could not prepare output redirection.")
        }
        if stdoutWrite != STDOUT_FILENO {
            guard posix_spawn_file_actions_addclose(&actions, stdoutWrite) == 0 else {
                closePipeHandles(stdoutPipe, stderrPipe)
                throw ProgressTaskRunnerError.launchFailed("Could not prepare stdout cleanup.")
            }
        }
        if stderrWrite != STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(&actions, stderrWrite) == 0 else {
                closePipeHandles(stdoutPipe, stderrPipe)
                throw ProgressTaskRunnerError.launchFailed("Could not prepare stderr cleanup.")
            }
        }
        guard directory.path.withCString({ path in
            posix_spawn_file_actions_addchdir(&actions, path)
        }) == 0 else {
            closePipeHandles(stdoutPipe, stderrPipe)
            throw ProgressTaskRunnerError.launchFailed("Could not set the working directory.")
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            closePipeHandles(stdoutPipe, stderrPipe)
            throw ProgressTaskRunnerError.launchFailed("Could not prepare process attributes.")
        }
        defer { _ = posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            closePipeHandles(stdoutPipe, stderrPipe)
            throw ProgressTaskRunnerError.launchFailed("Could not prepare process group ownership.")
        }

        let arguments = ["zsh", "-lc", command]
        let argumentPointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argumentPointers.forEach { if let pointer = $0 { free(pointer) } } }
        var pid: pid_t = 0
        let spawnResult = "/bin/zsh".withCString { executable in
            argumentPointers.withUnsafeBufferPointer { argumentBuffer in
                posix_spawn(
                    &pid,
                    executable,
                    &actions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environ
                )
            }
        }
        guard spawnResult == 0 else {
            closePipeHandles(stdoutPipe, stderrPipe)
            throw ProgressTaskRunnerError.launchFailed("posix_spawn failed (\(spawnResult)).")
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        let processGroupID = getpgid(pid) == pid ? pid : nil
        var initialExitCode: Int32?
        if processGroupID == nil {
            var waitStatus: Int32 = 0
            let waitResult = waitpid(pid, &waitStatus, WNOHANG)
            if waitResult == pid {
                initialExitCode = Self.exitCode(from: waitStatus)
            } else if waitResult == 0 {
                // The spawn attributes did not provide an owned group while
                // the shell is still alive. Kill only this verified child and
                // fail rather than retaining an un-cancellable task.
                _ = kill(pid, SIGKILL)
                _ = waitpid(pid, &waitStatus, 0)
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                throw ProgressTaskRunnerError.launchFailed("The spawned process did not receive its own process group.")
            }
        }
        if processGroupID == nil, initialExitCode == nil, processIdentity(for: pid) != nil || kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
            var waitStatus: Int32 = 0
            _ = waitpid(pid, &waitStatus, 0)
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw ProgressTaskRunnerError.launchFailed("The spawned process did not receive its own process group.")
        }
        return SpawnedProcess(
            pid: pid,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading,
            processGroupID: processGroupID,
            initialExitCode: initialExitCode
        )
    }

    private func terminateSpawnedProcess(_ spawned: SpawnedProcess) {
        if spawned.initialExitCode == nil {
            if spawned.processGroupID == spawned.pid, getpgid(spawned.pid) == spawned.pid {
                _ = kill(-spawned.pid, SIGKILL)
            } else {
                _ = kill(spawned.pid, SIGKILL)
            }
            var status: Int32 = 0
            while waitpid(spawned.pid, &status, 0) < 0 && errno == EINTR {}
        }
        try? spawned.stdout.close()
        try? spawned.stderr.close()
    }

    private func closePipeHandles(_ stdout: Pipe, _ stderr: Pipe) {
        try? stdout.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForReading.close()
        try? stderr.fileHandleForWriting.close()
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        if waitStatus & 0x7f == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + (waitStatus & 0x7f)
    }

    private func signalOwnedProcess(pid: pid_t, processGroupID: pid_t?) {
        // An unreaped direct child reserves this PID even after it exits.
        // Once reaped, never signal the old ID or its group.
        guard processExitCode == nil, processGroupID == pid,
              getpgid(pid) == pid else { return }
        _ = kill(-pid, SIGKILL)
    }

    private func processIdentity(for pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let receivedSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard receivedSize >= expectedSize, info.pbi_status != UInt32(SZOMB) else { return nil }
        return ProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }
}

private nonisolated final class ProgressOutputCapture: @unchecked Sendable {
    private static let maxLogBytes = 2 * 1024 * 1024
    private static let maxParserCharacters = 16 * 1024
    private static let readChunkBytes = 64 * 1024

    private let lock = NSLock()
    private let logHandle: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let onProgress: @Sendable (Int) -> Void
    private let onFinished: @Sendable (Int?) -> Void
    private var logBytesWritten = 0
    private var parserBuffer = Data()
    private var discardingLine = false
    private var endedStreams = Set<Int>()
    private var latestProgress: Int?
    private var processExited = false
    private var didFinish = false

    init(
        logURL: URL,
        stdout: FileHandle,
        stderr: FileHandle,
        onProgress: @escaping @Sendable (Int) -> Void,
        onFinished: @escaping @Sendable (Int?) -> Void
    ) throws {
        self.stdout = stdout
        self.stderr = stderr
        self.onProgress = onProgress
        self.onFinished = onFinished
        self.logHandle = try FileHandle(forWritingTo: logURL)
        for handle in [stdout, stderr] {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
    }

    func start() {
        stdout.readabilityHandler = { [weak self] _ in self?.readAvailable(stream: 0) }
        stderr.readabilityHandler = { [weak self] _ in self?.readAvailable(stream: 1) }
    }

    private func readAvailable(stream: Int) {
        lock.lock()
        guard !didFinish, !endedStreams.contains(stream) else { lock.unlock(); return }
        var bytes = [UInt8](repeating: 0, count: Self.readChunkBytes)
        let handle = stream == 0 ? stdout : stderr
        let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        let readError = errno
        lock.unlock()
        if count > 0 {
            consume(Data(bytes.prefix(count)), stream: stream)
        } else if count == 0 || (count < 0 && readError != EAGAIN && readError != EINTR) {
            handle.readabilityHandler = nil
            streamDidEnd(stream)
        }
    }

    func markProcessExited() {
        var shouldFinish = false
        var finalProgress: Int?
        lock.lock()
        processExited = true
        shouldFinish = markFinishedIfReadyLocked()
        finalProgress = shouldFinish ? latestProgress : nil
        lock.unlock()
        if shouldFinish { onFinished(finalProgress) }
    }

    func stop() {
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        lock.lock()
        if !didFinish {
            didFinish = true
            try? logHandle.close()
        }
        try? stdout.close()
        try? stderr.close()
        lock.unlock()
    }

    private func consume(_ data: Data, stream: Int) {
        var progress: Int?
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        if logBytesWritten < Self.maxLogBytes {
            let writable = data.prefix(Self.maxLogBytes - logBytesWritten)
            try? logHandle.write(contentsOf: writable)
            logBytesWritten += writable.count
        }
        if stream == 0 {
            for byte in data {
                if byte == 10 {
                    if !discardingLine,
                       let value = Self.progressValue(in: String(decoding: parserBuffer, as: UTF8.self)) {
                        progress = value
                        latestProgress = value
                    }
                    parserBuffer.removeAll(keepingCapacity: true)
                    discardingLine = false
                } else if !discardingLine {
                    if parserBuffer.count < Self.maxParserCharacters {
                        parserBuffer.append(byte)
                    } else {
                        parserBuffer.removeAll(keepingCapacity: true)
                        discardingLine = true
                    }
                }
            }
        }
        lock.unlock()
        // One update per read prevents verbose tasks flooding the main actor.
        if let progress { onProgress(progress) }
    }

    private func streamDidEnd(_ stream: Int) {
        var progressValues: [Int] = []
        var shouldFinish = false
        lock.lock()
        guard !didFinish, endedStreams.insert(stream).inserted else {
            lock.unlock()
            return
        }
        if stream == 0, !discardingLine,
           let value = Self.progressValue(in: String(decoding: parserBuffer, as: UTF8.self)) {
            progressValues.append(value)
            latestProgress = value
        }
        shouldFinish = markFinishedIfReadyLocked()
        let finalProgress = shouldFinish ? latestProgress : nil
        lock.unlock()

        for value in progressValues {
            onProgress(value)
        }
        if shouldFinish { onFinished(finalProgress) }
    }

    func forceFinish() {
        var progressValues: [Int] = []
        var finalProgress: Int?
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        processExited = true
        if !discardingLine, let value = Self.progressValue(in: String(decoding: parserBuffer, as: UTF8.self)) {
            progressValues.append(value)
            latestProgress = value
        }
        endedStreams = [0, 1]
        didFinish = true
        finalProgress = latestProgress
        try? logHandle.close()
        lock.unlock()

        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        try? stdout.close()
        try? stderr.close()
        for value in progressValues {
            onProgress(value)
        }
        onFinished(finalProgress)
    }

    private func markFinishedIfReadyLocked() -> Bool {
        guard processExited, endedStreams.count == 2, !didFinish else { return false }
        didFinish = true
        try? logHandle.close()
        return true
    }

    private static func progressValue(in line: String) -> Int? {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let prefix = "SIDEPULSE_PROGRESS="
        guard line.hasPrefix(prefix) else { return nil }
        let rawValue = String(line.dropFirst(prefix.count))
        guard !rawValue.isEmpty, rawValue.count <= 3,
              rawValue.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(rawValue), (0...100).contains(value) else {
            return nil
        }
        return value
    }
}
