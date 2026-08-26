#!/usr/bin/env python3
"""Create candidate authority configs without touching the authoritative inputs."""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from ruamel.yaml import YAML


def load_fragments(directory: Path, roles: set[str]):
    yaml = YAML(typ="safe")
    proxies = []
    outbounds = []
    yaml_by_role = {
        "RealityEntry": "mihomo-test-primary.yaml",
        "AnyTlsEntry": "mihomo-anytls-test.yaml",
        "ShadowsocksLanding": "mihomo-shadowsocks-test.yaml",
    }
    json_by_role = {
        "RealityEntry": "sing-box-outbounds.private.json",
        "AnyTlsEntry": "sing-box-anytls-outbounds.private.json",
        "ShadowsocksLanding": "sing-box-shadowsocks-outbounds.private.json",
    }
    for role in roles:
        yp = directory / yaml_by_role[role]
        jp = directory / json_by_role[role]
        if not yp.is_file() or not jp.is_file():
            raise SystemExit(f"missing client fragment for {role}")
        ydoc = yaml.load(yp.read_text(encoding="utf-8")) or {}
        proxies.extend(copy.deepcopy(ydoc.get("proxies") or []))
        jdoc = json.loads(jp.read_text(encoding="utf-8"))
        outbounds.extend(copy.deepcopy(jdoc.get("outbounds") or []))
    if not proxies or not outbounds:
        raise SystemExit("no client nodes found in fragments")
    return proxies, outbounds


def replace_tagged(items, key, prefix, replacements):
    names = {str(item[key]) for item in replacements}
    result = [item for item in items if str(item.get(key, "")) not in names]
    result.extend(replacements)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--clash", type=Path, required=True)
    parser.add_argument("--sing-box", type=Path, required=True)
    parser.add_argument("--fragments", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--roles", required=True)
    parser.add_argument("--entry-group")
    parser.add_argument("--remove-prefix")
    args = parser.parse_args()

    allowed = {"RealityEntry", "AnyTlsEntry", "ShadowsocksLanding"}
    roles = {value for value in args.roles.split(",") if value}
    if (not args.remove_prefix and not roles) or not roles <= allowed:
        raise SystemExit("invalid roles")
    args.output.mkdir(parents=True, exist_ok=True)
    if args.remove_prefix:
        proxies, outbounds = [], []
    else:
        proxies, outbounds = load_fragments(args.fragments, roles)

    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    with args.clash.open("r", encoding="utf-8") as handle:
        clash = yaml.load(handle)
    if args.remove_prefix:
        removed_names = {str(item.get("name")) for item in clash.get("proxies", [])
                         if str(item.get("name", "")) == args.remove_prefix or str(item.get("name", "")).startswith(args.remove_prefix + "-")}
        clash["proxies"] = [item for item in clash.get("proxies", []) if str(item.get("name")) not in removed_names]
        for group in clash.get("proxy-groups", []):
            group["proxies"] = [name for name in group.get("proxies", []) if str(name) not in removed_names]
    else:
        clash["proxies"] = replace_tagged(list(clash.get("proxies") or []), "name", "", proxies)
    proxy_names = [str(item["name"]) for item in proxies]
    if args.entry_group:
        groups = [item for item in clash.get("proxy-groups", []) if str(item.get("name")) == args.entry_group]
        if len(groups) != 1:
            raise SystemExit("entry group not found exactly once in Clash config")
        current = list(groups[0].get("proxies") or [])
        groups[0]["proxies"] = current + [name for name in proxy_names if name not in current]
    clash_out = args.output / "Clash_General.candidate.yaml"
    with clash_out.open("w", encoding="utf-8", newline="\n") as handle:
        yaml.dump(clash, handle)

    sing = json.loads(args.sing_box.read_text(encoding="utf-8"))
    if args.remove_prefix:
        removed_tags = {str(item.get("tag")) for item in sing.get("outbounds", [])
                        if str(item.get("tag", "")) == args.remove_prefix or str(item.get("tag", "")).startswith(args.remove_prefix + "-")}
        sing["outbounds"] = [item for item in sing.get("outbounds", []) if str(item.get("tag")) not in removed_tags]
        for item in sing["outbounds"]:
            if item.get("type") == "selector":
                item["outbounds"] = [tag for tag in item.get("outbounds", []) if str(tag) not in removed_tags]
    else:
        sing["outbounds"] = replace_tagged(list(sing.get("outbounds") or []), "tag", "", outbounds)
    outbound_tags = [str(item["tag"]) for item in outbounds]
    if args.entry_group:
        selectors = [item for item in sing["outbounds"] if item.get("type") == "selector" and item.get("tag") == args.entry_group]
        if len(selectors) != 1:
            raise SystemExit("entry selector not found exactly once in sing-box config")
        current = list(selectors[0].get("outbounds") or [])
        selectors[0]["outbounds"] = current + [tag for tag in outbound_tags if tag not in current]
    sing_out = args.output / "sing-box-general.candidate.json"
    sing_out.write_text(json.dumps(sing, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    manifest = {
        "roles": sorted(roles), "entry_group": args.entry_group,
        "clash_nodes": proxy_names, "sing_box_outbounds": outbound_tags,
        "remove_prefix": args.remove_prefix, "authoritative_files_modified": False,
    }
    (args.output / "candidate-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
