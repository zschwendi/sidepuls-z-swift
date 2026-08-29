import Darwin
import Foundation

/// Reads Codex Desktop's same-user thread stream without owning or modifying a thread.
/// Transcript discovery remains the fallback if Codex Desktop is closed or its IPC protocol changes.
final class CodexIPCBridge: @unchecked Sendable {
    private enum RequestKind {
        case initialize
        case discover(threadID: String)
        case load(threadID: String)
    }

    fileprivate struct LiveStatus: Equatable {
        var type: String
        var activeFlags: [String]

        var needsUser: Bool {
            type == "active" && activeFlags.contains(where: {
                $0 == "waitingOnApproval" || $0 == "waitingOnUserInput"
            })
        }
    }

    private let socketPath: String
    private let queue = DispatchQueue(label: "io.sidepulse.codex-ipc", qos: .utility)
    private let statusLock = NSLock()
    private var liveStatuses: [String: LiveStatus] = [:]

    private var started = false
    private var socket: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var retryWorkItem: DispatchWorkItem?
    private var readBuffer = Data()
    private var clientID = "initializing-client"
    private var desiredThreadIDs: Set<String> = []
    private var ownerByThreadID: [String: String] = [:]
    private var pendingDiscoveryThreadIDs: Set<String> = []
    private var ownerDiscoveryRetryAttempts: [String: Int] = [:]
    private var ownerDiscoveryRetryWorkItems: [String: DispatchWorkItem] = [:]
    private var requests: [String: RequestKind] = [:]
    private var onStatusChange: (@Sendable () -> Void)?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start(onStatusChange: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onStatusChange = onStatusChange
            guard !self.started else { return }
            self.started = true
            self.connectSocket()
        }
    }

    func stop() {
        queue.sync {
            started = false
            retryWorkItem?.cancel()
            retryWorkItem = nil
            onStatusChange = nil
            disconnect(scheduleReconnect: false)
        }
    }

    func observe(threadIDs: Set<String>) {
        queue.async { [weak self] in
            guard let self else { return }
            let removed = self.desiredThreadIDs.subtracting(threadIDs)
            for threadID in removed {
                self.pendingDiscoveryThreadIDs.remove(threadID)
                self.cancelOwnerDiscoveryRetry(threadID: threadID)
                if let ownerID = self.ownerByThreadID.removeValue(forKey: threadID) {
                    self.sendFollowing(threadID: threadID, ownerID: ownerID, following: false)
                }
            }
            self.desiredThreadIDs = threadIDs
            self.statusLock.lock()
            self.liveStatuses = self.liveStatuses.filter { threadIDs.contains($0.key) }
            self.statusLock.unlock()
            guard self.clientID != "initializing-client" else { return }
            for threadID in threadIDs where self.ownerByThreadID[threadID] == nil {
                self.discoverOwner(threadID: threadID)
            }
        }
    }

    func needsUser(threadID: String) -> Bool? {
        statusLock.lock()
        defer { statusLock.unlock() }
        return liveStatuses[threadID]?.needsUser
    }

    static func snapshotNeedsUser(in frame: Data) -> Bool? {
        guard let envelope = try? JSONDecoder().decode(CodexIPCEnvelope.self, from: frame),
              envelope.type == "broadcast",
              envelope.method == "thread-stream-state-changed",
              envelope.params?.change?.type == "snapshot",
              let status = envelope.params?.change?.conversationState?.threadRuntimeStatus
        else { return nil }
        return LiveStatus(type: status.type, activeFlags: status.activeFlags ?? []).needsUser
    }

    private func connectSocket() {
        guard started, socket < 0 else { return }

        let candidate = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard candidate >= 0 else {
            scheduleReconnect()
            return
        }

        var noPipe: Int32 = 1
        setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maximumPathLength else {
            Darwin.close(candidate)
            return
        }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: maximumPathLength) {
                    _ = strlcpy($0, source, maximumPathLength)
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(candidate)
            scheduleReconnect()
            return
        }

        socket = candidate
        readBuffer.removeAll(keepingCapacity: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: candidate, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.readAvailableBytes(estimatedCount: source.data)
        }
        source.setCancelHandler {
            Darwin.close(candidate)
        }
        readSource = source
        source.resume()
        sendRequest(method: "initialize", version: 0, params: ["clientType": "sidepulse"], kind: .initialize)
    }

    private func readAvailableBytes(estimatedCount: UInt) {
        guard socket >= 0 else { return }
        let count = max(4_096, min(Int(estimatedCount), 262_144))
        var bytes = [UInt8](repeating: 0, count: count)
        let bytesRead = Darwin.read(socket, &bytes, bytes.count)
        guard bytesRead > 0 else {
            disconnect(scheduleReconnect: started)
            return
        }
        readBuffer.append(contentsOf: bytes.prefix(bytesRead))
        processFrames()
    }

    private func processFrames() {
        var consumed = 0
        while readBuffer.count - consumed >= 4 {
            let frameLength = readBuffer.withUnsafeBytes { bytes -> Int in
                Int(UInt32(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: consumed,
                    as: UInt32.self
                )))
            }
            guard frameLength > 0, frameLength <= 256 * 1_024 * 1_024 else {
                disconnect(scheduleReconnect: started)
                return
            }
            guard readBuffer.count - consumed >= frameLength + 4 else { break }
            let start = consumed + 4
            handleFrame(readBuffer.subdata(in: start..<(start + frameLength)))
            consumed = start + frameLength
        }
        if consumed > 0 {
            readBuffer.removeSubrange(0..<consumed)
        }
    }

    private func handleFrame(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(CodexIPCEnvelope.self, from: data) else { return }

        if envelope.type == "response", let requestID = envelope.requestId,
           let request = requests.removeValue(forKey: requestID) {
            handleResponse(envelope, request: request)
            return
        }

        guard envelope.type == "broadcast" else { return }
        switch envelope.method {
        case "thread-stream-state-changed":
            guard let threadID = envelope.params?.conversationId,
                  desiredThreadIDs.contains(threadID),
                  let change = envelope.params?.change
            else { return }
            apply(change: change, threadID: threadID)
        case "client-status-changed", "ipc-connection-reset":
            ownerByThreadID.removeAll()
            pendingDiscoveryThreadIDs.removeAll()
            cancelAllOwnerDiscoveryRetries()
            clearLiveStatuses()
            for threadID in desiredThreadIDs { discoverOwner(threadID: threadID) }
        default:
            break
        }
    }

    private func handleResponse(_ envelope: CodexIPCEnvelope, request: RequestKind) {
        guard envelope.resultType == "success" else {
            if case let .discover(threadID) = request {
                pendingDiscoveryThreadIDs.remove(threadID)
                ownerByThreadID[threadID] = nil
                scheduleOwnerDiscoveryRetry(threadID: threadID)
            }
            return
        }

        switch request {
        case .initialize:
            guard let resolvedClientID = envelope.result?.clientId else { return }
            clientID = resolvedClientID
            for threadID in desiredThreadIDs { discoverOwner(threadID: threadID) }
        case let .discover(threadID):
            pendingDiscoveryThreadIDs.remove(threadID)
            guard desiredThreadIDs.contains(threadID) else {
                cancelOwnerDiscoveryRetry(threadID: threadID)
                return
            }
            guard let ownerID = envelope.handledByClientId else {
                scheduleOwnerDiscoveryRetry(threadID: threadID)
                return
            }
            cancelOwnerDiscoveryRetry(threadID: threadID)
            ownerByThreadID[threadID] = ownerID
            sendFollowing(threadID: threadID, ownerID: ownerID, following: true)
            sendRequest(
                method: "thread-follower-load-complete-history",
                version: 1,
                params: ["conversationId": threadID],
                targetClientID: ownerID,
                timeoutMilliseconds: 60_000,
                kind: .load(threadID: threadID)
            )
        case .load:
            break
        }
    }

    private func discoverOwner(threadID: String) {
        guard clientID != "initializing-client",
              desiredThreadIDs.contains(threadID),
              ownerByThreadID[threadID] == nil,
              pendingDiscoveryThreadIDs.insert(threadID).inserted
        else {
            return
        }
        let sent = sendRequest(
            method: "thread-owner-discovery",
            version: 1,
            params: ["hostId": "local", "conversationId": threadID],
            kind: .discover(threadID: threadID)
        )
        if !sent {
            pendingDiscoveryThreadIDs.remove(threadID)
            scheduleOwnerDiscoveryRetry(threadID: threadID)
        }
    }

    private func scheduleOwnerDiscoveryRetry(threadID: String) {
        guard started,
              socket >= 0,
              clientID != "initializing-client",
              desiredThreadIDs.contains(threadID),
              ownerByThreadID[threadID] == nil,
              !pendingDiscoveryThreadIDs.contains(threadID),
              ownerDiscoveryRetryWorkItems[threadID] == nil
        else { return }

        let attempt = min((ownerDiscoveryRetryAttempts[threadID] ?? 0) + 1, 6)
        ownerDiscoveryRetryAttempts[threadID] = attempt
        let delay = min(30.0, Double(1 << max(0, attempt - 1)))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ownerDiscoveryRetryWorkItems[threadID] = nil
            self.discoverOwner(threadID: threadID)
        }
        ownerDiscoveryRetryWorkItems[threadID] = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelOwnerDiscoveryRetry(threadID: String) {
        ownerDiscoveryRetryWorkItems.removeValue(forKey: threadID)?.cancel()
        ownerDiscoveryRetryAttempts[threadID] = nil
    }

    private func cancelAllOwnerDiscoveryRetries() {
        ownerDiscoveryRetryWorkItems.values.forEach { $0.cancel() }
        ownerDiscoveryRetryWorkItems.removeAll(keepingCapacity: true)
        ownerDiscoveryRetryAttempts.removeAll(keepingCapacity: true)
    }

    private func sendFollowing(threadID: String, ownerID: String, following: Bool) {
        sendMessage([
            "type": "broadcast",
            "method": "thread-stream-following-changed",
            "sourceClientId": clientID,
            "targetClientIds": [ownerID],
            "params": [
                "conversationId": threadID,
                "hostId": "local",
                "following": following,
            ],
            "version": 1,
        ])
    }

    @discardableResult
    private func sendRequest(
        method: String,
        version: Int,
        params: [String: Any],
        targetClientID: String? = nil,
        timeoutMilliseconds: Int = 10_000,
        kind: RequestKind
    ) -> Bool {
        let requestID = UUID().uuidString.lowercased()
        var message: [String: Any] = [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": clientID,
            "version": version,
            "method": method,
            "params": params,
            "timeoutMs": timeoutMilliseconds,
        ]
        if let targetClientID { message["targetClientId"] = targetClientID }
        requests[requestID] = kind
        let sent = sendMessage(message)
        if !sent { requests[requestID] = nil }
        return sent
    }

    @discardableResult
    private func sendMessage(_ message: [String: Any]) -> Bool {
        guard socket >= 0,
              let payload = try? JSONSerialization.data(withJSONObject: message)
        else { return false }
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)

        let result = frame.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(socket, base.advanced(by: written), bytes.count - written)
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        if !result { disconnect(scheduleReconnect: started) }
        return result
    }

    private func apply(change: CodexIPCChange, threadID: String) {
        switch change.type {
        case "snapshot":
            guard let status = change.conversationState?.threadRuntimeStatus else { return }
            set(status: LiveStatus(type: status.type, activeFlags: status.activeFlags ?? []), threadID: threadID)
        case "patches":
            for patch in change.patches ?? [] { apply(patch: patch, threadID: threadID) }
        default:
            break
        }
    }

    private func apply(patch: CodexIPCPatch, threadID: String) {
        let path = patch.path
        guard path.first?.key == "threadRuntimeStatus" else { return }

        statusLock.lock()
        var status = liveStatuses[threadID] ?? LiveStatus(type: "active", activeFlags: [])
        statusLock.unlock()

        if path.count == 1 {
            if patch.op == "remove" {
                status = LiveStatus(type: "inactive", activeFlags: [])
            } else if let replacement = patch.value?.runtimeStatus {
                status = replacement
            } else {
                return
            }
        } else if path[1].key == "type" {
            if patch.op == "remove" {
                status.type = "inactive"
            } else if let type = patch.value?.stringValue {
                status.type = type
            }
        } else if path[1].key == "activeFlags" {
            if path.count == 2 {
                status.activeFlags = patch.op == "remove" ? [] : (patch.value?.stringArray ?? [])
            } else if path.count == 3 {
                applyFlagPatch(patch, component: path[2], flags: &status.activeFlags)
            }
        } else {
            return
        }
        set(status: status, threadID: threadID)
    }

    private func applyFlagPatch(
        _ patch: CodexIPCPatch,
        component: CodexIPCPathComponent,
        flags: inout [String]
    ) {
        let index: Int
        switch component {
        case let .index(value): index = value
        case let .key(value) where value == "-": index = flags.count
        default: return
        }

        switch patch.op {
        case "add":
            guard let value = patch.value?.stringValue else { return }
            flags.insert(value, at: min(max(index, 0), flags.count))
        case "replace":
            guard flags.indices.contains(index), let value = patch.value?.stringValue else { return }
            flags[index] = value
        case "remove":
            guard flags.indices.contains(index) else { return }
            flags.remove(at: index)
        default:
            break
        }
    }

    private func set(status: LiveStatus, threadID: String) {
        statusLock.lock()
        let changed = liveStatuses[threadID] != status
        liveStatuses[threadID] = status
        statusLock.unlock()
        if changed { onStatusChange?() }
    }

    private func clearLiveStatuses() {
        statusLock.lock()
        let changed = !liveStatuses.isEmpty
        liveStatuses.removeAll()
        statusLock.unlock()
        if changed { onStatusChange?() }
    }

    private func disconnect(scheduleReconnect: Bool) {
        let source = readSource
        readSource = nil
        if let source {
            source.cancel()
        } else if socket >= 0 {
            Darwin.close(socket)
        }
        socket = -1
        clientID = "initializing-client"
        requests.removeAll()
        ownerByThreadID.removeAll()
        pendingDiscoveryThreadIDs.removeAll()
        cancelAllOwnerDiscoveryRetries()
        readBuffer.removeAll(keepingCapacity: true)
        clearLiveStatuses()
        if scheduleReconnect { self.scheduleReconnect() }
    }

    private func scheduleReconnect() {
        guard started, retryWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.connectSocket()
        }
        retryWorkItem = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

private struct CodexIPCEnvelope: Decodable {
    var type: String
    var requestId: String?
    var resultType: String?
    var method: String?
    var handledByClientId: String?
    var result: CodexIPCResult?
    var params: CodexIPCParams?
}

private struct CodexIPCResult: Decodable {
    var clientId: String?
}

private struct CodexIPCParams: Decodable {
    var conversationId: String?
    var change: CodexIPCChange?
}

private struct CodexIPCChange: Decodable {
    var type: String
    var conversationState: CodexIPCConversationState?
    var patches: [CodexIPCPatch]?
}

private struct CodexIPCConversationState: Decodable {
    var threadRuntimeStatus: CodexIPCRuntimeStatus?
}

private struct CodexIPCRuntimeStatus: Decodable {
    var type: String
    var activeFlags: [String]?
}

private struct CodexIPCPatch: Decodable {
    var op: String
    var path: [CodexIPCPathComponent]
    var value: CodexIPCJSONValue?
}

private enum CodexIPCPathComponent: Decodable {
    case key(String)
    case index(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .index(value)
        } else {
            self = .key(try container.decode(String.self))
        }
    }

    var key: String? {
        if case let .key(value) = self { value } else { nil }
    }
}

private indirect enum CodexIPCJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([CodexIPCJSONValue])
    case object([String: CodexIPCJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([CodexIPCJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: CodexIPCJSONValue].self)) }
    }

    var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }

    var stringArray: [String]? {
        guard case let .array(values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    var runtimeStatus: CodexIPCBridge.LiveStatus? {
        guard case let .object(object) = self,
              let type = object["type"]?.stringValue
        else { return nil }
        return CodexIPCBridge.LiveStatus(
            type: type,
            activeFlags: object["activeFlags"]?.stringArray ?? []
        )
    }
}
