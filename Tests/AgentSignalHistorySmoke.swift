import Foundation

@main
enum AgentSignalHistorySmoke {
    static func main() {
        testTransitionsAndDeduplication()
        testCapacityAndStableOrdering()
        testPersistenceAndRouting()
        print("Agent signal history smoke passed: transitions are deduplicated, bounded, persistent, and openable")
    }

    private static func testTransitionsAndDeduplication() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = AgentSignalHistoryLedger()
        var session = makeSession(
            id: "codex:history",
            state: .working,
            eventName: "CodexTurnStarted",
            updatedAt: base
        )

        precondition(ledger.record([session], observedAt: base))
        precondition(ledger.entries.count == 1)
        precondition(!ledger.record([session], observedAt: base.addingTimeInterval(1)))
        precondition(ledger.entries.count == 1, "An unchanged runtime refresh must not create history noise")

        session.updatedAt = base.addingTimeInterval(2)
        precondition(ledger.record([session], observedAt: base.addingTimeInterval(2)))
        precondition(ledger.entries.count == 1, "A repeated signal with a newer timestamp must remain deduplicated")

        session.eventName = "CodexMessage"
        session.updatedAt = base.addingTimeInterval(3)
        precondition(ledger.record([session], observedAt: base.addingTimeInterval(3)))
        precondition(ledger.entries.count == 2, "An event-only change must be recorded")

        session.toolName = "Planning"
        session.updatedAt = base.addingTimeInterval(4)
        precondition(ledger.record([session], observedAt: base.addingTimeInterval(4)))
        precondition(ledger.entries.count == 3, "A tool-only change must be recorded")

        session.state = .toolRunning
        session.eventName = "CodexToolCall"
        session.toolName = "Command"
        session.updatedAt = base.addingTimeInterval(5)
        precondition(ledger.record([session], observedAt: base.addingTimeInterval(5)))
        precondition(ledger.entries.count == 4)
        precondition(ledger.entries[0].state == .toolRunning)
        precondition(ledger.entries[0].previousState == .working)
        precondition(ledger.entries[0].toolName == "Command")

        session.state = .completed
        session.eventName = "CodexTurnComplete"
        session.toolName = nil
        session.updatedAt = base.addingTimeInterval(6)
        precondition(ledger.record([session], observedAt: base.addingTimeInterval(6)))
        precondition(ledger.entries[0].state == .completed)
        precondition(ledger.entries[0].previousState == .toolRunning)
    }

    private static func testCapacityAndStableOrdering() {
        let timestamp = Date(timeIntervalSince1970: 1_810_000_000)
        var tied = AgentSignalHistoryLedger()
        let zeta = makeSession(id: "codex:zeta", state: .working, eventName: "Start", updatedAt: timestamp)
        let alpha = makeSession(id: "codex:alpha", state: .working, eventName: "Start", updatedAt: timestamp)
        precondition(tied.record([zeta, alpha], observedAt: timestamp))
        precondition(tied.entries.map(\.agentID) == ["codex:alpha", "codex:zeta"])

        var capped = AgentSignalHistoryLedger()
        for index in 0...AgentSignalHistoryLedger.capacity {
            let date = timestamp.addingTimeInterval(Double(index))
            let session = makeSession(
                id: "codex:cap-\(index)",
                state: .working,
                eventName: "Start",
                updatedAt: date
            )
            precondition(capped.record([session], observedAt: date))
        }
        precondition(capped.entries.count == AgentSignalHistoryLedger.capacity)
        precondition(capped.entries.first?.agentID == "codex:cap-100")
        precondition(!capped.entries.contains(where: { $0.agentID == "codex:cap-0" }))
    }

    private static func testPersistenceAndRouting() {
        let suiteName = "sidepulse.signal-history-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let base = Date(timeIntervalSince1970: 1_820_000_000)
        var ledger = AgentSignalHistoryLedger()
        let session = makeSession(
            id: "codex:persisted",
            state: .completed,
            eventName: "CodexTurnComplete",
            updatedAt: base
        )
        precondition(ledger.record([session], observedAt: base))
        ledger.save(to: defaults)

        var restored = AgentSignalHistoryLedger.load(from: defaults)
        precondition(restored.entries == ledger.entries)
        precondition(!restored.record([session], observedAt: base.addingTimeInterval(1)))
        precondition(restored.entries.count == 1, "Relaunching must not duplicate the last known signal")

        let destination = AgentOpenRouting.destination(for: restored.entries[0].agentSnapshot)
        precondition(destination?.absoluteString == "codex://threads/persisted")
    }

    private static func makeSession(
        id: String,
        state: AgentState,
        eventName: String,
        updatedAt: Date
    ) -> AgentSession {
        let sessionID = id.split(separator: ":").last.map(String.init) ?? id
        return AgentSession(
            id: id,
            provider: .codex,
            sessionID: sessionID,
            name: "History \(sessionID)",
            project: "SidePulse",
            cwd: nil,
            state: state,
            eventName: eventName,
            toolName: nil,
            updatedAt: updatedAt,
            message: nil
        )
    }
}
