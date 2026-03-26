#!/usr/bin/env bash
# Lightweight SSH (TCP/22) watcher for macOS.
#
# 1) Polls ESTABLISHED inbound :22 (lsof/netstat) → notify on each new peer.
# 2) Subscribes to unified log for sshd / sshd-session / sshd-auth (stream only,
#    no verbose sshd files) → notify on failed / pre-auth style events.
#
# Usage: ./ssh-connection-notify.sh   (or an absolute path from LaunchAgent)
#
# Env:
#   SSH_WATCH_INTERVAL       Poll seconds for TCP (default 3)
#   SSH_WATCH_LOG_MAX_LINES  Log rotation threshold (default 5000)
#   SSH_WATCH_AUTH_LOGS     Set 0 to disable log-stream auth watcher
#   SSH_WATCH_AUTH_NOTIFY_COOLDOWN  Seconds between *notifications* for failure-style auth per client IPv4 (default: 0).
#                            0 = notify on every matching line (log always records each line anyway).
#                            Set e.g. 25 to reduce banner spam from one IP brute-forcing. Legacy: SSH_WATCH_AUTH_COOLDOWN.
#   SSH_WATCH_AUTH_LOG_STREAM_LEVEL  Unified log level for auth log stream: default | info | debug (default: debug).
#                            Failures (invalid user, failed password) are often emitted at debug level on macOS
#                            while "Accepted …" is visible at info — using only --info can miss failures entirely.
#   SSH_WATCH_AUTH_STREAM_DEBUG   Legacy: if set to 1, forces log stream level to debug (same as level=debug).
#   SSH_WATCH_AUTH_SUCCESS_COOLDOWN  Same for successful "Accepted …" lines (default 15)
#   SSH_WATCH_NOTIFY_USE_TERMINAL_NOTIFIER
#                            Set 0 to force AppleScript notifications only (no click action).
#                            If `terminal-notifier` is on PATH (brew install terminal-notifier),
#                            notifications use it so a click runs: open <logfile>.
#
# Note: log stream needs Terminal (or the LaunchAgent) to have normal access to logs.
# Some lines may be redacted as <private> in unified logging.
#
# Reliability: the auth reader runs in a subshell with `set +e` so a failed grep/osascript
# under `set -euo pipefail` cannot kill auth monitoring. The main loop restarts log stream
# if the writer or reader dies (log stream exits, FIFO EOF, etc.).

set -euo pipefail

INTERVAL="${SSH_WATCH_INTERVAL:-3}"
STATEDIR="${HOME}/.ssh-connection-notify"
LOG="${HOME}/Library/Logs/ssh-connection-notify.log"
mkdir -p "$STATEDIR" "$(dirname "$LOG")"

PREV_FILE="${STATEDIR}/prev_peers.txt"
FIFO="${STATEDIR}/auth_log.fifo"
WRITER_PID=""
READER_PID=""

rotate_log() {
  local max="${SSH_WATCH_LOG_MAX_LINES:-5000}"
  [[ -f "$LOG" ]] || return 0
  local n
  n=$(wc -l <"$LOG" | tr -d ' ')
  if [[ "$n" -gt "$max" ]]; then
    tail -n 2000 "$LOG" >"${LOG}.tmp"
    mv "${LOG}.tmp" "$LOG"
  fi
}

peers_from_lsof() {
  lsof -nP -iTCP:22 -sTCP:ESTABLISHED 2>/dev/null | awk '
    $0 ~ /:22->/ {
      line = $0;
      sub(/^.*:22->/, "", line);
      sub(/ \(.*/, "", line);
      print line;
    }' | sort -u
}

peers_from_netstat() {
  netstat -anv -p tcp 2>/dev/null | awk '
    $NF == "ESTABLISHED" {
      loc = $4; rem = $5;
      if (loc ~ /\.22$/) {
        if (rem ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
          n = split(rem, p, ".");
          port = p[n];
          printf "%s.%s.%s.%s:%s\n", p[1], p[2], p[3], p[4], port;
        } else {
          print rem;
        }
      }
    }' | sort -u
}

peers_now() {
  { peers_from_lsof; peers_from_netstat; } | sort -u
}

notify_macos() {
  local title="$1"
  local subtitle="$2"
  local body="$3"
  local open_cmd
  # AppleScript `display notification` cannot attach a click handler or file: URL.
  # terminal-notifier: click runs `open` on the log (default app for .log, often Console/TextEdit).
  # Never fail the caller: notification denial / missing UI must not kill the auth reader (set -e).
  if [[ "${SSH_WATCH_NOTIFY_USE_TERMINAL_NOTIFIER:-1}" != "0" ]] &&
    command -v terminal-notifier >/dev/null 2>&1; then
    # Bash builtin printf — /usr/bin/printf does not support %q (fixes "illegal format character q").
    open_cmd="/usr/bin/open $(printf '%q' "$LOG")"
    terminal-notifier -title "$title" -subtitle "$subtitle" -message "$body" -execute "$open_cmd" 2>/dev/null || true
    return 0
  fi
  /usr/bin/osascript <<OSA 2>/dev/null || true
display notification "$body" with title "$title" subtitle "$subtitle"
OSA
  return 0
}

log_event() {
  local peer="$1"
  rotate_log
  printf '%s peer=%s event=new_established\n' "$(date -Iseconds)" "$peer" >>"$LOG"
}

log_auth_event() {
  local summary="$1"
  rotate_log
  # One line; avoid flooding file with huge redacted blobs
  printf '%s event=auth_log %s\n' "$(date -Iseconds)" "$summary" >>"$LOG"
}

log_success_event() {
  local summary="$1"
  rotate_log
  printf '%s event=auth_success %s\n' "$(date -Iseconds)" "$summary" >>"$LOG"
}

# Best-effort client IPv4 from a syslog line (OpenSSH often has "from 1.2.3.4 port")
# Must always succeed: with pipefail, grep "no match" must not abort the auth reader.
extract_client_ip() {
  printf '%s' "$1" | grep -oE 'from ([0-9]{1,3}\.){3}[0-9]{1,3} ' 2>/dev/null | head -1 | sed 's/^from //;s/ $//' | tr -d '\n' || true
}

# Per-IP cooldown for *notifications* only (log lines are always written when a line matches).
# cd=0 (default): always show a banner for each matching line for this IP.
auth_notify_cooldown_ok() {
  local ip="$1"
  local cd="${SSH_WATCH_AUTH_NOTIFY_COOLDOWN:-${SSH_WATCH_AUTH_COOLDOWN:-0}}"
  local now f last
  [[ "$cd" == "0" ]] && return 0
  now=$(date +%s)
  f="${STATEDIR}/cooldown_auth_${ip//[^a-zA-Z0-9.]/_}"
  if [[ -f "$f" ]] && last=$(cat "$f") && [[ "$last" =~ ^[0-9]+$ ]]; then
    if (( now - last < cd )); then
      return 1
    fi
  fi
  printf '%s' "$now" >"$f"
  return 0
}

auth_success_cooldown_ok() {
  local ip="$1"
  local cd="${SSH_WATCH_AUTH_SUCCESS_COOLDOWN:-15}"
  local now f last
  now=$(date +%s)
  f="${STATEDIR}/cooldown_auth_ok_${ip//[^a-zA-Z0-9.]/_}"
  if [[ -f "$f" ]] && last=$(cat "$f") && [[ "$last" =~ ^[0-9]+$ ]]; then
    if (( now - last < cd )); then
      return 1
    fi
  fi
  printf '%s' "$now" >"$f"
  return 0
}

# OpenSSH success (default LogLevel INFO) — username + method come from here, not from TCP/lsof.
is_auth_success_line() {
  printf '%s' "$1" | grep -qiE \
    'Accepted (publickey|password|keyboard-interactive|gssapi-with-mic|hostbased) for '
}

# Parse IPv4 "from host port" form; IPv6 or odd formats return empty → we still log truncated raw line.
parse_accepted_fields() {
  printf '%s' "$1" | sed -nE \
    's/.*Accepted ([a-zA-Z0-9-]+) for ([^ ]+) from ([^ ]+) port ([0-9]+).*/method=\1 user=\2 host=\3 port=\4/p'
}

# OpenSSH-style auth / handshake failures (tuned to reduce noise vs generic [preauth] chatter).
# Includes PAM / OpenDirectory phrasing: valid users (e.g. root) often differ from "Invalid user …" lines.
# "invalid[[:space:]]+user" catches odd spacing; "invalid username" is not matched by plain "invalid user".
is_auth_interesting_line() {
  printf '%s' "$1" | grep -qiE \
    'failed password|failed publickey|failed keyboard|invalid[[:space:]]+user|invalid user|authentication refused|authentication failure|penalty: failed authentication|pam_.*sshd|exceeded maximum|exceeded max|max authtries|too many authentication failures|maximum authentication|unable to negotiate|bad protocol version|no matching (cipher|mac|host key|key exchange)|connection reset by authenticating|disconnected from authenticating|received disconnect|disconnecting|kex_exchange_identification|error: maximum authentication|fatal: (userauth|no mutual|bad )|banner exchange: |Connection closed by authenticating user'
}

cleanup_auth_stream() {
  [[ "${SSH_WATCH_AUTH_LOGS:-1}" == "0" ]] && return 0
  if [[ -n "${WRITER_PID:-}" ]] && kill -0 "$WRITER_PID" 2>/dev/null; then
    kill "$WRITER_PID" 2>/dev/null || true
    wait "$WRITER_PID" 2>/dev/null || true
  fi
  if [[ -n "${READER_PID:-}" ]] && kill -0 "$READER_PID" 2>/dev/null; then
    kill "$READER_PID" 2>/dev/null || true
    wait "$READER_PID" 2>/dev/null || true
  fi
  WRITER_PID=""
  READER_PID=""
  rm -f "$FIFO"
}

# If log stream exits or the reader subshell dies (set -e bug, EOF), auth would stay dead forever.
ensure_auth_stream_alive() {
  [[ "${SSH_WATCH_AUTH_LOGS:-1}" == "0" ]] && return 0
  local ok=0
  if [[ -n "${WRITER_PID:-}" ]] && kill -0 "$WRITER_PID" 2>/dev/null &&
    [[ -n "${READER_PID:-}" ]] && kill -0 "$READER_PID" 2>/dev/null; then
    ok=1
  fi
  if [[ "$ok" -eq 1 ]]; then
    return 0
  fi
  rotate_log
  printf '%s event=auth_stream_restart reason=writer_or_reader_exited writer_pid=%s reader_pid=%s\n' \
    "$(date -Iseconds)" "${WRITER_PID:-none}" "${READER_PID:-none}" >>"$LOG"
  printf '%s ssh-connection-notify: restarting auth log stream (log stream or reader died)\n' "$(date -Iseconds)" >&2
  cleanup_auth_stream
  start_auth_log_stream
}

start_auth_log_stream() {
  [[ "${SSH_WATCH_AUTH_LOGS:-1}" == "0" ]] && return 0

  rm -f "$FIFO"
  mkfifo "$FIFO"
  chmod 600 "$FIFO"

  # Reader first (blocks until writer opens FIFO). set +e: do not exit on grep/notify edge cases.
  (
    set +e
    set +o pipefail
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "${line// }" ]] && continue

      # Successful login: OpenSSH logs "Accepted <method> for <user> from <host> port <n>"
      if is_auth_success_line "$line"; then
        ip="$(extract_client_ip "$line")"
        [[ -z "$ip" ]] && ip="unknown"
        fields="$(parse_accepted_fields "$line")"
        if [[ -n "$fields" ]]; then
          log_success_event "$fields"
        else
          sum="$(printf '%s' "$line" | tr -d '\r\n' | head -c 400)"
          log_success_event "parse=failed raw=${sum}"
        fi
        auth_success_cooldown_ok "$ip" || continue
        if [[ -n "$fields" ]]; then
          u="$(printf '%s' "$fields" | sed -n 's/.*user=\([^ ]*\).*/\1/p')"
          m="$(printf '%s' "$fields" | sed -n 's/.*method=\([^ ]*\).*/\1/p')"
          notify_macos "SSH login accepted" "${u:-?}" "${m:-?} from ${ip}"
          printf '%s SSH accepted user=%s method=%s ip=%s\n' "$(date -Iseconds)" "${u:-?}" "${m:-?}" "$ip" >&2
        else
          notify_macos "SSH login accepted" "$ip" "See ssh-connection-notify.log (IPv6 or non-standard line)"
          printf '%s SSH accepted (unparsed) ip=%s\n' "$(date -Iseconds)" "$ip" >&2
        fi
        continue
      fi

      is_auth_interesting_line "$line" || continue

      ip="$(extract_client_ip "$line")"
      [[ -z "$ip" ]] && ip="unknown"
      sum="$(printf '%s' "$line" | tr -d '\r\n' | head -c 400)"
      log_auth_event "$sum"
      if auth_notify_cooldown_ok "$ip"; then
        notify_macos "SSH auth / pre-auth" "$ip" "See ssh-connection-notify.log (auth_log)"
        printf '%s SSH auth event (ip=%s) — see log\n' "$(date -Iseconds)" "$ip" >&2
      fi
    done <"$FIFO"
  ) &
  READER_PID=$!

  # Match sshd-related processes by name and by binary path. Do NOT use composedMessage in the
  # predicate: on some macOS versions, mixing composedMessage with OR breaks delivery of sshd
  # failure lines while "Accepted …" lines still arrive (senderImagePath / process quirks).
  AUTH_LOG_PREDICATE='(process == "sshd") OR (process == "sshd-session") OR (process == "sshd-auth") OR (senderImagePath ENDSWITH "/sshd") OR (senderImagePath ENDSWITH "/sshd-auth")'

  AUTH_LOG_LEVEL="${SSH_WATCH_AUTH_LOG_STREAM_LEVEL:-debug}"
  case "$AUTH_LOG_LEVEL" in
    default|info|debug) ;;
    *) AUTH_LOG_LEVEL=debug ;;
  esac
  [[ "${SSH_WATCH_AUTH_STREAM_DEBUG:-0}" == "1" ]] && AUTH_LOG_LEVEL=debug

  /usr/bin/log stream \
    --predicate "$AUTH_LOG_PREDICATE" \
    --style syslog \
    --level "$AUTH_LOG_LEVEL" \
    >"$FIFO" 2>>"${STATEDIR}/log-stream.err" &
  WRITER_PID=$!

  trap 'cleanup_auth_stream' EXIT INT TERM
}

start_auth_log_stream

# --- TCP peer watcher (seed: no alert for sessions already up)
NOW="$(peers_now | sort -u)"
echo "$NOW" >"$PREV_FILE"

while true; do
  sleep "$INTERVAL"
  ensure_auth_stream_alive
  NOW="$(peers_now | sort -u)"

  comm -23 <(echo "$NOW") <(sort -u "$PREV_FILE") | while read -r peer; do
    [[ -z "${peer// }" ]] && continue
    notify_macos "SSH (TCP/22)" "$peer" "New connection — see ssh-connection-notify.log"
    log_event "$peer"
    printf '%s inbound SSH peer %s (logged)\n' "$(date -Iseconds)" "$peer" >&2
  done

  echo "$NOW" >"$PREV_FILE"
done
