import Foundation

@main
enum NearbySignalSmoke {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let localID = UUID().uuidString.lowercased()
        let remoteID = UUID().uuidString.lowercased()
        let local = frame(
            nodeID: localID,
            state: .working,
            program: "brightness 255\n0:#FF00FF\nrepeat",
            at: now.addingTimeInterval(-4)
        )
        let remote = frame(
            nodeID: remoteID,
            state: .waiting,
            program: "brightness 255\n0:#FFFF00",
            at: now.addingTimeInterval(-2)
        )

        let encoded = try JSONEncoder().encode(remote)
        let json = try require(String(data: encoded, encoding: .utf8))
        for forbiddenKey in ["agents", "slots", "project", "cwd", "message", "profileName", "devicePath"] {
            precondition(!json.contains("\"\(forbiddenKey)\""))
        }

        var wire = encoded
        wire.append(0x0A)
        var decoder = NearbySignalStreamDecoder()
        let midpoint = wire.count / 2
        precondition(decoder.append(wire[..<midpoint]).isEmpty)
        let decoded = decoder.append(wire[midpoint...])
        precondition(decoded == [remote])

        var oversized = remote
        oversized.proProgram = String(repeating: "x", count: NearbySignalFrame.maximumProgramBytes + 1)
        do {
            _ = try oversized.validated()
            preconditionFailure("Oversized programs must be rejected")
        } catch NearbySignalFrameError.invalidProgramSize {
            // Expected.
        }

        let compilerPrograms = [
            "off",
            "brightness 0\noff",
            "brightness 128\n0:#FF0000;1:#00FF00",
            "off\n0:#6A1259 600ms pulse;7:#6A1259 600ms pulse 430ms\nrepeat",
            "brightness 128\noff\n0:#FFD60A 740ms none;1:#FFD60A 740ms none\nrepeat",
            "off\n0:#FF2BD6 1.51s pulse;7:#FF2BD6 1.51s pulse 1.09s\nrepeat",
            "brightness 255\n#4D4D4D\n0:#FF9F0A 120ms cosine;3:#FF9F0A 120ms cosine 378ms",
        ]
        for program in compilerPrograms {
            var generated = remote
            generated.proProgram = program
            let accepted = (try? generated.validated()) != nil
            precondition(accepted, "Compiler output must validate: \(program)")
        }

        for easing in ["linear", "ease", "ease-in", "ease-out", "ease-in-out", "cosine", "pulse", "none"] {
            var generated = remote
            generated.proProgram = "0:#FF0000 100ms \(easing) 20ms"
            let accepted = (try? generated.validated()) != nil
            precondition(accepted, "Allowed easing must validate: \(easing)")
        }

        let rendererPrograms = [
            "off 2s none",
            "#FF0000",
            "#FF0000 2s none",
            "#FF0000 #00FF00",
        ]
        for program in rendererPrograms {
            var generated = remote
            generated.proProgram = program
            let accepted = (try? generated.validated()) != nil
            precondition(accepted, "Renderer DSL must validate: \(program)")
        }

        let invalidPrograms = [
            "run arbitrary command",
            "brightness 256",
            "brightness -1",
            "brightness 1.5",
            "brightness 01",
            "brightness 255 extra",
            "8:#FF0000",
            "0:#FF00F",
            "0:#GG0000",
            "0:#FF0000 500",
            "0:#FF0000 linear",
            "0:#FF0000 0ms pulse",
            "0:#FF0000 -1ms pulse",
            "0:#FF0000 500ms wobble",
            "0:#FF0000 500ms pulse 20",
            "0:#FF0000 500ms pulse 20ms extra",
            "0:#FF0000 1.234s pulse",
            "0:#FF0000\t500ms pulse",
            "0:#FF0000;;1:#000000",
            "0:#FF0000; ;1:#000000",
            "#FF0000 500ms wobble",
            "repeat forever",
            "off now",
            "off\n",
        ]
        for program in invalidPrograms {
            var malformed = remote
            malformed.proProgram = program
            let rejected = (try? malformed.validated()) == nil
            precondition(rejected, "Malformed program must be rejected: \(program)")
        }

        var tooManyLines = remote
        tooManyLines.proProgram = Array(repeating: "off", count: NearbySignalFrame.maximumProgramLines + 1)
            .joined(separator: "\n")
        do {
            _ = try tooManyLines.validated()
            preconditionFailure("Programs over the line limit must be rejected")
        } catch NearbySignalFrameError.invalidProgramLines {
            // Expected.
        }

        var invalidDot = remote
        invalidDot.dotProgram = "0:#000000 0s none"
        let dotRejected = (try? invalidDot.validated()) == nil
        precondition(dotRejected, "The Dot program must be validated independently")

        let receipt = ReceivedNearbySignal(
            peerID: remoteID,
            frame: remote,
            receivedAt: now
        )
        let receipts = [remoteID: receipt]

        let localRoute = try require(NearbySignalRouter.route(
            mode: .off,
            selectedPeerID: nil,
            localFrame: local,
            receivedSignals: receipts,
            now: now
        ))
        precondition(localRoute.frame.sourceNodeID == localID)
        precondition(!localRoute.isRemote)

        let outboundRoute = try require(NearbySignalRouter.route(
            mode: .shareThisMac,
            selectedPeerID: nil,
            localFrame: local,
            receivedSignals: receipts,
            now: now
        ))
        precondition(outboundRoute.frame.sourceNodeID == localID)

        let followed = try require(NearbySignalRouter.route(
            mode: .followNearbyMac,
            selectedPeerID: remoteID,
            localFrame: local,
            receivedSignals: receipts,
            now: now
        ))
        precondition(followed.frame.sourceNodeID == remoteID)
        precondition(followed.isRemote)
        precondition(abs(followed.clockOrigin.timeIntervalSince(now.addingTimeInterval(-2))) < 0.001)

        let allMacs = try require(NearbySignalRouter.route(
            mode: .allMacs,
            selectedPeerID: nil,
            localFrame: local,
            receivedSignals: receipts,
            now: now
        ))
        precondition(allMacs.frame.sourceNodeID == remoteID, "Approval must outrank thinking")

        var finished = remote
        finished.aggregateState = .completed
        let finishedReceipt = ReceivedNearbySignal(peerID: remoteID, frame: finished, receivedAt: now)
        let thinkingWins = try require(NearbySignalRouter.route(
            mode: .allMacs,
            selectedPeerID: nil,
            localFrame: local,
            receivedSignals: [remoteID: finishedReceipt],
            now: now
        ))
        precondition(thinkingWins.frame.sourceNodeID == localID, "Thinking must outrank finished")

        let staleReceipt = ReceivedNearbySignal(
            peerID: remoteID,
            frame: remote,
            receivedAt: now.addingTimeInterval(-(NearbySignalRouter.staleAfter + 0.1))
        )
        precondition(NearbySignalRouter.route(
            mode: .followNearbyMac,
            selectedPeerID: remoteID,
            localFrame: local,
            receivedSignals: [remoteID: staleReceipt],
            now: now
        ) == nil)

        var selfFrame = remote
        selfFrame.sourceNodeID = localID
        let selfReceipt = ReceivedNearbySignal(peerID: localID, frame: selfFrame, receivedAt: now)
        precondition(NearbySignalRouter.route(
            mode: .followNearbyMac,
            selectedPeerID: localID,
            localFrame: local,
            receivedSignals: [localID: selfReceipt],
            now: now
        ) == nil)

        print("Nearby signal smoke passed: strict programs, private frames, routing direction, priority, loop rejection, and staleness")
    }

    private static func frame(
        nodeID: String,
        state: AgentState,
        program: String,
        at date: Date
    ) -> NearbySignalFrame {
        NearbySignalFrame(
            sourceNodeID: nodeID,
            sequence: 1,
            generatedAt: date,
            sentAt: date.addingTimeInterval(2),
            programStartedAt: date,
            aggregateState: state,
            hasVisibleActivity: true,
            proProgram: program,
            dotProgram: "brightness 255\n0:#FF00FF"
        )
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw NSError(domain: "NearbySignalSmoke", code: 1)
        }
        return value
    }
}
