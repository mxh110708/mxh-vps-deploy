#!/usr/bin/env bash
set -euo pipefail
systemctl stop mxh-protocol-migration-rollback.timer >/dev/null 2>&1 || true
systemctl disable mxh-protocol-migration-rollback.timer >/dev/null 2>&1 || true
systemctl is-active --quiet mxh-protocol-migration-rollback.timer 2>/dev/null && exit 1 || true
printf '%s\n' 'VPSDEPLOY_MAINTENANCE_COMMITTED'
