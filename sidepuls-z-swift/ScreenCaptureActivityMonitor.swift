import ApplicationServices
import AppKit
import Foundation

/// The read-only state surface used by the microphone utility mode.
struct ScreenCaptureSnapshot: Equatable, Sendable {
    var isRecording: Bool
    var detail: String
    var isAvailable: Bool

    nonisolated static var unavailable: Self {
        Self(
            isRecording: false,
            detail: "Recording status could not be read.",
            isAvailable: false
        )
    }
}

/// Watches the native ScreenCaptureUI accessibility tree without starting a
/// capture stream or requesting Screen Recording permission.
///
/// macOS does not expose a public process-independent recording-state API. A
/// trusted Accessibility client can, however, inspect ScreenCaptureUI's
/// published controls. Active recording is classified only when the exact
/// ScreenCaptureUI accessibility tree contains its Stop Screen Recording
/// button. The process being present is never treated as recording activity.
@MainActor
final class ScreenCaptureActivityMonitor {
    typealias OnChange = @MainActor @Sendable (ScreenCaptureSnapshot) -> Void
    typealias OnScreenshot = @MainActor @Sendable () -> Void

    private nonisolated static let screenCaptureUIBundleIdentifier = "com.apple.screencaptureui"
    private nonisolated static let screenCaptureUIBundlePath =
        "/System/Library/CoreServices/screencaptureui.app"
    private nonisolated static let stopRecordingIdentifier = "stop.circle.fill"
    private nonisolated static let stopRecordingDescription = "Stop Screen Recording"
    private nonisolated static let maxAXDepth = 8
    private nonisolated static let maxAXNodes = 128
    private nonisolated static let axMessagingTimeout: Float = 0.075
    private nonisolated static let axWalkDeadlineNanoseconds: UInt64 = 200_000_000
    private nonisolated static let pollIntervalNanoseconds: UInt64 = 250_000_000
    private nonisolated static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    // This metadata attribute is supplied by Spotlight on macOS but has no
    // public Swift constant in the current SDK.
    private nonisolated static let isScreenCaptureMetadataKey = "kMDItemIsScreenCapture"

    private let onChange: OnChange
    private let onScreenshot: OnScreenshot

    private var isStarted = false
    private var pollTask: Task<Void, Never>?
    private var axProbeTask: Task<ScreenCaptureAXProbeResult, Never>?
    private var accessibilityProbeGeneration: UInt64 = 0
    private var snapshot = ScreenCaptureSnapshot.unavailable

    private var screenshotQuery: NSMetadataQuery?
    private var screenshotQueryObserverTokens: [NSObjectProtocol] = []
    private var screenshotMetadataReady = false
    private var screenshotStartDate = Date.distantFuture
    private var knownScreenshotItems: Set<ScreenshotItemID> = []
    private var pendingScreenshotItems: Set<ScreenshotItemID> = []

    private struct ScreenshotItemID: Hashable {
        let path: String
        let creationDate: Date
    }

    init(
        onChange: @escaping @MainActor @Sendable (ScreenCaptureSnapshot) -> Void,
        onScreenshot: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onChange = onChange
        self.onScreenshot = onScreenshot
    }

    deinit {
        for token in screenshotQueryObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        screenshotQuery?.stop()
        pollTask?.cancel()
        axProbeTask?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        accessibilityProbeGeneration &+= 1
        snapshot = .unavailable
        screenshotMetadataReady = false
        knownScreenshotItems.removeAll(keepingCapacity: true)
        pendingScreenshotItems.removeAll(keepingCapacity: true)
        screenshotStartDate = Date()

        installScreenshotMetadataQuery()
        beginAccessibilityProbe()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        accessibilityProbeGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        axProbeTask?.cancel()
        axProbeTask = nil
        removeScreenshotMetadataQuery()

        snapshot = .unavailable
        screenshotMetadataReady = false
        knownScreenshotItems.removeAll(keepingCapacity: true)
        pendingScreenshotItems.removeAll(keepingCapacity: true)
    }

    /// Prompts for Accessibility permission only when the user explicitly
    /// invokes the access action, then opens the system Accessibility pane.
    func requestAccessibilityAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let accessibilitySettingsURL = Self.accessibilitySettingsURL {
            _ = NSWorkspace.shared.open(accessibilitySettingsURL)
        }

        if isStarted {
            beginAccessibilityProbe()
        } else {
            publish(
                Self.snapshot(
                    accessibilityTrusted: AXIsProcessTrusted(),
                    stopButtonFound: nil
                )
            )
        }
    }

    /// Pure state reduction used by the monitor and its focused smoke test.
    /// `nil` means Accessibility was granted but the native tree could not be
    /// read for this sample.
    nonisolated static func snapshot(
        accessibilityTrusted: Bool,
        stopButtonFound: Bool?
    ) -> ScreenCaptureSnapshot {
        guard accessibilityTrusted else {
            return ScreenCaptureSnapshot(
                isRecording: false,
                detail: "Accessibility access is required to detect native macOS screen recording.",
                isAvailable: false
            )
        }

        guard let stopButtonFound else {
            return ScreenCaptureSnapshot(
                isRecording: false,
                detail: "Recording status could not be read.",
                isAvailable: false
            )
        }

        return ScreenCaptureSnapshot(
            isRecording: stopButtonFound,
            detail: stopButtonFound
                ? "Screen recording is active in macOS Screenshot."
                : "macOS Screenshot is not recording.",
            isAvailable: true
        )
    }

    /// The fallback intentionally recognizes only the exact native identifier
    /// and the known English accessibility description.
    nonisolated static func matchesStopRecordingControl(
        identifier: String?,
        description: String?
    ) -> Bool {
        identifier == stopRecordingIdentifier
            || description == stopRecordingDescription
    }

    private func beginAccessibilityProbe() {
        guard isStarted, axProbeTask == nil else { return }

        let probeGeneration = accessibilityProbeGeneration
        let accessibilityTrusted = AXIsProcessTrusted()
        guard accessibilityTrusted else {
            publish(
                Self.snapshot(
                    accessibilityTrusted: false,
                    stopButtonFound: nil
                )
            )
            scheduleNextAccessibilityProbe(for: probeGeneration)
            return
        }

        // NSWorkspace and runningApplications are read on the MainActor. Only
        // the PID crosses into the detached AX probe; no UI object is retained
        // by the background task.
        guard let processIdentifier = exactScreenCaptureUIProcessIdentifier() else {
            publish(
                Self.snapshot(
                    accessibilityTrusted: true,
                    stopButtonFound: false
                )
            )
            scheduleNextAccessibilityProbe(for: probeGeneration)
            return
        }

        let probe = Task.detached(priority: .utility) {
            ScreenCaptureActivityMonitor.probeAX(processIdentifier: processIdentifier)
        }
        axProbeTask = probe

        Task { @MainActor [weak self] in
            let result = await probe.value
            guard let self,
                  self.accessibilityProbeGeneration == probeGeneration
            else { return }

            self.axProbeTask = nil
            guard self.isStarted else { return }

            let accessibilityTrusted = AXIsProcessTrusted()
            self.publish(
                Self.snapshot(
                    accessibilityTrusted: accessibilityTrusted,
                    stopButtonFound: accessibilityTrusted
                        ? result.stopButtonFound
                        : nil
                )
            )
            self.scheduleNextAccessibilityProbe(for: probeGeneration)
        }
    }

    private func scheduleNextAccessibilityProbe(for generation: UInt64) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            } catch {
                return
            }

            guard let self,
                  self.isStarted,
                  self.accessibilityProbeGeneration == generation
            else { return }

            self.pollTask = nil
            self.beginAccessibilityProbe()
        }
    }

    private func publish(_ next: ScreenCaptureSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onChange(next)
    }

    private func exactScreenCaptureUIProcessIdentifier() -> pid_t? {
        // Running-application lookup identifies the exact native client only;
        // its presence alone never determines the recording state.
        exactScreenCaptureUIApplication()?.processIdentifier
    }

    private func exactScreenCaptureUIApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { application in
            if application.bundleIdentifier == Self.screenCaptureUIBundleIdentifier {
                return true
            }
            return application.bundleURL?.standardizedFileURL.path
                == Self.screenCaptureUIBundlePath
        }
    }

    private nonisolated static func probeAX(
        processIdentifier: pid_t
    ) -> ScreenCaptureAXProbeResult {
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ axWalkDeadlineNanoseconds
        let application = AXUIElementCreateApplication(processIdentifier)
        guard setAXMessagingTimeout(on: application) == .success else {
            return ScreenCaptureAXProbeResult(stopButtonFound: nil)
        }

        guard let roots = accessibilityRoots(
            for: application,
            deadline: deadline
        ) else {
            return ScreenCaptureAXProbeResult(stopButtonFound: nil)
        }

        var scanner = ScreenCaptureAXTreeScanner(
            maxDepth: maxAXDepth,
            maxNodes: maxAXNodes,
            deadline: deadline
        )
        return ScreenCaptureAXProbeResult(
            stopButtonFound: scanner.containsStopRecordingControl(in: roots)
        )
    }

    private nonisolated static func setAXMessagingTimeout(
        on element: AXUIElement
    ) -> AXError {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    }

    private nonisolated static func accessibilityRoots(
        for application: AXUIElement,
        deadline: UInt64
    ) -> [AXUIElement]? {
        guard !deadlineExceededForAXProbe(deadline) else { return nil }
        var roots: [AXUIElement] = []

        let menuBar = copyAXValue(
            application,
            attribute: kAXMenuBarAttribute
        )
        switch menuBar.0 {
        case .success:
            guard let menuBarElement = axElement(from: menuBar.1) else {
                return nil
            }
            roots.append(menuBarElement)
        case .noValue, .attributeUnsupported:
            break
        default:
            return nil
        }

        guard !deadlineExceededForAXProbe(deadline) else { return nil }
        let windows = copyAXValue(
            application,
            attribute: kAXWindowsAttribute
        )
        switch windows.0 {
        case .success:
            guard let windowElements = axElements(from: windows.1) else {
                return nil
            }
            roots.append(contentsOf: windowElements)
        case .noValue, .attributeUnsupported:
            break
        default:
            return nil
        }
        return roots
    }

    fileprivate nonisolated static func deadlineExceededForAXProbe(
        _ deadline: UInt64
    ) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline
    }

    private nonisolated static func copyAXValue(
        _ element: AXUIElement,
        attribute: String
    ) -> (AXError, CFTypeRef?) {
        _ = setAXMessagingTimeout(on: element)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        return (error, value)
    }

    private nonisolated static func axElement(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private nonisolated static func axElements(from value: CFTypeRef?) -> [AXUIElement]? {
        guard let value else { return nil }
        return value as? [AXUIElement]
    }

    fileprivate nonisolated static func axStringResult(
        from element: AXUIElement,
        attribute: String
    ) -> ScreenCaptureAXValueResult<String> {
        let result = copyAXValue(element, attribute: attribute)
        switch result.0 {
        case .success:
            guard let value = result.1 as? String else { return .absent }
            return .value(value)
        case .noValue, .attributeUnsupported:
            return .absent
        default:
            return .unavailable
        }
    }

    fileprivate nonisolated static func axChildren(
        of element: AXUIElement
    ) -> ScreenCaptureAXChildrenResult {
        let result = copyAXValue(element, attribute: kAXChildrenAttribute)
        switch result.0 {
        case .success:
            guard let children = axElements(from: result.1) else {
                return .unavailable
            }
            return .values(children)
        case .noValue, .attributeUnsupported:
            return .values([])
        default:
            return .unavailable
        }
    }

    private func installScreenshotMetadataQuery() {
        let query = NSMetadataQuery()
        query.operationQueue = OperationQueue.main
        query.notificationBatchingInterval = 0.1
        query.predicate = NSPredicate(
            format: "%K == YES AND %K >= %@",
            Self.isScreenCaptureMetadataKey,
            NSMetadataItemFSCreationDateKey,
            screenshotStartDate as NSDate
        )
        query.searchScopes = [NSMetadataQueryUserHomeScope]

        let didFinish = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let query = self.screenshotQuery else { return }
                self.finishScreenshotMetadataGathering(query)
            }
        }
        let didUpdate = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let query = self.screenshotQuery else { return }
                self.handleScreenshotMetadataUpdate(query)
            }
        }

        screenshotQuery = query
        screenshotQueryObserverTokens = [didFinish, didUpdate]

        guard query.start() else {
            removeScreenshotMetadataQuery()
            return
        }
    }

    private func removeScreenshotMetadataQuery() {
        for token in screenshotQueryObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        screenshotQueryObserverTokens.removeAll(keepingCapacity: true)
        screenshotQuery?.stop()
        screenshotQuery = nil
    }

    private func finishScreenshotMetadataGathering(_ query: NSMetadataQuery) {
        guard isStarted, screenshotQuery === query else { return }

        query.disableUpdates()
        let gatheredItems = Set(
            query.results
                .compactMap { $0 as? NSMetadataItem }
                .compactMap(Self.screenshotItemID)
        )
        let candidates = gatheredItems.union(pendingScreenshotItems)
        pendingScreenshotItems.removeAll(keepingCapacity: true)
        knownScreenshotItems = candidates
        query.enableUpdates()
        screenshotMetadataReady = true

        // A screenshot created while Spotlight performs its initial gather can
        // already be in the result set. Emit it after establishing the
        // baseline so it is not absorbed as history or lost between updates.
        publishNewScreenshotItems(candidates)
    }

    private func handleScreenshotMetadataUpdate(_ query: NSMetadataQuery) {
        guard isStarted, screenshotQuery === query else { return }

        let currentItems = Set(
            query.results
                .compactMap { $0 as? NSMetadataItem }
                .compactMap(Self.screenshotItemID)
        )
        guard screenshotMetadataReady else {
            pendingScreenshotItems.formUnion(currentItems)
            return
        }

        let newItems = currentItems.subtracting(knownScreenshotItems)
        knownScreenshotItems.formUnion(currentItems)
        publishNewScreenshotItems(newItems)
    }

    private func publishNewScreenshotItems(_ items: Set<ScreenshotItemID>) {
        for itemID in items.sorted(by: { $0.creationDate < $1.creationDate }) {
            guard isStarted, itemID.creationDate >= screenshotStartDate else {
                continue
            }
            onScreenshot()
        }
    }

    private static func screenshotItemID(
        _ item: NSMetadataItem
    ) -> ScreenshotItemID? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
              !path.isEmpty,
              let creationDate = item.value(
                forAttribute: NSMetadataItemFSCreationDateKey
              ) as? Date
        else { return nil }

        return ScreenshotItemID(path: path, creationDate: creationDate)
    }
}

private struct ScreenCaptureAXProbeResult: Sendable {
    let stopButtonFound: Bool?
}

private enum ScreenCaptureAXValueResult<Value> {
    case value(Value)
    case absent
    case unavailable
}

private enum ScreenCaptureAXChildrenResult {
    case values([AXUIElement])
    case unavailable
}

private struct ScreenCaptureAXTreeScanner {
    private let maxDepth: Int
    private let maxNodes: Int
    private let deadline: UInt64
    private var visitedNodes = 0
    private var reachedBound = false

    nonisolated init(maxDepth: Int, maxNodes: Int, deadline: UInt64) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.deadline = deadline
    }

    nonisolated mutating func containsStopRecordingControl(
        in roots: [AXUIElement]
    ) -> Bool? {
        for root in roots {
            if scan(root, depth: 0) { return true }
            if reachedBound { return nil }
        }
        return reachedBound ? nil : false
    }

    private nonisolated mutating func scan(
        _ element: AXUIElement,
        depth: Int
    ) -> Bool {
        guard !ScreenCaptureActivityMonitor.deadlineExceededForAXProbe(deadline) else {
            reachedBound = true
            return false
        }

        guard visitedNodes < maxNodes else {
            reachedBound = true
            return false
        }
        visitedNodes += 1

        let identifierResult = ScreenCaptureActivityMonitor.axStringResult(
            from: element,
            attribute: kAXIdentifierAttribute
        )
        let identifier: String?
        switch identifierResult {
        case .value(let value):
            identifier = value
        case .absent:
            identifier = nil
        case .unavailable:
            reachedBound = true
            return false
        }

        // The identifier is the stable native marker. If it matches, avoid a
        // second AX request whose failure could otherwise hide a positive hit.
        if ScreenCaptureActivityMonitor.matchesStopRecordingControl(
            identifier: identifier,
            description: nil
        ) {
            return true
        }

        let descriptionResult = ScreenCaptureActivityMonitor.axStringResult(
            from: element,
            attribute: kAXDescriptionAttribute
        )
        let description: String?
        switch descriptionResult {
        case .value(let value):
            description = value
        case .absent:
            description = nil
        case .unavailable:
            reachedBound = true
            return false
        }

        if ScreenCaptureActivityMonitor.matchesStopRecordingControl(
            identifier: nil,
            description: description
        ) {
            return true
        }

        guard !ScreenCaptureActivityMonitor.deadlineExceededForAXProbe(deadline) else {
            reachedBound = true
            return false
        }

        switch ScreenCaptureActivityMonitor.axChildren(of: element) {
        case .unavailable:
            reachedBound = true
            return false
        case .values(let children):
            if depth >= maxDepth {
                if !children.isEmpty { reachedBound = true }
                return false
            }
            for child in children {
                if scan(child, depth: depth + 1) { return true }
                if reachedBound { return false }
            }
        }
        return false
    }
}
