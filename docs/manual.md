# SSH connection notify (macOS)

This document describes the **SSH / TCP port 22 watcher**: what it does, how to install it, and how to tune it on another Mac.

---

## Purpose

Get **Notification Center** alerts when:

1. **A new inbound TCP connection** is established to **local port 22** (SSH server), with the **remote peer** (IP:port) identified from `lsof` / `netstat`.
2. **SSH authentication / pre-auth style events** appear in the **unified log** (e.g. invalid user, failed auth, KEX issues), without turning on **`sshd` LogLevel DEBUG** or writing huge verbose log files.

Optional: **click the notification** to **`open`** the human-readable log file (requires **`terminal-notifier`** from Homebrew).

---

## How it works (short)

| Mechanism | What it watches | Disk impact |
|-----------|------------------|-------------|
| **Polling** every few seconds | `lsof` / `netstat` for **ESTABLISHED** sockets where the **local** side is **`:22->`** (inbound SSH), not outbound `ssh` client traffic | None beyond a small rotating log |
| **`log stream`** (background) | **`process`** **`sshd` / `sshd-session` / `sshd-auth`** **or** **`senderImagePath`** ending in **`/sshd`** or **`/sshd-auth`**. (Message-based predicates were removed: they can suppress failure lines on some systems while **`Accepted …`** still streams.) **`--level`** defaults to **`debug`** so failure lines (often **debug** in unified log) are not dropped while **`Accepted …`** (often **info**) still appears. Override with **`SSH_WATCH_AUTH_LOG_STREAM_LEVEL`**. | Stream only; no extra OpenSSH log files |

**Why two kinds of lines?** **TCP (`lsof`)** only knows **IP:port** — it does **not** know SSH **username** or **auth method**. Those appear in OpenSSH’s **`Accepted …`** messages (normally at default **INFO**), which the same **`log stream`** watches. Successful logins add **`event=auth_success`** with **`method=… user=… host=… port=…`** when the line matches the usual IPv4 form; otherwise a truncated raw line is stored.

State and logs live under the **user’s home directory** (see below).

---

## Requirements

- **macOS** (developed on **macOS 26.x**; should work on recent releases with bash 3.2+).
- **`bash`** at **`/bin/bash`**.
- **`/usr/bin/log`**, **`lsof`**, **`netstat`**, **`osascript`** (all part of macOS).
- **Remote Login (SSH)** enabled if you actually want inbound SSH (System Settings → General → Sharing → Remote Login).

### Optional (recommended)

- **Homebrew** — [https://brew.sh](https://brew.sh)
- **`terminal-notifier`** — for notifications whose **click** runs **`open`** on the log file:

  ```bash
  brew install terminal-notifier
  ```

Without **`terminal-notifier`**, notifications use **AppleScript** `display notification` (same look, **no** click-to-open).

---

## Files in this repository

| Path | Role |
|------|------|
| `ssh-connection-notify.sh` | Main bash script (TCP poll + `log stream` + notifications); copy to **`~/.ssh/script/`** for the LaunchAgent (see below) |
| `launchd/com.user.ssh-connection-notify.plist.example` | **LaunchAgent** template; copy to `~/Library/LaunchAgents/` and edit `YOUR_USERNAME` |

---

## Paths on your Mac (reference)

Adjust the plist so the **second** `ProgramArguments` string is the **absolute path** to the script on **your** account.

| Item | Example path |
|------|----------------|
| Script (used by LaunchAgent) | **`~/.ssh/script/ssh-connection-notify.sh`** (create the directory and **`cp`** the file from the repo when you install or update) |
| LaunchAgent plist (installed copy) | `~/Library/LaunchAgents/com.user.ssh-connection-notify.plist` |
| Per-user state directory | `~/.ssh-connection-notify/` |
| Main log file | `~/Library/Logs/ssh-connection-notify.log` |
| `log stream` stderr (debug) | `~/.ssh-connection-notify/log-stream.err` |
| LaunchAgent stdout | `/tmp/ssh-connection-notify.out.log` |
| LaunchAgent stderr | `/tmp/ssh-connection-notify.err.log` |

---

## Installation

### 1. Clone or copy this repository

Clone the repo to any path, or copy only `ssh-connection-notify.sh` and `launchd/com.user.ssh-connection-notify.plist.example`.

### 2. Install the script under `~/.ssh/script` (recommended)

```bash
mkdir -p ~/.ssh/script
cp /path/to/clone/ssh-connection-notify.sh ~/.ssh/script/
chmod +x ~/.ssh/script/ssh-connection-notify.sh
```

The LaunchAgent plist should point at **`~/.ssh/script/ssh-connection-notify.sh`** (as an absolute path). After you **update** the script in a new clone, **`cp`** it again to that path (or symlink if you prefer).

### 3. Install the LaunchAgent plist

Copy the example plist and edit **`YOUR_USERNAME`** (replace with your macOS account short name — same as the folder under `~/` or `/Users/`):

```bash
cp /path/to/clone/launchd/com.user.ssh-connection-notify.plist.example ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist
```

Open **`ProgramArguments`** so the **second string** is the **absolute path** to **`ssh-connection-notify.sh`** on **this** Mac.

Example (path matches **`~/.ssh/script`** install):

```xml
<key>ProgramArguments</key>
<array>
  <string>/bin/bash</string>
  <string>/Users/YOUR_USERNAME/.ssh/script/ssh-connection-notify.sh</string>
</array>
```

Keep **`EnvironmentVariables` → `PATH`** if you use Homebrew on Apple Silicon / Intel:

- Apple Silicon: `/opt/homebrew/bin` first  
- Intel Homebrew: often `/usr/local/bin`

### 4. (Optional) Install `terminal-notifier`

```bash
brew install terminal-notifier
```

Ensure **`command -v terminal-notifier`** works in Terminal. The plist’s **`PATH`** includes common Homebrew locations so the **LaunchAgent** can find it without extra setup.

### 5. Test in the foreground first

```bash
/path/to/ssh-connection-notify.sh
```

Trigger an SSH to this Mac from another host; confirm notifications and **`~/Library/Logs/ssh-connection-notify.log`**. Stop with **Ctrl+C**.

### 6. Load the LaunchAgent

(Plist should already be in **`~/Library/LaunchAgents/`** from step 3.)

macOS Ventura and later:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist
```

On older macOS:

```bash
launchctl load ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist
```

Verify:

```bash
launchctl list | grep ssh-connection-notify
```

### 7. Notifications permission

- **System Settings → Notifications** — allow **Script Editor** / **Terminal** / **terminal-notifier** as applicable so banners appear and (with **terminal-notifier**) clicks can run **`open`**.

---

## Environment variables (optional)

| Variable | Default | Meaning |
|----------|---------|---------|
| `SSH_WATCH_INTERVAL` | `3` | Seconds between TCP polls |
| `SSH_WATCH_LOG_MAX_LINES` | `5000` | Trim log when line count exceeds this |
| `SSH_WATCH_AUTH_LOGS` | `1` | Set **`0`** to disable the **`log stream`** auth watcher |
| `SSH_WATCH_AUTH_NOTIFY_COOLDOWN` | `0` | Seconds between **failure-style notification banners** **per client IPv4**. **`0`** = **no** throttling (one banner per matching log line). Set **`25`** (or similar) if one IP would otherwise flood Notification Center; the **log file** still records **every** attempt. Legacy alias: `SSH_WATCH_AUTH_COOLDOWN`. |
| `SSH_WATCH_AUTH_LOG_STREAM_LEVEL` | `debug` | **`log stream --level`**: **`default`**, **`info`**, or **`debug`**. Use **`debug`** (default) so invalid-user / failed-password lines are not missed; **`info`** alone often hides those while **`Accepted …`** still shows. |
| `SSH_WATCH_AUTH_STREAM_DEBUG` | `0` | Legacy: set **`1`** to force **`--level debug`** (same as **`SSH_WATCH_AUTH_LOG_STREAM_LEVEL=debug`**). |
| `SSH_WATCH_AUTH_SUCCESS_COOLDOWN` | `15` | Same for **successful** `Accepted …` lines (per client IPv4) |
| `SSH_WATCH_NOTIFY_USE_TERMINAL_NOTIFIER` | `1` | Set **`0`** to force **AppleScript** notifications only (no click-to-open) |

To set variables for the LaunchAgent, add a **`EnvironmentVariables`** dict in the plist (same pattern as **`PATH`**), or wrap the script.

---

## Limitations (know what you are not getting)

- **Supervision.** The main loop **restarts** the **`log stream`** + FIFO reader if either **exits** (otherwise auth alerts would stop forever while TCP polling kept running). Restarts append **`event=auth_stream_restart`** to **`~/Library/Logs/ssh-connection-notify.log`** and a line to **`/tmp/ssh-connection-notify.err.log`** (LaunchAgent stderr). **`launchctl list`** should show **`com.user.ssh-connection-notify`** with a **PID**; exit code **non-zero** means the job crashed—check stderr.
- **This Mac only, as SSH server.** The watcher reads **unified log** lines from **this machine’s** **`sshd`** (Remote Login) and **inbound** TCP to **local port 22**. It does **not** see: **outbound** SSH from this Mac (`ssh user@other-host` — **`debug1:`** / “Permission denied” text in the **client** terminal is not the server unified log); or **SSH sessions to another host** unless that host **is** this Mac running this tool. To monitor a **remote** server, use that server’s logging / **fail2ban** / router logs.
- **Inbound** detection uses **ESTABLISHED** TCP; very short connections may be missed between polls (lower **`SSH_WATCH_INTERVAL`** if needed).
- **“Attempts”** come from **unified log** content; some messages may be redacted as **`<private>`**. If failures vanish but **`Accepted …`** still works, try **`SSH_WATCH_AUTH_LOG_STREAM_LEVEL=debug`** (default) and inspect **`~/.ssh-connection-notify/log-stream.err`**.
- **AppleScript** notifications do **not** support clickable links; **terminal-notifier** adds **click → `open` log**.
- With **NAT and no port forwarding**, only **LAN / VPN / same network** hosts can reach **:22** on the laptop; this tool does not replace **router** logs for WAN attribution.

---

## Reload after changes

After editing the **script** or **plist**:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist
# edit files
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist
```

---

## Uninstall

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist
```

Optional cleanup:

```bash
rm -rf ~/.ssh-connection-notify
rm -f ~/Library/Logs/ssh-connection-notify.log
rm -f /tmp/ssh-connection-notify.out.log /tmp/ssh-connection-notify.err.log
```

Uninstalling **`terminal-notifier`** is optional: `brew uninstall terminal-notifier`.

---

## Quick reference: what is “installed” on the system

| Component | Installed by | Location |
|-----------|--------------|----------|
| Script | You (from repo) | Wherever you cloned; LaunchAgent points to it |
| LaunchAgent plist | You | `~/Library/LaunchAgents/com.user.ssh-connection-notify.plist` |
| `terminal-notifier` (optional) | `brew install` | e.g. `/opt/homebrew/bin/terminal-notifier` |
| No kernel extension / no Apple-signed “app” | — | — |

Everything else uses **built-in macOS** tools (**bash**, **log**, **lsof**, **osascript**).

---

## Document version

- Maintained in **[ssh-login-attempt-notifcation-macos](https://github.com/gliepins/ssh-login-attempt-notifcation-macos)**. The **running** copy is usually **`~/.ssh/script/ssh-connection-notify.sh`**; update the plist if you use a different absolute path.
