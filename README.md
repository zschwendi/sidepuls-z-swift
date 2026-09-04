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
- Includes custom colors, animations, brightness, battery indicators, profiles, and Focus automation.
- Adds a full-brightness, color-balanced white flashlight that can override lighting or sit behind agent animations.
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

## Project

- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [MIT License](LICENSE)
- [Upstream attribution](NOTICE)

SidePulse hardware, its LED format, and the original SidePulse software were created by [Peter Kuhar / InteliWEAR](https://github.com/inteliwear/sidepulse).
