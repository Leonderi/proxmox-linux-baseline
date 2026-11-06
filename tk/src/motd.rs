//! MOTD: Kopf aus /etc/tk/motd-head (Banner und Steckbrief aus NetBox), Systemzustand, Warnblock.

use crate::sys::{self, Disk};
use crate::ui::{self, Pal};

const BAR: usize = 16;

fn label(p: &Pal, l: &str) -> String {
    format!("  {}{l:<8}{} ", p.lilac, p.reset)
}

/// Kopf mit Farb-Platzhaltern: @P@ Lila, @L@ Label, @V@ Wert, @T@ Text, @D@ gedimmt, @R@ zurueck.
pub fn head(p: &Pal) -> String {
    match sys::read(sys::MOTD_HEAD) {
        Some(h) => h
            .replace("@P@", &p.purple)
            .replace("@L@", &p.lilac)
            .replace("@V@", &p.value)
            .replace("@T@", &p.text)
            .replace("@D@", &p.dim)
            .replace("@R@", &p.reset),
        None => {
            let host = sys::read("/etc/hostname").unwrap_or_default();
            format!("  {}{}{}\n", p.value, host.trim(), p.reset)
        }
    }
}

fn disk_lines(p: &Pal, disks: &[Disk]) -> Vec<String> {
    let (used, total) = sys::mem();
    let mem_pct = (used * 100).checked_div(total).unwrap_or(0);
    let ut = |d: &Disk| {
        if d.mounted {
            format!("{}/{}", ui::human(d.used), ui::human(d.total))
        } else {
            "-/-".into()
        }
    };
    let w1 = disks.iter().map(|d| ui::width(&d.name)).max().unwrap_or(0);
    let w2 = disks.iter().map(|d| ui::width(&d.mount)).max().unwrap_or(0);
    let w3 = disks.iter().map(|d| ui::width(&d.kind)).max().unwrap_or(0);
    let w4 = disks
        .iter()
        .map(|d| ui::width(&ut(d)))
        .max()
        .unwrap_or(0)
        .max(9);
    let prefix = (w1 + w2 + w3 + 4).max(15);

    let mut out = vec![format!(
        "{}{}{:<prefix$}{}  {:>w4$}  {} {mem_pct:>3} %",
        label(p, "RAM"),
        p.dim,
        "Arbeitsspeicher",
        p.reset,
        format!("{}/{}", ui::human(used), ui::human(total)),
        ui::bar(mem_pct, BAR, p)
    )];
    for (i, d) in disks.iter().enumerate() {
        let lead = if i == 0 {
            label(p, "Platten")
        } else {
            format!("  {:<8} ", "")
        };
        let cols = format!(
            "{:<w1$}  {:<w2$}  {}{:<w3$}{}  ",
            d.name,
            d.mount,
            p.dim,
            d.kind,
            p.reset,
            w1 = w1,
            w2 = w2,
            w3 = w3
        );
        let tail = if d.mounted {
            format!("{:>w4$}  {} {:>3} %", ut(d), ui::bar(d.pct, BAR, p), d.pct)
        } else {
            format!("{:>w4$}  {}nicht eingehängt{}", d.size_nb, p.bad, p.reset)
        };
        out.push(format!("{lead}{cols}{tail}"));
    }
    out
}

pub fn render(p: &Pal) -> String {
    let mut out = String::from("\n");
    out.push_str(&head(p));

    let load = if sys::is_lxc() {
        String::new()
    } else {
        format!(
            " {}·{} Load {}",
            p.dim,
            p.reset,
            sys::loadavg().first().cloned().unwrap_or_default()
        )
    };
    out.push_str(&format!(
        "\n{}{} {}·{} up {}{load}\n",
        label(p, "System"),
        sys::distro(),
        p.dim,
        p.reset,
        sys::uptime_words()
    ));
    if let Some((when, from)) = sys::last_login() {
        out.push_str(&format!(
            "{}zuletzt {} von {}\n",
            label(p, "Login"),
            sys::when_words(&when),
            from
        ));
    }

    let disks = sys::disks();
    for l in disk_lines(p, &disks) {
        out.push_str(&l);
        out.push('\n');
    }

    let ctrs = sys::containers();
    match &ctrs {
        Some(list) if !list.is_empty() => {
            let total = list.len();
            let running = list.iter().filter(|c| c.running).count();
            let sick = list.iter().filter(|c| c.health == "unhealthy").count();
            let clean = list
                .iter()
                .all(|c| c.running || (c.state == "exited" && c.exit == 0));
            if sick == 0 && clean {
                let note = if running == total {
                    "alle gesund".to_string()
                } else {
                    format!("{} sauber beendet", total - running)
                };
                out.push_str(&format!(
                    "{}{}{running}/{total} laufen, {note}{}\n",
                    label(p, "Docker"),
                    p.good,
                    p.reset
                ));
            } else {
                out.push_str(&format!(
                    "{}{}{running}/{total} laufen, {sick} ungesund{} {}(tk ps){}\n",
                    label(p, "Docker"),
                    p.warn,
                    p.reset,
                    p.dim,
                    p.reset
                ));
            }
        }
        None if sys::which("docker") => {
            out.push_str(&format!(
                "{}{}kein Zugriff (Gruppe docker, neu anmelden){}\n",
                label(p, "Docker"),
                p.dim,
                p.reset
            ));
        }
        _ => {}
    }

    let probs = sys::problems(&ctrs, &disks);
    if !probs.is_empty() {
        out.push_str(&format!(
            "\n  {}⚠ {}{}\n",
            p.warn,
            probs.join(" · "),
            p.reset
        ));
    }
    out.push('\n');
    out
}
