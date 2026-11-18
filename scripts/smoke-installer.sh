#!/bin/sh
# Functional smoke tests for the release tarball: unpack it, stage the
# installer for systemd/OpenRC/dinit, then exercise ursine-activate and
# ursine-deactivate against staged roots. No host access: every root lives
# in the run directory (`<run dir>/smoke`).
#
#   scripts/smoke-installer.sh <run dir>/release/<tarball>
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2
TARBALL=${1:?usage: $0 <release-tarball>}

. scripts/run-dir.sh
SMOKE=$RUN_DIR/smoke

sh -n install.sh
sh -n packaging/openrc/ursined
sh -n packaging/dinit/ursined.wrapper

rm -rf "$SMOKE"
mkdir -p "$SMOKE"
tar xzf "$TARBALL" -C "$SMOKE"
test -x "$SMOKE/bin/ursine-activate"
test -x "$SMOKE/bin/ursine-deactivate"
sh -n "$SMOKE/bin/ursine-activate"
sh -n "$SMOKE/bin/ursine-deactivate"

for init in systemd openrc dinit; do
  root="$PWD/$SMOKE/root-$init"
  case "$init" in
  systemd)
    "$SMOKE/install.sh" --destdir "$root" --prefix /usr --init systemd --no-start
    test -f "$root/etc/systemd/system/ursined.service"
    ;;
  openrc)
    "$SMOKE/install.sh" --destdir "$root" --prefix /usr --init openrc --no-start
    test -x "$root/etc/init.d/ursined"
    ;;
  dinit)
    "$SMOKE/install.sh" --destdir "$root" --prefix /usr --init dinit \
      --unitdir /lib/dinit.d --libexecdir /usr/lib --no-start
    test -f "$root/lib/dinit.d/ursined"
    test -x "$root/usr/lib/dinit/ursined"
    test -f "$root/etc/dinit.d/config/ursined.conf"
    ;;
  esac
  test -x "$root/usr/bin/ursine"
  test -x "$root/usr/sbin/ursined"
  test "$("$root/usr/sbin/ursined" --version | grep -c 'auth: shadow')" = "1"
done

root="$PWD/$SMOKE/install-dinit-default"
"$SMOKE/install.sh" --destdir "$root" --prefix /usr --init dinit --no-start
test -f "$root/lib/dinit.d/ursined"
test -x "$root/usr/lib/dinit/ursined"
test -f "$root/etc/dinit.d/config/ursined.conf"
root="$PWD/$SMOKE/install-dinit-auto"
URSINE_PID1_COMM=init URSINE_PID1_EXE=/sbin/dinit \
  "$SMOKE/install.sh" --destdir "$root" --prefix /usr --no-start
test -f "$root/lib/dinit.d/ursined"

profile="$PWD/$SMOKE/profile"
mkdir -p "$profile"
cp -R "$SMOKE/bin" "$SMOKE/packaging" "$profile/"
for init in systemd openrc dinit; do
  root="$PWD/$SMOKE/activate-$init"
  "$SMOKE/bin/ursine-activate" --profile "$profile" --root "$root" --init "$init" --no-start
  test -f "$root/usr/local/sbin/ursined"
  test ! -L "$root/usr/local/sbin/ursined"
  test "$(stat -c '%a' "$root/usr/local/sbin/ursined")" = "755"
  case "$init" in
  systemd)
    test -f "$root/etc/systemd/system/ursined.service"
    grep -Fq "/usr/local/sbin/ursined" "$root/etc/systemd/system/ursined.service"
    ! grep -Fq "$profile" "$root/etc/systemd/system/ursined.service"
    ;;
  openrc)
    test -x "$root/etc/init.d/ursined"
    grep -Fq "/usr/local/sbin/ursined" "$root/etc/init.d/ursined"
    ! grep -Fq "$profile" "$root/etc/init.d/ursined"
    ;;
  dinit)
    test -f "$root/lib/dinit.d/ursined"
    test -x "$root/usr/lib/dinit/ursined"
    test -f "$root/etc/dinit.d/config/ursined.conf"
    grep -Fq "/usr/local/sbin/ursined" "$root/usr/lib/dinit/ursined"
    ! grep -Fq "$profile" "$root/usr/lib/dinit/ursined"
    mkdir -p "$root/lib/dinit.d/boot.d" "$root/etc/dinit.d/boot.d"
    ln -sfn ../ursined "$root/lib/dinit.d/boot.d/ursined"
    ln -sfn ../ursined "$root/etc/dinit.d/boot.d/ursined"
    ;;
  esac
done

root="$PWD/$SMOKE/activate-auto-dinit"
mkdir -p "$root/etc/init.d" "$root/etc/dinit.d/boot.d" "$root/lib/dinit.d/boot.d"
printf '# Ursine control daemon\n' >"$root/etc/init.d/ursined"
printf '# Ursine control daemon\n' >"$root/etc/dinit.d/ursined"
printf '# Ursine control daemon\n' >"$root/lib/dinit.d/ursined"
ln -sfn ../ursined "$root/etc/dinit.d/boot.d/ursined"
ln -sfn ../ursined "$root/lib/dinit.d/boot.d/ursined"
URSINE_PID1_COMM=init URSINE_PID1_EXE=/sbin/dinit \
  "$SMOKE/bin/ursine-activate" --profile "$profile" --root "$root" --no-start
URSINE_PID1_COMM=init URSINE_PID1_EXE=/sbin/dinit \
  "$SMOKE/bin/ursine-activate" --profile "$profile" --root "$root" --no-start
test -f "$root/lib/dinit.d/ursined"
test ! -e "$root/etc/dinit.d/ursined"
test ! -e "$root/etc/init.d/ursined"
test ! -L "$root/etc/dinit.d/boot.d/ursined"
test ! -L "$root/lib/dinit.d/boot.d/ursined"
if "$SMOKE/bin/ursine-activate" --profile "$profile" --root / --no-start; then
  echo "activation accepted --root /" >&2
  exit 1
fi

for init in systemd openrc dinit; do
  root="$PWD/$SMOKE/activate-$init"
  "$SMOKE/bin/ursine-deactivate" --profile "$profile" --root "$root" --init "$init"
  test ! -e "$root/usr/local/sbin/ursined"
  case "$init" in
  systemd) test ! -e "$root/etc/systemd/system/ursined.service" ;;
  openrc) test ! -e "$root/etc/init.d/ursined" ;;
  dinit)
    test ! -e "$root/lib/dinit.d/ursined"
    test ! -e "$root/etc/dinit.d/ursined"
    test ! -e "$root/usr/lib/dinit/ursined"
    test ! -e "$root/etc/dinit.d/config/ursined.conf"
    test ! -L "$root/lib/dinit.d/boot.d/ursined"
    test ! -L "$root/etc/dinit.d/boot.d/ursined"
    ;;
  esac
done

echo "smoke: installer and activation OK for systemd, OpenRC, dinit"
