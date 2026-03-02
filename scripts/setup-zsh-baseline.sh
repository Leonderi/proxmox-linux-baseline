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
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
cat >/etc/default/keyboard <<'EOF_KEYBOARD'
XKBMODEL="pc105"
XKBLAYOUT="de"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF_KEYBOARD
setupcon --force || true

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

printf '# managed by cloud-init baseline\n' > /etc/skel/.zshrc
chmod 0644 /etc/skel/.zshrc
systemctl start qemu-guest-agent || true
