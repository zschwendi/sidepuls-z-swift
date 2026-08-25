import Foundation

@main
enum ProfileLibrarySmoke {
    static func main() throws {
        let factory = LightingProfile.factoryDefault
        precondition(factory.name == "Default")
        precondition(factory.strategy == .adaptiveOccupancy)
        precondition(factory.deviceBrightness == 0.72)
        precondition(factory.styles == [
            .init(state: .idle, colorHex: "#EEF9E0", secondaryColorHex: "#7C3AED", motion: .off, cycleSeconds: 8, intensity: 0),
            .init(state: .working, colorHex: "#FF2BD6", secondaryColorHex: "#DBD1EE", motion: .breathe, cycleSeconds: 1.0340260549065254, intensity: 0.41507945559610704),
            .init(state: .toolRunning, colorHex: "#0018FF", secondaryColorHex: "#7C3AED", motion: .breathe, cycleSeconds: 1.0340260549065254, intensity: 0.41507945559610704),
            .init(state: .waiting, colorHex: "#FFD60A", secondaryColorHex: "#7C3AED", motion: .flash, cycleSeconds: 0.7369829683698299, intensity: 0.88),
            .init(state: .error, colorHex: "#FF0000", secondaryColorHex: "#7C3AED", motion: .solid, cycleSeconds: 1, intensity: 0.95),
            .init(state: .completed, colorHex: "#00D300", secondaryColorHex: "#7C3AED", motion: .solid, cycleSeconds: 1, intensity: 0.85),
        ])

        let protectedSuiteName = "sidepulse.profile-protected-smoke.\(UUID().uuidString)"
        let protectedDefaults = UserDefaults(suiteName: protectedSuiteName)!
        defer { protectedDefaults.removePersistentDomain(forName: protectedSuiteName) }
        var userOwned = factory
        userOwned.id = UUID()
        userOwned.name = "Never Replace Me"
        userOwned.deviceBrightness = 0.317
        var userThinking = userOwned.style(for: .working)
        userThinking.colorHex = "#123456"
        userOwned.updateStyle(userThinking)
        let currentLibrary = SavedProfileLibrary(
            schemaVersion: 9,
            profiles: [userOwned],
            selectedProfileID: userOwned.id
        )
        protectedDefaults.set(
            try JSONEncoder().encode(currentLibrary),
            forKey: "sidepulse.profile-library.v1"
        )
        let protectedLibrary = try require(ProfileLibrary.load(from: protectedDefaults))
        precondition(protectedLibrary.profiles == [userOwned])
        precondition(protectedLibrary.selectedProfileID == userOwned.id)

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

        let preferencesSuiteName = "sidepulse.preferences-smoke.\(UUID().uuidString)"
        let preferencesDefaults = UserDefaults(suiteName: preferencesSuiteName)!
        defer { preferencesDefaults.removePersistentDomain(forName: preferencesSuiteName) }
        precondition(AppPreferences.agentDisplayMode(from: preferencesDefaults) == .simple)
        AppPreferences.saveAgentDisplayMode(.perAgent, to: preferencesDefaults)
        precondition(AppPreferences.agentDisplayMode(from: preferencesDefaults) == .perAgent)
        precondition(AppPreferences.menuBarIconStyle(from: preferencesDefaults) == .horizontalEight)
        AppPreferences.saveMenuBarIconStyle(.mirroredFour, to: preferencesDefaults)
        precondition(AppPreferences.menuBarIconStyle(from: preferencesDefaults) == .mirroredFour)
        precondition(AppPreferences.batteryIndicatorSettings(from: preferencesDefaults) == BatteryIndicatorSettings())
        var batterySettings = BatteryIndicatorSettings()
        batterySettings.mode = .statusBottom
        batterySettings.showsWhenLidCloses = false
        batterySettings.lowBatteryThresholdPercent = 30
        batterySettings.lowBatteryReminderIntervalSeconds = 45
        AppPreferences.saveBatteryIndicatorSettings(batterySettings, to: preferencesDefaults)
        precondition(AppPreferences.batteryIndicatorSettings(from: preferencesDefaults) == batterySettings)

        print("Profile library smoke passed: profiles, display mode, menu icon, and battery preferences persist independently")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw NSError(domain: "ProfileLibrarySmoke", code: 1)
        }
        return value
    }
}
