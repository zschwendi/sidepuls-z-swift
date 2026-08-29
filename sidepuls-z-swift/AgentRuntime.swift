import Darwin
import Foundation

struct TerminalAcknowledgements: Codable, Sendable {
    private(set) var acknowledgedAt: [String: Date] = [:]

    private static let storageKey = "sidepulse.completion-acknowledgements.v1"
    private static let bootstrapKey = "sidepulse.completion-acknowledgements-bootstrapped.v1"

    static func load(from defaults: UserDefaults = .standard) -> TerminalAcknowledgements {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(TerminalAcknowledgements.self, from: data)
        else { return TerminalAcknowledgements() }
        return stored
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    mutating func acknowledgeExistingIfNeeded(
        _ sessions: [AgentSession],
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !defaults.bool(forKey: Self.bootstrapKey) else { return false }
        let changed = acknowledge(sessions)
        save(to: defaults)
        defaults.set(true, forKey: Self.bootstrapKey)
        return changed
    }

    mutating func acknowledge(
        _ sessions: [AgentSession],
        sessionID: String? = nil,
        at date: Date = .now
    ) -> Bool {
        var changed = false
        for session in sessions where session.isAcknowledgableTerminalAlert {
            guard sessionID == nil || session.id == sessionID else { continue }
            let resolvedDate = max(date, session.updatedAt)
            if acknowledgedAt[session.id] != resolvedDate {
                acknowledgedAt[session.id] = resolvedDate
                changed = true
            }
        }
        return changed
    }

    func shouldDisplay(_ session: AgentSession) -> Bool {
        guard session.isAcknowledgableTerminalAlert,
              let date = acknowledgedAt[session.id]
        else { return true }
        return session.updatedAt > date
    }
}

enum AgentTimelinePolicy {
    static func includes(_ session: AgentSession) -> Bool {
        guard session.provider == .codex else { return true }

        if session.id.lowercased().contains(":agent:") {
            return false
        }
        if session.message?.lowercased() == "codex subagent" {
            return false
        }
        if isCodexMemoryMaintenance(session) {
            return false
        }
        let fallbackSuffix = "(\(String(session.sessionID.prefix(8))))"
        if session.name.hasSuffix(fallbackSuffix), isInternalBackgroundPayload(session.message) {
            return false
        }
        if hasOpaqueInternalName(session) {
            return false
        }
        return true
    }

    static func fallbackName(project: String, sessionID: String) -> String {
        "\(project) (\(String(sessionID.prefix(8))))"
    }

    static func hasOpaqueInternalName(_ session: AgentSession) -> Bool {
        let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sessionPrefix = String(session.sessionID.prefix(8)).lowercased()
        guard !name.isEmpty, !sessionPrefix.isEmpty else { return true }

        if name == sessionPrefix || name == "/\(sessionPrefix)" {
            return true
        }

        guard name.hasPrefix("/"), name.count <= 80 else { return false }
        return name.dropFirst().allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "/"
        }
    }

    private static func isCodexMemoryMaintenance(_ session: AgentSession) -> Bool {
        guard let cwd = session.cwd else { return false }
        let sessionPath = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let maintenancePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/memories", isDirectory: true)
            .standardizedFileURL.path
        return sessionPath == maintenancePath
    }

    private static func isInternalBackgroundPayload(_ message: String?) -> Bool {
        guard let message,
              let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object.keys.contains("suggestions") || object.keys.contains("exclude")
    }

}

final class NativeAgentRuntime: @unchecked Sendable {
    typealias UpdateHandler = @Sendable ([AgentSession], String, [AgentIntegrationStatus]) -> Void
    private static let transcriptTailBytes: UInt64 = 196_608
    private static let grokBotBase32Values = Dictionary(
        uniqueKeysWithValues: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".enumerated().map {
            ($0.element, $0.offset)
        }
    )

    private let queue = DispatchQueue(label: "io.sidepulse.native-agent-runtime")
    private let cloudQueue = DispatchQueue(label: "io.sidepulse.codex-cloud-discovery", qos: .utility)
    private let stateRoot: URL
    private let socketPath: String
    private let latestStateURL: URL
    private let codexSessionsRoot: URL
    private let codexSessionIndexURL: URL
    private let codexIPCBridge: CodexIPCBridge
    private let grokBotPersistenceRoot: URL
    private let usesPersistentAppState: Bool
    private var server: LocalUnixEventServer?
    private var timer: DispatchSourceTimer?
    private var sessions: [String: AgentSession] = [:]
    private var terminalAcknowledgements = TerminalAcknowledgements.load()
    private var discoveredKeys: Set<String> = []
    private var discoveredTranscriptURLs: [String: URL] = [:]
    private var cloudKeys: Set<String> = []
    private var cloudRefreshInFlight = false
    private var lastCloudRefresh = Date.distantPast
    private var hookEventDates: [String: Date] = [:]
    private var lastDiscoveryScan = Date.distantPast
    private var threadNames: [String: String] = [:]
    private var threadIndexModification: Date?
    private var codexMetadataCache: [URL: [String: Any]] = [:]
    private var codexTranscriptCache: [URL: CodexTranscriptSnapshot] = [:]
    private var observedCodexThreadIDs = Set<String>()
    private var grokBotDiscoveredKeys: Set<String> = []
    private var grokBotDocumentCache: [URL: GrokBotCachedDocument] = [:]
    private var grokBotLastEventAt: Date?
    private var ownsSocket = false
    private var lastLatestModification: Date?
    private var lastPublishedSignature = ""
    private let onUpdate: UpdateHandler

    init(onUpdate: @escaping UpdateHandler) {
        self.onUpdate = onUpdate

        let environment = ProcessInfo.processInfo.environment
        let resolvedStateRoot: URL
        if let override = environment["XDG_STATE_HOME"], !override.isEmpty {
            resolvedStateRoot = URL(fileURLWithPath: override, isDirectory: true)
                .appending(path: "sidepulse/agent-monitor", directoryHint: .isDirectory)
        } else {
            resolvedStateRoot = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".local/state/sidepulse/agent-monitor", directoryHint: .isDirectory)
        }
        stateRoot = resolvedStateRoot
        socketPath = environment["SIDEPULSE_EVENT_SOCKET_PATH"]
            ?? resolvedStateRoot.appending(path: "events.sock").path
        latestStateURL = URL(
            fileURLWithPath: environment["SIDEPULSE_LATEST_STATE_PATH"]
                ?? resolvedStateRoot.appending(path: "latest.json").path
        )
        usesPersistentAppState = environment["SIDEPULSE_LATEST_STATE_PATH"] == nil
        let codexHome = URL(
            fileURLWithPath: environment["CODEX_HOME"]
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path,
            isDirectory: true
        )
        codexSessionsRoot = codexHome.appending(path: "sessions", directoryHint: .isDirectory)
        codexSessionIndexURL = codexHome.appending(path: "session_index.jsonl")
        codexIPCBridge = CodexIPCBridge(
            socketPath: environment["SIDEPULSE_CODEX_IPC_SOCKET_PATH"]
                ?? codexHome.appending(path: "ipc/ipc.sock").path
        )
        grokBotPersistenceRoot = URL(
            fileURLWithPath: environment["GROK_BOT_PERSISTENCE_PATH"]
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Library/Application Support/Grok Bot/sand-client-persistence")
                    .path,
            isDirectory: true
        )
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            server?.stop()
            server = nil
            codexIPCBridge.stop()
            ownsSocket = false
        }
    }

    func acknowledgeTerminal(sessionID: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let changed = terminalAcknowledgements.acknowledge(
                Array(sessions.values),
                sessionID: sessionID
            )
            if changed {
                terminalAcknowledgements.save()
                publishLocked(force: true)
            }
        }
    }

    private func startLocked() {
        codexIPCBridge.start { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.discoverCodexSessionsLocked(now: .now)
                self.publishLocked(force: true)
            }
        }
        loadLatestStateLocked(force: true)
        if usesPersistentAppState,
           terminalAcknowledgements.acknowledgeExistingIfNeeded(Array(sessions.values)) {
            publishLocked(force: true)
        }

        let eventServer = LocalUnixEventServer(path: socketPath) { [weak self] data in
            self?.queue.async {
                self?.ingestLocked(data)
            }
        }
        do {
            try eventServer.start()
            server = eventServer
            ownsSocket = true
        } catch LocalUnixEventServer.ServerError.alreadyInUse {
            ownsSocket = false
        } catch {
            ownsSocket = false
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.25, repeating: 0.5, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !ownsSocket { loadLatestStateLocked() }
            let now = Date.now
            if now.timeIntervalSince(lastDiscoveryScan) >= 0.75 {
                discoverCodexSessionsLocked(now: now)
                discoverGrokBotSessionsLocked(now: now)
                pruneStaleHookSessionsLocked(now: now)
                lastDiscoveryScan = now
            }
            if now.timeIntervalSince(lastCloudRefresh) >= 15 {
                refreshCodexCloudLocked(now: now)
            }
            publishLocked()
        }
        timer = source
        source.resume()
        publishLocked(force: true)
    }

    private func ingestLocked(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let envelope = object as? [String: Any],
            let providerText = envelope["provider"] as? String,
            let line = envelope["line"] as? [String: Any]
        else { return }

        var provider = AgentProvider(rawValue: providerText.lowercased()) ?? .unknown
        let outerTimestamp = string(in: line, keys: ["logged_at", "timestamp"])
        let raw: [String: Any]
        if provider == .codex, let event = line["event"] as? [String: Any] {
            raw = event
        } else {
            raw = line
            let transcript = string(in: raw, keys: ["transcriptPath", "transcript_path"]) ?? ""
            if provider == .claude, transcript.contains("/.grok/") { provider = .grok }
        }

        guard let eventName = canonicalEventName(
            string(in: raw, keys: ["hook_event_name", "hookEventName", "event_name", "eventName"])
        ) else { return }

        let sessionID = string(in: raw, keys: ["session_id", "sessionId"]) ?? "unknown"
        let childAgentID = string(in: raw, keys: ["agent_id", "agentId"])
        let identity = childAgentID.map { "agent:\($0)" } ?? "session:\(sessionID)"
        let key = "\(provider.rawValue):\(identity)"
        if childAgentID != nil {
            let changed = sessions.removeValue(forKey: key) != nil
            hookEventDates[key] = nil
            if changed {
                writeLatestStateLocked()
                publishLocked(force: true)
            }
            return
        }
        let previous = sessions[key]
        let cwd = string(in: raw, keys: ["cwd", "workspaceRoot"]) ?? previous?.cwd
        let project = projectName(cwd) ?? previous?.project ?? "Unknown Project"
        let reportedTitle = string(
            in: raw,
            keys: ["session_title", "sessionTitle", "title", "task_name"]
        )
        let title = provider == .codex
            ? threadNames[sessionID]
                ?? reportedTitle
                ?? previous?.name
                ?? AgentTimelinePolicy.fallbackName(project: project, sessionID: sessionID)
            : reportedTitle
                ?? previous?.name
                ?? "\(project) (\(String(sessionID.prefix(8))))"
        let message = string(in: raw, keys: ["message", "last_assistant_message", "lastAssistantMessage"])
        let toolName = string(in: raw, keys: ["tool_name", "toolName"])
        let state = stateForEvent(eventName, raw: raw, message: message)
        let timestamp = parseTimestamp(
            outerTimestamp
                ?? string(in: raw, keys: ["logged_at", "timestamp"])
        )
        hookEventDates[key] = timestamp

        var resolvedState = state
        if previous?.state == .waiting,
           !["UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PermissionDenied", "Stop", "SessionEnd"].contains(eventName) {
            resolvedState = .waiting
        }

        sessions[key] = AgentSession(
            id: key,
            provider: provider,
            sessionID: sessionID,
            name: title,
            project: project,
            cwd: cwd,
            state: resolvedState,
            eventName: eventName,
            toolName: toolName ?? previous?.toolName,
            updatedAt: timestamp,
            message: message,
            openURL: previous?.openURL ?? AgentOpenRouting.fallbackDestination(
                provider: provider,
                sessionID: sessionID
            )
        )
        writeLatestStateLocked()
        publishLocked(force: true)
    }

    private func loadLatestStateLocked(force: Bool = false) {
        let values = try? latestStateURL.resourceValues(forKeys: [.contentModificationDateKey])
        let modified = values?.contentModificationDate
        if !force, modified == lastLatestModification { return }
        lastLatestModification = modified

        guard
            let data = try? Data(contentsOf: latestStateURL),
            let snapshot = try? JSONDecoder().decode(LegacyLatestState.self, from: data)
        else { return }

        var loaded: [String: AgentSession] = [:]
        for status in snapshot.statuses {
            guard let state = AgentState(legacyValue: status.mode) else { continue }
            let provider = AgentProvider(rawValue: status.provider.lowercased()) ?? .unknown
            let sessionID = status.sessionID ?? status.agentID
            let project = projectName(status.cwd) ?? "Unknown Project"
            let session = AgentSession(
                id: status.agentID,
                provider: provider,
                sessionID: sessionID,
                name: status.displayName,
                project: project,
                cwd: status.cwd,
                state: state,
                eventName: status.eventName,
                toolName: status.toolName,
                updatedAt: parseTimestamp(status.updatedAt),
                message: status.message,
                openURL: status.openURL.flatMap(URL.init(string:))
                    ?? AgentOpenRouting.fallbackDestination(
                        provider: provider,
                        sessionID: sessionID
                    )
            )
            if AgentTimelinePolicy.includes(session) {
                loaded[status.agentID] = session
            }
        }
        sessions = loaded
        publishLocked(force: true)
    }

    private func visibleSessionsLocked() -> [AgentSession] {
        sessions.values
            .filter { session in
                guard AgentTimelinePolicy.includes(session) else { return false }
                if session.state == .idle { return false }
                return terminalAcknowledgements.shouldDisplay(session)
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                if $0.state.priority != $1.state.priority { return $0.state.priority < $1.state.priority }
                return $0.id < $1.id
            }
    }

    private func publishLocked(force: Bool = false) {
        let visible = visibleSessionsLocked()
        let ownership = ownsSocket
            ? "Unified agent hub · local + cloud discovery · live hooks"
            : "Unified agent hub · local + cloud discovery"
        let runningCount = visible.filter { $0.state != .completed }.count
        let finishedCount = visible.count - runningCount
        let statusParts = [
            runningCount > 0 ? "\(runningCount) active" : nil,
            finishedCount > 0 ? "\(finishedCount) finished" : nil,
        ].compactMap { $0 }
        let message = visible.isEmpty
            ? "\(ownership) · no active agents"
            : "\(ownership) · \(statusParts.joined(separator: " · "))"
        let integrations = integrationStatusesLocked(visible: visible)
        let integrationSignature = integrations.map {
            "\($0.provider.rawValue):\($0.state.rawValue):\($0.activeSessionCount):\($0.lastEventAt?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        let signature = visible.map {
            "\($0.id):\($0.state.rawValue):\($0.eventName):\($0.toolName ?? ""):\($0.updatedAt.timeIntervalSince1970)"
        }.joined(separator: "|")
            + message + integrationSignature
        guard force || signature != lastPublishedSignature else { return }
        lastPublishedSignature = signature
        onUpdate(visible, message, integrations)
    }

    private func writeLatestStateLocked() {
        let now = Date.now
        let payload = NativeLatestState(
            updatedAt: isoString(now),
            statuses: sessions.values.map { session in
                NativeLatestStatus(
                    provider: session.provider.rawValue,
                    agentID: session.id,
                    displayName: session.name,
                    mode: session.state.legacyValue,
                    modeLabel: session.state.title,
                    priority: session.state.priority + 1,
                    updatedAt: isoString(session.updatedAt),
                    ageSeconds: max(0, now.timeIntervalSince(session.updatedAt)),
                    eventName: session.eventName,
                    sessionID: session.sessionID,
                    cwd: session.cwd,
                    toolName: session.toolName,
                    message: session.message,
                    openURL: session.openURL?.absoluteString,
                    origin: session.provider.title,
                    stale: false
                )
            }
        )
        guard let data = try? JSONEncoder.pretty.encode(payload) else { return }
        do {
            try FileManager.default.createDirectory(
                at: latestStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporary = latestStateURL.appendingPathExtension("tmp")
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(latestStateURL, withItemAt: temporary)
            lastLatestModification = try? latestStateURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } catch {
            try? data.write(to: latestStateURL, options: .atomic)
        }
    }
}

private extension NativeAgentRuntime {
    func refreshCodexCloudLocked(now: Date) {
        guard !cloudRefreshInFlight else { return }
        lastCloudRefresh = now
        guard let executable = codexExecutableURL() else { return }
        cloudRefreshInFlight = true

        cloudQueue.async { [weak self] in
            let tasks = Self.loadCodexCloudTasks(executable: executable)
            self?.queue.async { [weak self] in
                guard let self else { return }
                cloudRefreshInFlight = false
                guard let tasks else { return }
                applyCodexCloudTasksLocked(tasks)
            }
        }
    }

    func codexExecutableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appending(path: ".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    static func loadCodexCloudTasks(executable: URL) -> [CodexCloudTask]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["cloud", "list", "--json", "--limit", "20"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date.now.addingTimeInterval(8)
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try? JSONDecoder().decode(CodexCloudTaskList.self, from: data).tasks
    }

    func applyCodexCloudTasksLocked(_ tasks: [CodexCloudTask]) {
        let activeStatuses: Set<String> = [
            "pending", "queued", "starting", "running", "in_progress", "working", "needs_input", "waiting",
        ]
        var active: [String: AgentSession] = [:]

        for task in tasks {
            let status = task.status.lowercased()
            guard activeStatuses.contains(status) else { continue }
            let key = "codex:cloud:\(task.id)"
            let state: AgentState
            switch status {
            case "needs_input", "waiting": state = .waiting
            case "pending", "queued", "starting": state = .working
            default: state = .working
            }
            active[key] = AgentSession(
                id: key,
                provider: .codex,
                sessionID: task.id,
                name: task.title.isEmpty ? "Codex Cloud Task" : task.title,
                project: task.environmentLabel ?? "Codex Cloud",
                cwd: nil,
                state: state,
                eventName: "CodexCloud\(status.replacingOccurrences(of: "_", with: " ").capitalized.replacingOccurrences(of: " ", with: ""))",
                toolName: nil,
                updatedAt: parseTimestamp(task.updatedAt),
                message: "Codex Cloud · \(status.replacingOccurrences(of: "_", with: " ").capitalized)",
                openURL: URL(string: task.url)
            )
        }

        var changed = false
        let activeKeys = Set(active.keys)
        for key in cloudKeys.subtracting(activeKeys) where sessions.removeValue(forKey: key) != nil {
            changed = true
        }
        for (key, session) in active where sessions[key] != session {
            sessions[key] = session
            changed = true
        }
        cloudKeys = activeKeys
        if changed {
            if ownsSocket { writeLatestStateLocked() }
            publishLocked(force: true)
        }
    }

    func discoverCodexSessionsLocked(now: Date) {
        var changed = refreshThreadNamesLocked()

        var discovered: [String: AgentSession] = [:]
        var transcriptURLs: [String: URL] = [:]
        let recentURLs = recentCodexTranscriptURLs(now: now)
        let retainedURLs: [URL] = discoveredTranscriptURLs.compactMap { entry -> URL? in
            let (key, url) = entry
            guard let session = sessions[key], shouldContinueTracking(session) else { return nil }
            return url
        }
        let candidateURLs = Set(recentURLs + retainedURLs)
        codexMetadataCache = codexMetadataCache.filter { candidateURLs.contains($0.key) }
        codexTranscriptCache = codexTranscriptCache.filter { candidateURLs.contains($0.key) }
        for url in candidateURLs {
            guard let session = codexSession(from: url, now: now) else { continue }
            discovered[session.id] = session
            transcriptURLs[session.id] = url
        }

        let newKeys = Set(discovered.keys)
        for key in discoveredKeys.subtracting(newKeys) {
            let hookIsRecent = hookEventDates[key].map { now.timeIntervalSince($0) <= 15 * 60 } ?? false
            if !hookIsRecent, sessions.removeValue(forKey: key) != nil { changed = true }
        }

        for (key, discoveredSession) in discovered {
            if let hookDate = hookEventDates[key], hookDate > discoveredSession.updatedAt { continue }
            if sessions[key] != discoveredSession {
                sessions[key] = discoveredSession
                changed = true
            }
        }
        discoveredTranscriptURLs = Dictionary(uniqueKeysWithValues: discovered.compactMap { key, session in
            guard shouldContinueTracking(session) else { return nil }
            guard let url = transcriptURLs[key] else { return nil }
            return (key, url)
        })
        discoveredKeys = newKeys
        let threadIDs = Set(discovered.values.map(\.sessionID))
        if threadIDs != observedCodexThreadIDs {
            observedCodexThreadIDs = threadIDs
            codexIPCBridge.observe(threadIDs: threadIDs)
        }

        if changed {
            if ownsSocket { writeLatestStateLocked() }
            publishLocked(force: true)
        }
    }

    func discoverGrokBotSessionsLocked(now: Date) {
        let manager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
        ]
        guard let urls = try? manager.contentsOfDirectory(
            at: grokBotPersistenceRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            removeGrokBotSessionsLocked()
            grokBotLastEventAt = nil
            return
        }

        var rosterURL: URL?
        var transcriptURLs: [String: URL] = [:]
        var newestModification: Date?

        for url in urls where url.pathExtension == "blob" {
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 2_097_152,
                  let persistenceKey = grokBotPersistenceKey(for: url)
            else { continue }

            if let modified = values.contentModificationDate {
                newestModification = max(newestModification ?? .distantPast, modified)
            }
            if persistenceKey.hasSuffix(".roster.last-roster") {
                rosterURL = url
            } else if let markerRange = persistenceKey.range(of: ".transcript.replicas.") {
                let sessionID = String(persistenceKey[markerRange.upperBound...])
                if !sessionID.isEmpty { transcriptURLs[sessionID.lowercased()] = url }
            }
        }
        grokBotLastEventAt = newestModification
        let currentDocumentURLs = Set(transcriptURLs.values).union(rosterURL.map { [$0] } ?? [])
        grokBotDocumentCache = grokBotDocumentCache.filter {
            currentDocumentURLs.contains($0.key)
        }

        guard let rosterURL,
              let roster = readGrokBotDocument(rosterURL),
              let value = roster["value"] as? [String: Any],
              let rows = value["rows"] as? [[String: Any]]
        else {
            removeGrokBotSessionsLocked()
            return
        }

        var discovered: [String: AgentSession] = [:]
        for row in rows {
            guard let sessionID = string(in: row, keys: ["id"]), !sessionID.isEmpty else { continue }
            let key = "grok_bot:session:\(sessionID)"
            let transcript = transcriptURLs[sessionID.lowercased()].flatMap(readGrokBotDocument)
            let activity = inferGrokBotActivity(row: row, transcript: transcript, now: now)
            let updatedAt = min(now, activity.updatedAt)
            let previous = sessions[key]

            let session = AgentSession(
                id: key,
                provider: .grokBot,
                sessionID: sessionID,
                name: string(in: row, keys: ["name", "title"])
                    ?? previous?.name
                    ?? "Grok Bot (\(String(sessionID.prefix(8))))",
                project: "Grok Bot",
                cwd: string(in: row, keys: ["path"]),
                state: activity.state,
                eventName: activity.eventName,
                toolName: activity.toolName,
                updatedAt: updatedAt,
                message: "Detected from Grok Bot local activity",
                // Grok Bot only exposes a generic app-open route today; its
                // public deep-link contract does not include an agent ID.
                openURL: URL(string: "grokbot://app/v1/open")
            )

            let isRecent = now.timeIntervalSince(updatedAt) <= 15 * 60
            if isRecent || activity.state == .waiting || previous.map(shouldContinueTracking) == true {
                discovered[key] = session
            }
        }

        let newKeys = Set(discovered.keys)
        var changed = false
        for key in grokBotDiscoveredKeys.subtracting(newKeys) where sessions.removeValue(forKey: key) != nil {
            changed = true
        }
        for (key, session) in discovered where sessions[key] != session {
            sessions[key] = session
            changed = true
        }
        grokBotDiscoveredKeys = newKeys

        if changed {
            if ownsSocket { writeLatestStateLocked() }
            publishLocked(force: true)
        }
    }

    func removeGrokBotSessionsLocked() {
        var changed = false
        for key in grokBotDiscoveredKeys where sessions.removeValue(forKey: key) != nil {
            changed = true
        }
        grokBotDiscoveredKeys.removeAll()
        grokBotDocumentCache.removeAll()
        if changed {
            if ownsSocket { writeLatestStateLocked() }
            publishLocked(force: true)
        }
    }

    func pruneStaleHookSessionsLocked(now: Date) {
        let discoveryOwnedKeys = discoveredKeys
            .union(cloudKeys)
            .union(grokBotDiscoveredKeys)
        let staleStates: Set<AgentState> = [.idle, .working, .toolRunning]
        let staleKeys = sessions.compactMap { key, session -> String? in
            guard !discoveryOwnedKeys.contains(key),
                  staleStates.contains(session.state),
                  now.timeIntervalSince(session.updatedAt) > 15 * 60
            else { return nil }
            return key
        }
        guard !staleKeys.isEmpty else { return }

        for key in staleKeys {
            sessions[key] = nil
            hookEventDates[key] = nil
        }
        if ownsSocket { writeLatestStateLocked() }
        publishLocked(force: true)
    }

    func grokBotPersistenceKey(for url: URL) -> String? {
        let encoded = url.deletingPathExtension().lastPathComponent.uppercased()
        var buffer = 0
        var bitCount = 0
        var bytes: [UInt8] = []

        for character in encoded where character != "=" {
            guard let value = Self.grokBotBase32Values[character] else { return nil }
            buffer = (buffer << 5) | value
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((buffer >> bitCount) & 0xFF))
                buffer = bitCount == 0 ? 0 : buffer & ((1 << bitCount) - 1)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    func readGrokBotDocument(_ url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              (values.fileSize ?? 0) <= 2_097_152
        else { return nil }
        let modifiedAt = values.contentModificationDate
        if let cached = grokBotDocumentCache[url], cached.modifiedAt == modifiedAt {
            return cached.document
        }
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        grokBotDocumentCache[url] = GrokBotCachedDocument(
            modifiedAt: modifiedAt,
            document: document
        )
        return document
    }

}

extension NativeAgentRuntime {
    func inferGrokBotActivity(
        row: [String: Any],
        transcript: [String: Any]?,
        now: Date
    ) -> GrokBotActivity {
        let rowUpdatedAt = grokBotDate(in: row, keys: ["lastActivityAt", "updatedAt"]) ?? .distantPast
        let transcriptValue = transcript?["value"] as? [String: Any]
        let entries = transcriptValue?["entries"] as? [[String: Any]] ?? []
        let latest = entries.reversed().first(where: { entry in
            let kind = string(in: entry, keys: ["kind", "type"])?.lowercased() ?? ""
            return kind == "message" || kind == "send-message" || kind.contains("tool")
                || kind.contains("command") || kind.contains("permission")
        })
        let latestMessage = latest?["message"] as? [String: Any]
        let latestTimestamp = latest.flatMap { grokBotDate(in: $0, keys: ["timestampMs", "createdAt"]) }
        let updatedAt = [rowUpdatedAt, latestTimestamp].compactMap { $0 }.max() ?? now

        if row["awaitingUserResponse"] as? Bool == true || grokBotHasPendingPermission(entries) {
            return GrokBotActivity(
                state: .waiting,
                eventName: "GrokBotNeedsApproval",
                toolName: "Waiting for you",
                updatedAt: updatedAt
            )
        }

        let isStreaming = latest?["isStreaming"] as? Bool == true
            || latestMessage?["isStreaming"] as? Bool == true
        if isStreaming {
            return GrokBotActivity(
                state: .working,
                eventName: "GrokBotStreaming",
                toolName: nil,
                updatedAt: updatedAt
            )
        }

        let latestKind = [
            string(in: latest ?? [:], keys: ["kind", "type"]),
            string(in: latestMessage ?? [:], keys: ["type", "kind"]),
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        let latestRole = string(in: latest ?? [:], keys: ["role"])?.lowercased()
        let age = max(0, now.timeIntervalSince(updatedAt))

        if latestKind.contains("error") || latestKind.contains("failed") {
            return GrokBotActivity(
                state: .error,
                eventName: "GrokBotFailed",
                toolName: nil,
                updatedAt: updatedAt
            )
        }

        if latestRole == "user" {
            let state: AgentState = age <= 15 * 60 ? .working : .completed
            return GrokBotActivity(
                state: state,
                eventName: state == .working ? "GrokBotWorking" : "GrokBotTurnComplete",
                toolName: nil,
                updatedAt: updatedAt
            )
        }

        let responseIsUnread = row["hasUnread"] as? Bool == true
        if latestKind.contains("tool") || latestKind.contains("command") {
            let state: AgentState = responseIsUnread || age > 30 ? .completed : .toolRunning
            return GrokBotActivity(
                state: state,
                eventName: state == .completed ? "GrokBotTurnComplete" : "GrokBotToolActivity",
                toolName: state == .completed ? nil : "Tool",
                updatedAt: updatedAt
            )
        }

        // Grok Bot persists response chunks but does not persist a dedicated turn-finished flag.
        // Keep the turn active across normal pauses between chunks, then settle only after the
        // transcript has been quiet. An unread response is explicit completion evidence.
        let state: AgentState = responseIsUnread || age > 30 ? .completed : .working
        return GrokBotActivity(
            state: state,
            eventName: state == .working ? "GrokBotWorking" : "GrokBotTurnComplete",
            toolName: nil,
            updatedAt: updatedAt
        )
    }

}

private extension NativeAgentRuntime {

    func grokBotHasPendingPermission(_ entries: [[String: Any]]) -> Bool {
        for entry in entries.reversed() {
            guard let message = entry["message"] as? [String: Any] else { continue }
            let type = string(in: message, keys: ["type", "kind"])?.lowercased() ?? ""
            guard type.contains("permission") else { continue }
            if let ask = message["ask"] as? [String: Any] {
                return string(in: ask, keys: ["status"])?.lowercased() == "pending"
            }
            return false
        }
        return false
    }

    func grokBotDate(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                let value = number.doubleValue
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
            }
            if let text = dictionary[key] as? String, let value = Double(text) {
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
            }
        }
        return nil
    }

    func shouldContinueTracking(_ session: AgentSession) -> Bool {
        if session.state == .idle { return false }
        if session.isAcknowledgableTerminalAlert {
            return terminalAcknowledgements.shouldDisplay(session)
        }
        return true
    }

    func recentCodexTranscriptURLs(now: Date) -> [URL] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var result: [URL] = []

        for dayOffset in [0, -1] {
            guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { continue }
            let folder = codexSessionsRoot
                .appending(path: String(format: "%04d", year), directoryHint: .isDirectory)
                .appending(path: String(format: "%02d", month), directoryHint: .isDirectory)
                .appending(path: String(format: "%02d", day), directoryHint: .isDirectory)
            guard let urls = try? manager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) <= 15 * 60
                else { continue }
                result.append(url)
            }
        }
        return result
    }

    func codexSession(from url: URL, now: Date) -> AgentSession? {
        guard let snapshot = readCodexTranscript(url) else { return nil }
        let metadata = snapshot.metadata
        let sessionID = string(in: metadata, keys: ["session_id", "id"])
            ?? url.deletingPathExtension().lastPathComponent.split(separator: "-").last.map(String.init)
        guard let sessionID, !sessionID.isEmpty else { return nil }

        let key = "codex:session:\(sessionID)"
        let cwd = string(in: metadata, keys: ["cwd"])
        let project = projectName(cwd) ?? "Codex"
        let subagent = subagentIdentity(in: metadata)
        guard subagent == nil else { return nil }
        let fallbackName = AgentTimelinePolicy.fallbackName(
            project: project,
            sessionID: sessionID
        )
        let activity: CodexActivity
        if codexIPCBridge.needsUser(threadID: sessionID) == true {
            activity = CodexActivity(
                state: .waiting,
                eventName: "CodexNeedsApproval",
                toolName: "Waiting for you"
            )
        } else {
            activity = snapshot.activity
        }
        let updatedAt = snapshot.modifiedAt > now ? now : snapshot.modifiedAt

        return AgentSession(
            id: key,
            provider: .codex,
            sessionID: sessionID,
            name: threadNames[sessionID] ?? fallbackName,
            project: project,
            cwd: cwd,
            state: activity.state,
            eventName: activity.eventName,
            toolName: activity.toolName,
            updatedAt: updatedAt,
            message: "Detected from local Codex activity",
            openURL: URL(string: "codex://threads/\(sessionID)")
        )
    }

    func subagentIdentity(in metadata: [String: Any]) -> String? {
        if string(in: metadata, keys: ["thread_source"])?.lowercased() == "subagent" {
            return "Subagent"
        }
        guard let source = metadata["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any]
        else { return nil }
        if let nickname = string(in: spawn, keys: ["agent_nickname"]), !nickname.isEmpty {
            return nickname
        }
        if let path = string(in: spawn, keys: ["agent_path"]), !path.isEmpty {
            return path.split(separator: "/").last.map(String.init) ?? "Subagent"
        }
        return "Subagent"
    }

    func readCodexTranscript(_ url: URL) -> CodexTranscriptSnapshot? {
        guard let values = try? url.resourceValues(
                  forKeys: [.contentModificationDateKey, .fileSizeKey]
              ),
              let modifiedAt = values.contentModificationDate,
              let fileSize = values.fileSize
        else { return nil }
        if let cached = codexTranscriptCache[url],
           cached.modifiedAt == modifiedAt,
           cached.fileSize == fileSize {
            return cached
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard
              let size = try? handle.seekToEnd()
        else { return nil }

        let metadata: [String: Any]
        if let cached = codexMetadataCache[url] {
            metadata = cached
        } else {
            try? handle.seek(toOffset: 0)
            guard let metadataRecord = readFirstJSONObject(from: handle),
                  metadataRecord["type"] as? String == "session_meta",
                  let parsedMetadata = metadataRecord["payload"] as? [String: Any]
            else { return nil }
            metadata = parsedMetadata
            codexMetadataCache[url] = parsedMetadata
        }

        let tailStart = size > Self.transcriptTailBytes ? size - Self.transcriptTailBytes : 0
        try? handle.seek(toOffset: tailStart)
        let tail = (try? handle.readToEnd()) ?? Data()

        let snapshot = CodexTranscriptSnapshot(
            metadata: metadata,
            activity: inferCodexActivity(
                in: tail,
                dropFirstPartialLine: tailStart > 0
            ),
            modifiedAt: modifiedAt,
            fileSize: Int(size)
        )
        codexTranscriptCache[url] = snapshot
        return snapshot
    }

    func readFirstJSONObject(from handle: FileHandle) -> [String: Any]? {
        var line = Data()
        let maximumBytes = 2_097_152
        while line.count < maximumBytes {
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[..<newline])
                break
            }
            line.append(chunk)
        }
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line)
        else { return nil }
        return object as? [String: Any]
    }

    func jsonLineObjects(in data: Data, dropFirstPartialLine: Bool) -> [[String: Any]] {
        var start = data.startIndex
        if dropFirstPartialLine, let firstNewline = data.firstIndex(of: 0x0A) {
            start = data.index(after: firstNewline)
        }
        var end = data.endIndex
        if data.last != 0x0A, let lastNewline = data.lastIndex(of: 0x0A) {
            end = data.index(after: lastNewline)
        }
        guard start <= end else { return [] }
        let completeLineData = data.subdata(in: start..<end)
        guard let text = String(data: completeLineData, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.compactMap { line in
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData)
            else { return nil }
            return object as? [String: Any]
        }
    }

    func inferCodexActivity(_ records: [[String: Any]]) -> CodexActivity {
        for record in records.reversed() {
            if let activity = codexActivity(in: record) { return activity }
        }
        return CodexActivity(state: .working, eventName: "CodexActivity", toolName: nil)
    }

    func inferCodexActivity(in data: Data, dropFirstPartialLine: Bool) -> CodexActivity {
        var start = data.startIndex
        if dropFirstPartialLine, let firstNewline = data.firstIndex(of: 0x0A) {
            start = data.index(after: firstNewline)
        }
        var end = data.endIndex
        if data.last != 0x0A, let lastNewline = data.lastIndex(of: 0x0A) {
            end = data.index(after: lastNewline)
        }
        guard start < end else {
            return CodexActivity(state: .working, eventName: "CodexActivity", toolName: nil)
        }

        let lines = data[start..<end].split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let activity = codexActivity(in: record)
            else { continue }
            return activity
        }
        return CodexActivity(state: .working, eventName: "CodexActivity", toolName: nil)
    }

    private func codexActivity(in record: [String: Any]) -> CodexActivity? {
        guard let recordType = record["type"] as? String,
              let payload = record["payload"] as? [String: Any]
        else { return nil }

        if recordType == "event_msg" {
            switch payload["type"] as? String {
            case "task_complete":
                return CodexActivity(state: .completed, eventName: "CodexTurnComplete", toolName: nil)
            case "turn_aborted":
                return CodexActivity(state: .error, eventName: "CodexTurnAborted", toolName: nil)
            case "task_started":
                return CodexActivity(state: .working, eventName: "CodexTurnStarted", toolName: nil)
            default:
                return nil
            }
        }

        guard recordType == "response_item", let itemType = payload["type"] as? String else { return nil }
        switch itemType {
        case "custom_tool_call", "function_call", "local_shell_call":
            let rawName = string(in: payload, keys: ["name", "tool_name"]) ?? "Tool"
            if rawName == "request_user_input" {
                return CodexActivity(state: .waiting, eventName: "CodexNeedsInput", toolName: "Waiting for you")
            }
            return CodexActivity(
                state: .toolRunning,
                eventName: "CodexToolCall",
                toolName: friendlyToolName(rawName)
            )
        case "custom_tool_call_output", "function_call_output", "local_shell_call_output", "reasoning":
            return CodexActivity(state: .working, eventName: "CodexWorking", toolName: nil)
        case "message":
            let role = payload["role"] as? String
            let phase = payload["phase"] as? String
            if role == "assistant", phase == "final" {
                return CodexActivity(state: .completed, eventName: "CodexTurnComplete", toolName: nil)
            }
            return CodexActivity(state: .working, eventName: "CodexMessage", toolName: nil)
        default:
            return nil
        }
    }

    func friendlyToolName(_ rawName: String) -> String {
        switch rawName {
        case "exec", "exec_command", "functions.exec": "Command"
        case "apply_patch": "Editing code"
        case "web__run": "Web research"
        case "request_user_input": "Waiting for you"
        default:
            rawName
                .replacingOccurrences(of: "__", with: " · ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    func refreshThreadNamesLocked() -> Bool {
        let modified = try? codexSessionIndexURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        guard modified != threadIndexModification,
              let data = try? Data(contentsOf: codexSessionIndexURL)
        else { return false }

        var updated: [String: String] = [:]
        for object in jsonLineObjects(in: data, dropFirstPartialLine: false) {
            guard let id = object["id"] as? String,
                  let name = object["thread_name"] as? String,
                  !name.isEmpty
            else { continue }
            updated[id] = name
        }
        threadNames = updated
        threadIndexModification = modified

        var renamedExistingSession = false
        for (sessionID, name) in updated {
            let key = "codex:session:\(sessionID)"
            guard var session = sessions[key], session.name != name else { continue }
            session.name = name
            sessions[key] = session
            renamedExistingSession = true
        }
        return renamedExistingSession
    }

    func integrationStatusesLocked(visible: [AgentSession]) -> [AgentIntegrationStatus] {
        AgentProvider.allCases.filter { $0 != .unknown }.map { provider in
            let active = visible.filter { $0.provider == provider }
            let configured: Bool
            switch provider {
            case .codex:
                configured = FileManager.default.fileExists(atPath: codexSessionsRoot.path)
            case .grokBot:
                configured = FileManager.default.fileExists(atPath: grokBotPersistenceRoot.path)
            case .claude:
                configured = integrationFileContainsSidePulse(
                    FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
                )
            case .grok:
                configured = integrationFileContainsSidePulse(
                    FileManager.default.homeDirectoryForCurrentUser.appending(path: ".grok/hooks/sidepulse.json")
                )
            case .unknown:
                configured = false
            }

            let discoveredDate = active.map(\.updatedAt).max()
            let logDate = providerLogModificationDate(provider)
            let lastEvent = [discoveredDate, logDate].compactMap { $0 }.max()
            let state: IntegrationConnectionState = active.isEmpty
                ? (configured ? .ready : .needsSetup)
                : .active
            let detail: String
            if !active.isEmpty {
                if provider == .codex {
                    let cloudCount = active.filter { $0.id.hasPrefix("codex:cloud:") }.count
                    let localCount = active.count - cloudCount
                    let parts = [
                        localCount > 0 ? "\(localCount) local" : nil,
                        cloudCount > 0 ? "\(cloudCount) cloud" : nil,
                    ].compactMap { $0 }
                    detail = parts.joined(separator: " · ") + " active"
                } else {
                    detail = "\(active.count) local session\(active.count == 1 ? "" : "s") detected"
                }
            } else if provider == .codex || provider == .grokBot {
                detail = "Watching local \(provider.title) sessions automatically"
            } else if configured {
                detail = logDate == nil ? "Hooks installed · no events seen yet" : "Hooks installed · ready for the next event"
            } else {
                detail = "SidePulse hooks are not installed"
            }

            return AgentIntegrationStatus(
                provider: provider,
                state: state,
                detail: detail,
                activeSessionCount: active.count,
                lastEventAt: lastEvent
            )
        }
    }

    func integrationFileContainsSidePulse(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?.lowercased()
        else { return false }
        return text.contains("sidepulse") && text.contains("hook")
    }

    func providerLogModificationDate(_ provider: AgentProvider) -> Date? {
        if provider == .grokBot { return grokBotLastEventAt }
        let url = stateRoot.appending(path: "\(provider.rawValue).jsonl")
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              (values.fileSize ?? 0) > 0
        else { return nil }
        return values.contentModificationDate
    }

    func stateForEvent(_ event: String, raw: [String: Any], message: String?) -> AgentState {
        if let explicit = explicitState(message ?? string(in: raw, keys: ["sidepulse_status", "sidepulse_mode"])) {
            return explicit
        }
        switch event {
        case "PermissionRequest": return .waiting
        case "PreToolUse": return .toolRunning
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied", "StopFailure":
            // Tool failures and denied permissions are recoverable turn events. The
            // agent decides whether to retry or take another path, so they must not
            // impersonate a terminal run failure on the physical array.
            return .working
        case "UserPromptSubmit", "PreCompact", "PostCompact", "SubagentStart": return .working
        case "Stop", "SubagentStop": return asksConcreteQuestion(message) ? .waiting : .completed
        case "SessionEnd": return .completed
        case "SessionStart": return .idle
        case "Notification":
            let text = [
                string(in: raw, keys: ["notification_type", "notificationType"]),
                message,
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            if ["turn complete", "task complete", "completed successfully", "work complete"].contains(where: text.contains) {
                return .completed
            }
            if ["waiting for input", "needs input", "permission", "approval"].contains(where: text.contains) {
                return .waiting
            }
            return .working
        default: return .working
        }
    }

    func explicitState(_ text: String?) -> AgentState? {
        guard let value = text?.lowercased() else { return nil }
        if value.contains("sidepulse:blocked") || value.contains("blocked_error") { return .error }
        if value.contains("sidepulse:ask") || value.contains("waiting_for_input") { return .waiting }
        if value.contains("sidepulse:done") || value.contains("completed") { return .completed }
        if value.contains("sidepulse:working") || value == "working" { return .working }
        if value.contains("sidepulse:idle") || value.contains("idle_ready") { return .idle }
        return nil
    }

    func asksConcreteQuestion(_ text: String?) -> Bool {
        guard let text, text.contains("?") else { return false }
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["anything else?", "let me know?"].contains(where: lowered.hasSuffix)
    }

    func canonicalEventName(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let collapsed = value.lowercased().filter(\.isLetter)
        return [
            "sessionstart": "SessionStart", "userpromptsubmit": "UserPromptSubmit",
            "pretooluse": "PreToolUse", "posttooluse": "PostToolUse",
            "posttoolusefailure": "PostToolUseFailure", "permissionrequest": "PermissionRequest",
            "permissiondenied": "PermissionDenied", "notification": "Notification",
            "precompact": "PreCompact", "postcompact": "PostCompact",
            "subagentstart": "SubagentStart", "subagentstop": "SubagentStop",
            "subagentend": "SubagentStop", "stop": "Stop", "stopfailure": "StopFailure",
            "sessionend": "SessionEnd",
        ][collapsed]
    }

    func string(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
            if let value = dictionary[key], !(value is NSNull) { return String(describing: value) }
        }
        return nil
    }

    func projectName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    func parseTimestamp(_ value: String?) -> Date {
        guard let value else { return .now }
        if let date = try? Date(value, strategy: .iso8601) { return date }
        return ISO8601DateFormatter().date(from: value) ?? .now
    }

    func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct CodexTranscriptSnapshot {
    var metadata: [String: Any]
    var activity: CodexActivity
    var modifiedAt: Date
    var fileSize: Int
}

private struct CodexActivity {
    var state: AgentState
    var eventName: String
    var toolName: String?
}

private struct GrokBotCachedDocument {
    var modifiedAt: Date?
    var document: [String: Any]
}

struct GrokBotActivity {
    var state: AgentState
    var eventName: String
    var toolName: String?
    var updatedAt: Date
}

private struct CodexCloudTaskList: Decodable {
    var tasks: [CodexCloudTask]
}

private struct CodexCloudTask: Decodable {
    var id: String
    var url: String
    var title: String
    var status: String
    var updatedAt: String
    var environmentLabel: String?

    enum CodingKeys: String, CodingKey {
        case id, url, title, status
        case updatedAt = "updated_at"
        case environmentLabel = "environment_label"
    }
}

private struct LegacyLatestState: Decodable {
    var statuses: [LegacyLatestStatus]
}

private struct LegacyLatestStatus: Decodable {
    var provider: String
    var agentID: String
    var displayName: String
    var mode: String
    var updatedAt: String
    var eventName: String
    var sessionID: String?
    var cwd: String?
    var toolName: String?
    var message: String?
    var openURL: String?

    enum CodingKeys: String, CodingKey {
        case provider, mode, cwd, message
        case agentID = "agent_id"
        case displayName = "display_name"
        case updatedAt = "updated_at"
        case eventName = "event_name"
        case sessionID = "session_id"
        case toolName = "tool_name"
        case openURL = "open_url"
    }
}

private struct NativeLatestState: Encodable {
    var updatedAt: String
    var statuses: [NativeLatestStatus]
    enum CodingKeys: String, CodingKey { case updatedAt = "updated_at", statuses }
}

private struct NativeLatestStatus: Encodable {
    var provider: String
    var agentID: String
    var displayName: String
    var mode: String
    var modeLabel: String
    var priority: Int
    var updatedAt: String
    var ageSeconds: Double
    var eventName: String
    var sessionID: String?
    var cwd: String?
    var toolName: String?
    var message: String?
    var openURL: String?
    var origin: String?
    var stale: Bool

    enum CodingKeys: String, CodingKey {
        case provider, mode, priority, cwd, message, origin, stale
        case agentID = "agent_id"
        case displayName = "display_name"
        case modeLabel = "mode_label"
        case updatedAt = "updated_at"
        case ageSeconds = "age_seconds"
        case eventName = "event_name"
        case sessionID = "session_id"
        case toolName = "tool_name"
        case openURL = "open_url"
    }
}

private extension AgentState {
    init?(legacyValue: String) {
        switch legacyValue {
        case "idle_ready": self = .idle
        case "working": self = .working
        case "tool_running": self = .toolRunning
        case "long_task_progress": self = .working
        case "waiting_for_input": self = .waiting
        case "blocked_error": self = .error
        case "completed": self = .completed
        default: return nil
        }
    }

    var legacyValue: String {
        switch self {
        case .idle: "idle_ready"
        case .working: "working"
        case .toolRunning: "tool_running"
        case .waiting: "waiting_for_input"
        case .error: "blocked_error"
        case .completed: "completed"
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private final class LocalUnixEventServer: @unchecked Sendable {
    enum ServerError: Error { case alreadyInUse, pathTooLong, system(Int32) }

    private let path: String
    private let onData: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "io.sidepulse.unix-event-server")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, onData: @escaping @Sendable (Data) -> Void) {
        self.path = path
        self.onData = onData
    }

    func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: path) {
            if Self.canConnect(to: path) { throw ServerError.alreadyInUse }
            _ = Darwin.unlink(path)
        }

        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ServerError.system(errno) }
        descriptor = socketFD

        var address = try Self.address(for: path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let failure = errno
            Darwin.close(socketFD)
            descriptor = -1
            throw failure == EADDRINUSE ? ServerError.alreadyInUse : ServerError.system(failure)
        }
        _ = Darwin.chmod(path, S_IRUSR | S_IWUSR)
        guard Darwin.listen(socketFD, 16) == 0 else {
            let failure = errno
            stop()
            throw ServerError.system(failure)
        }
        _ = Darwin.fcntl(socketFD, F_SETFL, O_NONBLOCK)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        readSource.setCancelHandler { Darwin.close(socketFD) }
        source = readSource
        readSource.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        _ = Darwin.unlink(path)
    }

    private func acceptPendingConnections() {
        while descriptor >= 0 {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            read(client)
        }
    }

    private func read(_ client: Int32) {
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while payload.count <= 1_048_576 {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(client, $0.baseAddress, $0.count)
            }
            if count <= 0 { break }
            payload.append(buffer, count: count)
        }
        if !payload.isEmpty, payload.count <= 1_048_576 { onData(payload) }
    }

    private static func canConnect(to path: String) -> Bool {
        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { return false }
        defer { Darwin.close(client) }
        guard var address = try? address(for: path) else { return false }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }
}
