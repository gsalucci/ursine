# ADR 0001 — Maximum-severity, fully blocking test gates

- **Status**: Accepted
- **Date**: 2026-11-18
- **Owner**: skea999
- **Supersedes**: the warn-1-to-9 advisory threshold, the report-only
  duplicate detection, and the three-image CI split.

## Context

Ursine is a root-capable control center for FeralOS: it can change packages,
users, storage, services, the firewall and the boot chain. A defect is a
security incident, not a cosmetic bug. The earlier policy allowed findings to
pass (advisory threshold of 10, duplicates report-only, checks split across
three images and several jobs), so a regression could reach `main` while the
pipeline stayed green.

## Decision

Every test that can be run on the code is **binding** and calibrated to the
**strictest available setting**. Any finding blocks commit, push and tag.

- **No report-only mode, no finding threshold.** A gate is either blocking or
  it does not exist.
- **Full layers**: fmt; single-pass clippy `-D warnings` + the whole workspace
  suite (unit, integration, functional); rustdoc `-D warnings`; repo linters
  (typos, editorconfig, shellcheck, shfmt, taplo, actionlint, zizmor); SAST
  (gitleaks full history, cargo-geiger); deps (`cargo deny` advisories,
  licenses, bans, sources; cargo-machete); SBOM; markdownlint.
- **Advisories are zero-tolerance.** Vulnerability, yanked, unsound and
  unmaintained findings all fail. Ignore entries exist only for the pinned
  upstream COSMIC/iced graph, with owner and expiry in
  `docs/static-analysis-exceptions.md`.
- **Duplicate source blocks.** `jscpd` at `minTokens 50` over Rust and shell
  with `threshold 0`: clones are refactored, never exempted by raising the
  threshold. Dependency duplicates (`cargo tree -d`) are reported into the run
  directory, never tolerated by a committed list — a baseline file would be
  generated state and would legitimise what we do not want. Every remaining
  entry comes from the pinned libcosmic/iced graph and cannot be aligned
  without an upstream release.
- **A missing tool fails the group.** Silent skips are forbidden.
- **No overlapping tests.** Each check executes exactly once per gate: CI has no
  two jobs or two steps that test the same surface, and the release build is
  never a second test run. Fix overlap by deleting the redundant *execution*,
  never a test: a test is removed only when it is a true duplicate (same
  assertion on the same surface), never because it costs wall-clock time.
- **If a new test becomes possible, it must be added.** New linters, new
  analysers, new Rust checks: they enter the gate at maximum severity, not as
  a warning.
- **One image, two jobs.** A single Alpine image (`ci/Containerfile`) runs
  build, tests, static analysis and docs; `nixos/nix` only lints/evaluates and
  packages the pinned release. Push/PR runs everything and discards the
  binary; a tag skips the tests (already run on the push) and only builds and
  publishes the release.

## Consequences

- Refactoring cost is paid immediately (clone gate, duplicate ratchet) instead
  of accumulating.
- The upstream COSMIC/iced pins produce documented, expiring exceptions; they
  are reviewed monthly and cannot grow silently.
- CI is linear and slower wall-clock than the old parallel jobs, by design:
  one image, one order, no duplicated or skipped checks.
- Local work uses the same image and the same scripts (`scripts/verify.sh`),
  so CI cannot drift from the local gate.
