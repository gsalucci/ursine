# Build and test (canonical)

Every build, test and static check runs inside the project container. The host
is never used for compilation or tooling. This is the only supported workflow:
CI and local runs use the same image and the same scripts.

## 1. One-time image build

```bash
podman build -t ursine-ci:1 -f ci/Containerfile .
```

ONE Alpine 3.24/musl image carries everything: Rust 1.99.1 via the apk
`rustup` package (pinned by `rust-toolchain.toml`), clippy, rustfmt, the GUI
build dependencies, the analysers and the pinned npm tools (jscpd,
markdownlint-cli2). Ursine is not a container app: this image only produces
and verifies the binaries.

The only other container is `nixos/nix`, used by the Nix job (lint, flake
evaluation and release pinning). It never builds or tests the app.

## 2. Standard checks

Canonical shortcut (same image and commands as CI):

```bash
scripts/dev.sh check        # fmt + FULL test gate
scripts/dev.sh test         # the same gate without fmt
scripts/dev.sh static all   # fmt + tests + rustdoc + analyzers + duplicates
scripts/dev.sh docs         # Markdown
scripts/dev.sh verify       # EXACT CI push/PR sequence (see below)
```

**Test gate** (`scripts/test-gate.sh`): the single source of truth used by
`dev.sh check/test`, the `rust` static group and CI. SINGLE pass:
clippy-driver lints (workspace `[lints]` + `-D warnings`) ride the compilation
that builds the whole workspace suite — unit, integration and functional
tests. No cargo features exist today.

**Full verification** (`scripts/verify.sh`, `dev.sh verify`): the exact
sequence CI runs on push/PR — `static-check.sh all`, `docs-check.sh`, then
`package-release.sh --check` (release binaries, static-link contract, tarball,
installer/activation smoke). The artifact is discarded.

**Time policy** (no scoped gates — every run tests everything):

- **Per edit**: `check`. With a warm `artifacts/target` only the changed
  crates recompile; the suite itself runs in seconds.
- **Before push**: `verify` is the authoritative full gate; CI re-runs it.
- **Before a release**: the same `verify`.

Manual equivalent:

```bash
podman run --rm --network=host -v "$PWD:/work" -w /work \
  -e CARGO_HOME=/work/artifacts/cargo-home \
  -e RUST_MIN_STACK=16777216 \
  ursine-ci:1 sh scripts/verify.sh
```

Every gate result lands in `artifacts/container-dev/<UTC timestamp>/`
(`scripts/run-dir.sh`): reports, packages and smoke trees. One gate run uses
one directory — a parent script exports `URSINE_RUN_DIR`, children reuse it.
Only the newest 10 runs are kept; older ones are deleted when a new run
starts. Build caches stay outside: `artifacts/target`, `artifacts/cargo-home`.

`scripts/test-gate.sh` exports `RUSTC_WORKSPACE_WRAPPER=clippy-driver`,
`CLIPPY_ARGS=-Dwarnings` and `RUST_MIN_STACK=16777216` itself: libtest gives
each test thread 2 MiB by default and the debug-build daemon call stack (the
growing `Action` enum) exceeds it in the inprocess suite.

`--network=host` is required on this host: pasta cannot create the tap device.

## 3. Static analysis

One image, one entry point: `scripts/static-check.sh` (policy and gates:
`docs/STATIC-ANALYSIS.md`).

```bash
scripts/dev.sh static all
```

Groups: `rust` (fmt + `scripts/test-gate.sh` + rustdoc), `repo`, `sast`,
`deps`, `duplicates`, `sbom`, `all`. `all` runs everything; a missing tool or
any finding fails the group. Nix linters are the only rule outside this image
(they run in the Nix job). Every layer is blocking — no report-only rule and
no finding threshold.

## 4. Feature matrix

No cargo features exist today (the `pam` feature died with the shadow-auth
switch). The single test gate covers the whole workspace; when web/oidc land
in v3 the gate regains legs.

## 5. Release builds

`scripts/package-release.sh` is the only way binaries are produced:

```bash
scripts/package-release.sh --check            # build + verify, discard
scripts/package-release.sh --release <name>   # keep <run dir>/release/<name>
```

It builds the static daemon+CLI (`+crt-static`, `readelf`-verified: zero
dynamic deps) and the dynamic GUI in ONE release build, enforces the GUI
runtime-library allowlist, packs the tarball and checksum, and runs
`scripts/smoke-installer.sh` (installer staging + activation/deactivation for
systemd, OpenRC and dinit in `<run dir>/smoke`).

- **Push/PR**: CI runs it via `verify.sh`, then discards the artifact — branch
  pushes never publish.
- **Tag**: CI runs `--release` and publishes the tarball+checksum to the
  GitHub release.
- **Nix** does not compile Rust: `flake.nix` fetches the pinned GitHub release
  tarball from `nix/binary.nix`.

Never publish a local artifact.

## 6. Nix checks

All Nix work runs in `nixos/nix`; never install Nix on the host. Nix stays
fast: it never builds the app and never runs its tests.

PR/main (no build):

```bash
podman run --rm --network=host -v "$PWD:/work" -w /work \
  -e NIX_CONFIG='experimental-features = nix-command flakes' nixos/nix \
  sh -c 'nix run nixpkgs#statix -- check flake.nix &&
         nix run nixpkgs#statix -- check nix &&
         nix run nixpkgs#deadnix -- --fail flake.nix nix &&
         nix run nixpkgs#alejandra -- --check flake.nix nix &&
         nix eval --raw .#packages.x86_64-linux.ursine.version'
```

Tag (after the release exists): the Nix job downloads the published tarball,
runs a fast integrity smoke (sha256, gzip, tar listing, static contract, the
daemon's `--version`), updates `nix/binary.nix` (version/url/sha256), commits
the pin to `main`, evaluates the flake version, and attaches the flake source
tarball+checksum to the release. No `nix build`, no `nix flake check`.

### Host acceptance (release only)

`scripts/test-host.sh` is the single script allowed to run outside a container
(user decision, AGENTS.md host isolation). Run it **after** the tag is
published; it never reads or changes the repository, the package comes from the
published GitHub flake (`github:skea999/ursine`):

1. ensure the registry entry `flake:ursine` exists (add or refresh it);
2. refresh the published flake and read its version (`nix flake metadata`,
   `nix eval --refresh`);
3. install or upgrade the profile package and require the installed `ursined`
   to report that version;
4. run `sudo ursine-activate`;
5. check `auth: shadow`, the live service under the real init and
   `ursinectl system status`.

`scripts/build-gui-dev.sh` and `nix/dev-flake.nix` no longer exist.

## 7. Rules

- No host `cargo`, `rustc`, `nix`, `clippy`, `cargo-deny` or scanner.
  Everything in a container.
- Build output: `artifacts/target` (`.cargo/config.toml`). Never `target/`.
- Gate results: `artifacts/container-dev/<timestamp>/`; caches in
  `artifacts/target` and `artifacts/cargo-home`. Nothing generated is committed.
- Temporary files: `artifacts/<task>/`. Never host `/tmp`.
- `Cargo.lock` committed; every CI cargo command uses `--locked`.
- Do not skip hooks or checks. Fix the finding.

## 8. GitHub Actions pipeline

Two jobs, linear by design:

1. **verify** (one image, one job, exact order):
   - build `ursine-ci` from `ci/Containerfile` once (GHA layer cache);
   - **push/PR**: `scripts/verify.sh` — fmt, single-pass clippy+all tests,
     rustdoc, repo/sast/deps/duplicates/sbom, markdownlint, release build +
     installer smoke; the binary is discarded;
   - **tag**: tests are skipped (the push that produced the commit already ran
     them); only `package-release.sh --release` runs, then the release is
     published.
2. **nix** (`nixos/nix`, never builds or tests):
   - PR/main: statix/deadnix/alejandra + `nix eval` of the package version;
   - tag: download the published tarball, integrity smoke, pin
     `nix/binary.nix` on `main`, `nix eval` the flake version, attach the
     flake source tarball.

Cargo cache: `actions/cache/restore` on the `verify` job; only pushes to
`main` save. Tag/PR refs are restore-only. This keeps zizmor's
cache-poisoning audit clean.

## Image contents

`ci/Containerfile` is based on `alpine:3.24`. It installs from apk:

- build: `build-base`, `openssl-dev`, `pkgconf`, `cmake`, `fontconfig-dev`,
  `freetype-dev`, `libxkbcommon-dev`, `expat-dev`, `rustup`;
- analysis: `cargo-deny`, `cargo-audit`, `cargo-cyclonedx`, `typos`, `taplo`,
  `zizmor`, `actionlint`, `shellcheck`, `shfmt`, `editorconfig-checker`;
- edge/testing: `cargo-geiger`, `cargo-machete`, `gitleaks`;
- npm (pinned): `jscpd@4.3.0`, `markdownlint-cli2@0.24.0`.

## Documentation checks

Docs are not baked into any image; the repo is mounted at runtime.

```bash
podman run --rm --network=host -v "$PWD:/work" -w /work \
  ursine-ci:1 sh scripts/docs-check.sh
```

CI runs the same image and script inside `verify.sh`.
