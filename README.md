# ScreenSwap

ScreenSwap is a macOS 14+ menu-bar app that swaps eligible visible windows
between exactly two active displays. It uses public Accessibility and Quartz
APIs, plans the complete swap before the first AX write, and preserves
proportional geometry through `ScreenSwapCore`.

## Purpose

This repository is also an independently implemented benchmark reference. Use
it as:

- an independent behavioral reference
- a code-quality comparison
- a sanity check for the external black-box evaluator

Do **not** treat its ChatGPT task cost as a measured API cost unless separate API telemetry exists.

## Build and test

On macOS:

```bash
./build-test.sh
```

After any app update, install and launch a fresh release build for local
testing:

```bash
Packaging/pack-app.sh --install --replace
```

If no local stable signing identity exists, create one once with
`Packaging/create-local-signing-identity.sh`. Ad-hoc signing is opt-in with
`--allow-ad-hoc` and may require Accessibility approval again. Release packages
must name an explicit Developer ID Application identity.

## Current behavior and limitations

- Swaps all currently visible, eligible standard windows across applications;
  it intentionally does not use a frontmost-app-only policy.
- Minimized, transient, non-movable, spanning, and Quartz-offscreen windows
  are skipped.
- Fixed-size windows keep their captured size and their destination position is
  clamped using that real size.
- If a moved ordinary window remains absent from Quartz’s on-screen list after
  bounded verification, ScreenSwap attempts to restore its captured frame.
- Public APIs cannot reliably transfer arbitrary foreign windows between macOS
  Spaces. Physical two-display validation remains required.

## Black-box validation

The ZIP containing this repo also contains a sibling `_blackbox/` directory.

From the extracted package:

```bash
./_blackbox/run-blackbox.sh ./ScreenSwap-GPT56Reference
```

The packaged reference was verified against the external suite before delivery.

## Public contract

`docs/CORE_PUBLIC_API.md` fixes the public interface only. The external test vectors remain outside this Git repo.
