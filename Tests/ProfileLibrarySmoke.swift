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
        let profiles = try JSONSerialization.jsonObject(with: encodedProfiles)
        let legacyLibrary: [String: Any] = [
            "schemaVersion": 5,
            "profiles": profiles,
            "selectedProfileID": builtIn.id.uuidString,
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacyLibrary), forKey: "sidepulse.profile-library.v1")

        let migrated = try require(ProfileLibrary.load(from: defaults))
        precondition(migrated.schemaVersion == 6)
        precondition(migrated.profiles.first(where: { $0.id == builtIn.id })?.style(for: .working).motion == .breathe)
        precondition(migrated.profiles.first(where: { $0.id == custom.id })?.style(for: .working).motion == .pulse)
        print("Profile library smoke passed: Pulse Wave rollback restores built-ins and preserves custom Pulse")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw NSError(domain: "ProfileLibrarySmoke", code: 1)
        }
        return value
    }
}
