#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_TARGET:?}"
: "${VPS_PARAM_SAMPLES:?}"
: "${VPS_PARAM_MAX_MEDIAN_MS:?}"

target="$VPS_PARAM_TARGET"
samples="$VPS_PARAM_SAMPLES"
[[ "$samples" =~ ^[0-9]+$ ]] && (( samples >= 5 && samples <= 100 )) || exit 1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

getent ahostsv4 "$target" > "$work/addresses.txt" || true
dig +short CNAME "$target" > "$work/cname.txt" || true

if ! timeout 20 openssl s_client -4 -connect "${target}:443" -servername "$target" \
    -verify_return_error -tls1_3 -alpn h2 </dev/null > "$work/tls.txt" 2>&1; then
  tls_command_ok=false
else
  tls_command_ok=true
fi

tls13=false
alpn_h2=false
verify_ok=false
grep -Eq 'Protocol[^:]*:[[:space:]]*TLSv1\.3|New, TLSv1\.3' "$work/tls.txt" && tls13=true
grep -Eq 'ALPN protocol:[[:space:]]*h2' "$work/tls.txt" && alpn_h2=true
grep -Eq 'Verify return code:[[:space:]]*0 \(ok\)' "$work/tls.txt" && verify_ok=true

curl -4sS --connect-timeout 10 --max-time 20 -D "$work/headers.txt" -o /dev/null \
  -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140 Safari/537.36' \
  -w '%{http_code}\t%{http_version}\t%{remote_ip}\t%{url_effective}\n' \
  "https://${target}/" > "$work/http.txt" || true

: > "$work/timings.tsv"
failures=0
for ((i=1; i<=samples; i++)); do
  if value="$(curl -4sS -o /dev/null --connect-timeout 10 --max-time 20 \
      -w '%{time_namelookup}\t%{time_connect}\t%{time_appconnect}' "https://${target}/")"; then
    printf '%s\n' "$value" >> "$work/timings.tsv"
  else
    failures=$((failures + 1))
  fi
done

python3 - "$target" "$samples" "$failures" "$VPS_PARAM_MAX_MEDIAN_MS" \
  "$tls_command_ok" "$tls13" "$alpn_h2" "$verify_ok" "$work" <<'PY'
import base64
import json
from pathlib import Path
import statistics
import sys
from urllib.parse import urljoin, urlparse

target, samples, failures, max_median, tls_command_ok, tls13, alpn_h2, verify_ok, work = sys.argv[1:]
root = Path(work)
timings = []
for line in root.joinpath("timings.tsv").read_text().splitlines():
    parts = line.split("\t")
    if len(parts) != 3:
        continue
    name_lookup, tcp_connected, tls_connected = map(float, parts)
    timings.append({
        "dns": max(0.0, name_lookup * 1000),
        "tcp": max(0.0, (tcp_connected - name_lookup) * 1000),
        "tls": max(0.0, tls_connected * 1000),
    })

dns_times = sorted(item["dns"] for item in timings)
tcp_times = sorted(item["tcp"] for item in timings)
tls_times = sorted(item["tls"] for item in timings)

def percentile(values, fraction):
    if not values:
        return None
    index = max(0, min(len(values) - 1, int((len(values) * fraction) + 0.999999) - 1))
    return round(values[index], 2)

http_parts = root.joinpath("http.txt").read_text().strip().split("\t")
while len(http_parts) < 4:
    http_parts.append("")
code, http_version, remote_ip, effective_url = http_parts[:4]
cname = root.joinpath("cname.txt").read_text().strip()
headers = root.joinpath("headers.txt").read_text(errors="replace")
cdn_text = (cname + "\n" + headers).lower()
cdn_patterns = [
    "cloudflare", "cf-ray", "cloudfront.net", "x-amz-cf-", "fastly",
    "x-served-by", "akama", "imperva", "incapsula", "gcore"
]
cdn_hits = sorted({pattern for pattern in cdn_patterns if pattern in cdn_text})
effective_host = urlparse(effective_url).hostname or ""
location = ""
for line in headers.splitlines():
    if line.lower().startswith("location:"):
        location = line.split(":", 1)[1].strip()
        break
location_host = urlparse(urljoin(f"https://{target}/", location)).hostname or ""
cross_host_redirect = bool(
    (effective_host and effective_host.lower() != target.lower()) or
    (location_host and location_host.lower() != target.lower())
)
def median(values):
    return round(statistics.median(values), 2) if values else None

tcp_median = median(tcp_times)

result = {
    "target": target,
    "sample_count": int(samples),
    "success_count": len(timings),
    "failure_count": int(failures),
    "latency_gate_metric": "tcp_connect_excluding_dns",
    "median_ms": tcp_median,
    "p95_ms": percentile(tcp_times, 0.95),
    "max_ms": round(max(tcp_times), 2) if tcp_times else None,
    "dns_median_ms": median(dns_times),
    "tcp_connect_median_ms": tcp_median,
    "tcp_connect_p95_ms": percentile(tcp_times, 0.95),
    "tcp_connect_max_ms": round(max(tcp_times), 2) if tcp_times else None,
    "tls_appconnect_median_ms": median(tls_times),
    "tls_appconnect_p95_ms": percentile(tls_times, 0.95),
    "tls_appconnect_max_ms": round(max(tls_times), 2) if tls_times else None,
    "tls_command_ok": tls_command_ok == "true",
    "tls13": tls13 == "true",
    "alpn_h2": alpn_h2 == "true",
    "certificate_verify_ok": verify_ok == "true",
    "http_code": int(code) if code.isdigit() else 0,
    "http_version": http_version,
    "remote_ip": remote_ip,
    "effective_url": effective_url,
    "location": location,
    "cross_host_redirect": cross_host_redirect,
    "cname": cname,
    "shared_cdn_indicators": cdn_hits,
    "maximum_median_ms": int(max_median),
}
result["automatic_pass"] = all([
    result["tls_command_ok"], result["tls13"], result["alpn_h2"],
    result["certificate_verify_ok"], 200 <= result["http_code"] < 400,
    not result["cross_host_redirect"], not cdn_hits,
    result["failure_count"] == 0, tcp_median is not None,
    tcp_median <= int(max_median),
])
payload = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()
print("VPSDEPLOY_TARGET_JSON_B64=" + base64.b64encode(payload).decode())
PY
