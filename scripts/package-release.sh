#!/bin/sh
# Release package builder: the ONLY way binaries are produced, locally and in
# CI. Builds static daemon+CLI and dynamic GUI, enforces the static contract,
# packs the tarball and runs the installer/activation smoke tests.
#
#   scripts/package-release.sh --check              # verify only, artifact unused
#   scripts/package-release.sh --release NAME       # keep <run dir>/release/NAME
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2

MODE=${1:---check}
case "$MODE" in
--check) NAME=ursine-latest-x86_64-musl.tar.gz ;;
--release)
  NAME=${2:?usage: $0 --release <tarball-name>}
  ;;
*)
  echo "usage: $0 [--check|--release <name>]" >&2
  exit 2
  ;;
esac

. scripts/run-dir.sh
RELEASE=$RUN_DIR/release
PKG=$RUN_DIR/pkg
mkdir -p "$RELEASE"

# ONE build per linkage class: the daemon and CLI are pure Rust since the
# shadow-auth switch → fully static. The GUI needs libxkbcommon (no .a in
# Alpine) → dynamic musl, like every desktop app. Host units (proc-macros)
# must NOT get +crt-static, hence the explicit --target with scoped rustflags.
CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C target-feature=+crt-static" \
  cargo build --release --target x86_64-unknown-linux-musl \
  -p ursined -p ursinectl --locked
cargo build --release -p ursine --locked

rm -rf "$PKG"
mkdir -p "$PKG/bin"
cp artifacts/target/x86_64-unknown-linux-musl/release/ursined \
  artifacts/target/x86_64-unknown-linux-musl/release/ursinectl \
  "$PKG/bin/"
cp artifacts/target/release/ursine "$PKG/bin/"
cp install.sh "$PKG/"
cp src/tools/ursine-activate.sh "$PKG/bin/ursine-activate"
cp src/tools/ursine-deactivate.sh "$PKG/bin/ursine-deactivate"
chmod 755 "$PKG/bin/ursine-activate" "$PKG/bin/ursine-deactivate"
cp -r packaging "$PKG/"

# Static contract: daemon + CLI must have ZERO dynamic deps. The GUI may only
# need the known desktop runtime libs.
fail=0
for b in ursined ursinectl; do
  f="artifacts/target/x86_64-unknown-linux-musl/release/$b"
  if readelf -d "$f" | grep -q NEEDED; then
    echo "error: $b is not static:" >&2
    readelf -d "$f" | grep NEEDED >&2
    fail=1
  else
    echo "$b: static OK"
  fi
done
f="artifacts/target/release/ursine"
echo "ursine (GUI) dynamic deps:"
readelf -d "$f" | grep NEEDED
if readelf -d "$f" | grep NEEDED |
  grep -Ev 'libxkbcommon\.so\.0|libgcc_s\.so\.1|libc\.musl-x86_64\.so\.1'; then
  echo "error: ursine (GUI) links an unexpected library" >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1

tar czf "$RELEASE/$NAME" -C "$PKG" .
(
  cd "$RELEASE"
  sha256sum "$NAME" >"$NAME.sha256"
)
tar tzf "$RELEASE/$NAME"
cat "$RELEASE/$NAME.sha256"

sh scripts/smoke-installer.sh "$RELEASE/$NAME"

if [ "$MODE" = "--check" ]; then
  echo "package: verified, artifact discarded (push builds are never published)"
  rm -f "$RELEASE/$NAME" "$RELEASE/$NAME.sha256"
else
  echo "package: $RELEASE/$NAME"
fi
