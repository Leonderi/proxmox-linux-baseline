#!/usr/bin/env bash
# Einmalig je Gast, bevor Ansible ihn erreicht: Schluessel von ansible@ops-devbox
# eintragen und sudo ohne Passwort fuer alexander setzen. Danach pflegt die Rolle beides.
# Laeuft als root im Gast, aufgerufen von pve1:
#
#   LXC:  pct exec <vmid> -- bash -s < bootstrap/bootstrap-guest.sh
#   VM:   qm guest exec <vmid> --pass-stdin 1 -- bash -s < bootstrap/bootstrap-guest.sh
set -euo pipefail

USER_NAME=alexander
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW4h6PFWlZGA8BLsUbVPAePtbRZl2XN/cuMXPSCo54W ansible@ops-devbox'

id "$USER_NAME" >/dev/null
home=$(getent passwd "$USER_NAME" | cut -d: -f6)
install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$home/.ssh"
touch "$home/.ssh/authorized_keys"
grep -qxF "$PUBKEY" "$home/.ssh/authorized_keys" || echo "$PUBKEY" >> "$home/.ssh/authorized_keys"
chown "$USER_NAME:$USER_NAME" "$home/.ssh/authorized_keys"; chmod 0600 "$home/.ssh/authorized_keys"

tmp=$(mktemp)
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "$tmp"
visudo -cqf "$tmp"
install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/10-tk-baseline
rm -f "$tmp"
echo "bootstrap ok: $(hostname)"
