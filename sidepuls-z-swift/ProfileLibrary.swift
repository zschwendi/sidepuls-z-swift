import Foundation

struct SavedProfileLibrary: Codable, Sendable {
    var schemaVersion = 7
    var profiles: [LightingProfile]
    var selectedProfileID: UUID
}

enum ProfileLibrary {
    private static let storageKey = "sidepulse.profile-library.v1"

    static func load(from defaults: UserDefaults = .standard) -> SavedProfileLibrary? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard var library = try? JSONDecoder().decode(SavedProfileLibrary.self, from: data) else { return nil }
        guard library.schemaVersion < 7 else { return library }

        let builtIns = [
            LightingProfile.commandCenter,
            LightingProfile.quietNight,
            LightingProfile.highSignal,
        ]
        for index in library.profiles.indices where library.schemaVersion < 3 {
            guard let builtIn = builtIns.first(where: { $0.id == library.profiles[index].id }) else { continue }
            if library.schemaVersion < 2 {
                library.profiles[index].strategy = .adaptiveOccupancy
            }
            for state in [AgentState.working, .toolRunning, .waiting, .error, .completed] {
                library.profiles[index].updateStyle(builtIn.style(for: state))
            }
        }
        if library.schemaVersion < 6 {
            let builtInIDs = Set(builtIns.map(\.id))
            for profileIndex in library.profiles.indices where builtInIDs.contains(library.profiles[profileIndex].id) {
                for styleIndex in library.profiles[profileIndex].styles.indices {
                    let state = library.profiles[profileIndex].styles[styleIndex].state
                    if [.idle, .working, .toolRunning].contains(state),
                       library.profiles[profileIndex].styles[styleIndex].motion == .pulse {
                        library.profiles[profileIndex].styles[styleIndex].motion = .breathe
                    }
                }
            }
        }
        if library.schemaVersion < 7 {
            for profileIndex in library.profiles.indices {
                var seenStates = Set<String>()
                library.profiles[profileIndex].styles = library.profiles[profileIndex].styles.filter {
                    seenStates.insert($0.state.rawValue).inserted
                }
            }
        }
        library.schemaVersion = 7
        save(
            profiles: library.profiles,
            selectedProfileID: library.selectedProfileID,
            to: defaults
        )
        return library
    }

    static func save(
        profiles: [LightingProfile],
        selectedProfileID: UUID,
        to defaults: UserDefaults = .standard
    ) {
        let library = SavedProfileLibrary(
            profiles: profiles,
            selectedProfileID: selectedProfileID
        )
        guard let data = try? JSONEncoder().encode(library) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

enum AppPreferences {
    private static let liveOutputKey = "sidepulse.live-output-enabled.v1"

    static func liveOutputEnabled(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: liveOutputKey) != nil else {
            // SidePulse is a hardware controller, so first launch should work without
            // requiring a second, easy-to-miss enable switch.
            return true
        }
        return defaults.bool(forKey: liveOutputKey)
    }

    static func saveLiveOutputEnabled(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: liveOutputKey)
    }
}
