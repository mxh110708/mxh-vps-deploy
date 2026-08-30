#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_ADMIN_USER:?}"
: "${VPS_PARAM_ADMIN_PASSWORD:?}"
: "${VPS_PARAM_PUBLIC_KEY:?}"

export DEBIAN_FRONTEND=noninteractive
apt_get_retry() {
  local attempt output status
  for attempt in 1 2 3 4 5 6; do
    set +e
    output="$(apt-get -o DPkg::Lock::Timeout=60 "$@" 2>&1)"
    status="$?"
    set -e
    if [[ "$status" -eq 0 ]]; then printf '%s\n' "$output"; return 0; fi
    if ! grep -Eqi 'could not get lock|unable to acquire.*lock|is another process using it' <<<"$output"; then printf '%s\n' "$output" >&2; return "$status"; fi
    printf 'Waiting for apt/dpkg lock (attempt %s/6).\n' "$attempt" >&2
    sleep 5
  done
  printf '%s\n' "$output" >&2
  return "$status"
}
apt_get_retry update
apt_get_retry install -y --no-install-recommends \
  ca-certificates curl dnsutils iproute2 jq nftables openssl python3 sudo tar unzip

if systemctl is-active --quiet chrony.service 2>/dev/null || \
   systemctl is-active --quiet chronyd.service 2>/dev/null; then
  :
elif systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
  systemctl enable --now systemd-timesyncd.service
  timedatectl set-ntp true || true
else
  apt_get_retry install -y --no-install-recommends systemd-timesyncd
  systemctl enable --now systemd-timesyncd.service
  timedatectl set-ntp true || true
fi

if ! id "$VPS_PARAM_ADMIN_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$VPS_PARAM_ADMIN_USER"
fi
usermod -aG sudo "$VPS_PARAM_ADMIN_USER"
printf '%s:%s\n' "$VPS_PARAM_ADMIN_USER" "$VPS_PARAM_ADMIN_PASSWORD" | chpasswd

install -d -o root -g root -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
grep -qxF "$VPS_PARAM_PUBLIC_KEY" /root/.ssh/authorized_keys || \
  printf '%s\n' "$VPS_PARAM_PUBLIC_KEY" >> /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

admin_home="$(getent passwd "$VPS_PARAM_ADMIN_USER" | cut -d: -f6)"
admin_group="$(id -gn "$VPS_PARAM_ADMIN_USER")"
install -d -o "$VPS_PARAM_ADMIN_USER" -g "$admin_group" -m 0700 "$admin_home/.ssh"
touch "$admin_home/.ssh/authorized_keys"
grep -qxF "$VPS_PARAM_PUBLIC_KEY" "$admin_home/.ssh/authorized_keys" || \
  printf '%s\n' "$VPS_PARAM_PUBLIC_KEY" >> "$admin_home/.ssh/authorized_keys"
chown "$VPS_PARAM_ADMIN_USER:$admin_group" "$admin_home/.ssh/authorized_keys"
chmod 0600 "$admin_home/.ssh/authorized_keys"

sshd -t
printf 'VPSDEPLOY_BASE_OK\n'
