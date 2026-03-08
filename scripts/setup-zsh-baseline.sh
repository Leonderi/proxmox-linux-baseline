#!/usr/bin/env bash
set -euxo pipefail

exec > >(tee -a /var/log/clone-baseline.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

detect_cloud_init_user() {
  local user_data="/var/lib/cloud/instance/user-data.txt"
  local detected=""

  if [[ -r "$user_data" ]]; then
    detected="$(awk -F': *' '/^user:/{print $2; exit}' "$user_data" | tr -d "\"'[:space:]")"

    if [[ -z "$detected" ]]; then
      detected="$(awk '
        /^users:/ { in_users=1; next }
        in_users && /^[^[:space:]-]/ { exit }
        in_users && /^[[:space:]]*-[[:space:]]+/ {
          gsub(/^[[:space:]]*-[[:space:]]+/, "", $0)
          gsub(/["'"'"'[:space:]]/, "", $0)
          if ($0 != "" && $0 != "default") { print $0; exit }
        }' "$user_data")"
    fi
  fi

  printf '%s' "${detected:-alexander}"
}

configure_interactive_user() {
  local target_user="$1"
  local home_dir=""

  if ! id "$target_user" >/dev/null 2>&1; then
    return 0
  fi

  home_dir="$(getent passwd "$target_user" | cut -d: -f6)"
  usermod -s /usr/bin/zsh "$target_user"
  printf '# managed by cloud-init baseline\n' > "${home_dir}/.zshrc"
  chown "$target_user:$target_user" "${home_dir}/.zshrc"
  chmod 0644 "${home_dir}/.zshrc"
}

ensure_group_membership() {
  local group_name="$1"
  local target_user="$2"

  if ! getent group "$group_name" >/dev/null 2>&1; then
    return 0
  fi
  if ! id "$target_user" >/dev/null 2>&1; then
    return 0
  fi
  if id -nG "$target_user" | tr ' ' '\n' | grep -qx "$group_name"; then
    return 0
  fi

  usermod -aG "$group_name" "$target_user"
}

install_tk_motd() {
  install -d -m 0755 /usr/local/lib/tk-motd

  cat >/usr/local/lib/tk-motd/render.sh <<'EOF_MOTD_RENDER'
#!/usr/bin/env bash
set -u

if [[ -r /etc/default/tk-motd ]]; then
  # shellcheck disable=SC1091
  source /etc/default/tk-motd
fi

TK_MOTD_BRAND="${TK_MOTD_BRAND:-tk-thran}"
TK_MOTD_SERVICES="${TK_MOTD_SERVICES:-qemu-guest-agent ssh systemd-resolved systemd-timesyncd cron docker fail2ban}"
TK_MOTD_MOUNTS="${TK_MOTD_MOUNTS:-/ /boot /boot/efi /mnt/hdd /mnt/nvme}"
TK_MOTD_DOCKER_MODE="${TK_MOTD_DOCKER_MODE:-summary}"
TK_MOTD_DOCKER_LIMIT="${TK_MOTD_DOCKER_LIMIT:-10}"

safe_cmd() {
  "$@" 2>/dev/null || true
}

setup_colors() {
    if [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]]; then
      C_RESET=""
      C_LABEL=""
      C_VALUE=""
      C_ACCENT=""
      C_GOOD=""
      C_WARN=""
      C_BAD=""
      C_DIM=""
      C_HEADER_FRAME=""
      C_HEADER_TEXT=""
      C_HEADER_DIM=""
      return
    fi
  
  C_RESET=$'\033[0m'
  C_LABEL=$'\033[38;5;182m'
  C_VALUE=$'\033[0;97m'
  C_ACCENT=$'\033[38;5;117m'
  C_GOOD=$'\033[38;5;114m'
  C_WARN=$'\033[38;5;180m'
  C_BAD=$'\033[38;5;174m'
  C_DIM=$'\033[0;90m'
  C_HEADER_FRAME=$'\033[38;5;99m'
  C_HEADER_TEXT=$'\033[38;5;245m'
  C_HEADER_DIM=$'\033[38;5;240m'
}

color_for_percent() {
  local percent="${1:-0}"

  if ! [[ "$percent" =~ ^[0-9]+$ ]]; then
    percent=0
  fi

  if (( percent >= 90 )); then
    printf '%s' "$C_BAD"
  elif (( percent >= 75 )); then
    printf '%s' "$C_WARN"
  else
    printf '%s' "$C_GOOD"
  fi
}

print_kv() {
  local label="$1"
  local value="$2"
  printf '%b%-16s%b %b%s%b\n' "$C_LABEL" "${label}:" "$C_RESET" "$C_VALUE" "$value" "$C_RESET"
}

print_ascii_header_line() {
  local line="$1"
  local out=""
  local i=0
  local len=${#line}
  local ch=""

  while (( i < len )); do
    ch="${line:$i:1}"
    case "$ch" in
      '/'|'\\'|'_'|'|')
        out+="${C_HEADER_FRAME}${ch}${C_HEADER_TEXT}"
        ;;
      *)
        out+="$ch"
        ;;
    esac
    ((i++))
  done

  printf '%b%b%b\n' "$C_HEADER_TEXT" "$out" "$C_RESET"
}

get_primary_ip() {
  local detected_ip=""

  detected_ip="$(safe_cmd ip route get 1.1.1.1 | awk '{print $7; exit}')"
  if [[ -n "$detected_ip" ]]; then
    printf '%s' "$detected_ip"
    return
  fi

  printf '%s' 'unavailable'
}

docker_safe_cmd() {
  docker_query "$@" || true
}

docker_query() {
  if ((${#DOCKER_RUN[@]} == 0)); then
    return 1
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout 2s "${DOCKER_RUN[@]}" "$@" 2>/dev/null
  else
    "${DOCKER_RUN[@]}" "$@" 2>/dev/null
  fi
}

init_docker_access() {
  DOCKER_RUN=()

  if ! command -v docker >/dev/null 2>&1; then
    return
  fi

  if command -v timeout >/dev/null 2>&1; then
    if timeout 2s docker info >/dev/null 2>&1; then
      DOCKER_RUN=(docker)
      return
    fi
    if command -v sudo >/dev/null 2>&1 && timeout 2s sudo -n docker info >/dev/null 2>&1; then
      DOCKER_RUN=(sudo -n docker)
      return
    fi
    return
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER_RUN=(docker)
    return
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER_RUN=(sudo -n docker)
  fi
}

draw_bar() {
  local percent="$1"
  local width=44
  local filled=0
  local empty=0
  local percent_color=""
  local filled_char="█"
  local empty_char="░"
  local filled_bar=""
  local empty_bar=""
  local i=0

  if ! [[ "$percent" =~ ^[0-9]+$ ]]; then
    percent=0
  fi

  if (( percent < 0 )); then
    percent=0
  elif (( percent > 100 )); then
    percent=100
  fi

  filled=$((percent * width / 100))
  empty=$((width - filled))
  percent_color="$(color_for_percent "$percent")"

  if (( filled > 0 )); then
    for ((i = 0; i < filled; i++)); do
      filled_bar+="$filled_char"
    done
  fi
  if (( empty > 0 )); then
    for ((i = 0; i < empty; i++)); do
      empty_bar+="$empty_char"
    done
  fi

  printf '%b%s%b%b%s%b' "$percent_color" "$filled_bar" "$C_RESET" "$C_DIM" "$empty_bar" "$C_RESET"
}

format_memory() {
  local mem_line
  mem_line="$(safe_cmd free -h | awk '/^Mem:/ {print $3 " used, " $4 " free, " $6 " cached, " $7 " available, " $2 " total"}')"
  if [[ -n "$mem_line" ]]; then
    printf '%s' "$mem_line"
  else
    printf 'unavailable'
  fi
}

format_package_status() {
  local updates=0
  local security=0
  local apt_check=""

  if [[ -x /usr/lib/update-notifier/apt-check ]]; then
    apt_check="$(safe_cmd /usr/lib/update-notifier/apt-check 2>&1)"
    updates="${apt_check%%;*}"
    security="${apt_check##*;}"
    if ! [[ "$updates" =~ ^[0-9]+$ ]]; then
      updates=0
    fi
    if ! [[ "$security" =~ ^[0-9]+$ ]]; then
      security=0
    fi
    printf '%s updates can be applied immediately (%s security).' "$updates" "$security"
    return
  fi

  if command -v apt >/dev/null 2>&1; then
    updates="$(safe_cmd bash -c "apt list --upgradable 2>/dev/null | awk 'NR>1 {count++} END {print count+0}'")"
    if ! [[ "$updates" =~ ^[0-9]+$ ]]; then
      updates=0
    fi
    printf '%s updates can be applied immediately.' "$updates"
    return
  fi

  printf 'unavailable'
}

format_last_login() {
  local login_user
  local last_login

  login_user="${PAM_USER:-${SUDO_USER:-${USER:-unknown}}}"
  if [[ "$login_user" == "unknown" ]]; then
    printf 'unavailable'
    return
  fi

  last_login="$(safe_cmd last -w -n 1 "$login_user" | head -n 1)"
  if [[ -z "$last_login" || "$last_login" == *"wtmp begins"* ]]; then
    printf 'unavailable'
    return
  fi

  printf '%s' "$last_login"
}

print_disk_usage() {
  local mount_point
  local printed=0
  local df_line=""
  local size=""
  local used_percent=""
  local used_num=0

  printf '%b%-16s%b ' "$C_LABEL" 'Disk Usage:' "$C_RESET"
  for mount_point in $TK_MOTD_MOUNTS; do
    if [[ ! -d "$mount_point" ]]; then
      continue
    fi

    df_line="$(safe_cmd df -hP "$mount_point" | awk 'NR==2 {print $2 "|" $5}')"
    if [[ -z "$df_line" ]]; then
      continue
    fi

    size="${df_line%%|*}"
    used_percent="${df_line##*|}"
    used_num="${used_percent%%%}"
    if ! [[ "$used_num" =~ ^[0-9]+$ ]]; then
      used_num=0
    fi

    if (( printed == 0 )); then
      printf '%b%-16s%b %b%2s%b used out of %b%s%b\n' "$C_VALUE" "$mount_point" "$C_RESET" "$(color_for_percent "$used_num")" "$used_percent" "$C_RESET" "$C_ACCENT" "$size" "$C_RESET"
    else
      printf '%16s %b%-16s%b %b%2s%b used out of %b%s%b\n' '' "$C_VALUE" "$mount_point" "$C_RESET" "$(color_for_percent "$used_num")" "$used_percent" "$C_RESET" "$C_ACCENT" "$size" "$C_RESET"
    fi
    printf '%16s %s\n' '' "$(draw_bar "$used_num")"
    printed=1
  done

  if (( printed == 0 )); then
    printf '%bno configured mount points found%b\n' "$C_DIM" "$C_RESET"
  fi
}

service_exists() {
  local unit="$1"
  systemctl show "$unit" >/dev/null 2>&1
}

print_service_status() {
  local service
  local printed=0
  local active=""
  local substate=""
  local active_color=""
  local unit_state=""

  printf '%b%-16s%b ' "$C_LABEL" 'Services:' "$C_RESET"
  for service in $TK_MOTD_SERVICES; do
    if ! service_exists "$service"; then
      continue
    fi

    active="$(safe_cmd systemctl is-active "$service")"
    if [[ -z "$active" ]]; then
      active="unknown"
    fi
    substate="$(safe_cmd systemctl show -p SubState --value "$service")"
    if [[ -z "$substate" ]]; then
      substate="unknown"
    fi
    unit_state="${active}/${substate}"
    case "$active" in
      active) active_color="$C_GOOD" ;;
      inactive) active_color="$C_DIM" ;;
      failed) active_color="$C_BAD" ;;
      *) active_color="$C_WARN" ;;
    esac

    if (( printed == 0 )); then
      printf '%b%-34s%b %b%s%b\n' "$C_VALUE" "$service" "$C_RESET" "$active_color" "$unit_state" "$C_RESET"
    else
      printf '%16s %b%-34s%b %b%s%b\n' '' "$C_VALUE" "$service" "$C_RESET" "$active_color" "$unit_state" "$C_RESET"
    fi
    printed=1
  done

  if (( printed == 0 )); then
    printf '%bno configured services found%b\n' "$C_DIM" "$C_RESET"
  fi
}

print_docker_status() {
  local docker_total=0
  local docker_running=0
  local docker_attention=0
  local problem_lines=""
  local detail_mode="$TK_MOTD_DOCKER_MODE"

  if [[ "$detail_mode" == "off" ]]; then
    print_kv 'Docker' 'disabled via TK_MOTD_DOCKER_MODE=off'
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    print_kv 'Docker' 'docker CLI not installed'
    return
  fi

  if [[ "$(safe_cmd systemctl is-active docker)" != "active" ]]; then
    print_kv 'Docker' 'docker service is not active'
    return
  fi

  if ((${#DOCKER_RUN[@]} == 0)); then
    print_kv 'Docker' 'docker access unavailable (re-login after docker group change)'
    return
  fi

  docker_total="$(docker_safe_cmd ps -a -q | wc -l | tr -d ' ')"
  docker_running="$(docker_safe_cmd ps -q | wc -l | tr -d ' ')"
  if ! [[ "$docker_total" =~ ^[0-9]+$ ]]; then
    docker_total=0
  fi
  if ! [[ "$docker_running" =~ ^[0-9]+$ ]]; then
    docker_running=0
  fi
  docker_attention=$((docker_total - docker_running))
  if (( docker_attention < 0 )); then
    docker_attention=0
  fi

  printf '%b%-16s%b %b%s%b containers (%b%s running%b, %b%s need attention%b)\n' \
    "$C_LABEL" 'Docker:' "$C_RESET" \
    "$C_VALUE" "$docker_total" "$C_RESET" \
    "$C_GOOD" "$docker_running" "$C_RESET" \
    "$([[ "$docker_attention" =~ ^0+$ ]] && printf '%s' "$C_GOOD" || printf '%s' "$C_WARN")" "$docker_attention" "$C_RESET"

  if (( docker_attention == 0 )); then
    return
  fi

  problem_lines="$(
    docker_safe_cmd ps -a --format '{{.Names}}|{{.State}}|{{.Status}}' \
      | awk -F'|' '$2 != "running" {print $1 ": " $3}' \
      | head -n "$TK_MOTD_DOCKER_LIMIT"
  )"

  if [[ -z "$problem_lines" ]]; then
    return
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%16s %b%s%b\n' '' "$C_WARN" "$line" "$C_RESET"
  done <<<"$problem_lines"

  if [[ "$detail_mode" == "detailed" ]]; then
    local running_lines
    running_lines="$(
      docker_safe_cmd ps --format '{{.Names}}|{{.Status}}' \
        | head -n "$TK_MOTD_DOCKER_LIMIT"
    )"
    if [[ -n "$running_lines" ]]; then
      printf '%16s %brunning:%b\n' '' "$C_GOOD" "$C_RESET"
      while IFS='|' read -r cname cstatus; do
        [[ -n "$cname" ]] || continue
        printf '%16s %b%s%b: %s\n' '' "$C_VALUE" "$cname" "$C_RESET" "$cstatus"
      done <<<"$running_lines"
    fi
  fi
}

print_traefik_status() {
  local traefik_state

  if ! command -v docker >/dev/null 2>&1; then
    print_kv 'Traefik' 'docker unavailable'
    return
  fi

  traefik_state="$(docker_safe_cmd inspect -f '{{.State.Status}}' traefik)"
  if [[ -z "$traefik_state" ]]; then
    print_kv 'Traefik' 'Traefik container not found'
    return
  fi

  if [[ "$traefik_state" == "running" ]]; then
    printf '%b%-16s%b %bTraefik container is running%b\n' "$C_LABEL" 'Traefik:' "$C_RESET" "$C_GOOD" "$C_RESET"
  else
    printf '%b%-16s%b %bTraefik container is %s%b\n' "$C_LABEL" 'Traefik:' "$C_RESET" "$C_WARN" "$traefik_state" "$C_RESET"
  fi
}

print_header() {
  local kernel="$1"
  local uptime_human="$2"
  local load_1="$3"
  local load_5="$4"
  local load_15="$5"
  local brand_upper
  local brand_raw
  local line_one=""
  local line_two=""
  local line_three=""
  local line_four=""
  local line_five=""
  local line_six=""
  local host_name=""
  local primary_ip=""

  brand_raw="$(printf '%s' "$TK_MOTD_BRAND")"
  brand_upper="$(printf '%s' "$brand_raw" | tr '[:lower:]' '[:upper:]')"
  host_name="$(safe_cmd hostname -f)"
  if [[ -z "$host_name" ]]; then
    host_name="$(safe_cmd hostname)"
  fi
  primary_ip="$(get_primary_ip)"

  if [[ "$brand_upper" == "TK-THRAN" ]]; then
    line_one='   __     __            __     __'
    line_two='  / /_   / /__         / /_   / /_    _____  ____ _   ____'
    line_three=' / __/  / //_/ ______ / __/  / __ \  / ___/ / __ `/  / __ \'
    line_four='/ /_   / ,<   /_____// /_   / / / / / /    / /_/ /  / / / /'
    line_five='\__/  /_/|_|         \__/  /_/ /_/ /_/     \__,_/  /_/ /_/'
    line_six=''
    print_ascii_header_line "$line_one"
    print_ascii_header_line "$line_two"
    print_ascii_header_line "$line_three"
    print_ascii_header_line "$line_four"
    print_ascii_header_line "$line_five"
  else
    printf '%b/-------------------------------------------------------\\\\%b\n' "$C_DIM" "$C_RESET"
    printf '%b|%b %-53s %b|\n' "$C_DIM" "$C_RESET" "$brand_upper" "$C_DIM"
    printf '%b\\\\-------------------------------------------------------/%b\n' "$C_DIM" "$C_RESET"
  fi
  printf '\n'
  printf '  %b│%b %bHost%b    %b%s%b\n' "$C_HEADER_FRAME" "$C_RESET" "$C_HEADER_TEXT" "$C_RESET" "$C_HEADER_DIM" "${host_name:-unavailable}" "$C_RESET"
  printf '  %b│%b %bIP%b      %b%s%b\n' "$C_HEADER_FRAME" "$C_RESET" "$C_HEADER_TEXT" "$C_RESET" "$C_HEADER_DIM" "${primary_ip:-unavailable}" "$C_RESET"
  printf '  %b│%b %bKernel%b  %b%s%b\n' "$C_HEADER_FRAME" "$C_RESET" "$C_HEADER_TEXT" "$C_RESET" "$C_HEADER_DIM" "${kernel:-unavailable}" "$C_RESET"
  printf '  %b│%b %bUptime%b  %b%s%b\n' "$C_HEADER_FRAME" "$C_RESET" "$C_HEADER_TEXT" "$C_RESET" "$C_HEADER_DIM" "${uptime_human:-unavailable}" "$C_RESET"
  if [[ -n "${load_1:-}" || -n "${load_5:-}" || -n "${load_15:-}" ]]; then
    printf '  %b│%b %bLoad%b    %b%s %s %s%b\n' "$C_HEADER_FRAME" "$C_RESET" "$C_HEADER_TEXT" "$C_RESET" "$C_HEADER_DIM" "${load_1:-n/a}" "${load_5:-n/a}" "${load_15:-n/a}" "$C_RESET"
  else
    printf '  %b│%b %bLoad%b    %b%s%b\n' "$C_HEADER_FRAME" "$C_RESET" "$C_HEADER_TEXT" "$C_RESET" "$C_HEADER_DIM" 'unavailable' "$C_RESET"
  fi
  printf '\n'
}

main() {
  local distro
  local kernel
  local uptime_human
  local load
  local load_1
  local load_5
  local load_15
  local process_count
  local cpu_model
  local cpu_cores
  local gpu_lines
  local sessions
  local package_status
  local memory_line
  local current_user

  setup_colors
  init_docker_access
  distro="$(safe_cmd awk -F= '$1=="PRETTY_NAME"{gsub(/"/,"",$2); print $2}' /etc/os-release)"
  kernel="$(safe_cmd uname -r)"
  uptime_human="$(safe_cmd uptime -p | sed 's/^up //')"
  load="$(safe_cmd awk '{print $1, $2, $3}' /proc/loadavg)"
  process_count="$(safe_cmd ps -e --no-headers | wc -l | tr -d ' ')"
  cpu_model="$(safe_cmd awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
  cpu_cores="$(safe_cmd nproc)"
  gpu_lines="$(safe_cmd lspci | grep -Ei 'vga|3d|display' | head -n 2)"
  sessions="$(safe_cmd who | wc -l | tr -d ' ')"
  package_status="$(format_package_status)"
  memory_line="$(format_memory)"
  current_user="${SUDO_USER:-${USER:-unknown}}"

  if [[ -n "${load:-}" ]]; then
    read -r load_1 load_5 load_15 <<<"$load"
  fi
  print_header "$kernel" "$uptime_human" "${load_1:-}" "${load_5:-}" "${load_15:-}"
  print_kv 'Distribution' "${distro:-unavailable}"
  printf '%b%-16s%b %b%s%b running processes\n' "$C_LABEL" 'Processes:' "$C_RESET" "$C_ACCENT" "${process_count:-unavailable}" "$C_RESET"
  printf '%b%-16s%b %b%s%b (%b%s cores%b)\n' "$C_LABEL" 'CPU:' "$C_RESET" "$C_VALUE" "${cpu_model:-unavailable}" "$C_RESET" "$C_ACCENT" "${cpu_cores:-unavailable}" "$C_RESET"
  if [[ -n "${gpu_lines:-}" ]]; then
    printf '%b%-16s%b %b%s%b\n' "$C_LABEL" 'GPU:' "$C_RESET" "$C_VALUE" "$(printf '%s\n' "$gpu_lines" | head -n 1)" "$C_RESET"
    if (( $(printf '%s\n' "$gpu_lines" | wc -l | tr -d ' ') > 1 )); then
      printf '%16s %b%s%b\n' '' "$C_VALUE" "$(printf '%s\n' "$gpu_lines" | tail -n +2)" "$C_RESET"
    fi
  else
    print_kv 'GPU' 'unavailable'
  fi
  print_kv 'Memory Usage' "$memory_line"
  print_kv 'Package Status' "$package_status"
  printf '%b%-16s%b %b%s%b active sessions\n' "$C_LABEL" 'User Sessions:' "$C_RESET" "$C_ACCENT" "${sessions:-unavailable}" "$C_RESET"
  print_kv 'Last login' "$(format_last_login)"
  print_disk_usage
  print_service_status
  print_docker_status
  print_traefik_status
  if [[ "${DOCKER_RUN[*]:-}" == "sudo -n docker" ]]; then
    printf '%b%s%b\n' "$C_DIM" "Hint: docker data is read via passwordless sudo." "$C_RESET"
  elif command -v docker >/dev/null 2>&1 && ((${#DOCKER_RUN[@]} == 0)); then
    printf '%b%s%b\n' "$C_DIM" "Hint: add ${current_user} to the docker group and re-login for docker-aware MOTD data." "$C_RESET"
  fi
}

main
EOF_MOTD_RENDER
  chmod 0755 /usr/local/lib/tk-motd/render.sh

  install -d -m 0755 /etc/update-motd.d
  cat >/etc/update-motd.d/99-tk-thran-status <<'EOF_MOTD_WRAPPER'
#!/usr/bin/env bash
/usr/local/lib/tk-motd/render.sh
EOF_MOTD_WRAPPER
  chmod 0644 /etc/update-motd.d/99-tk-thran-status

  install -d -m 0755 /etc/profile.d
  cat >/etc/profile.d/90-tk-thran-motd.sh <<'EOF_MOTD_PROFILE'
#!/usr/bin/env bash
[[ $- == *i* ]] || return
[[ -n "${TK_MOTD_RENDERED:-}" ]] && return
export TK_MOTD_RENDERED=1

if [[ -x /usr/local/lib/tk-motd/render.sh ]]; then
  /usr/local/lib/tk-motd/render.sh
  printf '\n'
fi
EOF_MOTD_PROFILE
  chmod 0755 /etc/profile.d/90-tk-thran-motd.sh

  if [[ ! -f /etc/default/tk-motd ]]; then
    cat >/etc/default/tk-motd <<'EOF_MOTD_DEFAULTS'
# tk-thran MOTD defaults
TK_MOTD_BRAND="tk-thran"
TK_MOTD_SERVICES="qemu-guest-agent ssh systemd-resolved systemd-timesyncd cron docker fail2ban"
TK_MOTD_MOUNTS="/ /boot /boot/efi /mnt/hdd /mnt/nvme"
TK_MOTD_DOCKER_MODE="summary"
TK_MOTD_DOCKER_LIMIT="10"
EOF_MOTD_DEFAULTS
    chmod 0644 /etc/default/tk-motd
  fi

  if [[ -d /etc/update-motd.d ]]; then
    for motd_script in /etc/update-motd.d/*; do
      [[ -f "$motd_script" ]] || continue
      chmod 0644 "$motd_script"
    done
  fi
  chmod 0644 /etc/update-motd.d/99-tk-thran-status
}

TARGET_USER="${1:-$(detect_cloud_init_user)}"
STARSHIP_VERSION="${STARSHIP_VERSION:-1.24.2}"
BASELINE_REPO_BASE_URL="${BASELINE_REPO_BASE_URL:-https://raw.githubusercontent.com/Leonderi/proxmox-linux-baseline/main}"
STARSHIP_URL="https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-x86_64-unknown-linux-gnu.tar.gz"
STARSHIP_TOML_URL="${STARSHIP_TOML_URL:-${BASELINE_REPO_BASE_URL}/config/starship.toml}"
STARSHIP_ZSH_URL="${STARSHIP_ZSH_URL:-${BASELINE_REPO_BASE_URL}/config/starship.zsh}"

echo "Using TARGET_USER=${TARGET_USER}"

cd /tmp
rm -f /usr/local/bin/starship
curl -fL -o starship.tar.gz "${STARSHIP_URL}"
tar -xzf starship.tar.gz starship
install -m 0755 starship /usr/local/bin/starship
rm -f starship.tar.gz starship

curl -fL -o /etc/starship.toml "${STARSHIP_TOML_URL}"
curl -fL -o /etc/profile.d/starship.zsh "${STARSHIP_ZSH_URL}"
chmod 0644 /etc/starship.toml /etc/profile.d/starship.zsh

timedatectl set-timezone Europe/Berlin || true
locale-gen de_DE.UTF-8
update-locale LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8
cat >/etc/default/keyboard <<'EOF_KEYBOARD'
XKBMODEL="pc105"
XKBLAYOUT="de"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF_KEYBOARD

if [[ -f /etc/adduser.conf ]]; then
  sed -i 's|^DSHELL=.*|DSHELL=/usr/bin/zsh|' /etc/adduser.conf
fi

if [[ -f /etc/default/useradd ]]; then
  if grep -q '^SHELL=' /etc/default/useradd; then
    sed -i 's|^SHELL=.*|SHELL=/usr/bin/zsh|' /etc/default/useradd
  else
    printf 'SHELL=/usr/bin/zsh\n' >> /etc/default/useradd
  fi
fi

if [[ ! -d /usr/share/oh-my-zsh/.git ]]; then
  rm -rf /usr/share/oh-my-zsh
  git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git /usr/share/oh-my-zsh
fi

mkdir -p /usr/share/oh-my-zsh/custom/plugins
if [[ ! -d /usr/share/oh-my-zsh/custom/plugins/zsh-autosuggestions/.git ]]; then
  rm -rf /usr/share/oh-my-zsh/custom/plugins/zsh-autosuggestions
  git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git /usr/share/oh-my-zsh/custom/plugins/zsh-autosuggestions
fi

if [[ ! -d /usr/share/oh-my-zsh/custom/plugins/zsh-autocomplete/.git ]]; then
  rm -rf /usr/share/oh-my-zsh/custom/plugins/zsh-autocomplete
  git clone --depth 1 https://github.com/marlonrichert/zsh-autocomplete.git /usr/share/oh-my-zsh/custom/plugins/zsh-autocomplete
fi

cat >/etc/zsh/zshrc <<'EOF_ZSHRC'
[[ -o interactive ]] || return
export ZSH="/usr/share/oh-my-zsh"
export STARSHIP_CONFIG="/etc/starship.toml"
ZSH_THEME=""
plugins=(git zsh-autosuggestions)
[[ -f "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"
[[ -f /usr/share/oh-my-zsh/custom/plugins/zsh-autocomplete/zsh-autocomplete.plugin.zsh ]] && source /usr/share/oh-my-zsh/custom/plugins/zsh-autocomplete/zsh-autocomplete.plugin.zsh
[[ -f /etc/profile.d/starship.zsh ]] && source /etc/profile.d/starship.zsh
[[ -f /etc/profile.d/90-tk-thran-motd.sh ]] && source /etc/profile.d/90-tk-thran-motd.sh
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
command -v eza >/dev/null 2>&1 && alias ls='eza --group-directories-first --icons=auto'
HISTFILE="${HOME}/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt APPEND_HISTORY INC_APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE
EOF_ZSHRC
chmod 0644 /etc/zsh/zshrc

configure_interactive_user "$TARGET_USER"
configure_interactive_user root
ensure_group_membership docker "$TARGET_USER"

printf '# managed by cloud-init baseline\n' > /etc/skel/.zshrc
chmod 0644 /etc/skel/.zshrc
install_tk_motd
systemctl start qemu-guest-agent || true
