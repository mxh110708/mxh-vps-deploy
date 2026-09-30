"""Komari 1.5 lifecycle branches in a disposable filesystem with fake services.

No real systemctl, network request, user account, database or VPS is used.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = None


def shell_path(path):
    value = Path(path).as_posix()
    return '/' + value[0].lower() + value[2:] if os.name == 'nt' and len(value) > 1 and value[1] == ':' else value


PREAMBLE = r'''
uname(){ echo x86_64; }
python3(){
  local converted=() argument
  for argument in "$@"; do converted+=("${argument//$TEST_ROOT/$TEST_NATIVE_ROOT}"); done
  "$TEST_PYTHON" "${converted[@]}"
}
systemctl(){
  echo "$*" >> "$CALLS"
  case "$1" in
    is-active) [[ "$(cat "$TEST_ROOT/active")" == true ]] ;;
    is-enabled) [[ "$WAS_ENABLED" == true ]] ;;
    stop) echo false > "$TEST_ROOT/active" ;;
    start|restart)
      if [[ "$SERVICE_START_FAILS" == true ]]; then echo false > "$TEST_ROOT/active"; return 1; fi
      echo true > "$TEST_ROOT/active"
      [[ "$STALE_PID" == true ]] || ln -f "$SERVICE_BINARY" "$TEST_ROOT/proc/123/exe"
      if [[ "$*" == *komari.service* ]] && grep -Fq 'new-upgrade' "$SERVICE_BINARY"; then
        echo migrated > "$TEST_ROOT/opt/komari/data/komari.db"
        echo new-metrics > "$TEST_ROOT/opt/komari/data/metrics.db"
      fi ;;
    show)
      if [[ "$*" == *ExecStart* ]]; then printf '{ path=%s ; argv[]=%s server %s ; }\n' "$SERVICE_BINARY" "$SERVICE_BINARY" "$EXTRA_DB_ARGUMENTS"
      elif [[ "$*" == *MainPID* ]]; then echo 123
      else echo "$TEST_ROOT/opt/komari"; fi ;;
    *) return 0 ;;
  esac
}
ss(){ echo 'LISTEN 0 128 127.0.0.1:25774 0.0.0.0:*'; }
sleep(){ echo "sleep $*" >> "$CALLS"; }
install(){
  local args=()
  while (($#)); do
    case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  command install "${args[@]}"
  if [[ "$CORRUPT_INSTALL" == true && "$VPS_PARAM_ACTION" == AgentUpgrade ]]; then printf '\n# corrupt-install\n' >> "$SERVICE_BINARY"; fi
}
tar(){
  local args=()
  while (($#)); do
    if [[ "$1" == -C && "$2" == / ]]; then args+=(-C "$TEST_ROOT"); shift 2
    else args+=("$1"); shift; fi
  done
  command tar "${args[@]}"
}
curl(){
  local output='' url='' previous=''
  for arg in "$@"; do
    [[ "$previous" != --output ]] || output="$arg"
    [[ "$arg" != http* ]] || url="$arg"
    previous="$arg"
  done
  if [[ "$url" == *releases/download* ]]; then cp "$TEST_ROOT/new-binary" "$output"
  elif [[ "$url" == *database-migration/auth ]]; then
    printf '%s' "$MIGRATION_BODY" > "$output"; printf '%s' "$MIGRATION_CODE"
  elif [[ "$url" == */api/version ]]; then
    printf '%s' "$VERSION_BODY" > "$output"; printf '%s' "$VERSION_CODE"
  else printf '%s' "$HOME_CODE"; fi
}
'''


class KomariLifecycleTests(unittest.TestCase):
    def run_case(self, action, *, active=True, enabled=True, migration_code='404', body='{}', home_code='200', bad_version=False,
                 extra_db_arguments='', version_code='200', version_body=None, binary_location='opt/komari/komari', stale_pid=False,
                 bad_checksum=False, corrupt_install=False, service_start_fails=False):
        with tempfile.TemporaryDirectory(prefix='komari-lifecycle-', dir=ROOT / '.tmp') as folder:
            root = Path(folder)
            script = (ROOT / 'assets/remote/maintenance-komari.sh').read_text(encoding='utf-8')
            for prefix in ('/usr/local', '/usr/bin', '/etc', '/var/lib', '/opt', '/root', '/proc'):
                script = script.replace(prefix, shell_path(root) + prefix)
            script = script.replace('"/$p"', '"$TEST_ROOT/$p"')
            for relative in ('opt/komari/data/plugin', 'opt/komari/data/plguin-data', 'opt/komari/data/theme', 'root/vps-deploy-backups', 'etc/komari-agent', 'usr/local/bin', 'proc/123', 'tmp'):
                (root / relative).mkdir(parents=True, exist_ok=True)
            (root / 'active').write_text(str(active).lower())
            (root / 'opt/komari/data/komari.db').write_text('old-db')
            (root / 'opt/komari/data/plugin/fixture').write_text('old-plugin')
            old_binary = root / ('usr/local/bin/komari-agent' if action == 'AgentUpgrade' else binary_location)
            old_binary.write_text('#!/usr/bin/env bash\necho "Komari Monitor 1.4.3"\n')
            old_binary.chmod(0o755)
            token_config = root / 'etc/komari-agent/config.json'
            token_config.write_text('{"token":"fixture-token","disable_web_ssh":true}')
            before_token = token_config.read_bytes()
            version = '1.5.11' if action == 'AgentUpgrade' else '1.5.1'
            new_text = '#!/usr/bin/env bash\n# new-upgrade\necho "Komari Monitor ' + ('0.0.0' if bad_version else version) + '"\n'
            if action == 'AgentUpgrade':
                # The real Agent has no --version interface. Any direct invocation
                # of this fixture is a preflight bug, not a successful version check.
                new_text = '#!/usr/bin/env bash\n# new-upgrade\necho "agent-binary-executed" >> "$CALLS"\necho "unsupported agent preflight invocation" >&2\nexit 64\n'
            new_binary = root / 'new-binary'
            new_binary.write_text(new_text, newline='\n')
            backup = root / 'root/komari-controller-20260930-010101.tar.gz'
            packed = subprocess.run([BASH, '-c', 'tar -czpf "$2" -C "$1" opt/komari usr/local/bin', '--', shell_path(root), shell_path(backup)], capture_output=True, text=True)
            self.assertEqual(packed.returncode, 0, packed.stderr)
            environment = dict(os.environ, TEST_ROOT=shell_path(root), TEST_NATIVE_ROOT=root.as_posix(), CALLS=shell_path(root / 'calls'),
                TMPDIR=shell_path(root / 'tmp'), TEST_PYTHON=shell_path(sys.executable), WAS_ENABLED=str(enabled).lower(), MIGRATION_CODE=migration_code,
                MIGRATION_BODY=body, HOME_CODE=home_code, EXTRA_DB_ARGUMENTS=extra_db_arguments, VERSION_CODE=version_code,
                VERSION_BODY=version_body if version_body is not None else json.dumps({'data': {'version': version}}),
                SERVICE_BINARY=shell_path(old_binary), STALE_PID=str(stale_pid).lower(), VPS_PARAM_ACTION=action, VPS_PARAM_VERSION=version,
                CORRUPT_INSTALL=str(corrupt_install).lower(), SERVICE_START_FAILS=str(service_start_fails).lower(),
                VPS_PARAM_ASSET_NAME='komari-agent-linux-amd64' if action == 'AgentUpgrade' else 'komari-linux-amd64',
                VPS_PARAM_SHA256='0' * 64 if bad_checksum else hashlib.sha256(new_binary.read_bytes()).hexdigest(), VPS_PARAM_BACKUP_FILE=shell_path(backup))
            if action == 'ControllerVerify':
                old_binary.write_text(new_text, newline='\n'); old_binary.chmod(0o755)
            os.link(old_binary, root / 'proc/123/exe')
            result = subprocess.run([BASH, '--noprofile', '--norc', '-s'], input=PREAMBLE + script,
                                    capture_output=True, text=True, encoding='utf-8', timeout=20, env=environment)
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            current = (root / 'opt/komari/data/komari.db').read_text()
            result.binary_contents = old_binary.read_text()
            result.service_active = (root / 'active').read_text().strip() == 'true'
            result.quarantined_metrics = len(list((root / 'root/vps-deploy-backups').glob('komari-failed-upgrade-*/**/metrics.db')))
            return result, calls, current, (root / 'opt/komari/data/metrics.db').exists(), before_token == token_config.read_bytes()

    def marker(self, output):
        line = next(line for line in output.splitlines() if line.startswith('VPSDEPLOY_KOMARI_MIGRATION_REQUIRED_B64='))
        return base64.b64decode(line.split('=', 1)[1]).decode()

    def test_migration_guide_is_pending_not_completed(self):
        result, _, _, _, _ = self.run_case('ControllerUpgrade', migration_code='200', body=json.dumps({'data': {'mode': 'metric_store_restructure'}}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(result.stdout), 'true')

    def test_normal_controller_is_verified(self):
        result, _, _, _, _ = self.run_case('ControllerUpgrade')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(result.stdout), 'false')

    def test_invalid_migration_response_rolls_back_database_and_binary(self):
        result, _, database, metrics, _ = self.run_case('ControllerUpgrade', migration_code='200', body='{"data":{"mode":"unknown"}}')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(database, 'old-db')
        self.assertFalse(metrics)
        self.assertIn('Komari Monitor 1.4.3', result.binary_contents)
        self.assertEqual(result.quarantined_metrics, 1)

    def test_normal_spa_fallback_requires_valid_version_api(self):
        result, _, _, _, _ = self.run_case('ControllerUpgrade', migration_code='200', body='<!doctype html><html>Komari</html>')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(result.stdout), 'false')

    def test_spa_response_is_not_completion_when_version_api_is_html(self):
        result, _, database, metrics, _ = self.run_case('ControllerUpgrade', migration_code='200', body='<html>Komari</html>', version_body='<html>migration</html>')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(database, 'old-db')
        self.assertFalse(metrics)

    def test_version_api_mismatch_rolls_back(self):
        result, _, database, _, _ = self.run_case('ControllerUpgrade', version_body='{"data":{"version":"1.4.3"}}')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(database, 'old-db')

    def test_upgrade_uses_registered_service_binary(self):
        result, _, _, _, _ = self.run_case('ControllerUpgrade', binary_location='usr/local/bin/komari')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Komari Monitor 1.5.1', result.binary_contents)

    def test_running_process_must_use_replaced_binary(self):
        result, _, database, _, _ = self.run_case('ControllerUpgrade', stale_pid=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(database, 'old-db')

    def test_http_failure_restores_pre_migration_database(self):
        result, _, database, metrics, _ = self.run_case('ControllerUpgrade', home_code='500')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(database, 'old-db')
        self.assertFalse(metrics)

    def test_version_mismatch_rolls_back(self):
        result, _, database, metrics, _ = self.run_case('ControllerUpgrade', bad_version=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(database, 'old-db')
        self.assertFalse(metrics)

    def test_inactive_controller_stays_inactive_and_migration_is_deferred(self):
        result, calls, database, _, _ = self.run_case('ControllerUpgrade', active=False, enabled=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(result.stdout), 'deferred')
        self.assertNotIn('start komari.service', calls)
        self.assertIn('disable komari.service', calls)
        self.assertEqual(database, 'old-db')

    def test_readonly_reverification_does_not_start_or_stop_controller(self):
        result, calls, _, _, _ = self.run_case('ControllerVerify')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker(result.stdout), 'false')
        self.assertNotIn('start ', calls)
        self.assertNotIn('stop ', calls)

    def test_agent_upgrade_preserves_token_and_enabled_state(self):
        result, calls, _, _, token_unchanged = self.run_case('AgentUpgrade', enabled=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(token_unchanged)
        self.assertIn('restart komari-agent.service', calls)
        self.assertIn('disable komari-agent.service', calls)
        self.assertIn('show --property=MainPID --value komari-agent.service', calls)
        self.assertNotIn('agent-binary-executed', calls)
        self.assertTrue(result.service_active)

    def test_agent_upgrade_never_executes_unsupported_version_command(self):
        result, calls, _, _, token_unchanged = self.run_case('AgentUpgrade')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('agent-binary-executed', calls)
        self.assertNotIn('disable komari-agent.service', calls)
        self.assertTrue(token_unchanged)

    def test_inactive_agent_is_updated_without_starting_it(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                result, calls, _, _, token_unchanged = self.run_case('AgentUpgrade', active=False, enabled=enabled)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('new-upgrade', result.binary_contents)
                self.assertFalse(result.service_active)
                self.assertTrue(token_unchanged)
                self.assertNotIn('agent-binary-executed', calls)
                self.assertNotIn('restart komari-agent.service', calls)
                self.assertNotIn('start komari-agent.service', calls)
                self.assertNotIn('enable komari-agent.service', calls)

    def test_agent_checksum_mismatch_rejects_before_replacement(self):
        result, calls, _, _, token_unchanged = self.run_case('AgentUpgrade', bad_checksum=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Komari Monitor 1.4.3', result.binary_contents)
        self.assertNotIn('restart komari-agent.service', calls)
        self.assertNotIn('agent-binary-executed', calls)
        self.assertTrue(token_unchanged)

    def test_agent_installed_checksum_mismatch_rejects_before_restart(self):
        result, calls, _, _, token_unchanged = self.run_case('AgentUpgrade', corrupt_install=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('restart komari-agent.service', calls)
        self.assertTrue(token_unchanged)

    def test_agent_running_process_must_use_replaced_binary(self):
        result, calls, _, _, token_unchanged = self.run_case('AgentUpgrade', stale_pid=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('restart komari-agent.service', calls)
        self.assertEqual(calls.count('sleep 1'), 10)
        self.assertNotIn('VPSDEPLOY_KOMARI_LIFECYCLE_OK', result.stdout)
        self.assertTrue(token_unchanged)

    def test_agent_restart_failure_is_not_reported_as_success(self):
        result, calls, _, _, token_unchanged = self.run_case('AgentUpgrade', service_start_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('restart komari-agent.service', calls)
        self.assertNotIn('VPSDEPLOY_KOMARI_LIFECYCLE_OK', result.stdout)
        self.assertFalse(result.service_active)
        self.assertTrue(token_unchanged)

    def test_external_database_is_rejected_before_any_service_change(self):
        result, calls, database, _, _ = self.run_case('ControllerUpgrade', extra_db_arguments='--database /external/komari.db')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(database, 'old-db')
        self.assertNotIn('stop ', calls)
        self.assertNotIn('start ', calls)

    def test_non_sqlite_database_is_rejected(self):
        result, calls, _, _, _ = self.run_case('ControllerPreflight', extra_db_arguments='--db-type mysql')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('stop ', calls)

    def test_compact_short_database_flags_are_checked(self):
        for arguments in ('-d/external/komari.db', '-tmysql', '--database=file:/external/komari.db'):
            with self.subTest(arguments=arguments):
                result, calls, _, _, _ = self.run_case('ControllerPreflight', extra_db_arguments=arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('stop ', calls)

    def test_backup_stops_and_restores_controller_without_changing_data(self):
        result, calls, database, _, _ = self.run_case('ControllerBackup')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(calls.index('stop komari.service'), calls.index('start komari.service'))
        self.assertEqual(database, 'old-db')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bash', required=True)
    arguments = parser.parse_args()
    BASH = arguments.bash
    (ROOT / '.tmp').mkdir(exist_ok=True)
    unittest.main(argv=[__file__], verbosity=2)
