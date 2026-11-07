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
