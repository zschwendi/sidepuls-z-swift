# Contributing to SidePulse Z

Thanks for helping make agent status lower-friction and more glanceable.

## Before opening a pull request

1. Open an issue for broad behavior, architecture, hardware, or UX changes.
2. Keep changes focused and preserve unrelated behavior.
3. Run `./scripts/test.sh`.
4. Run the unsigned Release build documented in `README.md`.
5. Describe what you tested on real hardware. If hardware was unavailable, say so explicitly.

## Product contracts

These behaviors are intentional:

- The menu-bar icon, software array, and physical device should render the same LED program. The hardware-only maximum-brightness control must not dim software UI.
- Simple mode prioritizes failure, approval, thinking, and done in that order. Tool use is part of thinking.
- Per Agent mode keeps allocations stable; ordinary activity changes state, not position.
- Completed work stays green until the user acknowledges it.
- A failure means the overall run stopped unsuccessfully, not that one recoverable tool call failed.
- SidePulse Pro is the primary supported hardware target. Treat Dot and multi-device changes as experimental unless real-device evidence proves otherwise.
- Internal maintenance jobs and child-agent implementation details should not leak into Agent Hub.

## Tests

The smoke suite covers profile persistence, animation and allocation geometry, battery scenes, menu-bar mirroring, agent merging, approval state, and session filtering.

```sh
./scripts/test.sh
```

For UI or animation changes, include a short screen recording or screenshots and describe the physical SidePulse result separately. A passing compiler test does not prove the hardware looks right.

## Privacy

Never commit agent transcripts, `latest.json`, JSONL event logs, local paths, credentials, signing material, or screenshots containing private task names. Use synthetic fixtures.

## Licensing

By contributing, you agree that your contribution is licensed under the repository's MIT License. Preserve upstream notices and attribution.
