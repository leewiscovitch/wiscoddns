#!/usr/bin/env bash
# One command for every check: shellcheck (shell lint), hadolint (Dockerfile lint) and bats (tests).
# The same script runs on a laptop and in CI (.github/workflows/ci.yml), so "green here" means "green there".
#
# Every tool runs in a container pinned to an exact version: nothing to install on the host but Docker, and
# everyone gets the same tool versions. Usage, from anywhere:  scripts/test.sh
set -euo pipefail

# Pinned tool images (bump deliberately, then rerun this script)
SHELLCHECK_IMAGE=koalaman/shellcheck:v0.11.0
HADOLINT_IMAGE=hadolint/hadolint:v2.14.0

cd "$(dirname "$0")/.."   # repo root, whatever the caller's directory

# The repo is mounted read-only: checks must never change files
run() { docker run --rm -v "$PWD:/code:ro" -w /code "$@"; }

echo "== shellcheck"
# -x follows `source` lines so functions from src/lib.sh are known in the files that load it
shopt -s nullglob   # a pattern with no matches expands to nothing (src/ may still be empty)
files=(src/*.sh scripts/*.sh tests/fakes/*)
run "$SHELLCHECK_IMAGE" -x "${files[@]}"
echo "${#files[@]} files: ok"

echo "== hadolint"
for f in Dockerfile tests/Dockerfile; do
  # The Dockerfile is read on stdin (docker run -i); the settings in .hadolint.yaml are mounted where
  # hadolint looks for its config
  docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" "$HADOLINT_IMAGE" < "$f"
  echo "$f: ok"
done

echo "== bats"
# The test image is Ubuntu (same bash, jq and coreutils as the real image) with bats copied in: see
# tests/Dockerfile. Docker caches it, so only the first run pays for the build.
docker build -q -t wiscoddns-test -f tests/Dockerfile tests >/dev/null
run wiscoddns-test tests
