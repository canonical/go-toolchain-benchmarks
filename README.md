# Go Toolchain Benchmarks on Ubuntu

This repository documents a reproducible benchmarking study comparing
**Go 1.26.7** against **Go 1.27.0** on Ubuntu, run on real hardware through
Canonical's [Testflinger](https://canonical-testflinger.readthedocs-hosted.com/)
device lab. Two Ubuntu releases were tested:

| OS | Role | How it was provisioned |
|---|---|---|
| Ubuntu 26.04 LTS | Control | Clean MAAS install of `resolute` |
| Ubuntu 26.10 | Target | MAAS install of `resolute`, then an in-place APT upgrade to `stonking` and a reboot |

The 26.10 leg needs some explanation. The lab's MAAS server did not carry
26.10 ("stonking") images at the time of the run, while the Ubuntu archive
already had a live stonking suite. So the 26.10 jobs install 26.04 first,
upgrade in place using `scripts/dut-upgrade-stonking.sh`, reboot into the
stonking kernel, and verify `/etc/os-release` before any benchmarking
starts. This is an upgraded-to-devel system rather than a clean install,
and the pre- and post-upgrade package manifests are kept in the artifacts
for audit. The 26.10 measurements were taken on 2026-10-10, a few days
before the release.

## What we found

The full data is in [RESULTS.md](RESULTS.md), and a narrative write-up is
in [discourse-post.md](discourse-post.md). In short:

- Allocation-heavy workloads improve by 3 to 11 percent with Go 1.27,
  matching the release notes' size-specialized malloc change.
- JSON unmarshal is dramatically faster (up to 87 percent), but JSON
  marshal on struct-heavy workloads regresses by 29 to 42 percent. The
  regression is tracked upstream as
  [golang/go#81315](https://github.com/golang/go/issues/81315) and our
  numbers independently corroborate it on both Ubuntu releases.
- Go builds are up to 7 percent faster, flate decode is 9 to 20 percent
  faster, and binaries grow by about 4 percent.
- Etcd Put latency regresses on 26.10 only (about 4 to 8 percent), a
  possible kernel and runtime interaction that remains an open item.

## How the study was run

Every run happened on the same physical machine: an HPE ProLiant DL385
Gen10 Plus with an AMD EPYC 7302 (16 cores, 32 threads) and 62 GiB of RAM,
with the CPU governor pinned to performance. Both OS legs were submitted
to a Testflinger queue served by exactly one agent, so there is no
possibility of the two legs landing on different hardware. Machine
identity is proven with DMI serial and UUID captured on each run and
checked during analysis.

Both Go toolchains were installed side by side on every provisioning,
into `/opt/go1.26.7` and `/opt/go1.27.0`, after SHA-256 verification of
the official tarballs. `GOTOOLCHAIN=local` was set throughout so Go could
not silently download a different toolchain. All benchmark sources are
pinned by commit in [versions.env](versions.env); the benchmarks
repository has no release tags, so the commit is the reproducibility
anchor.

The workload has three parts:

1. The upstream `golang.org/x/benchmarks` test suite (the GC latency
   benchmarks at the pinned commit), run in two interleaved passes with
   the baseline and experiment alternating first place, for 6 observations
   per toolchain.
2. Sweet, the Go team's real-world benchmark suite (CockroachDB, etcd,
   esbuild, gopher-lua, bleve, tile38, markdown, and go-build at this
   commit), run once per OS with both toolchains in a single configuration
   and 10 iterations, because results from separate Sweet invocations are
   not comparable.
3. An extras round covering the Go 1.27 release-note claims that Sweet
   does not exercise: `encoding/json` and `compress/flate` stdlib
   benchmarks, a binary size comparison, and a rerun of the one regression
   candidate from the main campaign.

All results were analyzed with benchstat from a pinned `x/perf` commit,
and only statistically significant changes (p < 0.05) are reported.

## Repository layout

```
README.md                    # this file
RESULTS.md                   # consolidated results with all numbers
discourse-post.md            # narrative write-up for Ubuntu Discourse
versions.env                 # every version pin and checksum
scripts/                     # DUT-side setup, benchmark, and metadata scripts
testflinger/                 # job definitions (smoke, campaign, extras)
runs/                        # raw results, benchstat reports, system metadata
```

## Reproducing

You need access to a Testflinger server and a queue backed by a single
amd64 agent with at least 16 GiB of RAM. Authenticate with
`testflinger-cli login` (the token lasts 6 days), then:

```sh
cd testflinger
testflinger-cli submit ubuntu-26.04-amd64.yaml   # note the job ID
testflinger-cli submit ubuntu-26.10-amd64.yaml   # queues behind the first
testflinger-cli poll <job-id>
```

The extras jobs (`extras-26.04.yaml`, `extras-26.10.yaml`) follow the same
pattern. Smoke jobs (`smoke-*.yaml`) are short validation runs and a good
way to check a new queue before committing a machine to a full day of
benchmarking.

When the jobs finish, pull the artifacts and analyze:

```sh
testflinger-cli artifacts <job-id-26.04>
testflinger-cli artifacts <job-id-26.10>
./scripts/analyze-results.sh <artifacts-26.04-dir> <artifacts-26.10-dir>
```

## Scope and caveats

The study covers amd64 only, because Sweet itself supports just
linux/amd64 (gVisor is permanently amd64-only). It is also a single
machine, so the absolute numbers describe that hardware, not a fleet. The
gVisor Sweet workload is out of scope because it is currently broken
upstream ([go.dev/issue/72042](https://go.dev/issue/72042)); at this
benchmarks commit it does not even build with Go 1.26.7, which is recorded
as an explicit failure in the extras artifacts.

When reading across the two OS legs, compare the relative Go version
deltas within each release rather than raw cross-OS timings, since the
kernel and userspace differences between 26.04 and 26.10 confound direct
comparison.
