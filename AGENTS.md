# wiscoddns: instructions for AI agents and humans

A small dynamic-DNS updater: a bash script in a container that keeps one Cloudflare A record pointed at the
current public IPv4. It is also a **learning project** (building and shipping a container image), so clear
explanations matter as much as the code.

## Rules

- **This repo is public.** Never commit secrets, tokens, real zone or account IDs, LAN IPs, hostnames or other
  details of the network it runs in. Examples use `example.org` (and the documentation IP ranges
  `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`)
- **Documentation is part of every change.** Comment the why (not just the what) in scripts, the Dockerfile and
  workflows; keep `README.md` and `docs/walkthrough.md` in step with the code; add a `CHANGELOG.md` line
- **Pin everything exactly:** the base image by digest, tool images by version, GitHub Actions by commit SHA with
  the version in a comment (`uses: owner/action@<sha> # vX.Y.Z`). Never rely on `latest`
- **Test first.** `scripts/test.sh` runs shellcheck, hadolint and the bats tests in containers (only Docker is
  needed). It must pass before every commit; CI runs the same script
- Tests never use the network: `tests/fakes/curl` stands in for curl (see the comment at its top)

## Versioning and releases

- SemVer git tags `vX.Y.Z`. Pushing a tag runs `.github/workflows/release.yml`, which builds amd64 + arm64 and
  publishes `ghcr.io/leewiscovitch/wiscoddns:X.Y.Z` (also `X.Y`, `X`, `sha-<short>`)
- Every release gets a `CHANGELOG.md` section first. Users pin an exact version
- Breaking changes (renamed variables, changed behaviour) need a new major version

## Layout

- `src/lib.sh`: functions only (logging, IP lookup, Cloudflare API, ntfy, one round); sourced
- `src/wiscoddns.sh`: the entrypoint (config, startup checks, loop, signals); `src/healthcheck.sh`
- `tests/`: bats tests, the fake curl, JSON fixtures shaped like real Cloudflare responses
- `docs/walkthrough.md`: the concepts behind the image and the pipeline, with real commands
