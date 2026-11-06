# Proxmox Linux Baseline

Gemeinsame Grundausstattung der Linux-Gäste auf `pve1` als Ansible-Rolle: Zugang, Systemschicht, Sicherheitsupdates, zsh mit starship, `tk-thran`-MOTD und der Werkzeugkasten `tk`. Das Inventar kommt aus NetBox.

Entscheidungen und Einordnung: [Zielarchitektur HZ1, Linux-Baseline](https://doku.tk-thran.com/infrastructure/inventory/target-architecture#linux-baseline) (2026-11-06).

## Aufbau

| Pfad | Inhalt |
| --- | --- |
| `ansible.cfg` | Inventar, Benutzer `alexander`, Schlüssel `~/.ssh/id_ed25519_ansible` |
| `inventory/netbox.py` | dynamisches Inventar, siehe unten |
| `playbooks/baseline.yml` | wendet die Rolle auf die Gruppe `baseline` an, ein Gast nach dem anderen |
| `roles/baseline/` | Grundausstattung |
| `roles/docker/`, `playbooks/docker.yml` | Docker einheitlich aus dem Repo von Docker, Umstellung von `docker.io` |
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
| Zugang | Schlüssel `ansible@ops-devbox` in `authorized_keys`, `/etc/sudoers.d/10-tk-baseline` (`NOPASSWD`), `sshd` nur mit Schlüssel, ohne root-Login und ohne eigene „Last login“-Zeile, die steht im MOTD (`/etc/ssh/sshd_config.d/10-tk-baseline.conf`) |
| System | Basispakete, `journald` höchstens 500 MB, Zeitzone `Europe/Berlin`, Locale `de_DE.UTF-8`, Tastatur `de`. Nur VMs: Guest Agent, `fstrim.timer`, `systemd-timesyncd` |
| Updates | `unattended-upgrades` täglich, nur Sicherheitsupdates (Ubuntu-Vorgabe), **ohne automatischen Neustart**. `needrestart` mit Ubuntu-Vorgabe (Docker ausgenommen), in LXCs ohne Kernel-Hinweise. Zähler offener Updates nach jedem apt-Lauf in `/var/lib/tk/apt-check` |
| Shell | zsh mit oh-my-zsh, `zsh-autosuggestions`, `zsh-autocomplete` und starship für `alexander` und root. Versionen fest in `defaults/main.yml`. Der Steuerrechner lädt sie und prüft die Prüfsumme, die Gäste holen nichts aus dem Internet |
| MOTD | Banner `tk-thran` und Steckbrief aus NetBox (`/etc/tk/motd-head`, `/etc/tk/host.json`), darunter Systemzustand, Warnblock nur bei Problemen |
| `tk` | `/usr/local/bin/tk` |

### MOTD

Kopf „kompakt“ (entschieden 2026-11-06): Banner `tk-thran` in Firmen-Lila (`#9040D0`), rechts daneben die wichtigsten Angaben aus NetBox. Die Platten kommen aus NetBox (Name, Mountpoint, NVMe/HDD), die Belegung misst der Gast selbst.

```
  __  __       __  __                 app-web · LXC 380
 / /_/ /______/ /_/ /  _______ ____   APP (VLAN 30) · 10.40.30.30
/ __/  '_/___/ __/ _ \/ __/ _ `/ _ \  std · PBS täglich 01:00
\__/_/\_\    \__/_//_/_/  \_,_/_//_/  Firmenwebseite tk-thran.de (Hugo, Caddy)

  Dienste  Caddy :80
  Web      https://www.tk-thran.de
  Doku     doku.tk-thran.com/infrastructure/hosts/app-web

  System   Ubuntu 24.04.5 · up 16 Tage
  Login    zuletzt heute 18:25 von 192.168.6.110
  RAM      Arbeitsspeicher                 86M/512M  ███░░░░░░░░░░░░░  16 %
  Platten  rootfs  /                NVMe  1,8G/7,8G  ████░░░░░░░░░░░░  24 %
           mp0     /opt/containers  NVMe  1,1M/3,9G  ░░░░░░░░░░░░░░░░   1 %
  Docker   1/1 laufen, alle gesund

  ⚠ 10 Sicherheitsupdates offen
```

Der Warnblock erscheint bei: Neustart nötig, offenen Sicherheitsupdates, fehlgeschlagenen Units, nicht eingehängten Disks, Platten ab 85 %, ungesunden, ständig neu startenden oder mit Fehler beendeten Containern. In LXCs fehlt die Last, weil `/proc/loadavg` dort die Last des Hosts zeigt. `NO_COLOR=1` schaltet die Farben ab.

### tk

`/usr/local/bin/tk` (Python) gibt Rahmentabellen im Stil von `cscli` aus, Zustände farbig.

| Befehl | Zeigt |
| --- | --- |
| `tk ps` | Container: Zustand, Health, Image, Version, Laufzeit, Neustarts. Probleme oben |
| `tk status` | Überblick: System, RAM, Platten, Docker, Updates, Neustart, Units, needrestart |
| `tk logs <dienst> [n] [-f]` | Container-Log oder Journal einer Unit (als Strom, nicht als Tabelle) |
| `tk stacks` | Compose-Projekte mit Zustand, Container und Datei |
| `tk updates` | offene Updates je Paket mit Quelle und ob es automatisch kommt (Docker-Pakete: monatlich), letzter Lauf, Neustart |
| `tk net` | Schnittstellen, Route, DNS, lauschende Ports |
| `tk doctor` | Prüfliste der Baseline mit ✓ und ⚠ |
| `tk info` | Steckbrief aus NetBox mit Diensten und Platten |
| `tk table` | TSV von stdin als Tabelle, für eigene Skripte |

## Docker

Entschieden am 2026-11-06: überall `docker-ce` aus dem Repo von Docker. Die Rolle `docker` (`playbooks/docker.yml`) lässt Gäste ohne Docker aus und macht sonst:

1. Docker-Schlüssel auf dem Steuerrechner laden und den Fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` prüfen, Paketquelle als `docker.sources` anlegen.
2. `daemon.json` mit `live-restore` und Log-Grenzen (`10m` × 3) schreiben. Vorhandene Einstellungen wie `data-root` bleiben.
3. Auf Gästen mit `docker.io`: `live-restore` per Reload aktivieren, laufende Container merken, Dienst und Socket stoppen, Ubuntu-Pakete entfernen (`/var/lib/docker` bleibt), `docker-ce` installieren, Socket und Dienst frisch starten, prüfen, dass jeder vorher laufende Container läuft und kein Image fehlt. Scheitert etwas, kommt `docker.io` zurück und der Lauf bricht ab.

Updates kommen nicht über `unattended-upgrades`, sondern monatlich per Ansible.

Ausgenommen (`docker_exclude_vmids`, `docker_keep_ubuntu_vmids`): Mailcow (330) mit eigenem Update-Ablauf und die Gäste, die bis zu ihrem Umzug nach `ops-core`/`app-tools` bei `docker.io` bleiben (220, 240, 320, 360, 390, 520).

Umgestellt am 2026-11-06: 380, 510, 370, 110, 340, 250, 210; nur Konfiguration auf 310 und 800. Die Container liefen überall ohne Neustart durch. Zwei Lücken bleiben:

| Lücke | Dauer | Wen es trifft |
| --- | --- | --- |
| Start des neuen Daemons baut die Portweiterleitungen neu auf | etwa 1 s | alle veröffentlichten Ports |
| Während des Paketwechsels läuft kein Daemon, damit gibt es keinen eingebauten DNS zwischen den Containern | etwa 20 s (`dpkg`) | Dienste, die ihre Datenbank bei jeder Anfrage über den Containernamen suchen, z. B. Nextcloud und Authentik |

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
