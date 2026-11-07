#!/usr/bin/env bats
# One round: public IP -> record IP -> update if different (+ notify).

setup() {
  load helpers
  # shellcheck source=../src/lib.sh
  source "$REPO_ROOT/src/lib.sh"
  FIX="$REPO_ROOT/tests/fixtures"
  export WISCODDNS_ZONE=example.org WISCODDNS_RECORD=ddns.example.org
  export WISCODDNS_NTFY_URL=http://ntfy.test WISCODDNS_NTFY_TOPIC=alerts
  WD_AUTH_HEADER_FILE="$BATS_TEST_TMPDIR/auth-header"
  echo 'Authorization: Bearer t' > "$WD_AUTH_HEADER_FILE"
  WD_ZONE_ID=zone123 WD_RECORD_ID=rec456
  # the record holds 198.51.100.7 (record.json)
  route_file GET '/dns_records/rec456' "$FIX/record.json"
  route_file PATCH '/dns_records/rec456' "$FIX/patch_ok.json"
}

public_ip_is() {
  route GET 1.1.1.1/cdn-cgi/trace "ip=$1"
  route GET api.ipify.org "$1"
}

@test "round: record already right -> no PATCH, no notify, logs unchanged" {
  : > "$FAKE_CURL_DIR/routes"
  public_ip_is 8.8.4.4
  route_file GET '/dns_records/rec456' "$FIX/patch_ok.json"   # a record whose content is already 8.8.4.4
  run wd_round
  assert_success
  assert_output --partial 'unchanged'
  run grep -cE '^(PATCH|POST)' "$FAKE_CURL_DIR/calls.log"
  assert_output 0
}

@test "round: record different -> PATCH and one notification with old and new IP" {
  public_ip_is 8.8.4.4
  route POST ntfy.test/alerts 'ok'
  run wd_round
  assert_success
  run grep -c '^PATCH .*/dns_records/rec456 {"content":"8.8.4.4"}$' "$FAKE_CURL_DIR/calls.log"
  assert_output 1
  run grep '^POST http://ntfy.test/alerts' "$FAKE_CURL_DIR/calls.log"
  assert_output --partial '198.51.100.7'
  assert_output --partial '8.8.4.4'
  assert_equal "$(grep -c '^POST' "$FAKE_CURL_DIR/calls.log")" 1
}

@test "round: ntfy down -> round still succeeds, WARN logged" {
  public_ip_is 8.8.4.4
  route POST ntfy.test FAIL
  run wd_round
  assert_success
  assert_output --partial 'WARN'
}

@test "round: no ntfy URL -> no POST" {
  unset WISCODDNS_NTFY_URL
  public_ip_is 8.8.4.4
  run wd_round
  assert_success
  run grep -c '^POST' "$FAKE_CURL_DIR/calls.log"
  assert_output 0
}

@test "round: IP lookup fails -> rc 1, Cloudflare never called" {
  public_ip_is '<html>'
  run wd_round
  assert_failure
  run grep -c 'cloudflare' "$FAKE_CURL_DIR/calls.log"
  assert_output 0
}

@test "round: Cloudflare read fails -> rc 1, no PATCH" {
  : > "$FAKE_CURL_DIR/routes"
  public_ip_is 8.8.4.4
  route GET '/dns_records/rec456' FAIL
  run wd_round
  assert_failure
  run grep -c '^PATCH' "$FAKE_CURL_DIR/calls.log"
  assert_output 0
}

@test "round: PATCH fails -> rc 1, no notify" {
  : > "$FAKE_CURL_DIR/routes"
  public_ip_is 8.8.4.4
  route_file GET '/dns_records/rec456' "$FIX/record.json"
  route_file PATCH '/dns_records/rec456' "$FIX/auth_error.json"
  route POST ntfy.test 'ok'
  run wd_round
  assert_failure
  run grep -c '^POST' "$FAKE_CURL_DIR/calls.log"
  assert_output 0
}
