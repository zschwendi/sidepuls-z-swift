# Security Policy

## Supported version

Security fixes target the latest commit on `main`. There is not yet a separately supported binary-release channel.

## Report a vulnerability

Please use GitHub's private vulnerability reporting for this repository. Do not open a public issue containing exploit details, credentials, private agent content, or sensitive local paths.

Include:

- the affected commit or build
- the macOS and Xcode versions
- whether physical SidePulse hardware was connected
- the smallest safe reproduction
- the expected impact

## Local data and permissions

SidePulse Z reads local agent metadata and writes to mounted SidePulse volumes. It is not sandboxed so it can discover those sources and hardware paths. Reports involving agent transcripts, Codex IPC, Grok Bot persistence, login-item behavior, or removable-volume writes are especially useful.

## Nearby Mac mirroring (experimental)

Nearby Mac mirroring is opt-in and defaults to **Off**. The four modes are **Off**, **Share This Mac**, **Follow Nearby Mac**, and **All Macs**. Modes that publish or browse require macOS Local Network permission and use Bonjour service `_sidepulse-z._tcp`; peers are expected to be on the same trusted local LAN.

The signal payload is limited to protocol metadata, coarse aggregate state, timing, and Pro/Dot compiled LED programs. It does not include agent names, messages, projects, paths, or LED slots. Bonjour discovery does expose a Mac display name and per-instance node identifier for peer selection. Authentication and pairing are not implemented yet, so do not use this mode on an untrusted, shared, or guest network.

Remote frames older than 3.5 seconds stop driving **Follow Nearby Mac**. **All Macs** ignores stale remote frames and falls back to another fresh signal, including a fresh local signal when available. Include the selected mode, local-network permission state, network topology, and whether the issue affects local or remote output in security reports.
