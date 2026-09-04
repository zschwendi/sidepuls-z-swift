#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h}
test_dir=$(mktemp -d /tmp/sidepulse-smoke.XXXXXX)

cleanup() {
    rm -rf "$test_dir"
}
trap cleanup EXIT

cd "$repo_dir"

xcrun swiftc \
    sidepuls-z-swift/LEDProgramRenderer.swift \
    sidepuls-z-swift/Models.swift \
    sidepuls-z-swift/NearbySignalModels.swift \
    sidepuls-z-swift/ProfileLibrary.swift \
    Tests/ProfileLibrarySmoke.swift \
    -o "$test_dir/ProfileLibrarySmoke"
"$test_dir/ProfileLibrarySmoke"

xcrun swiftc \
    sidepuls-z-swift/LEDProgramRenderer.swift \
    sidepuls-z-swift/Models.swift \
    sidepuls-z-swift/NearbySignalModels.swift \
    sidepuls-z-swift/ProfileLibrary.swift \
    sidepuls-z-swift/NotchDisplay.swift \
    Tests/NotchDisplaySmoke.swift \
    -o "$test_dir/NotchDisplaySmoke"
"$test_dir/NotchDisplaySmoke"

xcrun swiftc \
    sidepuls-z-swift/LEDProgramRenderer.swift \
    sidepuls-z-swift/Models.swift \
    sidepuls-z-swift/LightingEngine.swift \
    sidepuls-z-swift/NearbySignalModels.swift \
    sidepuls-z-swift/ProfileLibrary.swift \
    sidepuls-z-swift/UtilityModes.swift \
    Tests/UtilityModesSmoke.swift \
    -o "$test_dir/UtilityModesSmoke"
"$test_dir/UtilityModesSmoke"

xcrun swiftc \
    -default-isolation MainActor \
    sidepuls-z-swift/MicrophoneMonitor.swift \
    Tests/MicrophoneMonitorSmoke.swift \
    -o "$test_dir/MicrophoneMonitorSmoke"
"$test_dir/MicrophoneMonitorSmoke"

xcrun swiftc \
    -default-isolation MainActor \
    sidepuls-z-swift/ProgressTaskRunner.swift \
    Tests/ProgressTaskRunnerSmoke.swift \
    -o "$test_dir/ProgressTaskRunnerSmoke"
"$test_dir/ProgressTaskRunnerSmoke"

xcrun swiftc \
    sidepuls-z-swift/LEDProgramRenderer.swift \
    sidepuls-z-swift/Models.swift \
    sidepuls-z-swift/LightingEngine.swift \
    sidepuls-z-swift/HardwareController.swift \
    Tests/SceneCompilerSmoke.swift \
    -o "$test_dir/SceneCompilerSmoke"
"$test_dir/SceneCompilerSmoke"

xcrun swiftc \
    sidepuls-z-swift/LEDProgramRenderer.swift \
    sidepuls-z-swift/Models.swift \
    sidepuls-z-swift/SidePulseEjectGuard.swift \
    Tests/EjectGuardSmoke.swift \
    -o "$test_dir/EjectGuardSmoke"
"$test_dir/EjectGuardSmoke"

xcrun swiftc \
    sidepuls-z-swift/LEDProgramRenderer.swift \
    sidepuls-z-swift/Models.swift \
    sidepuls-z-swift/AgentSignalHistory.swift \
    Tests/AgentSignalHistorySmoke.swift \
    -o "$test_dir/AgentSignalHistorySmoke"
"$test_dir/AgentSignalHistorySmoke"

xcrun swiftc \
    sidepuls-z-swift/LEDProgramRenderer.swift \
    sidepuls-z-swift/Models.swift \
    sidepuls-z-swift/NearbySignalModels.swift \
    Tests/NearbySignalSmoke.swift \
    -o "$test_dir/NearbySignalSmoke"
"$test_dir/NearbySignalSmoke"

xcrun swiftc \
    sidepuls-z-swift/CodexIPCBridge.swift \
    sidepuls-z-swift/LEDProgramRenderer.swift \
    sidepuls-z-swift/Models.swift \
    sidepuls-z-swift/AgentSignalHistory.swift \
    sidepuls-z-swift/AgentRuntime.swift \
    Tests/AgentRuntimeSmoke.swift \
    -o "$test_dir/AgentRuntimeSmoke"
"$test_dir/AgentRuntimeSmoke"
