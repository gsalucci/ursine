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
  version = "0.40.0";
  url = "https://github.com/skea999/ursine/releases/download/v0.40.0/ursine-v0.40.0-x86_64-musl.tar.gz";
  # sha256 of the tarball (hex, as printed by sha256sum)
  sha256 = "5da33332eb26b2e2bf6086f781a4801574d6bdbd995a43891dd2aed9741eed27";
}
