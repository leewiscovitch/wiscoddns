# Walkthrough: how wiscoddns is built, tested and shipped

A guided tour for a reader learning containers and CI. Each section explains one idea with the real commands
used in this repo and what their output looks like.

Sections (filled in as the project grows):

1. Testing (below)
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
