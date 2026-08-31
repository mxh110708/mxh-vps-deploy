#!/usr/bin/env bash
set -euo pipefail

emit() {
  local name="$1" value="${2:-}"
  printf 'VPSDEPLOY_%s_B64=%s\n' "$name" "$(printf '%s' "$value" | base64 | tr -d '\n')"
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo 'Root is required.' >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo '/etc/os-release is missing.' >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
os_id="${ID:-unknown}"
os_version="${VERSION_ID:-unknown}"
architecture="$(uname -m)"
kernel="$(uname -r)"
memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
disk_kib="$(df -Pk / | awk 'NR==2 {print $2}')"

service_candidates=(xray sing-box docker containerd podman nginx apache2 caddy x-ui 3x-ui s-ui)
existing_services=()
for service in "${service_candidates[@]}"; do
  unit_names="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}')"
  if grep -Eq "^${service}(\.service)?$" <<< "$unit_names"; then
    existing_services+=("$service")
  fi
done

nft_lines=0
if command -v nft >/dev/null 2>&1; then
  nft_lines="$(nft list ruleset 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
fi

listeners="$(ss -H -lntup 2>/dev/null | awk '{print $5}' | paste -sd ',' -)"
ssh_effective="$(sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) ' || true)"

emit OS_ID "$os_id"
emit OS_VERSION "$os_version"
emit ARCH "$architecture"
emit KERNEL "$kernel"
emit MEMORY_KIB "$memory_kib"
emit DISK_KIB "$disk_kib"
emit EXISTING_SERVICES "$(IFS=,; echo "${existing_services[*]}")"
emit NFT_LINES "$nft_lines"
emit LISTENERS "$listeners"
emit SSH_EFFECTIVE "$ssh_effective"
