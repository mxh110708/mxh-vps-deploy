#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_BOOTSTRAP_PORT:?}"
: "${VPS_PARAM_SSH_PRIMARY:?}"
: "${VPS_PARAM_SSH_RESCUE:?}"

for port in "$VPS_PARAM_BOOTSTRAP_PORT" "$VPS_PARAM_SSH_PRIMARY" "$VPS_PARAM_SSH_RESCUE"; do
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || {
    echo "Invalid SSH port" >&2
    exit 1
  }
done
[[ "$VPS_PARAM_SSH_PRIMARY" != "$VPS_PARAM_SSH_RESCUE" ]] || {
  echo 'Primary and rescue SSH ports must be different.' >&2
  exit 1
}
mapfile -t ssh_ports < <(printf '%s\n' \
  "$VPS_PARAM_BOOTSTRAP_PORT" "$VPS_PARAM_SSH_PRIMARY" "$VPS_PARAM_SSH_RESCUE" | sort -n -u)
(( ${#ssh_ports[@]} >= 2 )) || { echo 'At least two unique SSH ports are required.' >&2; exit 1; }

stamp="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="/root/vps-deploy-backups/${stamp}/ssh"
managed='/etc/ssh/sshd_config.d/00-00-local-access.conf'
install -d -m 0700 "$backup_dir"
install -d -m 0755 /etc/ssh/sshd_config.d

cp -a /etc/ssh/sshd_config "$backup_dir/sshd_config"
if [[ -f "$managed" ]]; then
  cp -a "$managed" "$backup_dir/00-00-local-access.conf"
fi

if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' /etc/ssh/sshd_config; then
  temporary="$(mktemp)"
  printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf' > "$temporary"
  cat /etc/ssh/sshd_config >> "$temporary"
  install -o root -g root -m 0644 "$temporary" /etc/ssh/sshd_config
  rm -f "$temporary"
fi

while IFS= read -r file; do
  [[ "$file" == "$managed" ]] && continue
  if grep -Eq '^[[:space:]]*(Port|PermitRootLogin|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication)[[:space:]]' "$file"; then
    relative="${file#/}"
    install -d -m 0700 "$backup_dir/$(dirname "$relative")"
    cp -a "$file" "$backup_dir/$relative"
    sed -Ei 's/^([[:space:]]*)(Port|PermitRootLogin|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication)([[:space:]])/\1# VPSDEPLOY disabled \2\3/' "$file"
  fi
done < <(find /etc/ssh -maxdepth 2 -type f \( -path '/etc/ssh/sshd_config' -o -path '/etc/ssh/sshd_config.d/*.conf' \) -print)

{
  for port in "${ssh_ports[@]}"; do
    printf 'Port %s\n' "$port"
  done
  cat <<'EOF'

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
} > "$managed"
chmod 0644 "$managed"

sshd -t
effective="$(sshd -T)"
for port in "${ssh_ports[@]}"; do
  grep -qx "port $port" <<<"$effective" || { echo "Effective SSH port missing: $port" >&2; exit 1; }
done
grep -qx 'pubkeyauthentication yes' <<<"$effective"
grep -qx 'passwordauthentication no' <<<"$effective"
grep -qx 'kbdinteractiveauthentication no' <<<"$effective"
grep -qx 'permitrootlogin without-password' <<<"$effective" || \
  grep -qx 'permitrootlogin prohibit-password' <<<"$effective"

if systemctl is-active --quiet ssh.socket 2>/dev/null; then
  systemctl disable --now ssh.socket
  systemctl enable --now ssh.service
else
  systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
fi
sleep 1
for port in "${ssh_ports[@]}"; do
  ss -H -lntp "sport = :$port" | grep -q sshd || { echo "sshd is not listening on $port" >&2; exit 1; }
done

printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$backup_dir" | base64 | tr -d '\n')"
