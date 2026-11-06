#!/usr/bin/env python3
# managed by proxmox-linux-baseline (Ansible)
"""tk – Werkzeugkasten fuer die tk-thran-Gaeste. Ausgaben als Tabellen im Stil von cscli.

"tk help" zeigt die Befehle. Warnungen und Plattenwerte kommen aus dem MOTD-Renderer
(/usr/local/lib/tk/motd-render), damit MOTD und tk dasselbe melden.
"""
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata

RENDER = "/usr/local/lib/tk/motd-render"
HOST_JSON = "/etc/tk/host.json"
APT_CHECK = "/var/lib/tk/apt-check"
UU_LOG = "/var/log/unattended-upgrades/unattended-upgrades.log"
DOCKER_PKGS = {"docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin", "docker-ce-rootless-extras"}

# --------------------------------------------------------------------------- Ausgabe

ANSI = re.compile(r"\x1b\[[0-9;]*m")
COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR") and os.environ.get("TERM", "dumb") != "dumb"


def rgb(r, g, b, fallback):
    if not COLOR:
        return ""
    if os.environ.get("TERM") == "linux":
        return f"\x1b[38;5;{fallback}m"
    return f"\x1b[38;2;{r};{g};{b}m"


BOLD = "\x1b[1m" if COLOR else ""
RESET = "\x1b[0m" if COLOR else ""
DIM = "\x1b[90m" if COLOR else ""
PURPLE = rgb(0x90, 0x40, 0xD0, 98)       # Firmen-Lila #9040D0
LILAC = rgb(0xC9, 0xA6, 0xEC, 183)
GOOD = rgb(0x7C, 0xC4, 0x7F, 114)
WARN = rgb(0xE5, 0xC0, 0x7B, 180)
BAD = rgb(0xE0, 0x6C, 0x75, 174)

GOOD_WORDS = {"running", "healthy", "ok", "✓", "aktiv", "ja", "up", "läuft", "gesund", "nicht nötig"}
BAD_WORDS = {"exited", "unhealthy", "failed", "✗", "dead", "fehlt", "nein"}
WARN_WORDS = {"starting", "restarting", "⚠", "paused", "created", "nötig", "offen"}


def width(text):
    text = ANSI.sub("", str(text))
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 0 if unicodedata.combining(c) else 1 for c in text)


def paint(cell):
    cell = str(cell)
    if not COLOR or "\x1b" in cell:
        return cell
    key = cell.strip().lower()
    first = key.split(" ")[0] if key else ""
    for words, col in ((GOOD_WORDS, GOOD), (BAD_WORDS, BAD), (WARN_WORDS, WARN)):
        if key in words or first in words:
            return col + cell + RESET
    if key in {"-", "–", ""}:
        return DIM + cell + RESET
    return cell


def pad(cell, w, align="<"):
    gap = w - width(cell)
    if align == "^":
        return " " * (gap // 2) + cell + " " * (gap - gap // 2)
    if align == ">":
        return " " * gap + cell
    return cell + " " * gap


def table(head, rows, title=None, align=None, maxwidth=None):
    """Rahmentabelle. align: Zeichenkette mit < > je Spalte."""
    cols = len(head)
    rows = [[paint(c) for c in (list(r) + [""] * cols)[:cols]] for r in rows]
    align = (align or "<" * cols).ljust(cols, "<")
    term = maxwidth or shutil.get_terminal_size((160, 40)).columns
    widths = [max([width(h)] + [width(r[i]) for r in rows]) for i, h in enumerate(head)]
    # zu breit: die breiteste Spalte kuerzen
    while sum(widths) + 3 * cols + 1 > term and max(widths) > 12:
        i = widths.index(max(widths))
        widths[i] -= 1
        rows = [r[:i] + [cut(r[i], widths[i])] + r[i + 1:] for r in rows]

    def line(left, mid, right):
        return PURPLE + left + mid.join("─" * (w + 2) for w in widths) + right + RESET

    bar = PURPLE + "│" + RESET
    out = []
    if title:
        out.append(f"{BOLD}{PURPLE}{title}{RESET}")
    out.append(line("╭", "┬", "╮"))
    out.append(bar + bar.join(f" {BOLD}{LILAC}{pad(h, widths[i], '^')}{RESET} " for i, h in enumerate(head)) + bar)
    out.append(line("├", "┼", "┤"))
    if not rows:
        inner = sum(widths) + 3 * cols - 1
        out.append(bar + " " + DIM + pad("keine Einträge", inner - 2) + RESET + " " + bar)
    for r in rows:
        out.append(bar + bar.join(f" {pad(c, widths[i], align[i])} " for i, c in enumerate(r)) + bar)
    out.append(line("╰", "┴", "╯"))
    print("\n".join(out))


def cut(cell, w):
    plain = ANSI.sub("", cell)
    if width(plain) <= w:
        return cell
    out = ""
    for ch in plain:
        if width(out + ch + "…") > w:
            break
        out += ch
    return out + "…"


def mark(ok, warn_only=False):
    if ok:
        return "✓"
    return "⚠" if warn_only else "✗"


# --------------------------------------------------------------------------- Helfer

def run(cmd, sudo=False, timeout=15):
    if sudo and os.geteuid() != 0:
        cmd = ["sudo", "-n"] + cmd
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return res.stdout if res.returncode == 0 else ""


def can_sudo():
    return os.geteuid() == 0 or subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0


def render_fn(fn):
    return run(["bash", "-c", f". {RENDER}; tk_colors() {{ :; }}; C_P= C_L= C_V= C_T= C_D= C_R= C_W= C_G= C_E=; {fn}"])


def problems():
    return [p for p in render_fn("tk_motd_problems").splitlines() if p.strip()]


def disk_rows():
    rows = []
    for line in render_fn("tk_disk_rows").splitlines():
        p = line.split("|")
        if len(p) == 8:
            rows.append(dict(zip(("name", "mount", "kind", "size", "used", "total", "pct", "state"), p)))
    return rows


def docker_ok():
    return shutil.which("docker") and run(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=5).strip()


def need_docker():
    if not docker_ok():
        sys.exit("tk: kein Zugriff auf Docker (Gruppe docker, neu anmelden)")


def parse_time(ts):
    if not ts or ts.startswith("0001"):
        return None
    ts = re.sub(r"\.(\d{6})\d*", r".\1", ts).replace("Z", "+00:00")
    try:
        return datetime.datetime.fromisoformat(ts)
    except ValueError:
        return None


def since(ts):
    t = parse_time(ts) if isinstance(ts, str) else ts
    if not t:
        return "-"
    s = int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds())
    for size, one, many in ((31536000, "Jahr", "Jahre"), (2592000, "Monat", "Monate"), (604800, "Woche", "Wochen"),
                            (86400, "Tag", "Tage"), (3600, "Std", "Std"), (60, "Min", "Min")):
        if s >= size:
            n = s // size
            return f"{n} {one if n == 1 else many}"
    return f"{s} Sek"


def apt_counts():
    try:
        n, sec = open(APT_CHECK).read().strip().split(";")
        return int(n), int(sec), datetime.datetime.fromtimestamp(os.path.getmtime(APT_CHECK))
    except (OSError, ValueError):
        return None, None, None


def uu_active():
    return '"1"' in run(["apt-config", "dump", "APT::Periodic::Unattended-Upgrade"])


def is_lxc():
    return run(["systemd-detect-virt"]).strip() == "lxc"


# --------------------------------------------------------------------------- Befehle

def cmd_help(_):
    table(["Befehl", "Zeigt"], [
        ["tk ps", "Container: Zustand, Health, Image, Version, Laufzeit, Neustarts. Probleme oben"],
        ["tk status", "Überblick: System, RAM, Platten, Docker, Updates, Units, needrestart"],
        ["tk logs <dienst> [n] [-f]", "Log eines Containers oder einer Unit (letzte n Zeilen, -f folgt)"],
        ["tk stacks", "Compose-Projekte mit Zustand und Datei"],
        ["tk updates", "offene Updates je Paket, unattended-upgrades, Neustart"],
        ["tk net", "Schnittstellen, Route, DNS, lauschende Ports"],
        ["tk doctor", "Prüfliste der Baseline"],
        ["tk info", "Steckbrief aus NetBox: Dienste, Platten, Links"],
    ], title="tk – Werkzeugkasten (proxmox-linux-baseline)")


def cmd_ps(_):
    need_docker()
    ids = run(["docker", "ps", "-aq"]).split()
    if not ids:
        table(["Name", "Zustand", "Health", "Image", "Version", "Läuft seit", "Neustarts"], [], title="Container")
        return
    data = json.loads(run(["docker", "inspect"] + ids) or "[]")
    rows = []
    for c in data:
        st = c.get("State", {})
        state = st.get("Status", "?")
        health = (st.get("Health") or {}).get("Status", "-")
        if state == "exited":
            state = f"exited ({st.get('ExitCode')})"
        labels = c.get("Config", {}).get("Labels") or {}
        version = labels.get("org.opencontainers.image.version") or "-"
        ts = st.get("StartedAt") if st.get("Running") else st.get("FinishedAt")
        rank = 2
        if state.startswith("exited (0)"):
            rank = 1
        elif state != "running" or health == "unhealthy":
            rank = 0
        rows.append((rank, [c["Name"].lstrip("/"), state, health, c.get("Config", {}).get("Image", "?"), version,
                            since(ts), str(c.get("RestartCount", 0))]))
    rows.sort(key=lambda r: (r[0], r[1][0]))
    table(["Name", "Zustand", "Health", "Image", "Version", "Läuft seit", "Neustarts"], [r for _, r in rows],
          title="Container", align="<<<<<>>")


def cmd_status(_):
    rows = []
    osr = dict(line.split("=", 1) for line in open("/etc/os-release").read().splitlines() if "=" in line)
    rows.append(["System", f"{osr.get('PRETTY_NAME', '?').strip(chr(34))} · Kernel {os.uname().release}", "✓"])
    up = float(open("/proc/uptime").read().split()[0])
    rows.append(["Laufzeit", since(datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=up)), "✓"])
    if not is_lxc():
        rows.append(["Last", " ".join(open("/proc/loadavg").read().split()[:3]), "✓"])
    mem = {k: int(v.split()[0]) * 1024 for k, v in (l.split(":", 1) for l in open("/proc/meminfo"))}
    used = mem["MemTotal"] - mem["MemAvailable"]
    pct = used * 100 // max(mem["MemTotal"], 1)
    rows.append(["RAM", f"{human(used)} / {human(mem['MemTotal'])} ({pct} %)", mark(pct < 90, True)])
    for d in disk_rows():
        if d["state"] == "fehlt":
            rows.append([f"Platte {d['name']}", f"{d['mount']} nicht eingehängt", "✗"])
        else:
            p = int(d["pct"])
            rows.append([f"Platte {d['name']}", f"{d['mount']} · {d['kind']} · {d['used']} / {d['total']} ({p} %)", mark(p < 85, True)])
    if docker_ok():
        total = len(run(["docker", "ps", "-aq"]).split())
        running = len(run(["docker", "ps", "-q"]).split())
        sick = len(run(["docker", "ps", "-q", "--filter", "health=unhealthy"]).split())
        rows.append(["Docker", f"{running}/{total} laufen, {sick} ungesund", mark(running == total and sick == 0, True)])
    n, sec, _ = apt_counts()
    if n is not None:
        rows.append(["Updates", f"{n} offen, davon {sec} Sicherheit", mark(sec == 0, True)])
    reboot = os.path.exists("/var/run/reboot-required")
    rows.append(["Neustart", "nötig" if reboot else "nicht nötig", mark(not reboot, True)])
    failed = [l.split(None, 4) for l in run(["systemctl", "list-units", "--state=failed", "--no-legend", "--plain"]).splitlines() if l.strip()]
    rows.append(["Units", f"{len(failed)} fehlgeschlagen", mark(not failed, True)])
    svc = []
    if shutil.which("needrestart") and can_sudo():
        svc = [l.split(": ", 1)[1] for l in run(["needrestart", "-b"], sudo=True, timeout=60).splitlines() if l.startswith("NEEDRESTART-SVC")]
        rows.append(["needrestart", f"{len(svc)} Dienste mit altem Code", mark(not svc, True)])
    table(["Bereich", "Zustand", ""], rows, title=f"Status {os.uname().nodename}")
    if failed:
        print()
        table(["Unit", "Zustand", "Beschreibung"], [[f[0], f"{f[2]} {f[3]}", f[4] if len(f) > 4 else ""] for f in failed], title="Fehlgeschlagene Units")
    if svc:
        print()
        table(["Dienst"], [[s] for s in svc], title="Dienste mit altem Code (Neustart empfohlen)")


def human(n):
    for unit in ("B", "K", "M", "G", "T"):
        if abs(n) < 1024 or unit == "T":
            return f"{n:.1f}{unit}" if unit not in ("B", "K") and n < 10 else f"{n:.0f}{unit}"
        n /= 1024
    return str(n)


def cmd_logs(args):
    if not args:
        sys.exit("tk logs <container|unit> [zeilen] [-f]")
    name, rest = args[0], args[1:]
    lines = next((a for a in rest if a.isdigit()), "100")
    follow = ["-f"] if "-f" in rest else []
    if docker_ok() and run(["docker", "inspect", "--format", "{{.Name}}", name]).strip():
        os.execvp("docker", ["docker", "logs", "--tail", lines, "--timestamps"] + follow + [name])
    unit = name if "." in name else name + ".service"
    if subprocess.run(["systemctl", "cat", unit], capture_output=True).returncode == 0:
        cmd = ["journalctl", "-u", unit, "-n", lines, "--no-pager"] + follow
        if os.geteuid() != 0 and can_sudo():
            cmd = ["sudo", "-n"] + cmd
        os.execvp(cmd[0], cmd)
    sys.exit(f"tk: weder Container noch Unit '{name}'")


def cmd_stacks(_):
    need_docker()
    projects = json.loads(run(["docker", "compose", "ls", "-a", "--format", "json"]) or "[]")
    counts = {}
    for line in run(["docker", "ps", "-a", "--format", '{{.Label "com.docker.compose.project"}}|{{.State}}']).splitlines():
        proj, _, state = line.partition("|")
        c = counts.setdefault(proj, [0, 0])
        c[1] += 1
        c[0] += state == "running"
    rows = []
    for p in projects:
        run_, all_ = counts.get(p["Name"], [0, 0])
        rows.append([p["Name"], p.get("Status", "?").split("(")[0], f"{run_}/{all_}", p.get("ConfigFiles", "")])
    table(["Projekt", "Zustand", "Container", "Compose-Datei"], rows, title="Compose-Projekte", align="<<><")


def cmd_updates(_):
    n, sec, stamp = apt_counts()
    last = "-"
    log = run(["tail", "-n", "200", UU_LOG], sudo=True)
    for line in reversed(log.splitlines()):
        if re.search(r"(Packages that will be upgraded|No packages found|All upgrades installed|ERROR)", line):
            last = line[:16] + " " + re.sub(r"^\S+ \S+ \w+ ", "", line)[:50]
            break
    reboot = os.path.exists("/var/run/reboot-required")
    rows = [
        ["Offene Updates", "-" if n is None else str(n), mark(n == 0, True) if n is not None else "-"],
        ["davon Sicherheit", "-" if sec is None else str(sec), mark(sec == 0, True) if sec is not None else "-"],
        ["Stand der Zählung", stamp.strftime("%Y-%m-%d %H:%M") if stamp else "-", "-"],
        ["unattended-upgrades", "täglich aktiv" if uu_active() else "nicht aktiv", mark(uu_active())],
        ["letzter Lauf", last, "-"],
        ["Neustart", "nötig: " + " ".join(open("/var/run/reboot-required.pkgs").read().split()) if reboot and os.path.exists("/var/run/reboot-required.pkgs") else ("nötig" if reboot else "nicht nötig"), mark(not reboot, True)],
    ]
    table(["Punkt", "Wert", ""], rows, title="Updates")
    pkgs = []
    for line in run(["apt", "list", "--upgradable"]).splitlines():
        m = re.match(r"^(\S+?)/(\S+) (\S+) \S+ \[\S+ \S+ (\S+)\]", line)
        if m:
            name, suites, new, old = m.groups()
            security = "-security" in suites
            if name in DOCKER_PKGS:
                pkgs.append([name, old, new, "Docker", "nein (monatlich)"])
            else:
                pkgs.append([name, old, new, "Sicherheit" if security else suites.split(",")[0], "ja" if security and uu_active() else "nein"])
    print()
    table(["Paket", "Installiert", "Neu", "Quelle", "Automatisch"], sorted(pkgs, key=lambda p: (p[3] != "Sicherheit", p[0])), title="Pakete")


def cmd_net(_):
    rows = []
    for i in json.loads(run(["ip", "-j", "addr"]) or "[]"):
        if re.match(r"^(lo|veth|docker|br-)", i["ifname"]):
            continue
        addrs = [f"{a['local']}/{a['prefixlen']}" for a in i.get("addr_info", []) if a.get("scope") == "global"]
        rows.append([i["ifname"], i.get("operstate", "?").lower(), ", ".join(addrs) or "-"])
    table(["Schnittstelle", "Zustand", "Adressen"], rows, title="Netz")
    info = []
    for r in json.loads(run(["ip", "-j", "route", "show", "default"]) or "[]"):
        info.append(["Default-Route", f"{r.get('gateway', '-')} über {r.get('dev', '?')}"])
    dns = re.findall(r"^nameserver\s+(\S+)", open("/run/systemd/resolve/resolv.conf").read() if os.path.exists("/run/systemd/resolve/resolv.conf") else open("/etc/resolv.conf").read(), re.M)
    info.append(["DNS-Server", ", ".join(dns) or "-"])
    search = re.findall(r"^search\s+(.+)$", open("/etc/resolv.conf").read(), re.M)
    info.append(["Suchdomäne", search[0] if search else "-"])
    print()
    table(["Punkt", "Wert"], info, title="Routing und DNS")
    ports = []
    out = run(["ss", "-Htulnp"], sudo=True) or run(["ss", "-Htuln"])
    for line in out.splitlines():
        p = line.split()
        if len(p) < 5:
            continue
        addr, _, port = p[4].rpartition(":")
        proc = re.search(r'users:\(\("([^"]+)"', line)
        ports.append([p[0], addr.strip("[]"), port, proc.group(1) if proc else "-"])
    ports = sorted({tuple(x) for x in ports}, key=lambda x: (x[0], int(x[2]) if x[2].isdigit() else 0, x[1]))
    print()
    table(["Proto", "Adresse", "Port", "Prozess"], ports, title="Lauschende Ports", align="<<><")


def cmd_doctor(_):
    rows = []
    try:
        host = json.load(open(HOST_JSON))
        stamp = datetime.datetime.fromtimestamp(os.path.getmtime(HOST_JSON)).strftime("%Y-%m-%d")
        rows.append(["Steckbrief aus NetBox", f"{host['host'].get('name')}, Stand {stamp}", "✓"])
    except (OSError, ValueError, KeyError):
        rows.append(["Steckbrief aus NetBox", "fehlt", "✗"])
    user = os.environ.get("SUDO_USER") or os.environ.get("USER") or "root"
    shell = run(["getent", "passwd", user]).strip().split(":")[-1]
    rows.append(["Login-Shell", f"{user}: {shell}", mark(shell.endswith("zsh"))])
    star = run(["starship", "--version"]).splitlines()
    rows.append(["starship", star[0] if star else "fehlt", mark(bool(star))])
    try:
        omz = open("/usr/share/oh-my-zsh/.tk-version").read().strip()
        rows.append(["oh-my-zsh", omz, "✓"])
    except OSError:
        rows.append(["oh-my-zsh", "nicht aus der Baseline", "⚠"])
    sshd = run(["sshd", "-T"], sudo=True)
    if sshd:
        pw = "passwordauthentication no" in sshd
        root = "permitrootlogin no" in sshd
        rows.append(["SSH", ("nur Schlüssel" if pw else "Passwörter erlaubt") + (", kein root-Login" if root else ", root-Login erlaubt"), mark(pw and root)])
    else:
        rows.append(["SSH", "sshd -T nicht lesbar (sudo)", "⚠"])
    rows.append(["unattended-upgrades", "täglich aktiv" if uu_active() else "nicht aktiv", mark(uu_active())])
    if is_lxc():
        rows.append(["Zeit", "vom Host (LXC)", "✓"])
    else:
        sync = run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"]).strip() == "yes"
        rows.append(["Zeit", "synchronisiert" if sync else "nicht synchronisiert", mark(sync)])
    jsize = re.search(r"([0-9.]+[KMGT])", run(["journalctl", "--disk-usage"]) or run(["journalctl", "--disk-usage"], sudo=True))
    limit = re.findall(r"^SystemMaxUse=(\S+)", run(["systemd-analyze", "cat-config", "systemd/journald.conf"]), re.M)
    rows.append(["Journal", f"{jsize.group(1) if jsize else '?'} (Grenze {limit[-1] if limit else 'Standard'})", mark(bool(limit), True)])
    dns_ok = subprocess.run(["getent", "hosts", "doku.tk-thran.com"], capture_output=True).returncode == 0
    rows.append(["DNS", "doku.tk-thran.com " + ("aufgelöst" if dns_ok else "nicht auflösbar"), mark(dns_ok)])
    probs = problems()
    for p in probs:
        rows.append(["Warnung", p, "⚠"])
    if not probs:
        rows.append(["Warnungen", "keine (Neustart, Updates, Units, Platten, Container)", "✓"])
    table(["Prüfung", "Ergebnis", ""], rows, title=f"Baseline-Prüfung {os.uname().nodename}")


def cmd_info(_):
    try:
        d = json.load(open(HOST_JSON))
    except (OSError, ValueError):
        sys.exit(f"tk: {HOST_JSON} fehlt")
    h = d.get("host", {})
    rows = [
        ["Name", h.get("name", "?")],
        ["Typ", f"{h.get('typ')} {h.get('vmid')}"],
        ["Zone", f"{h.get('zone')} (VLAN {h.get('vlan')})"],
        ["IP", h.get("ip", "-")],
        ["Beschreibung", h.get("description", "")],
        ["Klasse", h.get("class") or "-"],
        ["Backup", d.get("backup", "-")],
        ["Tags", ";".join(h.get("tags", []))],
    ] + [["Web", "https://" + f] for f in h.get("fqdns", [])] + [
        ["Doku", d.get("doku", "-")],
        ["NetBox", h.get("netbox", "-")],
    ]
    table(["Feld", "Wert"], rows, title="Steckbrief (NetBox)")
    svc = [[s["name"], f"{s.get('protocol') or ''}/{','.join(map(str, s.get('ports', [])))}", s.get("description", "")] for s in h.get("services", [])]
    print()
    table(["Dienst", "Port", "Beschreibung"], svc, title="Dienste")
    disks = [[x.get("name"), x.get("mountpoint") or "-", {"local-lvm": "NVMe", "hdd-zfs": "HDD"}.get(x.get("storage"), x.get("storage") or "-"),
              f"{x.get('sizeGb')}G", x.get("description", "")] for x in sorted(h.get("disks", []), key=lambda x: x.get("mountpoint") or "")]
    print()
    table(["Disk", "Mount", "Speicher", "Größe", "Beschreibung"], disks, title="Platten", align="<<<><")


def cmd_table(args):
    """TSV von stdin als Tabelle, fuer eigene Skripte: ... | tk table [--title X]"""
    title = args[args.index("--title") + 1] if "--title" in args else None
    lines = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip("\n")]
    if lines:
        table(lines[0], lines[1:], title=title)


COMMANDS = {"help": cmd_help, "ps": cmd_ps, "status": cmd_status, "logs": cmd_logs, "stacks": cmd_stacks,
            "updates": cmd_updates, "net": cmd_net, "doctor": cmd_doctor, "info": cmd_info, "table": cmd_table}


def main():
    args = sys.argv[1:] or ["help"]
    if args[0] in ("-h", "--help"):
        args[0] = "help"
    fn = COMMANDS.get(args[0])
    if not fn:
        print(f"tk: unbekannter Befehl '{args[0]}'", file=sys.stderr)
        cmd_help([])
        sys.exit(2)
    try:
        fn(args[1:])
    except BrokenPipeError:
        pass
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
