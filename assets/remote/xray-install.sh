#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_VERSION:?}"
: "${VPS_PARAM_INSTALLER_URL:?}"
: "${VPS_PARAM_INSTALLER_SHA256:?}"

temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT
curl --fail --location --silent --show-error --retry 3 --output "$temporary" "$VPS_PARAM_INSTALLER_URL"
printf '%s  %s\n' "$VPS_PARAM_INSTALLER_SHA256" "$temporary" | sha256sum --check --status
bash "$temporary" install --version "v${VPS_PARAM_VERSION#v}"

actual="$(/usr/local/bin/xray version | awk 'NR==1 {print $2}')"
[[ "${actual#v}" == "${VPS_PARAM_VERSION#v}" ]] || {
  echo "Unexpected Xray version" >&2
  exit 1
}
systemctl enable xray.service
printf 'VPSDEPLOY_XRAY_VERSION_B64=%s\n' "$(printf '%s' "$actual" | base64 | tr -d '\n')"
