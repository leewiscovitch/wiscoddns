#!/usr/bin/env bash
# Docker HEALTHCHECK (/usr/local/bin/wiscoddns-healthcheck): healthy while the last successful round is recent.
# wiscoddns.sh touches the heartbeat file after every good round; if it is older than two intervals, two rounds
# in a row went wrong (or the loop hung) and Docker marks the container "unhealthy".
# Exit 0 = healthy, 1 = unhealthy (the only two codes Docker expects).
set -u

heartbeat="${WISCODDNS_RUN_DIR:-/tmp/wiscoddns}/heartbeat"
interval=${WISCODDNS_INTERVAL:-300}

[ -f "$heartbeat" ] || { echo "no heartbeat yet ($heartbeat)"; exit 1; }
age=$(($(date +%s) - $(stat -c %Y "$heartbeat")))
if ((age < 2 * interval)); then
  echo "ok: last good round ${age}s ago"
  exit 0
fi
echo "unhealthy: last good round ${age}s ago (limit $((2 * interval))s)"
exit 1
