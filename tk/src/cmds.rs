//! Die tk-Befehle. Ausgaben als Rahmentabellen.

use crate::sys;
use crate::ui::{self, mark, table, Align};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::BufRead;
use std::os::unix::process::CommandExt;
use std::process::Command;

use Align::{Left as L, Right as R};

fn s<T: ToString>(v: T) -> String {
    v.to_string()
}

fn hostname() -> String {
    sys::read("/etc/hostname")
        .map(|h| h.trim().to_string())
        .unwrap_or_default()
}

fn need_docker() -> Vec<sys::Container> {
    match sys::containers() {
        Some(c) if sys::docker_ok() => c,
        _ => {
            eprintln!("tk: kein Zugriff auf Docker (Gruppe docker, neu anmelden)");
            std::process::exit(1);
        }
    }
}

pub fn help() {
    let rows = [
        (
            "tk ps",
            "Container: Zustand, Health, Image, Version, Laufzeit, Neustarts. Probleme oben",
        ),
        (
            "tk status",
            "Überblick: System, RAM, Platten, Docker, Updates, Units, needrestart",
        ),
        (
            "tk logs <dienst> [n] [-f]",
            "Log eines Containers oder einer Unit (letzte n Zeilen, -f folgt)",
        ),
        ("tk stacks", "Compose-Projekte mit Zustand und Datei"),
        (
            "tk updates",
            "offene Updates je Paket, unattended-upgrades, Neustart",
        ),
        ("tk net", "Schnittstellen, Route, DNS, lauschende Ports"),
        ("tk doctor", "Prüfliste der Baseline"),
        ("tk info", "Steckbrief aus NetBox: Dienste, Platten, Links"),
        ("tk motd", "MOTD ausgeben (läuft bei jeder Anmeldung)"),
        ("tk version", "Version und Commit"),
    ];
    let rows: Vec<Vec<String>> = rows.iter().map(|(a, b)| vec![s(a), s(b)]).collect();
    table(
        &["Befehl", "Zeigt"],
        &rows,
        Some("tk – Werkzeugkasten (proxmox-linux-baseline)"),
        &[],
    );
}

pub fn ps() {
    let mut list = need_docker();
    let rank = |c: &sys::Container| {
        if c.state == "exited" && c.exit == 0 {
            1
        } else if !c.running || c.health == "unhealthy" {
            0
        } else {
            2
        }
    };
    list.sort_by(|a, b| rank(a).cmp(&rank(b)).then(a.name.cmp(&b.name)));
    let now = sys::now();
    let rows: Vec<Vec<String>> = list
        .iter()
        .map(|c| {
            let state = if c.state == "exited" {
                format!("exited ({})", c.exit)
            } else {
                c.state.clone()
            };
            let ts = if c.running { c.started } else { c.finished };
            vec![
                c.name.clone(),
                state,
                c.health.clone(),
                c.image.clone(),
                c.version.clone(),
                ts.map(|t| ui::since_secs(now - t))
                    .unwrap_or_else(|| "-".into()),
                s(c.restarts),
            ]
        })
        .collect();
    table(
        &[
            "Name",
            "Zustand",
            "Health",
            "Image",
            "Version",
            "Läuft seit",
            "Neustarts",
        ],
        &rows,
        Some("Container"),
        &[L, L, L, L, L, R, R],
    );
}

pub fn status() {
    let mut rows = Vec::new();
    let kernel = sys::run("uname", &["-r"], 3)
        .map(|k| k.trim().to_string())
        .unwrap_or_default();
    rows.push(vec![
        s("System"),
        format!("{} · Kernel {kernel}", sys::distro()),
        s("✓"),
    ]);
    rows.push(vec![
        s("Laufzeit"),
        ui::since_secs(sys::uptime_secs()),
        s("✓"),
    ]);
    if !sys::is_lxc() {
        rows.push(vec![s("Last"), sys::loadavg().join(" "), s("✓")]);
    }
    let (used, total) = sys::mem();
    let pct = (used * 100).checked_div(total).unwrap_or(0);
    rows.push(vec![
        s("RAM"),
        format!("{} / {} ({pct} %)", ui::human(used), ui::human(total)),
        mark(pct < 90, true),
    ]);
    for d in sys::disks() {
        if d.mounted {
            rows.push(vec![
                format!("Platte {}", d.name),
                format!(
                    "{} · {} · {} / {} ({} %)",
                    d.mount,
                    d.kind,
                    ui::human(d.used),
                    ui::human(d.total),
                    d.pct
                ),
                mark(d.pct < sys::DISK_WARN, true),
            ]);
        } else {
            rows.push(vec![
                format!("Platte {}", d.name),
                format!("{} nicht eingehängt", d.mount),
                s("✗"),
            ]);
        }
    }
    if let Some(list) = sys::containers().filter(|_| sys::docker_ok()) {
        let running = list.iter().filter(|c| c.running).count();
        let sick = list.iter().filter(|c| c.health == "unhealthy").count();
        let clean = list
            .iter()
            .all(|c| c.running || (c.state == "exited" && c.exit == 0));
        rows.push(vec![
            s("Docker"),
            format!("{running}/{} laufen, {sick} ungesund", list.len()),
            mark(sick == 0 && clean, true),
        ]);
    }
    if let Some((n, sec, _)) = sys::apt_counts() {
        rows.push(vec![
            s("Updates"),
            format!("{n} offen, davon {sec} Sicherheit"),
            mark(sec == 0, true),
        ]);
    }
    let reboot = sys::reboot_required();
    rows.push(vec![
        s("Neustart"),
        s(if reboot.is_some() {
            "nötig"
        } else {
            "nicht nötig"
        }),
        mark(reboot.is_none(), true),
    ]);
    let failed = sys::failed_units();
    rows.push(vec![
        s("Units"),
        format!("{} fehlgeschlagen", failed.len()),
        mark(failed.is_empty(), true),
    ]);
    let mut svc = Vec::new();
    if sys::which("needrestart") && sys::can_sudo() {
        svc = sys::run_root("needrestart", &["-b"], 60)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.strip_prefix("NEEDRESTART-SVC: ").map(String::from))
            .collect();
        rows.push(vec![
            s("needrestart"),
            format!("{} Dienste mit altem Code", svc.len()),
            mark(svc.is_empty(), true),
        ]);
    }
    table(
        &["Bereich", "Zustand", ""],
        &rows,
        Some(&format!("Status {}", hostname())),
        &[],
    );
    if !failed.is_empty() {
        println!();
        table(
            &["Unit", "Zustand", "Beschreibung"],
            &failed,
            Some("Fehlgeschlagene Units"),
            &[],
        );
    }
    if !svc.is_empty() {
        println!();
        let rows: Vec<Vec<String>> = svc.into_iter().map(|x| vec![x]).collect();
        table(
            &["Dienst"],
            &rows,
            Some("Dienste mit altem Code (Neustart empfohlen)"),
            &[],
        );
    }
}

pub fn logs(args: &[String]) {
    let Some(name) = args.first() else {
        eprintln!("tk logs <container|unit> [zeilen] [-f]");
        std::process::exit(2);
    };
    let lines = args
        .iter()
        .skip(1)
        .find(|a| a.chars().all(|c| c.is_ascii_digit()))
        .cloned()
        .unwrap_or_else(|| "100".into());
    let follow = args.iter().any(|a| a == "-f");
    if sys::which("docker")
        && sys::run("docker", &["inspect", "--format", "{{.Name}}", name], 4).is_some()
    {
        let mut c = Command::new("docker");
        c.args(["logs", "--tail", &lines, "--timestamps"]);
        if follow {
            c.arg("-f");
        }
        let e = c.arg(name).exec();
        eprintln!("tk: {e}");
        std::process::exit(1);
    }
    let unit = if name.contains('.') {
        name.clone()
    } else {
        format!("{name}.service")
    };
    if sys::run("systemctl", &["cat", &unit], 5).is_some() {
        let mut argv: Vec<String> = vec![
            "journalctl".into(),
            "-u".into(),
            unit,
            "-n".into(),
            lines,
            "--no-pager".into(),
        ];
        if follow {
            argv.push("-f".into());
        }
        if !sys::is_root() && sys::can_sudo() {
            argv.insert(0, "-n".into());
            argv.insert(0, "sudo".into());
        }
        let e = Command::new(&argv[0]).args(&argv[1..]).exec();
        eprintln!("tk: {e}");
        std::process::exit(1);
    }
    eprintln!("tk: weder Container noch Unit '{name}'");
    std::process::exit(1);
}

pub fn stacks() {
    let list = need_docker();
    let mut projects: BTreeMap<String, (usize, usize, String)> = BTreeMap::new();
    for c in list.iter().filter(|c| !c.project.is_empty()) {
        let e = projects
            .entry(c.project.clone())
            .or_insert((0, 0, c.workdir.clone()));
        e.1 += 1;
        if c.running {
            e.0 += 1;
        }
    }
    let files: BTreeMap<String, String> =
        sys::run("docker", &["compose", "ls", "-a", "--format", "json"], 8)
            .and_then(|j| serde_json::from_str::<Value>(&j).ok())
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .iter()
            .map(|p| {
                (
                    p["Name"].as_str().unwrap_or("").to_string(),
                    p["ConfigFiles"].as_str().unwrap_or("").to_string(),
                )
            })
            .collect();
    let rows: Vec<Vec<String>> = projects
        .iter()
        .map(|(name, (run, all, wd))| {
            let state = if run == all {
                "running"
            } else if *run == 0 {
                "exited"
            } else {
                "teilweise"
            };
            vec![
                name.clone(),
                s(state),
                format!("{run}/{all}"),
                files.get(name).cloned().unwrap_or_else(|| wd.clone()),
            ]
        })
        .collect();
    table(
        &["Projekt", "Zustand", "Container", "Compose-Datei"],
        &rows,
        Some("Compose-Projekte"),
        &[L, L, R, L],
    );
}

const DOCKER_PKGS: &[&str] = &[
    "docker-ce",
    "docker-ce-cli",
    "containerd.io",
    "docker-buildx-plugin",
    "docker-compose-plugin",
    "docker-ce-rootless-extras",
];

pub fn updates() {
    let counts = sys::apt_counts();
    let uu = sys::uu_active();
    let mut last = s("-");
    if let Some(log) =
        sys::read(sys::UU_LOG).or_else(|| sys::run_root("tail", &["-n", "200", sys::UU_LOG], 5))
    {
        let keys = [
            "Packages that will be upgraded",
            "No packages found",
            "All upgrades installed",
            "ERROR",
        ];
        if let Some(l) = log
            .lines()
            .rev()
            .find(|l| keys.iter().any(|k| l.contains(k)))
        {
            let msg = l.splitn(4, ' ').nth(3).unwrap_or("");
            last = format!("{} {}", l.get(..16).unwrap_or(""), ui::cut(msg, 50));
        }
    }
    let reboot = sys::reboot_required();
    let dash = || s("-");
    let rows = vec![
        vec![
            s("Offene Updates"),
            counts.map(|c| s(c.0)).unwrap_or_else(dash),
            counts.map(|c| mark(c.0 == 0, true)).unwrap_or_else(dash),
        ],
        vec![
            s("davon Sicherheit"),
            counts.map(|c| s(c.1)).unwrap_or_else(dash),
            counts.map(|c| mark(c.1 == 0, true)).unwrap_or_else(dash),
        ],
        vec![
            s("Stand der Zählung"),
            counts
                .map(|c| sys::fmt_local(c.2, "%Y-%m-%d %H:%M"))
                .unwrap_or_else(dash),
            dash(),
        ],
        vec![
            s("unattended-upgrades"),
            s(if uu { "täglich aktiv" } else { "nicht aktiv" }),
            mark(uu, false),
        ],
        vec![s("letzter Lauf"), last, dash()],
        vec![
            s("Neustart"),
            match &reboot {
                Some(p) if !p.is_empty() => format!("nötig: {p}"),
                Some(_) => s("nötig"),
                None => s("nicht nötig"),
            },
            mark(reboot.is_none(), true),
        ],
    ];
    table(&["Punkt", "Wert", ""], &rows, Some("Updates"), &[]);
    let mut pkgs: Vec<Vec<String>> = Vec::new();
    for line in sys::run("apt", &["list", "--upgradable"], 30)
        .unwrap_or_default()
        .lines()
    {
        // name/suite1,suite2 neu arch [upgradable from: alt]
        let Some((name, rest)) = line.split_once('/') else {
            continue;
        };
        let f: Vec<&str> = rest.split_whitespace().collect();
        if f.len() < 3 || !line.contains("from:") {
            continue;
        }
        let old = line
            .rsplit("from: ")
            .next()
            .unwrap_or("")
            .trim_end_matches(']')
            .to_string();
        let suites = f[0];
        let (src, auto) = if DOCKER_PKGS.contains(&name) {
            (s("Docker"), s("nein (monatlich)"))
        } else if suites.contains("-security") {
            (s("Sicherheit"), s(if uu { "ja" } else { "nein" }))
        } else {
            (
                suites.split(',').next().unwrap_or("").to_string(),
                s("nein"),
            )
        };
        pkgs.push(vec![name.to_string(), old, f[1].to_string(), src, auto]);
    }
    pkgs.sort_by(|a, b| {
        (a[3] != "Sicherheit")
            .cmp(&(b[3] != "Sicherheit"))
            .then(a[0].cmp(&b[0]))
    });
    println!();
    table(
        &["Paket", "Installiert", "Neu", "Quelle", "Automatisch"],
        &pkgs,
        Some("Pakete"),
        &[],
    );
}

pub fn net() {
    let ifs: Value = sys::run("ip", &["-j", "addr"], 5)
        .and_then(|j| serde_json::from_str(&j).ok())
        .unwrap_or(Value::Null);
    let mut rows = Vec::new();
    for i in ifs.as_array().into_iter().flatten() {
        let name = i["ifname"].as_str().unwrap_or("");
        if ["lo", "veth", "docker", "br-"]
            .iter()
            .any(|p| name.starts_with(p))
        {
            continue;
        }
        let addrs: Vec<String> = i["addr_info"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|a| a["scope"] == "global")
            .map(|a| format!("{}/{}", a["local"].as_str().unwrap_or(""), a["prefixlen"]))
            .collect();
        rows.push(vec![
            name.to_string(),
            i["operstate"].as_str().unwrap_or("?").to_lowercase(),
            if addrs.is_empty() {
                s("-")
            } else {
                addrs.join(", ")
            },
        ]);
    }
    table(
        &["Schnittstelle", "Zustand", "Adressen"],
        &rows,
        Some("Netz"),
        &[],
    );

    let mut info = Vec::new();
    let routes: Value = sys::run("ip", &["-j", "route", "show", "default"], 5)
        .and_then(|j| serde_json::from_str(&j).ok())
        .unwrap_or(Value::Null);
    for r in routes.as_array().into_iter().flatten() {
        info.push(vec![
            s("Default-Route"),
            format!(
                "{} über {}",
                r["gateway"].as_str().unwrap_or("-"),
                r["dev"].as_str().unwrap_or("?")
            ),
        ]);
    }
    let resolv = sys::read("/run/systemd/resolve/resolv.conf")
        .or_else(|| sys::read("/etc/resolv.conf"))
        .unwrap_or_default();
    let dns: Vec<&str> = resolv
        .lines()
        .filter_map(|l| l.strip_prefix("nameserver "))
        .map(str::trim)
        .collect();
    info.push(vec![
        s("DNS-Server"),
        if dns.is_empty() {
            s("-")
        } else {
            dns.join(", ")
        },
    ]);
    let search = sys::read("/etc/resolv.conf")
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.strip_prefix("search ").map(|v| v.trim().to_string()));
    info.push(vec![s("Suchdomäne"), search.unwrap_or_else(|| s("-"))]);
    println!();
    table(&["Punkt", "Wert"], &info, Some("Routing und DNS"), &[]);

    let out = sys::run_root("ss", &["-Htulnp"], 5)
        .or_else(|| sys::run("ss", &["-Htuln"], 5))
        .unwrap_or_default();
    let mut ports: Vec<(String, String, u32, String)> = out
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            let (addr, port) = f.get(4)?.rsplit_once(':')?;
            let proc_ = l
                .split("users:((\"")
                .nth(1)
                .and_then(|r| r.split('"').next())
                .unwrap_or("-");
            Some((
                f[0].to_string(),
                addr.trim_matches(['[', ']']).to_string(),
                port.parse().unwrap_or(0),
                proc_.to_string(),
            ))
        })
        .collect();
    ports.sort();
    ports.dedup();
    let rows: Vec<Vec<String>> = ports
        .into_iter()
        .map(|(p, a, n, c)| vec![p, a, s(n), c])
        .collect();
    println!();
    table(
        &["Proto", "Adresse", "Port", "Prozess"],
        &rows,
        Some("Lauschende Ports"),
        &[L, L, R, L],
    );
}

pub fn doctor() {
    let mut rows = Vec::new();
    match sys::read(sys::HOST_JSON).and_then(|j| serde_json::from_str::<Value>(&j).ok()) {
        Some(h) => {
            let stamp = sys::mtime(sys::HOST_JSON)
                .map(|t| sys::fmt_local(t, "%Y-%m-%d"))
                .unwrap_or_default();
            rows.push(vec![
                s("Steckbrief aus NetBox"),
                format!(
                    "{}, Stand {stamp}",
                    h["host"]["name"].as_str().unwrap_or("?")
                ),
                s("✓"),
            ]);
        }
        None => rows.push(vec![s("Steckbrief aus NetBox"), s("fehlt"), s("✗")]),
    }
    let user = std::env::var("SUDO_USER")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| s("root"));
    let shell = sys::run("getent", &["passwd", &user], 3)
        .and_then(|l| l.trim().rsplit(':').next().map(String::from))
        .unwrap_or_default();
    rows.push(vec![
        s("Login-Shell"),
        format!("{user}: {shell}"),
        mark(shell.ends_with("zsh"), false),
    ]);
    let star = sys::run("/usr/local/bin/starship", &["--version"], 3)
        .and_then(|v| v.lines().next().map(String::from));
    rows.push(vec![
        s("starship"),
        star.clone().unwrap_or_else(|| s("fehlt")),
        mark(star.is_some(), false),
    ]);
    match sys::read("/usr/share/oh-my-zsh/.tk-version") {
        Some(v) => rows.push(vec![s("oh-my-zsh"), v.trim().to_string(), s("✓")]),
        None => rows.push(vec![s("oh-my-zsh"), s("nicht aus der Baseline"), s("⚠")]),
    }
    match sys::run_root("sshd", &["-T"], 5) {
        Some(c) => {
            let pw = c.lines().any(|l| l == "passwordauthentication no");
            let root = c.lines().any(|l| l == "permitrootlogin no");
            let txt = format!(
                "{}{}",
                if pw {
                    "nur Schlüssel"
                } else {
                    "Passwörter erlaubt"
                },
                if root {
                    ", kein root-Login"
                } else {
                    ", root-Login erlaubt"
                }
            );
            rows.push(vec![s("SSH"), txt, mark(pw && root, false)]);
        }
        None => rows.push(vec![s("SSH"), s("sshd -T nicht lesbar (sudo)"), s("⚠")]),
    }
    let uu = sys::uu_active();
    rows.push(vec![
        s("unattended-upgrades"),
        s(if uu { "täglich aktiv" } else { "nicht aktiv" }),
        mark(uu, false),
    ]);
    if sys::is_lxc() {
        rows.push(vec![s("Zeit"), s("vom Host (LXC)"), s("✓")]);
    } else {
        let sync = sys::run(
            "timedatectl",
            &["show", "-p", "NTPSynchronized", "--value"],
            5,
        )
        .map(|v| v.trim() == "yes")
        .unwrap_or(false);
        rows.push(vec![
            s("Zeit"),
            s(if sync {
                "synchronisiert"
            } else {
                "nicht synchronisiert"
            }),
            mark(sync, false),
        ]);
    }
    let usage = sys::run("journalctl", &["--disk-usage"], 10)
        .or_else(|| sys::run_root("journalctl", &["--disk-usage"], 10))
        .unwrap_or_default();
    let size = usage
        .split_whitespace()
        .find(|w| {
            w.ends_with(['K', 'M', 'G', 'T'])
                && w.chars().next().is_some_and(|c| c.is_ascii_digit())
        })
        .unwrap_or("?")
        .to_string();
    let limit = sys::run(
        "systemd-analyze",
        &["cat-config", "systemd/journald.conf"],
        5,
    )
    .unwrap_or_default()
    .lines()
    .filter_map(|l| l.strip_prefix("SystemMaxUse=").map(String::from))
    .next_back();
    rows.push(vec![
        s("Journal"),
        format!(
            "{size} (Grenze {})",
            limit.clone().unwrap_or_else(|| s("Standard"))
        ),
        mark(limit.is_some(), true),
    ]);
    let dns = sys::run("getent", &["hosts", "doku.tk-thran.com"], 5).is_some();
    rows.push(vec![
        s("DNS"),
        format!(
            "doku.tk-thran.com {}",
            if dns {
                "aufgelöst"
            } else {
                "nicht auflösbar"
            }
        ),
        mark(dns, false),
    ]);
    let probs = sys::problems(&sys::containers(), &sys::disks());
    if probs.is_empty() {
        rows.push(vec![
            s("Warnungen"),
            s("keine (Neustart, Updates, Units, Platten, Container)"),
            s("✓"),
        ]);
    }
    for p in probs {
        rows.push(vec![s("Warnung"), p, s("⚠")]);
    }
    table(
        &["Prüfung", "Ergebnis", ""],
        &rows,
        Some(&format!("Baseline-Prüfung {}", hostname())),
        &[],
    );
}

pub fn info() {
    let Some(d) = sys::read(sys::HOST_JSON).and_then(|j| serde_json::from_str::<Value>(&j).ok())
    else {
        eprintln!("tk: {} fehlt", sys::HOST_JSON);
        std::process::exit(1);
    };
    let h = &d["host"];
    let st = |v: &Value| match v {
        Value::Null => s("-"),
        Value::String(x) => x.clone(),
        other => other.to_string(),
    };
    let mut rows = vec![
        vec![s("Name"), st(&h["name"])],
        vec![s("Typ"), format!("{} {}", st(&h["typ"]), st(&h["vmid"]))],
        vec![
            s("Zone"),
            format!("{} (VLAN {})", st(&h["zone"]), st(&h["vlan"])),
        ],
        vec![s("IP"), st(&h["ip"])],
        vec![s("Beschreibung"), st(&h["description"])],
        vec![s("Klasse"), st(&h["class"])],
        vec![s("Backup"), st(&d["backup"])],
        vec![
            s("Tags"),
            h["tags"]
                .as_array()
                .map(|t| {
                    t.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(";")
                })
                .unwrap_or_default(),
        ],
    ];
    for f in h["fqdns"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        rows.push(vec![s("Web"), format!("https://{f}")]);
    }
    rows.push(vec![s("Doku"), st(&d["doku"])]);
    rows.push(vec![s("NetBox"), st(&h["netbox"])]);
    table(&["Feld", "Wert"], &rows, Some("Steckbrief (NetBox)"), &[]);

    let svc: Vec<Vec<String>> = h["services"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|x| {
            let ports: Vec<String> = x["ports"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|p| p.to_string())
                .collect();
            vec![
                st(&x["name"]),
                format!(
                    "{}/{}",
                    x["protocol"].as_str().unwrap_or(""),
                    ports.join(",")
                ),
                st(&x["description"]),
            ]
        })
        .collect();
    println!();
    table(
        &["Dienst", "Port", "Beschreibung"],
        &svc,
        Some("Dienste"),
        &[],
    );

    let mut disks: Vec<&Value> = h["disks"].as_array().into_iter().flatten().collect();
    disks.sort_by_key(|x| x["mountpoint"].as_str().unwrap_or("").to_string());
    let rows: Vec<Vec<String>> = disks
        .iter()
        .map(|x| {
            let kind = match x["storage"].as_str() {
                Some("local-lvm") => s("NVMe"),
                Some("hdd-zfs") => s("HDD"),
                Some(o) => s(o),
                None => s("-"),
            };
            vec![
                st(&x["name"]),
                st(&x["mountpoint"]),
                kind,
                format!("{}G", st(&x["sizeGb"])),
                st(&x["description"]),
            ]
        })
        .collect();
    println!();
    table(
        &["Disk", "Mount", "Speicher", "Größe", "Beschreibung"],
        &rows,
        Some("Platten"),
        &[L, L, L, R, L],
    );
}

/// TSV von stdin als Tabelle, fuer eigene Skripte: ... | tk table [--title X]
pub fn tsv_table(args: &[String]) {
    let title = args
        .iter()
        .position(|a| a == "--title")
        .and_then(|i| args.get(i + 1))
        .cloned();
    let lines: Vec<Vec<String>> = std::io::stdin()
        .lock()
        .lines()
        .map_while(Result::ok)
        .filter(|l| !l.is_empty())
        .map(|l| l.split('\t').map(String::from).collect())
        .collect();
    if let Some((head, rows)) = lines.split_first() {
        let head: Vec<&str> = head.iter().map(String::as_str).collect();
        table(&head, rows, title.as_deref(), &[]);
    }
}
