#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_NEW_PRIMARY:?}"; : "${VPS_PARAM_NEW_RESCUE:?}"; : "${VPS_PARAM_NEW_PUBLIC_KEY:?}"
old_public="${VPS_PARAM_OLD_PUBLIC_KEY:-}"; admin="${VPS_PARAM_ADMIN_USER:-root}"
managed=/etc/ssh/sshd_config.d/00-00-local-access.conf
cat > "$managed" <<EOF
Port ${VPS_PARAM_NEW_PRIMARY}
Port ${VPS_PARAM_NEW_RESCUE}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
if [[ -n "$old_public" && "$old_public" != "$VPS_PARAM_NEW_PUBLIC_KEY" ]]; then
  for user in root "$admin"; do
    id "$user" >/dev/null 2>&1 || continue
    home="$(getent passwd "$user" | cut -d: -f6)"; file="$home/.ssh/authorized_keys"
    [[ ! -f "$file" ]] || sed -i "\|^${old_public//|/\\|}$|d" "$file"
  done
fi
sshd -t; systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
systemctl disable --now mxh-ssh-maintenance-rollback.timer >/dev/null 2>&1 || true
printf '%s\n' 'VPSDEPLOY_SSH_MAINTENANCE_COMMITTED'
