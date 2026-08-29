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
