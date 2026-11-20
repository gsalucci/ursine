# Pinned musl release artifact consumed by flake.nix.
#
# WHY a prebuilt tarball: nixpkgs does not cache pkgsMusl/pkgsStatic tools
# (stable included) — a source build would compile the musl toolchain for
# hours on every CI run. The artifact is built in the Alpine CI container
# (same libc, fast) and pinned here: static daemon+CLI, dynamic GUI.
#
# RELEASE CHECKLIST: CI updates version/url/sha256 on every `v*` tag; keep this
# as the manual fallback.
#   sha256sum ursine-<ver>-x86_64-musl.tar.gz
{
  version = "0.46.0";
  url = "https://github.com/skea999/ursine/releases/download/v0.46.0/ursine-v0.46.0-x86_64-musl.tar.gz";
  # sha256 of the tarball (hex, as printed by sha256sum)
  sha256 = "93a0969880c2eeef3ea55ff645099d3e6310d47df6aee9280c6f996aed532a36";
}
