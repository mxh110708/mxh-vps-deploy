#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_PUBLIC_NAME:?}"
binary="${VPS_PARAM_SING_BOX_BIN:-/usr/local/bin/sing-box-anytls}"
[[ -x "$binary" ]] || { echo 'sing-box AnyTLS binary is unavailable.' >&2; exit 1; }

output="$("$binary" generate ech-keypair "$VPS_PARAM_PUBLIC_NAME")"
config="$(awk '/-----BEGIN ECH CONFIGS-----/{capture=1} capture{print} /-----END ECH CONFIGS-----/{exit}' <<<"$output")"
keys="$(awk '/-----BEGIN ECH KEYS-----/{capture=1} capture{print} /-----END ECH KEYS-----/{exit}' <<<"$output")"
[[ "$config" == *'BEGIN ECH CONFIGS'* && "$config" == *'END ECH CONFIGS'* ]]
[[ "$keys" == *'BEGIN ECH KEYS'* && "$keys" == *'END ECH KEYS'* ]]
printf 'VPSDEPLOY_ECH_CONFIG_B64=%s\n' "$(printf '%s\n' "$config" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_ECH_KEYS_B64=%s\n' "$(printf '%s\n' "$keys" | base64 | tr -d '\n')"
