# Proxmox Linux Baseline

Gemeinsame Grundausstattung der Linux-Gäste auf `pve1` als Ansible-Rolle: Zugang, Systemschicht, Sicherheitsupdates, zsh mit starship, `tk-thran`-MOTD und der Werkzeugkasten `tk`. Das Inventar kommt aus NetBox.

Entscheidungen und Einordnung: [Zielarchitektur HZ1, Linux-Baseline](https://doku.tk-thran.com/infrastructure/inventory/target-architecture#linux-baseline) (2026-11-06).

## Aufbau

| Pfad | Inhalt |
| --- | --- |
| `ansible.cfg` | Inventar, Benutzer `alexander`, Schlüssel `~/.ssh/id_ed25519_ansible` |
| `inventory/netbox.py` | dynamisches Inventar, siehe unten |
| `playbooks/baseline.yml` | wendet die Rolle auf die Gruppe `baseline` an, ein Gast nach dem anderen |
| `playbooks/template.yml` | baut die Vorlage: Rolle auf eine Bau-VM, Updates, mit `-e seal=true` versiegeln |
| `roles/baseline/` | Grundausstattung |
| `tk/` | Werkzeugkasten und MOTD als Rust-Binary |
| `.forgejo/workflows/tk.yml` | CI für `tk`: Format, Clippy, Tests, Release-Build |
| `roles/docker/`, `playbooks/docker.yml` | Docker einheitlich aus dem Repo von Docker, Umstellung von `docker.io` |
| `bootstrap/bootstrap-guest.sh` | einmalig je Gast: Ansible-Schlüssel und `sudo` ohne Passwort |
| `scripts/setup-zsh-baseline.sh` | **veraltet**, altes Einmal-Skript für cloud-init der Vorlage 900. Entfällt mit dem Löschen von 900 |

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
| MOTD | Banner `tk-thran` und Steckbrief aus NetBox (`/etc/tk/motd-head`, `/etc/tk/host.json`, `/etc/tk/disks`), darunter Systemzustand, Warnblock nur bei Problemen. Ausgegeben von `tk motd` beim Login |
| `tk` | `/usr/local/bin/tk`, statisches Rust-Binary |

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

`/usr/local/bin/tk` ist ein statisches Rust-Binary (musl, ca. 820 KB, entschieden 2026-11-06). Es braucht auf dem Gast nichts außer den Werkzeugen, die es abfragt (`docker`, `systemctl`, `ip`, `ss`, `apt`). Plattenbelegung und RAM liest es direkt (`statvfs`, `/proc/meminfo`). Ausgaben als Rahmentabellen im Stil von `cscli`, Zustände farbig.

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
| `tk motd` | das MOTD, läuft bei jeder Anmeldung |
| `tk table` | TSV von stdin als Tabelle, für eigene Skripte |
| `tk version` | Version und Commit |

**Bau und Verteilung.** Bei jeder Änderung an `tk/` prüft Forgejo Actions Format, Clippy (`-D warnings`) und Tests und baut das Release-Binary. Verteilt wird nicht das CI-Ergebnis, sondern der Ansible-Steuerrechner baut selbst: aus dem committeten Stand (`git archive`, Version = letzter Commit an `tk/`), im selben Image `rust:1.99.1-alpine3.23` mit gepinntem Digest (`baseline_tk_builder_image`), und nur, wenn die Version noch nicht im Cache `~/.cache/tk-baseline/` liegt. Grund: Das Repo ist privat, für Release-Anhänge bräuchte Ansible einen gespeicherten Token. Mit Semaphore auf `ops-core` lässt sich auf Releases umstellen. Voraussetzung auf dem Steuerrechner: Docker.

Lokal bauen und testen, im Repo:

```bash
cd tk
docker run --rm --user "$(id -u):$(id -g)" -e CARGO_HOME=/cargo -v ~/.cache/tk-baseline/cargo:/cargo -v "$PWD:/src" -w /src rust:1.99.1-alpine3.23 cargo test --release --locked
```

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
| Der neue Daemon legt ein neues Socket an | bis zum Neustart des Containers | Container, die `/var/run/docker.sock` einbinden (z. B. `socket-proxy` für Traefik). Die Rolle startet sie seit `1e5f59c` gezielt neu |
| Während des Paketwechsels läuft kein Daemon, damit gibt es keinen eingebauten DNS zwischen den Containern | etwa 20 s (`dpkg`) | Dienste, die ihre Datenbank bei jeder Anfrage über den Containernamen suchen, z. B. Nextcloud und Authentik |

## Vorlage

Vorlage `901` (`ubuntu26-template-base`, Ubuntu 26.04 LTS), gebaut am 2026-11-06. Neue VMs nur als Vollklon (`qm clone 901 <vmid> --full 1`).

Bau, auf `pve1`:

```bash
B=https://cloud-images.ubuntu.com/releases/resolute/release
curl -fsSLO $B/SHA256SUMS && curl -fsSLO $B/ubuntu-26.04-server-cloudimg-amd64.img
grep ' \*\?ubuntu-26.04-server-cloudimg-amd64.img$' SHA256SUMS | sha256sum -c -
qm create 901 --name ubuntu26-template-base --ostype l26 --machine q35 --bios ovmf \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 --cpu host --cores 2 --memory 2048 --balloon 0 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr2,tag=40 --serial0 socket \
  --agent enabled=1,fstrim_cloned_disks=1 --tags template
qm importdisk 901 ubuntu-26.04-server-cloudimg-amd64.img local-lvm
qm set 901 --scsi0 local-lvm:vm-901-disk-1,discard=on,iothread=1,ssd=1 --boot order=scsi0 --ide2 local-lvm:cloudinit
qm resize 901 scsi0 16G
qm set 901 --ciuser alexander --sshkeys keys.pub --ipconfig0 ip=10.40.40.90/24,gw=10.40.40.1 --nameserver 10.40.40.1 --ciupgrade 0
qm start 901
```

`keys.pub` enthält den Admin-Schlüssel und `ansible@ops-devbox`. Auf dem Steuerrechner:

```bash
ansible-playbook -i 10.40.40.90, playbooks/template.yml
ansible-playbook -i 10.40.40.90, playbooks/template.yml -e seal=true
```

Danach auf `pve1` Netz zurücksetzen (ins Leere, damit ein vergessener Netzschritt beim Klonen auffällt) und zur Vorlage machen:

```bash
qm set 901 --net0 virtio,bridge=vmbr2 --ipconfig0 ip=dhcp --delete nameserver
qm template 901
```

Pflicht danach: ein Test-Klon (Hostname, eigene `machine-id`, neue SSH-Hostschlüssel, Zeit vom Gateway, `tk doctor` ohne Warnungen), dann löschen.

Auf Ubuntu 26.04 geprüft: `sudo-rs` (Drop-in mit `visudo -cf`), Rust-coreutils (`tk` nutzt sie nicht), Python 3.14 mit ansible-core 2.16, chrony mit dem Gateway als Quelle.

## Verwendung

Steuerrechner ist die Dev-VM 210 (`ops-devbox`), bis Semaphore auf `ops-core` läuft. Die Firewall-Regel `4470` (`OPS -> Zonen | tcp/22 Ansible | ops-devbox`) erlaubt SSH in die Zonen EDGE, APP, MAIL und GAME.

Voraussetzungen auf dem Steuerrechner:

```bash
sudo apt-get install -y ansible-core
ssh-keygen -t ed25519 -C ansible@ops-devbox -f ~/.ssh/id_ed25519_ansible
```

Bestandsgast ohne Baseline, einmalig, auf `pve1` (Klone aus Vorlage 901 brauchen das nicht):

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
