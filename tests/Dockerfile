# Test image: the same Ubuntu base as the real image (so bash, jq and coreutils behave the same) plus bats.
# Built and run by scripts/test.sh; never published.

# Same base and digest as ../Dockerfile (Dependabot bumps both)
FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c

# jq: the app parses Cloudflare's JSON with it. curl is NOT installed: tests use the fake in tests/fakes/
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*

# bats-core and its helper libraries (bats-support, bats-assert, bats-file), copied from the official image
COPY --from=bats/bats:1.13.0 /opt/bats /opt/bats
COPY --from=bats/bats:1.13.0 /usr/lib/bats /usr/lib/bats

WORKDIR /code
ENTRYPOINT ["/opt/bats/bin/bats"]
