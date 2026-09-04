import CoreAudio
import Foundation

enum MicrophoneActivity: String, Codable, CaseIterable, Sendable {
    case idle
    case inUse
    case muted
    case unavailable
}

struct MicrophoneSnapshot: Equatable, Sendable {
    var activity: MicrophoneActivity
    var deviceName: String
    var hardwareMuteAvailable: Bool
    var detail: String

    nonisolated static var unavailable: Self {
        Self(
            activity: .unavailable,
            deviceName: "No microphone",
            hardwareMuteAvailable: false,
            detail: "No usable input device is available."
        )
    }
}

/// The read-only facts used by the pure aggregation helper and smoke tests.
/// A nil hardware mute value means that the device does not expose a readable
/// input-scope hardware mute control.
struct MicrophoneDeviceState: Equatable, Sendable {
    var deviceName: String
    var isRunning: Bool
    var hardwareMuted: Bool?
}

/// The read-only process facts used to associate active input with a device.
/// Output-only processes deliberately do not contribute to this set.
struct MicrophoneProcessState: Equatable, Sendable {
    var isRunningInput: Bool
    var inputDeviceIDs: [AudioObjectID]
}

@MainActor
final class MicrophoneActivityMonitor {
    typealias OnChange = @MainActor @Sendable (MicrophoneSnapshot) -> Void

    private static let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let inputStreamsAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let processObjectListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let processInputDevicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyDevices,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let processRunningInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let inputMuteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private let onChange: OnChange
    private var timer: Timer?
    private var isEnabled = false
    private var lastPollUptime: TimeInterval?
    private var lastSnapshot: MicrophoneSnapshot?

    init(onChange: @escaping @MainActor @Sendable (MicrophoneSnapshot) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        lastPollUptime = nil
        lastSnapshot = nil

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    func stop() {
        isEnabled = false
        timer?.invalidate()
        timer = nil
        lastPollUptime = nil
        lastSnapshot = nil
    }

    /// Reduces read-only device facts without touching CoreAudio. Unknown mute
    /// state is treated as active input when a device is running.
    nonisolated static func reduce(_ devices: [MicrophoneDeviceState]) -> MicrophoneSnapshot {
        guard !devices.isEmpty else { return .unavailable }

        let hardwareMuteAvailable = devices.contains { $0.hardwareMuted != nil }
        let activeDevices = devices.filter(\.isRunning)
        let activeNames = displayName(for: activeDevices)

        if activeDevices.contains(where: { $0.hardwareMuted != true }) {
            let unknownMute = activeDevices.contains { $0.hardwareMuted == nil }
            let detail = unknownMute
                ? "Input is active; hardware mute is unavailable for at least one active device."
                : "Input is active and hardware mute is off."
            return MicrophoneSnapshot(
                activity: .inUse,
                deviceName: activeNames,
                hardwareMuteAvailable: hardwareMuteAvailable,
                detail: detail
            )
        }

        if !activeDevices.isEmpty {
            return MicrophoneSnapshot(
                activity: .muted,
                deviceName: activeNames,
                hardwareMuteAvailable: hardwareMuteAvailable,
                detail: "All active input devices report hardware mute."
            )
        }

        return MicrophoneSnapshot(
            activity: .idle,
            deviceName: displayName(for: devices),
            hardwareMuteAvailable: hardwareMuteAvailable,
            detail: "No input device is running."
        )
    }

    /// Returns only devices associated with a process that has active input IO.
    /// A process that is active only for output contributes no device IDs.
    nonisolated static func activeInputDeviceIDs(
        from processes: [MicrophoneProcessState]
    ) -> Set<AudioObjectID> {
        Set(
            processes
                .filter(\.isRunningInput)
                .flatMap(\.inputDeviceIDs)
        )
    }

    private func poll() {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastPollUptime, now - lastPollUptime < 1.0 { return }
        self.lastPollUptime = now
        let next = currentSnapshot()
        guard next != lastSnapshot else { return }
        lastSnapshot = next
        onChange(next)
    }

    private func currentSnapshot() -> MicrophoneSnapshot {
        // Metadata queries only: this monitor never starts an AudioDevice or reads samples.
        guard let inputDeviceIDs = inputDeviceIDs(),
              let activeInputDeviceIDs = activeInputDeviceIDs()
        else {
            return .unavailable
        }
        let devices = inputDeviceIDs.compactMap {
            deviceState(for: $0, activeInputDeviceIDs: activeInputDeviceIDs)
        }
        return Self.reduce(devices)
    }

    private func inputDeviceIDs() -> [AudioObjectID]? {
        readObjectIDs(on: Self.systemObjectID, address: Self.devicesAddress)
    }

    private func readObjectIDs(
        on objectID: AudioObjectID,
        address propertyAddress: AudioObjectPropertyAddress
    ) -> [AudioObjectID]? {
        var address = propertyAddress
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            objectID,
            &address,
            0,
            nil,
            &dataSize
        ) == kAudioHardwareNoError else {
            return nil
        }

        let elementSize = MemoryLayout<AudioObjectID>.stride
        guard dataSize > 0, Int(dataSize) % elementSize == 0 else { return [] }

        var deviceIDs = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / elementSize
        )
        var returnedSize = dataSize
        let status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return OSStatus(kAudioHardwareBadPropertySizeError)
            }
            return AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &returnedSize,
                baseAddress
            )
        }
        guard status == kAudioHardwareNoError else { return nil }
        return deviceIDs.filter { $0 != kAudioObjectUnknown }
    }

    private func deviceState(
        for deviceID: AudioObjectID,
        activeInputDeviceIDs: Set<AudioObjectID>
    ) -> MicrophoneDeviceState? {
        guard hasInputStream(on: deviceID) else { return nil }
        return MicrophoneDeviceState(
            deviceName: readName(on: deviceID) ?? "Microphone",
            isRunning: activeInputDeviceIDs.contains(deviceID),
            hardwareMuted: readHardwareMute(on: deviceID)
        )
    }

    private func activeInputDeviceIDs() -> Set<AudioObjectID>? {
        guard let processObjectIDs = processObjectIDs() else { return nil }
        var processes: [MicrophoneProcessState] = []
        processes.reserveCapacity(processObjectIDs.count)

        for processObjectID in processObjectIDs {
            guard let isRunningInput = readUInt32(
                on: processObjectID,
                address: Self.processRunningInputAddress
            ) else {
                return nil
            }
            guard isRunningInput != 0 else { continue }
            guard let inputDeviceIDs = processInputDeviceIDs(on: processObjectID),
                  !inputDeviceIDs.isEmpty
            else {
                return nil
            }
            processes.append(
                MicrophoneProcessState(isRunningInput: true, inputDeviceIDs: inputDeviceIDs)
            )
        }

        return Self.activeInputDeviceIDs(from: processes)
    }

    private func processObjectIDs() -> [AudioObjectID]? {
        readObjectIDs(on: Self.systemObjectID, address: Self.processObjectListAddress)
    }

    private func processInputDeviceIDs(on processObjectID: AudioObjectID) -> [AudioObjectID]? {
        readObjectIDs(on: processObjectID, address: Self.processInputDevicesAddress)
    }

    private func hasInputStream(on deviceID: AudioObjectID) -> Bool {
        var address = Self.inputStreamsAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        ) == kAudioHardwareNoError else {
            return false
        }
        guard dataSize > 0 else { return false }

        let elementSize = MemoryLayout<AudioStreamID>.stride
        guard Int(dataSize) % elementSize == 0 else { return false }
        var streamIDs = [AudioStreamID](repeating: 0, count: Int(dataSize) / elementSize)
        var returnedSize = dataSize
        let status = streamIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return OSStatus(kAudioHardwareBadPropertySizeError)
            }
            return AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &returnedSize,
                baseAddress
            )
        }
        return status == kAudioHardwareNoError && !streamIDs.isEmpty
    }

    private func readHardwareMute(on deviceID: AudioObjectID) -> Bool? {
        guard let value = readUInt32(on: deviceID, address: Self.inputMuteAddress) else { return nil }
        return value != 0
    }

    private func readUInt32(on deviceID: AudioObjectID, address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == kAudioHardwareNoError && dataSize >= MemoryLayout<UInt32>.size ? value : nil
    }

    private func readName(on deviceID: AudioObjectID) -> String? {
        var address = Self.nameAddress
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &name
        )
        guard status == kAudioHardwareNoError, let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private nonisolated static func displayName(for devices: [MicrophoneDeviceState]) -> String {
        let names = devices
            .map { $0.deviceName.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? "Microphone" : names.joined(separator: ", ")
    }
}
