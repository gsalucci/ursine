#!/bin/sh
# Host acceptance for a published release. This is the single script allowed
# to interact with the host (AGENTS.md, host isolation). It never reads or
# changes the repository: the package comes from the published GitHub flake.
#
#   scripts/test-host.sh
#
# Run it after the release tag is published (CI pins it on main first).
# Requires: nix with flakes, sudo, an interactive session.
set -eu

FLAKE_URL=${URSINE_FLAKE:-github:skea999/ursine}
INSTALLABLE=$FLAKE_URL#ursine

fail() {
  echo "error: $*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
}

# Nix profile bin directory: new CLI first (XDG state), then the classic link
# and the system default.
profile_bin() {
  for dir in \
    "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/profile/bin" \
    "$HOME/.nix-profile/bin" \
    /nix/var/nix/profiles/default/bin; do
    if [ -x "$dir/ursined" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

installed_version() {
  "$1/ursined" --version | sed -n 's/^ursined \([^ ]*\).*/\1/p'
}

command -v nix >/dev/null 2>&1 || fail "nix is required (this script runs on the host)"
command -v sudo >/dev/null 2>&1 || fail "sudo is required (system activation)"

step "flake registry"
if nix registry list | grep -q 'flake:ursine'; then
  echo "registry entry present: flake:ursine"
else
  echo "adding registry entry: flake:ursine -> $FLAKE_URL"
fi
nix registry add ursine "$FLAKE_URL"

step "refresh the published flake"
nix flake metadata --refresh "$FLAKE_URL" >/dev/null
version=$(nix eval --raw --refresh "$FLAKE_URL#packages.x86_64-linux.ursine.version")
[ -n "$version" ] || fail "cannot read the published version from $FLAKE_URL"
echo "published version: $version"

step "install or upgrade ursine"
if nix profile list 2>/dev/null | grep -qw ursine; then
  nix profile upgrade ursine || {
    echo "upgrade by name failed; reinstalling the element"
    nix profile remove ursine || true
    nix profile install --refresh "$INSTALLABLE"
  }
else
  nix profile install --refresh "$INSTALLABLE"
fi

bin=$(profile_bin) || fail "ursined is not in any known nix profile"
current=$(installed_version "$bin")
if [ "$current" != "$version" ]; then
  echo "profile has $current, reinstalling $version"
  nix profile remove ursine || true
  nix profile install --refresh "$INSTALLABLE"
  bin=$(profile_bin) || fail "ursined is not in any known nix profile"
  current=$(installed_version "$bin")
  [ "$current" = "$version" ] ||
    fail "installed $current but the published flake says $version — retry with a refreshed flake cache"
fi

step "activate the system units"
sudo env URSINE_PROFILE="${bin%/bin}" "$bin/ursine-activate"

step "tests"
"$bin/ursined" --version | grep -Fq 'auth: shadow' ||
  fail "ursined --version does not report shadow auth"
"$bin/ursined" --version
"$bin/ursinectl" --version

# Activation enables and restarts the service: prove it is live under the
# init this machine actually runs.
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl is-active --quiet ursined || fail "ursined service is not active (systemd)"
elif command -v rc-service >/dev/null 2>&1; then
  rc-service ursined status >/dev/null 2>&1 || fail "ursined service is not running (OpenRC)"
elif command -v dinitctl >/dev/null 2>&1; then
  dinitctl status ursined >/dev/null 2>&1 || fail "ursined service is not running (dinit)"
else
  fail "no supported init found (systemd, OpenRC, dinit)"
fi
echo "ursined service: active"

status=$(sudo "$bin/ursinectl" system status)
printf '%s\n' "$status"
case "$status" in
*'"protocol_version"'*) ;;
*) fail "ursinectl system status returned no protocol_version" ;;
esac

step "done"
printf 'ursine %s installed and running\n' "$version"
