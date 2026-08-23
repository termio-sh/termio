//! CPU cost of parsing a payload into the grid — the half of the daemon's bill
//! that a shared-memory transport cannot touch.
//!
//! Run: cargo run --release -p termiod-vt --example parse_cost -- <file> [rows] [cols]

use std::time::Instant;

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("usage: parse_cost <payload> [rows] [cols]");
    let rows: u16 = args.next().and_then(|v| v.parse().ok()).unwrap_or(50);
    let cols: u16 = args.next().and_then(|v| v.parse().ok()).unwrap_or(200);

    let bytes = std::fs::read(&path).expect("read payload");
    let mut terminal = termiod_vt::VtTerminal::new(rows, cols).expect("VtTerminal::new");

    // Feed in 64 KiB chunks, the shape the sidecar actually sees.
    let start = Instant::now();
    for chunk in bytes.chunks(65536) {
        terminal.vt_write(chunk);
    }
    let elapsed = start.elapsed();

    let mb = bytes.len() as f64 / 1048576.0;
    println!(
        "{:>6.1} MB  {:>7.3} s  {:>8.1} MB/s  {:>7.3} s per 100 MB",
        mb,
        elapsed.as_secs_f64(),
        mb / elapsed.as_secs_f64(),
        elapsed.as_secs_f64() / mb * 100.0
    );
}
