# wiscoddns

A home-made dynamic DNS updater for Cloudflare: a small bash script in a container that keeps one **A record**
(for example `ddns.example.org`) pointed at your current **public IPv4** address.

**Status:** in development (1.0 not released yet).

## Why

Home internet connections get a public IP that changes now and then. Services you reach from outside (a VPN,
for example) need a name that follows it. Ready-made tools do this well; this one exists to **learn how to build
and ship a container image**: a Dockerfile, tests, CI, a registry, versioned releases. The app itself is
deliberately simple, and every file is commented for a reader who is learning. Start with
[docs/walkthrough.md](docs/walkthrough.md).

## What it does (1.0)

Every few minutes:

1. Asks two outside services for the public IPv4 and only trusts a valid, public address (both must agree when
   both answer)
2. Reads the record's current address from the Cloudflare API
3. If they differ, changes only the record's address (it never creates or deletes records)
4. Optionally sends an [ntfy](https://ntfy.sh) notification on a change, or when lookups keep failing

## Sections still to write

- How it works, configuration, running it (`docker run`, compose), troubleshooting, releasing, roadmap

## Development

```
scripts/test.sh     # shellcheck + hadolint + bats, each in a pinned container (only Docker needed)
```

See [AGENTS.md](AGENTS.md) for the rules (this repo is public, pin everything, docs with every change).

## Licence

[MIT](LICENSE)
