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
