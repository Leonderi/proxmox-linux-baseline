#!/usr/bin/env bash
# managed by proxmox-linux-baseline (Ansible)
#
# MOTD in drei Teilen:
#   1. Kopf aus /etc/tk/motd-head: Banner und Steckbrief, von Ansible aus NetBox geschrieben
#   2. Systemzustand: Distribution, Laufzeit, Last, Speicher, Platten, Container
#   3. Warnblock, nur wenn etwas nicht stimmt
# Mit "tk_motd_problems" (fuer tk doctor) lassen sich die Warnungen auch einzeln abfragen.
set -u

TK_DISK_WARN="${TK_DISK_WARN:-85}"
HEAD=/etc/tk/motd-head

tk_colors() {
    if [[ -n "${NO_COLOR:-}" || "${TERM:-dumb}" == dumb || ! -t 1 ]]; then
        C_L= C_V= C_T= C_D= C_R= C_F= C_B= C_W= C_G=
    else
        C_L=$'\e[38;5;182m' C_V=$'\e[1;97m' C_T=$'\e[38;5;250m' C_D=$'\e[0;90m' C_R=$'\e[0m'
        C_F=$'\e[38;5;91m' C_B=$'\e[38;5;245m' C_W=$'\e[38;5;180m' C_G=$'\e[38;5;114m'
    fi
}

tk_docker() {
    command -v docker >/dev/null 2>&1 || return 1
    timeout 3 docker "$@" 2>/dev/null
}

tk_human_uptime() {
    local s d h m
    s=$(cut -d. -f1 /proc/uptime)
    d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
    if ((d >= 2)); then echo "$d Tage"; elif ((d == 1)); then echo "1 Tag, $h Std"; elif ((h > 0)); then echo "$h Std"; else echo "$m min"; fi
}

# Zeilen "<ziel> <prozent>" der echten Dateisysteme
tk_disks() {
    df --output=target,pcent,fstype 2>/dev/null | awk 'NR > 1 && $3 ~ /^(ext[234]|xfs|btrfs|zfs)$/ && $1 !~ /^\/(var\/lib\/docker|snap)/ { sub("%", "", $2); print $1, $2 }'
}

# Ausgabe: eine Zeile je Problem. Leer, wenn alles stimmt.
tk_motd_problems() {
    local line n sec target pct
    [[ -e /var/run/reboot-required ]] && echo "Neustart nötig"
    if [[ -r /var/lib/tk/apt-check ]]; then
        IFS=';' read -r n sec < /var/lib/tk/apt-check
        [[ "${sec:-0}" =~ ^[0-9]+$ ]] && ((sec > 0)) && echo "$sec Sicherheitsupdates offen"
    fi
    n=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | wc -l)
    ((n > 0)) && echo "$n Units fehlgeschlagen (tk status)"
    while read -r target pct; do
        [[ -n "$target" ]] && ((pct >= TK_DISK_WARN)) && echo "$target zu $pct % voll"
    done < <(tk_disks)
    while IFS='|' read -r name state status; do
        [[ -n "$name" ]] || continue
        case "$status" in
            *"(unhealthy)"*) echo "$name ungesund" ;;
            *"(health: starting)"*) ;;
            Restarting*) echo "$name startet ständig neu" ;;
            "Exited (0)"*) ;;
            Exited*) echo "$name beendet: ${status%% ago*}" ;;
        esac
    done < <(tk_docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}')
}

tk_motd_main() {
    local distro mem disks docker_line total running unhealthy problems
    tk_colors

    if [[ -r "$HEAD" ]]; then
        while IFS= read -r line; do
            if [[ "$line" == @B@* ]]; then
                line="${line#@B@}"
                line=$(sed "s#[/\\\\_|]#${C_F}&${C_B}#g" <<<"$line")
                printf '%s%s%s\n' "$C_B" "$line" "$C_R"
            else
                line="${line//@L@/$C_L}"; line="${line//@V@/$C_V}"; line="${line//@T@/$C_T}"
                line="${line//@D@/$C_D}"; line="${line//@R@/$C_R}"
                printf '%s\n' "$line"
            fi
        done < "$HEAD"
    else
        printf '  %s%s%s\n' "$C_V" "$(hostname)" "$C_R"
    fi

    distro=$(. /etc/os-release && echo "${PRETTY_NAME% LTS}")
    mem=$(free -m | awk '/^Mem:/ { u=$3; t=$2; f=(t >= 10240) ? "%.0fG/%.0fG" : "%dM/%dM"; if (t >= 10240) { u/=1024; t/=1024 } printf f, u, t }')
    disks=$(tk_disks | awk '{ printf "%s%s %s %%", (NR > 1 ? " · " : ""), $1, $2 }')

    printf '\n  %sSystem  %s  %s %s·%s up %s %s·%s Load %s\n' "$C_L" "$C_R" "$distro" "$C_D" "$C_R" "$(tk_human_uptime)" "$C_D" "$C_R" "$(cut -d' ' -f1 /proc/loadavg)"
    printf '  %sSpeicher%s  RAM %s %s·%s %s\n' "$C_L" "$C_R" "$mem" "$C_D" "$C_R" "$disks"

    if total=$(tk_docker ps -aq | wc -l) && ((total > 0)); then
        running=$(tk_docker ps -q | wc -l)
        unhealthy=$(tk_docker ps --filter health=unhealthy -q | wc -l)
        if ((running == total && unhealthy == 0)); then
            docker_line="${C_G}$running/$total laufen, alle gesund${C_R}"
        else
            docker_line="${C_W}$running/$total laufen, $unhealthy ungesund${C_R}"
        fi
        printf '  %sDocker  %s  %s\n' "$C_L" "$C_R" "$docker_line"
    elif command -v docker >/dev/null 2>&1 && ! tk_docker info >/dev/null; then
        printf '  %sDocker  %s  %skein Zugriff (Gruppe docker, neu anmelden)%s\n' "$C_L" "$C_R" "$C_D" "$C_R"
    fi

    problems=$(tk_motd_problems | paste -sd'|' | sed 's/|/ · /g')
    [[ -n "$problems" ]] && printf '\n  %s⚠ %s%s\n' "$C_W" "$problems" "$C_R"
    printf '\n'
}

# Nur ausfuehren, wenn direkt aufgerufen (tk sourct die Datei fuer tk_motd_problems)
[[ "${BASH_SOURCE[0]}" == "$0" ]] && tk_motd_main
