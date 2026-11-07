# Changelog

All notable changes are listed here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/) (git tag `vX.Y.Z` → image tags `X.Y.Z`, `X.Y`, `X`).

## [Unreleased]

- Test kit: `scripts/test.sh` (shellcheck, hadolint, bats in pinned containers), fake `curl`, CI on every push
- Public IPv4 lookup from two sources (Cloudflare trace, ipify), only valid public addresses, both must agree
