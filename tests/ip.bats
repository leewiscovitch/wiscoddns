#!/usr/bin/env bats
# Public IPv4 lookup: validation, parsing the Cloudflare trace, combining the two sources.
# The rule under test: junk from an IP source must never become an address we write to DNS.

setup() {
  load helpers
  # shellcheck source=../src/lib.sh
  source "$REPO_ROOT/src/lib.sh"
}

trace_body() {   # a body shaped like https://1.1.1.1/cdn-cgi/trace
  printf 'fl=123abc\nh=1.1.1.1\nip=%s\nts=1762500000.123\nvisit_scheme=https\nuag=curl/8.5.0\ncolo=EWR\n' "$1"
}

@test "wd_log prints UTC timestamp, level and message" {
  run wd_log INFO hello
  assert_success
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z INFO hello$'
}

@test "wd_is_public_ipv4 accepts public addresses" {
  for ip in 8.8.8.8 1.2.3.4 100.63.255.255 100.128.0.1 172.32.0.1 223.255.255.254; do
    run wd_is_public_ipv4 "$ip"
    assert_success
  done
}

@test "wd_is_public_ipv4 rejects junk, private and reserved addresses" {
  for ip in "" abc 1.2.3 1.2.3.4.5 256.1.1.1 01.2.3.4 1..2.3 -1.2.3.4 \
            0.1.2.3 10.0.0.1 100.64.0.1 100.127.255.255 127.0.0.1 169.254.1.1 172.16.0.1 172.31.255.255 \
            192.0.0.1 192.0.2.1 192.168.1.1 198.18.0.1 198.19.255.255 198.51.100.1 203.0.113.9 \
            224.0.0.1 240.0.0.1 255.255.255.255 2606:4700::1 "1.2.3.4 " " 1.2.3.4" "1.2.3.4
5.6.7.8" "<html>"; do
    run wd_is_public_ipv4 "$ip"
    assert_failure
  done
}

@test "wd_ip_from_trace prints the ip= value" {
  run wd_ip_from_trace <<< "$(trace_body 203.0.113.9)"
  assert_success
  assert_output 203.0.113.9
}

@test "wd_ip_from_trace prints nothing for a body without ip=" {
  run wd_ip_from_trace <<< '<html>captive portal</html>'
  assert_output ''
}

@test "wd_public_ip: both sources agree" {
  route GET 1.1.1.1/cdn-cgi/trace "$(trace_body 8.8.4.4)"
  route GET api.ipify.org 8.8.4.4
  run wd_public_ip
  assert_success
  assert_output 8.8.4.4
}

@test "wd_public_ip: one source down, the other valid" {
  route GET 1.1.1.1/cdn-cgi/trace FAIL
  route GET api.ipify.org 8.8.4.4
  run --separate-stderr wd_public_ip
  assert_success
  assert_output 8.8.4.4
}

@test "wd_public_ip: sources disagree -> fail, no output" {
  route GET 1.1.1.1/cdn-cgi/trace "$(trace_body 8.8.4.4)"
  route GET api.ipify.org 9.9.9.9
  run --separate-stderr wd_public_ip
  assert_failure
  assert_output ''
  [[ $stderr == *disagree* ]]
}

@test "wd_public_ip: HTML from one source, the other down -> fail" {
  route GET 1.1.1.1/cdn-cgi/trace FAIL
  route GET api.ipify.org '<html>502 Bad Gateway</html>'
  run --separate-stderr wd_public_ip
  assert_failure
  assert_output ''
}

@test "wd_public_ip: private address rejected -> fail" {
  route GET 1.1.1.1/cdn-cgi/trace "$(trace_body 10.0.0.5)"
  route GET api.ipify.org FAIL
  run --separate-stderr wd_public_ip
  assert_failure
  assert_output ''
}

@test "wd_public_ip: IPv6 answer rejected, valid IPv4 from the other source used" {
  route GET 1.1.1.1/cdn-cgi/trace "$(trace_body 2606:4700::1)"
  route GET api.ipify.org 8.8.4.4
  run --separate-stderr wd_public_ip
  assert_success
  assert_output 8.8.4.4
}

@test "wd_public_ip: asks both sources" {
  route GET 1.1.1.1/cdn-cgi/trace "$(trace_body 8.8.4.4)"
  route GET api.ipify.org 8.8.4.4
  run --separate-stderr wd_public_ip
  assert_success
  run grep -c . "$FAKE_CURL_DIR/calls.log"
  assert_output 2
}
