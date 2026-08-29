import DiskArbitration
import Darwin
import Foundation
import OSLog

/// Native Swift port of SidePulse Pro Eject Prevention from inteliwear/sidepulse.
/// The original project and this port are MIT licensed; see NOTICE.
final class SidePulseEjectGuard: @unchecked Sendable {
    struct DiskDescription: Equatable, Sendable {
        var deviceProtocol: String?
        var deviceModel: String?
        var isInternal: Bool?
        var volumeName: String?
        var volumePathName: String?

        var shouldProtect: Bool {
            let protocolIsSD = deviceProtocol?.localizedCaseInsensitiveContains("Secure Digital") == true
            let modelIsSDXC = deviceModel?.localizedCaseInsensitiveContains("SDXC") == true
            guard isInternal == true, protocolIsSD || modelIsSDXC else { return false }

            let candidateNames = [volumeName, volumePathName].compactMap { $0 }
            return candidateNames.contains {
                SidePulseDeviceKind.detected(fromVolumeName: $0) == .pro
            }
        }
    }

    enum StartError: LocalizedError {
        case sessionUnavailable

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable:
                "macOS Disk Arbitration is unavailable."
            }
        }
    }

    private static let helperLabel = "io.sidepulse.sdejectguard"
    private static let remountInterval: TimeInterval = 5
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zephyrstudios.sidepulse-z",
        category: "EjectGuard"
    )

    private let queue = DispatchQueue(label: "io.sidepulse.eject-guard", qos: .utility)
    private var session: DASession?
    private var remountTimers: [String: DispatchSourceTimer] = [:]

    private(set) var isRunning = false

    static func runningExternalHelperExists(
        currentUserID: uid_t = getuid(),
        serviceIsLoaded: (String) -> Bool = launchServiceIsLoaded
    ) -> Bool {
        [
            "gui/\(currentUserID)/\(helperLabel)",
            "system/\(helperLabel)",
        ].contains(where: serviceIsLoaded)
    }

    func start() throws {
        guard !isRunning else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw StartError.sessionUnavailable
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskEjectApprovalCallback(
            session,
            nil,
            sidePulseEjectApprovalCallback,
            context
        )
        DASessionSetDispatchQueue(session, queue)
        self.session = session
        isRunning = true
        Self.logger.info("SidePulse-only eject prevention started")
    }

    func stop() {
        guard isRunning else { return }
        if let session {
            DASessionSetDispatchQueue(session, nil)
        }
        session = nil
        isRunning = false
        queue.sync {
            remountTimers.values.forEach { $0.cancel() }
            remountTimers.removeAll()
        }
        Self.logger.info("Eject prevention stopped")
    }

    fileprivate func approveEject(for disk: DADisk) -> Unmanaged<DADissenter>? {
        let description = Self.description(for: disk)
        guard description.shouldProtect else { return nil }

        let bsdName = DADiskGetBSDName(disk).map(String.init(cString:)) ?? "unknown"
        Self.logger.notice("Preventing software eject of SidePulse Pro on \(bsdName, privacy: .public)")
        scheduleRemountIfNeeded(disk, identifier: bsdName)

        let dissenter = DADissenterCreate(
            kCFAllocatorDefault,
            DAReturn(kDAReturnNotPermitted),
            "SidePulse is keeping SidePulse Pro attached" as CFString
        )
        return Unmanaged.passRetained(dissenter)
    }

    static func description(for disk: DADisk) -> DiskDescription {
        guard let values = DADiskCopyDescription(disk) as? [CFString: Any] else {
            return DiskDescription()
        }
        let path = values[kDADiskDescriptionVolumePathKey] as? URL
        return DiskDescription(
            deviceProtocol: values[kDADiskDescriptionDeviceProtocolKey] as? String,
            deviceModel: values[kDADiskDescriptionDeviceModelKey] as? String,
            isInternal: values[kDADiskDescriptionDeviceInternalKey] as? Bool,
            volumeName: values[kDADiskDescriptionVolumeNameKey] as? String,
            volumePathName: path?.lastPathComponent
        )
    }

    private func scheduleRemountIfNeeded(_ disk: DADisk, identifier: String) {
        guard !Self.isMounted(disk), remountTimers[identifier] == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.remountInterval,
            repeating: Self.remountInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Self.isMounted(disk) {
                remountTimers.removeValue(forKey: identifier)?.cancel()
                Self.logger.info("SidePulse Pro remounted on \(identifier, privacy: .public)")
                return
            }
            DADiskMount(
                disk,
                nil,
                DADiskMountOptions(kDADiskMountOptionDefault),
                sidePulseMountCallback,
                nil
            )
        }
        remountTimers[identifier] = timer
        timer.resume()
    }

    private static func isMounted(_ disk: DADisk) -> Bool {
        guard let values = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return values[kDADiskDescriptionVolumePathKey] != nil
    }

    private static func launchServiceIsLoaded(_ target: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

private let sidePulseEjectApprovalCallback: DADiskEjectApprovalCallback = { disk, context in
    guard let context else { return nil }
    let ejectGuard = Unmanaged<SidePulseEjectGuard>
        .fromOpaque(context)
        .takeUnretainedValue()
    return ejectGuard.approveEject(for: disk)
}

private let sidePulseMountCallback: DADiskMountCallback = { disk, dissenter, _ in
    let bsdName = DADiskGetBSDName(disk).map(String.init(cString:)) ?? "unknown"
    if let dissenter {
        let status = DADissenterGetStatus(dissenter)
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.zephyrstudios.sidepulse-z",
            category: "EjectGuard"
        ).debug("Remount of \(bsdName, privacy: .public) deferred with status \(status)")
    }
}
