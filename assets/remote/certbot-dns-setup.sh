#!/usr/bin/env bash
set -Eeuo pipefail

phase='initialization'
emit_safe_error() {
  local message="$1"
  printf 'VPSDEPLOY_CERTBOT_SAFE_ERROR_B64=%s\n' "$(printf '%s' "$message" | base64 | tr -d '\n')"
}
report_failure() {
  local status="$?"
  trap - ERR
  emit_safe_error "Certbot DNS-01 在阶段 ${phase} 失败（退出码 ${status}）；敏感输出已隐藏。请修复该阶段后继续未完成部署。"
  exit "$status"
}
trap report_failure ERR

: "${VPS_PARAM_CLOUDFLARE_TOKEN:?}"
: "${VPS_PARAM_ZONE_NAME:?}"
: "${VPS_PARAM_EMAIL:?}"
anytls_enabled="${VPS_PARAM_ANYTLS_ENABLED:-false}"
reality_enabled="${VPS_PARAM_REALITY_ENABLED:-false}"
propagation_seconds="${VPS_PARAM_PROPAGATION_SECONDS:-30}"

[[ "$anytls_enabled" == 'true' || "$reality_enabled" == 'true' ]] || {
  echo 'No trusted TLS certificate was requested.' >&2
  exit 1
}

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
zone_json="$work/zone.json"
phase='cloudflare-zone-api'
set +e
zone_meta="$(curl --silent --show-error --get --output "$zone_json" \
  --write-out $'%{http_code}\t%{local_ip}' \
  --header "Authorization: Bearer ${VPS_PARAM_CLOUDFLARE_TOKEN}" \
  --data-urlencode "name=${VPS_PARAM_ZONE_NAME}" \
  'https://api.cloudflare.com/client/v4/zones')"
zone_curl_status="$?"
set -e
if [[ "$zone_curl_status" -ne 0 ]]; then
  safe_error='Cloudflare Zone API 连接失败；请检查 VPS 的 DNS、IPv4/IPv6 出口和到 api.cloudflare.com 的 HTTPS 连通性。'
  emit_safe_error "$safe_error"
  exit 20
fi
zone_http="${zone_meta%%$'\t'*}"
zone_local_ip="${zone_meta#*$'\t'}"
zone_error="$(python3 - "$zone_json" "$zone_http" "$zone_local_ip" <<'PY'
import json
import sys

path, http_status, local_ip = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    print(f"Cloudflare Zone API 返回了不可解析响应（HTTP {http_status}）。")
    raise SystemExit

results = data.get("result") or []
if data.get("success") and len(results) == 1:
    raise SystemExit

codes = ",".join(str(item.get("code")) for item in (data.get("errors") or []) if isinstance(item, dict)) or "unknown"
family = "IPv6" if ":" in local_ip else "IPv4"
print(
    f"Cloudflare Zone API 拒绝 Token（HTTP {http_status} / code {codes}；"
    f"实际请求源地址 {local_ip}，{family}）。请确认 Token 为有效 API Token、"
    "包含 Zone:Read 与 DNS:Edit，并把该 VPS 实际使用的 IPv4/IPv6 地址加入客户端 IP 筛选。"
)
PY
)"
if [[ -n "$zone_error" ]]; then
  emit_safe_error "$zone_error"
  exit 21
fi

phase='backup-existing-certbot-state'
stamp="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="/root/vps-deploy-backups/${stamp}/certbot-dns"
install -d -m 0700 "$backup_dir"
for existing in \
  /etc/letsencrypt/cloudflare.ini \
  /usr/local/libexec/mxh-certbot-deploy \
  /etc/systemd/system/mxh-certbot-renew.service \
  /etc/systemd/system/mxh-certbot-renew.timer; do
  if [[ -f "$existing" ]]; then
    cp -a "$existing" "$backup_dir/$(basename "$existing")"
  fi
done

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
phase='apt-update'
apt_get_retry update -qq
phase='apt-install-certbot'
apt_get_retry install -y -qq certbot python3-certbot-dns-cloudflare ca-certificates >/dev/null
phase='certbot-runtime-validation'
certbot_plugins="$(certbot plugins 2>/dev/null)"
grep -Fq 'dns-cloudflare' <<< "$certbot_plugins"
# The distribution timer does not run our explicit deploy hook. Keep a single
# renewal owner so a renewed certificate is always copied and the service is
# reloaded in the same transaction.
systemctl disable --now certbot.timer >/dev/null 2>&1 || true

phase='cloudflare-credentials-install'
install -d -o root -g root -m 0700 /etc/letsencrypt
credentials_tmp="$work/cloudflare.ini"
printf 'dns_cloudflare_api_token = %s\n' "$VPS_PARAM_CLOUDFLARE_TOKEN" > "$credentials_tmp"
install -o root -g root -m 0600 "$credentials_tmp" /etc/letsencrypt/cloudflare.ini

install -d -o root -g root -m 0755 /usr/local/libexec
cat > /usr/local/libexec/mxh-certbot-deploy <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

: "${RENEWED_LINEAGE:?}"
cert_name="$(basename "$RENEWED_LINEAGE")"
case "$cert_name" in
  mxh-anytls)
    destination='/etc/mxh-tls/anytls'
    group='sing-box-anytls'
    ;;
  mxh-reality-target)
    destination='/etc/mxh-tls/reality-target'
    group='root'
    ;;
  *)
    exit 0
    ;;
esac

getent group "$group" >/dev/null 2>&1 || groupadd --system "$group"
install -d -o root -g "$group" -m 0750 "$destination"
fullchain_tmp="$(mktemp -p "$destination" .fullchain.XXXXXX)"
privkey_tmp="$(mktemp -p "$destination" .privkey.XXXXXX)"
cleanup() { rm -f "$fullchain_tmp" "$privkey_tmp"; }
trap cleanup EXIT
install -o root -g "$group" -m 0644 "$RENEWED_LINEAGE/fullchain.pem" "$fullchain_tmp"
install -o root -g "$group" -m 0640 "$RENEWED_LINEAGE/privkey.pem" "$privkey_tmp"
mv -f "$fullchain_tmp" "$destination/fullchain.pem"
mv -f "$privkey_tmp" "$destination/privkey.pem"

if [[ "$cert_name" == 'mxh-anytls' ]] && systemctl is-active --quiet sing-box-anytls.service; then
  /usr/local/bin/sing-box-anytls check -c /etc/sing-box-anytls/config.json
  systemctl restart sing-box-anytls.service
fi
if [[ "$cert_name" == 'mxh-reality-target' ]] && systemctl is-active --quiet nginx.service; then
  nginx -t
  systemctl reload nginx.service
fi
HOOK
chmod 0750 /usr/local/libexec/mxh-certbot-deploy

cat > /etc/systemd/system/mxh-certbot-renew.service <<'EOF'
[Unit]
Description=MXH Certbot DNS-01 certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --no-random-sleep-on-renew --deploy-hook /usr/local/libexec/mxh-certbot-deploy
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

cat > /etc/systemd/system/mxh-certbot-renew.timer <<'EOF'
[Unit]
Description=Run MXH Certbot renewal twice daily

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
chmod 0644 /etc/systemd/system/mxh-certbot-renew.service /etc/systemd/system/mxh-certbot-renew.timer

issue_certificate() {
  local cert_name="$1"
  local domains_csv="$2"
  local -a domain_args=()
  local domain
  IFS=',' read -r -a domains <<<"$domains_csv"
  for domain in "${domains[@]}"; do
    [[ -n "$domain" ]] || continue
    domain_args+=('-d' "$domain")
  done
  [[ "${#domain_args[@]}" -gt 0 ]] || { echo 'Certificate domain list is empty.' >&2; exit 1; }

  phase='certificate-issuance'
  certbot certonly \
    --non-interactive --agree-tos --email "$VPS_PARAM_EMAIL" \
    --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    --dns-cloudflare-propagation-seconds "$propagation_seconds" \
    --key-type ecdsa --elliptic-curve secp256r1 \
    --cert-name "$cert_name" --keep-until-expiring \
    "${domain_args[@]}" >/dev/null
  phase='certificate-deploy-hook'
  RENEWED_LINEAGE="/etc/letsencrypt/live/$cert_name" \
    RENEWED_DOMAINS="$domains_csv" /usr/local/libexec/mxh-certbot-deploy
  phase='certificate-renewal-dry-run'
  certbot renew --cert-name "$cert_name" --dry-run --quiet --no-random-sleep-on-renew >/dev/null
}

if [[ "$anytls_enabled" == 'true' ]]; then
  : "${VPS_PARAM_ANYTLS_CERT_NAME:?}"
  : "${VPS_PARAM_ANYTLS_DOMAINS:?}"
  issue_certificate "$VPS_PARAM_ANYTLS_CERT_NAME" "$VPS_PARAM_ANYTLS_DOMAINS"
fi
if [[ "$reality_enabled" == 'true' ]]; then
  : "${VPS_PARAM_REALITY_CERT_NAME:?}"
  : "${VPS_PARAM_REALITY_DOMAINS:?}"
  issue_certificate "$VPS_PARAM_REALITY_CERT_NAME" "$VPS_PARAM_REALITY_DOMAINS"
fi

phase='renewal-timer-validation'
systemctl daemon-reload
systemctl enable --now mxh-certbot-renew.timer >/dev/null
systemctl is-enabled --quiet mxh-certbot-renew.timer
systemctl is-active --quiet mxh-certbot-renew.timer
! systemctl is-active --quiet certbot.timer
[[ "$(stat -c '%a' /etc/letsencrypt/cloudflare.ini)" == '600' ]]

certbot_version="$(certbot --version 2>&1 | awk '{print $2}')"
printf 'VPSDEPLOY_CERTBOT_VERSION_B64=%s\n' "$(printf '%s' "$certbot_version" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$backup_dir" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_CERTBOT_DNS_OK\n'
