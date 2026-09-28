# Contributing to ScreenSwap

Thanks for helping improve ScreenSwap.

## Before you start

1. Fork the repository and create a focused feature or fix branch.
2. Read the [README](README.md) and the [architecture notes](docs/ARCHITECTURE.md).
3. For implementation work, follow the repository's [agent and architecture
   guidance](AGENTS.md).

## Development workflow

1. Keep each change focused on one behavior or issue.
2. Add or update deterministic tests for behavior changes.
3. Before opening a pull request, run:

   ```bash
   ./build-test.sh
   git diff --check
   ```

   `build-test.sh` is the canonical gate: it configures `Testing.framework`,
   verifies test discovery, builds the package, and runs the complete suite.

4. Open a pull request that explains what changed, why, and how it was tested.
   Include relevant physical Accessibility or multi-display validation when the
   behavior cannot be covered by fakes.

## Accessibility and privacy

ScreenSwap operates on other apps' windows through macOS Accessibility APIs.
Do not add logging that records window titles, document contents, credentials,
or other private desktop information.

## Pull requests

Please keep pull requests small enough to review, describe user-visible
behavior and known limitations, and include relevant automated or manual
validation. Avoid unrelated formatting or refactoring changes.
