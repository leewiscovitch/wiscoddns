# wiscoddns

A home-made dynamic DNS updater for Cloudflare: a small bash script in a container that keeps one **A record**
(for example `ddns.example.org`) pointed at your current **public IPv4** address.

```
docker pull ghcr.io/leewiscovitch/wiscoddns:1.0.0      # linux/amd64 and linux/arm64
```

## Why

Home internet connections get a public IP that changes now and then. Services you reach from outside (a VPN,
for example) need a name that follows it. Ready-made tools do this well; this one exists to **learn how to build
and ship a container image**: a Dockerfile, tests, CI, a registry, versioned releases. The app is deliberately
simple, and every file is commented for a reader who is learning. The concepts are explained, with real
commands and output, in **[docs/walkthrough.md](docs/walkthrough.md)**.

## How it works

```
            every WISCODDNS_INTERVAL seconds (default 300)
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ 1. public IPv4?   https://1.1.1.1/cdn-cgi/trace ─┐                       │
 │                   https://api.ipify.org ─────────┴─> valid + public?     │
 │                                                     both agree?          │
 │                   no ──> skip the round, count a failure                 │
 │ 2. record's IP?   Cloudflare API: GET .../dns_records/<id>               │
 │ 3. different?     Cloudflare API: PATCH {"content": "<new ip>"}          │
 │                   ntfy: "ddns.example.org changed from A to B" (optional)│
 │ 4. touch the heartbeat file (the Docker health check reads its age)      │
 └─────────────────────────────────────────────────────────────────────────┘
```

- Two IP sources, so one being down or returning junk (an error page, a captive portal, an IPv6 or private
  address) never reaches DNS. If both answer, they must agree
- The record's current value is read from the **Cloudflare API**, never from DNS (a local DNS server or a cache
  may answer something else)
- Only the record's address is changed. wiscoddns never creates or deletes records: create the record first
  (by hand or with OpenTofu/Terraform), and its TTL, proxy setting and comment stay as you set them
- The zone and record IDs are looked up by name at startup; a missing record or a token without access stops the
  program with one clear log line

## Configuration

Environment variables (see [.env.example](.env.example)):

| Variable | Default | Meaning |
| --- | --- | --- |
| `WISCODDNS_RECORD` | (required) | full record name, e.g. `ddns.example.org` (an existing A record) |
| `WISCODDNS_ZONE` | (required) | zone name, e.g. `example.org` |
| `WISCODDNS_TOKEN_FILE` | `/run/secrets/cloudflare_token` | file holding the Cloudflare API token |
| `WISCODDNS_INTERVAL` | `300` | seconds between rounds (at least 30) |
| `WISCODDNS_DRY_RUN` | `0` | `1` = log what would change, never change anything |
| `WISCODDNS_ONCE` | `0` | `1` = run one round and exit (0 = record is right, 1 = something failed) |
| `WISCODDNS_FAIL_ALERT_AFTER` | `3` | consecutive failed rounds before an ntfy alert (once; plus one on recovery) |
| `WISCODDNS_NTFY_URL` | empty | ntfy server, e.g. `https://ntfy.example.org`; notifications are off while empty |
| `WISCODDNS_NTFY_TOPIC` | `wiscoddns` | ntfy topic |
| `WISCODDNS_NTFY_TOKEN_FILE` | empty | file holding an ntfy access token, if the server needs one |
| `WISCODDNS_RUN_DIR` | `/tmp/wiscoddns` | where the heartbeat and the (0600) header files go |

**The token is read from a file**, not an environment variable: environment variables show up in
`docker inspect` and process listings. Inside the program it travels to curl in a 0600 header file
(`-H @file`), so it is never on a command line either.

### The Cloudflare token

Cloudflare dashboard → My Profile → API Tokens → Create Token → template **Edit zone DNS**, then:

- Permissions: **Zone → DNS → Edit** (change the record) and add **Zone → Zone → Read** (find the zone by name)
- Zone Resources: **Include → Specific zone → example.org** (this zone only)

## Running it

### docker run

```
printf '%s' 'YOUR_TOKEN' > cloudflare_token && sudo chown 10001 cloudflare_token && chmod 0400 cloudflare_token
docker run -d --name wiscoddns --restart unless-stopped \
  -e WISCODDNS_ZONE=example.org -e WISCODDNS_RECORD=ddns.example.org \
  -v "$PWD/cloudflare_token:/run/secrets/cloudflare_token:ro" \
  ghcr.io/leewiscovitch/wiscoddns:1.0.0
```

The container runs as UID **10001**, so the token file must be readable by that user.

### Docker Compose

```yaml
services:
  wiscoddns:
    image: ghcr.io/leewiscovitch/wiscoddns:1.0.0   # pin an exact version
    container_name: wiscoddns
    restart: unless-stopped
    environment:
      WISCODDNS_ZONE: example.org
      WISCODDNS_RECORD: ddns.example.org
    volumes:
      - ./secrets/cloudflare_token:/run/secrets/cloudflare_token:ro
    # Hardening: nothing in the image needs to be written, no Linux capabilities are needed
    read_only: true
    tmpfs:
      - /tmp/wiscoddns:uid=10001,mode=0700
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
```

## Troubleshooting

```
docker logs wiscoddns                                    # one line per event
docker inspect -f '{{.State.Health.Status}}' wiscoddns   # healthy / unhealthy / starting
```

Typical log lines:

```
2026-11-07T12:00:00Z INFO wiscoddns 1.0.0 starting: record=ddns.example.org zone=example.org interval=300s ...
2026-11-07T12:00:01Z INFO found zone 0123..., record 4567...
2026-11-07T12:00:02Z INFO ddns.example.org unchanged (203.0.113.9)
2026-11-07T12:05:02Z INFO ddns.example.org updated: 203.0.113.9 -> 198.51.100.7
2026-11-07T12:10:01Z WARN IP source https://api.ipify.org gave no valid public IPv4
2026-11-07T12:10:01Z ERROR Cloudflare API GET /zones?name=example.org failed: 10000: Authentication error
```

Try one round without changing anything (the same settings and token as the running container):

```
docker run --rm -e WISCODDNS_ONCE=1 -e WISCODDNS_DRY_RUN=1 \
  -e WISCODDNS_ZONE=example.org -e WISCODDNS_RECORD=ddns.example.org \
  -v "$PWD/cloudflare_token:/run/secrets/cloudflare_token:ro" \
  ghcr.io/leewiscovitch/wiscoddns:1.0.0; echo rc=$?
```

- `zone ... not found`: wrong `WISCODDNS_ZONE`, or the token has no access to that zone
- `A record ... not found`: create the record first (wiscoddns never creates one)
- `can't read token file`: the file isn't mounted, or isn't readable by UID 10001
- `unhealthy`: no good round for two intervals; `docker logs` says why

## Development

```
scripts/test.sh     # shellcheck + hadolint + bats, each in a pinned container (only Docker needed)
docker build -t wiscoddns:dev .
```

- `src/lib.sh`: the functions; `src/wiscoddns.sh`: startup and the loop; `src/healthcheck.sh`
- `tests/`: bats tests; `tests/fakes/curl` stands in for curl, so tests never use the network
- CI (`.github/workflows/ci.yml`) runs the same script plus a `docker build` on every push and pull request

See [AGENTS.md](AGENTS.md) for the rules (this repo is public, pin everything, docs with every change).

## Releasing

1. Add a section to [CHANGELOG.md](CHANGELOG.md) and commit it
2. Tag and push: `git tag -s v1.2.3 -m "wiscoddns 1.2.3" && git push origin v1.2.3`
3. `.github/workflows/release.yml` builds amd64 + arm64, pushes `1.2.3`, `1.2`, `1` and `sha-<commit>` to
   `ghcr.io/leewiscovitch/wiscoddns`, then scans the image with Trivy

Versions follow [SemVer](https://semver.org/): a new major version means something you set up has to change.

## Roadmap

- 2.0: the same program rewritten in Python (same image name, new major version)
- Maybe: AAAA (IPv6) records, several records, Prometheus metrics

## Licence

[MIT](LICENSE)
