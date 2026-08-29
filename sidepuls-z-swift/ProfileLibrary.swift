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
        // Saved profiles win over the compiled factory baseline. Factory changes
        // must never mutate a current-schema library behind the user's back.
        guard library.schemaVersion < 9 else { return library }

        let builtIns = [
            LightingProfile.factoryDefault,
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
                ?? .factoryDefault
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
    private static let batteryIndicatorKey = "sidepulse.battery-indicator.v1"
    private static let agentDisplayModeKey = "sidepulse.agent-display-mode.v1"
    private static let menuBarIconStyleKey = "sidepulse.menu-bar-icon-style.v1"
    private static let universalBrightnessKey = "sidepulse.universal-brightness.v1"
    private static let nearbyMirroringModeKey = "sidepulse.nearby-mirroring-mode.v1"
    private static let selectedNearbyPeerKey = "sidepulse.selected-nearby-peer.v1"
    private static let nearbyNodeIDKey = "sidepulse.nearby-node-id.v1"

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

    static func agentDisplayMode(from defaults: UserDefaults = .standard) -> AgentDisplayMode {
        guard let rawValue = defaults.string(forKey: agentDisplayModeKey),
              let mode = AgentDisplayMode(rawValue: rawValue)
        else { return .simple }
        return mode
    }

    static func saveAgentDisplayMode(
        _ mode: AgentDisplayMode,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: agentDisplayModeKey)
    }

    static func menuBarIconStyle(from defaults: UserDefaults = .standard) -> MenuBarIconStyle {
        guard let rawValue = defaults.string(forKey: menuBarIconStyleKey) else {
            return .horizontalFour
        }
        if let style = MenuBarIconStyle(rawValue: rawValue) { return style }

        // Preserve the closest horizontal layout when upgrading from the
        // retired vertical, mirrored, and symbol choices.
        return rawValue == "verticalEight" ? .horizontalEight : .horizontalFour
    }

    static func saveMenuBarIconStyle(
        _ style: MenuBarIconStyle,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(style.rawValue, forKey: menuBarIconStyleKey)
    }

    static func universalBrightness(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: universalBrightnessKey) != nil else { return 1 }
        return max(0, min(1, defaults.double(forKey: universalBrightnessKey)))
    }

    static func saveUniversalBrightness(
        _ brightness: Double,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(max(0, min(1, brightness)), forKey: universalBrightnessKey)
    }

    static func nearbyMirroringMode(
        from defaults: UserDefaults = .standard
    ) -> NearbyMirroringMode {
        guard let rawValue = defaults.string(forKey: nearbyMirroringModeKey),
              let mode = NearbyMirroringMode(rawValue: rawValue)
        else { return .off }
        return mode
    }

    static func saveNearbyMirroringMode(
        _ mode: NearbyMirroringMode,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: nearbyMirroringModeKey)
    }

    static func selectedNearbyPeerID(
        from defaults: UserDefaults = .standard
    ) -> String? {
        defaults.string(forKey: selectedNearbyPeerKey)
    }

    static func saveSelectedNearbyPeerID(
        _ peerID: String?,
        to defaults: UserDefaults = .standard
    ) {
        if let peerID {
            defaults.set(peerID, forKey: selectedNearbyPeerKey)
        } else {
            defaults.removeObject(forKey: selectedNearbyPeerKey)
        }
    }

    static func nearbyNodeID(from defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: nearbyNodeIDKey)?.lowercased(),
           UUID(uuidString: stored) != nil {
            return stored
        }
        let nodeID = UUID().uuidString.lowercased()
        defaults.set(nodeID, forKey: nearbyNodeIDKey)
        return nodeID
    }

    static func batteryIndicatorSettings(
        from defaults: UserDefaults = .standard
    ) -> BatteryIndicatorSettings {
        guard let data = defaults.data(forKey: batteryIndicatorKey),
              let settings = try? JSONDecoder().decode(BatteryIndicatorSettings.self, from: data)
        else { return BatteryIndicatorSettings() }
        return settings.normalized
    }

    static func saveBatteryIndicatorSettings(
        _ settings: BatteryIndicatorSettings,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(try? JSONEncoder().encode(settings.normalized), forKey: batteryIndicatorKey)
    }
}

enum LegacySidePulsePreferences {
    static let sourceBundleIdentifier = "com.zephyrstudiosllc.sidepuls-z-swift"
    private static let migrationMarker = "sidepulse.bundle-identity-migrated.v1"

    static func migrateIfNeeded(
        to defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        guard defaults.object(forKey: migrationMarker) == nil else { return }

        var legacyValues = UserDefaults(
            suiteName: sourceBundleIdentifier
        )?.dictionaryRepresentation() ?? [:]

        // Read the persisted domain directly as well. This preserves settings
        // if cfprefsd still has a stale view after an in-place app replacement.
        let legacyURL = homeDirectory
            .appending(path: "Library/Preferences")
            .appending(path: "\(sourceBundleIdentifier).plist")
        if let data = try? Data(contentsOf: legacyURL),
           let persisted = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) as? [String: Any]
        {
            legacyValues.merge(persisted) { _, persistedValue in persistedValue }
        }

        copySidePulseValues(from: legacyValues, to: defaults)
        defaults.set(true, forKey: migrationMarker)
    }

    static func copySidePulseValues(
        from legacyValues: [String: Any],
        to defaults: UserDefaults
    ) {
        for (key, value) in legacyValues where key.hasPrefix("sidepulse.") {
            guard key != migrationMarker, defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
        }
    }
}
