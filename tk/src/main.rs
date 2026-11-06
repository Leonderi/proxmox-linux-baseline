//! tk – Werkzeugkasten und MOTD der tk-thran-Gaeste (proxmox-linux-baseline).
//!
//! Ein statisches Binary ohne Laufzeit-Abhaengigkeiten. Gebaut im Image rust:alpine (musl),
//! verteilt von der Ansible-Rolle baseline nach /usr/local/bin/tk.

mod cmds;
mod motd;
mod sys;
mod ui;

use std::io::Write;

fn main() {
    // Bei `tk … | head` still beenden statt mit "Broken pipe" abzubrechen
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("help");
    let rest = if args.is_empty() { &[][..] } else { &args[1..] };
    match cmd {
        "help" | "-h" | "--help" => cmds::help(),
        "ps" => cmds::ps(),
        "status" => cmds::status(),
        "logs" => cmds::logs(rest),
        "stacks" => cmds::stacks(),
        "updates" => cmds::updates(),
        "net" => cmds::net(),
        "doctor" => cmds::doctor(),
        "info" => cmds::info(),
        "table" => cmds::tsv_table(rest),
        "motd" => {
            let p = ui::Pal::detect();
            let mut out = std::io::stdout().lock();
            let _ = out.write_all(motd::render(&p).as_bytes());
        }
        "version" | "--version" => println!(
            "tk {} ({})",
            env!("CARGO_PKG_VERSION"),
            option_env!("TK_COMMIT").unwrap_or("lokal")
        ),
        other => {
            eprintln!("tk: unbekannter Befehl '{other}'");
            cmds::help();
            std::process::exit(2);
        }
    }
}
