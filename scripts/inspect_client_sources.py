"""Read paired client nodes to private stdout; never modify either source."""
import argparse
import json
from pathlib import Path
from ruamel.yaml import YAML


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--clash', type=Path, required=True)
    parser.add_argument('--sing-box', type=Path, required=True)
    args = parser.parse_args()
    clash = YAML(typ='safe').load(args.clash.read_text(encoding='utf-8')) or {}
    sing = json.loads(args.sing_box.read_text(encoding='utf-8'))
    proxies = clash.get('proxies') or []
    outbounds = sing.get('outbounds') or []
    names = [str(n.get('name', '')) for n in proxies]
    tags = [str(n.get('tag', '')) for n in outbounds]
    if len(set(names)) != len(names) or len(set(tags)) != len(tags):
        raise SystemExit('duplicate source names')
    by_name = {str(n.get('name')): n for n in proxies}
    nodes = []
    for outbound in outbounds:
        name = str(outbound.get('tag', ''))
        proxy = by_name.get(name)
        if not proxy:
            continue
        pair = (proxy.get('type'), outbound.get('type'))
        if pair not in (('vless', 'vless'), ('anytls', 'anytls'), ('ss', 'shadowsocks')):
            continue
        if pair[0] == 'vless' and not outbound.get('tls', {}).get('reality', {}).get('enabled'):
            continue
        nodes.append(dict(name=name, kind='landing' if pair[0] == 'ss' else 'entry',
                          region_group=None, transit_group=None, clash=proxy, sing_box=outbound))
    # ASCII transport avoids Windows redirected-stdout code-page differences.
    print(json.dumps(nodes, ensure_ascii=True))


if __name__ == '__main__':
    main()
