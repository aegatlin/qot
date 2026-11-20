//! `qot web`: opens the web app in the browser. Which address and which
//! opener are pure rules; `open` is the I/O.

use std::process::Command;

pub const PRODUCTION_APP: &str = "https://app.quantumofthought.com";

/// The web app that goes with a server: the address the server gave at
/// sign-in if it was kept, else the ones known for qot's own servers (a
/// sign-in made before addresses were kept). `None` for any other server.
pub fn app_url(server_label: &str, saved: Option<&str>) -> Option<String> {
    if let Some(url) = saved.filter(|u| !u.trim().is_empty()) {
        return Some(url.to_string());
    }
    match server_label {
        "production" => Some(PRODUCTION_APP.to_string()),
        "staging" => Some("https://staging-app.quantumofthought.com".to_string()),
        "local" => Some("http://localhost:5173".to_string()),
        _ => None,
    }
}

/// The command that opens an address: `$BROWSER` if it isn't empty (a
/// command line, run through `sh`), else the system's opener.
pub fn opener(browser: Option<String>, os: &str) -> String {
    browser
        .filter(|b| !b.trim().is_empty())
        .unwrap_or_else(|| match os {
            "macos" => "open".to_string(),
            _ => "xdg-open".to_string(),
        })
}

pub fn open(command: &str, url: &str) -> Result<(), String> {
    // The address is an argument, never spliced into the script.
    let status = Command::new("sh")
        .arg("-c")
        .arg(format!("{command} \"$1\""))
        .arg("qot")
        .arg(url)
        .status()
        .map_err(|e| format!("Can't start the browser ({command}): {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "Couldn't open a browser ({command}). Open the address above yourself, \
             or set BROWSER to a command that opens one."
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_saved_address_wins() {
        assert_eq!(
            app_url("production", Some("https://notes.example.com")).as_deref(),
            Some("https://notes.example.com")
        );
    }

    #[test]
    fn known_servers_have_known_apps() {
        assert_eq!(app_url("production", None).as_deref(), Some(PRODUCTION_APP));
        assert_eq!(
            app_url("staging", Some(" ")).as_deref(),
            Some("https://staging-app.quantumofthought.com")
        );
        assert_eq!(app_url("custom", None), None);
    }

    #[test]
    fn the_opener_is_browser_else_the_systems() {
        assert_eq!(
            opener(Some("firefox --new-tab".into()), "macos"),
            "firefox --new-tab"
        );
        assert_eq!(opener(Some("".into()), "macos"), "open");
        assert_eq!(opener(None, "linux"), "xdg-open");
    }
}
