#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_ADMIN_USER:?}"; : "${VPS_PARAM_PUBLIC_KEY:?}"
[[ "$VPS_PARAM_ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; [[ "$VPS_PARAM_PUBLIC_KEY" == ssh-ed25519\ * ]]
id "$VPS_PARAM_ADMIN_USER" >/dev/null
home="$(getent passwd "$VPS_PARAM_ADMIN_USER" | cut -d: -f6)"; group="$(id -gn "$VPS_PARAM_ADMIN_USER")"
install -d -o "$VPS_PARAM_ADMIN_USER" -g "$group" -m 0700 "$home/.ssh"
touch "$home/.ssh/authorized_keys"; chown "$VPS_PARAM_ADMIN_USER:$group" "$home/.ssh/authorized_keys"; chmod 0600 "$home/.ssh/authorized_keys"
if ! grep -qxF "$VPS_PARAM_PUBLIC_KEY" "$home/.ssh/authorized_keys"; then
  [[ ! -s "$home/.ssh/authorized_keys" ]] || printf '\n' >> "$home/.ssh/authorized_keys"
  printf '%s\n' "$VPS_PARAM_PUBLIC_KEY" >> "$home/.ssh/authorized_keys"
fi
printf '%s\n' 'VPSDEPLOY_IMPORT_ADMIN_KEY_OK'
