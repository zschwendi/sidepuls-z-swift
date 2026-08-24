import Foundation
import IOKit
import IOKit.ps

final class SidePulseHardwareController: @unchecked Sendable {
    typealias UpdateHandler = @Sendable (DeviceState) -> Void

    private let queue = DispatchQueue(label: "io.sidepulse.hardware-controller")
    private let onUpdate: UpdateHandler
    private var timer: DispatchSourceTimer?
    private var state = DeviceState()
    private var outputEnabled = false
    private var requestedProgram = "off"
    private var lastWrittenProgram: String?
    private var previewGeneration = 0
    private let outputDisabledByEnvironment: Bool

    init(onUpdate: @escaping UpdateHandler) {
        self.onUpdate = onUpdate
        outputDisabledByEnvironment = ["1", "true", "yes"].contains(
            ProcessInfo.processInfo.environment["SIDEPULSE_DISABLE_DEVICE_OUTPUT"]?.lowercased() ?? ""
        )
    }

    func start() {
        queue.async { [weak self] in
            guard let self, timer == nil else { return }
            refreshDeviceLocked()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 0.5, repeating: 1, leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.refreshDeviceLocked() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if outputEnabled { try? writeLocked("off", remember: false) }
            outputEnabled = false
        }
    }

    func update(enabled: Bool, program: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let wasEnabled = outputEnabled
            outputEnabled = enabled
            requestedProgram = program
            previewGeneration += 1
            if enabled {
                tryWriteRequestedLocked()
            } else if wasEnabled {
                do {
                    try writeLocked("off", remember: true)
                } catch {
                    recordErrorLocked(error)
                }
            }
        }
    }

    func preview(program: String, duration: TimeInterval = 3) {
        queue.async { [weak self] in
            guard let self, state.connected else { return }
            previewGeneration += 1
            let generation = previewGeneration
            do {
                try writeLocked(program, remember: false)
            } catch {
                recordErrorLocked(error)
                return
            }
            queue.asyncAfter(deadline: .now() + max(0.5, duration)) { [weak self] in
                guard let self, generation == previewGeneration else { return }
                let restore = outputEnabled ? requestedProgram : "off"
                do {
                    try writeLocked(restore, remember: outputEnabled)
                } catch {
                    recordErrorLocked(error)
                }
            }
        }
    }

    private func refreshDeviceLocked() {
        let discovered = Self.discoverDevice()
        var next = discovered ?? DeviceState()
        if next.connected, next.path == state.path {
            next.lastWrite = state.lastWrite
            next.lastError = state.lastError
        }
        let changed = next != state
        state = next
        if changed { onUpdate(state) }
        if state.connected, outputEnabled { tryWriteRequestedLocked() }
    }

    private func tryWriteRequestedLocked() {
        guard state.connected, requestedProgram != lastWrittenProgram else { return }
        do {
            try writeLocked(requestedProgram, remember: true)
        } catch {
            recordErrorLocked(error)
        }
    }

    private func writeLocked(_ program: String, remember: Bool) throws {
        guard !outputDisabledByEnvironment else { throw HardwareError.outputDisabledForTest }
        guard state.connected else { throw HardwareError.deviceNotConnected }
        let data = Data(program.utf8)
        guard !data.isEmpty else { throw HardwareError.emptyProgram }
        guard data.count <= 512 else { throw HardwareError.programTooLarge(data.count) }
        guard program.split(whereSeparator: \.isNewline).count <= 20 else { throw HardwareError.tooManyLines }
        try program.write(
            to: URL(fileURLWithPath: state.path),
            atomically: false,
            encoding: .utf8
        )
        if remember { lastWrittenProgram = program }
        state.lastWrite = .now
        state.lastError = nil
        onUpdate(state)
    }

    private func recordErrorLocked(_ error: Error) {
        state.lastError = error.localizedDescription
        onUpdate(state)
    }

    private static func discoverDevice() -> DeviceState? {
        let root = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let volumes = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = volumes.compactMap { volume -> DeviceState? in
            guard (try? volume.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let normalized = volume.lastPathComponent.lowercased().filter(\.isLetter)
            let isPro = normalized.contains("sidepulsepro")
            let isDot = normalized.contains("sidepulsedot")
            let target = volume.appending(path: "LEDS.LED")
            guard isPro || isDot || FileManager.default.fileExists(atPath: target.path) else { return nil }
            return DeviceState(
                name: isDot ? "SidePulse Dot" : "SidePulse Pro",
                path: target.path,
                ledCount: isDot ? 2 : 8,
                connected: true
            )
        }
        return candidates.sorted {
            if $0.ledCount != $1.ledCount { return $0.ledCount > $1.ledCount }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }.first
    }
}

final class LidStateMonitor: @unchecked Sendable {
    typealias UpdateHandler = @Sendable (_ isClosed: Bool, _ isTransition: Bool) -> Void

    private let queue = DispatchQueue(label: "io.sidepulse.lid-state-monitor", qos: .utility)
    private let onUpdate: UpdateHandler
    private var timer: DispatchSourceTimer?
    private var lastState: Bool?

    init(onUpdate: @escaping UpdateHandler) {
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            guard let self, timer == nil else { return }
            sampleLocked()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
            source.setEventHandler { [weak self] in self?.sampleLocked() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func sampleLocked() {
        guard let isClosed = Self.readClamshellState(), isClosed != lastState else { return }
        let isTransition = lastState != nil
        lastState = isClosed
        onUpdate(isClosed, isTransition)
    }

    private static func readClamshellState() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        return value as? Bool
    }
}

struct BatteryState: Equatable, Sendable {
    var chargeFraction: Double
    var isCharging: Bool
    var isExternallyPowered: Bool

    var isLowAndDischarging: Bool {
        chargeFraction <= 0.25 && !isCharging && !isExternallyPowered
    }
}

final class BatteryStateMonitor: @unchecked Sendable {
    typealias UpdateHandler = @Sendable (BatteryState?) -> Void

    private let queue = DispatchQueue(label: "io.sidepulse.battery-state-monitor", qos: .utility)
    private let onUpdate: UpdateHandler
    private var timer: DispatchSourceTimer?

    init(onUpdate: @escaping UpdateHandler) {
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            guard let self, timer == nil else { return }
            sampleLocked()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.sampleLocked() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func sampleLocked() {
        onUpdate(Self.currentState())
    }

    static func currentState() -> BatteryState? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                maximum > 0
            else { continue }

            let powerSource = description[kIOPSPowerSourceStateKey] as? String
            return BatteryState(
                chargeFraction: max(0, min(1, current / maximum)),
                isCharging: (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false,
                isExternallyPowered: powerSource == kIOPSACPowerValue
            )
        }
        return nil
    }
}

private enum HardwareError: LocalizedError {
    case deviceNotConnected
    case emptyProgram
    case programTooLarge(Int)
    case tooManyLines
    case outputDisabledForTest

    var errorDescription: String? {
        switch self {
        case .deviceNotConnected: "No SidePulse device is mounted."
        case .emptyProgram: "The LED program is empty."
        case .programTooLarge(let bytes): "The LED program is \(bytes) bytes; the maximum is 512."
        case .tooManyLines: "The LED program has more than 20 lines."
        case .outputDisabledForTest: "Device output is disabled for this test run."
        }
    }
}
