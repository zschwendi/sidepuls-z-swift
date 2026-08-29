import Foundation
import Network
import OSLog

final class NearbySidePulseService: @unchecked Sendable {
    static let serviceType = "_sidepulse-z._tcp"
    private static let maximumInboundConnections = 16
    private static let logger = Logger(
        subsystem: "com.zephyrstudiosllc.sidepulse-z",
        category: "NearbySignal"
    )

    typealias PeerHandler = @Sendable ([NearbySignalPeer]) -> Void
    typealias SignalHandler = @Sendable (ReceivedNearbySignal) -> Void
    typealias StatusHandler = @Sendable (String) -> Void

    let nodeID: String
    let displayName: String
    let serviceName: String

    private struct DiscoveredPeer {
        var peer: NearbySignalPeer
        var endpoint: NWEndpoint
    }

    private let queue: DispatchQueue
    private let onPeers: PeerHandler
    private let onSignal: SignalHandler
    private let onStatus: StatusHandler

    private var mode: NearbyMirroringMode = .off
    private var selectedPeerID: String?
    private var latestLocalFrame: NearbySignalFrame?

    private var listener: NWListener?
    private var listenerGeneration = UUID()
    private var inboundConnections: [UUID: NWConnection] = [:]
    private var readyInboundConnections = Set<UUID>()
    private var pendingInboundSends = Set<UUID>()
    private var heartbeat: DispatchSourceTimer?

    private var browser: NWBrowser?
    private var browserGeneration = UUID()
    private var discoveredPeers: [String: DiscoveredPeer] = [:]
    private var outboundConnections: [String: NWConnection] = [:]
    private var outboundGenerations: [String: UUID] = [:]
    private var outboundDecoders: [String: NearbySignalStreamDecoder] = [:]
    private var readyOutboundPeers = Set<String>()

    init(
        nodeID: String,
        displayName: String,
        onPeers: @escaping PeerHandler,
        onSignal: @escaping SignalHandler,
        onStatus: @escaping StatusHandler
    ) {
        self.nodeID = nodeID
        self.displayName = displayName
        serviceName = Self.makeServiceName(displayName: displayName, nodeID: nodeID)
        queue = DispatchQueue(label: "com.zephyrstudiosllc.sidepulse-z.nearby-signal")
        self.onPeers = onPeers
        self.onSignal = onSignal
        self.onStatus = onStatus
    }

    deinit {
        listener?.cancel()
        browser?.cancel()
        heartbeat?.cancel()
        inboundConnections.values.forEach { $0.cancel() }
        outboundConnections.values.forEach { $0.cancel() }
    }

    func configure(mode: NearbyMirroringMode, selectedPeerID: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.mode = mode
            self.selectedPeerID = selectedPeerID
            self.reconcileListenerLocked()
            self.reconcileBrowserLocked()
            self.reconcileOutboundConnectionsLocked()
            self.publishStatusLocked()
        }
    }

    func updateLocalFrame(_ frame: NearbySignalFrame) {
        queue.async { [weak self] in
            guard let self,
                  frame.sourceNodeID == self.nodeID,
                  (try? frame.validated()) != nil
            else { return }
            self.latestLocalFrame = frame
            guard self.mode.sharesLocalSignal else { return }
            self.sendLatestFrameToInboundConnectionsLocked()
        }
    }

    func stop() {
        queue.sync {
            mode = .off
            stopListenerLocked()
            stopBrowserLocked()
            onPeers([])
            reportStatusLocked("Mirroring is off")
        }
    }

    static func makeServiceName(displayName: String, nodeID: String) -> String {
        var label = displayName
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { label = "Mac" }
        label = String(label.prefix(20))
        let suffix = "--\(nodeID.lowercased())"
        while !label.isEmpty,
              "\(label)\(suffix)".lengthOfBytes(using: .utf8) > 63 {
            label.removeLast()
        }
        return "\(label)\(suffix)"
    }

    static func peer(fromServiceName serviceName: String) -> NearbySignalPeer? {
        guard let divider = serviceName.range(of: "--", options: .backwards) else { return nil }
        let displayName = String(serviceName[..<divider.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nodeID = String(serviceName[divider.upperBound...]).lowercased()
        guard !displayName.isEmpty, UUID(uuidString: nodeID) != nil else { return nil }
        return NearbySignalPeer(id: nodeID, displayName: displayName)
    }

    private func reconcileListenerLocked() {
        if mode.sharesLocalSignal {
            startListenerLocked()
        } else {
            stopListenerLocked()
        }
    }

    private func startListenerLocked() {
        guard mode.sharesLocalSignal, listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            let generation = UUID()
            listenerGeneration = generation
            listener.service = NWListener.Service(
                name: serviceName,
                type: Self.serviceType,
                domain: nil,
                txtRecord: nil
            )
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerStateLocked(state, generation: generation)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptInboundConnectionLocked(connection)
            }
            self.listener = listener
            startHeartbeatLocked()
            listener.start(queue: queue)
        } catch {
            reportStatusLocked("Couldn’t share this Mac: \(error.localizedDescription)")
        }
    }

    private func handleListenerStateLocked(_ state: NWListener.State, generation: UUID) {
        guard generation == listenerGeneration else { return }
        switch state {
        case .ready:
            publishStatusLocked()
        case .failed(let error):
            reportStatusLocked("Couldn’t share this Mac: \(error.localizedDescription)")
            stopListenerLocked()
            guard mode.sharesLocalSignal else { return }
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startListenerLocked()
            }
        case .waiting(let error):
            reportStatusLocked("Waiting to share on the local network: \(error.localizedDescription)")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func acceptInboundConnectionLocked(_ connection: NWConnection) {
        guard mode.sharesLocalSignal,
              inboundConnections.count < Self.maximumInboundConnections
        else {
            connection.cancel()
            return
        }
        let id = UUID()
        inboundConnections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.readyInboundConnections.insert(id)
                self.sendLatestFrameLocked(to: id)
                self.publishStatusLocked()
            case .failed, .cancelled:
                self.removeInboundConnectionLocked(id: id, cancel: false)
                self.publishStatusLocked()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func startHeartbeatLocked() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.sendLatestFrameToInboundConnectionsLocked()
        }
        heartbeat = timer
        timer.resume()
    }

    private func stopListenerLocked() {
        listenerGeneration = UUID()
        listener?.cancel()
        listener = nil
        heartbeat?.cancel()
        heartbeat = nil
        inboundConnections.values.forEach {
            $0.stateUpdateHandler = nil
            $0.cancel()
        }
        inboundConnections.removeAll(keepingCapacity: true)
        readyInboundConnections.removeAll(keepingCapacity: true)
        pendingInboundSends.removeAll(keepingCapacity: true)
    }

    private func sendLatestFrameToInboundConnectionsLocked() {
        guard mode.sharesLocalSignal else { return }
        for id in readyInboundConnections where !pendingInboundSends.contains(id) {
            sendLatestFrameLocked(to: id)
        }
    }

    private func sendLatestFrameLocked(to id: UUID) {
        guard mode.sharesLocalSignal,
              readyInboundConnections.contains(id),
              !pendingInboundSends.contains(id),
              let connection = inboundConnections[id],
              var frame = latestLocalFrame
        else { return }
        frame.sentAt = .now
        guard let encoded = try? JSONEncoder().encode(frame),
              encoded.count <= NearbySignalStreamDecoder.maximumLineBytes
        else { return }
        var message = encoded
        message.append(0x0A)
        pendingInboundSends.insert(id)
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.pendingInboundSends.remove(id)
                if error != nil {
                    self.removeInboundConnectionLocked(id: id, cancel: true)
                    self.publishStatusLocked()
                }
            }
        })
    }

    private func removeInboundConnectionLocked(id: UUID, cancel: Bool) {
        readyInboundConnections.remove(id)
        pendingInboundSends.remove(id)
        guard let connection = inboundConnections.removeValue(forKey: id) else { return }
        connection.stateUpdateHandler = nil
        if cancel {
            connection.cancel()
        }
    }

    private func reconcileBrowserLocked() {
        if mode.receivesNearbySignals {
            startBrowserLocked()
        } else {
            stopBrowserLocked()
        }
    }

    private func startBrowserLocked() {
        guard mode.receivesNearbySignals, browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )
        let generation = UUID()
        browserGeneration = generation
        browser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserStateLocked(state, generation: generation)
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResultsLocked(results, generation: generation)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func handleBrowserStateLocked(_ state: NWBrowser.State, generation: UUID) {
        guard generation == browserGeneration else { return }
        switch state {
        case .ready:
            publishStatusLocked()
        case .failed(let error):
            reportStatusLocked("Nearby discovery failed: \(error.localizedDescription)")
            stopBrowserLocked()
            guard mode.receivesNearbySignals else { return }
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startBrowserLocked()
            }
        case .waiting(let error):
            reportStatusLocked("Waiting for Local Network access: \(error.localizedDescription)")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func handleBrowseResultsLocked(
        _ results: Set<NWBrowser.Result>,
        generation: UUID
    ) {
        guard generation == browserGeneration else { return }
        var next = [String: DiscoveredPeer]()
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  let peer = Self.peer(fromServiceName: name),
                  peer.id != nodeID
            else { continue }
            next[peer.id] = DiscoveredPeer(peer: peer, endpoint: result.endpoint)
        }
        discoveredPeers = next
        Self.logger.debug("Discovered \(next.count, privacy: .public) nearby SidePulse peer(s)")
        onPeers(next.values.map(\.peer).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        })
        reconcileOutboundConnectionsLocked()
        publishStatusLocked()
    }

    private func stopBrowserLocked() {
        browserGeneration = UUID()
        browser?.cancel()
        browser = nil
        discoveredPeers.removeAll(keepingCapacity: true)
        cancelAllOutboundConnectionsLocked()
        onPeers([])
    }

    private func reconcileOutboundConnectionsLocked() {
        let desiredPeerIDs: Set<String>
        switch mode {
        case .followNearbyMac:
            if let selectedPeerID, discoveredPeers[selectedPeerID] != nil {
                desiredPeerIDs = [selectedPeerID]
            } else {
                desiredPeerIDs = []
            }
        case .allMacs:
            desiredPeerIDs = Set(discoveredPeers.keys)
        case .off, .shareThisMac:
            desiredPeerIDs = []
        }

        for peerID in Array(outboundConnections.keys) where !desiredPeerIDs.contains(peerID) {
            cancelOutboundConnectionLocked(peerID: peerID)
        }
        for peerID in desiredPeerIDs where outboundConnections[peerID] == nil {
            connectToPeerLocked(peerID: peerID)
        }
    }

    private func connectToPeerLocked(peerID: String) {
        guard let discovered = discoveredPeers[peerID] else { return }
        let connection = NWConnection(to: discovered.endpoint, using: .tcp)
        let generation = UUID()
        outboundConnections[peerID] = connection
        outboundGenerations[peerID] = generation
        outboundDecoders[peerID] = NearbySignalStreamDecoder()
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleOutboundStateLocked(
                state,
                peerID: peerID,
                generation: generation
            )
        }
        connection.start(queue: queue)
    }

    private func handleOutboundStateLocked(
        _ state: NWConnection.State,
        peerID: String,
        generation: UUID
    ) {
        guard outboundGenerations[peerID] == generation else { return }
        switch state {
        case .ready:
            readyOutboundPeers.insert(peerID)
            Self.logger.info("Connected to nearby SidePulse peer \(peerID, privacy: .public)")
            receiveNextFrameLocked(peerID: peerID, generation: generation)
            publishStatusLocked()
        case .waiting(let error):
            reportStatusLocked("Waiting for nearby Mac: \(error.localizedDescription)")
        case .failed, .cancelled:
            cancelOutboundConnectionLocked(peerID: peerID)
            publishStatusLocked()
            guard mode.receivesNearbySignals, discoveredPeers[peerID] != nil else { return }
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.reconcileOutboundConnectionsLocked()
            }
        default:
            break
        }
    }

    private func receiveNextFrameLocked(peerID: String, generation: UUID) {
        guard outboundGenerations[peerID] == generation,
              let connection = outboundConnections[peerID]
        else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            [weak self] data, _, isComplete, error in
            guard let self,
                  self.outboundGenerations[peerID] == generation
            else { return }

            if let data, !data.isEmpty {
                var decoder = self.outboundDecoders[peerID] ?? NearbySignalStreamDecoder()
                let frames = decoder.append(data)
                self.outboundDecoders[peerID] = decoder
                for frame in frames where frame.sourceNodeID == peerID && frame.sourceNodeID != self.nodeID {
                    Self.logger.debug(
                        "Received nearby signal sequence \(frame.sequence, privacy: .public) from \(peerID, privacy: .public)"
                    )
                    self.onSignal(
                        ReceivedNearbySignal(
                            peerID: peerID,
                            frame: frame,
                            receivedAt: .now
                        )
                    )
                }
            }

            if isComplete || error != nil {
                self.cancelOutboundConnectionLocked(peerID: peerID)
                self.publishStatusLocked()
                guard self.mode.receivesNearbySignals,
                      self.discoveredPeers[peerID] != nil
                else { return }
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.reconcileOutboundConnectionsLocked()
                }
            } else {
                self.receiveNextFrameLocked(peerID: peerID, generation: generation)
            }
        }
    }

    private func cancelOutboundConnectionLocked(peerID: String) {
        readyOutboundPeers.remove(peerID)
        outboundGenerations[peerID] = nil
        outboundDecoders[peerID] = nil
        if let connection = outboundConnections.removeValue(forKey: peerID) {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    private func cancelAllOutboundConnectionsLocked() {
        for peerID in Array(outboundConnections.keys) {
            cancelOutboundConnectionLocked(peerID: peerID)
        }
    }

    private func publishStatusLocked() {
        switch mode {
        case .off:
            reportStatusLocked("Mirroring is off")
        case .shareThisMac:
            let count = readyInboundConnections.count
            reportStatusLocked(count == 0
                ? "Available to nearby Macs"
                : "Sharing with \(count) nearby Mac\(count == 1 ? "" : "s")")
        case .followNearbyMac:
            guard let selectedPeerID else {
                reportStatusLocked(discoveredPeers.isEmpty ? "Looking for nearby Macs…" : "Choose a nearby Mac")
                return
            }
            let name = discoveredPeers[selectedPeerID]?.peer.displayName ?? "selected Mac"
            reportStatusLocked(readyOutboundPeers.contains(selectedPeerID)
                ? "Connected to \(name)"
                : "Waiting for \(name)…")
        case .allMacs:
            let count = readyOutboundPeers.count
            reportStatusLocked(count == 0
                ? "Sharing this Mac · looking for others…"
                : "Sharing and watching \(count) nearby Mac\(count == 1 ? "" : "s")")
        }
    }

    private func reportStatusLocked(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        onStatus(message)
    }
}
