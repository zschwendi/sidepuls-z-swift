import Darwin
import Foundation
import IOKit

/// One administrator-authorized companion per app lifetime. Commands travel
/// over a private socket: the helper validates the app's UID and PID, and the
/// app accepts only a root peer. The
/// companion only changes SleepDisabled, and owns cleanup after parent exit.
@MainActor
final class CoffeePowerProtect {
    typealias StatusHandler = @MainActor @Sendable (String, Bool) -> Void
    private let onStatus: StatusHandler
    private var wantsActive = false
    private var authorizationProcess: Process?
    private var connection: FileHandle?
    private var directory: String?
    private var generation = 0
    private var reader: Task<Void, Never>?

    init(onStatus: @escaping StatusHandler) { self.onStatus = onStatus }

    func start(allowAuthorization: Bool = false) {
        wantsActive = true
        if connection != nil { sendControl(true); return }
        guard authorizationProcess == nil else { return }
        guard allowAuthorization else {
            onStatus("Idle sleep prevented · Enable closed-lid protection", true)
            return
        }
        launch()
    }

    @discardableResult
    func stop() -> Bool {
        wantsActive = false
        sendControl(false)
        return connection != nil
    }

    private func launch() {
        guard let executable = Bundle.main.executableURL,
              Bundle.main.bundleIdentifier == "com.zephyrstudiosllc.sidepulse-z",
              Bundle.main.bundleURL.pathExtension == "app" else {
            onStatus("Closed-lid companion is unavailable", true)
            return
        }
        generation += 1
        let session = generation
        var template = Array("/tmp/sidepulse-coffee-XXXXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else {
            onStatus("Could not prepare closed-lid protection", true); return
        }
        let directory = String(cString: created)
        let path = directory + "/control"
        let listener = CoffeePowerSocket.listen(path: path)
        guard listener >= 0 else {
            try? FileManager.default.removeItem(atPath: directory)
            onStatus("Could not prepare closed-lid protection", true); return
        }
        self.directory = directory
        let ownerPID = getpid(), ownerUID = getuid()
        let command = [executable.path, "--sidepulse-coffee-power-protect", path,
                       String(ownerUID), String(ownerPID)]
            .map(Self.shellQuote).joined(separator: " ")
        let script = "with timeout of 2147483647 seconds\ndo shell script \(Self.appleScriptString(command)) with administrator privileges with prompt \(Self.appleScriptString("SidePulse Coffee needs permission to keep this Mac awake with its lid closed. The setting is restored when Coffee turns off or SidePulse exits."))\nend timeout"
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { [weak self] child in
            let failed = child.terminationStatus != 0
            Task { @MainActor [weak self] in
                guard let self, self.generation == session else { return }
                self.authorizationProcess = nil
                if self.connection == nil, self.wantsActive {
                    self.onStatus(failed ? "Closed-lid protection was not authorized · idle sleep only" : "Closed-lid companion stopped · idle sleep only", true)
                }
            }
        }
        do { try process.run() } catch {
            close(listener)
            try? FileManager.default.removeItem(atPath: directory)
            self.directory = nil
            onStatus("Could not request closed-lid protection", true)
            return
        }
        authorizationProcess = process
        onStatus("Waiting for macOS authorization · idle sleep only", false)
        Task { [weak self] in
            let socket = await Task.detached(priority: .utility) {
                defer { try? FileManager.default.removeItem(atPath: directory) }
                return CoffeePowerSocket.acceptRoot(listener: listener, timeout: 900) { process.isRunning }
            }.value
            guard let self, self.generation == session else {
                if socket >= 0 { close(socket) }
                return
            }
            self.directory = nil
            guard socket >= 0 else {
                if process.isRunning { process.terminate() }
                self.onStatus("Closed-lid connection expired · try enabling it again", true)
                return
            }
            let handle = FileHandle(fileDescriptor: socket, closeOnDealloc: true)
            self.connection = handle
            self.sendControl(self.wantsActive)
            self.reader = self.readStatus(handle, session: session)
        }
    }

    private func sendControl(_ enabled: Bool) {
        guard let connection else { return }
        do { try connection.write(contentsOf: Data(enabled ? [49] : [48])) }
        catch { connectionLost() }
    }

    private func readStatus(_ handle: FileHandle, session: Int) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    guard let self, self.generation == session else { return }
                    guard let event = CoffeePowerStatus(rawValue: line) else { continue }
                    if self.wantsActive || [.releasing, .releaseFailed, .released, .idle].contains(event) {
                        self.onStatus(event.message, false)
                    }
                }
            } catch { }
            guard let self, self.generation == session else { return }
            self.connectionLost()
        }
    }

    private func connectionLost() {
        try? connection?.close()
        connection = nil
        if wantsActive { onStatus("Closed-lid protection disconnected · idle sleep only", true) }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    deinit {
        reader?.cancel()
        if connection == nil { authorizationProcess?.terminate() }
        try? connection?.close()
        // Do not terminate the authorized companion: EOF is its cleanup signal.
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1, args[1] == "--sidepulse-coffee-power-protect" else { return false }
        guard args.count == 5, geteuid() == 0,
              let uid = uid_t(args[3]), uid != 0,
              let pid = pid_t(args[4]), pid > 1 else { return true }
        let descriptor = CoffeePowerSocket.connectToOwner(path: args[2], uid: uid, pid: pid)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        CoffeePowerGuardian.run(descriptor: descriptor)
        return true
    }
}

private enum CoffeePowerStatus: String {
    case externalProtection, awaitingState, applying, protected, failed, releasing, released, releaseFailed, idle
    var message: String {
        switch self {
        case .externalProtection: "Lid sleep blocked by an existing system setting"
        case .awaitingState: "Checking closed-lid protection · idle sleep only"
        case .applying: "Applying closed-lid protection…"
        case .protected: "Lid sleep blocked · verified by macOS"
        case .failed: "Could not block lid sleep · idle sleep only"
        case .releasing: "Restoring normal sleep…"
        case .releaseFailed: "Retrying restoration of normal sleep"
        case .released, .idle: "Closed-lid protection off"
        }
    }
}

private enum CoffeePowerGuardian {
    static func run(descriptor: Int32) {
        // The setting is global. Only one SidePulse companion may own it,
        // including across app copies and user sessions.
        let lock = open("/var/run/sidepulse-coffee-power-protect.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { return }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o777 == 0o600,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        var lease = CoffeePowerLease()
        var active = false, ended = false
        var lastStatus: String?
        while true {
            var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let result = poll(&pollFD, 1, 250)
            if result < 0 && errno != EINTR { ended = true; active = false }
            if result > 0 {
                var commands = [UInt8](repeating: 0, count: 64)
                let count = read(descriptor, &commands, commands.count)
                if count <= 0 { ended = true; active = false }
                else {
                    // Every control request receives a fresh state response,
                    // including a rapid off/on that coalesces into one read.
                    lastStatus = nil
                    for command in commands.prefix(count) {
                        if command == 49 { active = true }
                        if command == 48 { active = false }
                    }
                }
                if pollFD.revents & Int16(POLLHUP | POLLERR) != 0 { ended = true; active = false }
            }
            let state = readSleepDisabled()
            let event = active
                ? lease.observe(sleepDisabled: state, setDisabled: setSleepDisabled)
                : lease.cleanup(current: state, setDisabled: setSleepDisabled)
            let status = String(describing: event)
            if status != lastStatus {
                lastStatus = status
                let bytes = Array((status + "\n").utf8)
                _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            }
            if ended, !lease.ownsSleepDisable { return }
            if ended { Thread.sleep(forTimeInterval: 1) }
        }
    }

    nonisolated static func readSleepDisabled() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return nil }
        return value.boolValue
    }

    nonisolated static func setSleepDisabled(_ enabled: Bool) -> Bool {
        // No arbitrary command, path, setting, or argument arrives over IPC.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", enabled ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.025) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                return false
            }
            return process.terminationStatus == 0
        }
        catch { return false }
    }
}

/// The app creates its private directory; the privileged side only connects.
private enum CoffeePowerSocket {
    nonisolated static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        return address
    }

    nonisolated static func makeSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var value: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value)))
        }
        return fd
    }

    nonisolated static func listen(path: String) -> Int32 {
        guard var address = address(path) else { return -1 }
        let fd = makeSocket()
        guard fd >= 0 else { return -1 }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return -1 }
        return fd
    }

    nonisolated static func acceptRoot(listener: Int32, timeout: TimeInterval, authorizationPending: @Sendable () -> Bool) -> Int32 {
        defer { close(listener) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && authorizationPending() {
            var check = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&check, 1, 250) > 0 else { continue }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { continue }
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(fd, &uid, &gid) == 0 && uid == 0 {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                var value: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value)))
                return fd
            }
            close(fd)
        }
        return -1
    }

    nonisolated static func connectToOwner(path: String, uid: uid_t, pid: pid_t) -> Int32 {
        guard var address = address(path) else { return -1 }
        let fd = makeSocket()
        guard fd >= 0 else { return -1 }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var peerUID: uid_t = 0, peerGID: gid_t = 0, peerPID: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard connected == 0, getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == uid,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &size) == 0, peerPID == pid else {
            close(fd); return -1
        }
        return fd
    }
}
