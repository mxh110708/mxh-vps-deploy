#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_VERSION:?}"
: "${VPS_PARAM_ASSET_NAME:?}"
: "${VPS_PARAM_SHA256:?}"
: "${VPS_PARAM_SELF_TEST_SCRIPT:?}"

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM
archive="$work/$VPS_PARAM_ASSET_NAME"
url="https://github.com/SagerNet/sing-box/releases/download/v${VPS_PARAM_VERSION#v}/${VPS_PARAM_ASSET_NAME}"
curl --fail --location --silent --show-error --retry 3 --output "$archive" "$url"
printf '%s  %s\n' "$VPS_PARAM_SHA256" "$archive" | sha256sum --check --status
tar -xzf "$archive" -C "$work"
binary="$(find "$work" -type f -name sing-box -print -quit)"
[[ -n "$binary" ]] || { echo 'sing-box probe binary is missing.' >&2; exit 1; }
chmod 0755 "$binary"
self_test="$work/anytls-self-test.sh"
printf '%s' "$VPS_PARAM_SELF_TEST_SCRIPT" > "$self_test"
chmod 0700 "$self_test"
export VPS_PARAM_SING_BOX_BIN="$binary"
bash "$self_test"
