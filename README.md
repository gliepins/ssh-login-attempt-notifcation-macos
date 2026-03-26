# SSH login attempt notification (macOS)

Get **Notification Center** alerts when someone connects to **SSH (port 22)** on your Mac, when **authentication** events appear in the **unified log** (invalid user, failed auth, pre-auth noise), and when a login **succeeds** — without enabling verbose OpenSSH file logging.

**Upstream repository:** [github.com/gliepins/ssh-login-attempt-notifcation-macos](https://github.com/gliepins/ssh-login-attempt-notifcation-macos)

### Why this exists

I keep **Remote Login** enabled for my own use: SSH is **restricted** the way I need it, and I mostly reach it over **tunnels**. I also work from **untrusted networks** from time to time. I did not want to **toggle Sharing** every time I changed location, so I needed visibility **without** constantly opening and closing Remote Login.

On this machine, **SSH is often the only listening service** exposed to the network. That makes it worth **monitoring deliberately**: alerts when something hits the port, plus a **single readable log** of `sshd`-related activity. Neither is obvious from day-to-day use of macOS, and relying on **Console** or raw unified logs for routine checks is **slow and awkward**. This project is a small LaunchAgent plus script that closes that gap.

It does **not** enable verbose OpenSSH **file** logging; it uses **`log stream`** and TCP polling instead — see [docs/manual.md](docs/manual.md) for the distinction.

## What it does

| Source | Behavior |
|--------|----------|
| `lsof` / `netstat` | New **inbound** TCP connections to local **:22** |
| `log stream` | `sshd` / `sshd-session` / `sshd-auth` (and related) — failures, successes (`Accepted …`), etc. |

Optional: [terminal-notifier](https://github.com/julienXX/terminal-notifier) so a click on the banner opens the log file.

## Requirements

- macOS (recent releases; uses bash 3.2+)
- **System Settings → General → Sharing → Remote Login** enabled if you want inbound SSH
- Optional: `brew install terminal-notifier`

## Quick install

```bash
git clone https://github.com/gliepins/ssh-login-attempt-notifcation-macos.git
cd ssh-login-attempt-notifcation-macos

mkdir -p ~/.ssh/script
cp ssh-connection-notify.sh ~/.ssh/script/
chmod +x ~/.ssh/script/ssh-connection-notify.sh

cp launchd/com.user.ssh-connection-notify.plist.example ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist
# Edit the plist: replace YOUR_USERNAME with your macOS account short name (see `whoami` / `/Users/...`).
open -e ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.ssh-connection-notify.plist
```

**Log file:** `~/Library/Logs/ssh-connection-notify.log`

## Documentation

- **[docs/manual.md](docs/manual.md)** — full guide (environment variables, limitations, uninstall, troubleshooting)

## Scope

This watches **this Mac as an SSH server** only. It does **not** see outbound `ssh user@other-host` client sessions on another machine’s logs.

## License

MIT — see [LICENSE](LICENSE).
