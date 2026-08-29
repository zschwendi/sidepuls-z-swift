import Foundation

struct AgentSignalHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let agentID: String
    var provider: AgentProvider
    var sessionID: String
    var name: String
    var project: String
    var state: AgentState
    var eventName: String
    var toolName: String?
    var occurredAt: Date
    var sourceUpdatedAt: Date
    var openURL: URL?
    var previousState: AgentState?

    var agentSnapshot: AgentSession {
        AgentSession(
            id: agentID,
            provider: provider,
            sessionID: sessionID,
            name: name,
            project: project,
            cwd: nil,
            state: state,
            eventName: eventName,
            toolName: toolName,
            updatedAt: sourceUpdatedAt,
            message: nil,
            openURL: openURL
        )
    }
}

struct AgentSignalHistoryLedger: Codable, Sendable {
    static let capacity = 100
    static let defaultVisibleCount = 16

    private struct Fingerprint: Codable, Hashable, Sendable {
        var state: AgentState
        var eventName: String
        var toolName: String?
    }

    private struct Marker: Codable, Hashable, Sendable {
        var fingerprint: Fingerprint
        var sourceUpdatedAt: Date
    }

    private static let storageKey = "sidepulse.agent-signal-history.v1"

    private(set) var entries: [AgentSignalHistoryEntry] = []
    private var latestByAgentID: [String: Marker] = [:]

    init() {}

    static func load(from defaults: UserDefaults = .standard) -> AgentSignalHistoryLedger {
        guard let data = defaults.data(forKey: storageKey),
              var ledger = try? JSONDecoder().decode(AgentSignalHistoryLedger.self, from: data)
        else { return AgentSignalHistoryLedger() }
        ledger.normalize()
        return ledger
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    @discardableResult
    mutating func record(
        _ sessions: [AgentSession],
        observedAt: Date = .now
    ) -> Bool {
        var changed = false
        let ordered = sessions
            .filter { $0.state != .idle }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id < $1.id
            }

        for session in ordered {
            let normalizedToolName = session.toolName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let fingerprint = Fingerprint(
                state: session.state,
                eventName: session.eventName,
                toolName: normalizedToolName
            )
            let previous = latestByAgentID[session.id]

            // Ignore a stale discovery snapshot that arrived after a newer event.
            if let previous, session.updatedAt < previous.sourceUpdatedAt {
                continue
            }

            if let previous, previous.fingerprint == fingerprint {
                if session.updatedAt > previous.sourceUpdatedAt {
                    latestByAgentID[session.id]?.sourceUpdatedAt = session.updatedAt
                    changed = true
                }
                changed = refreshLatestMetadata(for: session) || changed
                continue
            }

            let occurredAt: Date
            if let previous, session.updatedAt == previous.sourceUpdatedAt {
                // Live IPC can change the visible state without touching the transcript file.
                occurredAt = observedAt
            } else {
                occurredAt = min(session.updatedAt, observedAt)
            }

            entries.append(
                AgentSignalHistoryEntry(
                    id: UUID(),
                    agentID: session.id,
                    provider: session.provider,
                    sessionID: session.sessionID,
                    name: session.name,
                    project: session.project,
                    state: session.state,
                    eventName: session.eventName,
                    toolName: normalizedToolName,
                    occurredAt: occurredAt,
                    sourceUpdatedAt: session.updatedAt,
                    openURL: session.openURL,
                    previousState: previous?.fingerprint.state
                )
            )
            latestByAgentID[session.id] = Marker(
                fingerprint: fingerprint,
                sourceUpdatedAt: session.updatedAt
            )
            changed = true
        }

        guard changed else { return false }
        normalize(retaining: Set(ordered.map(\.id)))
        return true
    }

    private mutating func refreshLatestMetadata(for session: AgentSession) -> Bool {
        guard let index = entries.firstIndex(where: { $0.agentID == session.id }) else { return false }
        var changed = false

        if entries[index].provider != session.provider {
            entries[index].provider = session.provider
            changed = true
        }
        if entries[index].sessionID != session.sessionID {
            entries[index].sessionID = session.sessionID
            changed = true
        }
        if entries[index].name != session.name {
            entries[index].name = session.name
            changed = true
        }
        if entries[index].project != session.project {
            entries[index].project = session.project
            changed = true
        }
        if entries[index].openURL != session.openURL {
            entries[index].openURL = session.openURL
            changed = true
        }
        return changed
    }

    private mutating func normalize(retaining currentAgentIDs: Set<String> = []) {
        entries.sort { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            if lhs.sourceUpdatedAt != rhs.sourceUpdatedAt { return lhs.sourceUpdatedAt > rhs.sourceUpdatedAt }
            if lhs.agentID != rhs.agentID { return lhs.agentID < rhs.agentID }
            if lhs.eventName != rhs.eventName { return lhs.eventName < rhs.eventName }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }

        if latestByAgentID.isEmpty {
            for entry in entries where latestByAgentID[entry.agentID] == nil {
                latestByAgentID[entry.agentID] = Marker(
                    fingerprint: Fingerprint(
                        state: entry.state,
                        eventName: entry.eventName,
                        toolName: entry.toolName
                    ),
                    sourceUpdatedAt: entry.sourceUpdatedAt
                )
            }
        }

        let retainedIDs = Set(entries.map(\.agentID)).union(currentAgentIDs)
        latestByAgentID = latestByAgentID.filter { retainedIDs.contains($0.key) }
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
