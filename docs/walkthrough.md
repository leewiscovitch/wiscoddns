# Walkthrough: how wiscoddns is built, tested and shipped

A guided tour for a reader learning containers and CI. Each section explains one idea with the real commands
used in this repo and what their output looks like.

Sections (filled in as the project grows):

1. Testing
2. The app: one round, step by step
3. The image: layers, size, the base image digest, tini, the non-root user, the health check
4. CI: what runs on every push
5. Releasing: tags, SemVer, GHCR, multi-arch images, the vulnerability scan
6. Running it, upgrading and rolling back

## 1. Testing

### One command

```
$ scripts/test.sh
== shellcheck
2 files: ok
== hadolint
Dockerfile: not there yet, skipped
tests/Dockerfile: ok
== bats
1..4
ok 1 fake curl serves a route and logs the call
...
```

`scripts/test.sh` runs three tools, each **in a container pinned to an exact version** (`docker run --rm ...`):

- **shellcheck** reads shell scripts and points out bugs: unquoted variables, wrong tests, unused variables
- **hadolint** does the same for Dockerfiles (and runs shellcheck on their `RUN` lines)
- **bats** (Bash Automated Testing System) runs the tests in `tests/*.bats`

Why containers? Nothing to install except Docker; everybody (a laptop, GitHub's CI runner) runs the same
versions; bumping a tool is a one-line change in the script.

### What a test looks like

```bash
@test "fake curl serves a route and logs the call" {
  route GET example.org/x 'hello'        # set up: requests to .../x answer "hello"
  run curl -s https://example.org/x      # act: `run` captures exit status and output
  assert_success                         # check: exit status 0
  assert_output 'hello'                  # check: the output
}
```

`assert_success`, `assert_output` and friends come from the `bats-assert` library.

### The test image

The official `bats/bats` image is built on Alpine Linux: it has BusyBox tools and no `jq`. The real wiscoddns
image is Ubuntu with GNU tools and `jq`. To test against the same `bash`, `jq` and `date` that run in
production, `tests/Dockerfile` starts from the same Ubuntu base and **copies** bats out of the official image:

```dockerfile
COPY --from=bats/bats:1.13.0 /opt/bats /opt/bats
```

`COPY --from=<image>` takes files from another image without running it: a handy way to reuse a tool's files.

### No network in tests: the fake curl

wiscoddns talks to the outside world only through `curl`. The tests put `tests/fakes/` first on `PATH`, so
`curl` means the fake one: it answers from a list of routes the test sets up and writes down every call. A test
can then say "the IP service failed and Cloudflare returned an error" and check exactly which calls were made,
in a fraction of a second, without touching the internet.

## 2. The app: one round, step by step

`src/wiscoddns.sh` checks its settings, writes the token into a 0600 header file, looks up the zone and record IDs
by name, then repeats one **round** (`wd_round` in `src/lib.sh`):

```
$ docker run --rm -e WISCODDNS_ONCE=1 -e WISCODDNS_DRY_RUN=1 \
    -e WISCODDNS_ZONE=example.org -e WISCODDNS_RECORD=ddns.example.org \
    -v "$PWD/cloudflare_token:/run/secrets/cloudflare_token:ro" wiscoddns:dev
2026-11-07T05:39:47Z INFO wiscoddns dev starting: record=ddns.example.org zone=example.org interval=300s dry_run=1 alert_after=3 ntfy=off
2026-11-07T05:39:47Z INFO found zone <id>, record <id>
2026-11-07T05:39:48Z INFO ddns.example.org unchanged (203.0.113.9)
```

1. `wd_public_ip` asks both IP sources. `wd_is_public_ipv4` throws away anything that isn't a public IPv4 (error
   pages, IPv6, private ranges: each range is listed with its RFC in the code). Two valid answers must agree
2. `wd_record_ip` reads the record from the Cloudflare API
3. Same address: log `unchanged`, done. Different: `wd_update_record` sends a PATCH with only the new
   `content`, then `wd_notify` posts to ntfy

A failed round writes nothing; the loop counts failures and alerts once when the count reaches
`WISCODDNS_FAIL_ALERT_AFTER`, then once more when a round works again.

## 3. The image

The recipe is the [Dockerfile](../Dockerfile); every line has a comment. The ideas behind it:

### Layers

An image is a stack of read-only **layers**. Each `RUN`, `COPY` and `ADD` instruction adds one; the others
(`ENV`, `USER`, `LABEL`, ...) only change settings. `docker history` lists them, newest first:

```
$ docker history wiscoddns:dev --format '{{.Size}}\t{{.CreatedBy}}'
0B      ENTRYPOINT ["/usr/bin/tini" "--" "wiscoddns"]
0B      HEALTHCHECK {Test:[CMD wiscoddns-healthcheck…
0B      USER 10001
0B      ENV WISCODDNS_VERSION=dev
36.9kB  RUN ... chmod 0755 ... ln -s ...            <- links on PATH
45.1kB  COPY src/ /usr/local/lib/wiscoddns/         <- the scripts
41kB    RUN ... useradd --system --uid 10001 ...    <- the user
19.4MB  RUN ... apt-get install curl jq ca-certificates tini && rm -rf /var/lib/apt/lists/*
...
117MB   (the Ubuntu 26.04 base)
```

Two consequences:

- **Deleting a file in a later layer doesn't make the image smaller**: the file is still in the layer that added
  it. That's why the apt package lists are removed in the same `RUN` that downloads them
- **Layers are cached.** Docker rebuilds from the first changed instruction down. The scripts (which change
  often) are copied after the packages (which rarely do), so a code change rebuilds only the small top layers

`docker image ls wiscoddns:dev` reports **185 MB** (what it takes on disk, unpacked); about 117 MB of that is
the Ubuntu base, shared with any other image built on the same base.

### `apt-get`, not `apt`

The Dockerfile uses `apt-get`. Both install the same packages, but `apt` is meant for people at a terminal
(progress bars, colours) and its command-line interface may change between releases; it even says so when run
from a script: `WARNING: apt does not have a stable CLI interface. Use with caution in scripts.` `apt-get` keeps
a stable interface for scripts, and hadolint flags `apt` in a `RUN` line (rule DL3027). At your own terminal,
`apt` is the nicer one.

### Tags and digests

`ubuntu:26.04` is a **tag**: a name that can be moved to a new build at any time (security updates). A
**digest** like `sha256:6a06111c...` is the hash of the image's content: it can only ever mean those exact
bytes. The `FROM` line uses both: the tag for humans, the digest for repeatable builds.

```
$ docker buildx imagetools inspect ubuntu:26.04
Name:      docker.io/library/ubuntu:26.04
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
Manifests:
  Name:      docker.io/library/ubuntu:26.04@sha256:157dc3d6...
  Platform:  linux/amd64
  ...
```

The top digest is an **index** (a list of one image per CPU architecture); Docker picks the right one for the
machine. Dependabot watches the digest and opens a pull request when Ubuntu publishes a new build.

### PID 1 and tini

The first process in a container is PID 1, and Linux treats PID 1 specially: signals with no handler are
ignored, and orphaned child processes are left to it to clean up. A bash script makes a poor PID 1. **tini**
is a tiny init made for this: it starts the script as its child, forwards `SIGTERM` from `docker stop` to it, and
reaps zombies. The script also handles `SIGTERM` itself (it sleeps in the background and `wait`s, so the
signal is handled at once instead of after the sleep):

```
$ docker stop wiscoddns       # returns in about a second, not after Docker's 10 s timeout
$ docker logs wiscoddns | tail -1
2026-11-07T12:05:00Z INFO stopping (signal received)
```

### Not root

`USER 10001` makes the program run as an unprivileged user. If it were ever tricked into running something,
that something couldn't change the image's files or read files it doesn't own. The fixed number matters
outside the container too: the token file mounted from the host is owned by UID 10001 with mode `0400`.

```
$ docker run --rm --entrypoint id wiscoddns:dev
uid=10001(wiscoddns) gid=999(wiscoddns) groups=999(wiscoddns)
```

### The health check

`HEALTHCHECK` tells Docker how to test the app from inside: every 60 s it runs `wiscoddns-healthcheck`, which
is healthy while the last good round is younger than two intervals. Docker shows the result:

```
$ docker inspect -f '{{.State.Health.Status}}' wiscoddns
healthy
```

### Fail fast

Missing settings stop the program at once, with one line that says what's wrong:

```
$ docker run --rm wiscoddns:dev; echo rc=$?
2026-11-07T05:15:07Z ERROR WISCODDNS_RECORD is not set (the full record name, e.g. ddns.example.org)
rc=1
```

## 4. CI: what runs on every push

[.github/workflows/ci.yml](../.github/workflows/ci.yml) runs on GitHub's machines (a fresh Ubuntu VM per job)
for every push and pull request:

- **test**: `scripts/test.sh`, exactly as on a laptop
- **build**: `docker build` of the real image (nothing is published); runs only if `test` passed (`needs: test`)

```
$ gh run view 42342728882          # the run id comes from: gh run list --workflow ci
✓ main ci · 42342728882
JOBS
✓ test in 24s
✓ build in 23s
```

Both job names are **required status checks** on `main` (branch protection, managed with OpenTofu from the
author's homelab repo): a pull request can't merge while either is red.

**Why actions are pinned by SHA.** `uses: actions/checkout@v7` follows a tag that the action's owner can move;
if that account were compromised, every workflow using it would run the attacker's code. A commit SHA can't be
moved. The comment keeps it readable, and Dependabot proposes updates:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

**Least privilege.** `permissions: contents: read` gives the workflow's automatic `GITHUB_TOKEN` read access
only. The release workflow adds `packages: write`, the one extra thing it needs.

## 5. Releasing

A release is a **git tag**. Pushing `v1.0.0` starts [release.yml](../.github/workflows/release.yml):

```
$ git tag -s v1.0.0 -m "wiscoddns 1.0.0"     # -s signs the tag (shows "Verified" on GitHub)
$ git push origin v1.0.0
$ gh run watch                                # follow it live
```

1. **QEMU + Buildx** build the image twice, for `linux/amd64` (PCs, servers) and `linux/arm64` (Raspberry Pi,
   ARM servers). The arm64 build runs under emulation, which is why it is the slow part
2. **metadata-action** turns the git tag into image tags: `1.0.0`, `1.0`, `1` and `sha-<commit>`
3. **build-push-action** pushes both builds under one **multi-arch index** to `ghcr.io/leewiscovitch/wiscoddns`;
   `docker pull` picks the right one for the machine
4. **Trivy** scans the pushed image for known vulnerabilities (CVEs). Fixable CRITICAL or HIGH findings turn the
   run red: rebuild on a newer base (Dependabot's pull request) and release a patch version

This happened on the very first release. The image was already pushed when the scan failed:

```
Total: 2 (HIGH: 2, CRITICAL: 0)
│ apt           │ CVE-2026-109518 │ HIGH │ fixed │ 3.2.0 │ 3.2.1ubuntu0.1 │ apt: Remote code execution ...
│ libapt-pkg7.0 │                 │      │       │       │                │
```

Ubuntu had the fix in its mirrors but hadn't rebuilt the `ubuntu:26.04` base yet. The Dockerfile now runs
`apt-get upgrade` before installing packages, and 1.0.1 went out with the fix. Tags are never moved or
reused: 1.0.0 stays as it was, and the CHANGELOG says to use 1.0.1.

### SemVer and the moving tags

[Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`. PATCH = fixes, MINOR = new features that
change nothing for existing users, MAJOR = something users must change (a renamed variable, new behaviour).

| Image tag | Points to | Who uses it |
| --- | --- | --- |
| `1.0.0` | exactly this build, forever | deployments (pin this) |
| `1.0` | the newest `1.0.x` | "give me fixes" |
| `1` | the newest `1.x.y` | "give me anything compatible" |
| `sha-abc1234` | the build of that commit | tracing an image to its code |

There is deliberately no `latest`: it says nothing about what you get.

### GHCR and package visibility

GitHub Container Registry stores images next to the repo. A package that a workflow pushes from a repo, with
the `org.opencontainers.image.source` label pointing at it, is **linked** to that repo and takes its visibility:
this repo is public, so the package was public from the first push (GitHub's docs say a new package may start
private; check the package page, and change it there under Package settings → Change visibility if needed).
Anyone can pull without logging in:

```
$ DOCKER_CONFIG=$(mktemp -d) docker pull -q ghcr.io/leewiscovitch/wiscoddns:1.0.1   # empty config = anonymous
ghcr.io/leewiscovitch/wiscoddns:1.0.1
```

The `org.opencontainers.image.source` label in the Dockerfile is what links the package to this repo.

## 6. Running it, upgrading and rolling back

Pin the exact version (`ghcr.io/leewiscovitch/wiscoddns:1.0.1`) in compose or `docker run`. To **upgrade**,
change the tag and recreate the container (`docker compose up -d`); to **roll back**, put the old tag back and
do the same: every version stays in the registry. For a stronger pin, use the digest:

```
$ docker buildx imagetools inspect ghcr.io/leewiscovitch/wiscoddns:1.0.1 --format '{{.Manifest.Digest}}'
sha256:...
# image: ghcr.io/leewiscovitch/wiscoddns:1.0.1@sha256:...
```
