"""Describe a candidate change without printing configuration values or credentials."""
import argparse
import json
from pathlib import Path
from ruamel.yaml import YAML


def read_document(path, yaml=False):
    if not path.is_file():
        return {}, 'Missing'
    try:
        text = path.read_text(encoding='utf-8')
        result = YAML(typ='safe').load(text) if yaml else json.loads(text)
        if not isinstance(result, dict):
            raise ValueError('not a mapping')
        return result, 'Readable'
    except Exception:
        return {}, 'Unreadable'


def summarize(old, new, list_key, name_key):
    previous = {str(n.get(name_key)): n for n in (old.get(list_key) or []) if isinstance(n, dict)}
    current = {str(n.get(name_key)): n for n in (new.get(list_key) or []) if isinstance(n, dict)}
    return dict(Added=sorted(current.keys() - previous.keys()),
                Removed=sorted(previous.keys() - current.keys()),
                Changed=sorted(k for k in current.keys() & previous.keys() if current[k] != previous[k]),
                OtherSections=sorted(k for k in old.keys() | new.keys() if k != list_key and old.get(k) != new.get(k)))


def main():
    parser = argparse.ArgumentParser()
    for name in ('old-clash', 'old-sing', 'new-clash', 'new-sing'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    result = {}
    for name, old_path, new_path, yaml, list_key, name_key in (
        ('Clash', args.old_clash, args.new_clash, True, 'proxies', 'name'),
        ('SingBox', args.old_sing, args.new_sing, False, 'outbounds', 'tag'),
    ):
        old, state = read_document(old_path, yaml)
        new, new_state = read_document(new_path, yaml)
        if new_state != 'Readable':
            raise SystemExit('candidate cannot be read')
        result[name] = summarize(old, new, list_key, name_key)
        result[name]['PreviousState'] = state
    print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    main()
