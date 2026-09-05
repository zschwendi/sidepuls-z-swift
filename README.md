# SidePulse Z

[![Build](https://github.com/zschwendi/sidepuls-z-swift/actions/workflows/build.yml/badge.svg)](https://github.com/zschwendi/sidepuls-z-swift/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-7c3aed.svg)](LICENSE)

SidePulse Z is a native macOS app for seeing what your AI coding agents are doing. It was made for [SidePulse](https://sidepulse.io) products, so agent states can appear on the lights beside your screen. You do not need the hardware: the menu bar and Agent Hub work on their own. It runs locally and does not require a SidePulse account. SidePulse Z is an independent community project, not an official InteliWEAR app.

![SidePulse Z Command Center](docs/images/command-center.jpg)

## Features

- Tracks Codex sessions and experimental Grok Bot activity without a Python runtime.
- Accepts existing SidePulse hook events, so Python-installed integrations still work when present.
- Simple mode shows one prioritized signal; Per Agent mode gives each active agent its own LEDs.
- Uses magenta for working, yellow for approval, green for finished, and red for failed.
- Keeps the physical lights, live array, and animated menu-bar icon in sync.
- Opens an agent directly from the menu bar or Agent Hub.
- Includes custom colors, animations, brightness, SidePulse Pro RGB color balance, battery indicators, profiles, and Focus automation.
- Adds a full-brightness white flashlight that can override lighting or sit behind agent animations.
- Puts ON AIR, Coffee, Timer, and optional SidePulse Notch controls beside Flashlight in the main toolbar and menu-bar popover.
- ON AIR overlays microphone activity on agent lighting, with hardware-mute status when the device exposes it. It observes activity without recording audio. App-specific software mute is not a reliable system signal.
- Expands the notch on hover into an island with the driving agents, Command Center, Coffee and power controls. Its height follows the agent list and its collapsed width follows the actual display notch.
- Keeps Pro color-balance correction on the hardware; app, menu-bar and notch colors use the original saved colors.
- Includes a customizable countdown with pause/resume, a warning color, and a finished signal. Its countdown stays visible while running and catches up after system sleep.
- Adds Progress in Lighting Studio: run a command or watch an existing process, with customizable running, finished, and failed signals.
- Drives SidePulse Pro and SidePulse Dot as standalone outputs; neither device requires the other.
- Keeps SidePulse Pro mounted through software eject attempts after lock or hibernate.
- Lets each SidePulse use this Mac, one nearby Mac, or all discovered Macs over Bonjour.
- Filters internal child-agent noise while keeping top-level sessions accessible.

## Build and run

SidePulse Z requires macOS 26.5 or later and Xcode 26.6 or later.

```sh
git clone https://github.com/zschwendi/sidepuls-z-swift.git
cd sidepuls-z-swift
open sidepuls-z-swift.xcodeproj
```

Select the `sidepuls-z-swift` scheme, choose your Apple development team if Xcode asks, and press Run. SidePulse Pro and SidePulse Dot work independently, and hardware is optional.

Run the smoke tests with:

```sh
./scripts/test.sh
```

The repository currently ships as source rather than a notarized macOS download.

## Utility modes

Open **Settings → Modes** to customize ON AIR and timer colors, colorways,
motion, intensity, and speed. The notch has its own brightness control and is
disabled by default; its colors mirror the selected lighting. Selecting a mode
uses it for the LEDs without changing your agent profiles. **Agent lighting**
returns to your existing setup. Timers keep counting if you select another mode.

ON AIR shows an orange inward pulse while a microphone is active and returns
to the current agent signal immediately when input stops. Microphone, hardware
mute, recording and screenshot styles are independently editable. Recording
detection currently covers Apple's Screenshot app and requires Accessibility
access, enabled from the ON AIR settings. Saved screenshots use Spotlight's
screen-capture metadata; indexing can delay the white sweep and clipboard-only
captures are not reported. SidePulse does not read image or clipboard contents.

The notch menu-bar settings can hide SidePulse's menu-bar icon while the notch
is visible, with an exception for fullscreen apps and an auto-hidden menu bar.
Clicking the icon in fullscreen opens and brings you to Command Center.

Coffee holds a native idle-sleep assertion while SidePulse runs. On Apple Silicon,
its earlier private clamshell mask proved insufficient: macOS could enter
Clamshell Sleep while the app reported protection. Closed-lid protection now
uses an administrator-authorized companion and the same `pmset disablesleep`
setting used by Amphetamine Power Protect. Enable it in **Settings → Modes →
Coffee**; authentication is needed once per SidePulse launch. Turning Coffee
off and back on reuses that companion. No launch daemon or sudoers rule is
installed. The display can still turn off while the Mac continues working.

The app reports lid protection only after reading `SleepDisabled` back from
macOS. A pre-existing sleep block is preserved without taking ownership. If
that block ends while Coffee is active, SidePulse takes over. The companion
restores its own change when Coffee turns off or the app's connection closes,
including after a main-app crash, and verifies restoration. The setting is
system-wide and persistent; other apps writing the same value cannot be
independently tracked. Avoid running concurrent closed-lid sessions in multiple
utilities. A killed/crashed companion cannot guarantee cleanup; if normal
sleep remains blocked after quitting SidePulse, restore it with
`sudo pmset -a disablesleep 0`. Physical lid-close and power-transition testing
is required on the running Mac; a build or successful API call is not proof.

Open **Lighting Studio → Progress** to run a command in a chosen folder or watch
a process by its PID. Running a command records its exit status. Watching an
existing process only observes when it exits, so its success or failure is
unknown. Stopping that watcher does not stop the watched process.

Tasks with no reported percentage show an ongoing animation. A command can
report real percentage updates by printing whole-number lines to standard output:

```text
SIDEPULSE_PROGRESS=25
SIDEPULSE_PROGRESS=100
```

The finished or failed signal remains until cleared. **Open Log** opens the
bounded local output log for a command. Progress only runs commands explicitly
started with **Run & Watch**; app launch never reruns a saved command.
Quitting SidePulse cancels commands it started. Processes you only watch are
left running.

## Project links

- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [MIT License](LICENSE)
- [Upstream attribution](NOTICE)

SidePulse hardware, its LED format, and the original SidePulse software were created by [Peter Kuhar / InteliWEAR](https://github.com/inteliwear/sidepulse).
