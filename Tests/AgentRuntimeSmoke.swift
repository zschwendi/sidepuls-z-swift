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
        testGrokBotInferenceStability()

        let temporaryRoot = URL(
            fileURLWithPath: "/tmp/sidepulse-runtime-smoke-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let codexHome = temporaryRoot.appending(path: "codex", directoryHint: .isDirectory)
        let transcriptFolder = datedTranscriptFolder(codexHome: codexHome, date: .now)
        try FileManager.default.createDirectory(at: transcriptFolder, withIntermediateDirectories: true)
        let completedID = "runtime-smoke-completed-\(UUID().uuidString)"
        let abortedID = "runtime-smoke-aborted-\(UUID().uuidString)"
        let toolID = "runtime-smoke-tool-\(UUID().uuidString)"
        let recoverableID = "runtime-smoke-recoverable-\(UUID().uuidString)"
        let grokHookID = "runtime-smoke-grok-hook-\(UUID().uuidString)"
        let grokBotID = UUID().uuidString
        let staleHookID = "runtime-smoke-stale-hook-\(UUID().uuidString)"
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
        let grokBotPersistence = temporaryRoot.appending(path: "grok-bot", directoryHint: .isDirectory)
        try writeGrokBotFixture(root: grokBotPersistence, sessionID: grokBotID)

        let socketPath = temporaryRoot.appending(path: "events.sock").path
        let latestStateURL = temporaryRoot.appending(path: "latest.json")
        try writeLegacyState(url: latestStateURL, staleHookID: staleHookID)
        setenv("SIDEPULSE_EVENT_SOCKET_PATH", socketPath, 1)
        setenv("SIDEPULSE_LATEST_STATE_PATH", latestStateURL.path, 1)
        setenv("CODEX_HOME", codexHome.path, 1)
        setenv("GROK_BOT_PERSISTENCE_PATH", grokBotPersistence.path, 1)
        defer {
            unsetenv("SIDEPULSE_EVENT_SOCKET_PATH")
            unsetenv("SIDEPULSE_LATEST_STATE_PATH")
            unsetenv("CODEX_HOME")
            unsetenv("GROK_BOT_PERSISTENCE_PATH")
        }

        let probe = RuntimeProbe()
        let detected = DispatchSemaphore(value: 0)
        let runtime = NativeAgentRuntime { agents, _, integrations in
            probe.record(agents: agents, integrations: integrations)
            let states = Dictionary(uniqueKeysWithValues: agents.map { ($0.sessionID, $0.state) })
            if states[completedID] == .completed,
               states[abortedID] == .error,
               states[toolID] == .toolRunning,
               states[grokBotID] == .waiting {
                detected.signal()
            }
        }

        runtime.start()
        let result = detected.wait(timeout: .now() + 3)
        precondition(result == .success, "Expected deterministic local Codex fixtures")

        try sendHook(
            path: socketPath,
            provider: "grok",
            eventName: "UserPromptSubmit",
            sessionID: grokHookID,
            toolResponse: [:]
        )
        precondition(
            waitForState(probe: probe, sessionID: grokHookID, state: .working),
            "Expected the separate Grok hook provider to remain active"
        )

        try sendHook(
            path: socketPath,
            eventName: "PostToolUse",
            sessionID: recoverableID,
            toolResponse: ["isError": false, "output": "error.log failed string in successful output"]
        )
        precondition(
            waitForState(probe: probe, sessionID: recoverableID, state: .working),
            "Successful tool output containing failure words must remain Thinking"
        )
        for eventName in ["PostToolUseFailure", "PermissionDenied", "StopFailure"] {
            try sendHook(
                path: socketPath,
                eventName: eventName,
                sessionID: recoverableID,
                toolResponse: ["isError": true, "output": "The tool failed"]
            )
            precondition(
                waitForState(probe: probe, sessionID: recoverableID, state: .working),
                "\(eventName) is recoverable and must not turn the run red"
            )
        }

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
            "A tool call must stay a tool until an explicit output event"
        )
        precondition(
            agents.contains(where: { $0.sessionID == abortedID && $0.state == .error }),
            "An aborted Codex turn must be red, not successful green"
        )
        precondition(
            agents.contains(where: { $0.sessionID == grokBotID && $0.provider == .grokBot && $0.state == .waiting }),
            "Grok Bot local sessions must merge into the hub as a distinct provider"
        )
        precondition(
            agents.contains(where: { $0.sessionID == grokHookID && $0.provider == .grok }),
            "Grok hooks and Grok Bot must remain separate providers"
        )
        precondition(
            !agents.contains(where: { $0.sessionID == staleHookID }),
            "Abandoned hook activity must not keep the unified signal Thinking forever"
        )
        precondition(
            agents.first(where: { $0.sessionID == toolID })?.openURL?.scheme == "codex",
            "Local Codex sessions must expose a selectable desktop deep link"
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
            integrations.contains(where: { $0.provider == .grokBot && $0.state == .active }),
            "Expected Grok Bot local discovery to report active"
        )
        print("Agent runtime smoke passed: Codex, Grok hooks, and Grok Bot merge without conflating providers")
    }

    private static func waitForState(
        probe: RuntimeProbe,
        sessionID: String,
        state: AgentState,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if probe.snapshot().0.contains(where: { $0.sessionID == sessionID && $0.state == state }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return false
    }

    private static func sendHook(
        path: String,
        provider: String = "codex",
        eventName: String,
        sessionID: String,
        toolResponse: [String: Any]
    ) throws {
        let payload: [String: Any] = [
            "provider": provider,
            "line": [
                "hook_event_name": eventName,
                "session_id": sessionID,
                "cwd": "/tmp/SidePulse",
                "logged_at": ISO8601DateFormatter().string(from: .now),
                "tool_name": "Smoke Tool",
                "tool_response": toolResponse,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(client >= 0, "Expected a Unix socket client")
        defer { Darwin.close(client) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(connected == 0, "Expected the runtime event socket to accept hooks")
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(client, bytes.baseAddress, bytes.count)
        }
        precondition(written == data.count, "Expected the complete hook payload to be written")
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

    private static func writeGrokBotFixture(root: URL, sessionID: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let nowMilliseconds = Int(Date.now.timeIntervalSince1970 * 1_000)
        let roster: [String: Any] = [
            "schemaVersion": 2,
            "value": [
                "rows": [[
                    "id": sessionID,
                    "name": "Grok Bot fixture",
                    "updatedAt": nowMilliseconds,
                    "lastActivityAt": nowMilliseconds,
                    "awaitingUserResponse": true,
                ]],
            ],
        ]
        let transcript: [String: Any] = [
            "schemaVersion": 1,
            "value": [
                "persistedAt": nowMilliseconds,
                "entries": [[
                    "id": "permission-fixture",
                    "kind": "send-message",
                    "timestampMs": nowMilliseconds,
                    "message": [
                        "type": "local-tool-permission",
                        "ask": ["status": "pending", "action": "run-command"],
                    ],
                ]],
            ],
        ]
        try writeGrokBotBlob(
            root: root,
            key: "sidepulse.roster.last-roster",
            document: roster
        )
        try writeGrokBotBlob(
            root: root,
            key: "sidepulse.transcript.replicas.\(sessionID)",
            document: transcript
        )
    }

    private static func testGrokBotInferenceStability() {
        let runtime = NativeAgentRuntime { _, _, _ in }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func milliseconds(_ date: Date) -> Int {
            Int(date.timeIntervalSince1970 * 1_000)
        }

        func responseTranscript(at date: Date, persistedAt: Date? = nil) -> [String: Any] {
            [
                "value": [
                    "persistedAt": milliseconds(persistedAt ?? date),
                    "entries": [[
                        "kind": "send-message",
                        "timestampMs": milliseconds(date),
                        "message": ["type": "text", "content": "fixture"],
                    ]],
                ],
            ]
        }

        let chunkPause = now.addingTimeInterval(-12)
        let active = runtime.inferGrokBotActivity(
            row: ["lastActivityAt": milliseconds(chunkPause), "hasUnread": false],
            transcript: responseTranscript(at: chunkPause),
            now: now
        )
        precondition(
            active.state == .working,
            "Grok Bot must remain active across normal pauses between response chunks"
        )

        let settledAt = now.addingTimeInterval(-31)
        let settled = runtime.inferGrokBotActivity(
            row: ["lastActivityAt": milliseconds(settledAt), "hasUnread": false],
            transcript: responseTranscript(at: settledAt),
            now: now
        )
        precondition(settled.state == .completed, "Quiet Grok Bot responses must settle to Done")

        let oldActivity = now.addingTimeInterval(-60 * 60)
        let rewritten = runtime.inferGrokBotActivity(
            row: ["lastActivityAt": milliseconds(oldActivity), "hasUnread": false],
            transcript: responseTranscript(at: oldActivity, persistedAt: now),
            now: now
        )
        precondition(
            rewritten.state == .completed && rewritten.updatedAt == oldActivity,
            "A persistence rewrite must not make an old Grok Bot session active again"
        )

        let unread = runtime.inferGrokBotActivity(
            row: ["lastActivityAt": milliseconds(now), "hasUnread": true],
            transcript: responseTranscript(at: now),
            now: now
        )
        precondition(unread.state == .completed, "Unread Grok Bot output is explicit completion evidence")
    }

    private static func writeLegacyState(url: URL, staleHookID: String) throws {
        let staleDate = Date.now.addingTimeInterval(-16 * 60)
        let payload: [String: Any] = [
            "statuses": [[
                "provider": "codex",
                "agent_id": "codex:agent:\(staleHookID)",
                "display_name": "Abandoned hook fixture",
                "mode": "working",
                "updated_at": ISO8601DateFormatter().string(from: staleDate),
                "event_name": "PostToolUse",
                "session_id": staleHookID,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func writeGrokBotBlob(
        root: URL,
        key: String,
        document: [String: Any]
    ) throws {
        let filename = base32Encode(Data(key.utf8)).lowercased() + ".blob"
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try data.write(to: root.appending(path: filename), options: .atomic)
    }

    private static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer = 0
        var bitCount = 0
        var result = ""
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                result.append(alphabet[(buffer >> bitCount) & 31])
                buffer = bitCount == 0 ? 0 : buffer & ((1 << bitCount) - 1)
            }
        }
        if bitCount > 0 { result.append(alphabet[(buffer << (5 - bitCount)) & 31]) }
        return result
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
