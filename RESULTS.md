# Go 1.27.0 vs Go 1.26.7 on Ubuntu — Consolidated Results

All benchmarks: single fixed DUT (HPE ProLiant DL385 Gen10 Plus, AMD EPYC
7302 16C/32T, 62 GiB RAM, performance governor), amd64. go1.26.7 (baseline)
vs go1.27.0 (experiment), SHA-256-verified tarballs, `GOTOOLCHAIN=local`.
x/benchmarks @ `7069376`, benchstat from x/perf @ `ebcb479`. n=10 (Sweet,
stdlib), n=6 (GCLatency). Same physical DUT for both OS legs, DMI-verified
(serial JS04NP1155).

Testflinger jobs (testflinger.canonical.com, queue `chakron`):

| Leg | Job ID | Outcome |
|---|---|---|
| Campaign 26.04 | `90da431a-a7f5-4be5-b66c-14206ff4c944` | ✅ clean |
| Campaign 26.10 | `8bdd3f76-40ad-49e6-8708-d21656b35277` | ✅ clean (retry after MAAS flake) |
| Extras 26.04 | `233386ea-91b0-4221-bb7c-4b37ebb1616e` | ✅ (2 known non-fatal failures) |
| Extras 26.10 | `ea195d7f-79a5-4d92-ba21-220343b17d3b` | ✅ (2 known non-fatal failures) |

26.10 leg: provisioned 26.04 + in-place APT upgrade to stonking devel
(2026-10-09/10 snapshot, kernel 7.3.0-9-generic) because the lab MAAS had
no stonking images. 26.04 leg: MAAS resolute, kernel 7.0.0-38-generic.

## 1. Sweet (real-world workloads) — significant changes (p<0.05)

| Benchmark | 26.04 Δ | 26.10 Δ | Verdict |
|---|---|---|---|
| bleve-index sec/op | −10.95% | −11.43% | **Improvement, replicated** |
| gopher-lua knucleotide | −7.73% | −6.66% | **Improvement, replicated** |
| markdown sec/op | −3.28% | −3.58% (reruns: −3.00%, −3.07%) | **Improvement, replicated ×4** |
| go-build compile | −0.9…−4.8% | −0.9…−5.0% | **Improvement, replicated** |
| go-build link | −2.6…−5.5% | −2.6…−7.3% | **Improvement, replicated** |
| go-build peak RSS | −0.9…−1.3% | −0.7…−1.4% | Improvement |
| cockroachdb peak-VM | −1.5…−2.0% | −0.9…−1.4% | Memory improvement |
| tile38 query-load | −0.96% | n.s. | Marginal |
| etcd Put latency | n.s. | **+3.7% p50 / +3.9% p90 / +7.6% p99** | **26.10-only regression** |
| etcd Put throughput | n.s. | −3.4% | 26.10-only |
| esbuild, etcd STM | n.s. | n.s. | Neutral |

Consistent with Go 1.27's size-specialized malloc (release notes: ~1%
overall, up to 30% on small allocations; largest wins on allocation-heavy
workloads).

GCLatency (p99.999 / p99.9999): all deltas non-significant on both OSes —
no GC tail-latency change, matching the absence of any GC claim in the
1.27 release notes.

## 2. encoding/json (v1 API both sides; v2-backed in 1.27) — replicated on both OSes

| Path | Benchmark | 26.04 Δ | 26.10 Δ |
|---|---|---|---|
| Unmarshal | CodeUnmarshal | −43.6% | −43.3% |
| Unmarshal | CodeUnmarshalReuse | — | −45.5% |
| Unmarshal | CodeDecoder | −36.5% | −36.1% |
| Unmarshal | UnmarshalString | −86.0% | −87.3% |
| Unmarshal | UnmarshalFloat64 / Int64 | — | −83% / −86% |
| Unmarshal | UnmarshalMap | −42.6% | −42.5% |
| Marshal | CodeMarshal | **+34.2%** | **+33.0%** |
| Marshal | CodeEncoder | **+29.3%** | **+41.0%** |
| Marshal | MarshalBytes/32 | **+42.5%** | **+39.6%** |
| Marshal | MarshalMap | −42.3% | −43.3% (exception) |

- Release-note claim "unmarshal significantly faster": **validated, emphatically**.
- Claim "marshal broadly at parity": **does not hold** on reflect-heavy
  struct workloads. Corroborates known upstream issue golang/go#81315
  (marshal 1.5–2× slower on struct slices; milestone Go 1.28, fix CLs in
  flight, e.g. CL 828566).
- Notable: CodeMarshal **allocates 25.5% less** in 1.27 yet runs 34%
  slower (26.04) — time/allocation tradeoff inverted.

## 3. compress/flate (26.10; decode unless noted)

- Speed level: −9.0…−20.0%; Huffman: −1.5…−3.0%; Default: mixed
  (−9.4…+4.6%). Release-note "compression speed improved": **validated**,
  decode-side.
- Cost: benchmark RSS +22.8% geomean.

## 4. Binary size

sweet binary (identical on both OSes, deterministic): 23,482,369 →
24,460,836 bytes = **+978,467 B (+4.2%)**; text +431 KB. Larger than the
release notes' ~60 KB figure — plausibly json/v2 now linked into every
json-using binary.

## 5. Anomalies and dispositions

| Item | Disposition |
|---|---|
| markdown peak-VM +5.29% (26.04 only) | NOT replicated (26.10 ~0%, rerun +0.01%) — one-off, closed |
| EtcdPut +3.7…+7.6% latency, 26.10 only | **Open** — candidate kernel 7.3 × Go 1.27 runtime (timer-channel removal) interaction; recommend follow-up before 26.10 users rely on etcd-heavy workloads |
| cockroachdb tail-latency swings (+29%, +100%) | Noise (±84% variance); only the memory improvements are real |
| etcd "+0.00% (p=0.001)" | Zero-variance artifact; ignore |
| gVisor | Un-runnable: build fails under 1.26.7 at this benchmarks commit; upstream default-group disable = go.dev/issue/72042 |

## 6. Cross-release conclusion

The go1.27.0 delta profile is **stable across Ubuntu 26.04 and 26.10** for
every suite except etcd Put, which regresses only on 26.10 (kernel 7.3).
Compare relative deltas, not raw cross-OS timings.

## 7. Scope and caveats

- amd64 only (Sweet is linux/amd64-only upstream; gVisor permanently so).
- Single DUT (n=1 hardware); results are machine-specific.
- 26.10 leg ran against a pre-release devel snapshot (26.10 released
  2026-10-15, after our run) via dist-upgrade, not a clean MAAS install.
- go1.27.0 tested; go1.27.1 is out since 2026-09 (not tested).
- 4/~12 non-ephemeral provisions on chakron hit an intermittent MAAS
  post-install boot-signal flake; retries succeeded. Lab ticket candidate.
