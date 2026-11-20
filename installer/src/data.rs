use std::fs;
use std::path::Path;

#[derive(Clone)]
pub struct Disk {
    pub name: String,
    pub size: u64,
    pub model: String,
    pub tran: String,
    pub removable: bool,
}

pub struct Desktop {
    pub name: String,
    pub title: String,
    pub blurb: String,
}

fn read_trim(p: &str) -> String {
    fs::read_to_string(p).map(|s| s.trim().to_string()).unwrap_or_default()
}

fn base_disk(dev: &str) -> String {
    let n = dev.trim_start_matches("/dev/");
    if n.starts_with("nvme") || n.starts_with("mmcblk") {
        if let Some(i) = n.rfind('p') {
            if n[i + 1..].chars().all(|c| c.is_ascii_digit()) && i + 1 < n.len() {
                return n[..i].to_string();
            }
        }
        return n.to_string();
    }
    n.trim_end_matches(|c: char| c.is_ascii_digit()).to_string()
}

fn boot_disk() -> Option<String> {
    let m = fs::read_to_string("/proc/mounts").ok()?;
    for l in m.lines() {
        let mut it = l.split_whitespace();
        let src = it.next()?;
        let mp = it.next()?;
        if mp == "/System/Volumes/Boot" && src.starts_with("/dev/") {
            return Some(base_disk(src));
        }
    }
    None
}

pub fn disks(demo: bool) -> Vec<Disk> {
    let mut out = Vec::new();
    let boot = boot_disk();
    if let Ok(rd) = fs::read_dir("/sys/block") {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let skip = ["loop", "ram", "zram", "sr", "dm-", "md", "nbd", "fd"];
            if skip.iter().any(|p| name.starts_with(p)) {
                continue;
            }
            if boot.as_deref() == Some(name.as_str()) {
                continue;
            }
            let base = format!("/sys/block/{}", name);
            let sectors: u64 = read_trim(&format!("{}/size", base)).parse().unwrap_or(0);
            let size = sectors * 512;
            if size < 6 * 1024 * 1024 * 1024 {
                continue;
            }
            let mut model = read_trim(&format!("{}/device/model", base));
            if model.is_empty() {
                model = match name.as_str() {
                    n if n.starts_with("vd") => "Virtual disk".to_string(),
                    n if n.starts_with("nvme") => read_trim(&format!("{}/device/model", base)),
                    _ => String::new(),
                };
            }
            let link = fs::read_link(&base).map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
            let tran = if name.starts_with("nvme") {
                "NVMe"
            } else if link.contains("usb") {
                "USB"
            } else if link.contains("virtio") {
                "VirtIO"
            } else if name.starts_with("mmcblk") {
                "SD/MMC"
            } else {
                "SATA"
            };
            let removable = read_trim(&format!("{}/removable", base)) == "1";
            out.push(Disk { name, size, model, tran: tran.to_string(), removable });
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    if out.is_empty() && demo {
        out.push(Disk { name: "nvme0n1".into(), size: 1_000_204_886_016, model: "Samsung SSD 990 PRO 1TB".into(), tran: "NVMe".into(), removable: false });
        out.push(Disk { name: "sda".into(), size: 500_107_862_016, model: "Crucial MX500".into(), tran: "SATA".into(), removable: false });
        out.push(Disk { name: "sdb".into(), size: 64_023_257_088, model: "SanDisk Ultra".into(), tran: "USB".into(), removable: true });
    }
    out
}

pub const LOCALES: &[(&str, &str, &str)] = &[
    ("en_US.UTF-8", "English (United States)", "English (United States)"),
    ("en_GB.UTF-8", "English (United Kingdom)", "English (United Kingdom)"),
    ("ru_RU.UTF-8", "Русский (Россия)", "Russian (Russia)"),
    ("uk_UA.UTF-8", "Українська (Україна)", "Ukrainian (Ukraine)"),
    ("be_BY.UTF-8", "Беларуская (Беларусь)", "Belarusian (Belarus)"),
    ("kk_KZ.UTF-8", "Қазақша (Қазақстан)", "Kazakh (Kazakhstan)"),
    ("de_DE.UTF-8", "Deutsch (Deutschland)", "German (Germany)"),
    ("fr_FR.UTF-8", "Français (France)", "French (France)"),
    ("es_ES.UTF-8", "Español (España)", "Spanish (Spain)"),
    ("es_MX.UTF-8", "Español (México)", "Spanish (Mexico)"),
    ("it_IT.UTF-8", "Italiano (Italia)", "Italian (Italy)"),
    ("pt_BR.UTF-8", "Português (Brasil)", "Portuguese (Brazil)"),
    ("pt_PT.UTF-8", "Português (Portugal)", "Portuguese (Portugal)"),
    ("nl_NL.UTF-8", "Nederlands (Nederland)", "Dutch (Netherlands)"),
    ("pl_PL.UTF-8", "Polski (Polska)", "Polish (Poland)"),
    ("cs_CZ.UTF-8", "Čeština (Česko)", "Czech (Czechia)"),
    ("sk_SK.UTF-8", "Slovenčina (Slovensko)", "Slovak (Slovakia)"),
    ("hu_HU.UTF-8", "Magyar (Magyarország)", "Hungarian (Hungary)"),
    ("ro_RO.UTF-8", "Română (România)", "Romanian (Romania)"),
    ("bg_BG.UTF-8", "Български (България)", "Bulgarian (Bulgaria)"),
    ("el_GR.UTF-8", "Ελληνικά (Ελλάδα)", "Greek (Greece)"),
    ("tr_TR.UTF-8", "Türkçe (Türkiye)", "Turkish (Turkey)"),
    ("sv_SE.UTF-8", "Svenska (Sverige)", "Swedish (Sweden)"),
    ("nb_NO.UTF-8", "Norsk bokmål (Norge)", "Norwegian Bokmal (Norway)"),
    ("da_DK.UTF-8", "Dansk (Danmark)", "Danish (Denmark)"),
    ("fi_FI.UTF-8", "Suomi (Suomi)", "Finnish (Finland)"),
    ("he_IL.UTF-8", "עברית (ישראל)", "Hebrew (Israel)"),
    ("ar_SA.UTF-8", "العربية (السعودية)", "Arabic (Saudi Arabia)"),
    ("hi_IN.UTF-8", "हिन्दी (भारत)", "Hindi (India)"),
    ("th_TH.UTF-8", "ไทย (ประเทศไทย)", "Thai (Thailand)"),
    ("vi_VN.UTF-8", "Tiếng Việt (Việt Nam)", "Vietnamese (Vietnam)"),
    ("id_ID.UTF-8", "Bahasa Indonesia", "Indonesian (Indonesia)"),
    ("zh_CN.UTF-8", "简体中文 (中国)", "Chinese Simplified (China)"),
    ("zh_TW.UTF-8", "繁體中文 (台灣)", "Chinese Traditional (Taiwan)"),
    ("ja_JP.UTF-8", "日本語 (日本)", "Japanese (Japan)"),
    ("ko_KR.UTF-8", "한국어 (대한민국)", "Korean (South Korea)"),
    ("C.UTF-8", "C (POSIX, UTF-8)", "C (POSIX, UTF-8)"),
];

const FALLBACK_TZ: &[&str] = &[
    "UTC", "Europe/Moscow", "Europe/Kaliningrad", "Europe/Samara", "Asia/Yekaterinburg", "Asia/Omsk",
    "Asia/Novosibirsk", "Asia/Krasnoyarsk", "Asia/Irkutsk", "Asia/Yakutsk", "Asia/Vladivostok",
    "Asia/Magadan", "Asia/Kamchatka", "Europe/Kyiv", "Europe/Minsk", "Europe/London", "Europe/Berlin",
    "Europe/Paris", "Europe/Madrid", "Europe/Rome", "Europe/Warsaw", "Europe/Istanbul", "Asia/Almaty",
    "Asia/Tbilisi", "Asia/Yerevan", "Asia/Dubai", "Asia/Kolkata", "Asia/Bangkok", "Asia/Shanghai",
    "Asia/Tokyo", "Asia/Seoul", "Australia/Sydney", "Pacific/Auckland", "America/New_York",
    "America/Chicago", "America/Denver", "America/Los_Angeles", "America/Sao_Paulo", "Africa/Cairo",
];

fn walk(root: &Path, rel: &str, out: &mut Vec<String>) {
    let dir = if rel.is_empty() { root.to_path_buf() } else { root.join(rel) };
    let Ok(rd) = fs::read_dir(&dir) else { return };
    for e in rd.flatten() {
        let n = e.file_name().to_string_lossy().to_string();
        let r = if rel.is_empty() { n.clone() } else { format!("{}/{}", rel, n) };
        let Ok(ft) = e.file_type() else { continue };
        if ft.is_dir() {
            if rel.is_empty() && !["Africa", "America", "Antarctica", "Arctic", "Asia", "Atlantic", "Australia", "Europe", "Indian", "Pacific"].contains(&n.as_str()) {
                continue;
            }
            walk(root, &r, out);
        } else if rel.contains('/') || ["Africa", "America", "Antarctica", "Arctic", "Asia", "Atlantic", "Australia", "Europe", "Indian", "Pacific"].iter().any(|p| rel.starts_with(p)) {
            if n.chars().next().map(|c| c.is_ascii_uppercase()).unwrap_or(false) {
                out.push(r);
            }
        }
    }
}

pub fn timezones() -> Vec<String> {
    let mut v = Vec::new();
    for root in ["/System/share/zoneinfo", "/usr/share/zoneinfo"] {
        let p = Path::new(root);
        if p.is_dir() {
            walk(p, "", &mut v);
            if !v.is_empty() {
                break;
            }
        }
    }
    if v.is_empty() {
        v = FALLBACK_TZ.iter().map(|s| s.to_string()).collect();
    } else {
        v.push("UTC".to_string());
    }
    v.sort();
    v.dedup();
    v
}

fn json_field(s: &str, key: &str) -> Option<String> {
    let pat = format!("\"{}\"", key);
    let i = s.find(&pat)? + pat.len();
    let rest = &s[i..];
    let c = rest.find(':')?;
    let rest = rest[c + 1..].trim_start();
    let rest = rest.strip_prefix('"')?;
    let e = rest.find('"')?;
    Some(rest[..e].to_string())
}

fn blurb(name: &str) -> &'static str {
    match name {
        "kde" => "Plasma 6: familiar, powerful, polished",
        "xfce" => "Light and fast, traditional panel",
        "cinnamon" => "Classic desktop, easy transition",
        "hyprland" => "Tiling Wayland compositor with animations",
        "niri" => "Scrollable-tiling Wayland compositor",
        "cosmic" => "Pop!_OS desktop written in Rust",
        _ => "Custom desktop definition",
    }
}

pub fn desktops() -> Vec<Desktop> {
    let mut v = Vec::new();
    for root in ["/System/etc/desktops.d", "/home/claude/fasdeqos-v2/extra/System/etc/desktops.d"] {
        if let Ok(rd) = fs::read_dir(root) {
            for e in rd.flatten() {
                let p = e.path();
                if p.extension().map(|x| x != "json").unwrap_or(true) {
                    continue;
                }
                if let Ok(s) = fs::read_to_string(&p) {
                    let stem = p.file_stem().map(|x| x.to_string_lossy().to_string()).unwrap_or_default();
                    let name = json_field(&s, "name").unwrap_or(stem);
                    let title = json_field(&s, "title").unwrap_or_else(|| name.clone());
                    v.push(Desktop { blurb: blurb(&name).to_string(), name, title });
                }
            }
            if !v.is_empty() {
                break;
            }
        }
    }
    if v.is_empty() {
        for (n, t) in [("niri", "niri + Noctalia")] {
            v.push(Desktop { name: n.into(), title: t.into(), blurb: blurb(n).to_string() });
        }
    }
    v.sort_by_key(|d| if d.name == "kde" { 0 } else { 1 });
    v
}

pub fn ram_mb() -> u64 {
    let s = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    for l in s.lines() {
        if let Some(r) = l.strip_prefix("MemTotal:") {
            let kb: u64 = r.trim().trim_end_matches("kB").trim().parse().unwrap_or(0);
            return kb / 1024;
        }
    }
    8192
}

pub fn fmt_size(b: u64) -> String {
    let g = b as f64 / 1_000_000_000.0;
    if g >= 1000.0 {
        format!("{:.1} TB", g / 1000.0)
    } else {
        format!("{:.0} GB", g)
    }
}

pub fn hash_password(pw: &str) -> String {
    let params = sha_crypt::Sha512Params::new(10_000).unwrap();
    sha_crypt::sha512_simple(pw, &params).unwrap_or_default()
}
