# Proxmox Linux Baseline

Schlanke, wiederverwendbare Linux-Baseline fuer Ubuntu-VMs aus Proxmox-Templates.

## Inhalt

- `config/starship.toml` - Prompt-Konfiguration
- `config/starship.zsh` - OS-/Distro-Icon-Logik fuer `starship`
- `scripts/setup-zsh-baseline.sh` - nicht-interaktives Setup fuer `zsh`, `starship`, `eza`, `oh-my-zsh`, `zsh-autosuggestions`, `zsh-autocomplete`, Zeitzone, Locale, Konsolen-Keyboard und `tk-thran` MOTD

## Ziel

- Verwendung aus Cloud-Init `vendor`-Snippets
- keine interaktiven Installer
- reproduzierbarer Linux-Admin-Standard fuer neue Service-VMs

## Defaults

- Admin-User: `alexander`
- Zeitzone: `Europe/Berlin`
- Locale: `en_US.UTF-8`
- Konsolen-Tastaturlayout: `de`
- Starship-Version: `1.24.2`
- MOTD-Branding: `tk-thran`
- MOTD-Modus: `summary` (Docker-Kurzstatus)

## MOTD-Standard

`setup-zsh-baseline.sh` installiert zusaetzlich eine dynamische MOTD:

- Renderer: `/usr/local/lib/tk-motd/render.sh`
- Wrapper: `/etc/update-motd.d/99-tk-thran-status`
- Konfiguration: `/etc/default/tk-motd`

Verhalten:

- Ubuntu-Default-Skripte unter `/etc/update-motd.d/` werden deaktiviert.
- Nur `99-tk-thran-status` bleibt aktiv.
- `/etc/default/tk-motd` wird nur beim ersten Lauf angelegt und spaetere manuelle Overrides bleiben erhalten.

Konfigurationskeys in `/etc/default/tk-motd`:

- `TK_MOTD_BRAND` (`tk-thran`)
- `TK_MOTD_SERVICES` (space-separierte systemd-Units)
- `TK_MOTD_MOUNTS` (space-separierte Mountpoints)
- `TK_MOTD_DOCKER_MODE` (`off|summary|detailed`)
- `TK_MOTD_DOCKER_LIMIT` (Limit fuer gelistete Container)

## Verwendung

Das Script ist dafuer gedacht, per Cloud-Init `runcmd` oder manuell als `root` ausgefuehrt zu werden:

```bash
curl -fsSL https://raw.githubusercontent.com/Leonderi/proxmox-linux-baseline/main/scripts/setup-zsh-baseline.sh -o /usr/local/sbin/setup-zsh-baseline.sh
chmod 0755 /usr/local/sbin/setup-zsh-baseline.sh
/usr/local/sbin/setup-zsh-baseline.sh alexander
```
