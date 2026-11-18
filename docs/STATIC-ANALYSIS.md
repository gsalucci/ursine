# Static analysis policy

Binding. Every rule below runs in CI and locally through
`scripts/static-check.sh` (single image `ursine-ci:1`). A finding is not
waived without an entry in `docs/static-analysis-exceptions.md` with owner,
reason and expiry (max 90 days). No rule is report-only and no rule has a
finding threshold that lets findings pass: zero findings, or the gate fails.

## Layers and gates

| Layer | Tool | Gate |
|---|---|---|
| Formatting | `cargo fmt --check` | blocking |
| Rust lints | workspace `[lints]` + strict clippy | blocking, `-D warnings` |
| Tests | `scripts/test-gate.sh` (single-pass clippy + full workspace suite) | blocking |
| Docs | `cargo doc` with `RUSTDOCFLAGS=-D warnings` | blocking |
| Repo lint | `typos`, `editorconfig-checker` | blocking |
| Scripts | `shellcheck`, `shfmt` | blocking |
| Nix | `statix`, `deadnix`, `alejandra --check` | blocking (Nix job) |
| TOML | `taplo` | blocking |
| Markdown | `markdownlint-cli2` | blocking |
| GitHub Actions | `actionlint`, `zizmor` | blocking |
| Code security | clippy strict + `gitleaks` + `cargo-geiger` | blocking |
| Secrets | `gitleaks` full history | blocking |
| Unsafe | `unsafe_code = forbid`; `cargo-geiger` | blocking |
| Advisories | `cargo deny check advisories` + `cargo audit` | blocking, zero unignored findings |
| Licenses | `cargo-deny licenses` | blocking |
| Sources/bans | `cargo-deny sources`, `bans` | blocking |
| Unused deps | `cargo-machete` | blocking |
| SBOM | `cargo-cyclonedx` | artifact per release |
| Source clones | `jscpd --min-tokens 50` (Rust + shell) | blocking, threshold 0 |
| Duplicate crates | `cargo tree -d` report in the run directory | report (upstream-owned) |

## No overlapping tests

Every check runs exactly once per gate. CI must not execute the same test in
two jobs or two steps, and the release build is not a second test run: a push
either tests or packages, and a tag only packages the commit the push already
tested. Overlap is fixed by deleting the redundant execution; a test is never
deleted to save time. Removing a test is allowed only when it is a true
duplicate — same assertion on the same surface — and the surviving test keeps
the full coverage.

## Rust lint policy

Workspace lints are versioned in `Cargo.toml`; every crate opts in with
`[lints] workspace = true`. `unsafe_code` is forbidden in Ursine crates.
Clippy runs `all`, `pedantic`, `nursery`, `cargo` and a curated restriction
set (`unwrap_used`, `expect_used`, `panic`, `todo`, `unimplemented`, `dbg_macro`,
`print_stdout`, `print_stderr`, `exit`, `mem_forget`, `undocumented_unsafe_blocks`).

Exceptions live in `clippy.toml` (tests may use `unwrap`/`expect`) or in a
local `#[allow(...)]` with a `// reason:` comment. No blanket crate-level
allows without an exception entry.

## Dependency policy

- `Cargo.lock` committed; `--locked` everywhere.
- crates.io only, plus the pinned `github.com/pop-os` git dependencies.
- No wildcard versions, no unknown registries.
- Licenses allowlisted in `deny.toml`.
- GitHub Actions pinned by full commit SHA; `zizmor` enforces it.

## Duplicates

`scripts/duplicates-gate.sh` covers both surfaces:

1. **Our source — blocking.** `jscpd` with `.jscpd.json`: `minTokens` 50,
   formats `rust` and `shell`, `threshold` 0. Any clone fails the gate.
   Refactor the code; never raise the threshold.
2. **Dependency graph — report.** `cargo tree -d` is written to
   `artifacts/container-dev/<timestamp>/duplicates/dependency-duplicates.txt`
   and its count is printed. Every duplicate version comes from the pinned
   libcosmic/iced graph (`png` 0.17 + 0.18, `xkbcommon` 0.7 + 0.8, …) and
   cannot be aligned without an upstream release. A committed baseline is not
   an option: it would be generated state in the repository and it would
   legitimise versions we cannot remove.

## Tool pinning

Tool versions are pinned in `ci/Containerfile` (cargo tools, linters, jscpd,
markdownlint-cli2) and in `ci.yml` (Nix image digest and GitHub Actions SHAs).
Upgrade them in a dedicated PR monthly, never silently. The Rust toolchain is
pinned in `rust-toolchain.toml`; CI and local images must match it.

## Container policy

Ursine is not containerized and ships no container image. Container scanning
therefore does not apply. Build/test isolation still uses the single Alpine
container; the Nix packaging job uses `nixos/nix`. Those images are tooling,
not deliverables.

## Advisories

Zero tolerance: `cargo deny check advisories` AND `cargo audit --deny warnings`
must report no unignored finding. Vulnerability, yanked, unsound and
unmaintained advisories all fail the gate. Two implementations over the same
RustSec database: `cargo deny` reads its ignores from `deny.toml` (the single
source of truth, target-filtered on the musl graph); `cargo audit` is not
target-aware, so `scripts/static-check.sh` derives the same ignore flags from
`deny.toml` and adds only the two Windows-only crates the musl build never
compiles (`paste`, `pin-utils`). The allowed ignores name the upstream-pinned
COSMIC/iced dependencies with an owner and expiry in
`docs/static-analysis-exceptions.md`. Any new advisory fails CI; there is no
count threshold.
