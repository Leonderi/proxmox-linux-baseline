# Proxmox Linux Baseline

Schlanke, wiederverwendbare Linux-Baseline fuer Ubuntu-VMs aus Proxmox-Templates.

## Inhalt

- `config/starship.toml` - Prompt-Konfiguration
- `config/starship.zsh` - OS-/Distro-Icon-Logik fuer `starship`
- `scripts/setup-zsh-baseline.sh` - nicht-interaktives Setup fuer `zsh`, `starship`, `eza`, `oh-my-zsh`, `zsh-autosuggestions`, `zsh-autocomplete`, Zeitzone, Locale und Konsolen-Keyboard

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

## Verwendung

Das Script ist dafuer gedacht, per Cloud-Init `runcmd` oder manuell als `root` ausgefuehrt zu werden:

```bash
curl -fsSL https://raw.githubusercontent.com/Leonderi/proxmox-linux-baseline/main/scripts/setup-zsh-baseline.sh -o /usr/local/sbin/setup-zsh-baseline.sh
chmod 0755 /usr/local/sbin/setup-zsh-baseline.sh
/usr/local/sbin/setup-zsh-baseline.sh alexander
```
