"""Execute transaction guards in an isolated filesystem with mocked systemctl/flock.

These tests validate branching/ownership, not real systemd scheduling or Linux locks.
No production paths or services are touched.
"""
import argparse
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = None


def shell_path(path):
    value = Path(path).as_posix()
    if os.name == 'nt' and len(value) > 1 and value[1] == ':':
        value = '/' + value[0].lower() + value[2:]
    return value


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='transaction-tests-', dir=ROOT / '.tmp')
        self.root = Path(self.directory.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.backup = self.root / 'backups' / '20260909-120000' / 'protocol-lifecycle'
        self.backup.mkdir(parents=True)
        self.owner = self.state / 'transaction.owner'
        self.owner.write_text(shell_path(self.backup) + '\n', encoding='utf-8')

    def tearDown(self):
        self.directory.cleanup()

    def run_script(self, name, *, expected=None, active='', lock_fail=False, prefix_only=False, action='Status'):
        source = (ROOT / 'assets' / 'remote' / name).read_text(encoding='utf-8')
        if prefix_only:
            source = source.split('stamp="$(date', 1)[0] + "\nprintf 'GUARD_PASSED\\n'\n"
        source = source.replace('/var/lib/mxh-vps-deploy', shell_path(self.state))
        source = source.replace('/root/vps-deploy-backups', shell_path(self.root / 'backups'))
        preamble = r'''
flock() { return "${MOCK_LOCK_FAIL:-0}"; }
install() { mkdir -p "${@: -1}"; }
systemctl() {
  printf '%s\n' "$*" >> "$MOCK_CALLS"
  case "$1" in
    is-active) [[ -n "$MOCK_ACTIVE" && "$*" == *"$MOCK_ACTIVE"* ]];;
    is-failed) return 1;;
    *) return 0;;
  esac
}
'''
        env = dict(os.environ, MOCK_CALLS=shell_path(self.root / 'calls'), MOCK_ACTIVE=active,
                   MOCK_LOCK_FAIL='1' if lock_fail else '0', VPS_PARAM_EXPECTED_BACKUP=expected or shell_path(self.backup),
                   VPS_PARAM_SOURCE_ROLE='RealityEntry', VPS_PARAM_TARGET_ROLE='AnyTlsEntry',
                   VPS_PARAM_TIMEOUT_MINUTES='20', VPS_PARAM_ACTION=action)
        return subprocess.run([BASH, '--noprofile', '--norc', '-s'], input=preamble + source,
                              text=True, encoding='utf-8', errors='replace', capture_output=True, timeout=10, env=env)

    def test_arm_refuses_owner(self):
        result = self.run_script('protocol-migration-arm-rollback.sh', prefix_only=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.owner.exists())

    def test_arm_refuses_active_legacy_timer(self):
        self.owner.unlink()
        result = self.run_script('protocol-migration-arm-rollback.sh', prefix_only=True,
                                 active='mxh-protocol-migration-rollback.timer')
        self.assertNotEqual(result.returncode, 0)

    def test_arm_refuses_ssh_timer(self):
        self.owner.unlink()
        result = self.run_script('protocol-migration-arm-rollback.sh', prefix_only=True,
                                 active='mxh-ssh-maintenance-rollback.timer')
        self.assertNotEqual(result.returncode, 0)

    def test_arm_lock_failure(self):
        self.owner.unlink()
        self.assertNotEqual(self.run_script('protocol-migration-arm-rollback.sh', prefix_only=True, lock_fail=True).returncode, 0)

    def test_clean_arm_guard(self):
        self.owner.unlink()
        result = self.run_script('protocol-migration-arm-rollback.sh', prefix_only=True)
        self.assertIn('GUARD_PASSED', result.stdout, result.stderr)

    def test_wrong_commit_identity(self):
        self.assertNotEqual(self.run_script('maintenance-transaction-commit.sh', expected=shell_path(self.backup) + '-wrong').returncode, 0)
        self.assertTrue(self.owner.exists())

    def test_commit_and_repeat(self):
        self.assertEqual(self.run_script('maintenance-transaction-commit.sh').returncode, 0)
        self.assertFalse(self.owner.exists())
        self.assertTrue((self.backup / 'transaction-committed').exists())
        self.assertEqual(self.run_script('maintenance-transaction-commit.sh').returncode, 0)

    def test_commit_after_rollback_rejected(self):
        (self.backup / 'rollback-executed').touch()
        self.assertNotEqual(self.run_script('maintenance-transaction-commit.sh').returncode, 0)

    def test_running_rollback_blocks_commit(self):
        result = self.run_script('maintenance-transaction-commit.sh', active='mxh-protocol-migration-rollback.service')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.owner.exists())

    def test_wrong_rollback_identity(self):
        result = self.run_script('protocol-migration-trigger-rollback.sh', expected=shell_path(self.backup) + '-wrong')
        self.assertNotEqual(result.returncode, 0)

    def test_preparing_lock_release(self):
        self.assertEqual(self.run_script('maintenance-transaction-status.sh', action='ReleaseUnarmed').returncode, 0)
        self.assertFalse(self.owner.exists())

    def test_armed_lock_cannot_release(self):
        (self.backup / 'transaction-armed').touch()
        self.assertNotEqual(self.run_script('maintenance-transaction-status.sh', action='ReleaseUnarmed').returncode, 0)
        self.assertTrue(self.owner.exists())

    def test_status_uses_controller_marker_contract(self):
        (self.backup / 'transaction-armed').touch()
        result = self.run_script('maintenance-transaction-status.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        encoded = next(line.split('=', 1)[1] for line in result.stdout.splitlines()
                       if line.startswith('VPSDEPLOY_TRANSACTION_PHASE_B64='))
        self.assertEqual(base64.b64decode(encoded).decode('utf-8'), 'Armed')

    def test_active_ssh_lock_cannot_release(self):
        result = self.run_script('maintenance-transaction-status.sh', action='ReleaseUnarmed', active='mxh-ssh-maintenance-rollback.timer')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.owner.exists())


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bash', required=True)
    args = parser.parse_args()
    BASH = args.bash
    (ROOT / '.tmp').mkdir(exist_ok=True)
    unittest.main(argv=[__file__], verbosity=2)
