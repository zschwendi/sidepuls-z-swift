import Darwin
import Foundation

private final class RuntimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var agents: [AgentSession] = []
    private(set) var integrations: [AgentIntegrationStatus] = []

    func record(agents: [AgentSession], integrations: [AgentIntegrationStatus]) {
        lock.lock()
        self.agents = agents
        self.integrations = integrations
        lock.unlock()
    }

    func snapshot() -> ([AgentSession], [AgentIntegrationStatus]) {
        lock.lock()
        defer { lock.unlock() }
        return (agents, integrations)
    }
}

@main
enum AgentRuntimeSmoke {
    static func main() throws {
        testCompletionAcknowledgements()

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "sidepulse-runtime-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let codexHome = temporaryRoot.appending(path: "codex", directoryHint: .isDirectory)
        let transcriptFolder = datedTranscriptFolder(codexHome: codexHome, date: .now)
        try FileManager.default.createDirectory(at: transcriptFolder, withIntermediateDirectories: true)
        let completedID = "runtime-smoke-completed-\(UUID().uuidString)"
        let abortedID = "runtime-smoke-aborted-\(UUID().uuidString)"
        let toolID = "runtime-smoke-tool-\(UUID().uuidString)"
        let completedURL = transcriptFolder.appending(path: "completed.jsonl")
        try writeTranscript(url: completedURL, id: completedID, payload: ["type": "task_complete"])
        try writeTranscript(url: transcriptFolder.appending(path: "aborted.jsonl"), id: abortedID, payload: [
            "type": "turn_aborted",
            "reason": "interrupted",
        ])
        try writeTranscript(
            url: transcriptFolder.appending(path: "tool.jsonl"),
            id: toolID,
            recordType: "response_item",
            payload: ["type": "custom_tool_call", "name": "exec"]
        )

        setenv("SIDEPULSE_EVENT_SOCKET_PATH", temporaryRoot.appending(path: "events.sock").path, 1)
        setenv("SIDEPULSE_LATEST_STATE_PATH", temporaryRoot.appending(path: "latest.json").path, 1)
        setenv("CODEX_HOME", codexHome.path, 1)
        defer {
            unsetenv("SIDEPULSE_EVENT_SOCKET_PATH")
            unsetenv("SIDEPULSE_LATEST_STATE_PATH")
            unsetenv("CODEX_HOME")
        }

        let probe = RuntimeProbe()
        let detected = DispatchSemaphore(value: 0)
        let runtime = NativeAgentRuntime(
            policy: AgentRuntimePolicy(
                completedHoldSeconds: 10,
                postToolHoldSeconds: 0.1,
                toolTimeoutSeconds: 0.1
            )
        ) { agents, _, integrations in
            probe.record(agents: agents, integrations: integrations)
            let states = Dictionary(uniqueKeysWithValues: agents.map { ($0.sessionID, $0.state) })
            if states[completedID] == .completed,
               states[abortedID] == .error,
               states[toolID] == .toolRunning {
                detected.signal()
            }
        }

        runtime.start()
        let result = detected.wait(timeout: .now() + 3)
        precondition(result == .success, "Expected deterministic local Codex fixtures")

        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-20 * 60)],
            ofItemAtPath: completedURL.path
        )
        Thread.sleep(forTimeInterval: 2)
        var (agents, integrations) = probe.snapshot()
        precondition(
            agents.contains(where: { $0.sessionID == completedID && $0.state == .completed }),
            "Unacknowledged completion must survive the 15-minute discovery window"
        )
        precondition(
            agents.contains(where: { $0.sessionID == toolID && $0.state == .toolRunning }),
            "A long tool call must not become an inferred failure"
        )
        precondition(
            agents.contains(where: { $0.sessionID == abortedID && $0.state == .error }),
            "An aborted Codex turn must be red, not successful green"
        )

        runtime.acknowledgeCompleted(sessionID: "codex:session:\(completedID)")
        Thread.sleep(forTimeInterval: 0.5)
        (agents, integrations) = probe.snapshot()
        precondition(
            !agents.contains(where: { $0.sessionID == completedID }),
            "Explicitly selecting the finished session must acknowledge it"
        )
        runtime.stop()

        precondition(
            integrations.contains(where: { $0.provider == .codex && $0.state == .active }),
            "Expected Codex integration to report active"
        )
        precondition(
            agents.first(where: { $0.provider == .codex })?.openURL?.scheme == "codex",
            "Local Codex sessions must expose a selectable desktop deep link"
        )
        print("Agent runtime smoke passed: explicit states persist until explicit acknowledgement")
    }

    private static func datedTranscriptFolder(codexHome: URL, date: Date) -> URL {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return codexHome
            .appending(path: "sessions", directoryHint: .isDirectory)
            .appending(path: String(format: "%04d", components.year!), directoryHint: .isDirectory)
            .appending(path: String(format: "%02d", components.month!), directoryHint: .isDirectory)
            .appending(path: String(format: "%02d", components.day!), directoryHint: .isDirectory)
    }

    private static func writeTranscript(
        url: URL,
        id: String,
        recordType: String = "event_msg",
        payload: [String: Any]
    ) throws {
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/SidePulse"]],
            ["type": recordType, "payload": payload],
        ]
        let data = try records.reduce(into: Data()) { result, record in
            result.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            result.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func testCompletionAcknowledgements() {
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var finished = AgentSession(
            id: "codex:finished",
            provider: .codex,
            sessionID: "finished",
            name: "Finished run",
            project: "SidePulse",
            cwd: nil,
            state: .completed,
            eventName: "CodexTurnComplete",
            toolName: nil,
            updatedAt: finishedAt,
            message: nil
        )
        var acknowledgements = CompletionAcknowledgements()
        precondition(acknowledgements.shouldDisplay(finished), "Unacknowledged success must stay visible")
        precondition(acknowledgements.acknowledge([finished], at: finishedAt.addingTimeInterval(1)))
        precondition(!acknowledgements.shouldDisplay(finished), "Acknowledged success must clear")

        let suiteName = "sidepulse.runtime-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        acknowledgements.save(to: defaults)
        let restored = CompletionAcknowledgements.load(from: defaults)
        defaults.removePersistentDomain(forName: suiteName)
        precondition(!restored.shouldDisplay(finished), "Acknowledgements must survive an app relaunch")

        finished.state = .working
        finished.updatedAt = finishedAt.addingTimeInterval(2)
        precondition(acknowledgements.shouldDisplay(finished), "A new run must override the previous acknowledgement")
        finished.state = .completed
        finished.updatedAt = finishedAt.addingTimeInterval(3)
        precondition(acknowledgements.shouldDisplay(finished), "A later completion must become green again")
    }
}
