# shellcheck shell=bash
# wiscoddns function library. Sourced by src/wiscoddns.sh and by the tests; it only defines functions and
# defaults, it runs nothing by itself. Every name starts with wd_ (functions) or WD_ (globals).
#
# Logs go to stderr. Functions that return a value print it on stdout, so a caller can write
# `ip=$(wd_public_ip)` and still see the log lines in `docker logs` (Docker collects both streams).

# --- Logging ------------------------------------------------------------------------------------------------

# wd_log LEVEL MESSAGE...    e.g.  2026-11-07T12:00:00Z INFO record unchanged
# UTC and ISO 8601, so lines sort and compare the same on any machine.
wd_log() {
  local level=$1
  shift
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}

# --- Public IPv4 --------------------------------------------------------------------------------------------

# The two outside services that tell us our public IPv4. Two, so one being down or wrong isn't fatal.
WD_TRACE_URL=${WD_TRACE_URL:-https://1.1.1.1/cdn-cgi/trace}   # Cloudflare; key=value lines, one is ip=
WD_IPIFY_URL=${WD_IPIFY_URL:-https://api.ipify.org}            # ipify; the bare address

# wd_is_public_ipv4 IP: rc 0 if IP is a dotted-quad IPv4 address that is routable on the internet.
# Anything else (text, HTML, IPv6, private or reserved ranges) is rc 1: it must never reach DNS.
wd_is_public_ipv4() {
  local ip=$1
  # Four groups of 1-3 digits, nothing before or after (no spaces, no second line). A leading zero (01) is
  # refused: some tools read it as octal.
  [[ $ip =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
  local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1

  # Special-purpose ranges (IANA IPv4 Special-Purpose Address Registry, RFC 6890):
  ((a == 0)) && return 1                                # 0.0.0.0/8       "this network" (RFC 791)
  ((a == 10)) && return 1                               # 10.0.0.0/8      private (RFC 1918)
  ((a == 100 && b >= 64 && b <= 127)) && return 1       # 100.64.0.0/10   carrier-grade NAT (RFC 6598)
  ((a == 127)) && return 1                              # 127.0.0.0/8     loopback (RFC 1122)
  ((a == 169 && b == 254)) && return 1                  # 169.254.0.0/16  link-local (RFC 3927)
  ((a == 172 && b >= 16 && b <= 31)) && return 1        # 172.16.0.0/12   private (RFC 1918)
  ((a == 192 && b == 0 && c == 0)) && return 1          # 192.0.0.0/24    IETF protocol assignments (RFC 6890)
  ((a == 192 && b == 0 && c == 2)) && return 1          # 192.0.2.0/24    documentation TEST-NET-1 (RFC 5737)
  ((a == 192 && b == 168)) && return 1                  # 192.168.0.0/16  private (RFC 1918)
  ((a == 198 && (b == 18 || b == 19))) && return 1      # 198.18.0.0/15   benchmarking (RFC 2544)
  ((a == 198 && b == 51 && c == 100)) && return 1       # 198.51.100.0/24 documentation TEST-NET-2 (RFC 5737)
  ((a == 203 && b == 0 && c == 113)) && return 1        # 203.0.113.0/24  documentation TEST-NET-3 (RFC 5737)
  ((a >= 224)) && return 1                              # 224.0.0.0/4 multicast (RFC 5771), 240.0.0.0/4 reserved
                                                        # (RFC 1112) and 255.255.255.255 broadcast
  return 0
}

# wd_ip_from_trace: reads a /cdn-cgi/trace body on stdin, prints the value of its ip= line (or nothing)
wd_ip_from_trace() {
  sed -n 's/^ip=//p' | head -n 1
}

# wd_public_ip: prints our public IPv4; rc 0 on success.
# Asks both sources (IPv4 forced with -4, 10 s timeout each) and keeps only valid public answers. Success needs
# at least one valid answer, and two valid answers must agree; otherwise rc 1 and nothing printed.
wd_public_ip() {
  local trace ipify answers=()
  # -f: an HTTP error (4xx/5xx) is a failure, not a body; -sS: quiet, but show errors in the log
  if trace=$(curl -4 -fsS --max-time 10 "$WD_TRACE_URL" | wd_ip_from_trace) && wd_is_public_ipv4 "$trace"; then
    answers+=("$trace")
  else
    wd_log WARN "IP source $WD_TRACE_URL gave no valid public IPv4${trace:+ (got: ${trace:0:40})}"
  fi
  if ipify=$(curl -4 -fsS --max-time 10 "$WD_IPIFY_URL") && wd_is_public_ipv4 "$ipify"; then
    answers+=("$ipify")
  else
    wd_log WARN "IP source $WD_IPIFY_URL gave no valid public IPv4${ipify:+ (got: ${ipify:0:40})}"
  fi

  case ${#answers[@]} in
    0)
      wd_log ERROR "no IP source gave a valid public IPv4; skipping this round"
      return 1
      ;;
    2)
      if [ "${answers[0]}" != "${answers[1]}" ]; then
        wd_log ERROR "IP sources disagree (${answers[0]} vs ${answers[1]}); skipping this round"
        return 1
      fi
      ;;
  esac
  printf '%s\n' "${answers[0]}"
}

# --- Cloudflare API -----------------------------------------------------------------------------------------
#
# Cloudflare API v4 (https://developers.cloudflare.com/api/). Three endpoints are used:
#   GET   /zones?name=<zone>                                    list zones, filtered by name   -> zone ID
#   GET   /zones/<zone_id>/dns_records?type=A&name.exact=<name> list DNS records, exact name    -> record ID
#   GET   /zones/<zone_id>/dns_records/<record_id>              one record                     -> its content
#   PATCH /zones/<zone_id>/dns_records/<record_id>              change a record
# PATCH only changes the fields it is sent (name, type, content, ttl, proxied, comment, tags are accepted);
# we send only {"content": "<ip>"}, so OpenTofu's settings (TTL, proxied, comment) stay as they are.
# Every response is JSON: {"success": true|false, "errors": [{"code", "message"}], "result": ...}.

WD_CF_API=${WD_CF_API:-https://api.cloudflare.com/client/v4}
# File with the line "Authorization: Bearer <token>" (written by wiscoddns.sh, mode 0600). curl reads headers
# from it with -H @file, so the token never shows on a command line (ps, /proc/<pid>/cmdline).
WD_AUTH_HEADER_FILE=${WD_AUTH_HEADER_FILE:-/tmp/wiscoddns/auth-header}

# wd_cf_api METHOD PATH [JSON]: calls the API, prints the response body; rc 1 on a connection failure, a body
# that isn't JSON, or "success": false (Cloudflare's error messages are logged).
wd_cf_api() {
  local method=$1 path=$2 data=${3:-} body
  local args=(-sS --max-time 15 -X "$method" -H @"$WD_AUTH_HEADER_FILE" -H 'Content-Type: application/json')
  [ -n "$data" ] && args+=(--data "$data")
  # No -f: on 4xx/5xx Cloudflare still sends JSON with the reason, and we want to log it
  if ! body=$(curl "${args[@]}" "$WD_CF_API$path"); then
    wd_log ERROR "Cloudflare API $method $path: connection failed"
    return 1
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "$body"; then
    wd_log ERROR "Cloudflare API $method $path: answer is not JSON (${body:0:60})"
    return 1
  fi
  if ! jq -e '.success == true' >/dev/null <<< "$body"; then
    wd_log ERROR "Cloudflare API $method $path failed: $(jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' <<< "$body")"
    return 1
  fi
  printf '%s\n' "$body"
}

# wd_lookup_ids: sets WD_ZONE_ID and WD_RECORD_ID from the names in WISCODDNS_ZONE and WISCODDNS_RECORD.
# Looked up by name at startup, so no IDs need to be configured. rc 1 if either is missing.
wd_lookup_ids() {
  local body
  body=$(wd_cf_api GET "/zones?name=$WISCODDNS_ZONE") || return 1
  WD_ZONE_ID=$(jq -r '.result[0].id // empty' <<< "$body")
  if [ -z "$WD_ZONE_ID" ]; then
    wd_log ERROR "zone $WISCODDNS_ZONE not found (check WISCODDNS_ZONE and the token's zone access)"
    return 1
  fi
  body=$(wd_cf_api GET "/zones/$WD_ZONE_ID/dns_records?type=A&name.exact=$WISCODDNS_RECORD") || return 1
  WD_RECORD_ID=$(jq -r '.result[0].id // empty' <<< "$body")
  if [ -z "$WD_RECORD_ID" ]; then
    # Never created here: whoever owns the zone creates the record (wiscoddns only changes its address)
    wd_log ERROR "A record $WISCODDNS_RECORD not found: it must exist before wiscoddns starts"
    return 1
  fi
}

# wd_record_ip: prints the record's current address (read from the API, never from DNS: a local DNS server
# or a cache may answer something else)
wd_record_ip() {
  local body
  body=$(wd_cf_api GET "/zones/$WD_ZONE_ID/dns_records/$WD_RECORD_ID") || return 1
  jq -r '.result.content' <<< "$body"
}

# wd_update_record IP: sets the record's address. With WISCODDNS_DRY_RUN=1 it only logs what it would do.
wd_update_record() {
  local ip=$1
  if [ "${WISCODDNS_DRY_RUN:-0}" = 1 ]; then
    wd_log INFO "DRY-RUN would set $WISCODDNS_RECORD -> $ip"
    return 0
  fi
  wd_cf_api PATCH "/zones/$WD_ZONE_ID/dns_records/$WD_RECORD_ID" "$(jq -cn --arg ip "$ip" '{content: $ip}')" >/dev/null
}
