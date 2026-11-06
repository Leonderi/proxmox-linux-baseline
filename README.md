# Proxmox Linux Baseline

Gemeinsame Grundausstattung der Linux-Gäste auf `pve1` als Ansible-Rolle: Zugang, Systemschicht, Sicherheitsupdates, zsh mit starship, `tk-thran`-MOTD und der Werkzeugkasten `tk`. Das Inventar kommt aus NetBox.

Entscheidungen und Einordnung: [Zielarchitektur HZ1, Linux-Baseline](https://doku.tk-thran.com/infrastructure/inventory/target-architecture#linux-baseline) (2026-11-06).

## Aufbau

| Pfad | Inhalt |
| --- | --- |
| `ansible.cfg` | Inventar, Benutzer `alexander`, Schlüssel `~/.ssh/id_ed25519_ansible` |
| `inventory/netbox.py` | dynamisches Inventar, siehe unten |
| `playbooks/baseline.yml` | wendet die Rolle auf die Gruppe `baseline` an, ein Gast nach dem anderen |
| `roles/baseline/` | die Rolle |
| `bootstrap/bootstrap-guest.sh` | einmalig je Gast: Ansible-Schlüssel und `sudo` ohne Passwort |
| `scripts/setup-zsh-baseline.sh` | **veraltet**, altes Einmal-Skript für cloud-init. Entfällt, sobald die Vorlage VM 900 aus der Rolle gebaut wird |

## Inventar

`inventory/netbox.py` ruft den Doku-Exporter `netbox-hosts.mjs` aus dem Doku-Repo auf (über den NetBox-MCP-Server, ohne Token) und schreibt nach `~/.cache/tk-baseline/netbox-hosts.json`. Ist NetBox nicht erreichbar, nimmt es den letzten Export aus dem Doku-Repo (`infrastructure/inventory/netbox-hosts.json`). Kein Gast hängt zur Laufzeit an NetBox.

| Gruppe | Inhalt |
| --- | --- |
| `linux` | alle aktiven Ubuntu- und Debian-Gäste |
| `baseline` | `linux` ohne VM 850 (Saltbox verwaltet sich selbst) |
| `lxc`, `vm` | nach Typ |
| `zone_app`, `zone_ops`, … | nach Zone |
| `class_crit`, `class_std`, `env_prd`, `env_tst` | nach Tags |

Jeder Host bekommt die NetBox-Angaben als Variable `nb` (VMID, Typ, Zone, VLAN, IP, Beschreibung, Tags, Klasse, Dienste, FQDNs).

Umgebung: `TK_DOKU_REPO` (Standard `~/workdir/doku`), `NETBOX_MCP_URL`, `NETBOX_TOKEN` (REST statt MCP), `TK_INVENTORY_OFFLINE=1` (nur den Export im Doku-Repo lesen).

## Was die Rolle setzt

| Bereich | Inhalt |
| --- | --- |
| Zugang | Schlüssel `ansible@ops-devbox` in `authorized_keys`, `/etc/sudoers.d/10-tk-baseline` (`NOPASSWD`), `sshd` nur mit Schlüssel und ohne root-Login (`/etc/ssh/sshd_config.d/10-tk-baseline.conf`) |
| System | Basispakete, `journald` höchstens 500 MB, Zeitzone `Europe/Berlin`, Locale `de_DE.UTF-8`, Tastatur `de`. Nur VMs: Guest Agent, `fstrim.timer`, `systemd-timesyncd` |
| Updates | `unattended-upgrades` täglich, nur Sicherheitsupdates (Ubuntu-Vorgabe), **ohne automatischen Neustart**. `needrestart` mit Ubuntu-Vorgabe (Docker ausgenommen), in LXCs ohne Kernel-Hinweise. Zähler offener Updates nach jedem apt-Lauf in `/var/lib/tk/apt-check` |
| Shell | zsh mit oh-my-zsh, `zsh-autosuggestions`, `zsh-autocomplete` und starship für `alexander` und root. Versionen fest in `defaults/main.yml`. Der Steuerrechner lädt sie und prüft die Prüfsumme, die Gäste holen nichts aus dem Internet |
| MOTD | Banner `tk-thran` und Steckbrief aus NetBox (`/etc/tk/motd-head`, `/etc/tk/host.json`), darunter Systemzustand, Warnblock nur bei Problemen |
| `tk` | `/usr/local/bin/tk` |

### MOTD

Variante „Steckbrief“ (entschieden 2026-11-06), unter dem Banner:

```
  app-web · LXC 380 · APP (VLAN 30) · 10.40.30.30
  Firmenwebseite tk-thran.de (Hugo, Caddy)

  Klasse   std · PBS täglich 01:00
  Dienste  Caddy :80
  Web      https://www.tk-thran.de
  Doku     doku.tk-thran.com/infrastructure/hosts/app-web

  System   Ubuntu 24.04.5 · up 14 Tage · Load 0.02
  Speicher RAM 180M/512M · / 43 % · /opt/containers 3 %
  Docker   1/1 laufen, alle gesund

  ⚠ Neustart nötig · 3 Sicherheitsupdates offen
```

Der Warnblock erscheint bei: Neustart nötig, offenen Sicherheitsupdates, fehlgeschlagenen Units, Platten ab 85 %, ungesunden, ständig neu startenden oder mit Fehler beendeten Containern. `NO_COLOR=1` schaltet die Farben ab.

### tk

| Befehl | Zeigt |
| --- | --- |
| `tk ps` | Container: Name, Zustand, Health, Image, Laufzeit. Probleme oben |
| `tk status` | MOTD, fehlgeschlagene Units, Dienste mit altem Code (`needrestart -b`) |
| `tk logs <dienst> [n] [-f]` | Container-Log oder Journal einer Unit |
| `tk stacks` | Compose-Projekte |
| `tk updates` | offene Updates, letzter Lauf von `unattended-upgrades`, Neustart nötig? |
| `tk net` | Adressen, Route, DNS, lauschende Ports |
| `tk doctor` | Prüfliste der Baseline mit ✓ und ⚠ |
| `tk info` | Steckbrief aus NetBox |

## Verwendung

Steuerrechner ist die Dev-VM 210 (`ops-devbox`), bis Semaphore auf `ops-core` läuft. Die Firewall-Regel `4470` (`OPS -> Zonen | tcp/22 Ansible | ops-devbox`) erlaubt SSH in die Zonen EDGE, APP, MAIL und GAME.

Voraussetzungen auf dem Steuerrechner:

```bash
sudo apt-get install -y ansible-core
ssh-keygen -t ed25519 -C ansible@ops-devbox -f ~/.ssh/id_ed25519_ansible
```

Neuer Gast, einmalig, auf `pve1`:

```bash
pct exec <vmid> -- bash -s < bootstrap/bootstrap-guest.sh
qm guest exec <vmid> --pass-stdin 1 -- bash -s < bootstrap/bootstrap-guest.sh
```

Lauf, im Repo auf dem Steuerrechner:

```bash
ansible-inventory --graph
ansible-playbook playbooks/baseline.yml --limit app-web --check --diff
ansible-playbook playbooks/baseline.yml --limit app-web
```
