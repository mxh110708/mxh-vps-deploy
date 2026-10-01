"""Actual import/SSH validation branches with isolated inputs and fake commands."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
BASH=None


class ImportContractTests(unittest.TestCase):
    def import_ss(self, *, no_bind=False, duplicate=False, ambiguous=False, action='route'):
        with tempfile.TemporaryDirectory(prefix='import-ss-',dir=ROOT/'.tmp') as directory:
            root=Path(directory)
            outbound={'type':'direct','tag':'v6','inet6_bind_address':'2001:db8::20','bind_interface':'eth0'}
            if no_bind:
                outbound.pop('inet6_bind_address');outbound.pop('bind_interface')
            users=[{'name':'ipv4-client','password':'fixture4'},{'name':'ipv6-client','password':'fixture6'}]
            if duplicate:
                users.append(dict(users[0]))
            config={'inbounds':[{'type':'shadowsocks','listen_port':33456,'method':'2022-blake3-aes-128-gcm','password':'fixture-server','users':users}],
                    'outbounds':[outbound],'route':{'rules':[{'auth_user':['ipv6-client'],'action':'route','outbound':'v6'}]}}
            if ambiguous:
                config['route']['rules'].append(dict(config['route']['rules'][0]))
            if action is None:
                config['route']['rules'][0].pop('action')
            else:
                config['route']['rules'][0]['action']=action
            file=root/'config.json';file.write_text(json.dumps(config))
            source=(ROOT/'assets/remote/existing-vps-import-audit.sh').read_text()
            block=source.split('if inventory["ShadowsocksLanding"]["Installed"]:',1)[1].split('\nlisteners_tcp =',1)[0]
            body='if True:'+block
            body=body.replace('Path("/etc/sing-box/config.json")','Path('+repr(str(file))+')')
            values={'inventory':{'ShadowsocksLanding':{'Installed':True}},'protocols':{},'Path':Path,'json':json,
                    'run':lambda *args,**kwargs:subprocess.CompletedProcess(args,0,'sing-box version 1.14.2','')}
            exec(compile(body,'import-ss-payload','exec'),values)
            return values['protocols']['ShadowsocksLanding']

    def ssh(self,preserve,pubkey='yes'):
        source=(ROOT/'assets/remote/final-validate.sh').read_text().split('case "$firewall_mode"',1)[0]
        preamble='sshd(){ if [[ "$1" == -T ]]; then printf "port 30123\\nport 31234\\npasswordauthentication yes\\nkbdinteractiveauthentication yes\\npubkeyauthentication %s\\n" "$MOCK_PUBKEY"; fi; }\n'
        env=dict(os.environ,VPS_PARAM_ROLE='MonitorOnly',VPS_PARAM_SSH_PRIMARY='30123',VPS_PARAM_SSH_RESCUE='31234',
                 VPS_PARAM_KOMARI_ENABLED='false',VPS_PARAM_REALITY_ENABLED='false',VPS_PARAM_ANYTLS_ENABLED='false',
                 VPS_PARAM_SHADOWSOCKS_ENABLED='false',VPS_PARAM_PRESERVE_SSH_AUTH=str(preserve).lower(),MOCK_PUBKEY=pubkey)
        return subprocess.run([BASH,'--noprofile','--norc','-s'],input=preamble+source,text=True,capture_output=True,timeout=5,env=env)

    def test_import_preserves_ipv6_source_and_interface(self):
        imported=self.import_ss()
        self.assertEqual(imported['SecondaryIpv6Address'],'2001:db8::20')
        self.assertEqual(imported['SecondaryBindInterface'],'eth0')

    def test_import_does_not_invent_an_ipv6_binding(self):
        imported=self.import_ss(no_bind=True)
        self.assertIsNone(imported['SecondaryIpv6Address']);self.assertIsNone(imported['SecondaryBindInterface'])

    def test_import_accepts_default_and_empty_route_action(self):
        for action in (None,''):
            with self.subTest(action=action):
                imported=self.import_ss(action=action)
                self.assertEqual(imported['SecondaryIpv6Address'],'2001:db8::20')
                self.assertEqual(imported['SecondaryBindInterface'],'eth0')

    def test_import_still_rejects_non_route_actions(self):
        for action in ('reject','route-options'):
            with self.subTest(action=action):
                with self.assertRaisesRegex(RuntimeError,'identify'):
                    self.import_ss(action=action)

    def test_import_rejects_duplicate_users(self):
        with self.assertRaisesRegex(RuntimeError,'unique'):
            self.import_ss(duplicate=True)

    def test_import_rejects_ambiguous_ipv6_routing(self):
        with self.assertRaisesRegex(RuntimeError,'identify'):
            self.import_ss(ambiguous=True)

    def test_preserved_password_auth_passes_final_validation(self):
        self.assertEqual(self.ssh(True).returncode,0)

    def test_enforced_key_only_policy_still_rejects_password_auth(self):
        self.assertNotEqual(self.ssh(False).returncode,0)

    def test_preserving_auth_never_allows_disabled_pubkey(self):
        self.assertNotEqual(self.ssh(True,'no').returncode,0)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--bash',required=True)
    args,remaining=parser.parse_known_args();BASH=args.bash
    (ROOT/'.tmp').mkdir(exist_ok=True)
    unittest.main(argv=[sys.argv[0],*remaining],verbosity=2)
