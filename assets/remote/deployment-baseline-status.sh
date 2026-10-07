#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_TRANSACTION_ID:?}"
[[ "$VPS_PARAM_TRANSACTION_ID" =~ ^[a-f0-9]{32}$ ]]
baseline="/root/vps-deploy-transaction-baselines/$VPS_PARAM_TRANSACTION_ID"
phase=None
if [[ -e "$baseline" || -L "$baseline" ]]; then
  [[ ! -L "$baseline" && "$(readlink -f "$baseline")" == "$baseline" ]]
  phase=Incomplete
  if [[ -f "$baseline/baseline.complete" ]]; then phase=Ready; fi
  if [[ -f "$baseline/rollback.complete" ]]; then phase=RolledBack; fi
fi
printf 'VPSDEPLOY_DEPLOYMENT_BASELINE_STATUS_B64=%s\n' "$(printf '%s' "$phase" | base64 | tr -d '\n')"
