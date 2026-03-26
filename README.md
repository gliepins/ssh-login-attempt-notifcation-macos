# SSH login attempt notification (macOS)

Get **Notification Center** alerts when someone connects to **SSH (port 22)** on your Mac, when **authentication** events appear in the **unified log** (invalid user, failed auth, pre-auth noise), and when a login **succeeds** — without enabling verbose OpenSSH file logging.

**Upstream repository:** [github.com/gliepins/ssh-login-attempt-notifcation-macos](https://github.com/gliepins/ssh-login-attempt-notifcation-macos)

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
