#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_ADMIN_USER:?}"
[[ "$VPS_PARAM_ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]

home="$(getent passwd "$VPS_PARAM_ADMIN_USER" | cut -d: -f6)"
[[ -n "$home" ]]
printf 'ROOT_KEY_LINES=%s\n' "$(grep -cve '^[[:space:]]*$' /root/.ssh/authorized_keys 2>/dev/null || true)"
printf 'ADMIN_HOME=%s\n' "$home"
stat -c 'ADMIN_SSH=%U:%G:%a' "$home/.ssh"
stat -c 'ADMIN_KEYS=%U:%G:%a' "$home/.ssh/authorized_keys"
printf 'ADMIN_KEY_LINES=%s\n' "$(grep -cve '^[[:space:]]*$' "$home/.ssh/authorized_keys" 2>/dev/null || true)"
sshd -T -C "user=$VPS_PARAM_ADMIN_USER,host=localhost,addr=127.0.0.1" |
  grep -E '^(allowusers|denyusers|authorizedkeysfile|pubkeyauthentication|authenticationmethods|permitrootlogin|passwordauthentication|strictmodes) '
printf 'ROLLBACK_TIMER_ACTIVE=%s\n' "$(systemctl is-active mxh-ssh-maintenance-rollback.timer 2>/dev/null || true)"
printf 'ROLLBACK_TIMER_ENABLED=%s\n' "$(systemctl is-enabled mxh-ssh-maintenance-rollback.timer 2>/dev/null || true)"
printf '%s\n' 'VPSDEPLOY_SSH_MAINTENANCE_AUDIT_OK'
