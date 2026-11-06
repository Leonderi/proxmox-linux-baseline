//! Farben, Tabellen im Stil von cscli, Balken und Zahlenformat.

use std::io::IsTerminal;
use unicode_width::UnicodeWidthStr;

/// Farbpalette. Leer, wenn die Ausgabe kein Terminal ist, NO_COLOR gesetzt ist oder TERM=dumb.
#[derive(Clone)]
pub struct Pal {
    pub purple: String, // Firmen-Lila #9040D0, fett
    pub frame: String,  // Firmen-Lila fuer Rahmen
    pub lilac: String,  // helles Lila fuer Beschriftungen
    pub value: String,
    pub text: String,
    pub dim: String,
    pub good: String,
    pub warn: String,
    pub bad: String,
    pub bold: String,
    pub reset: String,
}

fn rgb(r: u8, g: u8, b: u8, fallback: u8) -> String {
    if std::env::var("TERM").map(|t| t == "linux").unwrap_or(false) {
        format!("\x1b[38;5;{fallback}m")
    } else {
        format!("\x1b[38;2;{r};{g};{b}m")
    }
}

impl Pal {
    pub fn detect() -> Pal {
        let term = std::env::var("TERM").unwrap_or_else(|_| "dumb".into());
        let on = std::io::stdout().is_terminal()
            && std::env::var_os("NO_COLOR").is_none()
            && term != "dumb";
        if on {
            Pal::colored()
        } else {
            Pal::plain()
        }
    }

    pub fn colored() -> Pal {
        Pal {
            purple: format!("\x1b[1m{}", rgb(0x90, 0x40, 0xD0, 98)),
            frame: rgb(0x90, 0x40, 0xD0, 98),
            lilac: rgb(0xC9, 0xA6, 0xEC, 183),
            value: "\x1b[1;97m".into(),
            text: "\x1b[38;5;250m".into(),
            dim: "\x1b[0;90m".into(),
            good: rgb(0x7C, 0xC4, 0x7F, 114),
            warn: rgb(0xE5, 0xC0, 0x7B, 180),
            bad: rgb(0xE0, 0x6C, 0x75, 174),
            bold: "\x1b[1m".into(),
            reset: "\x1b[0m".into(),
        }
    }

    pub fn plain() -> Pal {
        let e = String::new();
        Pal {
            purple: e.clone(),
            frame: e.clone(),
            lilac: e.clone(),
            value: e.clone(),
            text: e.clone(),
            dim: e.clone(),
            good: e.clone(),
            warn: e.clone(),
            bad: e.clone(),
            bold: e.clone(),
            reset: e,
        }
    }

    pub fn is_plain(&self) -> bool {
        self.reset.is_empty()
    }
}

/// ANSI-Farbcodes entfernen.
pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' && chars.peek() == Some(&'[') {
            chars.next();
            for n in chars.by_ref() {
                if n.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Sichtbare Breite in Terminalspalten.
pub fn width(s: &str) -> usize {
    UnicodeWidthStr::width(strip_ansi(s).as_str())
}

const GOOD: &[&str] = &[
    "running",
    "healthy",
    "ok",
    "✓",
    "aktiv",
    "ja",
    "up",
    "läuft",
    "gesund",
    "nicht nötig",
];
const BAD: &[&str] = &[
    "exited",
    "unhealthy",
    "failed",
    "✗",
    "dead",
    "fehlt",
    "nein",
];
const WARN: &[&str] = &[
    "starting",
    "restarting",
    "⚠",
    "paused",
    "created",
    "nötig",
    "offen",
];

/// Bekannte Zustandswoerter einfaerben.
pub fn paint(cell: &str, p: &Pal) -> String {
    if p.is_plain() || cell.contains('\x1b') {
        return cell.to_string();
    }
    let key = cell.trim().to_lowercase();
    let first = key.split(' ').next().unwrap_or("");
    let hit = |list: &[&str]| list.iter().any(|w| *w == key || *w == first);
    if hit(GOOD) {
        format!("{}{}{}", p.good, cell, p.reset)
    } else if hit(BAD) {
        format!("{}{}{}", p.bad, cell, p.reset)
    } else if hit(WARN) {
        format!("{}{}{}", p.warn, cell, p.reset)
    } else if key.is_empty() || key == "-" || key == "–" {
        format!("{}{}{}", p.dim, cell, p.reset)
    } else {
        cell.to_string()
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Align {
    Left,
    Right,
    Center,
}

fn pad(cell: &str, w: usize, align: Align) -> String {
    let gap = w.saturating_sub(width(cell));
    match align {
        Align::Left => format!("{cell}{}", " ".repeat(gap)),
        Align::Right => format!("{}{cell}", " ".repeat(gap)),
        Align::Center => format!("{}{cell}{}", " ".repeat(gap / 2), " ".repeat(gap - gap / 2)),
    }
}

/// Auf w Spalten kuerzen, mit "…". Farben gehen dabei verloren.
pub fn cut(cell: &str, w: usize) -> String {
    let plain = strip_ansi(cell);
    if width(&plain) <= w {
        return cell.to_string();
    }
    let mut out = String::new();
    for ch in plain.chars() {
        let mut next = out.clone();
        next.push(ch);
        if width(&next) + 1 > w {
            break;
        }
        out = next;
    }
    out.push('…');
    out
}

/// Terminalbreite (TIOCGWINSZ, sonst COLUMNS, sonst 160).
pub fn term_width() -> usize {
    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) == 0 && ws.ws_col > 0 {
            return ws.ws_col as usize;
        }
    }
    std::env::var("COLUMNS")
        .ok()
        .and_then(|c| c.parse().ok())
        .unwrap_or(160)
}

/// Rahmentabelle als Text.
pub fn render_table(
    head: &[&str],
    rows: &[Vec<String>],
    title: Option<&str>,
    align: &[Align],
    max: usize,
    p: &Pal,
) -> String {
    let cols = head.len();
    let mut rows: Vec<Vec<String>> = rows
        .iter()
        .map(|r| {
            (0..cols)
                .map(|i| paint(r.get(i).map(String::as_str).unwrap_or(""), p))
                .collect()
        })
        .collect();
    let al = |i: usize| align.get(i).copied().unwrap_or(Align::Left);
    let mut widths: Vec<usize> = (0..cols)
        .map(|i| {
            rows.iter()
                .map(|r| width(&r[i]))
                .chain(std::iter::once(width(head[i])))
                .max()
                .unwrap_or(0)
        })
        .collect();
    // zu breit: die breiteste Spalte kuerzen
    while widths.iter().sum::<usize>() + 3 * cols + 1 > max
        && *widths.iter().max().unwrap_or(&0) > 12
    {
        let i = widths
            .iter()
            .enumerate()
            .max_by_key(|(_, w)| **w)
            .map(|(i, _)| i)
            .unwrap_or(0);
        widths[i] -= 1;
        for r in rows.iter_mut() {
            r[i] = cut(&r[i], widths[i]);
        }
    }
    let line = |l: &str, m: &str, r: &str| {
        let inner: Vec<String> = widths.iter().map(|w| "─".repeat(w + 2)).collect();
        format!("{}{}{}{}{}", p.frame, l, inner.join(m), r, p.reset)
    };
    let bar = format!("{}│{}", p.frame, p.reset);
    let mut out = Vec::new();
    if let Some(t) = title {
        out.push(format!("{}{}{}", p.purple, t, p.reset));
    }
    out.push(line("╭", "┬", "╮"));
    let hcells: Vec<String> = head
        .iter()
        .enumerate()
        .map(|(i, h)| {
            format!(
                " {}{}{}{} ",
                p.bold,
                p.lilac,
                pad(h, widths[i], Align::Center),
                p.reset
            )
        })
        .collect();
    out.push(format!("{bar}{}{bar}", hcells.join(&bar)));
    out.push(line("├", "┼", "┤"));
    if rows.is_empty() {
        let inner = widths.iter().sum::<usize>() + 3 * cols - 1;
        out.push(format!(
            "{bar} {}{}{} {bar}",
            p.dim,
            pad("keine Einträge", inner - 2, Align::Left),
            p.reset
        ));
    }
    for r in &rows {
        let cells: Vec<String> = r
            .iter()
            .enumerate()
            .map(|(i, c)| format!(" {} ", pad(c, widths[i], al(i))))
            .collect();
        out.push(format!("{bar}{}{bar}", cells.join(&bar)));
    }
    out.push(line("╰", "┴", "╯"));
    out.join("\n")
}

pub fn table(head: &[&str], rows: &[Vec<String>], title: Option<&str>, align: &[Align]) {
    let p = Pal::detect();
    println!(
        "{}",
        render_table(head, rows, title, align, term_width(), &p)
    );
}

pub fn mark(ok: bool, warn_only: bool) -> String {
    if ok {
        "✓".into()
    } else if warn_only {
        "⚠".into()
    } else {
        "✗".into()
    }
}

/// Belegungsbalken: Lila bis 74 %, gelb ab 75 %, rot ab 90 %.
pub fn bar(pct: u64, width: usize, p: &Pal) -> String {
    let fill = (((pct as usize) * width + 50) / 100).min(width);
    let col = if pct >= 90 {
        &p.bad
    } else if pct >= 75 {
        &p.warn
    } else {
        &p.purple
    };
    format!(
        "{col}{}{}{}{}",
        "█".repeat(fill),
        p.dim,
        "░".repeat(width - fill),
        p.reset
    )
}

/// Groesse wie `numfmt --to=iec` mit deutschem Komma: 1,9G, 512M, 14G.
pub fn human(bytes: u64) -> String {
    let units = ["", "K", "M", "G", "T", "P"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1024.0 && i < units.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        return format!("{bytes}");
    }
    if v < 10.0 {
        let r = (v * 10.0).ceil() / 10.0;
        if r < 10.0 {
            return format!("{}{}", format!("{r:.1}").replace('.', ","), units[i]);
        }
    }
    format!("{}{}", v.ceil() as u64, units[i])
}

/// Dauer in Worten: "3 Tage", "1 Woche", "5 Min".
pub fn since_secs(s: i64) -> String {
    if s < 0 {
        return "-".into();
    }
    let steps: [(i64, &str, &str); 6] = [
        (31_536_000, "Jahr", "Jahre"),
        (2_592_000, "Monat", "Monate"),
        (604_800, "Woche", "Wochen"),
        (86_400, "Tag", "Tage"),
        (3_600, "Std", "Std"),
        (60, "Min", "Min"),
    ];
    for (size, one, many) in steps {
        if s >= size {
            let n = s / size;
            return format!("{n} {}", if n == 1 { one } else { many });
        }
    }
    format!("{s} Sek")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn human_like_numfmt() {
        assert_eq!(human(0), "0");
        assert_eq!(human(1_900_000_000), "1,8G");
        assert_eq!(human(512 * 1024 * 1024), "512M");
        assert_eq!(human(15 * 1024 * 1024 * 1024), "15G");
    }

    #[test]
    fn width_ignores_ansi_and_counts_umlauts() {
        assert_eq!(width("\x1b[1mÄrger\x1b[0m"), 5);
        assert_eq!(width("✓"), 1);
    }

    #[test]
    fn table_fits_and_cuts() {
        let rows = vec![vec!["caddy".to_string(), "x".repeat(200)]];
        let t = render_table(
            &["Name", "Beschreibung"],
            &rows,
            None,
            &[],
            60,
            &Pal::plain(),
        );
        assert!(t.lines().all(|l| width(l) <= 60), "{t}");
        assert!(t.contains('…'));
    }

    #[test]
    fn since_words() {
        assert_eq!(since_secs(30), "30 Sek");
        assert_eq!(since_secs(86_400 * 3), "3 Tage");
        assert_eq!(since_secs(604_800), "1 Woche");
    }

    #[test]
    fn bar_width() {
        assert_eq!(width(&bar(50, 16, &Pal::plain())), 16);
        assert_eq!(width(&bar(100, 16, &Pal::colored())), 16);
    }
}
