//! Systemdaten: Befehle mit Zeitlimit, Docker, Platten, Speicher, Updates, Warnungen.

use serde_json::Value;
use std::collections::HashSet;
use std::ffi::CString;
use std::fs;
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const HOST_JSON: &str = "/etc/tk/host.json";
pub const MOTD_HEAD: &str = "/etc/tk/motd-head";
pub const DISKS: &str = "/etc/tk/disks";
pub const APT_CHECK: &str = "/var/lib/tk/apt-check";
pub const UU_LOG: &str = "/var/log/unattended-upgrades/unattended-upgrades.log";
pub const DISK_WARN: u64 = 85;

// ------------------------------------------------------------------ Befehle

/// Befehl ausfuehren, stdout bei Exit 0 zurueckgeben. Nach `secs` wird abgebrochen.
pub fn run(cmd: &str, args: &[&str], secs: u64) -> Option<String> {
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut out = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = out.read_to_string(&mut s);
        s
    });
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let s = reader.join().unwrap_or_default();
                return if status.success() { Some(s) } else { None };
            }
            Ok(None) if start.elapsed() > Duration::from_secs(secs) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => return None,
        }
    }
}

pub fn is_root() -> bool {
    unsafe { libc::geteuid() == 0 }
}

/// sudo ohne Passwort verfuegbar (oder schon root)?
pub fn can_sudo() -> bool {
    is_root() || run("sudo", &["-n", "true"], 5).is_some()
}

/// Wie run, als root ueber `sudo -n`, falls noetig.
pub fn run_root(cmd: &str, args: &[&str], secs: u64) -> Option<String> {
    if is_root() {
        return run(cmd, args, secs);
    }
    let mut a = vec!["-n", cmd];
    a.extend_from_slice(args);
    run("sudo", &a, secs)
}

pub fn read(path: &str) -> Option<String> {
    fs::read_to_string(path).ok()
}

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub fn mtime(path: &str) -> Option<i64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs() as i64)
}

/// Lokale Zeit als "YYYY-MM-DD HH:MM" (ueber date, damit die Zeitzone stimmt).
pub fn fmt_local(epoch: i64, fmt: &str) -> String {
    run("date", &["-d", &format!("@{epoch}"), &format!("+{fmt}")], 5)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "-".into())
}

// ------------------------------------------------------------------ Zeit

/// Tage seit 1970-01-01 fuer ein Datum (Algorithmus von Howard Hinnant).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// RFC 3339 wie von Docker ("2026-10-21T17:21:19.2560354Z", auch mit +01:00) in Sekunden.
pub fn parse_rfc3339(s: &str) -> Option<i64> {
    if s.len() < 19 || s.starts_with("0001") {
        return None;
    }
    let n = |a: usize, b: usize| s.get(a..b)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (
        n(0, 4)?,
        n(5, 7)?,
        n(8, 10)?,
        n(11, 13)?,
        n(14, 16)?,
        n(17, 19)?,
    );
    let mut t = days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + se;
    let rest = &s[19..];
    let tz = rest.trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
    if tz.len() >= 6 && (tz.starts_with('+') || tz.starts_with('-')) {
        let off = tz[1..3].parse::<i64>().ok()? * 3600 + tz[4..6].parse::<i64>().ok()? * 60;
        t -= if tz.starts_with('+') { off } else { -off };
    }
    Some(t)
}

// ------------------------------------------------------------------ System

pub fn is_lxc() -> bool {
    if let Some(c) = read("/run/systemd/container") {
        return c.trim() == "lxc";
    }
    run("systemd-detect-virt", &[], 3)
        .map(|s| s.trim() == "lxc")
        .unwrap_or(false)
}

pub fn distro() -> String {
    let os = read("/etc/os-release").unwrap_or_default();
    os.lines()
        .find_map(|l| l.strip_prefix("PRETTY_NAME="))
        .map(|v| v.trim_matches('"').trim_end_matches(" LTS").to_string())
        .unwrap_or_else(|| "Linux".into())
}

pub fn uptime_secs() -> i64 {
    read("/proc/uptime")
        .and_then(|s| s.split('.').next().and_then(|v| v.parse().ok()))
        .unwrap_or(0)
}

/// "3 Tage", "1 Tag, 4 Std", "5 Std", "12 min" (wie das bisherige MOTD).
pub fn uptime_words() -> String {
    let s = uptime_secs();
    let (d, h, m) = (s / 86_400, s % 86_400 / 3600, s % 3600 / 60);
    if d >= 2 {
        format!("{d} Tage")
    } else if d == 1 {
        format!("1 Tag, {h} Std")
    } else if h > 0 {
        format!("{h} Std")
    } else {
        format!("{m} min")
    }
}

pub fn loadavg() -> Vec<String> {
    read("/proc/loadavg")
        .map(|s| s.split_whitespace().take(3).map(String::from).collect())
        .unwrap_or_default()
}

/// (benutzt, gesamt) in Bytes, benutzt = MemTotal - MemAvailable.
pub fn mem() -> (u64, u64) {
    let info = read("/proc/meminfo").unwrap_or_default();
    let get = |k: &str| {
        info.lines()
            .find(|l| l.starts_with(k))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0)
            * 1024
    };
    let total = get("MemTotal:");
    (total.saturating_sub(get("MemAvailable:")), total)
}

pub fn reboot_required() -> Option<String> {
    if !std::path::Path::new("/var/run/reboot-required").exists() {
        return None;
    }
    Some(
        read("/var/run/reboot-required.pkgs")
            .map(|p| p.split_whitespace().collect::<Vec<_>>().join(" "))
            .unwrap_or_default(),
    )
}

/// (alle, Sicherheit) offene Updates und Stand der Zaehlung.
pub fn apt_counts() -> Option<(u64, u64, i64)> {
    let s = read(APT_CHECK)?;
    let mut it = s.trim().split(';');
    Some((
        it.next()?.parse().ok()?,
        it.next()?.parse().ok()?,
        mtime(APT_CHECK).unwrap_or(0),
    ))
}

pub fn uu_active() -> bool {
    run(
        "apt-config",
        &["dump", "APT::Periodic::Unattended-Upgrade"],
        5,
    )
    .map(|s| s.contains("\"1\""))
    .unwrap_or(false)
}

pub fn failed_units() -> Vec<Vec<String>> {
    run(
        "systemctl",
        &["list-units", "--state=failed", "--no-legend", "--plain"],
        10,
    )
    .unwrap_or_default()
    .lines()
    .filter(|l| !l.trim().is_empty())
    .map(|l| {
        let p: Vec<&str> = l.split_whitespace().collect();
        vec![
            p.first().unwrap_or(&"").to_string(),
            format!("{} {}", p.get(2).unwrap_or(&""), p.get(3).unwrap_or(&"")),
            p.get(4..).map(|r| r.join(" ")).unwrap_or_default(),
        ]
    })
    .collect()
}

/// Vorherige Anmeldung des Benutzers: (Zeit, Herkunft). sshd zeigt sie nicht mehr (PrintLastLog no).
pub fn last_login() -> Option<(String, String)> {
    let user = std::env::var("USER")
        .ok()
        .or_else(|| run("id", &["-un"], 3).map(|s| s.trim().to_string()))?;
    let out = run("last", &["--time-format", "iso", "-w", "-n", "2", &user], 5)?;
    let rows: Vec<Vec<&str>> = out
        .lines()
        .map(|l| l.split_whitespace().collect::<Vec<_>>())
        .filter(|f| f.len() >= 4 && f[0] != "wtmp")
        .collect();
    let f = rows.get(1)?;
    if f[2].len() > 4 && f[2].as_bytes()[..4].iter().all(u8::is_ascii_digit) && f[2].contains('-') {
        Some((f[2].to_string(), "lokal".into()))
    } else {
        Some((f[3].to_string(), f[2].to_string()))
    }
}

/// "heute 18:22", "gestern 09:10", "Fr 30.10. 18:22".
pub fn when_words(iso: &str) -> String {
    let day = run("date", &["-d", iso, "+%F"], 3).map(|s| s.trim().to_string());
    let today = run("date", &["+%F"], 3).map(|s| s.trim().to_string());
    let yesterday = run("date", &["-d", "yesterday", "+%F"], 3).map(|s| s.trim().to_string());
    let fmt = match (&day, &today, &yesterday) {
        (Some(d), Some(t), _) if d == t => "+heute %H:%M",
        (Some(d), _, Some(y)) if d == y => "+gestern %H:%M",
        (Some(_), _, _) => "+%a %d.%m. %H:%M",
        _ => return iso.to_string(),
    };
    run("date", &["-d", iso, fmt], 3)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| iso.to_string())
}

// ------------------------------------------------------------------ Platten

pub struct Disk {
    pub name: String,
    pub mount: String,
    pub kind: String,
    pub size_nb: String,
    pub used: u64,
    pub total: u64,
    pub pct: u64,
    pub mounted: bool,
}

fn mountpoints() -> Vec<(String, String)> {
    read("/proc/self/mounts")
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            Some((f.get(1)?.replace("\\040", " "), f.get(2)?.to_string()))
        })
        .collect()
}

/// (benutzt, gesamt, Prozent wie df: benutzt / (benutzt + verfuegbar), aufgerundet).
fn statvfs(path: &str) -> Option<(u64, u64, u64)> {
    let c = CString::new(path).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let f = st.f_frsize as u64;
    let total = st.f_blocks as u64 * f;
    let used = total.saturating_sub(st.f_bfree as u64 * f);
    let avail = st.f_bavail as u64 * f;
    let denom = used + avail;
    let pct = if denom == 0 {
        0
    } else {
        (used * 100).div_ceil(denom)
    };
    Some((used, total, pct))
}

/// Platten laut NetBox (/etc/tk/disks), sonst die echten Dateisysteme im Gast.
pub fn disks() -> Vec<Disk> {
    let mounts = mountpoints();
    let mounted: HashSet<&str> = mounts.iter().map(|(m, _)| m.as_str()).collect();
    let mut out = Vec::new();
    if let Some(tsv) = read(DISKS).filter(|s| !s.trim().is_empty()) {
        for line in tsv.lines().filter(|l| !l.trim().is_empty()) {
            let f: Vec<&str> = line.split('\t').collect();
            let (name, mount, kind, size) = (
                f.first().copied().unwrap_or("-"),
                f.get(1).copied().unwrap_or("-"),
                f.get(2).copied().unwrap_or("-"),
                f.get(3).copied().unwrap_or(""),
            );
            let mut d = Disk {
                name: name.into(),
                mount: mount.into(),
                kind: kind.into(),
                size_nb: format!("{size}G"),
                used: 0,
                total: 0,
                pct: 0,
                mounted: false,
            };
            if mount.starts_with('/') && mounted.contains(mount) {
                if let Some((u, t, p)) = statvfs(mount) {
                    (d.used, d.total, d.pct, d.mounted) = (u, t, p, true);
                }
            }
            out.push(d);
        }
        return out;
    }
    let real = ["ext2", "ext3", "ext4", "xfs", "btrfs", "zfs"];
    let mut seen = HashSet::new();
    for (m, fs) in &mounts {
        if !real.contains(&fs.as_str())
            || m.starts_with("/var/lib/docker")
            || m.starts_with("/snap")
            || m.starts_with("/boot")
            || !seen.insert(m.clone())
        {
            continue;
        }
        if let Some((u, t, p)) = statvfs(m) {
            out.push(Disk {
                name: "-".into(),
                mount: m.clone(),
                kind: "-".into(),
                size_nb: "-".into(),
                used: u,
                total: t,
                pct: p,
                mounted: true,
            });
        }
    }
    out
}

// ------------------------------------------------------------------ Docker

pub struct Container {
    pub name: String,
    pub state: String,
    pub health: String,
    pub exit: i64,
    pub image: String,
    pub version: String,
    pub started: Option<i64>,
    pub finished: Option<i64>,
    pub restarts: i64,
    pub running: bool,
    pub project: String,
    pub workdir: String,
}

pub fn docker_ok() -> bool {
    which("docker") && run("docker", &["info", "--format", "{{.ServerVersion}}"], 4).is_some()
}

pub fn which(cmd: &str) -> bool {
    std::env::var("PATH")
        .unwrap_or_else(|_| "/usr/local/bin:/usr/bin:/bin".into())
        .split(':')
        .chain(["/usr/local/sbin", "/usr/sbin", "/sbin"])
        .any(|d| std::path::Path::new(d).join(cmd).is_file())
}

/// Alle Container per `docker inspect`. None, wenn Docker fehlt oder nicht antwortet.
pub fn containers() -> Option<Vec<Container>> {
    if !which("docker") {
        return None;
    }
    let ids = run("docker", &["ps", "-aq"], 4)?;
    let ids: Vec<&str> = ids.split_whitespace().collect();
    if ids.is_empty() {
        return Some(Vec::new());
    }
    let mut args = vec!["inspect"];
    args.extend(ids.iter());
    let json: Value = serde_json::from_str(&run("docker", &args, 8)?).ok()?;
    let s = |v: &Value| v.as_str().unwrap_or("").to_string();
    Some(
        json.as_array()?
            .iter()
            .map(|c| {
                let st = &c["State"];
                let labels = &c["Config"]["Labels"];
                Container {
                    name: s(&c["Name"]).trim_start_matches('/').to_string(),
                    state: s(&st["Status"]),
                    health: st["Health"]["Status"].as_str().unwrap_or("-").to_string(),
                    exit: st["ExitCode"].as_i64().unwrap_or(0),
                    image: s(&c["Config"]["Image"]),
                    version: labels["org.opencontainers.image.version"]
                        .as_str()
                        .unwrap_or("-")
                        .to_string(),
                    started: parse_rfc3339(st["StartedAt"].as_str().unwrap_or("")),
                    finished: parse_rfc3339(st["FinishedAt"].as_str().unwrap_or("")),
                    restarts: c["RestartCount"].as_i64().unwrap_or(0),
                    running: st["Running"].as_bool().unwrap_or(false),
                    project: labels["com.docker.compose.project"]
                        .as_str()
                        .unwrap_or("")
                        .to_string(),
                    workdir: labels["com.docker.compose.project.working_dir"]
                        .as_str()
                        .unwrap_or("")
                        .to_string(),
                }
            })
            .collect(),
    )
}

// ------------------------------------------------------------------ Warnungen

/// Eine Zeile je Problem. Leer, wenn alles stimmt. Gleiche Regeln in MOTD und tk doctor.
pub fn problems(ctrs: &Option<Vec<Container>>, disks: &[Disk]) -> Vec<String> {
    let mut out = Vec::new();
    if reboot_required().is_some() {
        out.push("Neustart nötig".into());
    }
    if let Some((_, sec, _)) = apt_counts() {
        if sec > 0 {
            out.push(format!("{sec} Sicherheitsupdates offen"));
        }
    }
    let failed = failed_units().len();
    if failed > 0 {
        out.push(format!("{failed} Units fehlgeschlagen (tk status)"));
    }
    for d in disks {
        if !d.mounted && d.mount.starts_with('/') {
            out.push(format!("{} ({}) nicht eingehängt", d.mount, d.name));
        } else if d.mounted && d.pct >= DISK_WARN {
            out.push(format!("{} zu {} % voll", d.mount, d.pct));
        }
    }
    for c in ctrs.iter().flatten() {
        if c.health == "unhealthy" {
            out.push(format!("{} ungesund", c.name));
        } else if c.state == "restarting" {
            out.push(format!("{} startet ständig neu", c.name));
        } else if c.state == "exited" && c.exit != 0 {
            let ago = c
                .finished
                .map(|f| format!(", seit {}", crate::ui::since_secs(now() - f)))
                .unwrap_or_default();
            out.push(format!("{} beendet: Code {}{ago}", c.name, c.exit));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc3339() {
        assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_rfc3339("2026-10-21T17:21:19.2560354Z"),
            Some(1_792_603_279)
        );
        assert_eq!(
            parse_rfc3339("2026-10-21T18:21:19+01:00"),
            Some(1_792_603_279)
        );
        assert_eq!(parse_rfc3339("0001-01-01T00:00:00Z"), None);
    }

    #[test]
    fn run_with_timeout() {
        assert_eq!(run("echo", &["hallo"], 2).as_deref(), Some("hallo\n"));
        assert!(run("sleep", &["5"], 1).is_none());
        assert!(run("false", &[], 2).is_none());
    }
}
