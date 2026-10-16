# Go 1.27 performance on Ubuntu 26.04 LTS and 26.10: real-world workloads, JSON surprises, and one etcd anomaly

We benchmarked **Go 1.27.0 against Go 1.26.7** on Ubuntu **26.04 LTS** and **26.10** (amd64), using the upstream [`golang.org/x/benchmarks`](https://go.googlesource.com/benchmarks) suite — including **Sweet**'s real-world workloads (CockroachDB, etcd, esbuild, gopher-lua, bleve, tile38, markdown, go-build) — plus stdlib microbenchmarks targeting the headline Go 1.27 changes in `encoding/json` and `compress/flate`.

**TL;DR:** Go 1.27 is a solid upgrade on Ubuntu — allocation-heavy workloads improve 3–11%, builds are up to 7% faster, and JSON unmarshal is dramatically faster (−36…−87%). But watch out for two things: a **JSON marshal regression** on struct-heavy workloads (known upstream, fix targeted at 1.28) and an **etcd Put latency regression that appears only on 26.10** (kernel 7.3).

## Methodology

- **Fixed hardware** for every run: HPE ProLiant DL385 Gen10 Plus, AMD EPYC 7302 (16C/32T), 62 GiB RAM, performance governor. Both OS legs ran on the *same physical machine* (DMI-verified) via [Testflinger](https://canonical-testflinger.readthedocs-hosted.com/).
- **Pinned everything**: SHA-256-verified Go tarballs, x/benchmarks at commit `7069376`, `GOTOOLCHAIN=local`, 10 observations per benchmark per toolchain, interleaved baseline/experiment ordering, benchstat for statistics (we only report p<0.05 changes here).
- The 26.10 leg ran against a **pre-release devel snapshot** (kernel 7.3.0-9) via dist-upgrade; 26.04 was a clean MAAS install (kernel 7.0.0-38).

## Headline results (Sweet, replicated on both OSes)

| Workload | go1.27.0 vs go1.26.7 |
|---|---|
| bleve-index | **−11%** time |
| gopher-lua (knucleotide) | **−7%** |
| markdown | **−3.3%** (replicated 4×) |
| go-build (link steps) | **−3…−7%** |
| go-build (compile) | **−1…−5%**, peak RSS −1% |
| CockroachDB | peak memory −1…−2%, latencies neutral |
| GC tail latency (p99.999+) | no change |

This pattern matches Go 1.27's **size-specialized memory allocation** — the release notes promise ~1% overall with up to 30% on small allocations, and the biggest wins land exactly on the most allocation-heavy workloads.

## The JSON story: unmarshal flies, marshal stumbles

Go 1.27's `encoding/json` is now backed by the json/v2 engine. Testing the same v1 API against both toolchains:

| Path | Result (replicated on 26.04 and 26.10) |
|---|---|
| **Unmarshal** | **−36…−87%** (e.g. `UnmarshalString` −86%, `CodeUnmarshal` −43%) — the release-note claim holds, emphatically |
| **Marshal (struct-heavy)** | **+29…+42% slower** (`CodeMarshal`, `CodeEncoder`, `MarshalBytes`) |
| Marshal (maps) | −42% *faster* |

The marshal regression contradicts the release notes' "broadly at parity" wording, but it is **already known upstream**: [golang/go#81315](https://github.com/golang/go/issues/81315) tracks 1.5–2× marshal slowdowns on struct slices, is milestoned for **Go 1.28**, and has fix CLs in flight. Our numbers independently corroborate it on Ubuntu. Curiously, 1.27 marshal uses **25% less memory** while running ~34% slower. If your services are marshal-heavy, benchmark before upgrading — or set `GOEXPERIMENT=nojsonv2` as a temporary opt-out.

## compress/flate and binary size

- **flate decode is 9–20% faster** at the Speed level (with a memory cost: +23% RSS in the benchmark) — the "compression speed improved" claim holds.
- Binaries grow: a representative build was **+978 KB (+4.2%)**, well above the ~60 KB the release notes attribute to the new malloc — plausibly because json/v2 now links into every JSON-using binary.

## One anomaly: etcd on 26.10

On 26.04, etcd is neutral. On **26.10**, EtcdPut latency regresses consistently: **+3.7% (p50), +3.9% (p90), +7.6% (p99)**, throughput −3.4% — all statistically significant, replicated across 10 runs. Etcd is fsync- and timer-heavy; with 26.10's kernel 7.3 and Go 1.27's removal of async timer channels, an OS×runtime interaction is plausible. We're flagging this for follow-up investigation before drawing conclusions — if you run etcd-heavy workloads on 26.10, we'd love to hear your experience.

Everything else (GC tail latency, esbuild, tile38, CockroachDB latencies) is neutral on both releases.

## Caveats

amd64 only (Sweet is linux/amd64-only upstream); single machine (n=1 hardware); 26.10 tested as a pre-release snapshot; gVisor's benchmark is currently broken upstream ([go.dev/issue/72042](https://go.dev/issue/72042)) and out of scope.

## Reproducibility

All Testflinger job definitions, pinned versions, raw results, and analysis scripts are available at **[github.com/canonical/go-toolchain-benchmarks](https://github.com/canonical/go-toolchain-benchmarks)** — campaign jobs `90da431a` (26.04) and `8bdd3f76` (26.10), extras `233386ea` / `ea195d7f` on testflinger.canonical.com. Full consolidated tables are in [`RESULTS.md`](https://github.com/canonical/go-toolchain-benchmarks/blob/main/RESULTS.md). Feedback and questions welcome below!
