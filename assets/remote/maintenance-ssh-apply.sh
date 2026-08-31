#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_OLD_PORTS:?}"
: "${VPS_PARAM_NEW_PRIMARY:?}"
: "${VPS_PARAM_NEW_RESCUE:?}"
: "${VPS_PARAM_NEW_PUBLIC_KEY:?}"
: "${VPS_PARAM_ADMIN_USER:?}"
for port in ${VPS_PARAM_OLD_PORTS//,/ } "$VPS_PARAM_NEW_PRIMARY" "$VPS_PARAM_NEW_RESCUE"; do
  [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535))
done
[[ "$VPS_PARAM_NEW_PUBLIC_KEY" == ssh-ed25519\ * ]]
[[ "$VPS_PARAM_ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]
stamp="$(date -u +%Y%m%d-%H%M%S)"; backup="/root/vps-deploy-backups/${stamp}/ssh-maintenance"
install -d -m 0700 "$backup"
cp -a /etc/ssh "$backup/etc-ssh"
cp -a /root/.ssh/authorized_keys "$backup/root-authorized_keys"
if id "$VPS_PARAM_ADMIN_USER" >/dev/null 2>&1; then
  home="$(getent passwd "$VPS_PARAM_ADMIN_USER" | cut -d: -f6)"
  [[ ! -f "$home/.ssh/authorized_keys" ]] || cp -a "$home/.ssh/authorized_keys" "$backup/admin-authorized_keys"
fi
cat > "$backup/rollback" <<EOF
#!/usr/bin/env bash
set -euo pipefail
rm -rf /etc/ssh
cp -a '$backup/etc-ssh' /etc/ssh
cp -a '$backup/root-authorized_keys' /root/.ssh/authorized_keys
if [[ -f '$backup/admin-authorized_keys' ]]; then
  home="\$(getent passwd '$VPS_PARAM_ADMIN_USER' | cut -d: -f6)"
  cp -a '$backup/admin-authorized_keys' "\$home/.ssh/authorized_keys"
fi
sshd -t
systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
EOF
chmod 0700 "$backup/rollback"
cat > /etc/systemd/system/mxh-ssh-maintenance-rollback.service <<EOF
[Service]
Type=oneshot
ExecStart=$backup/rollback
EOF
cat > /etc/systemd/system/mxh-ssh-maintenance-rollback.timer <<'EOF'
[Timer]
OnActiveSec=10min
AccuracySec=1s
Unit=mxh-ssh-maintenance-rollback.service
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now mxh-ssh-maintenance-rollback.timer >/dev/null

for user in root "$VPS_PARAM_ADMIN_USER"; do
  id "$user" >/dev/null 2>&1 || continue
  home="$(getent passwd "$user" | cut -d: -f6)"
  install -d -o "$user" -g "$(id -gn "$user")" -m 0700 "$home/.ssh"
  touch "$home/.ssh/authorized_keys"; chown "$user:$(id -gn "$user")" "$home/.ssh/authorized_keys"; chmod 0600 "$home/.ssh/authorized_keys"
  if ! grep -qxF "$VPS_PARAM_NEW_PUBLIC_KEY" "$home/.ssh/authorized_keys"; then
    [[ ! -s "$home/.ssh/authorized_keys" ]] || printf '\n' >> "$home/.ssh/authorized_keys"
    printf '%s\n' "$VPS_PARAM_NEW_PUBLIC_KEY" >> "$home/.ssh/authorized_keys"
  fi
done
managed=/etc/ssh/sshd_config.d/00-00-local-access.conf
install -d -m 0755 /etc/ssh/sshd_config.d
{
  for port in ${VPS_PARAM_OLD_PORTS//,/ } "$VPS_PARAM_NEW_PRIMARY" "$VPS_PARAM_NEW_RESCUE"; do printf '%s\n' "$port"; done |
    sort -nu | sed 's/^/Port /'
  printf '%s\n' 'PubkeyAuthentication yes' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin prohibit-password'
} > "$managed"
chmod 0644 "$managed"; sshd -t
systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$backup" | base64 | tr -d '\n')"
printf '%s\n' 'VPSDEPLOY_SSH_MAINTENANCE_STAGED'
