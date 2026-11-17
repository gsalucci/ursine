# Build and test (canonical)

Every build, test and static check runs inside the project container. The host
is never used for compilation or tooling. This is the only supported workflow:
CI and local runs use the same commands and the same environment.

## 1. One-time image build

```bash
podman build -t ursine-ci:1 -f ci/Containerfile.dev .
```

The image is Alpine 3.24/musl, matching FeralOS and the static/docs tooling
images. It installs system libraries from apk and Rust 1.99.1 via the apk
`rustup` package (pinned by `rust-toolchain.toml`); it includes clippy,
rustfmt, PAM headers and the GUI build dependencies.

## 2. Standard checks

Canonical shortcut (same images and commands as CI):

```bash
scripts/dev.sh fast         # WHILE EDITING: fmt + clippy/test scoped to
                            # the changed crates + pure lints (typos, ec,
                            # shellcheck, taplo, actionlint, zizmor,
                            # gitleaks) + markdown — no rust recompilation
scripts/dev.sh check        # fmt + single-pass test (clippy lints ride
                            # the same compilation, full workspace)
scripts/dev.sh static all   # analyzers (CI runs these too)
scripts/dev.sh docs         # Markdown
```

**Time policy** (tests are never dropped — they are staged):

- **Per edit**: `fast`. A `src/ursine/**`-only change compiles and
  tests just the `ursine` crate (not the workspace twice); an
  `api`/`core`/`Cargo.*` change falls back to the full workspace.
  The pure lints never compile anything, so they cost seconds.
- **Before push**: CI is the authoritative full gate (test matrix,
  clippy, rustdoc, analyzer groups) — run `check` locally if you
  want assurance before pushing, but CI re-runs everything anyway.
- **Before a release**: `static all` locally once (it duplicates the
  CI analyzer on purpose as the last line of defense).

Manual equivalents, if you need one command:

```bash
podman run --rm --network=host -v "$PWD:/work" -w /work \
  -e CARGO_HOME=/work/artifacts/cargo-home ursine-ci:1 \
  sh -c 'cargo fmt --check'

# Single pass: clippy-driver lints (workspace [lints] + -D warnings)
# during the ONE compilation that also builds the tests.
podman run --rm --network=host -v "$PWD:/work" -w /work \
  -e CARGO_HOME=/work/artifacts/cargo-home \
  -e RUST_MIN_STACK=16777216 \
  -e RUSTC_WORKSPACE_WRAPPER=clippy-driver \
  -e CLIPPY_ARGS="-Dwarnings" \
  ursine-ci:1 \
  sh -c 'cargo test --workspace --all-features --locked'
```

Test commands export `RUST_MIN_STACK=16777216`: libtest gives each test
thread 2 MiB by default and the debug-build daemon call stack (the
growing `Action` enum) exceeds it in the inprocess suite (stack
overflow). The CI test/gui jobs set the same variable.

`--network=host` is required on this host: pasta cannot create the tap device.

## 3. Static analysis

Analyzers live in `ci/Containerfile.static`; Rust lints use `ursine-ci:1`.
Build both:

```bash
scripts/dev.sh image
```

Run everything (analyzers only; Rust lints run in `ursine-ci`):

```bash
scripts/dev.sh static all
```

Groups: `repo`, `sast`, `deps`, `duplicates`, `sbom`, `all`. The `rust` group
is available only in `ursine-ci:1` (`scripts/dev.sh check`).

Policy and gates: `docs/STATIC-ANALYSIS.md`.

## 4. Feature matrix

```bash
# default (stub auth)
... cargo test --workspace --no-default-features

# real PAM build
... cargo test --workspace --features pam

# everything
... cargo test --workspace --all-features
```

## 5. Release builds

Release tarballs are built only by GitHub Actions (`package` job, Alpine/musl).
Local builds are debug/test builds; never publish a local artifact. Nix does
not compile Rust: `flake.nix` fetches the pinned GitHub release tarball from
`nix/binary.nix`.

## 6. Nix checks

All Nix work runs in `nixos/nix`; never install Nix on the host.

```bash
podman run --rm --network=host -v "$PWD:/work" -w /work nixos/nix \
  sh -c 'nix --extra-experimental-features "nix-command flakes" flake check'
podman run --rm --network=host -v "$PWD:/work" -w /work nixos/nix \
  sh -c 'nix --extra-experimental-features "nix-command flakes" build --out-link /work/artifacts/result'
```

## 7. Rules

- No host `cargo`, `rustc`, `nix`, `clippy`, `cargo-deny` or
  scanner. Everything in a container.
- Build output: `artifacts/target` (`.cargo/config.toml`). Never `target/`.
- Temporary files: `artifacts/<task>/`. Never host `/tmp`.
- `Cargo.lock` is committed; every CI cargo command uses `--locked`.
- Do not skip hooks or checks. Fix the finding.

## 8. GitHub Actions pipeline

`ci.yml` is ordered for wall-clock time, not for duplicating builds:

1. **image** builds the Alpine musl dev image once and pushes
   `ursine-ci:main` (or uses the GHA layer cache). Test/lint/gui/package pull
   that image.
2. **test (default)** and **test (pam)** run a SINGLE pass:
   `RUSTC_WORKSPACE_WRAPPER=clippy-driver CLIPPY_ARGS="-Dwarnings"
   cargo test …` — clippy lints (workspace `[lints]`, `-D warnings`)
   and the whole suite come out of one compilation. The GUI is excluded
   here because it has its own job. Jobs are skipped on tags.
3. **lint** runs `cargo fmt --check` and rustdoc with `-D warnings` only —
   clippy rides the test jobs (single pass), so there is no second clippy
   build anywhere in the pipeline. Skipped on tags.
4. **gui** runs the same single pass for `-p ursine`
   (`clippy-driver` wrapper + `cargo test -p ursine --all-targets --locked`);
   no separate `cargo build`, no repeated clippy. Skipped on tags.
5. **analyzer**, **docs**, and **zizmor** run in parallel. `analyzer` runs the
   repo/sast/deps/duplicates/sbom groups; `docs` runs markdownlint; `zizmor`
   audits workflow security.
6. **version** resolves the workspace version and whether a package is due.
   **changes** supplies the PR package/nix path filters.
7. **package** runs only on a release tag (or a forced
   `workflow_dispatch` / a PR smoke when build inputs change) — branch
   pushes never build artifacts. On a tag it starts after
   `image`/`version`/`changes` (the check jobs are skipped by then).
   It builds release PAM `ursined` and the GUI, runs the installer
   smoke tests, creates the tarball/checksum, and uploads
   `ursine-release`. This path has no dependency cache on purpose.
8. **publish** runs ONLY on tags. It waits for `package` (and tolerates the
   check jobs being skipped there — `test`/`lint`/`gui`/`analyzer`/`docs`/
   `zizmor` do not re-run on a tag: the push of the same commit already ran
   them). It publishes the versioned tag assets and updates
   `nix/binary.nix` on tags; branch pushes never publish.
9. **flake** runs on PR/main only when `flake.nix`, `flake.lock`, or `nix/**`
   changed. It is not a dependency of `package`, so a tag does not try to
   fetch a not-yet-published artifact.
10. **verify-pin** runs after a tag publish and executes `nix flake check` and
    `nix build` against the new pin on `main`.

Cargo cache policy: test/lint/gui/analyzer use `actions/cache/restore`; only
pushes to `main` save (`actions/cache/save`). Tag/PR refs are restore-only, and the
release package path is never cached. This keeps zizmor's cache-poisoning
audit clean while avoiding repeated dependency compilation on main.

`cargo test` builds the test binaries before running them; a separate
`cargo build` cannot replace that work. Two optimizations stack: the
single pass (`clippy-driver` wrapper) removes the second clippy
compilation, and the release build starts before the tests finish,
with `publish` still blocked on every quality gate.

## Static image contents

`ci/Containerfile.static` is based on `alpine:3.24`. It installs from apk:

- `cargo`, `cargo-deny`, `cargo-audit`, `cargo-cyclonedx`
- `typos`, `taplo`, `zizmor`, `actionlint`, `shellcheck`, `shfmt`, `editorconfig-checker`
- `cargo-geiger`, `cargo-machete`, `gitleaks` (Alpine edge/testing)

The Rust compile/clippy/fmt group runs in `ursine-ci:1`; the static image keeps
only analyzers so its build stays fast.

## Documentation checks

Docs are not baked into any image; the repo is mounted at runtime.

```bash
podman build -t ursine-docs:1 -f ci/Containerfile.docs .

podman run --rm --network=host -v "$PWD:/work" -w /work \
  ursine-docs:1 sh scripts/docs-check.sh
```

CI runs the same image and script in the `docs` job.
