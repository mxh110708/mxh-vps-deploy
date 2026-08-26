#!/usr/bin/env bash
set -euo pipefail
python3 <<'PY'
import base64, json, pathlib
root=pathlib.Path('/root/vps-deploy-backups')
items=[]
if root.is_dir():
    for path in sorted(root.glob('[0-9]'*8+'-'+'[0-9]'*6+'/protocol-lifecycle'), reverse=True):
        if not path.is_dir(): continue
        def text(name):
            p=path/name
            return p.read_text(errors='replace').strip() if p.is_file() else None
        items.append({
          'Id': path.parent.name, 'Path': str(path), 'SourceRole': text('source-role'), 'TargetRole': text('target-role'),
          'RolledBack': (path/'rollback-executed').is_file(),
          'HasProtocolFiles': (path/'protocol-files.tar.gz').is_file(), 'HasFirewall': (path/'nftables.conf').is_file(),
          'SizeBytes': sum(p.stat().st_size for p in path.rglob('*') if p.is_file())
        })
payload=json.dumps(items,separators=(',',':')).encode()
print('VPSDEPLOY_BACKUP_LIST_B64='+base64.b64encode(payload).decode())
PY
printf '%s\n' 'VPSDEPLOY_BACKUP_LIST_OK'
