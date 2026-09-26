import Darwin
import Foundation

private final class DiscoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[AgentSession]] = []
    private var latest: [AgentSession] = []

    func record(_ agents: [AgentSession]) {
        lock.lock()
        snapshots.append(agents)
        latest = agents
        lock.unlock()
    }

    func current() -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func drain() -> [[AgentSession]] {
        lock.lock()
        defer { lock.unlock() }
        let result = snapshots
        snapshots.removeAll()
        return result
    }
}

@main
enum AgentDiscoverySmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let latest = root.appendingPathComponent("latest.json")
        let socket = root.appendingPathComponent("events.sock").path
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Keep every runtime data source inside this disposable fixture.
        let environment = [
            "CODEX_HOME": codexHome.path,
            "SIDEPULSE_LATEST_STATE_PATH": latest.path,
            "SIDEPULSE_EVENT_SOCKET_PATH": socket,
            "SIDEPULSE_CODEX_IPC_SOCKET_PATH": root.appendingPathComponent("absent.sock").path,
            "GROK_BOT_PERSISTENCE_PATH": root.appendingPathComponent("grok").path,
        ]
        let previous = ProcessInfo.processInfo.environment
        for (key, value) in environment { setenv(key, value, 1) }
        defer {
            for key in environment.keys {
                if let value = previous[key] { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }

        let probe = DiscoveryProbe()
        let runtime = NativeAgentRuntime(cloudDiscoveryEnabled: false) { agents, _, _ in probe.record(agents) }
        let now = Date.now
        let olderFolder = sessionsRoot.appendingPathComponent("2020/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: olderFolder, withIntermediateDirectories: true)
        let resumed = olderFolder.appendingPathComponent("resumed.jsonl")
        let dormant = olderFolder.appendingPathComponent("dormant.jsonl")
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        try Data("{\"id\":\"resumed\",\"thread_name\":\"Resumed fixture\"}\n".utf8)
            .write(to: index, options: .atomic)
        try writeTranscript(resumed, id: "resumed", event: "task_started")
        try writeTranscript(dormant, id: "dormant", event: "task_complete")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)],
                                              ofItemAtPath: dormant.path)
        // Simulate another SidePulse process owning hooks and writing an incomplete snapshot.
        let owner = listeningSocket(path: socket)
        defer { Darwin.close(owner) }
        try Data(#"{"statuses":[]}"#.utf8).write(to: latest, options: .atomic)
        runtime.start()
        defer { runtime.stop() }
        precondition(waitFor(probe, id: "resumed", state: .working),
                     "Resumed tasks must be discovered in their original date folder")
        precondition(!probe.current().contains(where: { $0.sessionID == "dormant" }),
                     "Old inactive transcripts must stay outside the discovery window")

        // Force tracking through the retained URL, outside the recent-file window.
        let olderModification = now.addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: olderModification], ofItemAtPath: resumed.path)
        Thread.sleep(forTimeInterval: 2.5)
        try writeTranscript(resumed, id: "resumed", event: "task_complete")
        try FileManager.default.setAttributes([.modificationDate: olderModification], ofItemAtPath: resumed.path)
        precondition(waitFor(probe, id: "resumed", state: .completed),
                     "A retained transcript URL must see later writes")

        let added = olderFolder.appendingPathComponent("added-while-running.jsonl")
        try writeTranscript(added, id: "newly-observed", event: "task_started")
        precondition(waitFor(probe, id: "newly-observed", state: .working),
                     "A session created after startup must appear without restarting the monitor")

        try Data("{\"id\":\"newly-observed\",\"thread_name\":\"Named after discovery\"}\n".utf8)
            .write(to: index, options: .atomic)
        let nameDeadline = Date.now.addingTimeInterval(4)
        while Date.now < nameDeadline,
              !probe.current().contains(where: { $0.name == "Named after discovery" }) {
            Thread.sleep(forTimeInterval: 0.025)
        }
        precondition(probe.current().contains(where: { $0.name == "Named after discovery" }),
                     "Task titles written after discovery must refresh from the session index")

        _ = probe.drain()
        try Data(#"{"statuses":[]}"#.utf8).write(to: latest, options: .atomic)
        Thread.sleep(forTimeInterval: 2.5)
        let refreshed = probe.drain()
        precondition(!refreshed.isEmpty, "The shared snapshot refresh should publish")
        precondition(refreshed.allSatisfy { $0.contains(where: { $0.sessionID == "newly-observed" }) },
                     "A companion snapshot must never erase locally discovered activity, even for one update")

        let sharedStatuses: [[String: Any]] = [
            [
                "provider": "codex", "agent_id": "codex:session:newly-observed",
                "session_id": "newly-observed", "display_name": "Outdated companion entry",
                "mode": "completed", "updated_at": "2000-01-01T00:00:00Z", "event_name": "Stop",
            ],
            [
                "provider": "claude", "agent_id": "claude:session:shared-hook",
                "session_id": "shared-hook", "display_name": "Shared hook fixture",
                "mode": "working", "updated_at": ISO8601DateFormatter().string(from: .now),
                "event_name": "UserPromptSubmit",
            ],
        ]
        try JSONSerialization.data(withJSONObject: ["statuses": sharedStatuses])
            .write(to: latest, options: .atomic)
        Thread.sleep(forTimeInterval: 2.5)
        let merged = probe.drain()
        precondition(merged.contains(where: { $0.contains(where: { $0.sessionID == "shared-hook" }) }),
                     "Companion hook-only sessions must still be imported")
        precondition(merged.allSatisfy {
            $0.contains(where: { $0.sessionID == "newly-observed" && $0.state == .working })
        }, "An older companion entry must not replace the current local state")
        print("Agent discovery smoke passed: resumed tasks, fresh metadata, new sessions, titles and companion snapshots")
    }

    private static func waitFor(_ probe: DiscoveryProbe, id: String, state: AgentState) -> Bool {
        let deadline = Date.now.addingTimeInterval(4)
        while Date.now < deadline {
            if probe.drain().contains(where: { $0.contains(where: { $0.sessionID == id && $0.state == state }) }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return false
    }

    private static func writeTranscript(_ url: URL, id: String, event: String) throws {
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/discovery-fixture"]],
            ["type": "event_msg", "payload": ["type": event]],
        ]
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func listeningSocket(path: String) -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(socket >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && Darwin.listen(socket, 4) == 0)
        return socket
    }
}
