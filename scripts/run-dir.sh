#!/bin/sh
# One result directory per gate run:
#
#   artifacts/container-dev/<UTC timestamp>/
#
#   sh scripts/run-dir.sh      create it and print the repo-relative path
#   . scripts/run-dir.sh       same, plus URSINE_RUN_DIR exported for children
#
# Every gate result lands in that directory (reports, packages, smoke trees).
# Build caches stay outside it (`artifacts/target`, `artifacts/cargo-home`).
# A parent script exports URSINE_RUN_DIR, so nested gates reuse the directory
# instead of opening a second one. Only the newest 10 runs are kept: older
# ones are deleted when a new run directory is created.

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
RUNS="$ROOT/artifacts/container-dev"

# Names are UTC timestamps, so reverse name order is newest first.
prune_runs() {
  [ -d "$RUNS" ] || return 0
  find "$RUNS" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +11 |
    while IFS= read -r old; do
      rm -rf "$old"
    done
}

if [ -z "${URSINE_RUN_DIR:-}" ]; then
  mkdir -p "$RUNS"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  run="$RUNS/$stamp"
  n=1
  while [ -e "$run" ]; do
    run="$RUNS/$stamp-$n"
    n=$((n + 1))
  done
  mkdir -p "$run"
  URSINE_RUN_DIR=$run
  export URSINE_RUN_DIR
  # Retention: the run just created counts as one of the newest 10.
  prune_runs
fi

# Repo-relative form: every script runs with the repository root as cwd and
# the container mounts that root at /work, so one form serves both sides.
RUN_DIR=${URSINE_RUN_DIR#"$ROOT"/}

# Executed rather than sourced (scripts/dev.sh asks for the path this way).
# `case`, not `[ ] &&`, so a sourced run never returns a failing status.
case "${0##*/}" in
run-dir.sh) printf '%s\n' "$RUN_DIR" ;;
esac
