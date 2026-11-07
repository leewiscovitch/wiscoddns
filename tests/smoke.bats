#!/usr/bin/env bats
# Smoke tests for the test kit itself: if the fake curl is broken, every other test means nothing.

setup() {
  load helpers
}

@test "fake curl serves a route and logs the call" {
  route GET example.org/x 'hello'
  run curl -s https://example.org/x
  assert_success
  assert_output 'hello'
  run cat "$FAKE_CURL_DIR/calls.log"
  assert_output --partial 'GET https://example.org/x'
}

@test "fake curl FAIL route exits 7 like a connection failure" {
  route GET example.org/x FAIL
  run curl -s https://example.org/x
  assert_failure 7
}

@test "fake curl with no matching route exits 7" {
  run curl -s https://example.org/nothing
  assert_failure 7
}

@test "fake curl takes the method from -X and logs --data" {
  route PATCH example.org/r 'ok'
  run curl -sS -X PATCH -H 'Content-Type: application/json' --data '{"a":1}' https://example.org/r
  assert_success
  assert_output 'ok'
  run cat "$FAKE_CURL_DIR/calls.log"
  assert_output 'PATCH https://example.org/r {"a":1}'
}

@test "fake curl route with TIMES answers that many calls, then the next route" {
  route GET example.org/x FAIL 2
  route GET example.org/x 'ok'
  run curl -s https://example.org/x
  assert_failure 7
  run curl -s https://example.org/x
  assert_failure 7
  run curl -s https://example.org/x
  assert_success
  assert_output 'ok'
}
