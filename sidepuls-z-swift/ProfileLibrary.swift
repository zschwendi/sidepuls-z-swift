import Foundation

struct SavedProfileLibrary: Codable, Sendable {
    var schemaVersion = 9
    var profiles: [LightingProfile]
    var selectedProfileID: UUID
}

struct SidePulseProfileArchive: Codable, Sendable {
    var format = "com.zephyrstudios.sidepulse.profiles"
    var formatVersion = 1
    var exportedAt = Date.now
    var profiles: [LightingProfile]
}

enum ProfileArchiveError: LocalizedError {
    case empty
    case duplicateIdentifiers
    case unsupported

    var errorDescription: String? {
        switch self {
        case .empty: "The file does not contain any SidePulse profiles."
        case .duplicateIdentifiers: "The file contains duplicate profile identifiers."
        case .unsupported: "This is not a supported SidePulse profile file."
        }
    }
}

enum ProfileLibrary {
    private static let storageKey = "sidepulse.profile-library.v1"
    private static let defaultProfileKey = "sidepulse.default-profile-id.v1"
    private static let focusAutomationKey = "sidepulse.focus-automation-enabled.v1"

    static func load(from defaults: UserDefaults = .standard) -> SavedProfileLibrary? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard var library = try? JSONDecoder().decode(SavedProfileLibrary.self, from: data) else { return nil }
        guard library.schemaVersion < 9 else { return library }

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
        if library.schemaVersion < 8 {
            for profileIndex in library.profiles.indices {
                let thinking = library.profiles[profileIndex].style(for: .working)
                var tool = library.profiles[profileIndex].style(for: .toolRunning)
                tool.motion = thinking.motion
                tool.cycleSeconds = thinking.cycleSeconds
                tool.intensity = thinking.intensity
                library.profiles[profileIndex].updateStyle(tool)
            }
        }
        if library.schemaVersion < 9 {
            var current = library.profiles.first(where: { $0.id == library.selectedProfileID })
                ?? library.profiles.first
                ?? .commandCenter
            current.name = "Default"
            library.profiles = [current]
            library.selectedProfileID = current.id
            setDefaultProfileID(current.id, in: defaults)
        }
        library.schemaVersion = 9
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

    static func selectProfile(_ id: UUID, in defaults: UserDefaults = .standard) -> Bool {
        guard let library = load(from: defaults),
              library.profiles.contains(where: { $0.id == id })
        else { return false }
        save(profiles: library.profiles, selectedProfileID: id, to: defaults)
        return true
    }

    static func defaultProfileID(from defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: defaultProfileKey).flatMap(UUID.init(uuidString:))
    }

    static func setDefaultProfileID(_ id: UUID, in defaults: UserDefaults = .standard) {
        defaults.set(id.uuidString, forKey: defaultProfileKey)
    }

    static func focusAutomationEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: focusAutomationKey)
    }

    static func setFocusAutomationEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: focusAutomationKey)
    }

    static func exportData(profiles: [LightingProfile]) throws -> Data {
        guard !profiles.isEmpty else { throw ProfileArchiveError.empty }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(SidePulseProfileArchive(profiles: profiles))
    }

    static func importProfiles(from data: Data) throws -> [LightingProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(SidePulseProfileArchive.self, from: data),
              archive.format == "com.zephyrstudios.sidepulse.profiles",
              archive.formatVersion == 1
        else { throw ProfileArchiveError.unsupported }
        guard !archive.profiles.isEmpty else { throw ProfileArchiveError.empty }
        guard Set(archive.profiles.map(\.id)).count == archive.profiles.count else {
            throw ProfileArchiveError.duplicateIdentifiers
        }
        return archive.profiles
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
