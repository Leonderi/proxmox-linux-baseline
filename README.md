# Proxmox Linux Baseline

Schlanke, wiederverwendbare Linux-Baseline fuer Ubuntu-VMs aus Proxmox-Templates und bestehende Ubuntu-VMs.

## Inhalt

- `config/starship.toml` - Prompt-Konfiguration
- `config/starship.zsh` - OS-/Distro-Icon-Logik fuer `starship`
- `scripts/setup-zsh-baseline.sh` - nicht-interaktives Setup fuer `zsh`, `starship`, `eza`, `oh-my-zsh`, `zsh-autosuggestions`, `zsh-autocomplete`, Zeitzone, deutsche UTF-8-Locale, Konsolen-Keyboard und `tk-thran` MOTD

## Ziel

- Verwendung aus Cloud-Init `vendor`-Snippets
- keine interaktiven Installer
- reproduzierbarer Linux-Admin-Standard fuer neue Service-VMs

## Defaults

- Admin-User: `alexander`
- Zeitzone: `Europe/Berlin`
- Locale: `de_DE.UTF-8`
- Konsolen-Tastaturlayout: `de`
- Starship-Version: `1.24.2`
- MOTD-Branding: `tk-thran`
- MOTD-Modus: `summary` (Docker-Kurzstatus)
- Docker-Zugriff fuer den Zieluser: wenn die Gruppe `docker` existiert, wird der Zieluser ihr hinzugefuegt
- Fehlende Basis-Pakete auf Bestands-VMs: `ca-certificates`, `console-setup`, `curl`, `git`, `keyboard-configuration`, `locales`, `tar`, `zsh` werden bei Bedarf vorab per `apt-get` installiert

## MOTD-Standard

`setup-zsh-baseline.sh` installiert zusaetzlich eine dynamische MOTD:

- Renderer: `/usr/local/lib/tk-motd/render.sh`
- Shell-Hook: `/etc/profile.d/90-tk-thran-motd.sh`
- zsh-Source: `/etc/zsh/zshrc`
- Wrapper-Stub: `/etc/update-motd.d/99-tk-thran-status`
- Konfiguration: `/etc/default/tk-motd`

Verhalten:

- Die farbige MOTD wird standardmaessig in interaktiven Shell-Sessions ueber `/etc/profile.d/90-tk-thran-motd.sh` angezeigt.
- `zsh` sourced den Hook explizit aus `/etc/zsh/zshrc`.
- Der Wrapper unter `/etc/update-motd.d/99-tk-thran-status` bleibt nur als Stub erhalten und ist standardmaessig nicht ausfuehrbar.
- `/etc/default/tk-motd` wird nur beim ersten Lauf angelegt und spaetere manuelle Overrides bleiben erhalten.
- Die Ausgabe ist farbiger und kompakter an den Saltbox-Stil angelehnt.
- Der Header wird fuer `tk-thran` als ASCII-Art im Stil des vorgeschlagenen MOTD-Banners gerendert und zeigt direkt `Host`, `IP`, `Kernel`, `Uptime` und `Load`.
- Disk-Balken werden breiter mit vollen Unicode-Bloecken und ruhigeren Farbschwellen gerendert.
- `setupcon --force` wird bewusst nicht mehr im Setup-Lauf erzwungen, um harmlose `dead_belowmacron`-Warnings aus `console-setup` zu vermeiden.

Konfigurationskeys in `/etc/default/tk-motd`:

- `TK_MOTD_BRAND` (`tk-thran`)
- `TK_MOTD_SERVICES` (space-separierte systemd-Units)
- `TK_MOTD_MOUNTS` (space-separierte Mountpoints)
- `TK_MOTD_DOCKER_MODE` (`off|summary|detailed`)
- `TK_MOTD_DOCKER_LIMIT` (Limit fuer gelistete Container)

Default fuer `TK_MOTD_SERVICES`:

- `qemu-guest-agent ssh systemd-resolved systemd-timesyncd cron docker fail2ban`

Hinweis:

- Saltbox-spezifische Units wie `saltbox-docker-controller` oder `rclone_merger` werden bewusst nicht mehr als globale Baseline-Defaults gesetzt.
- Fuer Saltbox oder andere Sonderrollen wird die Service-Liste pro VM ueber `/etc/default/tk-motd` ueberschrieben.
- Docker-Zahlen in der MOTD erscheinen fuer interaktive User nur dann direkt, wenn der User auf den Docker-Socket zugreifen darf; nach dem ersten Hinzufuegen zur `docker`-Gruppe ist deshalb ein neuer Login noetig.

## Verwendung

Das Script ist dafuer gedacht, per Cloud-Init `runcmd` oder manuell als `root` ausgefuehrt zu werden:

```bash
curl -fsSL https://raw.githubusercontent.com/Leonderi/proxmox-linux-baseline/main/scripts/setup-zsh-baseline.sh -o /usr/local/sbin/setup-zsh-baseline.sh
chmod 0755 /usr/local/sbin/setup-zsh-baseline.sh
/usr/local/sbin/setup-zsh-baseline.sh alexander
```

Auf bestehenden Ubuntu-VMs ohne vorbereitete Template-Pakete ist derselbe Aufruf ausreichend; das Script zieht fehlende Basis-Pakete selbst nach und setzt danach die Baseline durch.
