# Static analysis exceptions

Active exceptions (owner + expiry required; max 90 days). `deny.toml` is the
machine-readable source of truth; this table explains each entry.

| Item | Reason | Owner | Expiry |
|---|---|---|---|
| `apply`, `cosmic-config`, `cosmic-config-derive`, `cosmic-settings-daemon`, `cosmic-theme`, `dnd`, `iced_accessibility`, `mime 0.1.0` | Upstream git crates ship no license field; source is MIT (COSMIC/iced ecosystem). `cargo-deny` clarifies them as MIT. | skea999 | 2027-01-21 |
| Unmaintained advisories in the pinned libcosmic/iced graph (`basic-toml`, `rustybuzz`, `ttf-parser`, `zbus_names`, `zvariant`, `zvariant_derive`) | Pulled by the pinned libcosmic/iced graph; no maintained release exists at the current pin. Reviewed monthly with the toolchain update. Any advisory outside this list fails CI. | skea999 | 2027-01-21 |
| `cargo audit` also reports `paste` (RUSTSEC-2024-0436) and `pin-utils` (RUSTSEC-2026-0441) | Windows-only backends in the lockfile; the musl target never compiles them (cargo-deny's target filter proves it). Ignored in the audit invocation only, never in `deny.toml`. | skea999 | 2027-01-21 |
| Unsound advisories `lru 0.16.4` (RUSTSEC-2026-0253) and `memmap2 0.8.0` (RUSTSEC-2026-0186) | Reached through `cryoglyph`/`xkbcommon` inside the pinned libcosmic/iced graph; fixed only in versions that are incompatible with that pin. Reviewed monthly. | skea999 | 2027-01-21 |

A new exception requires: rule/tool, file/line, reason, owner, expiry date
(max 90 days), and the compensating control. Expired entries fail the review.

`unsafe-libyaml` is no longer in the graph: YAML validation uses `saphyr`
(pure safe Rust), and `serde_yaml`/`serde_yaml_ng` were removed.
