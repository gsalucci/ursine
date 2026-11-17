#!/bin/sh
# The test gate — single source of truth for scripts/dev.sh check AND the
# CI test job (.github/workflows/ci.yml). Local and push run the exact
# same command: no test can exist in one place only.
#
# SINGLE pass: clippy-driver compiles with the workspace [lints] +
# CLIPPY_ARGS while building the tests, then runs them — no separate
# clippy build anywhere.
#
#   scripts/test-gate.sh
set -eu

# clippy-driver takes CLIPPY_ARGS as ONE argv: "-Dwarnings" (no space —
# "-D warnings" reaches rustc as the unknown lint " warnings" and denies
# nothing). RUST_MIN_STACK: libtest gives each test thread 2 MiB; the
# debug inprocess daemon stack (growing Action enum) needs 16 MiB.
export RUSTC_WORKSPACE_WRAPPER=clippy-driver
export CLIPPY_ARGS=-Dwarnings
export RUST_MIN_STACK=16777216

cargo test --workspace --all-targets --locked
