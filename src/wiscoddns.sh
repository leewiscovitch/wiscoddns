#!/usr/bin/env bash
# wiscoddns: keeps one Cloudflare A record pointed at this network's public IPv4.
# The entrypoint of the image (/usr/local/bin/wiscoddns). Configuration comes from the environment; see the
# README's table. Functions live in lib.sh, next to this file.
set -uo pipefail   # no -e: a failed round is expected now and then, and must not end the program

# Find lib.sh next to the real file, even when started through a symlink (/usr/local/bin/wiscoddns)
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source-path=SCRIPTDIR
source "$here/lib.sh"

# --- Configuration (defaults in one place) ------------------------------------------------------------------
WISCODDNS_VERSION=${WISCODDNS_VERSION:-dev}           # set by the image build (Dockerfile ARG VERSION)
WISCODDNS_TOKEN_FILE=${WISCODDNS_TOKEN_FILE:-/run/secrets/cloudflare_token}
WISCODDNS_INTERVAL=${WISCODDNS_INTERVAL:-300}         # seconds between rounds
WISCODDNS_MIN_INTERVAL=${WISCODDNS_MIN_INTERVAL:-30}  # lower limit; only tests lower it
WISCODDNS_DRY_RUN=${WISCODDNS_DRY_RUN:-0}
WISCODDNS_FAIL_ALERT_AFTER=${WISCODDNS_FAIL_ALERT_AFTER:-3}
WISCODDNS_RUN_DIR=${WISCODDNS_RUN_DIR:-/tmp/wiscoddns} # header files and heartbeat (a tmpfs in compose)
WISCODDNS_ONCE=${WISCODDNS_ONCE:-0}                   # 1 = one round, exit with its result

fatal() {
  wd_log ERROR "$*"
  exit 1
}

# --- Startup checks: fail fast with one clear line ----------------------------------------------------------
[ -n "${WISCODDNS_RECORD:-}" ] || fatal "WISCODDNS_RECORD is not set (the full record name, e.g. ddns.example.org)"
[ -n "${WISCODDNS_ZONE:-}" ] || fatal "WISCODDNS_ZONE is not set (the zone name, e.g. example.org)"
if ! [[ $WISCODDNS_INTERVAL =~ ^[0-9]+$ ]] || ((WISCODDNS_INTERVAL < WISCODDNS_MIN_INTERVAL)); then
  fatal "WISCODDNS_INTERVAL must be a whole number of seconds >= $WISCODDNS_MIN_INTERVAL (got: $WISCODDNS_INTERVAL)"
fi
[[ $WISCODDNS_FAIL_ALERT_AFTER =~ ^[1-9][0-9]*$ ]] ||
  fatal "WISCODDNS_FAIL_ALERT_AFTER must be a whole number >= 1 (got: $WISCODDNS_FAIL_ALERT_AFTER)"

# read_secret FILE: prints the file's content without whitespace (echo and editors add a trailing newline)
read_secret() {
  [ -r "$1" ] || fatal "can't read token file $1"
  local value
  value=$(tr -d '[:space:]' < "$1")
  [ -n "$value" ] || fatal "token file $1 is empty"
  printf '%s' "$value"
}

# Header files: curl reads them with -H @file, so tokens never appear in a process list. umask 077 makes
# every file created from here on readable by this user only (mode 600).
umask 077
mkdir -p "$WISCODDNS_RUN_DIR" || fatal "can't create $WISCODDNS_RUN_DIR"
token=$(read_secret "$WISCODDNS_TOKEN_FILE") || exit 1
WD_AUTH_HEADER_FILE="$WISCODDNS_RUN_DIR/auth-header"
printf 'Authorization: Bearer %s\n' "$token" > "$WD_AUTH_HEADER_FILE"
if [ -n "${WISCODDNS_NTFY_TOKEN_FILE:-}" ]; then
  token=$(read_secret "$WISCODDNS_NTFY_TOKEN_FILE") || exit 1
  WD_NTFY_HEADER_FILE="$WISCODDNS_RUN_DIR/ntfy-header"
  printf 'Authorization: Bearer %s\n' "$token" > "$WD_NTFY_HEADER_FILE"
fi
unset token

HEARTBEAT="$WISCODDNS_RUN_DIR/heartbeat"

wd_log INFO "wiscoddns $WISCODDNS_VERSION starting: record=$WISCODDNS_RECORD zone=$WISCODDNS_ZONE" \
  "interval=${WISCODDNS_INTERVAL}s dry_run=$WISCODDNS_DRY_RUN alert_after=$WISCODDNS_FAIL_ALERT_AFTER" \
  "ntfy=$([ -n "${WISCODDNS_NTFY_URL:-}" ] && echo on || echo off)"

# The record must exist and the token must reach it; otherwise there is nothing useful to do
wd_lookup_ids || fatal "startup failed: can't find $WISCODDNS_RECORD in Cloudflare (see the line above)"
wd_log INFO "found zone $WD_ZONE_ID, record $WD_RECORD_ID"

# --- One-shot mode ------------------------------------------------------------------------------------------
if [ "$WISCODDNS_ONCE" = 1 ]; then
  wd_round || exit 1
  touch "$HEARTBEAT"
  exit 0
fi

# --- The loop -----------------------------------------------------------------------------------------------
# docker stop sends SIGTERM (Ctrl-C sends SIGINT): log it, stop the sleep, exit cleanly. The sleep runs in the
# background and we `wait` for it, because bash only runs a trap between commands: a foreground `sleep 300`
# would delay the exit by up to 5 minutes, and Docker would kill us the hard way after 10 seconds.
sleep_pid=""
stop() {
  wd_log INFO "stopping (signal received)"
  [ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null
  exit 0
}
trap stop TERM INT

failures=0
while true; do
  if wd_round; then
    if ((failures >= WISCODDNS_FAIL_ALERT_AFTER)); then
      wd_notify "wiscoddns: recovered" "wiscoddns recovered after $failures failed rounds"
    fi
    failures=0
    touch "$HEARTBEAT"   # the health check reads this file's age
  else
    failures=$((failures + 1))
    wd_log WARN "round failed ($failures in a row)"
    # Alert once, when the count reaches the threshold (not on every failed round after it)
    if ((failures == WISCODDNS_FAIL_ALERT_AFTER)); then
      wd_notify "wiscoddns: failing" "wiscoddns: $failures rounds failed in a row for $WISCODDNS_RECORD, see docker logs"
    fi
  fi
  sleep "$WISCODDNS_INTERVAL" &
  sleep_pid=$!
  wait "$sleep_pid"
  sleep_pid=""
done
