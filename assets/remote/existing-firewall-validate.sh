#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/nftables.conf ]]; then
  command -v nft >/dev/null
  nft -c -f /etc/nftables.conf
fi
printf '%s\n' 'VPSDEPLOY_EXISTING_FIREWALL_OK'
