# Go Toolchain Benchmarks on Ubuntu: go1.26.7 vs go1.27.0

Reproducible Testflinger campaign comparing **go1.26.7** (baseline) against
**go1.27.0** (experiment) using upstream `golang.org/x/benchmarks` — including
**Sweet** — on a fixed physical amd64 DUT, across:

| OS | Role | Provisioning |
|---|---|---|
| Ubuntu 26.04 LTS | Control | MAAS distro `resolute` |
| Ubuntu 26.10 devel | Target | MAAS distro `resolute`, then in-place APT upgrade to `stonking` + reboot |

> **26.10 provisioning note:** the lab MAAS (`cert-maas-tel-01`) has no
> `stonking` images (valid `distro_series` stop at `ubuntu/resolute`,
> verified 2026-10-08), while archive.ubuntu.com carries a live `stonking`
> suite. The 26.10 jobs therefore provision 26.04 and upgrade in place
> (`scripts/dut-upgrade-stonking.sh`), reboot into the stonking kernel, and
> verify `/etc/os-release` before benchmarking. This is an
> *upgraded-to-devel* system, not a clean install; pre/post-upgrade package
> manifests and source files are preserved in artifacts for audit.

## Methodology

- **Fixed DUT:** both OS jobs target the `chakron` queue, which is served by
  exactly one agent (HPE ProLiant DL385 Gen10 Plus, AMD EPYC "Rome",
  TOR3-DH1). Queue selection alone does not prove same-hardware execution;
  a single-agent queue does. Machine identity (DMI serial/UUID) is captured
  in artifacts and checked by `scripts/analyze-results.sh`.
- **Exclusivity:** submit both full jobs back-to-back. `chakron` also serves
  shared queues (`rome`, `sonic-ci`, `maas-systemtests-amd64-new`), but all
  had 0 waiting jobs at planning time, and our second job is already queued
  when the first completes.
- **Both toolchains on each provisioning:** go1.26.7 and go1.27.0 are
  installed side-by-side into immutable GOROOTs (`/opt/go1.26.7`,
  `/opt/go1.27.0`) after SHA-256 verification. `GOTOOLCHAIN=local` prevents
  silent toolchain downloads. `x/benchmarks` requires `go >= 1.26.0` at the
  pinned commit, so both toolchains work.
- **Interleaved ordering:** `x/benchmarks` runs in two passes —
  (baseline, experiment) then (experiment, baseline), `-count=3` each —
  giving 6 observations per toolchain with balanced first/second-run effects.
- **Sweet:** ONE `sweet run` invocation with both GOROOTs in a single
  `config.toml`, default group, `-count=10`. Sweet explicitly warns against
  comparing results from separate invocations.
- **Architecture scope:** amd64 only (phase one). Sweet supports only
  `linux/amd64` (gVisor is permanently amd64-only), so arm64 is a separately
  qualified follow-up, not part of this campaign.

## Pins

All versions live in [`versions.env`](versions.env): Go tarballs + SHA-256s
(from `https://go.dev/dl/?mode=json&include=all`), `x/benchmarks` commit
`7069376...`, `x/perf` (benchstat) commit `ebcb479...`. The benchmarks
repository has no tags; the commit pin is the reproducibility anchor.

## Layout

```
versions.env                 # all version pins
scripts/
  dut-setup.sh               # DUT: deps, toolchains, pinned clone, sweet build/assets
  dut-upgrade-stonking.sh    # DUT (26.10 jobs only): resolute -> stonking upgrade
  dut-metadata.sh            # DUT: machine identity + system state capture
  dut-benchmark.sh           # DUT: interleaved x/benchmarks + Sweet + benchstat
  sweet-config.toml          # both GOROOTs in one Sweet config
  analyze-results.sh         # local: verify identity, print benchstat reports
testflinger/
  smoke-26.04.yaml           # fast validation job (ephemeral provisioning)
  smoke-26.10.yaml
  ubuntu-26.04-amd64.yaml    # full campaign job
  ubuntu-26.10-amd64.yaml
```

## Running

Prerequisite: `testflinger-cli login` (Ubuntu One SSO device flow; token
lasts 6 days).

1. **Smoke tests** (validates distro names, downloads, builds, asset fetch;
   ~45–90 min each; 26.10 also validates the upgrade + reboot path):
   ```sh
   cd testflinger
   testflinger-cli submit smoke-26.04.yaml --poll
   testflinger-cli submit smoke-26.10.yaml --poll
   ```
   Smoke jobs use persistent (non-ephemeral) provisioning on purpose:
   ephemeral in-memory deployments do not have enough space for Sweet's
   asset set (observed failure in the first smoke run).

2. **Full campaign** (submit back-to-back; expect many hours each):
   ```sh
   testflinger-cli submit ubuntu-26.04-amd64.yaml   # note job ID
   testflinger-cli submit ubuntu-26.10-amd64.yaml   # queues behind the first
   testflinger-cli poll <job-id>
   ```

3. **Retrieve artifacts:**
   ```sh
   testflinger-cli artifacts <job-id-26.04>
   testflinger-cli artifacts <job-id-26.10>
   ```

4. **Analyze:**
   ```sh
   ./scripts/analyze-results.sh <artifacts-26.04-dir> <artifacts-26.10-dir>
   ```

## Campaign runs

Smoke validation (2026-10-08, all on chakron):

| Round | 26.04 | 26.10 |
|---|---|---|
| 1 | `90042d05` — toolchain path OK; `sweet get` OOM on ephemeral disk | `417e0fc1` — proved `stonking` absent from lab MAAS |
| 2 | `fcb16bfa` — MAAS provisioning flake (same config later proven good) | `5a92fcda` — found + fixed empty-`Suites:` deb822 bug |
| 3 | `5652ba5b` — ✅ **PASS** (all phases) | `ccbd6f50` — upgrade OK; reboot netbooted into MAAS ephemeral (PXE-first boot order), hit global timeout |
| 4 | — | `eae11acc` — ✅ **PASS** with `efibootmgr -n` BootNext fix |

Full campaign:

- **26.04 LTS**: `90da431a-a7f5-4be5-b66c-14206ff4c944` — ✅ **complete**
  (2026-10-09, ~7.5 h, zero recorded failures; artifacts in
  `runs/artifacts-26.04/`)
- **26.10 devel**: `a64a4336-...` — failed in provisioning (recurring MAAS
  post-install boot-signal flake on chakron, 2/6 occurrences); retried as
  `8bdd3f76-40ad-49e6-8708-d21656b35277` on 2026-10-10.

Note: Sweet's default benchmark group at the pinned commit is
`bleve-index cockroachdb etcd esbuild go-build gopher-lua markdown tile38`.
The gVisor benchmark is deliberately excluded from the default group at
this commit because it is **broken at Go tip** (go.dev/issue/72042 — unsafe
dependence on runtime field offsets). It remains selectable via
`-run gvisor`; any failure under go1.27.0 must be interpreted against that
known upstream issue, not as a toolchain regression.

Extras (blog-coverage supplement, queued after the campaign leg):

- **26.04**: `f84918f3-c31c-46bf-a4ba-6ea5b7214efc`
- **26.10**: `ea195d7f-79a5-4d92-ba21-220343b17d3b`
- Contents (`scripts/dut-extras.sh`): stdlib benchmarks for the Go 1.27
  release-note claims (`encoding/json` — v1-backed in 1.26 vs v2-backed in
  1.27 — plus `compress/flate`, `compress/gzip`, and `encoding/json/v2` +
  `jsontext` where the package exists); binary-size comparison of the
  pinned sweet binary built by both toolchains (validates the ~+60KB
  claim); gVisor via `-run gvisor` (with the issue-72042 caveat); markdown
  rerun as a second observation of the peak-VM +5.29% regression.

## Interpretation

- Compare go1.27.0 vs go1.26.7 **within** each Ubuntu release (same DUT,
  same provisioning).
- Then compare the **relative deltas** across releases. Do not compare raw
  26.04-vs-26.10 timings: kernel/userspace differences confound that.
- Trust benchstat's significance output, not point estimates; rerun large or
  inconsistent regressions before concluding.
- Sweet's gVisor benchmark requires `kernel.yama/ptrace_scope` of 0 or 1
  (set to 0 by setup); if gVisor fails it is recorded in
  `bench-out/logs/FAILURES` rather than silently skipped.
