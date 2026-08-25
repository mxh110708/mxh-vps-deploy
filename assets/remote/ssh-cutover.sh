#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_SSH_PRIMARY:?}"
: "${VPS_PARAM_SSH_RESCUE:?}"

managed='/etc/ssh/sshd_config.d/00-00-local-access.conf'
stamp="$(date -u +%Y%m%d-%H%M%S)"
backup="/root/vps-deploy-backups/${stamp}/ssh-cutover/00-00-local-access.conf"
install -d -m 0700 "$(dirname "$backup")"
cp -a "$managed" "$backup"

cat > /usr/local/sbin/vps-deploy-ssh-rollback <<EOF
#!/usr/bin/env bash
set -eu
if [[ ! -e /run/vps-deploy-ssh-cutover-ok ]]; then
  cp -a '$backup' '$managed'
  sshd -t
  systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
fi
EOF
chmod 0700 /usr/local/sbin/vps-deploy-ssh-rollback
rm -f /run/vps-deploy-ssh-cutover-ok
systemctl stop vps-deploy-ssh-rollback.timer vps-deploy-ssh-rollback.service 2>/dev/null || true
systemd-run --unit=vps-deploy-ssh-rollback --on-active=5m /usr/local/sbin/vps-deploy-ssh-rollback >/dev/null

cat > "$managed" <<EOF
Port ${VPS_PARAM_SSH_PRIMARY}
Port ${VPS_PARAM_SSH_RESCUE}

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
chmod 0644 "$managed"
sshd -t
systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
sleep 1
effective="$(sshd -T)"
ports="$(awk '$1=="port" {print $2}' <<<"$effective" | sort -n | uniq | paste -sd, -)"
expected="$(printf '%s\n%s\n' "$VPS_PARAM_SSH_PRIMARY" "$VPS_PARAM_SSH_RESCUE" | sort -n | paste -sd, -)"
[[ "$ports" == "$expected" ]] || { echo "Unexpected effective SSH ports: $ports" >&2; exit 1; }
printf 'VPSDEPLOY_CUTOVER_PENDING\n'
