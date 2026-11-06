#!/usr/bin/env python3
"""Dynamisches Ansible-Inventar aus NetBox.

Quelle ist derselbe Export wie fuer die Doku (netbox-hosts.mjs im Doku-Repo), damit es nur
eine Abbildung von NetBox auf Host-Daten gibt. Ablauf:

1. Export frisch aus NetBox ziehen (MCP-Server, ohne Token) in den Cache
   ~/.cache/tk-baseline/netbox-hosts.json.
2. Klappt das nicht (NetBox weg, kein Node), den letzten Export aus dem Doku-Repo nehmen:
   infrastructure/inventory/netbox-hosts.json. Kein Dienst haengt zur Laufzeit an NetBox.

Umgebung:
  TK_DOKU_REPO          Pfad zum Doku-Repo (Standard ~/workdir/doku)
  NETBOX_MCP_URL        MCP-Endpunkt (Standard http://netbox.hz1.tkth.eu:8050/mcp)
  NETBOX_TOKEN          statt MCP die REST-API mit Token verwenden
  TK_INVENTORY_OFFLINE  1 = NetBox nicht fragen, nur den Export aus dem Doku-Repo lesen

Gruppen: linux (alle aktiven Linux-Gaeste), baseline (linux ohne Ausnahmen), lxc, vm,
zone_<zone>, class_<crit|std>, env_<prd|tst>.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

DOKU = Path(os.environ.get("TK_DOKU_REPO", Path.home() / "workdir" / "doku"))
EXPORTER = DOKU / ".vitepress" / "scripts" / "netbox-hosts.mjs"
FALLBACK = DOKU / "infrastructure" / "inventory" / "netbox-hosts.json"
CACHE = Path.home() / ".cache" / "tk-baseline" / "netbox-hosts.json"
MCP_URL = os.environ.get("NETBOX_MCP_URL", "http://netbox.hz1.tkth.eu:8050/mcp")

# Gaeste, die sich selbst verwalten oder kein Linux sind, bleiben draussen.
# 850 Saltbox: eigene Verwaltung (Entscheidung 2026-11-06).
EXCLUDE_VMIDS = {850}
TAG_CLASSES = ("crit", "std")
TAG_ENVS = ("prd", "tst", "dev")


def log(msg):
    print(f"netbox.py: {msg}", file=sys.stderr)


def refresh():
    if os.environ.get("TK_INVENTORY_OFFLINE") == "1" or not EXPORTER.exists():
        return None
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE.with_suffix(".tmp")
    cmd = ["node", str(EXPORTER), "--out", str(tmp)]
    if not os.environ.get("NETBOX_TOKEN"):
        cmd += ["--mcp", MCP_URL]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as err:
        log(f"Export aus NetBox nicht moeglich ({err.__class__.__name__}), nehme Export aus dem Doku-Repo")
        return None
    if res.returncode != 0 or not tmp.exists():
        log(f"Export aus NetBox fehlgeschlagen: {res.stderr.strip()[:200]}; nehme Export aus dem Doku-Repo")
        return None
    tmp.replace(CACHE)
    return CACHE


def load():
    fresh = refresh()
    data = json.loads((fresh or FALLBACK).read_text())
    if not fresh:
        log(f"Quelle {FALLBACK} (Stand {data.get('generated', '?')})")
    return data


def slim(host):
    """Nur, was Rolle und MOTD brauchen. Journale bleiben draussen."""
    v = host.get("vars", {})
    tags = [t for t in str(v.get("TAGS", "")).split(";") if t]
    return {
        "name": host["name"],
        "vmid": v.get("VMID"),
        "typ": v.get("TYP"),
        "zone": v.get("ZONE"),
        "vlan": v.get("VLAN_TAG"),
        "ip": v.get("IP"),
        "description": host.get("description") or "",
        "platform": host.get("platform") or "",
        "tags": tags,
        "class": next((t for t in tags if t in TAG_CLASSES), None),
        "env": next((t for t in tags if t in TAG_ENVS), None),
        "fqdns": host.get("fqdns", []),
        "services": [
            {"name": s["name"], "protocol": s.get("protocol"), "ports": s.get("ports", []), "description": s.get("description", "")}
            for s in host.get("services", [])
            if not str(s.get("description", "")).startswith("VERALTET")
        ],
        "disks": [
            {k: d.get(k) for k in ("name", "sizeGb", "storage", "mountpoint", "description")}
            for d in host.get("disks", [])
        ],
        "netbox": host.get("netbox"),
    }


def build(data):
    groups = {"linux": [], "baseline": [], "lxc": [], "vm": []}
    hostvars = {}
    for host in data["hosts"]:
        v = host.get("vars", {})
        status = host.get("status")
        if status not in ("active", "planned") or not str(host.get("platform", "")).startswith(("Ubuntu", "Debian")):
            continue
        if not v.get("IP"):
            continue
        nb = slim(host)
        name = nb["name"]
        hostvars[name] = {"ansible_host": nb["ip"], "nb": nb}
        # Gaeste im Aufbau: nur in der Gruppe planned, Laeufe mit -e target=<gast>
        if status == "planned":
            groups.setdefault("planned", []).append(name)
            continue
        groups["linux"].append(name)
        if nb["vmid"] not in EXCLUDE_VMIDS:
            groups["baseline"].append(name)
        groups["lxc" if nb["typ"] == "LXC" else "vm"].append(name)
        for key, prefix in (("zone", "zone_"), ("class", "class_"), ("env", "env_")):
            if nb[key]:
                groups.setdefault(prefix + str(nb[key]).lower(), []).append(name)
    inv = {g: {"hosts": sorted(h)} for g, h in groups.items()}
    inv["_meta"] = {"hostvars": hostvars}
    return inv


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--host":
        print("{}")
        return
    print(json.dumps(build(load()), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
