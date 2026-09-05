import AppKit

@main
enum NotchInteractionSmoke {
    @MainActor
    static func main() async throws {
        testMenuBarVisibilityMatrix()
        testMenuBarPreferenceIsolation()
        testAgentSelection()
        testExpandedGeometry()
        await testPanelExpansionContract()
        print("Notch interaction smoke passed")
    }

    private static func testMenuBarVisibilityMatrix() {
        let booleans = [false, true]
        for mode in MenuBarVisibilityMode.allCases {
            for notchPresented in booleans {
                for menuBarAutoHidden in booleans {
                    for keepWhenAutoHidden in booleans {
                        let expected: Bool
                        switch mode {
                        case .always:
                            expected = true
                        case .never:
                            expected = false
                        case .whenNotchOff:
                            expected = !notchPresented || (menuBarAutoHidden && keepWhenAutoHidden)
                        }
                        let actual = mode.shouldShow(
                            notchPresented: notchPresented,
                            menuBarAutoHidden: menuBarAutoHidden,
                            keepWhenAutoHidden: keepWhenAutoHidden
                        )
                        precondition(
                            actual == expected,
                            "Unexpected menu-bar visibility for \(mode.rawValue), notch=\(notchPresented), autoHidden=\(menuBarAutoHidden), keep=\(keepWhenAutoHidden)"
                        )
                    }
                }
            }
        }
    }

    private static func testMenuBarPreferenceIsolation() {
        let suiteName = "sidepulse.notch-interaction-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sentinelKey = "sidepulse.notch-interaction-smoke.sentinel"
        defaults.set("preserve me", forKey: sentinelKey)
        precondition(AppPreferences.menuBarVisibilityMode(from: defaults) == .whenNotchOff)
        precondition(AppPreferences.menuBarKeepWhenAutoHidden(from: defaults))

        AppPreferences.saveMenuBarVisibilityMode(.always, to: defaults)
        AppPreferences.saveMenuBarKeepWhenAutoHidden(false, to: defaults)
        precondition(AppPreferences.menuBarVisibilityMode(from: defaults) == .always)
        precondition(AppPreferences.menuBarKeepWhenAutoHidden(from: defaults) == false)
        precondition(defaults.string(forKey: sentinelKey) == "preserve me")

        defaults.set("unsupported", forKey: "sidepulse.menu-bar-visibility.v1")
        precondition(AppPreferences.menuBarVisibilityMode(from: defaults) == .whenNotchOff)
        defaults.removeObject(forKey: "sidepulse.menu-bar-keep-auto-hidden.v1")
        precondition(AppPreferences.menuBarKeepWhenAutoHidden(from: defaults))
    }

    private static func makeAgent(
        id: String,
        state: AgentState,
        updatedAt: TimeInterval
    ) -> AgentSession {
        AgentSession(
            id: id,
            provider: .codex,
            sessionID: id,
            name: id,
            project: "SidePulse",
            cwd: nil,
            state: state,
            eventName: "Smoke",
            toolName: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt),
            message: nil
        )
    }

    private static func testAgentSelection() {
        let agents = [
            makeAgent(id: "z-old-working", state: .working, updatedAt: 10),
            makeAgent(id: "b-new-working", state: .working, updatedAt: 20),
            makeAgent(id: "a-new-tool", state: .toolRunning, updatedAt: 20),
            makeAgent(id: "completed", state: .completed, updatedAt: 30),
            makeAgent(id: "idle", state: .idle, updatedAt: 40),
        ]
        let simple = NotchAgentSelection.drivingAgents(
            agents: agents,
            mode: .simple,
            displayedAgentIDs: ["completed"]
        )
        precondition(simple.map(\.id) == ["a-new-tool", "b-new-working", "z-old-working"])

        let errorFirst = agents + [makeAgent(id: "error", state: .error, updatedAt: 1)]
        let errors = NotchAgentSelection.drivingAgents(
            agents: errorFirst,
            mode: .simple,
            displayedAgentIDs: []
        )
        precondition(errors.map(\.id) == ["error"])

        let perAgent = NotchAgentSelection.drivingAgents(
            agents: [
                makeAgent(id: "first", state: .idle, updatedAt: 1),
                makeAgent(id: "second", state: .working, updatedAt: 2),
                makeAgent(id: "third", state: .error, updatedAt: 3),
            ],
            mode: .perAgent,
            displayedAgentIDs: ["third", "missing", "first", "third"]
        )
        // Placement IDs are supplied in physical LED-array order, which can
        // differ from the agent hub's order. Each session appears only once.
        precondition(perAgent.map(\.id) == ["third", "first"])
    }

    private static func testExpandedGeometry() {
        let screen = CGRect(x: 100, y: 50, width: 1200, height: 900)
        let collapsed = CGRect(x: 620, y: 880, width: 160, height: 40)
        let expanded = NotchDisplayGeometry.expandedFrame(
            collapsed: collapsed,
            screen: screen,
            contentHeight: 200
        )
        precondition(expanded.width == 400)
        precondition(expanded.height == 262)
        precondition(expanded.midX == collapsed.midX)
        precondition(expanded.maxY == screen.maxY)
        precondition(expanded.minY >= screen.minY)

        let left = NotchDisplayGeometry.expandedFrame(
            collapsed: CGRect(x: 0, y: 880, width: 80, height: 40),
            screen: screen,
            contentHeight: 200
        )
        precondition(left.minX == screen.minX && left.maxY == screen.maxY)

        let right = NotchDisplayGeometry.expandedFrame(
            collapsed: CGRect(x: 1_300, y: 880, width: 80, height: 40),
            screen: screen,
            contentHeight: 200
        )
        precondition(right.maxX == screen.maxX && right.maxY == screen.maxY)

        let capped = NotchDisplayGeometry.expandedFrame(
            collapsed: collapsed,
            screen: screen,
            contentHeight: 10_000
        )
        precondition(capped.width == 400)
        precondition(capped.height == screen.height)
        precondition(capped.minY == screen.minY && capped.maxY == screen.maxY)

        let narrowScreen = CGRect(x: -20, y: 0, width: 300, height: 500)
        let narrow = NotchDisplayGeometry.expandedFrame(
            collapsed: CGRect(x: 100, y: 450, width: 40, height: 30),
            screen: narrowScreen,
            contentHeight: 100
        )
        precondition(narrow.width == narrowScreen.width)
        precondition(narrow.maxY == narrowScreen.maxY)
    }

    @MainActor
    private static func testPanelExpansionContract() async {
        _ = NSApplication.shared
        let controller = NotchDisplayController()
        let program = "#FF00FF"

        controller.update(enabled: true, program: program, ledCount: 8, clockOrigin: nil, brightness: 1)
        precondition(!controller.isExpanded)
        controller.setExpanded(true, animated: false)
        precondition(!controller.isExpanded, "An enabled notch without island content must remain collapsed")

        guard !NSScreen.screens.isEmpty else {
            controller.update(enabled: false, program: program, ledCount: 8, clockOrigin: nil, brightness: 1)
            precondition(!controller.isPresented && !controller.isExpanded)
            return
        }

        let island = NSView(frame: .zero)
        controller.setIslandContent(island, height: 200)
        precondition(!controller.isExpanded)
        precondition(island.isHidden)

        guard let panel = NSApp.windows.first(where: { $0.title == "SidePulse Notch" }) else {
            preconditionFailure("The enabled controller did not create its panel")
        }
        precondition(controller.isPresented && panel.isVisible)
        precondition(!panel.ignoresMouseEvents, "The panel becomes interactive only after island content is installed")
        precondition(!panel.isKeyWindow && !panel.isMainWindow)

        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens[0]
        let depth = screen.safeAreaInsets.top
        let notchWidth: CGFloat?
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            notchWidth = right.minX - left.maxX
        } else {
            notchWidth = nil
        }
        let collapsed = NotchDisplayGeometry.frame(
            screen: screen.frame,
            notchDepth: depth,
            notchWidth: notchWidth
        )
        precondition(panel.frame == collapsed)
        precondition(panel.frame.maxY == screen.frame.maxY)

        controller.setExpanded(true, animated: false)
        precondition(controller.isExpanded && controller.isPresented)
        precondition(!island.isHidden)
        precondition(!panel.isKeyWindow && !panel.isMainWindow)
        precondition(!panel.ignoresMouseEvents)
        let expectedExpanded = NotchDisplayGeometry.expandedFrame(
            collapsed: collapsed,
            screen: screen.frame,
            contentHeight: 200
        )
        precondition(panel.frame == expectedExpanded)
        precondition(panel.frame.maxY == screen.frame.maxY)
        precondition(panel.collectionBehavior.contains(.fullScreenAuxiliary))

        controller.setIslandContentHeight(118)
        try? await Task.sleep(for: .milliseconds(450))
        precondition(controller.isExpanded && panel.frame.maxY == screen.frame.maxY)
        precondition(panel.frame.height == collapsed.height + 118 + 22,
                     "A single agent should shrink the island without closing it")
        controller.setIslandContentHeight(200)

        controller.setExpanded(false, animated: false)
        precondition(!controller.isExpanded && controller.isPresented)
        precondition(island.isHidden && panel.isVisible)
        precondition(panel.frame == collapsed)

        controller.setExpanded(true)
        try? await Task.sleep(for: .milliseconds(450))
        precondition(!island.isHidden && island.alphaValue == 1)
        controller.setExpanded(false)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(!island.isHidden, "Closing contents must stay present during their fade")
        }
        controller.setExpanded(true)
        try? await Task.sleep(for: .milliseconds(450))
        precondition(controller.isExpanded && !island.isHidden && island.alphaValue == 1,
                     "An interrupted close must not hide a reopened island")
        controller.setExpanded(false)
        try? await Task.sleep(for: .milliseconds(400))
        precondition(island.isHidden && island.alphaValue == 0 && panel.frame == collapsed)

        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                          eventNumber: 0, trackingNumber: 0, userData: nil)!
        let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                         eventNumber: 0, trackingNumber: 0, userData: nil)!
        panel.contentView?.mouseEntered(with: enter)
        precondition(controller.isExpanded, "Entering the notch must expand its controls")
        panel.contentView?.mouseExited(with: exit)
        panel.contentView?.mouseEntered(with: enter)
        try? await Task.sleep(for: .milliseconds(250))
        precondition(controller.isExpanded, "Re-entering must cancel a pending close")
        panel.contentView?.mouseExited(with: exit)
        try? await Task.sleep(for: .milliseconds(250))
        if !panel.frame.contains(NSEvent.mouseLocation) {
            precondition(!controller.isExpanded, "Leaving the entire island must close it")
        }
        precondition(!panel.canBecomeKey && !panel.canBecomeMain)

        controller.update(enabled: false, program: program, ledCount: 8, clockOrigin: nil, brightness: 1)
        precondition(!controller.isPresented && !controller.isExpanded)
        precondition(island.isHidden && !panel.isVisible)
        controller.setExpanded(true, animated: false)
        precondition(!controller.isExpanded)
    }
}
