use crate::data::{self, Desktop, Disk};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::process::{Command, Stdio};
use std::sync::mpsc::{channel, Receiver};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq)]
pub enum Item {
    Disk,
    Env,
    Locale,
    Tz,
    Root,
    User,
    Swap,
    Shell,
}

pub const SHELLS: [(&str, &str, &str); 4] = [
    ("none", "No extra shell", "Keep the compositor default and set things up yourself"),
    ("waybar", "Waybar", "Classic status bar, light and configurable"),
    ("noctalia", "Noctalia", "Complete Quickshell desktop shell, downloaded from GitHub"),
    ("dms", "DankMaterialShell", "Complete Quickshell desktop shell, downloaded from GitHub"),
];

pub fn is_wm(n: &str) -> bool {
    false && n == "niri"
}

impl Item {
    pub fn title(self) -> &'static str {
        match self {
            Item::Disk => "Disk",
            Item::Env => "Desktop",
            Item::Locale => "Language",
            Item::Tz => "Time zone",
            Item::Root => "Root password",
            Item::User => "User account",
            Item::Swap => "Swap & zram",
            Item::Shell => "Shell / bar",
        }
    }
    pub fn sub(self) -> &'static str {
        match self {
            Item::Disk => "Choose where FasdeqOS will be installed",
            Item::Env => "Pick the desktop environment",
            Item::Locale => "System language and regional formats",
            Item::Tz => "Where in the world are you",
            Item::Root => "Password for the administrator account",
            Item::User => "Your everyday account",
            Item::Swap => "Compressed memory and swap file",
            Item::Shell => "Optional panel and launcher for this window manager",
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Screen {
    Mode,
    Flow,
    Summary,
    Install,
    Done,
    Failed,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Act {
    Up,
    Down,
    Left,
    Right,
    Enter,
    Esc,
    Tab,
    BackTab,
    Bksp,
    Char(char),
}

#[derive(Default, Clone)]
pub struct ListState {
    pub cur: usize,
    pub filter: String,
    pub filtering: bool,
}

pub struct SwapState {
    pub mode: usize,
    pub zsize: usize,
    pub zalgo: usize,
    pub fsize: usize,
    pub custom_z: u64,
    pub custom_f: u64,
    pub row: usize,
    pub editing: bool,
    pub buf: String,
}

pub const SWAP_MODES: [&str; 4] = ["zram + swap file", "zram only", "swap file only", "no swap"];
pub const ZSIZES: [&str; 4] = ["25% of RAM", "50% of RAM", "100% of RAM", "Custom"];
pub const ZALGOS: [&str; 3] = ["zstd", "lz4", "lzo-rle"];
pub const FSIZES: [&str; 5] = ["2 GB", "4 GB", "8 GB", "16 GB", "Custom"];

pub enum Msg {
    Plan(Vec<String>),
    Step(usize, usize, String),
    Pct(u32),
    Log(String),
    Done,
    Err(String),
}

pub struct Progress {
    pub steps: Vec<String>,
    pub step: usize,
    pub pct: u32,
    pub log: Vec<String>,
    pub err: Option<String>,
    pub start: Instant,
    pub rx: Option<Receiver<Msg>>,
}

pub struct App {
    pub vt: bool,
    pub demo: bool,
    pub tick: u64,
    pub screen: Screen,
    pub mode_cur: usize,
    pub express: bool,
    pub flow: Vec<Item>,
    pub cur: usize,
    pub side: bool,
    pub disks: Vec<Disk>,
    pub desks: Vec<Desktop>,
    pub tzs: Vec<String>,
    pub disk_l: ListState,
    pub env_l: ListState,
    pub shell_l: ListState,
    pub sel_shell: usize,
    pub loc_l: ListState,
    pub tz_l: ListState,
    pub sel_disk: Option<usize>,
    pub sel_env: usize,
    pub sel_loc: usize,
    pub sel_tz: usize,
    pub root: [String; 2],
    pub root_f: usize,
    pub root_set: bool,
    pub user: [String; 4],
    pub user_f: usize,
    pub user_set: bool,
    pub swap: SwapState,
    pub msg: Option<String>,
    pub sum_btn: usize,
    pub sum_confirm: bool,
    pub done_btn: usize,
    pub prog: Progress,
    pub ram: u64,
    pub quit: bool,
    pub reboot: bool,
}

pub const ALL: [Item; 6] = [Item::Disk, Item::Locale, Item::Tz, Item::Root, Item::User, Item::Swap];
pub const EXPRESS: [Item; 5] = [Item::Disk, Item::Locale, Item::Tz, Item::Root, Item::User];

fn strength(p: &str) -> usize {
    let mut s = 0;
    if p.len() >= 6 {
        s += 1;
    }
    if p.len() >= 10 {
        s += 1;
    }
    if p.chars().any(|c| c.is_ascii_uppercase()) && p.chars().any(|c| c.is_ascii_lowercase()) {
        s += 1;
    }
    if p.chars().any(|c| c.is_ascii_digit()) {
        s += 1;
    }
    if p.chars().any(|c| !c.is_alphanumeric()) {
        s += 1;
    }
    if p.is_empty() {
        0
    } else {
        s.max(1)
    }
}

pub fn pw_strength(p: &str) -> usize {
    strength(p)
}

fn valid_user(u: &str) -> bool {
    let mut ch = u.chars();
    match ch.next() {
        Some(c) if c.is_ascii_lowercase() || c == '_' => {}
        _ => return false,
    }
    u.len() <= 32 && ch.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn valid_host(h: &str) -> bool {
    !h.is_empty() && h.len() <= 63 && h.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') && !h.starts_with('-')
}

impl App {
    pub fn new(vt: bool, demo: bool) -> App {
        let tzs = data::timezones();
        let utc = tzs.iter().position(|t| t == "UTC").unwrap_or(0);
        let mut desks = data::desktops();
        if desks.is_empty() {
            desks = data::desktops();
        }
        let mut tz_l = ListState::default();
        tz_l.cur = utc;
        App {
            vt,
            demo,
            tick: 0,
            screen: Screen::Mode,
            mode_cur: 1,
            express: false,
            flow: ALL.to_vec(),
            cur: 0,
            side: true,
            disks: data::disks(demo),
            desks,
            tzs,
            disk_l: ListState::default(),
            env_l: ListState::default(),
            shell_l: ListState::default(),
            sel_shell: 0,
            loc_l: ListState::default(),
            tz_l,
            sel_disk: None,
            sel_env: 0,
            sel_loc: 0,
            sel_tz: utc,
            root: [String::new(), String::new()],
            root_f: 0,
            root_set: false,
            user: [String::new(), "fasdeqos".to_string(), String::new(), String::new()],
            user_f: 0,
            user_set: false,
            swap: SwapState { mode: 1, zsize: 1, zalgo: 0, fsize: 1, custom_z: 4, custom_f: 4, row: 0, editing: false, buf: String::new() },
            msg: None,
            sum_btn: 0,
            sum_confirm: false,
            done_btn: 0,
            prog: Progress { steps: vec![], step: 0, pct: 0, log: vec![], err: None, start: Instant::now(), rx: None },
            ram: data::ram_mb(),
            quit: false,
            reboot: false,
        }
    }

    pub fn item(&self) -> Item {
        self.flow[self.cur.min(self.flow.len() - 1)]
    }

    pub fn labels(&self, it: Item) -> Vec<String> {
        match it {
            Item::Disk => self.disks.iter().map(|d| format!("{} {}", d.name, d.model)).collect(),
            Item::Env => self.desks.iter().map(|d| format!("{} {}", d.name, d.title)).collect(),
            Item::Shell => SHELLS.iter().map(|x| format!("{} {}", x.1, x.2)).collect(),
            Item::Locale => data::LOCALES.iter().map(|l| format!("{} {} {}", l.0, l.1, l.2)).collect(),
            Item::Tz => self.tzs.clone(),
            _ => vec![],
        }
    }

    pub fn list_of(&mut self, it: Item) -> &mut ListState {
        match it {
            Item::Disk => &mut self.disk_l,
            Item::Env => &mut self.env_l,
            Item::Shell => &mut self.shell_l,
            Item::Locale => &mut self.loc_l,
            _ => &mut self.tz_l,
        }
    }

    pub fn visible(&self, it: Item) -> Vec<usize> {
        let f = match it {
            Item::Disk => &self.disk_l.filter,
            Item::Env => &self.env_l.filter,
            Item::Shell => &self.shell_l.filter,
            Item::Locale => &self.loc_l.filter,
            _ => &self.tz_l.filter,
        }
        .to_lowercase();
        self.labels(it)
            .iter()
            .enumerate()
            .filter(|(_, s)| f.is_empty() || s.to_lowercase().contains(&f))
            .map(|(i, _)| i)
            .collect()
    }

    pub fn typing(&self) -> bool {
        if self.screen != Screen::Flow || (self.side && !self.express) {
            return false;
        }
        match self.item() {
            Item::Root | Item::User => true,
            Item::Swap => self.swap.editing,
            Item::Disk | Item::Shell => false,
            Item::Env => self.env_l.filtering,
            Item::Locale => self.loc_l.filtering,
            Item::Tz => self.tz_l.filtering,
        }
    }

    pub fn zram_mb(&self) -> u64 {
        match self.swap.mode {
            0 | 1 => match self.swap.zsize {
                0 => self.ram / 4,
                1 => self.ram / 2,
                2 => self.ram,
                _ => self.swap.custom_z * 1024,
            },
            _ => 0,
        }
    }

    pub fn file_mb(&self) -> u64 {
        match self.swap.mode {
            0 | 2 => match self.swap.fsize {
                0 => 2048,
                1 => 4096,
                2 => 8192,
                3 => 16384,
                _ => self.swap.custom_f * 1024,
            },
            _ => 0,
        }
    }

    pub fn desk_name(&self) -> String {
        if self.express {
            return "niri".to_string();
        }
        self.desks.get(self.sel_env).map(|d| d.name.clone()).unwrap_or_else(|| "none".into())
    }

    pub fn desk_title(&self) -> String {
        let n = self.desk_name();
        self.desks.iter().find(|d| d.name == n).map(|d| d.title.clone()).unwrap_or(n)
    }

    pub fn value_of(&self, it: Item) -> String {
        match it {
            Item::Disk => self.sel_disk.and_then(|i| self.disks.get(i)).map(|d| format!("{} · {}", d.name, data::fmt_size(d.size))).unwrap_or_default(),
            Item::Env => self.desk_title(),
            Item::Shell => SHELLS[self.sel_shell].1.to_string(),
            Item::Locale => data::LOCALES[self.sel_loc].0.to_string(),
            Item::Tz => self.tzs[self.sel_tz].clone(),
            Item::Root => if self.root_set { "set".into() } else { String::new() },
            Item::User => if self.user_set { format!("{}@{}", self.user[0], self.user[1]) } else { String::new() },
            Item::Swap => {
                let z = self.zram_mb();
                let f = self.file_mb();
                match (z > 0, f > 0) {
                    (true, true) => format!("zram {} + file {}", mb(z), mb(f)),
                    (true, false) => format!("zram {} {}", mb(z), ZALGOS[self.swap.zalgo]),
                    (false, true) => format!("file {}", mb(f)),
                    _ => "none".into(),
                }
            }
        }
    }

    pub fn is_set(&self, it: Item) -> bool {
        match it {
            Item::Disk => self.sel_disk.is_some(),
            Item::Root => self.root_set,
            Item::User => self.user_set,
            _ => true,
        }
    }

    pub fn missing(&self) -> Vec<&'static str> {
        self.flow.iter().filter(|i| !self.is_set(**i)).map(|i| i.title()).collect()
    }

    pub fn start_express(&mut self) {
        self.express = true;
        self.flow = EXPRESS.to_vec();
        self.cur = 0;
        self.side = false;
        self.msg = None;
        self.screen = Screen::Flow;
    }

    pub fn sync_flow(&mut self) {
        if self.express {
            return;
        }
        self.flow = ALL.to_vec();
        if is_wm(&self.desk_name()) {
            self.flow.push(Item::Shell);
        } else {
            self.sel_shell = 0;
        }
    }

    pub fn start_advanced(&mut self) {
        self.express = false;
        self.flow = ALL.to_vec();
        self.cur = 0;
        self.side = true;
        self.msg = None;
        self.sync_flow();
        self.screen = Screen::Flow;
    }

    pub fn on_act(&mut self, a: Act) {
        match self.screen {
            Screen::Mode => self.act_mode(a),
            Screen::Flow => self.act_flow(a),
            Screen::Summary => self.act_summary(a),
            Screen::Install => {}
            Screen::Done => match a {
                Act::Left | Act::Right | Act::Tab | Act::BackTab | Act::Up | Act::Down => self.done_btn = 1 - self.done_btn,
                Act::Enter => {
                    self.reboot = self.done_btn == 0;
                    self.quit = true;
                }
                _ => {}
            },
            Screen::Failed => {
                if a == Act::Enter || a == Act::Esc {
                    self.quit = true;
                }
            }
        }
    }

    fn act_mode(&mut self, a: Act) {
        match a {
            Act::Left | Act::Up | Act::BackTab => self.mode_cur = (self.mode_cur + 2) % 3,
            Act::Right | Act::Down | Act::Tab => self.mode_cur = (self.mode_cur + 1) % 3,
            Act::Char('1') => self.mode_cur = 0,
            Act::Char('2') => self.mode_cur = 1,
            Act::Char('3') => self.mode_cur = 2,
            Act::Esc | Act::Char('q') => self.quit = true,
            Act::Enter => match self.mode_cur {
                0 => self.start_express(),
                1 => self.start_advanced(),
                _ => self.quit = true,
            },
            _ => {}
        }
    }

    fn go_summary(&mut self) {
        let m = self.missing();
        if !m.is_empty() {
            self.msg = Some(format!("Still needed: {}", m.join(", ")));
            return;
        }
        self.msg = None;
        self.sum_btn = 0;
        self.sum_confirm = false;
        self.screen = Screen::Summary;
    }

    fn commit(&mut self) {
        self.msg = None;
        if self.express {
            if self.cur + 1 >= self.flow.len() {
                self.go_summary();
            } else {
                self.cur += 1;
            }
        } else {
            self.side = true;
            if self.cur < self.flow.len() {
                self.cur += 1;
            }
        }
    }

    fn back(&mut self) {
        self.msg = None;
        if self.express {
            if self.cur == 0 {
                self.screen = Screen::Mode;
            } else {
                self.cur -= 1;
            }
        } else {
            self.side = true;
        }
    }

    fn act_flow(&mut self, a: Act) {
        if self.side && !self.express {
            let n = self.flow.len() + 1;
            match a {
                Act::Up | Act::BackTab => self.cur = (self.cur + n - 1) % n,
                Act::Down | Act::Tab => self.cur = (self.cur + 1) % n,
                Act::Esc | Act::Left | Act::Char('q') => self.screen = Screen::Mode,
                Act::Enter | Act::Right => {
                    if self.cur == self.flow.len() {
                        self.go_summary();
                    } else {
                        self.side = false;
                        self.msg = None;
                    }
                }
                Act::Char(c) if c.is_ascii_digit() => {
                    let d = c as usize - '0' as usize;
                    if d >= 1 && d <= self.flow.len() {
                        self.cur = d - 1;
                    }
                }
                _ => {}
            }
            return;
        }
        let it = self.item();
        match it {
            Item::Disk | Item::Env | Item::Shell | Item::Locale | Item::Tz => self.act_list(it, a),
            Item::Root => self.act_root(a),
            Item::User => self.act_user(a),
            Item::Swap => self.act_swap(a),
        }
    }

    fn act_list(&mut self, it: Item, a: Act) {
        let vis = self.visible(it);
        let n = vis.len();
        let filtering = self.list_of(it).filtering;
        if filtering {
            let l = self.list_of(it);
            match a {
                Act::Char(c) => {
                    l.filter.push(c);
                    l.cur = 0;
                }
                Act::Bksp => {
                    l.filter.pop();
                    l.cur = 0;
                }
                Act::Enter | Act::Esc => l.filtering = false,
                Act::Up | Act::BackTab => l.cur = if n == 0 { 0 } else { (l.cur + n - 1) % n },
                Act::Down | Act::Tab => l.cur = if n == 0 { 0 } else { (l.cur + 1) % n },
                _ => {}
            }
            return;
        }
        match a {
            Act::Up | Act::BackTab => {
                let l = self.list_of(it);
                l.cur = if n == 0 { 0 } else { (l.cur + n - 1) % n };
            }
            Act::Down | Act::Tab => {
                let l = self.list_of(it);
                l.cur = if n == 0 { 0 } else { (l.cur + 1) % n };
            }
            Act::Char('/') if it != Item::Disk && it != Item::Shell => self.list_of(it).filtering = true,
            Act::Esc | Act::Left => self.back(),
            Act::Enter | Act::Right => {
                let cur = self.list_of(it).cur;
                if let Some(&idx) = vis.get(cur) {
                    match it {
                        Item::Disk => self.sel_disk = Some(idx),
                        Item::Env => {
                            self.sel_env = idx;
                            self.sync_flow();
                        }
                        Item::Shell => self.sel_shell = idx,
                        Item::Locale => self.sel_loc = idx,
                        _ => self.sel_tz = idx,
                    }
                    self.commit();
                }
            }
            _ => {}
        }
    }

    fn field_input(s: &mut String, a: Act, max: usize) {
        match a {
            Act::Char(c) if !c.is_control() && s.chars().count() < max => s.push(c),
            Act::Bksp => {
                s.pop();
            }
            _ => {}
        }
    }

    fn act_root(&mut self, a: Act) {
        self.msg = None;
        match a {
            Act::Up | Act::BackTab => self.root_f = 0,
            Act::Down | Act::Tab => self.root_f = 1,
            Act::Esc | Act::Left => self.back(),
            Act::Enter => {
                if self.root_f == 0 {
                    if self.root[0].is_empty() {
                        self.msg = Some("Password cannot be empty".into());
                    } else {
                        self.root_f = 1;
                    }
                } else if self.root[0] != self.root[1] {
                    self.msg = Some("Passwords do not match".into());
                } else if self.root[0].is_empty() {
                    self.msg = Some("Password cannot be empty".into());
                } else {
                    self.root_set = true;
                    self.root_f = 0;
                    self.commit();
                }
            }
            _ => {
                let f = self.root_f;
                Self::field_input(&mut self.root[f], a, 64);
                self.root_set = false;
            }
        }
    }

    fn act_user(&mut self, a: Act) {
        self.msg = None;
        match a {
            Act::Up | Act::BackTab => self.user_f = (self.user_f + 3) % 4,
            Act::Down | Act::Tab => self.user_f = (self.user_f + 1) % 4,
            Act::Esc | Act::Left => self.back(),
            Act::Enter => {
                if self.user_f < 3 {
                    self.user_f += 1;
                    return;
                }
                if !valid_user(&self.user[0]) {
                    self.msg = Some("Username: lowercase letters, digits, - and _, starting with a letter".into());
                    self.user_f = 0;
                } else if !valid_host(&self.user[1]) {
                    self.msg = Some("Computer name: letters, digits and -".into());
                    self.user_f = 1;
                } else if self.user[2].is_empty() {
                    self.msg = Some("Password cannot be empty".into());
                    self.user_f = 2;
                } else if self.user[2] != self.user[3] {
                    self.msg = Some("Passwords do not match".into());
                    self.user_f = 3;
                } else {
                    self.user_set = true;
                    self.user_f = 0;
                    self.commit();
                }
            }
            _ => {
                let f = self.user_f;
                Self::field_input(&mut self.user[f], a, if f == 1 { 63 } else { 64 });
                self.user_set = false;
            }
        }
    }

    fn swap_rows(&self) -> Vec<usize> {
        match self.swap.mode {
            0 => vec![0, 1, 2, 3, 4],
            1 => vec![0, 1, 2, 4],
            2 => vec![0, 3, 4],
            _ => vec![0, 4],
        }
    }

    pub fn swap_row_list(&self) -> Vec<usize> {
        self.swap_rows()
    }

    fn cycle(v: &mut usize, n: usize, fwd: bool) {
        *v = if fwd { (*v + 1) % n } else { (*v + n - 1) % n };
    }

    fn act_swap(&mut self, a: Act) {
        if self.swap.editing {
            match a {
                Act::Char(c) if c.is_ascii_digit() && self.swap.buf.len() < 3 => self.swap.buf.push(c),
                Act::Bksp => {
                    self.swap.buf.pop();
                }
                Act::Esc => self.swap.editing = false,
                Act::Enter => {
                    let v: u64 = self.swap.buf.parse().unwrap_or(0);
                    if v == 0 {
                        self.msg = Some("Enter a size in GB".into());
                    } else {
                        if self.swap.row == 2 {
                            self.swap.custom_z = v;
                        } else {
                            self.swap.custom_f = v;
                        }
                        self.swap.editing = false;
                        self.msg = None;
                    }
                }
                _ => {}
            }
            return;
        }
        let rows = self.swap_rows();
        if !rows.contains(&self.swap.row) {
            self.swap.row = rows[0];
        }
        let pos = rows.iter().position(|r| *r == self.swap.row).unwrap_or(0);
        match a {
            Act::Up | Act::BackTab => self.swap.row = rows[(pos + rows.len() - 1) % rows.len()],
            Act::Down | Act::Tab => self.swap.row = rows[(pos + 1) % rows.len()],
            Act::Esc => self.back(),
            Act::Left | Act::Right => {
                let fwd = a == Act::Right;
                match self.swap.row {
                    0 => Self::cycle(&mut self.swap.mode, 4, fwd),
                    1 => Self::cycle(&mut self.swap.zalgo, 3, fwd),
                    2 => Self::cycle(&mut self.swap.zsize, 4, fwd),
                    3 => Self::cycle(&mut self.swap.fsize, 5, fwd),
                    _ => {}
                }
            }
            Act::Enter => match self.swap.row {
                2 if self.swap.zsize == 3 => {
                    self.swap.editing = true;
                    self.swap.buf = self.swap.custom_z.to_string();
                }
                3 if self.swap.fsize == 4 => {
                    self.swap.editing = true;
                    self.swap.buf = self.swap.custom_f.to_string();
                }
                4 => self.commit(),
                0 => Self::cycle(&mut self.swap.mode, 4, true),
                1 => Self::cycle(&mut self.swap.zalgo, 3, true),
                2 => Self::cycle(&mut self.swap.zsize, 4, true),
                _ => Self::cycle(&mut self.swap.fsize, 5, true),
            },
            _ => {}
        }
    }

    fn act_summary(&mut self, a: Act) {
        match a {
            Act::Left | Act::Right | Act::Tab | Act::BackTab | Act::Up | Act::Down => {
                self.sum_btn = 1 - self.sum_btn;
                self.sum_confirm = false;
            }
            Act::Esc => {
                self.sum_confirm = false;
                self.leave_summary();
            }
            Act::Enter => {
                if self.sum_btn == 1 {
                    self.leave_summary();
                } else if !self.sum_confirm {
                    self.sum_confirm = true;
                } else {
                    self.start_install();
                }
            }
            _ => {}
        }
    }

    fn leave_summary(&mut self) {
        self.screen = Screen::Flow;
        if self.express {
            self.cur = self.flow.len() - 1;
        } else {
            self.side = true;
            self.cur = self.flow.len();
        }
    }

    fn q(s: &str) -> String {
        format!("'{}'", s.replace('\'', "'\\''"))
    }

    pub fn start_install(&mut self) {
        self.screen = Screen::Install;
        self.prog = Progress { steps: vec![], step: 0, pct: 0, log: vec![], err: None, start: Instant::now(), rx: None };
        let (tx, rx) = channel::<Msg>();
        self.prog.rx = Some(rx);
        if self.demo {
            thread::spawn(move || {
                let steps = ["Partitioning disk", "Creating file systems", "Copying the system", "Configuring accounts", "Locale, time zone and swap", "Installing the boot loader"];
                let _ = tx.send(Msg::Plan(steps.iter().map(|s| s.to_string()).collect()));
                for (i, s) in steps.iter().enumerate() {
                    let _ = tx.send(Msg::Step(i + 1, steps.len(), s.to_string()));
                    for p in 0..=20 {
                        let _ = tx.send(Msg::Pct(((i * 20 + p) * 100 / (steps.len() * 20)) as u32));
                        if p % 5 == 0 {
                            let _ = tx.send(Msg::Log(format!("{} ... {}", s.to_lowercase(), p * 5)));
                        }
                        thread::sleep(Duration::from_millis(if std::env::var("FASDEQ_FAIL").is_ok() && i == 3 { 10 } else { 90 }));
                    }
                    if std::env::var("FASDEQ_FAIL").is_ok() && i == 3 {
                        let _ = tx.send(Msg::Err("demo failure".into()));
                        return;
                    }
                }
                let _ = tx.send(Msg::Pct(100));
                let _ = tx.send(Msg::Done);
            });
            return;
        }
        let disk = self.sel_disk.and_then(|i| self.disks.get(i)).map(|d| d.name.clone()).unwrap_or_default();
        let conf = format!(
            "DISK={}\nDESKTOP={}\nLOCALE={}\nTIMEZONE={}\nHOSTNAME={}\nUSERNAME={}\nROOT_HASH={}\nUSER_HASH={}\nZRAM_MB={}\nZRAM_ALGO={}\nSWAPFILE_MB={}\n",
            Self::q(&format!("/dev/{}", disk)),
            Self::q(&self.desk_name()),
            Self::q(data::LOCALES[self.sel_loc].0),
            Self::q(&self.tzs[self.sel_tz]),
            Self::q(&self.user[1]),
            Self::q(&self.user[0]),
            Self::q(&data::hash_password(&self.root[0])),
            Self::q(&data::hash_password(&self.user[2])),
            self.zram_mb(),
            Self::q(ZALGOS[self.swap.zalgo]),
            self.file_mb()
        );
        let dir = if fs::metadata("/System/tmp").is_ok() { "/System/tmp" } else { "/tmp" };
        let path = format!("{}/fasdeq-install.conf", dir);
        let _ = fs::remove_file(&path);
        let w = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).and_then(|mut f| f.write_all(conf.as_bytes()));
        if let Err(e) = w {
            let _ = tx.send(Msg::Err(format!("cannot write configuration: {}", e)));
            return;
        }
        let backend = std::env::var("FASDEQ_BACKEND").unwrap_or_else(|_| "/System/libexec/fasdeqos/fasdeq-install".into());
        let root = fs::metadata("/proc/self").map(|m| m.uid() == 0).unwrap_or(false);
        let cmd = format!("exec {}{} {} 2>&1", if root { "" } else { "doas " }, backend, path);
        thread::spawn(move || {
            let child = Command::new("sh").arg("-c").arg(cmd).stdout(Stdio::piped()).stdin(Stdio::null()).spawn();
            let mut child = match child {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(Msg::Err(format!("cannot start installer backend: {}", e)));
                    return;
                }
            };
            let out = child.stdout.take().unwrap();
            let mut finished = false;
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if let Some(r) = line.strip_prefix("@PLAN ") {
                    let _ = tx.send(Msg::Plan(r.split('|').map(|s| s.to_string()).collect()));
                } else if let Some(r) = line.strip_prefix("@STEP ") {
                    let mut p = r.splitn(3, ' ');
                    let i = p.next().and_then(|x| x.parse().ok()).unwrap_or(1);
                    let n = p.next().and_then(|x| x.parse().ok()).unwrap_or(1);
                    let _ = tx.send(Msg::Step(i, n, p.next().unwrap_or("").to_string()));
                } else if let Some(r) = line.strip_prefix("@PCT ") {
                    let _ = tx.send(Msg::Pct(r.trim().parse().unwrap_or(0)));
                } else if let Some(r) = line.strip_prefix("@ERR ") {
                    let _ = tx.send(Msg::Err(r.to_string()));
                    finished = true;
                } else if line.starts_with("@DONE") {
                    let _ = tx.send(Msg::Done);
                    finished = true;
                } else {
                    let l = line.strip_prefix("@LOG ").unwrap_or(&line).to_string();
                    let _ = tx.send(Msg::Log(l));
                }
            }
            let st = child.wait();
            if !finished {
                let ok = st.map(|s| s.success()).unwrap_or(false);
                let _ = tx.send(if ok { Msg::Done } else { Msg::Err("installer backend exited unexpectedly".into()) });
            }
        });
    }

    pub fn poll_install(&mut self) {
        let mut msgs = Vec::new();
        if let Some(rx) = &self.prog.rx {
            while let Ok(m) = rx.try_recv() {
                msgs.push(m);
            }
        }
        for m in msgs {
            match m {
                Msg::Plan(p) => self.prog.steps = p,
                Msg::Step(i, _, l) => {
                    self.prog.step = i;
                    if i >= 1 && i <= self.prog.steps.len() {
                        self.prog.steps[i - 1] = l;
                    } else if self.prog.steps.len() < i {
                        self.prog.steps.push(l);
                    }
                }
                Msg::Pct(p) => self.prog.pct = p.min(100),
                Msg::Log(l) => {
                    self.prog.log.push(l);
                    if self.prog.log.len() > 200 {
                        self.prog.log.remove(0);
                    }
                }
                Msg::Done => {
                    self.prog.pct = 100;
                    self.prog.step = self.prog.steps.len() + 1;
                    self.screen = Screen::Done;
                    self.prog.rx = None;
                    self.wipe();
                    break;
                }
                Msg::Err(e) => {
                    self.prog.err = Some(e);
                    self.screen = Screen::Failed;
                    self.prog.rx = None;
                    self.wipe();
                    break;
                }
            }
        }
    }

    fn wipe(&mut self) {
        self.root = [String::new(), String::new()];
        self.user[2].clear();
        self.user[3].clear();
    }
}

pub fn mb(v: u64) -> String {
    if v >= 1024 && v % 1024 == 0 {
        format!("{} GB", v / 1024)
    } else if v >= 1024 {
        format!("{:.1} GB", v as f64 / 1024.0)
    } else {
        format!("{} MB", v)
    }
}

impl App {
    pub fn flow_cur_list(&self, it: Item) -> usize {
        match it {
            Item::Disk => self.disk_l.cur,
            Item::Env => self.env_l.cur,
            Item::Shell => self.shell_l.cur,
            Item::Locale => self.loc_l.cur,
            _ => self.tz_l.cur,
        }
    }
}
