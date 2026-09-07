import Foundation

/// The narrow signal-service seam owned by CommandCenterStore.
///
/// The production Host integration supplies an authenticated implementation;
/// the existing NearbySidePulseService remains the standalone implementation.
@MainActor
protocol SidePulseSignalServicing: AnyObject {
    func configure(_ configuration: NearbySignalServiceConfiguration)
    func updateLocalFrame(_ frame: NearbySignalFrame)
    func stop()
}

extension NearbySidePulseService: SidePulseSignalServicing {}

#if PEEL_HOST_INTEGRATION
/// Factory signature shared by the standalone and authenticated signal
/// services. The callbacks may be invoked from the service's I/O queue.
typealias TrustedSidePulseSignalServiceFactory = @MainActor (
    _ nodeID: String,
    _ displayName: String,
    _ onPeers: @escaping NearbySidePulseService.PeerHandler,
    _ onSignal: @escaping NearbySidePulseService.SignalHandler,
    _ onStatus: @escaping NearbySidePulseService.StatusHandler,
    _ onSnapshot: @escaping NearbySidePulseService.SnapshotHandler
) -> any SidePulseSignalServicing
#endif
