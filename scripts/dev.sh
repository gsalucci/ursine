#!/bin/sh
# One entry point for local build/test/static/docs. Uses the same images and
# commands as CI.
#
#   scripts/dev.sh image          build ursine-ci
#   scripts/dev.sh build          cargo build (all features)
#   scripts/dev.sh test           full test gate (same legs as CI)
#   scripts/dev.sh fmt            cargo fmt --check
#   scripts/dev.sh check          fmt + full test gate (identical to CI)
#   scripts/dev.sh fast           fmt + test gate scoped to the change
#                                 + pure lints (seconds, no analyzers)
#   scripts/dev.sh static [group] static analysis (default: all)
#   scripts/dev.sh docs           markdownlint
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"
RUNTIME=${CONTAINER_RUNTIME:-podman}
CI_IMAGE=${URSINE_CI_IMAGE:-ursine-ci:1}
STATIC_IMAGE=${URSINE_STATIC_IMAGE:-ursine-static:1}
DOCS_IMAGE=${URSINE_DOCS_IMAGE:-ursine-docs:1}
CARGO_HOME_DIR=${CARGO_HOME:-/work/artifacts/cargo-home}

run_ci() {
  # RUST_MIN_STACK: libtest gives each test thread 2 MiB; the debug
  # inprocess daemon stack (growing Action enum) needs 16 MiB.
  "$RUNTIME" run --rm --network=host -v "$ROOT:/work" -w /work \
    -e "CARGO_HOME=$CARGO_HOME_DIR" -e RUST_MIN_STACK=16777216 "$CI_IMAGE" "$@"
}

run_static() {
  "$RUNTIME" run --rm --network=host -v "$ROOT:/work" -w /work \
    -e "CARGO_HOME=$CARGO_HOME_DIR" "$STATIC_IMAGE" "$@"
}

run_docs() {
  "$RUNTIME" run --rm --network=host -v "$ROOT:/work" -w /work \
    "$DOCS_IMAGE" "$@"
}

cmd=${1:-check}
shift || true

case "$cmd" in
image)
  "$RUNTIME" build -t "$CI_IMAGE" -f ci/Containerfile.dev .
  "$RUNTIME" build -t "$STATIC_IMAGE" -f ci/Containerfile.static .
  "$RUNTIME" build -t "$DOCS_IMAGE" -f ci/Containerfile.docs .
  ;;
build)
  run_ci cargo build --workspace --all-features --locked
  ;;
test)
  # Full gate without fmt: same legs as CI (stub + pam + gui).
  run_ci sh scripts/test-gate.sh all
  ;;
fmt)
  run_ci cargo fmt --check
  ;;
check)
  # Identical to the CI test/gui jobs: scripts/test-gate.sh is the one
  # source of truth (stub + pam + gui legs, single pass each).
  run_ci sh -c 'cargo fmt --check && sh scripts/test-gate.sh all'
  ;;
fast)
  # Iteration gate (the one to use while editing): fmt always, then
  # the test gate SCOPED to what changed (a GUI-only edit must not
  # rebuild the daemon), then the pure lints. CI runs the full matrix;
  # use `check` and `static all` before a release.
  run_ci cargo fmt --check
  changed=$( (
    git diff --name-only HEAD
    git ls-files --others --exclude-standard
  ) | sort -u)
  if printf '%s\n' "$changed" | grep -qE '^(Cargo\.(toml|lock)|rust-toolchain)'; then
    scope="all"
  elif printf '%s\n' "$changed" | grep -qE '^(src/ursine-api/|src/ursine-core/|src/ursined/|src/ursinectl/)'; then
    scope="default pam"
  elif printf '%s\n' "$changed" | grep -q '^src/ursine/'; then
    scope="gui"
  else
    scope=""
  fi
  if [ -n "$scope" ]; then
    # shellcheck disable=SC2086 # scope is a deliberate word list of gate legs
    run_ci sh scripts/test-gate.sh $scope
  fi
  run_static sh scripts/static-check.sh repo
  run_docs sh scripts/docs-check.sh
  ;;
static)
  run_static sh scripts/static-check.sh "${1:-all}"
  ;;
docs)
  run_docs sh scripts/docs-check.sh
  ;;
*)
  echo "usage: scripts/dev.sh {image|build|test|fmt|check|fast|static [group]|docs}" >&2
  exit 2
  ;;
esac
