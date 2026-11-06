#!/usr/bin/env bash
# managed by proxmox-linux-baseline (Ansible)
#
# MOTD in drei Teilen:
#   1. Kopf aus /etc/tk/motd-head: Banner und Steckbrief, von Ansible aus NetBox geschrieben
#   2. Systemzustand: Distribution, Laufzeit, RAM, Platten laut NetBox (/etc/tk/disks), Container
#   3. Warnblock, nur wenn etwas nicht stimmt
# tk sourct diese Datei und nutzt die Funktionen tk_* (z. B. tk_motd_problems, tk_disk_rows).
set -u

TK_DISK_WARN="${TK_DISK_WARN:-85}"
TK_HEAD=/etc/tk/motd-head
TK_DISKS=/etc/tk/disks
TK_BAR=16

tk_rgb() { # r g b fallback-256
    if [[ "${TERM:-}" == linux ]]; then printf '\e[38;5;%sm' "$4"; else printf '\e[38;2;%s;%s;%sm' "$1" "$2" "$3"; fi
}

tk_colors() {
    if [[ -n "${NO_COLOR:-}" || "${TERM:-dumb}" == dumb || ! -t 1 ]]; then
        C_P= C_L= C_V= C_T= C_D= C_R= C_W= C_G= C_E=
    else
        C_P=$'\e[1m'$(tk_rgb 144 64 208 98)   # Firmen-Lila #9040D0
        C_L=$(tk_rgb 201 166 236 183)         # helles Lila fuer Beschriftungen
        C_V=$'\e[1;97m' C_T=$'\e[38;5;250m' C_D=$'\e[0;90m' C_R=$'\e[0m'
        C_W=$(tk_rgb 229 192 123 180) C_G=$(tk_rgb 124 196 127 114) C_E=$(tk_rgb 224 108 117 174)
    fi
}

tk_docker() {
    command -v docker >/dev/null 2>&1 || return 1
    timeout 3 docker "$@" 2>/dev/null
}

tk_is_lxc() { [[ "$(systemd-detect-virt 2>/dev/null)" == lxc ]]; }

tk_human_uptime() {
    local s d h m
    s=$(cut -d. -f1 /proc/uptime)
    d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
    if ((d >= 2)); then echo "$d Tage"; elif ((d == 1)); then echo "1 Tag, $h Std"; elif ((h > 0)); then echo "$h Std"; else echo "$m min"; fi
}

tk_bar() { # prozent
    local pct=$1 fill i col full="" empty=""
    fill=$(( (pct * TK_BAR + 50) / 100 )); ((fill > TK_BAR)) && fill=$TK_BAR
    if ((pct >= 90)); then col=$C_E; elif ((pct >= 75)); then col=$C_W; else col=$C_P; fi
    for ((i = 0; i < fill; i++)); do full+="█"; done
    for ((; i < TK_BAR; i++)); do empty+="░"; done
    printf '%s%s%s%s%s' "$col" "$full" "$C_D" "$empty" "$C_R"
}

# Zeilen "name|mount|art|groesse_netbox|belegt|gesamt|prozent|zustand" je Platte.
# Quelle ist NetBox (/etc/tk/disks); fehlt sie, die echten Dateisysteme im Gast.
tk_disk_rows() {
    local name mount kind size desc target used total pct
    if [[ -s "$TK_DISKS" ]]; then
        while IFS=$'\t' read -r name mount kind size desc; do
            [[ -n "$name" ]] || continue
            if [[ "$mount" == /* ]] && target=$(findmnt -n -o TARGET --target "$mount" 2>/dev/null) && [[ "$target" == "$mount" ]]; then
                read -r used total pct < <(df -B1 --output=used,size,pcent "$mount" 2>/dev/null | awk 'NR == 2 { sub("%", "", $3); print $1, $2, $3 }')
                echo "$name|$mount|$kind|${size}G|$(numfmt --to=iec "$used")|$(numfmt --to=iec "$total")|$pct|ok"
            else
                echo "$name|$mount|$kind|${size}G|-|-|-|fehlt"
            fi
        done < "$TK_DISKS"
    else
        df -B1 --output=target,used,size,pcent,fstype 2>/dev/null \
            | awk 'NR > 1 && $5 ~ /^(ext[234]|xfs|btrfs|zfs)$/ && $1 !~ /^\/(var\/lib\/docker|snap|boot)/ { sub("%", "", $4); print $1, $2, $3, $4 }' \
            | while read -r mount used total pct; do
                echo "-|$mount|-|-|$(numfmt --to=iec "$used")|$(numfmt --to=iec "$total")|$pct|ok"
            done
    fi
}

# Eine Zeile je Problem. Leer, wenn alles stimmt.
tk_motd_problems() {
    local n sec name mount kind size used total pct state status
    [[ -e /var/run/reboot-required ]] && echo "Neustart nötig"
    if [[ -r /var/lib/tk/apt-check ]]; then
        IFS=';' read -r n sec < /var/lib/tk/apt-check
        [[ "${sec:-0}" =~ ^[0-9]+$ ]] && ((sec > 0)) && echo "$sec Sicherheitsupdates offen"
    fi
    n=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | wc -l)
    ((n > 0)) && echo "$n Units fehlgeschlagen (tk status)"
    while IFS='|' read -r name mount kind size used total pct state; do
        [[ "$state" == fehlt ]] && echo "$mount ($name) nicht eingehängt"
        [[ "$pct" =~ ^[0-9]+$ ]] && ((pct >= TK_DISK_WARN)) && echo "$mount zu $pct % voll"
    done < <(tk_disk_rows)
    while IFS='|' read -r name status; do
        [[ -n "$name" ]] || continue
        case "$status" in
            *"(unhealthy)"*) echo "$name ungesund" ;;
            Restarting*) echo "$name startet ständig neu" ;;
            "Exited (0)"*|*"health: starting"*) ;;
            Exited*) echo "$name beendet: ${status%% ago*}" ;;
        esac
    done < <(tk_docker ps -a --format '{{.Names}}|{{.Status}}')
}

tk_label() { printf '  %s%-8s%s ' "$C_L" "$1" "$C_R"; }

tk_motd_main() {
    local line distro load mem_used mem_total mem_pct rows w1=0 w2=0 w3=0 w4=0 prefix first=1
    local name mount kind size used total pct state total_c running unhealthy problems
    tk_colors

    if [[ -r "$TK_HEAD" ]]; then
        while IFS= read -r line; do
            line="${line//@P@/$C_P}"; line="${line//@L@/$C_L}"; line="${line//@V@/$C_V}"
            line="${line//@T@/$C_T}"; line="${line//@D@/$C_D}"; line="${line//@R@/$C_R}"
            printf '%s\n' "$line"
        done < "$TK_HEAD"
    else
        printf '  %s%s%s\n' "$C_V" "$(hostname)" "$C_R"
    fi

    distro=$(. /etc/os-release && echo "${PRETTY_NAME% LTS}")
    load=""
    tk_is_lxc || load=" ${C_D}·${C_R} Load $(cut -d' ' -f1 /proc/loadavg)"
    printf '\n'; tk_label System; printf '%s %s·%s up %s%s\n' "$distro" "$C_D" "$C_R" "$(tk_human_uptime)" "$load"

    # Spaltenbreiten der Plattenzeilen, damit RAM- und Plattenbalken untereinander stehen
    rows=$(tk_disk_rows)
    while IFS='|' read -r name mount kind size used total pct state; do
        [[ -n "$mount" ]] || continue
        ((${#name} > w1)) && w1=${#name}
        ((${#mount} > w2)) && w2=${#mount}
        ((${#kind} > w3)) && w3=${#kind}
        ((${#used} + ${#total} + 1 > w4)) && w4=$((${#used} + ${#total} + 1))
    done <<<"$rows"

    read -r mem_used mem_total < <(free -b | awk '/^Mem:/ { print $3, $2 }')
    mem_pct=$((mem_used * 100 / (mem_total > 0 ? mem_total : 1)))
    prefix=$((w1 + w2 + w3 + w4 + 6))
    tk_label RAM
    printf "%${prefix}s  %s %3d %%\n" "$(numfmt --to=iec "$mem_used")/$(numfmt --to=iec "$mem_total")" "$(tk_bar "$mem_pct")" "$mem_pct"

    while IFS='|' read -r name mount kind size used total pct state; do
        [[ -n "$mount" ]] || continue
        if ((first)); then tk_label Platten; first=0; else printf '  %-8s ' ''; fi
        printf "%-${w1}s  %-${w2}s  %s%-${w3}s%s  " "$name" "$mount" "$C_D" "$kind" "$C_R"
        if [[ "$state" == fehlt ]]; then
            printf "%${w4}s  %snicht eingehängt%s\n" "$size" "$C_E" "$C_R"
        else
            printf "%${w4}s  %s %3d %%\n" "$used/$total" "$(tk_bar "$pct")" "$pct"
        fi
    done <<<"$rows"

    if total_c=$(tk_docker ps -aq | wc -l) && ((total_c > 0)); then
        running=$(tk_docker ps -q | wc -l)
        unhealthy=$(tk_docker ps --filter health=unhealthy -q | wc -l)
        tk_label Docker
        if ((running == total_c && unhealthy == 0)); then
            printf '%s%s/%s laufen, alle gesund%s\n' "$C_G" "$running" "$total_c" "$C_R"
        else
            printf '%s%s/%s laufen, %s ungesund%s %s(tk ps)%s\n' "$C_W" "$running" "$total_c" "$unhealthy" "$C_R" "$C_D" "$C_R"
        fi
    elif command -v docker >/dev/null 2>&1 && ! tk_docker info >/dev/null; then
        tk_label Docker
        printf '%skein Zugriff (Gruppe docker, neu anmelden)%s\n' "$C_D" "$C_R"
    fi

    problems=$(tk_motd_problems | paste -sd'|' | sed 's/|/ · /g')
    [[ -n "$problems" ]] && printf '\n  %s⚠ %s%s\n' "$C_W" "$problems" "$C_R"
    printf '\n'
}

# Nur ausfuehren, wenn direkt aufgerufen (tk sourct die Datei)
[[ "${BASH_SOURCE[0]}" == "$0" ]] && tk_motd_main
