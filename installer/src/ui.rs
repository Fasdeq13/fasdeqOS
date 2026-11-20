use crate::app::*;
use crate::data;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::Frame;
use unicode_width::UnicodeWidthChar;

type Rgb = (u8, u8, u8);

const BG: Rgb = (13, 8, 7);
const PANEL: Rgb = (25, 15, 11);
const HI: Rgb = (62, 28, 16);
const TEXT: Rgb = (246, 234, 220);
const DIM: Rgb = (176, 150, 130);
const FAINT: Rgb = (110, 84, 68);
const RED: Rgb = (244, 72, 52);
const OK: Rgb = (150, 226, 110);
const STOPS: [Rgb; 5] = [(255, 226, 70), (255, 178, 36), (255, 122, 26), (238, 62, 40), (190, 26, 50)];

pub struct Th {
    pub vt: bool,
    pub tick: u64,
}

fn lerp(a: Rgb, b: Rgb, t: f32) -> Rgb {
    let f = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    (f(a.0, b.0), f(a.1, b.1), f(a.2, b.2))
}

pub fn grad(t: f32) -> Rgb {
    let t = t.clamp(0.0, 1.0) * (STOPS.len() - 1) as f32;
    let i = (t.floor() as usize).min(STOPS.len() - 2);
    lerp(STOPS[i], STOPS[i + 1], t - i as f32)
}

const VT_FG: [(Color, Rgb); 12] = [
    (Color::Black, (0, 0, 0)),
    (Color::Red, (170, 0, 0)),
    (Color::Green, (0, 170, 0)),
    (Color::Yellow, (170, 85, 0)),
    (Color::Gray, (170, 170, 170)),
    (Color::DarkGray, (85, 85, 85)),
    (Color::LightRed, (255, 85, 85)),
    (Color::LightGreen, (85, 255, 85)),
    (Color::LightYellow, (255, 255, 85)),
    (Color::White, (255, 255, 255)),
    (Color::Red, (120, 20, 10)),
    (Color::Yellow, (210, 130, 20)),
];

fn dist(a: Rgb, b: Rgb) -> i32 {
    let d = |x: u8, y: u8| (x as i32 - y as i32).pow(2);
    d(a.0, b.0) + d(a.1, b.1) + d(a.2, b.2)
}

impl Th {
    pub fn fg(&self, c: Rgb) -> Color {
        if self.vt {
            VT_FG.iter().min_by_key(|(_, r)| dist(*r, c)).map(|x| x.0).unwrap_or(Color::White)
        } else {
            Color::Rgb(c.0, c.1, c.2)
        }
    }
    pub fn bg(&self, c: Rgb) -> Color {
        if self.vt {
            let lum = c.0 as u32 * 3 + c.1 as u32 * 5 + c.2 as u32 * 2;
            if lum > 600 {
                Color::Yellow
            } else if lum > 380 {
                Color::Red
            } else {
                Color::Black
            }
        } else {
            Color::Rgb(c.0, c.1, c.2)
        }
    }
    pub fn s(&self, fg: Rgb, bg: Rgb) -> Style {
        Style::default().fg(self.fg(fg)).bg(self.bg(bg))
    }
    pub fn b(&self, fg: Rgb, bg: Rgb) -> Style {
        self.s(fg, bg).add_modifier(Modifier::BOLD)
    }
    fn sym(&self, a: &'static str, b: &'static str) -> &'static str {
        if !self.vt || crate::font::all_covered(a) {
            a
        } else {
            b
        }
    }
    pub fn g(&self, s: &'static str) -> &'static str {
        if !self.vt || crate::font::all_covered(s) {
            return s;
        }
        match s {
            "▌" | "▏" => "│",
            "▰" | "●" => "■",
            "▱" => "·",
            "○" => "o",
            "⚠" => "!",
            "✓" => "√",
            _ => ">",
        }
    }
    fn check(&self) -> &'static str {
        self.sym("✓", "√")
    }
    fn arrow(&self) -> &'static str {
        self.sym("▶", "►")
    }
    fn mask(&self) -> &'static str {
        self.sym("•", "*")
    }
    fn warn(&self) -> &'static str {
        self.sym("⚠", "!")
    }
    fn shimmer(&self, x: f32, span: f32) -> f32 {
        let base = x / span.max(1.0) * 0.72;
        let w = ((self.tick as f32 * 0.08 + x * 0.09).sin() * 0.5 + 0.5) * 0.28;
        (base + w).clamp(0.0, 1.0)
    }
}

fn cw(c: char) -> usize {
    c.width().unwrap_or(0)
}

fn tw(s: &str) -> usize {
    s.chars().map(cw).sum()
}

fn put(buf: &mut Buffer, x: u16, y: u16, s: &str, st: Style, maxw: usize) -> u16 {
    let a = *buf.area();
    if y >= a.y + a.height {
        return x;
    }
    let mut cx = x as usize;
    let lim = (x as usize + maxw).min((a.x + a.width) as usize);
    for c in s.chars() {
        let w = cw(c);
        if w == 0 {
            continue;
        }
        if cx + w > lim {
            break;
        }
        let mut tmp = [0u8; 4];
        buf[(cx as u16, y)].set_symbol(c.encode_utf8(&mut tmp)).set_style(st);
        if w == 2 && cx + 1 < lim {
            buf[(cx as u16 + 1, y)].set_symbol("").set_style(st);
        }
        cx += w;
    }
    cx as u16
}

fn fill(buf: &mut Buffer, r: Rect, st: Style) {
    for y in r.y..r.y + r.height {
        for x in r.x..r.x + r.width {
            if x < buf.area.x + buf.area.width && y < buf.area.y + buf.area.height {
                buf[(x, y)].set_symbol(" ").set_style(st);
            }
        }
    }
}

fn center(buf: &mut Buffer, r: Rect, y: u16, s: &str, st: Style) {
    let w = tw(s) as u16;
    let x = r.x + r.width.saturating_sub(w) / 2;
    put(buf, x, y, s, st, r.width as usize);
}

fn gtext(buf: &mut Buffer, th: &Th, x: u16, y: u16, s: &str, bgc: Rgb, bold: bool, span: f32, off: f32) {
    let mut cx = x;
    for c in s.chars() {
        let t = th.shimmer(off + (cx - x) as f32, span);
        let mut st = th.s(grad(t), bgc);
        if bold {
            st = st.add_modifier(Modifier::BOLD);
        }
        let mut tmp = [0u8; 4];
        buf[(cx, y)].set_symbol(c.encode_utf8(&mut tmp)).set_style(st);
        cx += cw(c).max(1) as u16;
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Line {
    Round,
    Double,
}

fn border(buf: &mut Buffer, th: &Th, r: Rect, kind: Line, lit: bool, bgc: Rgb, title: Option<&str>) {
    if r.width < 2 || r.height < 2 {
        return;
    }
    let (tl, tr, bl, br, h, v) = match (kind, th.vt) {
        (Line::Double, _) => ("╔", "╗", "╚", "╝", "═", "║"),
        (Line::Round, _) if crate::font::all_covered("╭╮╰╯") => ("╭", "╮", "╰", "╯", "─", "│"),
        (Line::Round, _) => ("┌", "┐", "└", "┘", "─", "│"),
    };
    let span = (r.width + r.height) as f32;
    let col = |i: f32| if lit { th.s(grad(th.shimmer(i, span)), bgc) } else { th.s(FAINT, bgc) };
    let x2 = r.x + r.width - 1;
    let y2 = r.y + r.height - 1;
    for x in r.x..=x2 {
        let (a, b) = if x == r.x {
            (tl, bl)
        } else if x == x2 {
            (tr, br)
        } else {
            (h, h)
        };
        put(buf, x, r.y, a, col((x - r.x) as f32), 1);
        put(buf, x, y2, b, col((x - r.x + r.height) as f32), 1);
    }
    for y in r.y + 1..y2 {
        put(buf, r.x, y, v, col((y - r.y) as f32), 1);
        put(buf, x2, y, v, col((y - r.y + r.width) as f32), 1);
    }
    if let Some(t) = title {
        let s = format!(" {} ", t);
        put(buf, r.x + 3, r.y, &s, th.b(if lit { TEXT } else { DIM }, bgc), r.width as usize - 4);
    }
}

fn hairline(buf: &mut Buffer, th: &Th, x: u16, y: u16, w: u16, bgc: Rgb) {
    for i in 0..w {
        put(buf, x + i, y, "─", th.s(grad(i as f32 / w.max(1) as f32 * 0.9), bgc), 1);
    }
}

const GLYPHS: [(char, [&str; 5]); 8] = [
    ('F', ["█████", "█    ", "████ ", "█    ", "█    "]),
    ('A', [" ███ ", "█   █", "█████", "█   █", "█   █"]),
    ('S', [" ████", "█    ", " ███ ", "    █", "████ "]),
    ('D', ["████ ", "█   █", "█   █", "█   █", "████ "]),
    ('E', ["█████", "█    ", "████ ", "█    ", "█████"]),
    ('Q', [" ███ ", "█   █", "█ █ █", "█  █ ", " ██ █"]),
    ('O', [" ███ ", "█   █", "█   █", "█   █", " ███ "]),
    ('-', ["     ", "     ", "     ", "     ", "     "]),
];

fn banner_width(text: &str) -> u16 {
    (text.chars().count() * 6 - 1) as u16
}

fn draw_banner(buf: &mut Buffer, th: &Th, r: Rect, y: u16, text: &str) {
    let w = banner_width(text);
    let x0 = r.x + r.width.saturating_sub(w) / 2;
    let rows: Vec<Vec<char>> = (0..5)
        .map(|row| {
            let mut v = Vec::new();
            for (i, ch) in text.chars().enumerate() {
                let g = GLYPHS.iter().find(|g| g.0 == ch).map(|g| g.1).unwrap_or(GLYPHS[7].1);
                v.extend(g[row].chars());
                if i + 1 < text.chars().count() {
                    v.push(' ');
                }
            }
            v
        })
        .collect();
    if !th.vt {
        for row in 0..5usize {
            for (i, c) in rows[row].iter().enumerate() {
                if *c == '█' {
                    let sx = x0 + i as u16 + 1;
                    let sy = y + row as u16 + 1;
                    let lit_below = row + 1 < 5 && rows[row + 1].get(i + 1).copied() == Some('█');
                    let lit_right = rows[row].get(i + 1).copied() == Some('█');
                    if !lit_below && !lit_right && sx < buf.area.x + buf.area.width && sy < buf.area.y + buf.area.height {
                        put(buf, sx, sy, "▒", th.s((86, 30, 22), BG), 1);
                    }
                }
            }
        }
    }
    for row in 0..5usize {
        for (i, c) in rows[row].iter().enumerate() {
            if *c == '█' {
                let t = th.shimmer(i as f32 + row as f32 * 2.0, w as f32);
                put(buf, x0 + i as u16, y + row as u16, "█", th.s(grad(t), BG), 1);
            }
        }
    }
}

fn keycaps(buf: &mut Buffer, th: &Th, r: Rect, y: u16, items: &[(&str, &str)]) {
    let total: usize = items.iter().map(|(k, l)| tw(k) + 2 + tw(l) + 3).sum::<usize>().saturating_sub(3);
    let mut x = r.x + r.width.saturating_sub(total as u16) / 2;
    for (k, l) in items {
        let kk = format!(" {} ", k);
        x = put(buf, x, y, &kk, th.b(TEXT, HI), 40);
        x = put(buf, x + 1, y, l, th.s(DIM, BG), 40);
        x += 2;
    }
}

fn titlebar(buf: &mut Buffer, th: &Th, a: Rect, app: &App) {
    fill(buf, Rect::new(a.x, a.y, a.width, 1), th.s(TEXT, PANEL));
    let d = th.sym(th.g("●"), "■");
    put(buf, 2, 0, d, th.s((255, 95, 86), PANEL), 1);
    put(buf, 4, 0, d, th.s((255, 189, 46), PANEL), 1);
    put(buf, 6, 0, d, th.s((255, 130, 30), PANEL), 1);
    let t = "FasdeqOS  ·  Installer";
    let x = a.width.saturating_sub(tw(t) as u16) / 2;
    gtext(buf, th, x, 0, t, PANEL, true, tw(t) as f32, 0.0);
    let right = match app.screen {
        Screen::Mode => "welcome".to_string(),
        Screen::Flow if app.express => format!("Express · step {} of {}", app.cur + 1, app.flow.len()),
        Screen::Flow => "Advanced".to_string(),
        Screen::Summary => "review".to_string(),
        Screen::Install => "installing".to_string(),
        Screen::Done => "done".to_string(),
        Screen::Failed => "error".to_string(),
    };
    let rw = tw(&right) as u16;
    put(buf, a.width.saturating_sub(rw + 2), 0, &right, th.s(DIM, PANEL), rw as usize);
}

pub fn draw(f: &mut Frame, app: &App) {
    let th = Th { vt: app.vt, tick: app.tick };
    let a = f.area();
    let buf = f.buffer_mut();
    if a.width < 64 || a.height < 22 {
        fill(buf, a, th.s(TEXT, BG));
        if a.width >= 8 && a.height >= 3 {
            let msg = ["FasdeqOS", "Window too small", "Need 64x22 or larger"];
            for (i, m) in msg.iter().enumerate() {
                let w = m.chars().count() as u16;
                let x = a.x + a.width.saturating_sub(w) / 2;
                let y = a.y + a.height / 2 + i as u16 - 1;
                buf.set_stringn(x, y, m, a.width as usize, th.s(TEXT, BG));
            }
        }
        return;
    }
    fill(buf, a, th.s(TEXT, BG));
    titlebar(buf, &th, a, app);
    let body = Rect::new(a.x, a.y + 1, a.width, a.height.saturating_sub(2));
    let foot_y = a.y + a.height - 1;
    match app.screen {
        Screen::Mode => draw_mode(buf, &th, app, body, foot_y),
        Screen::Flow => draw_flow(f, &th, app, body, foot_y),
        Screen::Summary => draw_summary(buf, &th, app, body, foot_y),
        Screen::Install => draw_install(buf, &th, app, body, foot_y),
        Screen::Done => draw_done(buf, &th, app, body, foot_y),
        Screen::Failed => draw_failed(buf, &th, app, body, foot_y),
    }
}

fn draw_mode(buf: &mut Buffer, th: &Th, app: &App, body: Rect, foot_y: u16) {
    let tall = body.height >= 24;
    let mut y = body.y + if tall { 1 } else { 0 };
    draw_banner(buf, th, body, y, "FASDEQOS");
    y += 6;
    let sub = if th.vt { "I N S T A L L E R" } else { "─────  I N S T A L L E R  ─────" };
    center(buf, body, y, sub, th.b((255, 160, 40), BG));
    y += 1;
    if tall {
        y += 1;
    }
    center(buf, body, y, "Choose how you want to set up your system", th.s(DIM, BG));
    y += 2;
    let ch = body.height.saturating_sub(y - body.y).min(12).max(9);
    let total_w = body.width.saturating_sub(4).min(100);
    let cw_ = (total_w - 4) / 3;
    let x0 = body.x + body.width.saturating_sub(cw_ * 3 + 4) / 2;
    let cards = [
        ("Express", "Quick setup", ["Pick a disk", "Language & time zone", "Passwords", "KDE Plasma desktop"], None),
        ("Advanced", "Full control", ["Disk and desktop", "Language & time zone", "Accounts", "Swap and zram (zstd)"], Some("RECOMMENDED")),
        ("Expert", "Just fish", ["Skip the installer", "Drop to the live shell", "Partition by hand", "Use pkg and doas"], None),
    ];
    for (i, c) in cards.iter().enumerate() {
        let r = Rect::new(x0 + i as u16 * (cw_ + 2), y, cw_, ch);
        let sel = app.mode_cur == i;
        let bgc = if sel { HI } else { PANEL };
        if sel && !th.vt && r.x + r.width < buf.area.width && r.y + r.height < buf.area.height {
            for yy in r.y + 1..=r.y + r.height {
                put(buf, r.x + r.width, yy, "░", th.s((70, 26, 18), BG), 1);
            }
            for xx in r.x + 1..=r.x + r.width {
                put(buf, xx, r.y + r.height, "░", th.s((70, 26, 18), BG), 1);
            }
        }
        fill(buf, r, th.s(TEXT, bgc));
        border(buf, th, r, if sel { Line::Double } else { Line::Round }, sel, bgc, None);
        let chip = format!(" {} ", i + 1);
        put(buf, r.x + 2, r.y + 1, &chip, th.b((20, 10, 6), if sel { (255, 196, 40) } else { FAINT }), 5);
        if let Some(b) = c.3 {
            let bw = tw(b) as u16 + 2;
            put(buf, r.x + r.width - bw - 2, r.y + 1, &format!(" {} ", b), th.b((20, 10, 6), (255, 120, 40)), bw as usize);
        }
        if sel {
            gtext(buf, th, r.x + 3, r.y + 3, c.0, bgc, true, 20.0, 0.0);
            put(buf, r.x + 2, r.y + 3, th.arrow(), th.b((255, 196, 40), bgc), 1);
        } else {
            put(buf, r.x + 3, r.y + 3, c.0, th.b(TEXT, bgc), cw_ as usize - 4);
        }
        put(buf, r.x + 3, r.y + 4, c.1, th.s(if sel { (255, 170, 80) } else { DIM }, bgc), cw_ as usize - 4);
        for (k, line) in c.2.iter().enumerate() {
            let yy = r.y + 6 + k as u16;
            if yy + 1 >= r.y + r.height {
                break;
            }
            put(buf, r.x + 3, yy, th.sym("•", "o"), th.s(if sel { (255, 122, 26) } else { FAINT }, bgc), 1);
            put(buf, r.x + 5, yy, line, th.s(if sel { TEXT } else { DIM }, bgc), cw_ as usize - 7);
        }
    }
    keycaps(buf, th, body, foot_y, &[("← →", "choose"), ("w a s d", "move"), ("1 2 3", "jump"), ("Enter", "start"), ("q", "shell")]);
}

fn sidebar_rows(app: &App, h: u16) -> bool {
    h as usize >= app.flow.len() * 3 + 6
}

fn draw_flow(f: &mut Frame, th: &Th, app: &App, body: Rect, foot_y: u16) {
    let buf = f.buffer_mut();
    let sw: u16 = if body.width >= 100 { 40 } else { 32 };
    let sidebar = Rect::new(body.x + 2, body.y + 1, sw, body.height.saturating_sub(2));
    let panel = Rect::new(sidebar.x + sw + 2, body.y + 1, body.width.saturating_sub(sw + 6), body.height.saturating_sub(2));
    let side_focus = app.side && !app.express;
    fill(buf, sidebar, th.s(TEXT, PANEL));
    border(buf, th, sidebar, Line::Round, side_focus, PANEL, Some(if app.express { "Express" } else { "Advanced" }));
    let two = sidebar_rows(app, sidebar.height);
    let mut y = sidebar.y + 2;
    let mut cursor: Option<(u16, u16)> = None;
    for (i, it) in app.flow.iter().enumerate() {
        let sel = i == app.cur;
        let rowh = if two { 2 } else { 1 };
        let bgc = if sel { HI } else { PANEL };
        fill(buf, Rect::new(sidebar.x + 1, y, sidebar.width - 2, rowh), th.s(TEXT, bgc));
        if sel {
            for k in 0..rowh {
                put(buf, sidebar.x + 1, y + k, th.g("▌"), th.s(grad(0.15 + th.tick as f32 * 0.0 + k as f32 * 0.2), bgc), 1);
            }
        }
        let done = app.is_set(*it) && (app.express == false || i < app.cur || app.value_of(*it).len() > 0);
        let known = !matches!(it, Item::Disk | Item::Root | Item::User) || app.is_set(*it);
        let mark = if known && done { th.check() } else { th.sym(th.g("○"), "o") };
        let mc = if known && done { OK } else { FAINT };
        put(buf, sidebar.x + 3, y, mark, th.b(mc, bgc), 1);
        let name = format!("{}  {}", i + 1, it.title());
        put(buf, sidebar.x + 5, y, &name, th.b(if sel { TEXT } else { DIM }, bgc), sw as usize - 8);
        let v = app.value_of(*it);
        if two {
            let shown = if v.is_empty() { "not set".to_string() } else { v };
            put(buf, sidebar.x + 8, y + 1, &shown, th.s(if sel { (255, 170, 80) } else { FAINT }, bgc), sw as usize - 11);
            y += 3;
        } else {
            let vw = tw(&v).min(sw as usize / 2 - 2);
            if !v.is_empty() && sw as usize > 16 + vw {
                put(buf, sidebar.x + sw - 2 - vw as u16, y, &v, th.s(if sel { (255, 170, 80) } else { FAINT }, bgc), vw);
            }
            y += 1;
        }
    }
    if !app.express {
        y += 1;
        if y + 2 < sidebar.y + sidebar.height {
            hairline(buf, th, sidebar.x + 2, y, sidebar.width - 4, PANEL);
            y += 1;
        }
        let sel = app.cur == app.flow.len();
        let ready = app.missing().is_empty();
        let r = Rect::new(sidebar.x + 2, y, sidebar.width - 4, 1);
        if ready {
            let st = if sel { th.b((24, 10, 4), (255, 196, 40)) } else { th.b((255, 196, 40), HI) };
            fill(buf, r, st);
            center(buf, r, y, &format!("{}  Review & install", th.arrow()), st);
        } else {
            let st = if sel { th.b(TEXT, HI) } else { th.s(FAINT, PANEL) };
            fill(buf, r, st);
            center(buf, r, y, "Review & install", st);
        }
    }

    let pbg = PANEL;
    fill(buf, panel, th.s(TEXT, pbg));
    let panel_focus = !side_focus;
    let it = if app.cur < app.flow.len() { Some(app.item()) } else { None };
    border(buf, th, panel, Line::Round, panel_focus, pbg, None);
    let inner = Rect::new(panel.x + 3, panel.y + 1, panel.width.saturating_sub(6), panel.height.saturating_sub(2));
    match it {
        Some(it) => {
            gtext(buf, th, inner.x, inner.y + 1, it.title(), pbg, true, 24.0, 0.0);
            put(buf, inner.x, inner.y + 2, it.sub(), th.s(DIM, pbg), inner.width as usize);
            hairline(buf, th, inner.x, inner.y + 3, inner.width.min(48), pbg);
            let content = Rect::new(inner.x, inner.y + 5, inner.width, inner.height.saturating_sub(7));
            match it {
                Item::Disk => cursor = draw_disks(buf, th, app, content),
                Item::Env => cursor = draw_envs(buf, th, app, content),
                Item::Shell => cursor = draw_shells(buf, th, app, content),
                Item::Locale | Item::Tz => cursor = draw_simple_list(buf, th, app, it, content),
                Item::Root => cursor = draw_root(buf, th, app, content),
                Item::User => cursor = draw_user(buf, th, app, content),
                Item::Swap => cursor = draw_swap(buf, th, app, content),
            }
        }
        None => {
            gtext(buf, th, inner.x, inner.y + 1, "Review & install", pbg, true, 24.0, 0.0);
            put(buf, inner.x, inner.y + 2, "Everything is ready when each step has a check mark", th.s(DIM, pbg), inner.width as usize);
            hairline(buf, th, inner.x, inner.y + 3, inner.width.min(48), pbg);
            let m = app.missing();
            let mut yy = inner.y + 5;
            if m.is_empty() {
                put(buf, inner.x, yy, &format!("{} All set. Press Enter to review your choices.", th.check()), th.b(OK, pbg), inner.width as usize);
            } else {
                put(buf, inner.x, yy, "Still needed:", th.b(TEXT, pbg), inner.width as usize);
                for s in m {
                    yy += 1;
                    put(buf, inner.x + 2, yy, &format!("{} {}", th.sym("•", "o"), s), th.s((255, 170, 80), pbg), inner.width as usize);
                }
            }
        }
    }
    if let Some(m) = &app.msg {
        let y = panel.y + panel.height - 2;
        put(buf, panel.x + 3, y, &format!("{} {}", th.warn(), m), th.b(RED, pbg), panel.width as usize - 6);
    }
    if let Some((cx, cy)) = cursor {
        f.set_cursor_position((cx, cy));
    }
    let buf = f.buffer_mut();
    let hints: Vec<(&str, &str)> = if side_focus {
        vec![("↑ ↓", "move"), ("w s", "move"), ("j k", "move"), ("Enter", "open"), ("Tab", "next"), ("Esc", "back")]
    } else if app.typing() && matches!(app.item(), Item::Root | Item::User) {
        vec![("Type", "text"), ("↑ ↓ Tab", "field"), ("Enter", "confirm"), ("Esc", "back")]
    } else if app.typing() {
        vec![("Type", "filter"), ("↑ ↓", "move"), ("Enter", "done"), ("Esc", "done")]
    } else if app.item() == Item::Swap {
        vec![("↑ ↓", "row"), ("← →", "change"), ("Enter", "edit / ok"), ("Esc", "back")]
    } else if matches!(app.item(), Item::Shell | Item::Disk) {
        vec![("↑ ↓", "move"), ("w s", "move"), ("Enter", "select"), ("a / Esc", "back")]
    } else {
        vec![("↑ ↓", "move"), ("w s", "move"), ("/", "search"), ("Enter", "select"), ("a / Esc", "back")]
    };
    keycaps(buf, th, body, foot_y, &hints);
}

fn scroll_off(cur: usize, per: usize, total_rows: usize) -> usize {
    if total_rows <= per {
        return 0;
    }
    let half = per / 2;
    cur.saturating_sub(half).min(total_rows - per)
}

fn filter_bar(buf: &mut Buffer, th: &Th, l: &ListState, r: Rect, shown: usize, total: usize) -> Option<(u16, u16)> {
    let bgc = if l.filtering { HI } else { PANEL };
    fill(buf, Rect::new(r.x, r.y, r.width.min(44), 1), th.s(TEXT, bgc));
    let label = if l.filter.is_empty() && !l.filtering { "press / to search".to_string() } else { format!("{}", l.filter) };
    put(buf, r.x, r.y, "/", th.b((255, 196, 40), bgc), 1);
    let x = put(buf, r.x + 2, r.y, &label, th.s(if l.filter.is_empty() && !l.filtering { FAINT } else { TEXT }, bgc), 40);
    let cnt = format!("{}/{}", shown, total);
    put(buf, r.x + r.width.min(44).saturating_sub(cnt.len() as u16 + 1), r.y, &cnt, th.s(FAINT, bgc), 12);
    if l.filtering {
        Some((x, r.y))
    } else {
        None
    }
}

fn row_bg(buf: &mut Buffer, th: &Th, r: Rect, h: u16, sel: bool, focus: bool) -> Rgb {
    let bgc = if sel { HI } else { PANEL };
    fill(buf, Rect::new(r.x, r.y, r.width, h), th.s(TEXT, bgc));
    if sel {
        for k in 0..h {
            put(buf, r.x, r.y + k, if focus { th.g("▌") } else { th.g("▏") }, th.s((255, 160, 36), bgc), 1);
        }
    }
    bgc
}

fn draw_simple_list(buf: &mut Buffer, th: &Th, app: &App, it: Item, r: Rect) -> Option<(u16, u16)> {
    let (l, selected) = match it {
        Item::Locale => (&app.loc_l, app.sel_loc),
        _ => (&app.tz_l, app.sel_tz),
    };
    let vis = app.visible(it);
    let cur = app.flow_cur_list(it);
    let c = filter_bar(buf, th, l, r, vis.len(), app.labels(it).len());
    let list = Rect::new(r.x, r.y + 2, r.width.min(64), r.height.saturating_sub(2));
    let per = list.height as usize;
    let off = scroll_off(cur, per, vis.len());
    for (k, idx) in vis.iter().enumerate().skip(off).take(per) {
        let y = list.y + (k - off) as u16;
        let sel = k == cur;
        let rr = Rect::new(list.x, y, list.width, 1);
        let bgc = row_bg(buf, th, rr, 1, sel, true);
        let (main, sub) = match it {
            Item::Locale => {
                let l = &data::LOCALES[*idx];
                (if crate::font::all_covered(l.1) { l.1.to_string() } else { l.2.to_string() }, l.0.to_string())
            }
            _ => {
                let t = &app.tzs[*idx];
                match t.rsplit_once('/') {
                    Some((a, b)) => (b.replace('_', " "), a.to_string()),
                    None => (t.clone(), String::new()),
                }
            }
        };
        put(buf, list.x + 2, y, &main, th.b(if sel { TEXT } else { DIM }, bgc), list.width as usize - 6);
        let subw = tw(&sub);
        if subw + tw(&main) + 6 < list.width as usize {
            put(buf, list.x + list.width - 4 - subw as u16, y, &sub, th.s(FAINT, bgc), subw);
        }
        if *idx == selected {
            put(buf, list.x + list.width - 2, y, th.check(), th.b(OK, bgc), 1);
        }
    }
    if vis.is_empty() {
        put(buf, list.x + 2, list.y, "No matches", th.s(FAINT, PANEL), 20);
    }
    c
}

fn draw_shells(buf: &mut Buffer, th: &Th, app: &App, r: Rect) -> Option<(u16, u16)> {
    let list = Rect::new(r.x, r.y, r.width.min(70), r.height.saturating_sub(3));
    let cur = app.shell_l.cur;
    let per = (list.height / 3) as usize;
    let off = scroll_off(cur, per.max(1), SHELLS.len());
    for (k, sh) in SHELLS.iter().enumerate().skip(off).take(per) {
        let y = list.y + (k - off) as u16 * 3;
        let sel = k == cur;
        let rr = Rect::new(list.x, y, list.width, 2);
        let bgc = row_bg(buf, th, rr, 2, sel, true);
        put(buf, list.x + 2, y, sh.1, th.b(if sel { TEXT } else { DIM }, bgc), list.width as usize - 20);
        put(buf, list.x + 2, y + 1, sh.2, th.s(if sel { (255, 170, 80) } else { FAINT }, bgc), list.width as usize - 6);
        if k == app.sel_shell {
            put(buf, list.x + list.width - 2, y, th.check(), th.b(OK, bgc), 1);
        }
    }
    let wy = r.y + r.height.saturating_sub(1);
    put(buf, r.x, wy, "Optional. Noctalia and DankMaterialShell download on first start.", th.s(FAINT, PANEL), r.width as usize);
    None
}

fn draw_envs(buf: &mut Buffer, th: &Th, app: &App, r: Rect) -> Option<(u16, u16)> {
    let vis = app.visible(Item::Env);
    let cur = app.flow_cur_list(Item::Env);
    let c = filter_bar(buf, th, &app.env_l, r, vis.len(), app.desks.len());
    let list = Rect::new(r.x, r.y + 2, r.width.min(70), r.height.saturating_sub(2));
    let per = (list.height / 3) as usize;
    let off = scroll_off(cur, per.max(1), vis.len());
    for (k, idx) in vis.iter().enumerate().skip(off).take(per) {
        let y = list.y + (k - off) as u16 * 3;
        let sel = k == cur;
        let rr = Rect::new(list.x, y, list.width, 2);
        let bgc = row_bg(buf, th, rr, 2, sel, true);
        let d = &app.desks[*idx];
        put(buf, list.x + 2, y, &d.title, th.b(if sel { TEXT } else { DIM }, bgc), list.width as usize - 20);
        if d.name == "kde" {
            put(buf, list.x + 3 + tw(&d.title) as u16, y, " recommended ", th.b((20, 10, 6), (255, 160, 40)), 14);
        }
        put(buf, list.x + 2, y + 1, &d.blurb, th.s(if sel { (255, 170, 80) } else { FAINT }, bgc), list.width as usize - 6);
        if *idx == app.sel_env {
            put(buf, list.x + list.width - 2, y, th.check(), th.b(OK, bgc), 1);
        }
    }
    c
}

fn draw_disks(buf: &mut Buffer, th: &Th, app: &App, r: Rect) -> Option<(u16, u16)> {
    let list = Rect::new(r.x, r.y, r.width.min(72), r.height.saturating_sub(2));
    if app.disks.is_empty() {
        put(buf, r.x, r.y, "No suitable disks found (need at least 6 GB, not the install medium)", th.b(RED, PANEL), r.width as usize);
        return None;
    }
    let cur = app.disk_l.cur;
    let per = (list.height / 3) as usize;
    let off = scroll_off(cur, per.max(1), app.disks.len());
    let maxsize = app.disks.iter().map(|d| d.size).max().unwrap_or(1);
    for (k, d) in app.disks.iter().enumerate().skip(off).take(per) {
        let y = list.y + (k - off) as u16 * 3;
        let sel = k == cur;
        let bgc = row_bg(buf, th, Rect::new(list.x, y, list.width, 2), 2, sel, true);
        put(buf, list.x + 2, y, &format!("/dev/{}", d.name), th.b(if sel { TEXT } else { DIM }, bgc), 18);
        let model = if d.model.is_empty() { "Unknown model".to_string() } else { d.model.clone() };
        put(buf, list.x + 14, y, &model, th.s(if sel { TEXT } else { DIM }, bgc), list.width as usize - 26);
        let tag = format!("{}{}", d.tran, if d.removable { " · removable" } else { "" });
        let tgw = tw(&tag) as u16;
        put(buf, list.x + list.width - tgw - 3, y, &tag, th.s(FAINT, bgc), tgw as usize);
        let bw = (list.width as usize).saturating_sub(18).min(40);
        let filled = ((d.size as f64 / maxsize as f64) * bw as f64).ceil() as usize;
        for i in 0..bw {
            let (s, c) = if i < filled { ("█", grad(i as f32 / bw as f32 * 0.9)) } else { (if th.vt { "░" } else { "▒" }, (60, 40, 32)) };
            put(buf, list.x + 2 + i as u16, y + 1, s, th.s(c, bgc), 1);
        }
        put(buf, list.x + 4 + bw as u16, y + 1, &data::fmt_size(d.size), th.b(if sel { (255, 196, 40) } else { DIM }, bgc), 10);
        if app.sel_disk == Some(k) {
            put(buf, list.x + list.width - 2, y + 1, th.check(), th.b(OK, bgc), 1);
        }
    }
    let wy = r.y + r.height.saturating_sub(1);
    put(buf, r.x, wy, &format!("{} Everything on the chosen disk will be erased", th.warn()), th.b((255, 140, 60), PANEL), r.width as usize);
    None
}

fn input_row(buf: &mut Buffer, th: &Th, x: u16, y: u16, w: u16, label: &str, value: &str, secret: bool, active: bool) -> Option<(u16, u16)> {
    put(buf, x, y, label, th.s(if active { (255, 170, 80) } else { DIM }, PANEL), w as usize);
    let bx = x;
    let by = y + 1;
    let bgc = if active { HI } else { (36, 22, 16) };
    fill(buf, Rect::new(bx, by, w, 1), th.s(TEXT, bgc));
    let shown: String = if secret { value.chars().map(|_| th.mask().chars().next().unwrap()).collect() } else { value.to_string() };
    let vis: String = {
        let n = shown.chars().count();
        let room = w as usize - 3;
        if n > room {
            shown.chars().skip(n - room).collect()
        } else {
            shown
        }
    };
    put(buf, bx + 1, by, th.sym(th.g("▌"), "|"), th.s(if active { (255, 160, 36) } else { FAINT }, bgc), 1);
    let ex = put(buf, bx + 2, by, &vis, th.s(TEXT, bgc), w as usize - 3);
    if active {
        Some((ex, by))
    } else {
        None
    }
}

fn meter(buf: &mut Buffer, th: &Th, x: u16, y: u16, pw: &str) {
    let s = pw_strength(pw);
    let (lbl, c) = match s {
        0 => ("", FAINT),
        1 => ("Weak", RED),
        2 => ("Fair", (255, 140, 40)),
        3 => ("Good", (255, 200, 60)),
        4 => ("Strong", (190, 226, 90)),
        _ => ("Excellent", OK),
    };
    put(buf, x, y, "Strength ", th.s(DIM, PANEL), 9);
    for i in 0..5 {
        let on = i < s;
        put(buf, x + 9 + i as u16 * 2, y, if on { th.sym(th.g("▰"), "■") } else { th.sym(th.g("▱"), "·") }, th.s(if on { c } else { FAINT }, PANEL), 1);
    }
    put(buf, x + 21, y, lbl, th.b(c, PANEL), 12);
}

fn draw_root(buf: &mut Buffer, th: &Th, app: &App, r: Rect) -> Option<(u16, u16)> {
    let w = r.width.min(46);
    let c1 = input_row(buf, th, r.x, r.y, w, "Password", &app.root[0], true, app.root_f == 0);
    let c2 = input_row(buf, th, r.x, r.y + 3, w, "Repeat password", &app.root[1], true, app.root_f == 1);
    meter(buf, th, r.x, r.y + 6, &app.root[0]);
    if !app.root[1].is_empty() {
        if app.root[0] == app.root[1] {
            put(buf, r.x, r.y + 8, &format!("{} Passwords match", th.check()), th.s(OK, PANEL), 30);
        } else {
            put(buf, r.x, r.y + 8, "x Passwords differ", th.s(RED, PANEL), 30);
        }
    }
    if app.root_f == 0 { c1 } else { c2 }
}

fn draw_user(buf: &mut Buffer, th: &Th, app: &App, r: Rect) -> Option<(u16, u16)> {
    let w = r.width.min(46);
    let labels = ["Username", "Computer name", "Password", "Repeat password"];
    let mut cur = None;
    let compact = r.height < 14;
    for i in 0..4 {
        let y = r.y + i as u16 * if compact { 2 } else { 3 };
        let c = if compact {
            let active = app.user_f == i;
            let lw = 17u16;
            put(buf, r.x, y, labels[i], th.s(if active { (255, 170, 80) } else { DIM }, PANEL), lw as usize);
            let bgc = if active { HI } else { (36, 22, 16) };
            fill(buf, Rect::new(r.x + lw, y, w - lw, 1), th.s(TEXT, bgc));
            let val: String = if i >= 2 { app.user[i].chars().map(|_| th.mask().chars().next().unwrap()).collect() } else { app.user[i].clone() };
            let ex = put(buf, r.x + lw + 1, y, &val, th.s(TEXT, bgc), (w - lw - 2) as usize);
            if active { Some((ex, y)) } else { None }
        } else {
            input_row(buf, th, r.x, y, w, labels[i], &app.user[i], i >= 2, app.user_f == i)
        };
        if app.user_f == i {
            cur = c;
        }
    }
    let my = r.y + if compact { 8 } else { 12 };
    if r.height as i32 > (my - r.y) as i32 {
        meter(buf, th, r.x, my, &app.user[2]);
    }
    cur
}

fn draw_swap(buf: &mut Buffer, th: &Th, app: &App, r: Rect) -> Option<(u16, u16)> {
    let rows = app.swap_row_list();
    let w = r.width.min(60);
    let mut y = r.y;
    let mut cur = None;
    for row in rows {
        let active = app.swap.row == row;
        let bgc = if active { HI } else { PANEL };
        fill(buf, Rect::new(r.x, y, w, 1), th.s(TEXT, bgc));
        if active {
            put(buf, r.x, y, th.g("▌"), th.s((255, 160, 36), bgc), 1);
        }
        let (label, value, hint) = match row {
            0 => ("Swap strategy", SWAP_MODES[app.swap.mode].to_string(), String::new()),
            1 => ("zram algorithm", ZALGOS[app.swap.zalgo].to_string(), "zstd compresses best".to_string()),
            2 => (
                "zram size",
                if app.swap.zsize == 3 { format!("{} GB", app.swap.custom_z) } else { ZSIZES[app.swap.zsize].to_string() },
                format!("= {} of {} RAM", mb(app.zram_mb()), mb(app.ram)),
            ),
            3 => (
                "Swap file size",
                if app.swap.fsize == 4 { format!("{} GB", app.swap.custom_f) } else { FSIZES[app.swap.fsize].to_string() },
                "stored on the system disk".to_string(),
            ),
            _ => ("", String::new(), String::new()),
        };
        if row == 4 {
            let st = if active { th.b((24, 10, 4), (255, 196, 40)) } else { th.b((255, 196, 40), HI) };
            let bw = 14u16;
            fill(buf, Rect::new(r.x + 2, y, bw, 1), st);
            center(buf, Rect::new(r.x + 2, y, bw, 1), y, "Done", st);
            fill(buf, Rect::new(r.x, y, 2, 1), th.s(TEXT, PANEL));
        } else {
            put(buf, r.x + 2, y, label, th.s(if active { (255, 170, 80) } else { DIM }, bgc), 18);
            let lw = th.sym("◀", "<");
            let rw = th.sym("▶", ">");
            let editing = app.swap.editing && active && (row == 2 || row == 3);
            let vs = if editing { format!("{} GB", app.swap.buf) } else { value.clone() };
            let x = put(buf, r.x + 20, y, lw, th.s(if active { (255, 160, 36) } else { FAINT }, bgc), 1);
            let x2 = put(buf, x + 1, y, &vs, th.b(TEXT, bgc), 22);
            put(buf, x2 + 1, y, rw, th.s(if active { (255, 160, 36) } else { FAINT }, bgc), 1);
            if editing {
                cur = Some((x2 - 3, y));
            }
            if !hint.is_empty() {
                put(buf, r.x + 2, y + 1, &hint, th.s(FAINT, PANEL), w as usize);
            }
        }
        y += 3;
    }
    cur
}

fn draw_summary(buf: &mut Buffer, th: &Th, app: &App, body: Rect, foot_y: u16) {
    let w = body.width.saturating_sub(4).min(72);
    let h = 17u16.min(body.height);
    let r = Rect::new(body.x + (body.width - w) / 2, body.y + body.height.saturating_sub(h) / 2, w, h);
    fill(buf, r, th.s(TEXT, PANEL));
    border(buf, th, r, Line::Double, true, PANEL, None);
    gtext(buf, th, r.x + 3, r.y + 1, "Ready to install", PANEL, true, 24.0, 0.0);
    hairline(buf, th, r.x + 3, r.y + 2, r.width - 6, PANEL);
    let mut y = r.y + 4;
    for it in app.flow.iter() {
        put(buf, r.x + 3, y, it.title(), th.s(DIM, PANEL), 20);
        put(buf, r.x + 24, y, &app.value_of(*it), th.b(TEXT, PANEL), r.width as usize - 28);
        y += 1;
    }
    if app.express {
        put(buf, r.x + 3, y, "Desktop", th.s(DIM, PANEL), 20);
        put(buf, r.x + 24, y, "KDE Plasma", th.b(TEXT, PANEL), 30);
        y += 1;
        put(buf, r.x + 3, y, "Swap & zram", th.s(DIM, PANEL), 20);
        put(buf, r.x + 24, y, &app.value_of(Item::Swap), th.b(TEXT, PANEL), 30);
    }
    let by = r.y + r.height - 3;
    if app.sum_confirm {
        let d = app.sel_disk.and_then(|i| app.disks.get(i)).map(|d| d.name.clone()).unwrap_or_default();
        let m = format!("{} This ERASES /dev/{}. Press Enter again to confirm", th.warn(), d);
        center(buf, r, by - 2, &m, th.b(RED, PANEL));
    }
    let labels = [if app.sum_confirm { "  Yes, erase and install  " } else { "  Install  " }, "  Back  "];
    let total = tw(labels[0]) + tw(labels[1]) + 4;
    let mut x = r.x + (r.width - total as u16) / 2;
    for (i, l) in labels.iter().enumerate() {
        let sel = app.sum_btn == i;
        let st = if sel {
            if i == 0 && app.sum_confirm { th.b((255, 240, 230), (200, 40, 30)) } else { th.b((24, 10, 4), (255, 196, 40)) }
        } else {
            th.s(DIM, HI)
        };
        fill(buf, Rect::new(x, by, tw(l) as u16, 1), st);
        x = put(buf, x, by, l, st, 40) + 4;
    }
    keycaps(buf, th, body, foot_y, &[("← →", "choose"), ("Enter", "confirm"), ("Esc", "back")]);
}

fn draw_install(buf: &mut Buffer, th: &Th, app: &App, body: Rect, foot_y: u16) {
    let mut y = body.y + 1;
    if body.height >= 30 {
        draw_banner(buf, th, body, y, "FASDEQOS");
        y += 7;
    }
    let w = body.width.saturating_sub(4).min(90);
    let x = body.x + (body.width - w) / 2;
    let title = "Installing FasdeqOS";
    center(buf, body, y, title, th.b(TEXT, BG));
    y += 2;
    let bw = w as usize - 8;
    let filled = bw * app.prog.pct as usize / 100;
    for i in 0..bw {
        if i < filled {
            put(buf, x + i as u16, y, "█", th.s(grad(th.shimmer(i as f32, bw as f32)), BG), 1);
        } else {
            put(buf, x + i as u16, y, if th.vt { "░" } else { "▒" }, th.s((52, 34, 26), BG), 1);
        }
    }
    put(buf, x + bw as u16 + 1, y, &format!("{:>3}%", app.prog.pct), th.b((255, 196, 40), BG), 5);
    y += 2;
    let frames: [&str; 10] = if th.vt { ["|", "/", "-", "\\", "|", "/", "-", "\\", "|", "/"] } else { ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] };
    let sp = frames[(app.tick as usize / 2) % 10];
    let sr = Rect::new(x, y, w, (app.prog.steps.len() as u16 + 2).min(body.height.saturating_sub(y - body.y + 8)));
    fill(buf, sr, th.s(TEXT, PANEL));
    border(buf, th, sr, Line::Round, true, PANEL, Some("Progress"));
    for (i, s) in app.prog.steps.iter().enumerate() {
        let yy = sr.y + 1 + i as u16;
        if yy + 1 >= sr.y + sr.height {
            break;
        }
        let n = i + 1;
        let (m, c, tc) = if n < app.prog.step {
            (th.check(), OK, DIM)
        } else if n == app.prog.step {
            (sp, (255, 196, 40), TEXT)
        } else {
            (th.sym(th.g("○"), "o"), FAINT, FAINT)
        };
        put(buf, sr.x + 3, yy, m, th.b(c, PANEL), 1);
        put(buf, sr.x + 6, yy, s, th.b(tc, PANEL), sr.width as usize - 10);
    }
    let ly = sr.y + sr.height + 1;
    if ly + 3 < foot_y {
        let lh = (foot_y - ly - 1).min(8);
        let lr = Rect::new(x, ly, w, lh);
        border(buf, th, lr, Line::Round, false, BG, Some("Log"));
        let lines: Vec<&String> = app.prog.log.iter().rev().take(lh as usize - 2).collect();
        for (i, l) in lines.iter().rev().enumerate() {
            put(buf, lr.x + 2, lr.y + 1 + i as u16, l, th.s(FAINT, BG), lr.width as usize - 4);
        }
    }
    let el = app.prog.start.elapsed().as_secs();
    let t = format!("{:02}:{:02}", el / 60, el % 60);
    put(buf, body.x + body.width - 8, foot_y, &t, th.s(DIM, BG), 6);
    center(buf, body, foot_y, "Please wait, do not power off", th.s(DIM, BG));
}

fn draw_done(buf: &mut Buffer, th: &Th, app: &App, body: Rect, foot_y: u16) {
    let mut y = body.y + body.height.saturating_sub(18) / 2;
    draw_banner(buf, th, body, y, "FASDEQOS");
    y += 7;
    center(buf, body, y, &format!("{}  Installation complete", th.check()), th.b(OK, BG));
    y += 2;
    center(buf, body, y, "Remove the install medium and restart to boot FasdeqOS", th.s(TEXT, BG));
    y += 1;
    center(buf, body, y, "With Secure Boot on, enroll FASDEQOS-MOK.cer from the boot partition on first start", th.s(DIM, BG));
    y += 3;
    let labels = ["  Restart now  ", "  Stay in live system  "];
    let total = tw(labels[0]) + tw(labels[1]) + 4;
    let mut x = body.x + (body.width.saturating_sub(total as u16)) / 2;
    for (i, l) in labels.iter().enumerate() {
        let sel = app.done_btn == i;
        let st = if sel { th.b((24, 10, 4), (255, 196, 40)) } else { th.s(DIM, HI) };
        fill(buf, Rect::new(x, y, tw(l) as u16, 1), st);
        x = put(buf, x, y, l, st, 40) + 4;
    }
    keycaps(buf, th, body, foot_y, &[("← →", "choose"), ("Enter", "select")]);
}

fn draw_failed(buf: &mut Buffer, th: &Th, app: &App, body: Rect, foot_y: u16) {
    let w = body.width.saturating_sub(4).min(90);
    let h = body.height.saturating_sub(2).min(20);
    let r = Rect::new(body.x + (body.width - w) / 2, body.y + 1, w, h);
    fill(buf, r, th.s(TEXT, PANEL));
    border(buf, th, r, Line::Double, true, PANEL, None);
    put(buf, r.x + 3, r.y + 1, &format!("{} Installation failed", th.warn()), th.b(RED, PANEL), r.width as usize - 6);
    if let Some(e) = &app.prog.err {
        put(buf, r.x + 3, r.y + 3, e, th.b(TEXT, PANEL), r.width as usize - 6);
    }
    let n = h as usize - 7;
    for (i, l) in app.prog.log.iter().rev().take(n).rev().enumerate() {
        put(buf, r.x + 3, r.y + 5 + i as u16, l, th.s(DIM, PANEL), r.width as usize - 6);
    }
    keycaps(buf, th, body, foot_y, &[("Enter", "go to shell")]);
}
