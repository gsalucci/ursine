#!/bin/sh
# Canonical test gate — single source of truth for scripts/dev.sh check AND
# the CI test/gui jobs (.github/workflows/ci.yml). Local and push run the
# exact same commands: no test may exist in one place only.
#
# Every leg is a SINGLE pass: clippy-driver compiles with the workspace
# [lints] + CLIPPY_ARGS while building the tests, then runs them — no
# separate clippy build anywhere.
#
#   scripts/test-gate.sh default   # stub auth (no pam), workspace minus GUI
#   scripts/test-gate.sh pam       # real PAM, workspace minus GUI
#   scripts/test-gate.sh gui       # libcosmic GUI crate only
#   scripts/test-gate.sh default pam   # any combination of legs
#   scripts/test-gate.sh all       # all three legs (what dev.sh check runs)
set -eu

# clippy-driver takes CLIPPY_ARGS as ONE argv: "-Dwarnings" (no space —
# "-D warnings" reaches rustc as the unknown lint " warnings" and denies
# nothing). RUST_MIN_STACK: libtest gives each test thread 2 MiB; the
# debug inprocess daemon stack (growing Action enum) needs 16 MiB.
export RUSTC_WORKSPACE_WRAPPER=clippy-driver
export CLIPPY_ARGS=-Dwarnings
export RUST_MIN_STACK=16777216

run_leg() {
  case "$1" in
  default)
    cargo test --workspace --exclude ursine --no-default-features --all-targets --locked
    ;;
  pam)
    cargo test --workspace --exclude ursine --features pam --all-targets --locked
    ;;
  gui)
    cargo test -p ursine --all-targets --locked
    ;;
  all)
    run_leg default
    run_leg pam
    run_leg gui
    ;;
  *)
    echo "usage: scripts/test-gate.sh {default|pam|gui|all}..." >&2
    exit 2
    ;;
  esac
}

if [ "$#" -eq 0 ]; then
  set -- all
fi
for leg in "$@"; do
  run_leg "$leg"
done
