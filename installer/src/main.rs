mod app;
mod data;
mod font;
mod ui;

use app::{Act, App, Screen};
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use std::process::Command;
use std::time::Duration;

fn to_act(k: event::KeyEvent, typing: bool) -> Option<Act> {
    if k.kind == KeyEventKind::Release {
        return None;
    }
    Some(match k.code {
        KeyCode::Up => Act::Up,
        KeyCode::Down => Act::Down,
        KeyCode::Left => Act::Left,
        KeyCode::Right => Act::Right,
        KeyCode::Enter => Act::Enter,
        KeyCode::Esc => Act::Esc,
        KeyCode::Tab => Act::Tab,
        KeyCode::BackTab => Act::BackTab,
        KeyCode::Backspace => Act::Bksp,
        KeyCode::Char(c) => {
            if typing {
                Act::Char(c)
            } else {
                match c {
                    'w' | 'k' | 'W' | 'K' => Act::Up,
                    's' | 'j' | 'S' | 'J' => Act::Down,
                    'a' | 'h' | 'A' | 'H' => Act::Left,
                    'd' | 'l' | 'D' | 'L' => Act::Right,
                    ' ' => Act::Enter,
                    c => Act::Char(c),
                }
            }
        }
        _ => return None,
    })
}

fn main() {
    let term = std::env::var("TERM").unwrap_or_default();
    let vt = term == "linux" || std::env::var("FASDEQ_VT").is_ok();
    let demo = std::env::var("FASDEQ_DEMO").is_ok();
    font::init(vt);
    let mut app = App::new(vt, demo);
    let mut terminal = ratatui::init();
    loop {
        let _ = terminal.draw(|f| ui::draw(f, &app));
        if event::poll(Duration::from_millis(70)).unwrap_or(false) {
            if let Ok(Event::Key(k)) = event::read() {
                if k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char('c') && app.screen != Screen::Install {
                    break;
                }
                if let Some(a) = to_act(k, app.typing()) {
                    app.on_act(a);
                }
            }
        }
        app.tick += 1;
        if app.screen == Screen::Install {
            app.poll_install();
        }
        if app.quit {
            break;
        }
    }
    ratatui::restore();
    if app.reboot {
        let _ = Command::new("reboot").status();
    }
}
