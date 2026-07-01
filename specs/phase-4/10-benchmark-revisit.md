# Unit 10 — Benchmark revisit (honest; G8)

> **1–2 owners · Wave B · depends on the frozen tier axes AND the landed tier work.** Read
> [`00-overview.md`](00-overview.md) (G1–G8), [`01-interface-freeze.md`](01-interface-freeze.md)
> (the `mem_tier`/`state_strategy` axes you bind to), then Phase-3
> [`11-capstone.md`](../phase-3/11-capstone.md) §F (the honest-benchmark contract you extend) and
> the committed [`docs/phase-3-benchmark.md`](../../docs/phase-3-benchmark.md) (the baseline you
> beat — or don't). Phase 3's benchmark named the villain in one number: on the tier-O `paged`
> immutable-binary memory model, 2core-Safe is **~76× slower than hand-written Erlang** on the one
> faithful head-to-head (CRC-32, bit-identical), and orders of magnitude below the native NIF
> ceiling on SHA-256/DEFLATE. Phase 4 builds the lever (tier-O `atomics`, unit 04). **This unit
> re-measures with that lever engaged and reports — measured, no hero number — whether it closes
> the gap and by how much (G8).**

---

## Context

Phase 3's benchmark did its job: it refused to assert "faster than hand-written Erlang" and instead
*measured* the answer as **not-yet**, pinning the cause on the `paged` memory model (every store
rebuilds a 4 KiB chunk) and the pure-Gleam `rt_num`. That honest finding is the whole motivation for
Phase 4's memory trust-tier ladder (G2). Unit 10 closes the loop: it re-drives the **same** committed
smoke kernels through the new `mem_tier`/`state_strategy` axes and publishes the new numbers against
the same three references — the `paged` baseline, hand-written Erlang, and the native NIF ceiling.

This unit ships **no new kernels and no new src** — it re-uses the committed `twocore_smoke.wasm`
(72,933 bytes, 80 functions, 0 imports; already differential-checked bit-exact vs `wasmtime` by
`smoke/run.sh`) and varies only the linked `Binding`. It is a **measurement + reporting** unit: its
correctness bar is that every tier build is proven bit-exact (unit 09's oracle differential) *before*
it is timed — a fast number that is wrong is not a number.

**Dependencies (Wave B — this unit is not startable until they land):** unit 04 (`rt_mem_atomics`,
the tier-O O(1) backend behind the frozen `rt_mem` interface §B.2), unit 07 (`portable`/`ceiling`
profiles + the tier→module mapping + the Safe-forbids-nif linker gate), unit 08 (the pipeline/CLI
`mem_tier`/`state_strategy` selection + the threaded run-ABI in `exec`). It **consumes** the frozen
keystone axes and **produces** nothing others build on — the capstone (11) cites its findings.

---

## Deliverables & freeze milestones

- **Consumes** (every Phase-4 freeze + the landed tier work): `«MEM-TIER-FROZEN»`
  (`Binding.mem_tier: MemTier { Paged Atomics Nif }`, the `Atomics → "twocore@runtime@rt_mem_atomics"`
  module map §B.1), `«STATE-STRATEGY-FROZEN»` (`Binding.state_strategy: StateStrategy { Cell Threaded }`);
  `rt_mem_atomics` (04); `profiles.portable()`/`profiles.ceiling()` + `validate_binding` (07); the
  profile/tier-selecting compile-to-`.beam` + threaded `exec` (08).
- **Produces** (terminal): the tier-matrix extension of `smoke/bench.sh` and the committed
  `docs/phase-4-benchmark.md` — **measured** numbers, methodology, limitations, and the honest reading,
  confirmed correct against `wasmtime` before timing. **No publish-day-1 stub, no freeze milestone** —
  this unit consumes every freeze and emits nothing downstream depends on.

**Out of scope for this unit:** the atomics backend itself (04), the profiles/linker (07), the CLI
flags/run-ABI (08), the tier differential (09 — this unit *reuses* its correctness proof, it does not
own it), the tier-N `nif` measurement (unit 05 ships the interface only; the C impl is
documented-deferred, so there is **no `nif` column** — the native `crypto`/`zlib` figures remain the
raw ceiling).

---

## Files owned

- `smoke/bench.sh` *(extend, single-owner)* — add the `mem_tier` × `state_strategy` × policy build
  matrix and the derived ratios to the existing Phase-3 harness.
- `docs/phase-4-benchmark.md` — the committed Phase-4 perf report (methodology + real numbers +
  stated limitations + the honest reading).
- *(fallback, only if unit 08's CLI flag slips)* `smoke/bench_harness.gleam` — a tiny Gleam driver
  that constructs each tier `Binding` directly and compiles the wasm, mirroring the Phase-3 fallback
  note (§D).

---

## A. The measurement axes — one program, three knobs

The revisit holds the **program fixed** (the committed `twocore_smoke.wasm`) and varies the `Binding`
along the two new Phase-4 axes plus the Phase-3 policy axis, so each measured delta is attributable to
exactly one change (the same discipline the capstone differentials use — vary one field):

- **`mem_tier`: `Paged` (tier-P) → `Atomics` (tier-O)** — the headline of the revisit (G2). `paged`
  rebuilds a chunk per store; `atomics` mutates in O(1), process-local, no rebuild.
- **`state_strategy`: `Cell` → `Threaded`** — the tier-P runs-anywhere build (G1). Measured to show its
  threading overhead is small (G4: `InstanceState` is a fixed-size box — the loop-carried record does
  not grow the frame), not because it is a speed lever.
- **policy: `Safe` → `Unsafe`** — the Phase-3 optimizer delta, now *measurable on this module* because
  the Aggressive inliner's whole-module node ceiling (`inline_node_ceiling = 65536`, landed
  post-P3-capstone) makes the 80-function compile terminate (in Phase 3 it was `n/a`).

The five builds to measure (single-axis moves off the baseline, then the composed extreme):

| Build | `Binding` (schematic) | Isolates |
|---|---|---|
| **baseline** | `safe()` — `Cell` + `Paged` | the Phase-3 number (~76× CRC-32) — the thing we are beating |
| **atomics-safe** | `Binding(..safe(), mem_tier: Atomics, safe_max_pages: cap)` — `Cell` + `Atomics` | **THE memory-tier delta** (everything else fixed — the number the revisit exists to produce) |
| **portable** | `profiles.portable()` — `Threaded` + `Paged` + Safe | threading overhead + the runs-anywhere posture (G4) |
| **unsafe-paged** | `profiles.unsafe()` — `Cell` + `Paged` + Aggressive | the optimizer delta on `paged` (now compilable) |
| **ceiling** | `Binding(..profiles.ceiling(), safe_max_pages: cap)` — Unsafe + `Atomics` + `Cell` + Aggressive | the fastest build (all levers at once) |

`atomics-safe` vs `baseline` is the **clean science**: `mem_tier` is the *only* field that differs, so
the ratio between them is the pure `paged → atomics` effect, uncontaminated by the optimizer or the
policy. (A Safe+Atomics build is admissible — Safe permits tier P **or O**, never N, G6/§B.4 — so this
is a legal, fail-closed posture, not an Unsafe-only measurement.) `ceiling` then shows what the
composed levers buy on top.

---

## B. Contenders & baselines (unchanged references, new 2core column set)

1. **the five 2core builds above** — each compiled to a persisted `.beam` under its `Binding`, timed
   with `gleam run -- exec -n N <beam> <fn> <arg>` (the ABI already exists, `src/twocore.gleam`; it
   loads + instantiates **once** then invokes `N` times and times only the loop — compile/load/
   instantiate excluded).
2. **hand-written pure-Erlang CRC-32** — the honest hand-written baseline (table-driven; recomputes
   the *same* LCG input, so its result is **bit-identical** to the wasm export). The one true
   head-to-head; carried over verbatim from Phase 3's escript.
3. **native NIF ceiling** — `crypto:hash(sha256, _)` and `zlib` for SHA-256/DEFLATE. **NIF-backed C,
   NOT hand-written Erlang** — a raw *ceiling*, clearly labelled; 2core is expected to sit below it,
   and the `nif` memory tier that would attack this gap is Phase-4-deferred (unit 05 interface only).
4. **`wasmtime`** — **correctness only** (bit-exact, already cross-checked by `smoke/run.sh` and now
   by the per-tier gate §C). Per-call *timing* stays **omitted**: `wasmtime run --invoke` measures a
   whole process (startup + JIT + one invoke), not comparable to `exec`'s pure-invocation timing — a
   number there would mislead (Phase-3 §4, unchanged).

---

## C. Methodology (the honest frame — written into the report, G8)

Reuse Phase-3's methodology **exactly**, add the tier axis and one new gate:

- **What is timed:** invocations only (`exec` excludes compile/load/instantiate); the Erlang baselines
  warm up once then `timer:tc` over `N` repeats. Each kernel recomputes its `n`-byte LCG input per
  call, so contenders 1/2/4 do **byte-identical total work** (the native SHA/zlib ceilings are a
  *different implementation over equivalent-size input* — a labelled caveat).
- **Correctness gate FIRST (new, load-bearing).** Before any tier build is timed, its result on each
  kernel is checked **bit-exact vs `wasmtime`** (reuse the `run.sh` differential per build). Unit 09's
  tier differential already proves every `(state_strategy, mem_tier)` combination is byte-identical to
  the `paged`/`rebuild` oracle across the spec `.wast`; the bench re-checks on the real kernels so **a
  fast contender is first a correct contender** — a mismatch aborts the bench, it is never reported as
  a number.
- **The `atomics` memory cap (the sharp edge, §B.2 / G2).** `atomics` is fixed-size at creation: `fresh`
  pre-allocates to the effective max `min(declared_max ?? safe_cap, safe_cap, hard_max_pages)`, and
  `grow` moves a logical watermark within that ceiling. The committed smoke wasm declares
  **`(memory 17)` with no maximum** — so the effective max collapses to `safe_cap` (default `65536`
  pages = **4 GiB**), which is infeasible to pre-allocate as an `atomics` array. The `atomics` builds
  therefore bake a **lowered cap** (`safe_capped(pages)` / a bench `--cap` flag) sized to the kernel's
  **peak `memory.grow` watermark** — 17 pages initial for CRC-32/SHA-256, plus `dlmalloc` scratch for
  DEFLATE; a cap of a few hundred to ~1024 pages (≈32–64 MB) covers all three and pre-allocates
  cheaply. **The report states the exact cap and confirms it exceeds each kernel's peak grow** (a cap
  below the working set would make `grow` return `-1` and change the result — the correctness gate
  catches it, but the report documents the chosen value and why).
- **Repeats & environment:** `REPEAT` for crc/sha, a capped repeat for deflate (~tens of ms/call);
  record machine, OTP/erts, Gleam, rustc target, wabt, wasmtime, and the testsuite pin — exactly the
  Phase-3 table, refreshed.

---

## D. The harness additions (`smoke/bench.sh`)

Extend the existing Phase-3 `bench.sh` (do not rewrite it — the wasm build/gate, the escript
baselines, and the `exec_ns`/`ratio` helpers are reused as-is):

- **Compile the smoke wasm under each build** via the profile/tier-selecting CLI. **FLAG for unit 08
  (CLI):** `to-beam-wasm` today takes only `[--unsafe]`; the bench needs a build-selecting compile —
  e.g. `to-beam-wasm --profile <safe|unsafe|portable|ceiling> [--mem-tier atomics] [--state-strategy
  threaded] [--cap PAGES] <in.wasm> <out.beam>`. Unit 08 owns `src/twocore.gleam`; this is a small
  additive flag on the existing verb. If it slips, `bench.sh` falls back to `smoke/bench_harness.gleam`,
  which constructs each `Binding` directly (`Binding(..profiles.safe(), mem_tier: instance.Atomics,
  safe_max_pages: cap)`, `profiles.portable()`, `profiles.ceiling()`) and calls
  `pipeline.ir_to_core(_, binding)` — the same fallback Phase-3's bench used for its profile compile.
- **Attempt the Unsafe/ceiling compiles** (no longer expected `n/a`: the `inline_node_ceiling` cap
  makes the 80-function inline terminate). Keep the portable `run_to` timeout **only** as a safety net;
  report `n/a` for a build **only** if it genuinely still fails to finish, with the reason.
- **`exec` each build `N` times**, parse `ns/call` (the existing `sed -n '2p' | awk '{print $(NF-1)}'`),
  and print the tier matrix + the two **derived ratios per kernel**: the `paged → atomics` speedup
  (`baseline / atomics-safe`) and the residual (`atomics-safe / hand-Erl-or-native`).
- **Run the escript baselines unchanged** (hand-written CRC-32 + native `crypto`/`zlib`), and echo the
  CRC-32 bit-identity line as today.

```sh
# smoke/bench.sh (schematic delta): compile the wasm under EACH tier build, correctness-gate it vs
# wasmtime, exec it N times, print a per-kernel matrix. `--cap` bounds the atomics pre-allocation.
for build in "safe" "safe --mem-tier atomics --cap $CAP" "portable" "unsafe" "ceiling --cap $CAP"; do
  gleam run -- to-beam-wasm --profile $build "$WASM" "$OUT/$name.beam"     # (unit-08 flag; else Gleam fallback)
  gate_vs_wasmtime "$OUT/$name.beam" || { echo "FAIL: $name not bit-exact vs wasmtime"; exit 1; }
  for spec in "crc32 4096" "sha256_word 4096" "deflate_roundtrip 2000"; do
    exec_ns "$REPEAT" "$OUT/$name.beam" ${spec% *} ${spec#* }             # ns/call, invocations only
  done
done
```

---

## E. The report (`docs/phase-4-benchmark.md`)

Structure mirrors `docs/phase-3-benchmark.md` (so the two are directly comparable), with the tier axis
added:

- **What is measured** — the three kernels + the five 2core builds + the two Erlang references; the
  `atomics` cap caveat stated up front.
- **Contenders & methodology** — §B/§C above, prose, with the environment table refreshed.
- **Results — one table per kernel**, columns = the five 2core builds + `hand-Erl/native`, plus the
  two derived ratios (`paged→atomics` speedup; residual `atomics→hand-Erl/native`). Carry the Phase-3
  `paged`/Safe numbers in the baseline column so the delta is legible:

  | kernel | Safe/paged (P3) | Safe/atomics | portable (thr/paged) | unsafe/paged | ceiling (uns/atomics) | hand-Erl / native |
  |---|---:|---:|---:|---:|---:|---:|
  | `crc32(4096)` | 4,006,910 ns¹ | *measured* | *measured* | *measured* | *measured* | 52,800 (hand-Erl) |
  | `sha256_word(4096)` | 19,781,600 ns¹ | *measured* | *measured* | *measured* | *measured* | 41,620 (native `crypto`) |
  | `deflate_roundtrip(2000)` | 62,098,600 ns¹ | *measured* | *measured* | *measured* | *measured* | 38,650 (native `zlib`) |

  ¹ Phase-3 measured (this machine); the Safe/atomics column is the number this unit produces.
- **The honest reading** (§F) and **Limitations** (below), then **What this motivates** (the residual
  levers).
- **No hero number, no marketing claim** — the report reports whatever the measurement says.

---

## F. The honest reading — does `atomics` close the gap? (measured, no hero number)

The report **answers three measured questions per kernel — it asserts none of them**:

1. **The `paged → atomics` speedup — does removing rebuild-on-write help, and by how much?** State the
   ratio. A principled *prediction to confirm or refute* (not a claim): the win should track
   **store intensity**, because `paged`'s dominant cost is the per-store chunk rebuild (~4 KiB copied
   per byte-store) and `atomics` removes it — so **store-heavy DEFLATE** (dlmalloc + memcpy/memset)
   should gain most, **SHA-256** (message schedule + working buffer) next, and **load-heavy CRC-32**
   least (paged *loads* are already near-O(1): a sparse `dict.get` + a sub-binary slice, no rebuild).
   The report says which prediction the numbers bore out.
2. **The residual `atomics → hand-Erl/native` — how far is still left?** State it, and name why a
   floor exists *below which `atomics` alone cannot go* — so no one reads a small residual as a
   failure or a large one as a surprise:
   - **`rt_num` stays tier-P `bif`** — pure Gleam over BEAM bignums, **not native** (tier-N numerics is
     explicitly out of Phase-4 scope, G8). `atomics` attacks the **memory** constant, never the
     **numeric** one; hand-written Erlang's `band`/`bxor`/`bsr` are inlined machine ops.
   - **Every memory access is a fixed inter-module seam call** — `call 'rt_mem_atomics':'<op>'(...)`
     (D3a: a build-controlled module atom, never inlined into the caller), versus hand-written Erlang's
     inlined binary pattern-match. The optimizer inlines *user* IR functions, not the runtime seam, so
     this per-access call cost is present in **every** build, `ceiling` included.
   - **`atomics` stores 64-bit words** — a byte-addressed WASM store of a sub-word or unaligned value
     needs a read-modify-write mask (and a two-word straddle for an unaligned access); unit 04 owns the
     exact representation, and its net cost is part of what the `atomics` column measures.
3. **The composed `ceiling`** — Unsafe + `atomics`, all levers at once: the fastest number 2core
   produces this phase, reported against the same references.

**State plainly whether "faster than hand-written Erlang" is now reached.** The honest expectation —
which the report confirms with numbers, not rhetoric — is that the pure CRC-32 head-to-head is
**still not** beaten by hand-written Erlang (the numeric + seam-call floor above), while `atomics` is
expected to **close a substantial fraction** of the `paged` gap, most of all for the store-heavy
kernels — but the phrase "substantial fraction" is a placeholder for **the measured ratio**, and the
report prints that ratio whatever it is. **No hero number.** As in Phase 3: the number to beat is
written down, and this time the number achieved beside it.

---

## Effect / soundness / security note

- **Correctness precedes speed (the load-bearing invariant).** No tier build is timed until it is
  proven bit-exact vs `wasmtime` on every kernel (§C) — a wrong fast number is never reported. This
  reuses, not replaces, unit 09's `rebuild`-oracle differential (§B.3): the oracle holds every tier to
  the spec (WebAssembly spec §4.4.7 memory instructions, §2.5.4 memory bounds); the bench is a
  real-kernel spot-check on top of it.
- **Safe-forbids-nif holds (G6/§B.4).** The bench constructs no `Safe + Nif` binding — it is
  unconstructible through the profile API and `validate_binding` rejects a hand-built one; and the
  `nif` tier is deferred regardless (no `nif` column). The `atomics-safe` build is a legal Safe tier-O
  posture (Safe permits P **or O**), so measuring it introduces no unsafe path.
- **`atomics` is process-local, never shared (threads non-goal, §12).** Every tier build runs one
  instance in one owned process; no memory tier is cross-process. The only cost `atomics` adds over raw
  mutation is the atomic barrier — the bench measures it, it does not enable sharing.
- **Fail-closed default survives (D4).** The default profile remains Safe / `Cell` / `Paged`; `atomics`,
  `threaded`, and `ceiling` are each an explicit, named opt-in (a CLI `--profile`/`--mem-tier` flag or
  the named profile), never reached by omission.

---

## Verification (Definition of Done)

- **`smoke/bench.sh` runs end-to-end** on a machine with the tier toolchain: it builds/gates the smoke
  wasm, compiles each of the five tier builds (**correctness-gated bit-exact vs `wasmtime` before
  timing**), `exec`s each `N` times, and prints the per-kernel matrix + the `paged→atomics` and
  residual ratios. A correctness mismatch aborts non-zero.
- **`docs/phase-4-benchmark.md` is committed** with **real measured numbers**, the full methodology,
  the `atomics`-cap caveat, the stated limitations, and the honest reading (§F) — **no hero number, no
  marketing claim**. The `paged→atomics` speedup and the residual to hand-written-Erlang/native are
  stated **per kernel**.
- **The Unsafe/`ceiling` numbers are included** if the compile finishes (expected, given the inliner
  ceiling); if any build genuinely does not finish, it is reported honestly `n/a` with the reason —
  never silently dropped.
- **Conformance/build untouched.** This unit adds no `src` (it is `smoke/` + `docs/` + an optional
  test-side harness), so `gleam format --check src test` stays clean, `gleam build` stays zero-warning,
  `gleam test` and conformance (`fail=0` under every shipped combination) are unaffected. **Done = the
  report is committed with measured, correctness-gated numbers** — never "the script ran."

---

## What this unit leaves

The Phase-4 performance question is **answered honestly**: the measured `paged → atomics` delta on the
three real kernels, and how far the tier-O build still sits from hand-written Erlang and the native NIF
ceiling. Whatever the numbers, the report states them plainly and attributes the residual — the tier-P
`bif` numeric constant and the inter-module seam-call floor that `atomics` does not touch. **Deferred
(stated, not dropped):** the tier-N `nif` memory measurement (unit 05 ships the interface + Safe-forbidden
status; the C impl — and thus the true raw ceiling for a 2core build — is documented-deferred until a
native toolchain lands); **tier-N numerics** (`rt_num` `nif`, out of Phase-4 scope, G8) — the biggest
remaining lever the residual analysis points at; and a smarter inliner cost model (the P3 limitation the
node ceiling papers over, not solves). The capstone (11) cites these findings as Phase 4's one measured
claim about the outside world.
