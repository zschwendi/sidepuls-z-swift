import Foundation
import IOKit
import IOKit.ps

enum HardwareUpdateTiming: Equatable, Sendable {
    case immediate
    case animationBoundary(cycleSeconds: TimeInterval)
}

final class SidePulseHardwareController: @unchecked Sendable {
    typealias UpdateHandler = @Sendable (DeviceState) -> Void

    private let queue: DispatchQueue
    private let kind: SidePulseDeviceKind
    private let onUpdate: UpdateHandler
    private var timer: DispatchSourceTimer?
    private var state: DeviceState
    private var outputEnabled = false
    private var requestedProgram = "off"
    private var lastWrittenProgram: String?
    private var lastProgramStartedAt: Date?
    private var previewGeneration = 0
    private var activePreviewGeneration: Int?
    private var deferredWriteGeneration = 0
    private var deferredWriteDeadline: Date?
    private let outputDisabledByEnvironment: Bool

    static func refreshInterval(for program: String) -> TimeInterval? {
        let trimmed = program.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "off" else { return nil }
        return program.split(whereSeparator: \.isNewline).contains("repeat") ? 5 : 15
    }

    init(kind: SidePulseDeviceKind, onUpdate: @escaping UpdateHandler) {
        self.kind = kind
        queue = DispatchQueue(label: "io.sidepulse.hardware-controller.\(kind.rawValue)")
        self.onUpdate = onUpdate
        state = kind.disconnectedState
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
            cancelPreviewLocked()
            cancelDeferredWriteLocked()
            if outputEnabled { try? writeLocked("off", remember: false) }
            outputEnabled = false
        }
    }

    func update(
        enabled: Bool,
        program: String,
        brightnessScale: Double = 1,
        timing: HardwareUpdateTiming = .immediate
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let calibratedProgram = LEDProgramOutputCalibration.applying(
                to: program,
                brightnessScale: kind.calibratedBrightnessScale(
                    universalBrightness: brightnessScale
                ),
                blueScale: kind.outputBlueScale
            )
            let wasEnabled = outputEnabled
            let enabledChanged = enabled != outputEnabled
            let programChanged = calibratedProgram != requestedProgram
            guard enabledChanged || programChanged else { return }
            outputEnabled = enabled
            requestedProgram = calibratedProgram
            if !enabled {
                cancelPreviewLocked()
                cancelDeferredWriteLocked()
                if !wasEnabled { return }
                do {
                    try writeLocked("off", remember: true)
                } catch {
                    recordErrorLocked(error)
                }
                return
            }

            // System and manual previews own the LEDs for their full, short
            // duration. Agent updates still replace requestedProgram above, so
            // the newest underlying scene is restored when the preview ends.
            if activePreviewGeneration != nil { return }

            if !wasEnabled {
                cancelPreviewLocked()
                cancelDeferredWriteLocked()
                tryWriteRequestedLocked(force: true)
                return
            }

            switch timing {
            case .immediate:
                let wasPreviewActive = activePreviewGeneration != nil
                cancelPreviewLocked()
                cancelDeferredWriteLocked()
                tryWriteRequestedLocked(force: wasPreviewActive)
            case .animationBoundary(let cycleSeconds):
                guard activePreviewGeneration == nil else { return }
                scheduleRequestedWriteAtBoundaryLocked(cycleSeconds: cycleSeconds)
            }
        }
    }

    func preview(
        program: String,
        brightnessScale: Double = 1,
        duration: TimeInterval = 3
    ) {
        queue.async { [weak self] in
            guard let self, state.connected else { return }
            let calibratedProgram = LEDProgramOutputCalibration.applying(
                to: program,
                brightnessScale: kind.calibratedBrightnessScale(
                    universalBrightness: brightnessScale
                ),
                blueScale: kind.outputBlueScale
            )
            cancelDeferredWriteLocked()
            previewGeneration += 1
            let generation = previewGeneration
            let previewPath = state.path
            activePreviewGeneration = generation
            do {
                try writeLocked(calibratedProgram, remember: false)
            } catch {
                activePreviewGeneration = nil
                recordErrorLocked(error)
                return
            }
            queue.asyncAfter(deadline: .now() + max(0.5, duration)) { [weak self] in
                guard let self, activePreviewGeneration == generation else { return }
                activePreviewGeneration = nil
                guard state.connected, state.path == previewPath else { return }
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
        let discovered = Self.discoverDevice(kind: kind)
        var next = discovered ?? kind.disconnectedState
        if next.connected, next.path == state.path {
            next.activeProgram = state.activeProgram
            next.lastWrite = state.lastWrite
            next.lastError = state.lastError
        }
        let topologyChanged = next.connected != state.connected || next.path != state.path
        if topologyChanged {
            cancelPreviewLocked()
            cancelDeferredWriteLocked()
            lastWrittenProgram = nil
            lastProgramStartedAt = nil
        }
        let changed = next != state
        state = next
        if changed { onUpdate(state) }
        if state.connected, outputEnabled, activePreviewGeneration == nil {
            let refreshDue = Self.refreshInterval(for: requestedProgram).map { interval in
                guard let lastProgramStartedAt else { return true }
                return Date.now.timeIntervalSince(lastProgramStartedAt) >= interval
            } ?? false
            tryWriteRequestedLocked(force: refreshDue)
        }
    }

    private func tryWriteRequestedLocked(force: Bool = false) {
        if let deadline = deferredWriteDeadline {
            guard deadline <= .now else { return }
            deferredWriteDeadline = nil
        }
        guard state.connected, force || requestedProgram != lastWrittenProgram else { return }
        do {
            try writeLocked(requestedProgram, remember: true)
        } catch {
            recordErrorLocked(error)
        }
    }

    private func scheduleRequestedWriteAtBoundaryLocked(cycleSeconds: TimeInterval) {
        cancelDeferredWriteLocked()
        guard requestedProgram != lastWrittenProgram else { return }
        guard let lastProgramStartedAt else {
            tryWriteRequestedLocked()
            return
        }

        let cycle = max(0.2, min(30, cycleSeconds))
        let elapsed = max(0, Date.now.timeIntervalSince(lastProgramStartedAt))
        let phase = elapsed.truncatingRemainder(dividingBy: cycle)
        let delay = phase < 0.04 ? 0 : cycle - phase
        guard delay >= 0.04 else {
            tryWriteRequestedLocked()
            return
        }

        deferredWriteDeadline = Date.now.addingTimeInterval(delay)
        let generation = deferredWriteGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  deferredWriteGeneration == generation,
                  activePreviewGeneration == nil
            else { return }
            deferredWriteDeadline = nil
            tryWriteRequestedLocked()
        }
    }

    private func cancelPreviewLocked() {
        previewGeneration += 1
        activePreviewGeneration = nil
    }

    private func cancelDeferredWriteLocked() {
        deferredWriteGeneration += 1
        deferredWriteDeadline = nil
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
        state.activeProgram = program
        if remember {
            lastWrittenProgram = program
            lastProgramStartedAt = .now
        }
        state.lastWrite = .now
        state.lastError = nil
        onUpdate(state)
    }

    private func recordErrorLocked(_ error: Error) {
        state.lastError = error.localizedDescription
        onUpdate(state)
    }

    private static func discoverDevice(kind: SidePulseDeviceKind) -> DeviceState? {
        let root = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let volumes = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = volumes.compactMap { volume -> DeviceState? in
            guard (try? volume.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            guard SidePulseDeviceKind.detected(fromVolumeName: volume.lastPathComponent) == kind else { return nil }
            let target = volume.appending(path: "LEDS.LED")
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            return DeviceState(
                name: kind.name,
                path: target.path,
                ledCount: kind.ledCount,
                connected: true
            )
        }
        return candidates.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.first
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
