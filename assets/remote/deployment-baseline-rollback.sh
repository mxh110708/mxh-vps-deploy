#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_BASELINE_DIR:?}"
: "${VPS_PARAM_ADMIN_USER:?}"
root='/root/vps-deploy-transaction-baselines'
baseline="$(readlink -f "$VPS_PARAM_BASELINE_DIR")"
[[ "$(dirname "$baseline")" == "$root" ]]
[[ "$(basename "$baseline")" =~ ^[a-f0-9]{32}$ ]]
[[ -f "$baseline/baseline.complete" && -f "$baseline/files.tar.gz" ]]
[[ "$(cat "$baseline/admin.name")" == "$VPS_PARAM_ADMIN_USER" ]]

for service in xray.service sing-box.service sing-box-anytls.service nginx.service komari-agent.service mxh-certbot-renew.timer vps-deploy-ssh-rollback.timer vps-deploy-ssh-rollback.service; do
  systemctl disable --now "$service" >/dev/null 2>&1 || true
done
rm -f /usr/local/sbin/vps-deploy-ssh-rollback /run/vps-deploy-ssh-cutover-ok

while IFS= read -r path; do
  [[ -n "$path" && "$path" != /* && "$path" != *'..'* ]]
  rm -rf -- "/${path:?}"
done < "$baseline/paths.list"
while IFS= read -r path; do
  [[ -n "$path" && "$path" != /* && "$path" != *'..'* ]]
  rm -rf -- "/${path:?}"
done < "$baseline/absent.list"
tar --numeric-owner -xzpf "$baseline/files.tar.gz" -C /

if [[ "$(cat "$baseline/admin.present")" == 'false' ]]; then
  if id "$VPS_PARAM_ADMIN_USER" >/dev/null 2>&1; then userdel -r "$VPS_PARAM_ADMIN_USER" >/dev/null 2>&1 || userdel "$VPS_PARAM_ADMIN_USER"; fi
else
  shadow_hash="$(cut -d: -f2 "$baseline/admin.shadow")"
  usermod -p "$shadow_hash" "$VPS_PARAM_ADMIN_USER"
  groups="$(tr ' ' ',' < "$baseline/admin.groups")"
  usermod -G "$groups" "$VPS_PARAM_ADMIN_USER"
fi
for account in sing-box sing-box-anytls komari-agent; do
  if [[ "$(cat "$baseline/user-${account}.present")" == 'false' ]] && id "$account" >/dev/null 2>&1; then
    userdel "$account" >/dev/null 2>&1 || true
    getent group "$account" >/dev/null 2>&1 && groupdel "$account" >/dev/null 2>&1 || true
  fi
done

systemctl daemon-reload
if command -v nft >/dev/null 2>&1; then
  nft flush ruleset
  [[ ! -s "$baseline/nftables.ruleset" ]] || nft -f "$baseline/nftables.ruleset"
fi
while IFS=$'\t' read -r key value; do
  [[ -n "$key" ]] || continue
  sysctl -w "$key=$value" >/dev/null 2>&1 || true
done < "$baseline/sysctl.tsv"

while IFS=$'\t' read -r service existed enabled active; do
  [[ "$existed" == 'true' ]] || continue
  [[ "$service" != 'ssh.service' && "$service" != 'ssh.socket' ]] || continue
  if [[ "$enabled" == 'true' ]]; then systemctl enable "$service" >/dev/null 2>&1 || true; else systemctl disable "$service" >/dev/null 2>&1 || true; fi
  if [[ "$active" == 'true' ]]; then systemctl start "$service" >/dev/null 2>&1 || true; else systemctl stop "$service" >/dev/null 2>&1 || true; fi
done < "$baseline/services.tsv"
sshd -t
for service in ssh.service ssh.socket; do
  row="$(awk -F '\t' -v name="$service" '$1 == name { print; exit }' "$baseline/services.tsv")"
  [[ -n "$row" ]] || continue
  IFS=$'\t' read -r _ existed enabled active <<<"$row"
  [[ "$existed" == 'true' ]] || continue
  if [[ "$enabled" == 'true' ]]; then systemctl enable "$service" >/dev/null 2>&1 || true; else systemctl disable "$service" >/dev/null 2>&1 || true; fi
  [[ "$active" == 'true' ]] && systemctl start "$service" >/dev/null 2>&1 || true
done
systemctl reload ssh.service >/dev/null 2>&1 || systemctl reload sshd.service >/dev/null 2>&1 || true
for service in ssh.service ssh.socket; do
  row="$(awk -F '\t' -v name="$service" '$1 == name { print; exit }' "$baseline/services.tsv")"
  [[ -n "$row" ]] || continue
  IFS=$'\t' read -r _ existed enabled active <<<"$row"
  [[ "$existed" == 'true' && "$active" == 'false' ]] && systemctl stop "$service" >/dev/null 2>&1 || true
done
dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u > "$baseline/packages.after"
comm -13 "$baseline/packages.before" "$baseline/packages.after" > "$baseline/packages.preserved"
package_residue_count="$(wc -l < "$baseline/packages.preserved" | tr -d ' ')"
date -u +%FT%TZ > "$baseline/rollback.complete"
printf 'VPSDEPLOY_PACKAGE_RESIDUE_COUNT_B64=%s\n' "$(printf '%s' "$package_residue_count" | base64 | tr -d '\n')"
printf '%s\n' 'VPSDEPLOY_DEPLOYMENT_ROLLBACK_OK'
