#!/usr/bin/env python3
"""Build Clash and sing-box authority candidates from a private layout specification.

The source authority files are read-only. The specification may contain active
credentials and must stay in a local private directory.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any

from ruamel.yaml import YAML


ROLE_FILES = {
    "RealityEntry": ("mihomo-test-primary.yaml", "sing-box-outbounds.private.json"),
    "AnyTlsEntry": ("mihomo-anytls-test.yaml", "sing-box-anytls-outbounds.private.json"),
    "ShadowsocksLanding": ("mihomo-shadowsocks-test.yaml", "sing-box-shadowsocks-outbounds.private.json"),
}


def fail(message: str) -> None:
    raise SystemExit(message)


def load_fragment(source: dict[str, Any]) -> list[dict[str, Any]]:
    role = str(source.get("role", ""))
    if role not in ROLE_FILES:
        fail(f"unsupported fragment role: {role}")
    directory = Path(str(source.get("fragment_dir", "")))
    yaml_name, json_name = ROLE_FILES[role]
    yaml_path, json_path = directory / yaml_name, directory / json_name
    if not yaml_path.is_file() or not json_path.is_file():
        fail(f"missing client exports for {role}: {directory}")
    yaml = YAML(typ="safe")
    clash_nodes = (yaml.load(yaml_path.read_text(encoding="utf-8")) or {}).get("proxies") or []
    sing_nodes = json.loads(json_path.read_text(encoding="utf-8")).get("outbounds") or []
    clash_by_name = {str(item.get("name")): item for item in clash_nodes}
    sing_by_name = {str(item.get("tag")): item for item in sing_nodes}
    selected = source.get("node_names") or sorted(set(clash_by_name) & set(sing_by_name))
    result: list[dict[str, Any]] = []
    for name in selected:
        if name not in clash_by_name or name not in sing_by_name:
            fail(f"fragment node is not present in both clients: {name}")
        result.append({
            "name": name,
            "kind": "landing" if role == "ShadowsocksLanding" else "entry",
            "region_group": source.get("region_group"),
            "transit_group": source.get("transit_group"),
            "clash": copy.deepcopy(clash_by_name[name]),
            "sing_box": copy.deepcopy(sing_by_name[name]),
            "origin": str(directory),
        })
    return result


def collect_nodes(spec: dict[str, Any], clash: dict[str, Any], sing: dict[str, Any]) -> list[dict[str, Any]]:
    nodes: list[dict[str, Any]] = []
    for source in spec.get("fragment_sources") or []:
        nodes.extend(load_fragment(source))
    nodes.extend(copy.deepcopy(spec.get("manual_nodes") or []))
    clash_existing = {str(item.get("name")): item for item in clash.get("proxies") or []}
    sing_existing = {str(item.get("tag")): item for item in sing.get("outbounds") or []}
    for reference in spec.get("existing_node_refs") or []:
        name = str(reference.get("name", ""))
        if name not in clash_existing or name not in sing_existing:
            fail(f"existing authority node is not present in both clients: {name}")
        nodes.append({
            "name": name,
            "kind": reference.get("kind"),
            "region_group": reference.get("region_group"),
            "transit_group": reference.get("transit_group"),
            "clash": copy.deepcopy(clash_existing[name]),
            "sing_box": copy.deepcopy(sing_existing[name]),
            "origin": "existing-authority",
        })
    seen: set[str] = set()
    for node in nodes:
        name = str(node.get("name", ""))
        if not name or name in seen:
            fail(f"empty or duplicate node name: {name!r}")
        seen.add(name)
        if str(node.get("clash", {}).get("name", "")) != name:
            fail(f"Clash node name mismatch: {name}")
        if str(node.get("sing_box", {}).get("tag", "")) != name:
            fail(f"sing-box node tag mismatch: {name}")
        kind = str(node.get("kind", ""))
        if kind == "entry":
            if not node.get("region_group"):
                fail(f"entry node has no region group: {name}")
        elif kind == "landing":
            transit = str(node.get("transit_group", ""))
            if not transit:
                fail(f"landing node has no transit group: {name}")
            node["clash"]["dialer-proxy"] = transit
            node["sing_box"]["detour"] = transit
        else:
            fail(f"invalid node kind for {name}: {kind}")
    return nodes


def replace_named(items: list[dict[str, Any]], key: str, replacements: list[dict[str, Any]]) -> list[dict[str, Any]]:
    names = {str(item[key]) for item in replacements}
    existing = [item for item in items if str(item.get(key, "")) not in names]
    return existing + copy.deepcopy(replacements)


def normalize_members(members: list[Any], client: str) -> list[str]:
    result: list[str] = []
    for value in members:
        name = str(value)
        if client == "clash" and name == "BLOCK":
            name = "REJECT"
        elif client == "sing_box" and name == "REJECT":
            name = "BLOCK"
        if name not in result:
            result.append(name)
    return result


def apply_clash_groups(document: dict[str, Any], groups: list[dict[str, Any]], order: list[str], remove: set[str]) -> None:
    current = [item for item in list(document.get("proxy-groups") or []) if str(item.get("name")) not in remove]
    by_name = {str(item.get("name")): item for item in current}
    for definition in groups:
        name = str(definition["name"])
        item = by_name.get(name, {"name": name, "type": "select"})
        item["type"] = "select"
        item["proxies"] = normalize_members(list(definition.get("members") or []), "clash")
        by_name[name] = item
    ordered: list[dict[str, Any]] = []
    emitted: set[str] = set()
    for name in order:
        if name in by_name and name not in emitted:
            ordered.append(by_name[name]); emitted.add(name)
    for item in current:
        name = str(item.get("name"))
        if name not in emitted:
            ordered.append(by_name[name]); emitted.add(name)
    for definition in groups:
        name = str(definition["name"])
        if name not in emitted:
            ordered.append(by_name[name]); emitted.add(name)
    document["proxy-groups"] = ordered


def apply_sing_groups(document: dict[str, Any], groups: list[dict[str, Any]], order: list[str], remove: set[str]) -> None:
    outbounds = [item for item in list(document.get("outbounds") or [])
                 if not (item.get("type") == "selector" and str(item.get("tag")) in remove)]
    selectors = {str(item.get("tag")): item for item in outbounds if item.get("type") == "selector"}
    non_selectors = [item for item in outbounds if item.get("type") != "selector"]
    for definition in groups:
        name = str(definition["name"])
        item = selectors.get(name, {"type": "selector", "tag": name})
        item["type"] = "selector"
        item["tag"] = name
        item["outbounds"] = normalize_members(list(definition.get("members") or []), "sing_box")
        item["default"] = item["outbounds"][0]
        selectors[name] = item
    ordered: list[dict[str, Any]] = []
    emitted: set[str] = set()
    for name in order:
        if name in selectors and name not in emitted:
            ordered.append(selectors[name]); emitted.add(name)
    for item in outbounds:
        if item.get("type") == "selector":
            name = str(item.get("tag"))
            if name not in emitted:
                ordered.append(selectors[name]); emitted.add(name)
    for definition in groups:
        name = str(definition["name"])
        if name not in emitted:
            ordered.append(selectors[name]); emitted.add(name)
    document["outbounds"] = non_selectors + ordered


def validate_group_graph(groups: list[dict[str, Any]], node_names: set[str]) -> None:
    group_names = {str(item["name"]) for item in groups}
    builtins = {"DIRECT", "REJECT", "BLOCK"}
    graph: dict[str, list[str]] = {}
    for group in groups:
        name = str(group["name"])
        members = [str(item) for item in group.get("members") or []]
        if not members:
            fail(f"selector group has no members: {name}")
        missing = [item for item in members if item not in node_names and item not in group_names and item not in builtins]
        if missing:
            fail(f"group {name} references unknown members: {', '.join(missing)}")
        graph[name] = [item for item in members if item in group_names]
    visiting: set[str] = set()
    visited: set[str] = set()
    def visit(name: str) -> None:
        if name in visiting:
            fail(f"selector cycle detected at: {name}")
        if name in visited:
            return
        visiting.add(name)
        for child in graph.get(name, []):
            visit(child)
        visiting.remove(name); visited.add(name)
    for name in graph:
        visit(name)


def validate_rendered_references(clash: dict[str, Any], sing: dict[str, Any]) -> None:
    clash_nodes = {str(item.get("name")) for item in clash.get("proxies") or []}
    clash_groups = {str(item.get("name")) for item in clash.get("proxy-groups") or []}
    for group in clash.get("proxy-groups") or []:
        missing = [str(item) for item in group.get("proxies") or []
                   if str(item) not in clash_nodes and str(item) not in clash_groups and str(item) not in {"DIRECT", "REJECT"}]
        if missing:
            fail(f"rendered Clash group {group.get('name')} has unknown members: {', '.join(missing)}")
    sing_tags = {str(item.get("tag")) for item in sing.get("outbounds") or []}
    for outbound in sing.get("outbounds") or []:
        if outbound.get("type") == "selector":
            missing = [str(item) for item in outbound.get("outbounds") or [] if str(item) not in sing_tags]
            if missing:
                fail(f"rendered sing-box selector {outbound.get('tag')} has unknown members: {', '.join(missing)}")
        detour = outbound.get("detour")
        if detour and str(detour) not in sing_tags:
            fail(f"rendered sing-box outbound {outbound.get('tag')} has unknown detour: {detour}")
    route = sing.get("route") or {}
    final = route.get("final")
    if final and str(final) not in sing_tags:
        fail(f"rendered sing-box route has unknown final outbound: {final}")
    def check_route_rules(value: Any) -> None:
        if isinstance(value, dict):
            outbound = value.get("outbound")
            if outbound and str(outbound) not in sing_tags:
                fail(f"rendered sing-box route rule has unknown outbound: {outbound}")
            for child in value.values():
                check_route_rules(child)
        elif isinstance(value, list):
            for child in value:
                check_route_rules(child)
    check_route_rules(route.get("rules") or [])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--clash", type=Path, required=True)
    parser.add_argument("--sing-box", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    if int(spec.get("schema_version", 0)) != 1:
        fail("unsupported client layout spec schema")
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    with args.clash.open("r", encoding="utf-8") as handle:
        clash = yaml.load(handle)
    sing = json.loads(args.sing_box.read_text(encoding="utf-8"))
    nodes = collect_nodes(spec, clash, sing)
    groups = copy.deepcopy(spec.get("groups") or [])
    order = [str(value) for value in spec.get("group_order") or []]
    remove_groups = {str(value) for value in spec.get("remove_groups") or []}
    if remove_groups & {str(group["name"]) for group in groups}:
        fail("a selector cannot be both generated and removed")
    validate_group_graph(groups, {str(node["name"]) for node in nodes})
    clash_nodes = [copy.deepcopy(node["clash"]) for node in nodes]
    sing_nodes = [copy.deepcopy(node["sing_box"]) for node in nodes]
    clash["proxies"] = replace_named(list(clash.get("proxies") or []), "name", clash_nodes)
    sing["outbounds"] = replace_named(list(sing.get("outbounds") or []), "tag", sing_nodes)
    apply_clash_groups(clash, groups, order, remove_groups)
    apply_sing_groups(sing, groups, order, remove_groups)
    validate_rendered_references(clash, sing)

    args.output.mkdir(parents=True, exist_ok=True)
    clash_path = args.output / "Clash_General.candidate.yaml"
    with clash_path.open("w", encoding="utf-8", newline="\n") as handle:
        yaml.dump(clash, handle)
    sing_path = args.output / "sing-box-general.candidate.json"
    # The desktop IPC path has a practical 4 MiB ceiling.  Keep the private
    # spec/manifest readable, but serialize the runtime profile compactly.
    sing_path.write_text(json.dumps(sing, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    manifest = {
        "schema_version": 1,
        "generated_nodes": [str(node["name"]) for node in nodes],
        "groups": [str(group["name"]) for group in groups],
        "removed_groups": sorted(remove_groups),
        "authoritative_files_modified": False,
        "source_clash": str(args.clash),
        "source_sing_box": str(args.sing_box),
    }
    (args.output / "candidate-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
