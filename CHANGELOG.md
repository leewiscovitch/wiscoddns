# Changelog

All notable changes are listed here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/) (git tag `vX.Y.Z` → image tags `X.Y.Z`, `X.Y`, `X`).

## [Unreleased]

- Test kit: `scripts/test.sh` (shellcheck, hadolint, bats in pinned containers), fake `curl`, CI on every push
- Public IPv4 lookup from two sources (Cloudflare trace, ipify), only valid public addresses, both must agree
- Cloudflare API: find zone and record by name, read the address, PATCH only `content`; dry run; token via a header file
- Main loop: startup checks, one-shot mode, ntfy on change/failures/recovery, clean exit on SIGTERM, health check
- Image: Ubuntu 26.04 (pinned by digest), tini, non-root UID 10001, health check, OCI labels; CI builds it
