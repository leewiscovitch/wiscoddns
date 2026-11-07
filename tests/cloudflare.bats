#!/usr/bin/env bats
# Cloudflare API calls: finding the zone and record, reading the address, changing it, and handling errors.
# Fixtures in tests/fixtures/ are shaped like real Cloudflare v4 responses (the IDs are fake).

setup() {
  load helpers
  # shellcheck source=../src/lib.sh
  source "$REPO_ROOT/src/lib.sh"
  FIX="$REPO_ROOT/tests/fixtures"
  export WISCODDNS_ZONE=example.org WISCODDNS_RECORD=ddns.example.org
  # The token travels in a header file, like in the real program
  WD_AUTH_HEADER_FILE="$BATS_TEST_TMPDIR/auth-header"
  echo 'Authorization: Bearer s3cr3t-t0ken' > "$WD_AUTH_HEADER_FILE"
}

@test "wd_lookup_ids finds the zone and record IDs by name" {
  route_file GET '/zones?name=example.org' "$FIX/zones.json"
  route_file GET '/zones/zone123/dns_records?type=A&name.exact=ddns.example.org' "$FIX/records.json"
  wd_lookup_ids
  [ "$WD_ZONE_ID" = zone123 ]
  [ "$WD_RECORD_ID" = rec456 ]
  run cat "$FAKE_CURL_DIR/calls.log"
  assert_line 'GET https://api.cloudflare.com/client/v4/zones?name=example.org'
  assert_line 'GET https://api.cloudflare.com/client/v4/zones/zone123/dns_records?type=A&name.exact=ddns.example.org'
}

@test "wd_lookup_ids: unknown zone -> rc 1, log names the zone" {
  route_file GET '/zones?name=' "$FIX/zones_empty.json"
  run wd_lookup_ids
  assert_failure
  assert_output --partial 'example.org'
}

@test "wd_lookup_ids: missing record -> rc 1, log says it must exist" {
  route_file GET '/zones?name=' "$FIX/zones.json"
  route_file GET '/dns_records' "$FIX/records_empty.json"
  run wd_lookup_ids
  assert_failure
  assert_output --partial 'ddns.example.org'
  assert_output --partial 'must exist'
}

@test "wd_cf_api: success false -> rc 1 with Cloudflare's message" {
  route_file GET '/zones?name=' "$FIX/auth_error.json"
  run wd_lookup_ids
  assert_failure
  assert_output --partial 'Authentication error'
}

@test "wd_cf_api: non-JSON body -> rc 1" {
  route GET '/zones' '<html>502 Bad Gateway</html>'
  run wd_cf_api GET /zones
  assert_failure
}

@test "wd_cf_api: connection failure -> rc 1" {
  route GET '/zones' FAIL
  run wd_cf_api GET /zones
  assert_failure
}

@test "wd_record_ip prints the record's current address" {
  WD_ZONE_ID=zone123 WD_RECORD_ID=rec456
  route_file GET '/zones/zone123/dns_records/rec456' "$FIX/record.json"
  run --separate-stderr wd_record_ip
  assert_success
  assert_output 198.51.100.7
}

@test "wd_record_ip: API error -> rc 1, no output" {
  WD_ZONE_ID=zone123 WD_RECORD_ID=rec456
  route_file GET '/dns_records/rec456' "$FIX/auth_error.json"
  run --separate-stderr wd_record_ip
  assert_failure
  assert_output ''
}

@test "wd_update_record PATCHes only the content" {
  WD_ZONE_ID=zone123 WD_RECORD_ID=rec456
  route_file PATCH '/zones/zone123/dns_records/rec456' "$FIX/patch_ok.json"
  run wd_update_record 8.8.4.4
  assert_success
  run cat "$FAKE_CURL_DIR/calls.log"
  assert_output 'PATCH https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec456 {"content":"8.8.4.4"}'
}

@test "wd_update_record: API error -> rc 1" {
  WD_ZONE_ID=zone123 WD_RECORD_ID=rec456
  route_file PATCH '/dns_records/rec456' "$FIX/auth_error.json"
  run wd_update_record 8.8.4.4
  assert_failure
}

@test "wd_update_record in dry run: no PATCH, logs DRY-RUN" {
  WD_ZONE_ID=zone123 WD_RECORD_ID=rec456
  export WISCODDNS_DRY_RUN=1
  run wd_update_record 8.8.4.4
  assert_success
  assert_output --partial 'DRY-RUN'
  run grep -c PATCH "$FAKE_CURL_DIR/calls.log"
  assert_output 0
}

@test "the token never appears in the curl command line" {
  route_file GET '/zones?name=' "$FIX/zones.json"
  route_file GET '/dns_records' "$FIX/records.json"
  route_file PATCH '/dns_records/rec456' "$FIX/patch_ok.json"
  wd_lookup_ids
  wd_update_record 8.8.4.4
  # a header file is used (-H @file) ...
  run grep -c -- '-H @' "$FAKE_CURL_DIR/argv.log"
  assert_output 3
  # ... and the token itself is on no command line
  run grep -c 's3cr3t' "$FAKE_CURL_DIR/argv.log"
  assert_output 0
}
