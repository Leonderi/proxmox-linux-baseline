#!/usr/bin/env bash
# managed by proxmox-linux-baseline (Ansible)
#
# tk – Werkzeugkasten fuer die tk-thran-Gaeste. "tk help" zeigt die Befehle.
set -u

# shellcheck source=/dev/null
. /usr/local/lib/tk/motd-render
tk_colors

SUDO=()
[[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && SUDO=(sudo -n)

h1() { printf '\n%s%s%s\n' "$C_V" "$*" "$C_R"; }
ok() { printf '  %s✓%s %s\n' "$C_G" "$C_R" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$C_W" "$C_R" "$*"; }
need_docker() { tk_docker info >/dev/null || { echo "tk: kein Zugriff auf Docker (Gruppe docker, neu anmelden)" >&2; exit 1; }; }

cmd_help() {
    cat <<EOF
tk – Werkzeugkasten (proxmox-linux-baseline)

  tk ps                Container: Name, Zustand und Health, Image, Laufzeit; Probleme oben
  tk status            MOTD, fehlgeschlagene Units, Dienste mit altem Code (needrestart)
  tk logs <dienst> [n] letzte n Zeilen (Standard 100) eines Containers oder einer Unit, -f folgt
  tk stacks            Compose-Projekte mit Zustand und Pfad
  tk updates           offene Updates, letzter unattended-upgrades-Lauf, Neustart nötig?
  tk net               Adressen, Route, DNS, lauschende Ports
  tk doctor            Prüfliste der Baseline mit ✓ und ⚠
  tk info              Steckbrief aus NetBox (/etc/tk/host.json)
EOF
}

cmd_ps() {
    need_docker
    # Probleme zuerst: nicht laufend (ausser sauber beendet) oder ungesund
    tk_docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}|{{.RunningFor}}' \
    | awk -F'|' '
        {
            health = "-"
            if ($3 ~ /\(unhealthy\)/) health = "unhealthy"; else if ($3 ~ /\(healthy\)/) health = "healthy"; else if ($3 ~ /health: starting/) health = "starting"
            rank = 2
            if ($2 == "exited" && $3 ~ /^Exited \(0\)/) rank = 1
            else if ($2 != "running" || health == "unhealthy") rank = 0
            printf "%d|%s|%s|%s|%s|%s\n", rank, $1, $2, health, $4, $5
        }' \
    | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2- \
    | { printf 'NAME|ZUSTAND|HEALTH|IMAGE|SEIT\n'; cat; } | column -t -s'|'
}

cmd_status() {
    tk_motd_main
    h1 "Fehlgeschlagene Units"
    local failed
    failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null)
    if [[ -n "$failed" ]]; then printf '%s\n' "$failed" | sed 's/^/  /'; else ok "keine"; fi
    if command -v needrestart >/dev/null 2>&1 && ((${#SUDO[@]} || EUID == 0)); then
        h1 "Dienste mit altem Code (needrestart)"
        local svc
        svc=$("${SUDO[@]}" needrestart -b 2>/dev/null | awk -F': ' '/^NEEDRESTART-SVC/ {print $2}')
        if [[ -n "$svc" ]]; then printf '%s\n' "$svc" | sed 's/^/  /'; else ok "keine"; fi
    fi
}

cmd_logs() {
    local name="${1:-}" lines=100 follow=()
    [[ -n "$name" ]] || { echo "tk logs <container|unit> [zeilen] [-f]" >&2; exit 2; }
    shift
    for a in "$@"; do
        case "$a" in -f) follow=(-f) ;; *[!0-9]*) ;; *) lines=$a ;; esac
    done
    if tk_docker inspect "$name" >/dev/null; then
        exec docker logs --tail "$lines" --timestamps "${follow[@]}" "$name"
    fi
    local unit="$name"
    [[ "$unit" == *.* ]] || unit="$unit.service"
    if systemctl cat "$unit" >/dev/null 2>&1; then
        exec "${SUDO[@]}" journalctl -u "$unit" -n "$lines" --no-pager "${follow[@]}"
    fi
    echo "tk: weder Container noch Unit '$name'" >&2
    exit 1
}

cmd_stacks() {
    need_docker
    if tk_docker compose version >/dev/null; then
        docker compose ls -a
    else
        tk_docker ps -a --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}' \
            | sort -u | column -t -s'|'
    fi
}

cmd_updates() {
    local n=? sec=?
    [[ -r /var/lib/tk/apt-check ]] && IFS=';' read -r n sec < /var/lib/tk/apt-check
    h1 "Offene Updates"
    printf '  %s insgesamt, davon %s Sicherheitsupdates (Stand %s)\n' "$n" "$sec" \
        "$(date -r /var/lib/tk/apt-check '+%F %R' 2>/dev/null || echo unbekannt)"
    apt list --upgradable 2>/dev/null | awk -F/ 'NR > 1 { print "  " $1 }' | head -30
    h1 "unattended-upgrades"
    if [[ "$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null)" == *'"1"'* ]]; then ok "täglich aktiv"; else warn "nicht aktiv"; fi
    local log=/var/log/unattended-upgrades/unattended-upgrades.log
    if [[ -r "$log" ]]; then
        grep -E 'Packages that will be upgraded|No packages found|All upgrades installed|error|ERROR' "$log" | tail -4 | sed 's/^/  /'
    else
        "${SUDO[@]}" tail -n 4 "$log" 2>/dev/null | sed 's/^/  /' || echo "  noch kein Lauf protokolliert"
    fi
    h1 "Neustart"
    if [[ -e /var/run/reboot-required ]]; then
        warn "nötig wegen: $(paste -sd' ' /var/run/reboot-required.pkgs 2>/dev/null)"
    else
        ok "nicht nötig"
    fi
}

cmd_net() {
    h1 "Adressen"; ip -br addr | grep -vE '^(lo|veth|br-|docker)' | sed 's/^/  /'
    h1 "Route"; ip route show default | sed 's/^/  /'
    h1 "DNS"
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl dns 2>/dev/null | grep -v ': *$' | sed 's/^/  /'
    else
        grep ^nameserver /etc/resolv.conf | sed 's/^/  /'
    fi
    h1 "Lauschende Ports (TCP)"
    "${SUDO[@]}" ss -Htlnp 2>/dev/null | awk '{ sub(/users:\(\("/, "", $6); sub(/".*/, "", $6); printf "  %-28s %s\n", $4, $6 }' | sort -u
}

cmd_doctor() {
    local problems
    h1 "Baseline"
    [[ -r /etc/tk/host.json ]] && ok "Steckbrief aus NetBox vom $(date -r /etc/tk/host.json '+%F')" || warn "kein Steckbrief /etc/tk/host.json"
    [[ "$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f7)" == */zsh ]] && ok "Login-Shell zsh" || warn "Login-Shell ist nicht zsh"
    command -v starship >/dev/null 2>&1 && ok "$(starship --version | head -1)" || warn "starship fehlt"
    [[ -r /usr/share/oh-my-zsh/.tk-version ]] && ok "oh-my-zsh $(cat /usr/share/oh-my-zsh/.tk-version)" || warn "oh-my-zsh nicht aus der Baseline"
    h1 "Sicherheit"
    if "${SUDO[@]}" sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; then ok "SSH nur mit Schlüssel"; else warn "SSH erlaubt Passwörter (oder sshd -T nicht lesbar)"; fi
    [[ "$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null)" == *'"1"'* ]] && ok "unattended-upgrades aktiv" || warn "unattended-upgrades nicht aktiv"
    h1 "Betrieb"
    if [[ "$(systemd-detect-virt 2>/dev/null)" == lxc ]]; then
        ok "Zeit kommt vom Host (LXC)"
    elif [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then
        ok "Zeit synchronisiert"
    else
        warn "Zeit nicht synchronisiert"
    fi
    local j
    j=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)
    ok "Journal ${j:-?} (Grenze $(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | awk -F= '/^SystemMaxUse/ {v=$2} END {print v ? v : "Standard"}'))"
    getent hosts doku.tk-thran.com >/dev/null && ok "DNS löst doku.tk-thran.com auf" || warn "DNS löst doku.tk-thran.com nicht auf"
    problems=$(tk_motd_problems)
    if [[ -n "$problems" ]]; then
        while IFS= read -r p; do warn "$p"; done <<<"$problems"
    else
        ok "keine Warnungen (Neustart, Sicherheitsupdates, Units, Platten, Container)"
    fi
}

cmd_info() {
    command -v python3 >/dev/null 2>&1 || { cat /etc/tk/host.json; return; }
    python3 - <<'PY_INFO'
import json
d = json.load(open("/etc/tk/host.json"))
h = d.get("host", {})
print("{} ({} {}), Zone {}, {}".format(h.get("name"), h.get("typ"), h.get("vmid"), h.get("zone"), h.get("ip")))
print(h.get("description", ""))
print("Klasse:", h.get("class"), "·", d.get("backup"), "· Tags:", ";".join(h.get("tags", [])))
for s in h.get("services", []):
    ports = ",".join(str(p) for p in s.get("ports", []))
    print("  {:<16} {}/{}  {}".format(s["name"], s.get("protocol") or "", ports, (s.get("description") or "")[:70]))
for f in h.get("fqdns", []):
    print("  https://" + f)
print("Doku:  ", d.get("doku"))
print("NetBox:", h.get("netbox"))
PY_INFO
}

case "${1:-help}" in
    ps|status|logs|stacks|updates|net|doctor|info|help) c="$1"; shift || true; "cmd_$c" "$@" ;;
    -h|--help) cmd_help ;;
    *) echo "tk: unbekannter Befehl '$1'" >&2; cmd_help >&2; exit 2 ;;
esac
