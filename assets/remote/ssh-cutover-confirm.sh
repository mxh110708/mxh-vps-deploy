#!/usr/bin/env bash
set -euo pipefail

touch /run/vps-deploy-ssh-cutover-ok
systemctl stop vps-deploy-ssh-rollback.timer vps-deploy-ssh-rollback.service 2>/dev/null || true
systemctl reset-failed vps-deploy-ssh-rollback.service 2>/dev/null || true
rm -f /usr/local/sbin/vps-deploy-ssh-rollback
printf 'VPSDEPLOY_CUTOVER_CONFIRMED\n'
