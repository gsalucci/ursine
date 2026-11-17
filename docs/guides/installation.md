# Installing Ursine

Ursine ships as a release tarball containing both binaries and init units
for systemd, OpenRC and dinit. The installer is the same on every
Linux distribution; only paths and the init system are detected or selected.

## Nix profile

```bash
# 1. Add the flake
nix registry add ursine github:skea999/ursine

# 2. Install in the default profile
nix profile add ursine#ursine

# 3. Bootstrap the service (detects systemd, OpenRC or dinit)
sudo "$HOME/.nix-profile/bin/ursine-activate"
```

`ursine-activate` discovers the Nix profile generically, copies `ursined` to
the root-owned `/usr/local/sbin/ursined`, renders the init unit against the
root-owned binary, and restarts the service. The user-writable Nix profile is never the live root
service path. Re-run it after every upgrade:

```bash
nix profile upgrade ursine
sudo "$HOME/.nix-profile/bin/ursine-activate"
```

The package chain is `ursine` → `ursined` → `ursine-activate`: the daemon owns
the activation tools and the GUI depends on the daemon. The activation command
is idempotent and refreshes changed unit assets.

Use `--init`, `--no-start`, or `--root <dir>` for advanced/staged tests.

To remove the service and init files:

```bash
sudo "$HOME/.nix-profile/bin/ursine-deactivate"
```

Add `--purge` to remove `/etc/ursine` and logs.

## Release tarball

```bash
mkdir -p ursine
tar xzf ursine-vX.Y.Z-x86_64-musl.tar.gz -C ursine
cd ursine
sudo ./install.sh
```

The daemon and `ursinectl` are **fully static musl** (pure Rust since the
shadow-auth switch); the GUI is dynamic musl (needs `libxkbcommon`, present
on every desktop) and targets Alpine/FeralOS. On a glibc distribution the
installer can stage or package the files, but the binaries need a musl
runtime/loader or a distribution-specific build; glibc artifacts are a v6
concern.

The installer:

- installs `ursine` (GUI) and `ursined` (root daemon);
- installs the unit for the detected init system;
- creates `/etc/ursine` and `/var/log/ursine` (mode `0750`);
- enables and starts the daemon unless `--no-start` is passed.

Use `--check` first to print the resolved paths and unit without changing
anything:

```bash
./install.sh --check
```

The installer executes `ursined --version` and requires `auth: shadow`.
Staged installs try the same check; when the target cannot run on the build
host, cross-architecture staging fails unless `--allow-unverified-auth` is
passed; that flag warns and leaves the auth backend unverified. CI runs the
staged binary and asserts `auth: shadow`.

## Paths

Defaults follow the FHS. Every path can be overridden by flag or environment
variable; this is what makes the same installer usable by package builds on
different distributions.

| Flag | Environment | Default | Purpose |
|------|-------------|---------|---------|
| `--prefix` | `PREFIX` | `/usr/local` | Prefix for binaries and libexec |
| `--bindir` | `BINDIR` | `PREFIX/bin` | GUI binary |
| `--sbindir` | `SBINDIR` | `PREFIX/sbin` | Root daemon |
| `--libexecdir` | `LIBEXECDIR` | `PREFIX/lib` | dinit wrapper |
| `--sysconfdir` | `SYSCONFDIR` | `/etc` | Config root (`/etc/ursine/config.toml`) |
| `--localstatedir` | `LOCALSTATEDIR` | `/var` | Audit/log directory |
| `--unitdir` | `UNITDIR` | init-dependent | systemd/OpenRC/dinit service directory |
| `--dinit-config-dir` | `DINIT_CONFIG_DIR` | `/etc/dinit.d/config` | dinit wrapper config |
| `--destdir` | `DESTDIR` | empty | Stage under a package root; no activation |
| `--allow-unverified-auth` | `ALLOW_UNVERIFIED_AUTH` | `0` | Permit cross-architecture staging when the target binary cannot run |

Paths must be absolute and limited to `[A-Za-z0-9/._+-]`. Whitespace, control
characters, quotes, `$`, backticks and `%` are rejected because init systems do
not quote paths consistently and systemd treats `%` as a specifier.

## Init systems

The installer detects systemd, OpenRC and dinit from PID 1 and available
commands. PID 1 wins: installed OpenRC or dinit tooling alone does not select
the backend, so a FeralOS host carrying both packages stays on dinit. Force the
target when cross-building a package:

```bash
# systemd (most distributions)
sudo ./install.sh --init systemd

# OpenRC (Alpine, Gentoo)
sudo ./install.sh --init openrc

# dinit (FeralOS, Artix, Chimera); FeralOS uses /lib/dinit.d
sudo ./install.sh --init dinit --unitdir /lib/dinit.d --libexecdir /usr/lib
```

The dinit layout follows FeralOS conventions:

- service: `UNITDIR/ursined` (usually `/lib/dinit.d/ursined`)
- wrapper: `LIBEXECDIR/dinit/ursined`
- user config: `/etc/dinit.d/config/ursined.conf`

The service uses `smooth-recovery` and depends on the FeralOS (dinit-services)
targets: `depends-on = local.target`, `before = login.target`. The logfile
lives in the `/var/log` fstab subvol, so the service must start after that
mount — this matches feralos-aports. On a dinit distribution with different
target names, rename or drop those two lines. Enabled services start from
`boot.d`; `ursined` binds its socket without requiring D-Bus at startup.

## Package builds (staging)

`--destdir` installs into a package root and skips service activation. Pass
`--init` explicitly: auto-detection on the build host may not match the target.

```bash
# Debian/Fedora-style systemd package
./install.sh --destdir "$pkgdir" --prefix /usr --init systemd \
  --unitdir /usr/lib/systemd/system --no-start

# Alpine/OpenRC package
./install.sh --destdir "$pkgdir" --prefix /usr --init openrc \
  --unitdir /etc/init.d --no-start

# FeralOS dinit package
./install.sh --destdir "$pkgdir" --prefix /usr --init dinit \
  --unitdir /lib/dinit.d --libexecdir /usr/lib --no-start
```

The staged `ursined` is executed when the build host can run it;
cross-architecture staging requires `--allow-unverified-auth`.

## Authentication

The daemon verifies user+password directly against `/etc/shadow`
(Webmin pattern): `pwhash` checks the crypt hash (`$6$` sha512crypt by
default, plus `$5$`/`$1$`/bcrypt) in-process. No PAM, no C libraries —
the daemon and `ursinectl` link fully static. Locked (`!`/`*`), expired
and unsupported-format accounts fail closed; the installer only checks
that `ursined --version` reports `auth: shadow`.

## Nix

`ursine-activate` is the Nix installation path. It copies the daemon to a
root-owned path, so the profile itself never writes to `/etc` or the init
service directory. The activation script targets dinit, OpenRC and systemd
hosts; run the activation command above — no separate release-tarball install
is needed.

## Uninstall

The installer does not remove packages or user data. To remove a manual
install: stop and disable the unit, then remove the binaries,
the unit file, `/etc/ursine`, and `/var/log/ursine`.
