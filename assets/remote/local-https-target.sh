#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_DOMAIN:?}"
: "${VPS_PARAM_PORT:?}"
: "${VPS_PARAM_CERT_NAME:?}"

cert_dir='/etc/mxh-tls/reality-target'
[[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] || {
  echo 'Reality target certificate files are missing.' >&2
  exit 1
}

nginx_install_guard='yes'
cleanup() {
  local status="$?"
  if [[ "$status" -ne 0 && "$nginx_install_guard" == 'yes' ]]; then
    set +e
    systemctl stop nginx.service >/dev/null 2>&1
    systemctl unmask nginx.service >/dev/null 2>&1
  fi
  exit "$status"
}
trap cleanup EXIT

stamp="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="/root/vps-deploy-backups/${stamp}/local-https-target"
install -d -m 0700 "$backup_dir"
for existing in \
  /etc/nginx/sites-available/mxh-reality-target \
  /etc/nginx/sites-enabled/mxh-reality-target \
  /etc/nginx/sites-enabled/default; do
  if [[ -e "$existing" || -L "$existing" ]]; then
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
apt_get_retry update -qq
# Prevent the package post-install script from exposing the distribution's
# default port-80 site before the loopback-only configuration is ready.
systemctl stop nginx.service >/dev/null 2>&1 || true
systemctl mask nginx.service >/dev/null 2>&1 || true
apt_get_retry install -y -qq nginx openssl curl >/dev/null
! ss -H -lntp "sport = :80" | grep -F nginx >/dev/null
! ss -H -lntp "sport = :443" | grep -F nginx >/dev/null
systemctl unmask nginx.service >/dev/null
rm -f /etc/nginx/sites-enabled/default
install -d -o root -g root -m 0755 /var/www/mxh-reality-target
cat > /var/www/mxh-reality-target/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Service Portal</title></head>
<body><main><h1>Service Portal</h1><p>This endpoint is operating normally.</p></main></body>
</html>
EOF
chmod 0644 /var/www/mxh-reality-target/index.html

cat > /etc/nginx/sites-available/mxh-reality-target <<EOF
server {
    # Debian 12 ships nginx 1.22, which requires the legacy listen-parameter
    # form. This remains valid on newer nginx releases as well.
    listen 127.0.0.1:${VPS_PARAM_PORT} ssl http2;
    listen [::1]:${VPS_PARAM_PORT} ssl http2;
    server_name ${VPS_PARAM_DOMAIN};

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols TLSv1.3;
    ssl_session_tickets off;
    server_tokens off;

    root /var/www/mxh-reality-target;
    location / { try_files \$uri /index.html; }
}
EOF
ln -sfn /etc/nginx/sites-available/mxh-reality-target /etc/nginx/sites-enabled/mxh-reality-target
nginx -t
systemctl enable nginx.service >/dev/null
systemctl restart nginx.service
systemctl is-active --quiet nginx.service

ss -H -lntp "sport = :${VPS_PARAM_PORT}" | grep -F nginx >/dev/null
! ss -H -lntp "sport = :80" | grep -F nginx >/dev/null
! ss -H -lntp "sport = :443" | grep -F nginx >/dev/null

tls_result="$(echo | openssl s_client -connect "127.0.0.1:${VPS_PARAM_PORT}" \
  -servername "$VPS_PARAM_DOMAIN" -alpn h2 -verify_hostname "$VPS_PARAM_DOMAIN" 2>/dev/null)"
grep -Fq 'Verify return code: 0 (ok)' <<<"$tls_result"
grep -Fq 'ALPN protocol: h2' <<<"$tls_result"
curl --fail --silent --show-error --max-time 15 \
  --resolve "${VPS_PARAM_DOMAIN}:${VPS_PARAM_PORT}:127.0.0.1" \
  "https://${VPS_PARAM_DOMAIN}:${VPS_PARAM_PORT}/" >/dev/null

nginx_install_guard='no'

printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$backup_dir" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_LOCAL_HTTPS_OK\n'
