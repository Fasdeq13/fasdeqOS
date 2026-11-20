use std::collections::HashSet;
use std::fs;
use std::sync::OnceLock;

static COV: OnceLock<Option<HashSet<u32>>> = OnceLock::new();
static VT: OnceLock<bool> = OnceLock::new();

const STOCK: &str = "│─┌┐└┘╔╗╚╝═║█▀▄░▒▓■▌▐►◄▲▼√·•↑↓←→";

fn parse(d: &[u8]) -> Option<HashSet<u32>> {
    if d.len() < 4 || d[0] != 0x36 || d[1] != 0x04 {
        return None;
    }
    let n = if d[2] & 1 == 1 { 512 } else { 256 };
    let cs = d[3] as usize;
    let mut set = HashSet::new();
    if d[2] & 6 == 0 {
        return Some(set);
    }
    let mut pos = 4 + n * cs;
    let mut g = 0;
    while g < n && pos + 1 < d.len() {
        let mut combining = false;
        while pos + 1 < d.len() {
            let v = d[pos] as u32 | (d[pos + 1] as u32) << 8;
            pos += 2;
            if v == 0xFFFF {
                break;
            }
            if v == 0xFFFE {
                combining = true;
                continue;
            }
            if !combining {
                set.insert(v);
            }
        }
        g += 1;
    }
    Some(set)
}

pub fn init(vt: bool) {
    let _ = VT.set(vt);
    let path = std::env::var("FASDEQ_FONT").unwrap_or_else(|_| "/System/share/consolefonts/Uni2-Terminus16.psf".to_string());
    let cov = if vt { fs::read(path).ok().and_then(|d| parse(&d)) } else { None };
    let _ = COV.set(cov);
}

pub fn covered(c: char) -> bool {
    if !*VT.get().unwrap_or(&false) || c.is_ascii() {
        return true;
    }
    match COV.get().and_then(|x| x.as_ref()) {
        Some(set) => set.contains(&(c as u32)),
        None => STOCK.contains(c),
    }
}

pub fn all_covered(s: &str) -> bool {
    s.chars().all(covered)
}
