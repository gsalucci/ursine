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
  version = "0.39.3";
  url = "https://github.com/skea999/ursine/releases/download/v0.39.3/ursine-v0.39.3-x86_64-musl.tar.gz";
  # sha256 of the tarball (hex, as printed by sha256sum)
  sha256 = "7fcb2cf2f494bfbc80e8f45406ddf57fcb0b74f7db2a6ec60065223a2de54bf2";
}
