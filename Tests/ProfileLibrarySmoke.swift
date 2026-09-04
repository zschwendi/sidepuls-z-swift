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
        precondition(AppPreferences.menuBarIconStyle(from: preferencesDefaults) == .horizontalFour)
        preferencesDefaults.set("mirroredFour", forKey: "sidepulse.menu-bar-icon-style.v1")
        precondition(AppPreferences.menuBarIconStyle(from: preferencesDefaults) == .horizontalFour)
        preferencesDefaults.set("verticalEight", forKey: "sidepulse.menu-bar-icon-style.v1")
        precondition(AppPreferences.menuBarIconStyle(from: preferencesDefaults) == .horizontalEight)
        AppPreferences.saveMenuBarIconStyle(.horizontalFour, to: preferencesDefaults)
        precondition(AppPreferences.menuBarIconStyle(from: preferencesDefaults) == .horizontalFour)
        precondition(AppPreferences.universalBrightness(from: preferencesDefaults) == 1)
        AppPreferences.saveUniversalBrightness(0.43, to: preferencesDefaults)
        precondition(AppPreferences.universalBrightness(from: preferencesDefaults) == 0.43)
        AppPreferences.saveUniversalBrightness(-1, to: preferencesDefaults)
        precondition(AppPreferences.universalBrightness(from: preferencesDefaults) == 0)
        AppPreferences.saveUniversalBrightness(2, to: preferencesDefaults)
        precondition(AppPreferences.universalBrightness(from: preferencesDefaults) == 1)
        precondition(AppPreferences.flashlightMode(from: preferencesDefaults) == .overrideEverything)
        AppPreferences.saveFlashlightMode(.behindAnimations, to: preferencesDefaults)
        precondition(AppPreferences.flashlightMode(from: preferencesDefaults) == .behindAnimations)
        precondition(AppPreferences.proColorBalance(from: preferencesDefaults) == .standard)
        AppPreferences.saveProColorBalance(
            OutputColorBalance(red: 0.8, green: -1, blue: 2),
            to: preferencesDefaults
        )
        precondition(
            AppPreferences.proColorBalance(from: preferencesDefaults)
                == OutputColorBalance(red: 0.8, green: 0, blue: 1)
        )
        precondition(AppPreferences.ejectPreventionEnabled(from: preferencesDefaults))
        AppPreferences.saveEjectPreventionEnabled(false, to: preferencesDefaults)
        precondition(!AppPreferences.ejectPreventionEnabled(from: preferencesDefaults))
        precondition(AppPreferences.nearbyMirroringMode(from: preferencesDefaults) == .off)
        precondition(!AppPreferences.nearbySharingEnabled(from: preferencesDefaults))
        precondition(!AppPreferences.nearbyDiscoveryEnabled(from: preferencesDefaults))
        precondition(AppPreferences.signalSource(for: .pro, from: preferencesDefaults) == .thisMac)
        precondition(AppPreferences.signalSource(for: .dot, from: preferencesDefaults) == .thisMac)
        precondition(
            AppPreferences.outputCalibration(for: .pro, from: preferencesDefaults)
                == SidePulseDeviceKind.pro.defaultOutputCalibration
        )
        precondition(
            AppPreferences.outputCalibration(for: .dot, from: preferencesDefaults)
                == SidePulseDeviceKind.dot.defaultOutputCalibration
        )
        AppPreferences.saveNearbyMirroringMode(.allMacs, to: preferencesDefaults)
        precondition(AppPreferences.nearbyMirroringMode(from: preferencesDefaults) == .allMacs)
        precondition(AppPreferences.nearbySharingEnabled(from: preferencesDefaults))
        precondition(AppPreferences.nearbyDiscoveryEnabled(from: preferencesDefaults))
        precondition(AppPreferences.signalSource(for: .pro, from: preferencesDefaults) == .allMacs)
        precondition(AppPreferences.signalSource(for: .dot, from: preferencesDefaults) == .allMacs)
        let nearbyPeerID = UUID().uuidString.lowercased()
        AppPreferences.saveNearbyMirroringMode(.followNearbyMac, to: preferencesDefaults)
        AppPreferences.saveSelectedNearbyPeerID(nearbyPeerID, to: preferencesDefaults)
        precondition(AppPreferences.selectedNearbyPeerID(from: preferencesDefaults) == nearbyPeerID)
        precondition(
            AppPreferences.signalSource(for: .pro, from: preferencesDefaults)
                == .nearbyMac(nearbyPeerID)
        )
        precondition(
            AppPreferences.signalSource(for: .dot, from: preferencesDefaults)
                == .nearbyMac(nearbyPeerID)
        )
        AppPreferences.saveSignalSource(.thisMac, for: .pro, to: preferencesDefaults)
        AppPreferences.saveSignalSource(.allMacs, for: .dot, to: preferencesDefaults)
        precondition(AppPreferences.signalSource(for: .pro, from: preferencesDefaults) == .thisMac)
        precondition(AppPreferences.signalSource(for: .dot, from: preferencesDefaults) == .allMacs)
        AppPreferences.saveNearbySharingEnabled(false, to: preferencesDefaults)
        AppPreferences.saveNearbyDiscoveryEnabled(true, to: preferencesDefaults)
        precondition(!AppPreferences.nearbySharingEnabled(from: preferencesDefaults))
        precondition(AppPreferences.nearbyDiscoveryEnabled(from: preferencesDefaults))
        AppPreferences.saveOutputCalibration(
            SidePulseOutputCalibration(brightnessScale: 0.57, blueScale: 0.83),
            for: .dot,
            to: preferencesDefaults
        )
        precondition(
            AppPreferences.outputCalibration(for: .dot, from: preferencesDefaults)
                == SidePulseOutputCalibration(brightnessScale: 0.57, blueScale: 0.83)
        )
        AppPreferences.saveOutputCalibration(
            SidePulseOutputCalibration(brightnessScale: 99, blueScale: -4),
            for: .pro,
            to: preferencesDefaults
        )
        precondition(
            AppPreferences.outputCalibration(for: .pro, from: preferencesDefaults)
                == SidePulseOutputCalibration(brightnessScale: 1.5, blueScale: 0.5)
        )
        let nodeID = AppPreferences.nearbyNodeID(from: preferencesDefaults)
        precondition(UUID(uuidString: nodeID) != nil)
        precondition(AppPreferences.nearbyNodeID(from: preferencesDefaults) == nodeID)
        precondition(AppPreferences.batteryIndicatorSettings(from: preferencesDefaults) == BatteryIndicatorSettings())
        var batterySettings = BatteryIndicatorSettings()
        batterySettings.mode = .statusBottom
        batterySettings.showsWhenLidCloses = false
        batterySettings.showsWhenPowerSourceChanges = false
        batterySettings.lowBatteryThresholdPercent = 30
        batterySettings.lowBatteryReminderIntervalSeconds = 45
        AppPreferences.saveBatteryIndicatorSettings(batterySettings, to: preferencesDefaults)
        precondition(AppPreferences.batteryIndicatorSettings(from: preferencesDefaults) == batterySettings)

        let legacyBatteryJSON = #"{"showsChargeInfo":true,"mode":"greenOutline","showsWhenLidOpens":false,"showsWhenLidCloses":true,"lowBatteryReminderEnabled":false,"lowBatteryThresholdPercent":35,"lowBatteryReminderIntervalSeconds":60}"#.data(using: .utf8)!
        preferencesDefaults.set(legacyBatteryJSON, forKey: "sidepulse.battery-indicator.v1")
        let migratedBatterySettings = AppPreferences.batteryIndicatorSettings(
            from: preferencesDefaults
        )
        precondition(migratedBatterySettings.mode == .greenOutline)
        precondition(!migratedBatterySettings.showsWhenLidOpens)
        precondition(migratedBatterySettings.showsWhenPowerSourceChanges)
        precondition(migratedBatterySettings.lowBatteryThresholdPercent == 35)

        let identityMigrationSuite = "sidepulse.identity-migration-smoke.\(UUID().uuidString)"
        let identityMigrationDefaults = UserDefaults(suiteName: identityMigrationSuite)!
        defer { identityMigrationDefaults.removePersistentDomain(forName: identityMigrationSuite) }
        identityMigrationDefaults.set(0.61, forKey: "sidepulse.universal-brightness.v1")
        LegacySidePulsePreferences.copySidePulseValues(
            from: [
                "sidepulse.universal-brightness.v1": 0.32,
                "sidepulse.agent-display-mode.v1": "perAgent",
                "NSWindow Frame command-center": "private geometry",
            ],
            to: identityMigrationDefaults
        )
        precondition(identityMigrationDefaults.double(forKey: "sidepulse.universal-brightness.v1") == 0.61)
        precondition(identityMigrationDefaults.string(forKey: "sidepulse.agent-display-mode.v1") == "perAgent")
        precondition(identityMigrationDefaults.object(forKey: "NSWindow Frame command-center") == nil)

        print("Profile library smoke passed: profiles, display mode, menu icon, brightness, color balance, flashlight, eject prevention, nearby routing, and battery preferences persist independently")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw NSError(domain: "ProfileLibrarySmoke", code: 1)
        }
        return value
    }
}
