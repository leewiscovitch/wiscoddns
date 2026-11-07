# wiscoddns image. Every line is explained; docs/walkthrough.md covers the ideas in more depth.
# Build: docker build --build-arg VERSION=1.0.0 --build-arg REVISION=$(git rev-parse HEAD) -t wiscoddns .

# Base image: Ubuntu 26.04 LTS, pinned by digest. A tag like "26.04" can be re-pointed to a newer build at any
# time; the digest (a SHA-256 of the image's manifest) always means exactly the same bytes. Dependabot opens a
# pull request when a new digest is published. To see the current one:
#   docker buildx imagetools inspect ubuntu:26.04
FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c

# Build arguments: set by the release workflow (VERSION from the git tag, REVISION = the commit SHA).
# A plain local build gets "dev" / "unknown".
ARG VERSION=dev
ARG REVISION=unknown

# OCI labels: metadata stored in the image (docker image inspect shows them). "source" is what links the
# package on GitHub Container Registry to this repo.
LABEL org.opencontainers.image.title="wiscoddns" \
      org.opencontainers.image.description="Keeps a Cloudflare A record pointed at the public IPv4" \
      org.opencontainers.image.source="https://github.com/leewiscovitch/wiscoddns" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Packages, in one RUN so they form one layer:
#   curl            HTTP client for the IP sources, Cloudflare and ntfy
#   jq              reads and writes JSON
#   ca-certificates lets curl check HTTPS certificates
#   tini            a tiny init for PID 1: passes signals on (docker stop -> SIGTERM reaches the script) and
#                   reaps zombie processes. Built into the image rather than compose's "init: true", so the image
#                   behaves the same however it is run
# --no-install-recommends skips "nice to have" packages. The apt lists are deleted in the same RUN: a file
# deleted in a later layer still takes space in the earlier one.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

# An unprivileged user with a fixed UID (10001, above any host's normal users), so file ownership on mounted
# secrets is predictable (the homelab gives the token file owner 10001, mode 0400). No home, no login shell.
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin wiscoddns

# The scripts (read-only for everyone, owned by root: the running user can't change them), plus short names
# on PATH. .dockerignore keeps everything except src/ out of the build context.
COPY src/ /usr/local/lib/wiscoddns/
RUN chmod 0755 /usr/local/lib/wiscoddns/*.sh \
 && ln -s /usr/local/lib/wiscoddns/wiscoddns.sh /usr/local/bin/wiscoddns \
 && ln -s /usr/local/lib/wiscoddns/healthcheck.sh /usr/local/bin/wiscoddns-healthcheck

# The program logs its version at startup
ENV WISCODDNS_VERSION=${VERSION}

# Run as that user from here on (by number, so it works even without /etc/passwd lookups)
USER 10001

# Docker runs this every 60 s; healthy while the last good round is younger than two intervals.
# start-period: grace time for the first round.
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s CMD ["wiscoddns-healthcheck"]

# tini is PID 1 and starts the script as its child. Exec form (a JSON list): no shell in between to eat signals.
ENTRYPOINT ["/usr/bin/tini", "--", "wiscoddns"]
