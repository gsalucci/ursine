#!/bin/sh
# Duplication gate.
#
# Our source: jscpd with .jscpd.json (50 tokens, Rust + shell, threshold 0).
# Any clone fails the gate. Refactor the code, never raise the threshold.
#
# Dependencies: `cargo tree -d` is written to the run directory as a report.
# Every duplicate version comes from the pinned libcosmic/iced git graph
# (png 0.17 + 0.18, xkbcommon 0.7 + 0.8, …); we cannot align them without an
# upstream change. Nothing generated is committed, so there is no tolerated
# list to keep: each run records the exact state in
# `artifacts/container-dev/<timestamp>/duplicates/`.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2
. scripts/run-dir.sh
DUP=$ROOT/$RUN_DIR/duplicates
REPORT=$DUP/dependency-duplicates.txt
mkdir -p "$DUP"

STATUS=0
step() { printf '\n==> %s\n' "$*"; }

step "source clones (jscpd, 50 tokens, threshold 0)"
if command -v jscpd >/dev/null 2>&1; then
  if ! jscpd --config "$ROOT/.jscpd.json" --output "$DUP/jscpd"; then
    echo "duplicates: source clones found — refactor them; never raise the threshold" >&2
    STATUS=1
  fi
else
  echo "duplicates: jscpd missing (run in ursine-ci:1)" >&2
  STATUS=1
fi

step "dependency duplicates (report)"
if cargo tree -d --locked --workspace >"$REPORT" 2>&1; then
  # Duplicate roots start at column 0 (`name vX.Y.Z`); children are indented
  # with box-drawing characters, so match the crate-name pattern only.
  count=$(grep -cE '^[a-z0-9_-]+ v[0-9]' "$REPORT" || true)
  echo "duplicates: $count duplicate crate versions in the dependency graph"
  echo "duplicates: report: $RUN_DIR/duplicates/dependency-duplicates.txt"
else
  echo "duplicates: cargo tree failed" >&2
  STATUS=1
fi

exit "$STATUS"
