#!/bin/sh
# Ursine installer — binaries and init unit.
#
# Works on any Linux distribution. Paths are configurable; the
# defaults follow the FHS and the service layouts used by systemd, OpenRC and
# dinit. Packaging builds should pass --destdir and an explicit --init.
#
# Run as root for a real install. --destdir stages files without touching the
# host and skips service activation.
#
# Usage: ./install.sh [options]
#        ./install.sh --help

set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/current-system/sw/bin
export PATH

# ── Defaults (overridable by environment or flags) ──────────────────────────
DESTDIR=${DESTDIR:-}
DESTDIR_SET=0
PREFIX=${PREFIX:-/usr/local}
BINDIR=${BINDIR:-}
SBINDIR=${SBINDIR:-}
MANDIR=${MANDIR:-}
DATADIR=${DATADIR:-}
LIBEXECDIR=${LIBEXECDIR:-}
SYSCONFDIR=${SYSCONFDIR:-/etc}
LOCALSTATEDIR=${LOCALSTATEDIR:-/var}
UNITDIR=${UNITDIR:-}
DINIT_CONFIG_DIR=${DINIT_CONFIG_DIR:-}
BIN_SRC=${BIN_SRC:-}
INIT=${INIT:-auto}
FORCE=${FORCE:-0}
START=${START:-1}
ALLOW_UNVERIFIED_AUTH=${ALLOW_UNVERIFIED_AUTH:-0}
INSTALL_SERVICE=${INSTALL_SERVICE:-1}
CHECK=0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

die() {
  printf 'install: error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'install: warning: %s\n' "$*" >&2
}

info() {
  printf 'install: %s\n' "$*"
}

usage() {
  cat <<'EOF'
Ursine installer — installs ursine, ursined and an init unit.

USAGE
  sudo ./install.sh [options]

OPTIONS
  --prefix DIR          Install prefix (default: /usr/local)
  --bindir DIR          GUI directory (default: PREFIX/bin)
  --sbindir DIR         Daemon directory (default: PREFIX/sbin)
  --libexecdir DIR      Internal helpers (default: PREFIX/lib)
  --datadir DIR         Data root for the desktop entry + icon (default: PREFIX/share)
  --sysconfdir DIR      Configuration root (default: /etc)
  --localstatedir DIR   Variable data root (default: /var)
  --unitdir DIR         Init service directory (default depends on --init)
  --dinit-config-dir DIR
                        dinit user config directory (default: SYSCONFDIR/dinit.d/config)
  --destdir DIR         Stage everything under DIR; skip activation
  --bin-dir DIR         Directory containing the ursine/ursined binaries
  --init NAME           systemd, openrc, dinit or none (default: auto-detect)
  --no-service          Do not install an init unit
  --no-start            Install the unit but do not enable/start it
  --allow-unverified-auth
                        Permit cross-architecture staging when the target
                        binary cannot run; auth backend stays unverified
  --force               Overwrite changed unit files (backup first)
  --check               Print the resolved plan and exit
  --help                Show this help

ENVIRONMENT
  DESTDIR, PREFIX, BINDIR, SBINDIR, LIBEXECDIR, SYSCONFDIR,
  MANDIR, DATADIR, LOCALSTATEDIR, UNITDIR, DINIT_CONFIG_DIR, BIN_SRC, INIT,
  START, ALLOW_UNVERIFIED_AUTH.

EXAMPLES
  sudo ./install.sh
  sudo ./install.sh --prefix /usr --init systemd
  ./install.sh --destdir "$pkgdir" --prefix /usr --init openrc --unitdir /etc/init.d
  ./install.sh --destdir "$pkgdir" --prefix /usr --init dinit \
      --unitdir /lib/dinit.d --libexecdir /usr/lib
EOF
}

# ── Argument parsing ────────────────────────────────────────────────────────
need_value() {
  [ "$#" -ge 2 ] || die "option $1 needs a value"
  [ -n "$2" ] || die "option $1 needs a non-empty value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --prefix)
    need_value "$@"
    PREFIX=$2
    shift 2
    ;;
  --prefix=*)
    PREFIX=${1#*=}
    shift
    ;;
  --bindir)
    need_value "$@"
    BINDIR=$2
    shift 2
    ;;
  --bindir=*)
    BINDIR=${1#*=}
    shift
    ;;
  --datadir)
    need_value "$@"
    DATADIR=$2
    shift 2
    ;;
  --datadir=*)
    DATADIR=${1#*=}
    shift
    ;;
  --sbindir)
    need_value "$@"
    SBINDIR=$2
    shift 2
    ;;
  --sbindir=*)
    SBINDIR=${1#*=}
    shift
    ;;
  --libexecdir)
    need_value "$@"
    LIBEXECDIR=$2
    shift 2
    ;;
  --libexecdir=*)
    LIBEXECDIR=${1#*=}
    shift
    ;;
  --sysconfdir)
    need_value "$@"
    SYSCONFDIR=$2
    shift 2
    ;;
  --sysconfdir=*)
    SYSCONFDIR=${1#*=}
    shift
    ;;
  --localstatedir)
    need_value "$@"
    LOCALSTATEDIR=$2
    shift 2
    ;;
  --localstatedir=*)
    LOCALSTATEDIR=${1#*=}
    shift
    ;;
  --unitdir)
    need_value "$@"
    UNITDIR=$2
    shift 2
    ;;
  --unitdir=*)
    UNITDIR=${1#*=}
    shift
    ;;
  --dinit-config-dir)
    need_value "$@"
    DINIT_CONFIG_DIR=$2
    shift 2
    ;;
  --dinit-config-dir=*)
    DINIT_CONFIG_DIR=${1#*=}
    shift
    ;;
  --destdir)
    need_value "$@"
    DESTDIR=$2
    DESTDIR_SET=1
    shift 2
    ;;
  --destdir=*)
    DESTDIR=${1#*=}
    DESTDIR_SET=1
    shift
    ;;
  --bin-dir | --from)
    need_value "$@"
    BIN_SRC=$2
    shift 2
    ;;
  --bin-dir=* | --from=*)
    BIN_SRC=${1#*=}
    shift
    ;;
  --init)
    need_value "$@"
    INIT=$2
    shift 2
    ;;
  --init=*)
    INIT=${1#*=}
    shift
    ;;
  --no-service)
    INSTALL_SERVICE=0
    shift
    ;;
  --no-start)
    START=0
    shift
    ;;
  --allow-unverified-auth)
    ALLOW_UNVERIFIED_AUTH=1
    shift
    ;;
  --force)
    FORCE=1
    shift
    ;;
  --check)
    CHECK=1
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ── Paths ───────────────────────────────────────────────────────────────────
trim_trailing_slash() {
  if [ "$1" = "/" ]; then
    printf '/'
  else
    printf '%s' "${1%/}"
  fi
}

if [ "$DESTDIR_SET" -eq 1 ]; then
  [ -n "$DESTDIR" ] || die "--destdir must not be empty"
  [ "$DESTDIR" != / ] || die "--destdir must not be /"
fi

PREFIX=$(trim_trailing_slash "$PREFIX")
SYSCONFDIR=$(trim_trailing_slash "$SYSCONFDIR")
LOCALSTATEDIR=$(trim_trailing_slash "$LOCALSTATEDIR")
[ -n "$DESTDIR" ] && DESTDIR=$(trim_trailing_slash "$DESTDIR")
[ -n "$BINDIR" ] || BINDIR="$PREFIX/bin"
[ -n "$SBINDIR" ] || SBINDIR="$PREFIX/sbin"
[ -n "$LIBEXECDIR" ] || LIBEXECDIR="$PREFIX/lib"
[ -n "$MANDIR" ] || MANDIR="$PREFIX/share/man"
[ -n "$DATADIR" ] || DATADIR="$PREFIX/share"
[ -n "$DINIT_CONFIG_DIR" ] || DINIT_CONFIG_DIR="$SYSCONFDIR/dinit.d/config"

validate_path() {
  [ -n "$1" ] || die "empty path is not allowed"
  case "$1" in
  /*) ;;
  *) die "path must be absolute: $1" ;;
  esac
  case "$1" in
  *' '* | *'	'*) die "path must not contain whitespace: $1" ;;
  esac
  case "$1" in
  *[!A-Za-z0-9/._+-]*) die "path contains unsafe characters: $1" ;;
  esac
  if [ "$1" != "/" ]; then
    case "$1/" in
    *//* | */../* | */./*) die "path contains empty, . or .. component: $1" ;;
    esac
  fi
}

for path in "$PREFIX" "$BINDIR" "$SBINDIR" "$LIBEXECDIR" "$SYSCONFDIR" \
  "$LOCALSTATEDIR" "$DINIT_CONFIG_DIR" "$MANDIR" "$DATADIR"; do
  validate_path "$path"
done
[ -z "$UNITDIR" ] || validate_path "$UNITDIR"

case "$DESTDIR" in
'') ;;
/) die "--destdir must not be /" ;;
/*) validate_path "$DESTDIR" ;;
*) die "--destdir must be absolute: $DESTDIR" ;;
esac
if [ -n "$DESTDIR" ] && [ -e "$DESTDIR" ]; then
  DESTDIR=$(CDPATH='' cd -- "$DESTDIR" && pwd -P) ||
    die "cannot resolve --destdir: $DESTDIR"
  [ "$DESTDIR" != / ] || die "--destdir must not be /"
fi

target_path() {
  printf '%s%s' "$DESTDIR" "$1"
}

# ── Assets and binaries ─────────────────────────────────────────────────────
find_asset_dir() {
  for dir in "$SCRIPT_DIR/packaging" "$SCRIPT_DIR/share/ursine/packaging" \
    "$SCRIPT_DIR/../packaging"; do
    if [ -d "$dir/systemd" ]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  return 1
}

find_bin_dir() {
  for dir in "$SCRIPT_DIR/bin" "$SCRIPT_DIR/artifacts/target/release" \
    "$SCRIPT_DIR/../artifacts/target/release"; do
    if [ -f "$dir/ursine" ] && [ -f "$dir/ursined" ]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  return 1
}

if [ -z "$BIN_SRC" ]; then
  BIN_SRC=$(find_bin_dir) || die "binaries not found (use --bin-dir DIR)"
fi
BIN_SRC=$(CDPATH='' cd -- "$BIN_SRC" && pwd -P) || die "cannot enter --bin-dir: $BIN_SRC"
[ -f "$BIN_SRC/ursine" ] || die "missing $BIN_SRC/ursine"
[ -f "$BIN_SRC/ursined" ] || die "missing $BIN_SRC/ursined"

# The daemon must report the shadow authenticator (the only build).
# Execute the target binary when possible, including DESTDIR staging. Cross-
# architecture staging cannot execute the target and must opt in explicitly.
if [ "$CHECK" -eq 0 ]; then
  if version=$("$BIN_SRC/ursined" --version 2>/dev/null); then
    case "$version" in
    *"auth: shadow"*) ;;
    *) die "unexpected ursined --version output: $version" ;;
    esac
  elif [ -n "$DESTDIR" ] && [ "$ALLOW_UNVERIFIED_AUTH" -eq 1 ]; then
    warn "cannot execute $BIN_SRC/ursined; staged auth backend is unverified"
  elif [ -n "$DESTDIR" ]; then
    die "cannot execute $BIN_SRC/ursined; use --allow-unverified-auth for cross-architecture staging"
  else
    die "cannot execute $BIN_SRC/ursined --version (wrong architecture or missing musl runtime?)"
  fi
fi

if [ "$INSTALL_SERVICE" -eq 1 ] && [ "$INIT" != none ]; then
  ASSET_DIR=$(find_asset_dir) || die "packaging assets not found (run from the release tree)"
fi

# ── OS and init detection ───────────────────────────────────────────────────
os_value() {
  [ -r /etc/os-release ] || return 1
  sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | head -n 1 | tr -d '"'
}

OS_ID=$(os_value ID || true)
OS_LIKE=$(os_value ID_LIKE || true)
OS_NAME=$(os_value PRETTY_NAME || true)
OS_ID=$(printf '%s' "$OS_ID" | tr '[:upper:]' '[:lower:]')
OS_LIKE=$(printf '%s' "$OS_LIKE" | tr '[:upper:]' '[:lower:]')

detect_init() {
  # PID 1 is authoritative: a host can have both OpenRC and dinit installed.
  pid1=${URSINE_PID1_COMM:-}
  if [ -z "$pid1" ] && [ -r /proc/1/comm ]; then
    pid1=$(tr -d '\n' </proc/1/comm)
  fi
  [ -n "$pid1" ] || pid1=$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)
  if [ "$pid1" = init ]; then
    pid1_exe=${URSINE_PID1_EXE:-}
    if [ -z "$pid1_exe" ] && [ -L /proc/1/exe ]; then
      pid1_exe=$(readlink /proc/1/exe 2>/dev/null || true)
    fi
    case "$pid1_exe" in
    */dinit) pid1=dinit ;;
    */openrc-init) pid1=openrc-init ;;
    esac
  fi
  case "$pid1" in
  systemd)
    printf systemd
    return 0
    ;;
  dinit)
    printf dinit
    return 0
    ;;
  init | openrc-init)
    if [ -d /run/openrc ]; then
      printf openrc
      return 0
    fi
    if command -v dinitctl >/dev/null 2>&1 && dinitctl list >/dev/null 2>&1; then
      printf dinit
      return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then
      printf openrc
      return 0
    fi
    ;;
  esac
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    printf systemd
  elif command -v dinitctl >/dev/null 2>&1 && dinitctl list >/dev/null 2>&1; then
    printf dinit
  elif [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1; then
    printf openrc
  elif command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]; then
    printf openrc
  elif command -v dinitctl >/dev/null 2>&1; then
    printf dinit
  else
    printf none
  fi
}

if [ "$INIT" = auto ]; then
  INIT=$(detect_init)
fi
case "$INIT" in
systemd | openrc | dinit | none) ;;
*) die "unknown --init value: $INIT (systemd, openrc, dinit or none)" ;;
esac

if [ -z "$UNITDIR" ]; then
  case "$INIT" in
  systemd) UNITDIR=/etc/systemd/system ;;
  openrc) UNITDIR=/etc/init.d ;;
  dinit)
    if [ -d /lib/dinit.d ] || [ ! -d /etc/dinit.d ]; then
      UNITDIR=/lib/dinit.d
    else
      UNITDIR=/etc/dinit.d
    fi
    ;;
  none) UNITDIR= ;;
  esac
fi

if [ "$INSTALL_SERVICE" -eq 1 ] && [ "$INIT" = none ]; then
  warn "no supported init system detected; skipping unit (use --init or --no-service)"
  INSTALL_SERVICE=0
  START=0
fi

# ── Preflight ───────────────────────────────────────────────────────────────
if [ "$CHECK" -eq 0 ] && [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
  die "run as root, or use --destdir DIR to stage files"
fi

if [ "$INSTALL_SERVICE" -eq 1 ]; then
  case "$INIT" in
  systemd) [ -f "$ASSET_DIR/systemd/ursined.service" ] || die "missing systemd unit asset" ;;
  openrc) [ -f "$ASSET_DIR/openrc/ursined" ] || die "missing OpenRC service asset" ;;
  dinit)
    [ -f "$ASSET_DIR/dinit/ursined" ] || die "missing dinit service asset"
    [ -f "$ASSET_DIR/dinit/ursined.wrapper" ] || die "missing dinit wrapper asset"
    [ -f "$ASSET_DIR/dinit/ursined.conf" ] || die "missing dinit config asset"
    ;;
  esac
fi

# ── Plan output ─────────────────────────────────────────────────────────────
show_plan() {
  info "distro: ${OS_NAME:-unknown} (${OS_ID:-unknown})"
  info "init: $INIT"
  info "prefix: $PREFIX"
  info "binaries: $BIN_SRC -> $BINDIR, $SBINDIR"
  info "config: $SYSCONFDIR/ursine/config.toml"
  if [ "$INSTALL_SERVICE" -eq 1 ]; then
    case "$INIT" in
    systemd) info "unit: $UNITDIR/ursined.service" ;;
    openrc) info "unit: $UNITDIR/ursined" ;;
    dinit)
      info "unit: $UNITDIR/ursined"
      info "dinit wrapper: $LIBEXECDIR/dinit/ursined"
      info "dinit config: $DINIT_CONFIG_DIR/ursined.conf"
      ;;
    esac
  else
    info "unit: not installed"
  fi
  info "audit directory: $LOCALSTATEDIR/log/ursine"
  if [ -n "$DESTDIR" ]; then
    info "mode: staging under $DESTDIR (no activation)"
  elif [ "$INSTALL_SERVICE" -eq 1 ] && [ "$START" -eq 1 ]; then
    info "mode: install and start"
  else
    info "mode: install only"
  fi
}

show_plan
[ "$CHECK" -eq 0 ] || exit 0

# ── Install helpers ─────────────────────────────────────────────────────────
ensure_dir() {
  install -d -m "$2" "$1" || die "cannot create $1"
}

# Escape a value for use in a sed replacement with | as the delimiter.
sed_escape() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

render_to() {
  render_src=$1
  render_dst=$2
  sed \
    -e "s|@PREFIX@|$(sed_escape "$PREFIX")|g" \
    -e "s|@BINDIR@|$(sed_escape "$BINDIR")|g" \
    -e "s|@SBINDIR@|$(sed_escape "$SBINDIR")|g" \
    -e "s|@LIBEXECDIR@|$(sed_escape "$LIBEXECDIR")|g" \
    -e "s|@SYSCONFDIR@|$(sed_escape "$SYSCONFDIR")|g" \
    -e "s|@LOCALSTATEDIR@|$(sed_escape "$LOCALSTATEDIR")|g" \
    -e "s|@DINIT_CONFIG_DIR@|$(sed_escape "$DINIT_CONFIG_DIR")|g" \
    "$render_src" >"$render_dst" || return 1
}

backup_file() {
  backup="$1.ursine-backup.$(date +%Y%m%d%H%M%S)"
  cp -p "$1" "$backup" || die "cannot back up $1"
  info "backup: $backup"
}

install_file() {
  file_src=$1
  file_dst=$2
  file_mode=$3
  file_tmp=$(mktemp "${file_dst}.ursine-new.XXXXXX") || {
    die "cannot create temporary file next to $file_dst"
  }
  install -m "$file_mode" "$file_src" "$file_tmp" || {
    rm -f "$file_tmp"
    die "cannot install $file_dst"
  }
  mv -f "$file_tmp" "$file_dst" || {
    rm -f "$file_tmp"
    die "cannot replace $file_dst"
  }
}

install_rendered() {
  inst_src=$1
  inst_dst=$2
  inst_mode=$3
  inst_tmp=$(mktemp "${inst_dst}.ursine-tmp.XXXXXX") || {
    die "cannot create temporary file next to $inst_dst"
  }
  render_to "$inst_src" "$inst_tmp" || {
    rm -f "$inst_tmp"
    die "cannot render $inst_src"
  }
  if [ -L "$inst_dst" ]; then
    rm -f "$inst_tmp"
    die "refusing to replace symlink: $inst_dst"
  fi
  if [ -d "$inst_dst" ]; then
    rm -f "$inst_tmp"
    die "refusing to replace directory: $inst_dst"
  fi
  if [ -e "$inst_dst" ]; then
    if cmp -s "$inst_tmp" "$inst_dst"; then
      rm -f "$inst_tmp"
      chmod "$inst_mode" "$inst_dst" || die "cannot set mode on $inst_dst"
      if [ "$(id -u)" -eq 0 ]; then
        chown 0:0 "$inst_dst" || die "cannot set owner on $inst_dst"
      fi
      info "unchanged: $inst_dst"
      return 0
    fi
    if [ "$FORCE" -ne 1 ]; then
      rm -f "$inst_tmp"
      die "refusing to overwrite $inst_dst (use --force)"
    fi
    backup_file "$inst_dst"
  fi
  install -m "$inst_mode" "$inst_tmp" "$inst_dst" || {
    rm -f "$inst_tmp"
    die "cannot install $inst_dst"
  }
  rm -f "$inst_tmp"
  info "installed: $inst_dst"
}

# ── Install ─────────────────────────────────────────────────────────────────
LOG_DIR="$LOCALSTATEDIR/log/ursine"

ensure_dir "$(target_path "$BINDIR")" 0755
ensure_dir "$(target_path "$SBINDIR")" 0755
ensure_dir "$(target_path "$SYSCONFDIR/ursine")" 0750
ensure_dir "$(target_path "$LOG_DIR")" 0750

if [ "$INSTALL_SERVICE" -eq 1 ]; then
  case "$INIT" in
  systemd)
    ensure_dir "$(target_path "$UNITDIR")" 0755
    install_rendered "$ASSET_DIR/systemd/ursined.service" \
      "$(target_path "$UNITDIR/ursined.service")" 0644
    ;;
  openrc)
    ensure_dir "$(target_path "$UNITDIR")" 0755
    install_rendered "$ASSET_DIR/openrc/ursined" \
      "$(target_path "$UNITDIR/ursined")" 0755
    ;;
  dinit)
    ensure_dir "$(target_path "$UNITDIR")" 0755
    ensure_dir "$(target_path "$LIBEXECDIR/dinit")" 0755
    ensure_dir "$(target_path "$DINIT_CONFIG_DIR")" 0755
    install_rendered "$ASSET_DIR/dinit/ursined" \
      "$(target_path "$UNITDIR/ursined")" 0644
    install_rendered "$ASSET_DIR/dinit/ursined.wrapper" \
      "$(target_path "$LIBEXECDIR/dinit/ursined")" 0755
    install_rendered "$ASSET_DIR/dinit/ursined.conf" \
      "$(target_path "$DINIT_CONFIG_DIR/ursined.conf")" 0644
    ;;
  esac
fi

# ursinectl (root CLI) ships with 0.24+ tarballs; optional so older
# layouts still install.
if [ -f "$BIN_SRC/ursinectl" ]; then
  install_file "$BIN_SRC/ursinectl" "$(target_path "$BINDIR/ursinectl")" 0755
else
  warn "ursinectl not found in $BIN_SRC (root CLI not installed)"
fi
# Manual page ships with the packaging assets (best effort: binary-only
# layouts without packaging/ still install the rest).
if asset_dir=$(find_asset_dir) && [ -f "$asset_dir/man/ursinectl.1" ]; then
  ensure_dir "$(target_path "$MANDIR/man1")" 0755
  install_file "$asset_dir/man/ursinectl.1" "$(target_path "$MANDIR/man1/ursinectl.1")" 0644
  info "installed: $(target_path "$MANDIR/man1/ursinectl.1")"
fi
install_file "$BIN_SRC/ursine" "$(target_path "$BINDIR/ursine")" 0755
info "installed: $(target_path "$BINDIR/ursine")"
install_file "$BIN_SRC/ursined" "$(target_path "$SBINDIR/ursined")" 0755
info "installed: $(target_path "$SBINDIR/ursined")"

# Desktop entry + icon: shipped by every install channel (release tree under
# a package manager, nix store copy) so the launcher lists Ursine.
if asset_dir=$(find_asset_dir); then
  if [ -f "$asset_dir/org.feralos.Ursine.desktop" ]; then
    ensure_dir "$(target_path "$DATADIR/applications")" 0755
    install_file "$asset_dir/org.feralos.Ursine.desktop" \
      "$(target_path "$DATADIR/applications/org.feralos.Ursine.desktop")" 0644
    info "installed: $(target_path "$DATADIR/applications/org.feralos.Ursine.desktop")"
  fi
  if [ -f "$asset_dir/icons/org.feralos.Ursine.svg" ]; then
    ensure_dir "$(target_path "$DATADIR/icons/hicolor/scalable/apps")" 0755
    install_file "$asset_dir/icons/org.feralos.Ursine.svg" \
      "$(target_path "$DATADIR/icons/hicolor/scalable/apps/org.feralos.Ursine.svg")" 0644
    info "installed: $(target_path "$DATADIR/icons/hicolor/scalable/apps/org.feralos.Ursine.svg")"
  fi
fi

if [ -z "$DESTDIR" ]; then
  chown root:root "$(target_path "$LOG_DIR")" || die "cannot set ownership on $LOG_DIR"
fi

if [ -z "$DESTDIR" ] && [ "$INSTALL_SERVICE" -eq 1 ] && [ "$START" -eq 1 ]; then
  case "$INIT" in
  systemd)
    systemctl daemon-reload || die "systemctl daemon-reload failed"
    systemctl enable ursined.service || die "systemctl enable failed"
    systemctl restart ursined.service || die "systemctl restart failed"
    info "started: ursined.service"
    ;;
  openrc)
    rc-update add ursined default || die "rc-update add failed"
    rc-service ursined restart 2>/dev/null || rc-service ursined start ||
      die "rc-service start failed"
    info "started: ursined"
    ;;
  dinit)
    if ! enable_out=$(dinitctl enable ursined 2>&1); then
      [ -L "${DESTDIR}/etc/dinit.d/boot.d/ursined" ] ||
        [ -L "${DESTDIR}/lib/dinit.d/boot.d/ursined" ] ||
        die "dinitctl enable failed: $enable_out"
      warn "dinit service was already enabled"
    fi
    dinitctl reload ursined >/dev/null 2>&1 || true
    dinitctl restart ursined 2>/dev/null || dinitctl start ursined ||
      die "dinitctl start failed"
    info "started: ursined"
    ;;
  esac
else
  case "$INIT" in
  systemd)
    [ "$INSTALL_SERVICE" -eq 1 ] && info "enable manually: systemctl enable --now ursined.service"
    ;;
  openrc)
    [ "$INSTALL_SERVICE" -eq 1 ] && info "enable manually: rc-update add ursined default && rc-service ursined start"
    ;;
  dinit)
    [ "$INSTALL_SERVICE" -eq 1 ] && info "enable manually: dinitctl enable ursined && dinitctl start ursined"
    ;;
  esac
fi

info "done"
