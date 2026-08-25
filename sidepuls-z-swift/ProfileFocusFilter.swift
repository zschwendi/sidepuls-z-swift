import AppIntents
import Foundation

extension Notification.Name {
    static let sidePulseProfileSelectionDidChange = Notification.Name(
        "com.zephyrstudiosllc.sidepulse.profile-selection-did-change"
    )
}

struct SidePulseProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "SidePulse Profile"
    static let defaultQuery = SidePulseProfileQuery()

    let id: UUID
    let name: String
    let symbol: String

    init(profile: LightingProfile) {
        id = profile.id
        name = profile.name
        symbol = profile.symbol
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "SidePulse lighting profile",
            image: .init(systemName: symbol)
        )
    }
}

struct SidePulseProfileQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [UUID]) async throws -> [SidePulseProfileEntity] {
        let requested = Set(identifiers)
        return profiles()
            .filter { requested.contains($0.id) }
            .map(SidePulseProfileEntity.init(profile:))
    }

    func suggestedEntities() async throws -> [SidePulseProfileEntity] {
        profiles().map(SidePulseProfileEntity.init(profile:))
    }

    private func profiles() -> [LightingProfile] {
        ProfileLibrary.load()?.profiles ?? [.commandCenter]
    }
}

struct SetSidePulseProfileFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set SidePulse Profile"
    static let description = IntentDescription(
        "Automatically activates a SidePulse lighting profile with this Focus."
    )

    @Parameter(title: "Lighting Profile")
    var profile: SidePulseProfileEntity?

    init() {}

    init(profile: SidePulseProfileEntity) {
        self.profile = profile
    }

    var displayRepresentation: DisplayRepresentation {
        guard let profile else { return "Choose a SidePulse profile" }
        return DisplayRepresentation(
            title: "Use \(profile.name)",
            subtitle: "Activate when this Focus is on",
            image: .init(systemName: profile.symbol)
        )
    }

    func perform() async throws -> some IntentResult {
        guard let profile else { throw SetFocusFilterIntentError.missingParameterValue }
        let didSelect = await MainActor.run {
            guard ProfileLibrary.selectProfile(profile.id) else { return false }
            ProfileLibrary.setFocusAutomationEnabled(true)
            ProfileFocusIntegration.postSelectionChange()
            return true
        }
        guard didSelect else { throw SetFocusFilterIntentError.notFound }
        return .result()
    }

    static func suggestedFocusFilters(
        for context: FocusFilterSuggestionContext
    ) async -> [SetSidePulseProfileFocusFilter] {
        let profiles = await MainActor.run {
            ProfileLibrary.load()?.profiles ?? [.commandCenter]
        }
        return profiles.map {
            SetSidePulseProfileFocusFilter(profile: SidePulseProfileEntity(profile: $0))
        }
    }
}

enum ProfileFocusIntegration {
    static func currentProfileID() async -> UUID? {
        try? await SetSidePulseProfileFocusFilter.current.profile?.id
    }

    static func profileLibraryDidChange() {
        SetSidePulseProfileFocusFilter.invalidateFocusFilterAppContext()
    }

    static func postSelectionChange() {
        DistributedNotificationCenter.default().post(
            name: .sidePulseProfileSelectionDidChange,
            object: nil
        )
    }
}
