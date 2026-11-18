# SPEC-packaging-infra

## Objective

Everything that makes Ursine buildable, testable, releasable and packagable — musl everywhere: `flake.nix` (dynamic musl builds), GitHub CI (per-feature test matrix, clippy/fmt gate, flake check/build, Release artifacts), Docker Alpine local builds, dinit service files. Written last per module but its skeleton lands with the workspace (kept green from day one).

## Tech Stack

- Nix flake: packages the **pinned musl release artifact** (`nix/binary.nix`: URL + sha256) — a `stdenvNoCC` derivation, no compilation. WHY: nixpkgs does not cache `pkgsMusl`/`pkgsStatic` toolchains (stable branches included — verified on nixos-26.05), so a from-source musl build compiles musl+rustc for hours on every run. Binaries are built in the Alpine CI container (same libc, fast) and the flake makes them consumable reproducibly (`nix build github:skea999/ursine#ursine`). The tarball also contains `install.sh` and `packaging/`, and the flake builds the dependency chain `ursine` (GUI) → `ursined` (daemon + packaging) → `ursine-activate` (system tools); `apps.activate`/`apps.deactivate` invoke the versioned tools to install/remove the init unit against a stable profile. CI updates the pin on every `v*` tag; the pinned v0.3.0 tarball predates the scripts, but the flake adds them as a dependency and the next tarball carries them too.
- Binaries: daemon + `ursinectl` are **fully static musl** (pure Rust since the shadow-auth switch, verified by a `readelf -d` NEEDED check in the package job); the GUI is dynamic musl (`libxkbcommon`, no `.a` in Alpine). glibc variants are a v6 concern (two artifacts from the same source).
- **Release checklist**: CI updates `nix/binary.nix` version/url/sha256 on every `v*` tag; manual bump remains the fallback (`sha256sum` of the tarball). The tarball must contain `bin/`, `install.sh` and `packaging/`; CI smoke-tests the installer into a staging root.
- **CI fully containerized (binding)**: every job runs inside a container on GitHub-hosted runners — NO build toolchain installed on the host:
  - cargo jobs: `container: alpine:3.22` (FeralOS target branch) + `apk add rust cargo git nodejs` (`nodejs` required so JS actions like checkout run inside the musl container)
  - flake/release jobs: `container: nixos/nix` (git present / `nix-env -iA nixpkgs.git` if missing) — nix itself runs INSIDE the container
- Local dev mirrors CI exactly: `podman run (or docker) --rm -it -v "$PWD:/work" -w /work rust:alpine …`
- Packaging: APKBUILDs in `skea999/feralos-aports` (out of this repo). The release tarball ships `install.sh` + `packaging/` (systemd/OpenRC/dinit units) so the same installer works on every Linux distribution; package builds stage it with `--destdir` and an explicit `--init`.

## CI workflow (`.github/workflows/ci.yml`)

1. `test` (ONE job — no cargo features exist today; `full` returns when web/oidc land in v3):
   - **Docker**: `alpine:3.22` container
   - `apk add rust cargo git nodejs`
   - gate: `sh scripts/test-gate.sh` — ONE script shared with `scripts/dev.sh check`: single pass (clippy-driver lints + the whole workspace suite, one compilation); `cargo fmt --check` runs in `lint`
2. `version` gate: reads `Cargo.toml`; on a tag it must equal `v<version>`. The expensive `package` job runs only on a release tag (plus a manual `workflow_dispatch` with `force_package`, and PR smoke when build inputs change) — branch pushes never build artifacts. Cargo registry and `artifacts/target` are cached with `actions/cache`.
3. `flake`: **container** `nixos/nix` → `nix flake check` + `nix build --out-link artifacts/result` on push/PR — builds the pinned binary package in seconds (out-link rule: nothing but source files ever appears at repo root)
4. `package` job (alpine rust image) builds release binaries ONLY on a tag (or forced dispatch / PR smoke) — static daemon+CLI (`+crt-static`, asserted by `readelf`) + dynamic GUI — then runs the installer smoke test. Branch pushes skip it entirely: artifacts are never built or staged without a tag.
5. `publish` runs ONLY on tags (`!cancelled()` so it survives the check jobs being skipped there): verifies the published checksum, updates `nix/binary.nix` on main, and attaches `ursine-flake-<tag>.tar.gz` (`flake.nix`, `flake.lock`, `nix/`, `README.md`). The check jobs (`test`/`lint`/`analyzer`/`docs`/`zizmor`) are skipped on tags — they already ran on the push of the same commit. Flake consumption: `github:skea999/ursine` (pinned via `nix/binary.nix`).
6. `verify-pin` re-runs `nix flake check` against main after a tag release, proving the auto-updated pin resolves.
7. NO job installs rustup/cargo/nix on the host runner; actions that need node work because containers provide `nodejs` (alpine) or ship it (nix image)

## Commands

```text
# local (dev machine, no toolchain needed)
docker run --rm -it -v "$PWD:/work" -w /work rust:alpine sh scripts/test-gate.sh
docker run --rm -it -v "$PWD:/work" -w /work rust:alpine cargo build -p ursined

# nix
nix build --out-link artifacts/result .#ursine   # both binaries, dynamic musl; symlink in artifacts/
nix flake check

# release tarball installer (staging; no host changes)
./install.sh --destdir "$PWD/artifacts/install-root" --prefix /usr \
  --init systemd --no-start
./install.sh --check
```

## Project Structure

```text
flake.nix                  package chain: ursine -> ursined -> ursine-activate
flake.lock
.github/workflows/ci.yml   verify (build/tests/static/docs/release) + nix packaging
.cargo/config.toml         target-dir = "artifacts/target" + musl dynamic default (release statics opt in via target rustflags)
ci/Containerfile           the ONE CI/dev image: Rust toolchain, GUI deps, analysers, jscpd, markdownlint
src/tools/ursine-activate.sh Nix profile activation: init detection, root-owned daemon copy, unit render, restart
src/tools/ursine-deactivate.sh Nix profile deactivation: stop/disable, remove unit files
scripts/clean-artifacts.sh keep LAST 3 nix out-links + nix-collect-garbage (-d); --all = + cargo clean
install.sh                 cross-distro installer: paths, systemd/OpenRC/dinit
packaging/
├─ systemd/ursined.service
├─ openrc/ursined
└─ dinit/                 ursined service + wrapper + /etc/dinit.d/config template
.dockerignore              artifacts/, target/
docs/guides/getting-started.md  local build instructions
docs/guides/installation.md     release install, paths and packaging staging
```

**Retention policy (local disk):** keep only the LAST 3 build copies. Every
`nix build --out-link artifacts/result*` registers a GC root; deleting old
links unroots those store paths and `nix-collect-garbage -d` reclaims them.
Run `scripts/clean-artifacts.sh` after builds or whenever disk is tight
(`--all` also cleans `artifacts/target`).

## Code Style

- Workflow YAML: one job per concern, `fail-fast: false`, concurrency cancel on branch
- flake.nix: `stdenvNoCC` package over the pinned release artifact; outputs: `packages.x86_64-linux.ursine`, default package; `devShells` NOT promised (Docker is the dev env; published-release acceptance on the host runs only through `scripts/test-host.sh`, which installs the GitHub flake and never reads the repository — see AGENTS.md host isolation)

## Testing Strategy

- CI IS the test infra: green matrix = merge gate
- flake: `nix flake check` must pass locally before tag
- Release artifacts smoke-tested by extracting tarball in an Alpine container, staging systemd/OpenRC/dinit, root-owned daemon copies, automatic PID-1 init detection, stale-unit cleanup, and running the staged `ursined --version` to require `auth: shadow`

## Boundaries

- Always: keep CI green on every push (skeleton lands with workspace); musl targets only
- Ask first: adding CI providers beyond GitHub Actions; changing flake inputs; adding a third build target (aarch64?)
- Never: glibc builds or artifacts; publishing binaries without the Release smoke test; secrets in workflow files

## Success Criteria

- Push → green CI: every job ran inside a container (alpine for cargo, nixos/nix for flake), the single test gate on musl + flake check/build
- Tag → GitHub Release with musl binaries (static daemon+CLI, verified) + installer + init assets; installer staging smoke test passes
- A dev machine with only Docker can build and test everything
- `sudo ./install.sh` on systemd, OpenRC and dinit installs the unit and starts `ursined`
- `nix build github:skea999/ursine#ursine` works on any nix-enabled musl host

## Open Questions

- aarch64 musl target needed in v1? (FeralOS is x86_64-only today — default: no)
- Cachix binary cache for the flake (faster local nix builds): skip v1?
