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
}

@main
enum AgentRuntimeSmoke {
    static func main() throws {
        testCompletionAcknowledgements()

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "sidepulse-runtime-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        setenv("SIDEPULSE_EVENT_SOCKET_PATH", temporaryRoot.appending(path: "events.sock").path, 1)
        setenv("SIDEPULSE_LATEST_STATE_PATH", temporaryRoot.appending(path: "latest.json").path, 1)
        defer {
            unsetenv("SIDEPULSE_EVENT_SOCKET_PATH")
            unsetenv("SIDEPULSE_LATEST_STATE_PATH")
        }

        let probe = RuntimeProbe()
        let detected = DispatchSemaphore(value: 0)
        let runtime = NativeAgentRuntime(
            policy: AgentRuntimePolicy(
                completedHoldSeconds: 10,
                postToolHoldSeconds: 8,
                toolTimeoutSeconds: 45
            )
        ) { agents, _, integrations in
            probe.record(agents: agents, integrations: integrations)
            if agents.contains(where: { $0.provider == .codex }) { detected.signal() }
        }

        runtime.start()
        let result = detected.wait(timeout: .now() + 3)
        runtime.stop()

        precondition(result == .success, "Expected a recent local Codex session")
        precondition(
            probe.integrations.contains(where: { $0.provider == .codex && $0.state == .active }),
            "Expected Codex integration to report active"
        )
        precondition(
            probe.agents.first(where: { $0.provider == .codex })?.openURL?.scheme == "codex",
            "Local Codex sessions must expose a selectable desktop deep link"
        )
        print("Agent runtime smoke passed: detected \(probe.agents.count) active local Codex session(s)")
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
