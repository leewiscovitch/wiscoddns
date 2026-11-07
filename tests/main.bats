#!/usr/bin/env bats
# The program: startup checks, one-shot mode, the loop (alerts, recovery), signals, and the health check.

setup() {
  load helpers
  FIX="$REPO_ROOT/tests/fixtures"
  MAIN="$REPO_ROOT/src/wiscoddns.sh"
  HEALTH="$REPO_ROOT/src/healthcheck.sh"
  export WISCODDNS_ZONE=example.org WISCODDNS_RECORD=ddns.example.org
  export WISCODDNS_RUN_DIR="$BATS_TEST_TMPDIR/run"
  export WISCODDNS_TOKEN_FILE="$BATS_TEST_TMPDIR/token"
  printf 's3cr3t\n' > "$WISCODDNS_TOKEN_FILE"
  export WISCODDNS_NTFY_URL=http://ntfy.test WISCODDNS_NTFY_TOPIC=alerts
}

# Cloudflare knows the zone and record; the public IP equals the record (8.8.4.4): a quiet, healthy round
happy_routes() {
  route GET 1.1.1.1/cdn-cgi/trace 'ip=8.8.4.4'
  route GET api.ipify.org 8.8.4.4
  route_file GET '/zones?name=' "$FIX/zones.json"
  route_file GET '/dns_records?type=A' "$FIX/records.json"
  route_file GET '/dns_records/rec456' "$FIX/patch_ok.json"
  route POST ntfy.test ok
}

@test "main: WISCODDNS_RECORD unset -> rc 1, log names the variable" {
  unset WISCODDNS_RECORD
  run "$MAIN"
  assert_failure 1
  assert_output --partial 'WISCODDNS_RECORD'
}

@test "main: interval below the minimum -> rc 1" {
  export WISCODDNS_INTERVAL=5
  run "$MAIN"
  assert_failure 1
  assert_output --partial 'WISCODDNS_INTERVAL'
}

@test "main: interval not a number -> rc 1" {
  export WISCODDNS_INTERVAL=5m
  run "$MAIN"
  assert_failure 1
  assert_output --partial 'WISCODDNS_INTERVAL'
}

@test "main: token file missing -> rc 1" {
  rm "$WISCODDNS_TOKEN_FILE"
  run "$MAIN"
  assert_failure 1
  assert_output --partial "$WISCODDNS_TOKEN_FILE"
}

@test "main: token file empty (only whitespace) -> rc 1" {
  printf ' \n' > "$WISCODDNS_TOKEN_FILE"
  run "$MAIN"
  assert_failure 1
  assert_output --partial 'empty'
}

@test "main: token with a trailing newline -> exact header line, file mode 600, token never logged" {
  happy_routes
  export WISCODDNS_ONCE=1
  run "$MAIN"
  assert_success
  refute_output --partial 's3cr3t'
  assert_equal "$(cat "$WISCODDNS_RUN_DIR/auth-header")" 'Authorization: Bearer s3cr3t'
  assert_equal "$(stat -c %a "$WISCODDNS_RUN_DIR/auth-header")" 600
}

@test "main: record lookup fails -> rc 1 with Cloudflare's message" {
  route_file GET '/zones?name=' "$FIX/auth_error.json"
  run "$MAIN"
  assert_failure 1
  assert_output --partial 'Authentication error'
}

@test "main: WISCODDNS_ONCE=1 happy path -> rc 0, version logged, heartbeat written" {
  happy_routes
  export WISCODDNS_ONCE=1 WISCODDNS_VERSION=9.9.9
  run "$MAIN"
  assert_success
  assert_output --partial '9.9.9'
  assert_output --partial 'unchanged'
  [ -f "$WISCODDNS_RUN_DIR/heartbeat" ]
}

@test "main: WISCODDNS_ONCE=1 failing round -> rc 1, no heartbeat" {
  route GET 1.1.1.1 FAIL
  route GET api.ipify.org FAIL
  route_file GET '/zones?name=' "$FIX/zones.json"
  route_file GET '/dns_records?type=A' "$FIX/records.json"
  export WISCODDNS_ONCE=1
  run "$MAIN"
  assert_failure 1
  [ ! -f "$WISCODDNS_RUN_DIR/heartbeat" ]
}

@test "main loop: 3 failed rounds then success -> one failure alert, one recovered alert" {
  route GET '/dns_records/rec456' FAIL 3      # Cloudflare is down for the first 3 rounds
  happy_routes
  export WISCODDNS_MIN_INTERVAL=1 WISCODDNS_INTERVAL=1
  "$MAIN" > "$BATS_TEST_TMPDIR/out" 2>&1 3>&- &
  pid=$!
  for _ in $(seq 1 100); do
    grep -q recovered "$FAKE_CURL_DIR/calls.log" && break
    sleep 0.1
  done
  kill -TERM "$pid"
  wait "$pid" || true
  run grep -c '^POST http://ntfy.test/alerts .*failed in a row' "$FAKE_CURL_DIR/calls.log"
  assert_output 1
  run grep -c '^POST http://ntfy.test/alerts .*recovered' "$FAKE_CURL_DIR/calls.log"
  assert_output 1
}

@test "main loop: SIGTERM while sleeping -> exits 0 within 2 s" {
  happy_routes
  export WISCODDNS_INTERVAL=300
  "$MAIN" > "$BATS_TEST_TMPDIR/out" 2>&1 3>&- &
  pid=$!
  for _ in $(seq 1 50); do
    [ -f "$WISCODDNS_RUN_DIR/heartbeat" ] && break
    sleep 0.1
  done
  [ -f "$WISCODDNS_RUN_DIR/heartbeat" ]   # the first round finished, it is sleeping now
  kill -TERM "$pid"
  start=$SECONDS
  rc=0
  wait "$pid" || rc=$?
  assert_equal "$rc" 0
  (( SECONDS - start <= 2 ))
  run cat "$BATS_TEST_TMPDIR/out"
  assert_output --partial 'stopping'
}

@test "healthcheck: fresh heartbeat -> 0" {
  mkdir -p "$WISCODDNS_RUN_DIR"
  touch "$WISCODDNS_RUN_DIR/heartbeat"
  run "$HEALTH"
  assert_success
}

@test "healthcheck: heartbeat older than 2 x interval -> 1" {
  mkdir -p "$WISCODDNS_RUN_DIR"
  export WISCODDNS_INTERVAL=300
  touch -d '@'$(($(date +%s) - 601)) "$WISCODDNS_RUN_DIR/heartbeat"
  run "$HEALTH"
  assert_failure 1
}

@test "healthcheck: no heartbeat -> 1" {
  run "$HEALTH"
  assert_failure 1
}
