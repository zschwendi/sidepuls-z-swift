import AppKit

@main
enum NotchDisplaySmoke {
    @MainActor
    static func main() throws {
        let screen = CGRect(x: -1728, y: 400, width: 1728, height: 1117)
        let notch = NotchDisplayGeometry.frame(screen: screen, notchDepth: 32, notchWidth: 200)
        precondition(notch == CGRect(x: -964, y: 1480, width: 200, height: 37))
        let flat = NotchDisplayGeometry.frame(screen: screen, notchDepth: 0, notchWidth: nil)
        precondition(flat.height == 5 && flat.maxY == screen.maxY && flat.midX == screen.midX)
        let narrow = NotchDisplayGeometry.frame(screen: CGRect(x: 0, y: 0, width: 150, height: 100), notchDepth: -1, notchWidth: 999)
        precondition(narrow.width == 150 && narrow.height == 5)
        let red = LEDProgramColor(red: 1, green: 0, blue: 0)
        let colors = [red] + Array(repeating: LEDProgramColor.black, count: 7)
        precondition(NotchDisplayGeometry.blendedColor(colors, x: 10, width: 160) == red)
        precondition(NotchDisplayGeometry.blendedColor(colors, x: 30, width: 160).red > 0)
        precondition(NotchDisplayGeometry.blendedColor(colors, x: 41, width: 160) == .black)
        precondition(NotchDisplayGeometry.blendedColor([], x: 0, width: 0) == .black)

        let suite = "sidepulse.notch-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var custom = LightingProfile.factoryDefault
        custom.name = "Keep my lighting"
        custom.deviceBrightness = 0.317
        ProfileLibrary.save(profiles: [custom], selectedProfileID: custom.id, to: defaults)
        AppPreferences.saveMenuBarIconStyle(.horizontalFour, to: defaults)
        let original = defaults.dictionaryRepresentation()
        precondition(!AppPreferences.notchEnabled(from: defaults))
        precondition(AppPreferences.notchBrightness(from: defaults) == 1)
        AppPreferences.saveNotchEnabled(true, to: defaults)
        AppPreferences.saveNotchBrightness(0.37, to: defaults)
        precondition(AppPreferences.notchEnabled(from: defaults))
        precondition(AppPreferences.notchBrightness(from: defaults) == 0.37)
        for (key, value) in original {
            precondition(NSDictionary(dictionary: [key: value]).isEqual(to: [key: defaults.object(forKey: key)!]))
        }
        AppPreferences.saveNotchBrightness(2, to: defaults)
        precondition(AppPreferences.notchBrightness(from: defaults) == 1)
        AppPreferences.saveNotchBrightness(-1, to: defaults)
        precondition(AppPreferences.notchBrightness(from: defaults) == 0)

        _ = NSApplication.shared
        let controller = NotchDisplayController()
        controller.update(enabled: false, program: "#FF00FF", ledCount: 8, clockOrigin: nil, brightness: 1)
        precondition(!NSApp.windows.contains { $0.title == "SidePulse Notch" })
        if !NSScreen.screens.isEmpty {
            controller.update(enabled: true, program: "#FF00FF", ledCount: 8, clockOrigin: nil, brightness: 1)
            let panel = NSApp.windows.first { $0.title == "SidePulse Notch" }!
            precondition(panel.isVisible && panel.ignoresMouseEvents && !panel.isKeyWindow)
            precondition(panel.level == .statusBar && panel.collectionBehavior.contains(.fullScreenAuxiliary))
            controller.update(enabled: true, program: "#FF00FF", ledCount: 8, clockOrigin: nil, brightness: 0)
            precondition(!panel.isVisible)
            controller.update(enabled: false, program: "#FF00FF", ledCount: 8, clockOrigin: nil, brightness: 1)
            precondition(!panel.isVisible)
        }
        // Offscreen visual fixtures exercise both display shapes without touching
        // the running app, its settings, hardware, or event socket.
        if let output = ProcessInfo.processInfo.environment["SIDEPULSE_NOTCH_QA_DIR"] {
            for hasNotch in [false, true] {
                let view = NotchLEDView(frame: CGRect(x: 0, y: 0, width: 220, height: hasNotch ? 37 : 5))
                view.configure(program: "0:#FF00FF; 1:#FF00FF; 2:#8000FF; 3:#0000FF; 4:#00FFFF; 5:#00FF80; 6:#FFFF00; 7:#FF8000", ledCount: 8, clockOrigin: nil, brightness: 1, hasNotch: hasNotch)
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = bitmap.representation(using: .png, properties: [:])!
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(hasNotch ? "notch.png" : "flat-display.png"))
                view.stopAnimating()
            }
        }
        print("Notch display smoke passed")
    }
}
