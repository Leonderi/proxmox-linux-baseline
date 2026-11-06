#!/bin/sh
# managed by proxmox-linux-baseline (Ansible)
# Haelt die Zahl offener Updates fest, damit MOTD und "tk updates" beim Login nicht apt fragen.
# Aufruf aus den apt-Hooks in /etc/apt/apt.conf.d/99tk-apt-check. Format: "<alle>;<sicherheit>"
[ -x /usr/lib/update-notifier/apt-check ] || exit 0
[ "$(id -u)" = 0 ] || exit 0
mkdir -p /var/lib/tk
out=$(/usr/lib/update-notifier/apt-check 2>&1 >/dev/null) || exit 0
case "$out" in
    *[0-9]\;[0-9]*) printf '%s\n' "$out" > /var/lib/tk/apt-check.tmp && mv /var/lib/tk/apt-check.tmp /var/lib/tk/apt-check ;;
esac
exit 0
