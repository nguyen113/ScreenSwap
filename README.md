# ScreenSwap — GPT-5.6 Sol Reference

This repository is an independently implemented reference for the first seven atomic MVP core tasks:

- `MVP-CORE-001`
- `MVP-CORE-002`
- `MVP-CORE-003`
- `MVP-CORE-004`
- `MVP-CORE-005`
- `MVP-CORE-006`
- `MVP-CORE-007`

It uses the same starter product models, same `backlog.yml`, and same visible `docs/CORE_PUBLIC_API.md` contract as the CGAW and direct-Claude benchmark arms.

## Purpose

Use this repo as:

- an independent behavioral reference
- a code-quality comparison
- a sanity check for the external black-box evaluator

Do **not** treat its ChatGPT task cost as a measured API cost unless separate API telemetry exists.

## Visible validation

On macOS:

```bash
swift build
swift test
```

Core-only package validation can also be performed through the external evaluator.

## Black-box validation

The ZIP containing this repo also contains a sibling `_blackbox/` directory.

From the extracted package:

```bash
./_blackbox/run-blackbox.sh ./ScreenSwap-GPT56Reference
```

The packaged reference was verified against the external suite before delivery.

## Public contract

`docs/CORE_PUBLIC_API.md` fixes the public interface only. The external test vectors remain outside this Git repo.
