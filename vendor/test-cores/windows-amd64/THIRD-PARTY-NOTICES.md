# Third-party test cores

This directory contains unmodified official Windows amd64 release archives used only for local configuration and real-protocol acceptance tests. MXH-VPS-Deploy verifies each archive with SHA-256 before extracting it into the ignored `.cache/client-cores/` directory.

## Mihomo

- Project: <https://github.com/MetaCubeX/mihomo>
- Vendored release: `v1.19.30`
- Archive: `mihomo-windows-amd64-v1.19.30.zip`
- License: GNU General Public License v3.0 or later; the license text is included as `MIHOMO-LICENSE.txt`.
- Corresponding source: <https://github.com/MetaCubeX/mihomo/tree/v1.19.30> (tag archive: <https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.30.zip>)

## sing-box

- Project: <https://github.com/SagerNet/sing-box>
- Vendored release: `v1.14.0`
- Archive: `sing-box-1.14.0-windows-amd64.zip`
- License: GNU General Public License v3.0 or later with the upstream name-use restriction; the upstream license is included inside the official archive.
- Corresponding source: <https://github.com/SagerNet/sing-box/tree/v1.14.0> (tag archive: <https://github.com/SagerNet/sing-box/archive/refs/tags/v1.14.0.zip>)

The corresponding download URLs and SHA-256 digests are recorded in `checksums.json` and `config/versions.json`. These archives are command-line cores, not GUI applications. Runtime validation never reads Clash Verge AppData and never changes the system proxy or TUN state.

## Mihomo GeoData

- Project: <https://github.com/MetaCubeX/meta-rules-dat>
- Release channel: `latest`, published `2026-08-31T00:44:45Z`; the exact vendored bytes are fixed by SHA-256 in `checksums.json` even though the upstream channel is rolling.
- Files: `mihomo-geodata/GeoSite.dat` and `mihomo-geodata/GeoIP.dat`.
- License: GNU General Public License v3.0; corresponding source and generated-data inputs are available in the upstream repository.

These files are copied into each temporary Mihomo validation directory so authority configurations using `GEOSITE` or `GEOIP` can be checked offline and deterministically.
