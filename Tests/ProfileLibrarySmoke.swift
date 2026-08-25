import Foundation

@main
enum ProfileLibrarySmoke {
    static func main() throws {
        let suiteName = "sidepulse.profile-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var builtIn = LightingProfile.commandCenter
        var builtInWorking = builtIn.style(for: .working)
        builtInWorking.motion = .pulse
        builtIn.updateStyle(builtInWorking)

        var custom = builtIn
        custom.id = UUID()
        custom.name = "Custom Pulse"

        let encodedProfiles = try JSONEncoder().encode([builtIn, custom])
        var profiles = try require(
            try JSONSerialization.jsonObject(with: encodedProfiles) as? [[String: Any]]
        )
        var styles = try require(profiles[0]["styles"] as? [[String: Any]])
        var legacyProgress = try require(styles.first(where: { $0["state"] as? String == "working" }))
        legacyProgress["state"] = "progress"
        styles.append(legacyProgress)
        profiles[0]["styles"] = styles
        let legacyLibrary: [String: Any] = [
            "schemaVersion": 5,
            "profiles": profiles,
            "selectedProfileID": builtIn.id.uuidString,
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacyLibrary), forKey: "sidepulse.profile-library.v1")

        let migrated = try require(ProfileLibrary.load(from: defaults))
        precondition(migrated.schemaVersion == 9)
        precondition(migrated.profiles.count == 1)
        precondition(migrated.profiles[0].name == "Default")
        precondition(migrated.selectedProfileID == builtIn.id)
        precondition(ProfileLibrary.defaultProfileID(from: defaults) == builtIn.id)
        precondition(migrated.profiles.first(where: { $0.id == builtIn.id })?.style(for: .working).motion == .breathe)
        precondition(!migrated.profiles.contains(where: { $0.id == custom.id }))
        precondition(
            migrated.profiles.first(where: { $0.id == builtIn.id })?.styles.filter { $0.state == .working }.count == 1
        )
        let migratedBuiltIn = try require(migrated.profiles.first(where: { $0.id == builtIn.id }))
        precondition(migratedBuiltIn.style(for: .toolRunning).motion == migratedBuiltIn.style(for: .working).motion)
        precondition(migratedBuiltIn.style(for: .toolRunning).cycleSeconds == migratedBuiltIn.style(for: .working).cycleSeconds)
        precondition(migratedBuiltIn.style(for: .toolRunning).intensity == migratedBuiltIn.style(for: .working).intensity)

        let archiveData = try ProfileLibrary.exportData(profiles: migrated.profiles)
        let imported = try ProfileLibrary.importProfiles(from: archiveData)
        precondition(imported == migrated.profiles)

        let currentSuiteName = "sidepulse.profile-current-smoke.\(UUID().uuidString)"
        let currentDefaults = UserDefaults(suiteName: currentSuiteName)!
        defer { currentDefaults.removePersistentDomain(forName: currentSuiteName) }
        var exactCurrent = LightingProfile.commandCenter
        exactCurrent.name = "My Current Setup"
        exactCurrent.deviceBrightness = 0.613
        var thinking = exactCurrent.style(for: .working)
        thinking.colorHex = "#C71585"
        thinking.cycleSeconds = 1.037
        thinking.intensity = 0.417
        exactCurrent.updateStyle(thinking)
        let schemaEight = SavedProfileLibrary(
            schemaVersion: 8,
            profiles: [.quietNight, exactCurrent, .highSignal],
            selectedProfileID: exactCurrent.id
        )
        currentDefaults.set(try JSONEncoder().encode(schemaEight), forKey: "sidepulse.profile-library.v1")

        let collapsed = try require(ProfileLibrary.load(from: currentDefaults))
        precondition(collapsed.profiles.count == 1)
        precondition(collapsed.profiles[0].name == "Default")
        precondition(collapsed.profiles[0].deviceBrightness == exactCurrent.deviceBrightness)
        precondition(collapsed.profiles[0].styles == exactCurrent.styles)
        precondition(ProfileLibrary.selectProfile(exactCurrent.id, in: currentDefaults))
        ProfileLibrary.setFocusAutomationEnabled(true, in: currentDefaults)
        precondition(ProfileLibrary.focusAutomationEnabled(from: currentDefaults))

        let duplicateArchive = SidePulseProfileArchive(profiles: [exactCurrent, exactCurrent])
        let duplicateEncoder = JSONEncoder()
        duplicateEncoder.dateEncodingStrategy = .iso8601
        let duplicateData = try duplicateEncoder.encode(duplicateArchive)
        do {
            _ = try ProfileLibrary.importProfiles(from: duplicateData)
            preconditionFailure("Duplicate profile IDs should be rejected")
        } catch ProfileArchiveError.duplicateIdentifiers {
            // Expected.
        }

        print("Profile library smoke passed: current settings become Default, presets are removed, and JSON round-trips")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw NSError(domain: "ProfileLibrarySmoke", code: 1)
        }
        return value
    }
}
