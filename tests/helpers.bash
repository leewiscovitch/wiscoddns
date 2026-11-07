# Shared setup for every .bats file:  load helpers   (at the top of the file)

# Assertions: assert_success, assert_output, assert_line ... (https://github.com/bats-core/bats-assert)
load '/usr/lib/bats/bats-support/load'
load '/usr/lib/bats/bats-assert/load'

# Repo root, whatever the current directory
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Each test gets its own empty temp dir (BATS_TEST_TMPDIR); the fake curl keeps its routes and call log there.
# tests/fakes goes first on PATH, so the code under test runs the fake curl, never the network.
export FAKE_CURL_DIR="$BATS_TEST_TMPDIR"
export PATH="$REPO_ROOT/tests/fakes:$PATH"
: > "$FAKE_CURL_DIR/routes"
: > "$FAKE_CURL_DIR/calls.log"

# route METHOD URL_SUBSTRING BODY
# Answer requests whose method is METHOD and whose URL contains URL_SUBSTRING with BODY. BODY "FAIL" makes the
# fake curl exit 7, like a connection failure. Earlier routes win, so add specific routes before general ones.
route() {
  local method=$1 substr=$2 body=$3 file
  if [ "$body" = FAIL ]; then
    file=FAIL
  else
    file=$(mktemp "$FAKE_CURL_DIR/body.XXXXXX")
    printf '%s' "$body" > "$file"
  fi
  echo "$method $substr $file" >> "$FAKE_CURL_DIR/routes"
}

# route_file METHOD URL_SUBSTRING FILE: like route, with the body read from a file (tests/fixtures/...)
route_file() {
  echo "$1 $2 $3" >> "$FAKE_CURL_DIR/routes"
}
