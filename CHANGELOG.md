# Changelog

All notable changes are listed here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/) (git tag `vX.Y.Z` → image tags `X.Y.Z`, `X.Y`, `X`).

## [Unreleased]

## [1.0.1] - 2026-11-07

### Security

- Image: install pending Ubuntu security updates at build time (`apt-get upgrade`). 1.0.0 shipped `apt` 3.2.0
  with CVE-2026-109518 (HIGH, fixed in 3.2.1ubuntu0.1), which the base image didn't include yet. The release
  scan caught it; use 1.0.1

## [1.0.0] - 2026-11-07

First release.

- Test kit: `scripts/test.sh` (shellcheck, hadolint, bats in pinned containers), fake `curl`, CI on every push
- Public IPv4 lookup from two sources (Cloudflare trace, ipify), only valid public addresses, both must agree
- Cloudflare API: find zone and record by name, read the address, PATCH only `content`; dry run; token via a header file
- Main loop: startup checks, one-shot mode, ntfy on change/failures/recovery, clean exit on SIGTERM, health check
- Image: Ubuntu 26.04 (pinned by digest), tini, non-root UID 10001, health check, OCI labels; CI builds it

[Unreleased]: https://github.com/leewiscovitch/wiscoddns/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/leewiscovitch/wiscoddns/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/leewiscovitch/wiscoddns/releases/tag/v1.0.0
