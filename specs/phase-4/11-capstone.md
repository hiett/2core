# Unit 11 — Capstone: the Phase-4 proof-of-goal (runs-anywhere + the tier matrix)

> **1–3 owners · Wave C (last) · depends on the freezes AND the landed work of 01–10.** Read
> [`00-overview.md`](00-overview.md) (G1–G8), [`01-interface-freeze.md`](01-interface-freeze.md)
> (the two frozen axes you bind to — `state_strategy` and `mem_tier`/`table_tier`), then Phase-3
> [`11`](../phase-3/11-capstone.md) (the binding-parameterized `driver.pipeline_with` + the
> two-profile conformance run you extend). Phases 1–3 are complete and green: **674 tests, 0
> warnings, conformance 15747 / 411 / 0 under both profiles**, the honest Phase-3 benchmark
> measuring tier-O `paged` memory as **~76× slower than hand-written Erlang** — the gap Phase 4
> set out to close, and the runs-anywhere build Phase 3 left unbuilt.

---

## Context

Phase 4 makes two claims only a capstone can prove. First — the **headline** — *runs-anywhere*:
the tier-P `portable` build (`threaded` state + `paged` memory + `bif` numerics, Safe) runs the
whole corpus on a **bare BEAM** with **no OTP-native state and no NIF** — provably (grep-verified)
and actually (executed). Second — *the tier matrix is conformance-neutral*: **every shipped
`state_strategy × mem_tier` combination** produces byte-identical, spec-correct results across the
whole pinned spec suite, not a subset (G7). Both are whole-corpus differential claims — they hold
the *program* fixed and vary the *`Binding`* — so the terminal unit owns the matrix wiring, exactly
as Phase-3's capstone owned the two-profile run and Phase-2's owned `load → instantiate → invoke`.

Phase 4 adds **no** IR nodes and **no** spec-suite files (G7), so this unit writes **no new
frontend fixtures**; it re-drives the *existing* Phase-1+2+3 acceptance corpus and pinned spec
suite through the two new axes via the already-generalized `driver.pipeline_with(binding)`
(Phase-3, verified) and asserts byte-for-byte sameness plus the runs-anywhere grep property. It
also **confirms** the tier differential (unit 09) and the honest re-measured benchmark (unit 10)
are green and committed, refreshes the conformance image to Phase-4 scope, and writes the honest
statement of what Phase 4 proved — and what it did not. This **closes Phase 4**.

The proof surface is five proofs + one image refresh:

| # | Proof | Decision |
|---|---|---|
| 1 | **runs-anywhere** — the tier-P `portable` build runs corpus + suite on a bare BEAM; **grep-verified zero** `atomics`/`ets`/`persistent_term`/NIF **and zero pdict *instance* state**, and **executed** green | G1/G3/G6 |
| 2 | **full-matrix conformance** — the whole pinned spec suite is `fail == 0` under **every** shipped `(state_strategy, mem_tier[, table_tier])`, byte-identical to the `cell`/`paged` oracle | G2/G7 |
| 3 | **tier differential confirmed** — unit 09's differential (every combo identical to the `rebuild` oracle) + constant-space-under-`threaded` (G4) are green and committed | G2/G4 |
| 4 | **fail-closed composition** — `Safe + Nif` is unconstructible / rejected by `validate_binding`; `portable`/`ceiling` compose the axes (G6) | G3/G6 |
| 5 | **honest benchmark confirmed** — unit 10's re-measured `atomics` numbers vs `paged`/hand-written/native are committed with methodology (G8) | G8 |
| — | **image refresh** — `docs/wasm-conformance.svg` regenerated, footnote → "Phase 4: every shipped tier green" | G7 |

---

## Deliverables & freeze milestones

**Consumes** (every Phase-4 freeze + landed unit): `«STATE-STRATEGY-FROZEN»` (`StateStrategy`,
`Binding.state_strategy`, the tier-P `rt_state`/`rt_mem`/`rt_table` threaded signatures) and
`«MEM-TIER-FROZEN»` (`MemTier`/`TableTier`, `Binding.mem_tier`/`table_tier`, the uniform backend
interface, the Safe-forbids-nif rule) from the keystone (01); the threaded seam (02) + tier-P
`rt_state` (03); `rt_mem_atomics` (04) and `rt_mem_nif` interface (05); the `rt_table` tiers (06);
the composed `portable`/`ceiling` profiles + `validate_binding` (07); the pipeline/CLI selection +
threaded run-ABI (08); the tier differential + constant-space proof (09); the honest benchmark (10).

**Produces** (terminal — nothing downstream depends on it): the full-matrix conformance run + the
runs-anywhere proof under `test/twocore/conformance/**`, the refreshed conformance image confirmed
green across every shipped combination, and the honest close-of-phase statement. No publish-day-1
stub — this unit consumes every freeze and emits nothing others build on.

---

## Files owned

- `test/twocore/conformance/conformance_test.gleam` *(extend, single-owner)* — run the pinned
  suite under **every shipped `(state_strategy, mem_tier[, table_tier])`** binding via
  `driver.pipeline_with`, each `fail == 0 && pass > 0` (proof 2). Supersedes the Phase-3
  two-profile run (which stays as two of the matrix points).
- `test/twocore/conformance/runs_anywhere_test.gleam` *(new)* — the tier-P `portable` proof
  (proof 1): grep the emitted `.core` + the linked runtime module set, then execute the corpus.
- `docs/wasm-conformance.svg` + `scripts/gen-conformance-svg.sh` footnote — refreshed to Phase-4
  scope (every shipped tier green; conformance-neutral, G7). Numbers unchanged, caption is not.
- *(confirm, do **not** re-own)* unit 09's `test/twocore/**` tier differential + constant-space
  test (proof 3); unit 10's `smoke/**` + `docs/phase-4-benchmark.md` (proof 5). The capstone
  asserts they are green and committed; it does not re-derive them.

> `test/twocore/conformance/runs_anywhere_test.gleam` is a fresh file — no ownership collision.
> The per-tier interface-conformance + oracle-differential property tests belong to units
> 04/05/06/09; this unit owns only the **whole-suite** matrix run and the runs-anywhere property.

---

## Depends on

- `«STATE-STRATEGY-FROZEN»` / `«MEM-TIER-FROZEN»` (01) — the `Binding` axes + the tier→module map.
- Units 02–08 (landed) — a `threaded` build that runs, the `atomics` memory backend, the table
  tiers, the composed `portable`/`ceiling` profiles + `validate_binding`, and the pipeline/CLI +
  run-ABI that thread the record and select a tier per profile.
- Units 09/10 (landed) — the tier differential + constant-space proof, and the honest benchmark.
- The Phase-3 `driver.pipeline_with(binding: Binding) -> Driver` (verified in-tree) — the single
  binding-parameterized code path; the capstone only enumerates bindings over it.

---

## A. The tier matrix — one binding-parameterized driver

Every proof here holds the *program* fixed and varies the *`Binding`*. Phase 3 already
generalized the conformance driver to `driver.pipeline_with(binding)` (verified: it composes
`decode → validate → lower → pipeline.ir_to_core(_, binding) → build → instantiate → invoke`, and
after unit 08 `ir_to_core` also selects the `state_strategy` codegen shape + the tier `mem_module`
from the binding). So the capstone **re-uses that path unchanged** and only enumerates the axis
bindings — it re-implements no compiler logic, exactly the E5/F-era discipline.

The **shipped matrix** the suite runs over (each a record-spread that varies only the axis fields,
so the tier/strategy is the sole variable):

```gleam
let base = profiles.safe()   // Cell / Paged / TablePaged — the Phase-2/3 oracle posture
// state_strategy × mem_tier (the primary matrix — 4 combinations):
let cell_paged    = base
let cell_atomics  = instance.Binding(..base, mem_tier: instance.Atomics)     // linker → rt_mem_atomics
let threaded_paged   = instance.Binding(..base, state_strategy: instance.Threaded)      // == portable-core
let threaded_atomics = instance.Binding(..base, state_strategy: instance.Threaded, mem_tier: instance.Atomics)
// table_tier sweep (over the call_indirect/element files — 2 extra table backends):
let cell_ets      = instance.Binding(..base, table_tier: instance.TableEts)
let cell_atomics_tbl = instance.Binding(..base, table_tier: instance.TableAtomics)
```

- **Nif is documented-deferred here (G8, honest).** `mem_tier: Nif` is **Unsafe-only** and its C
  backend may be deferred where a native toolchain is required (05). Where the C NIF is **not**
  built, the two `Nif` combinations (`Cell/Threaded × Nif`) are **not** run over the full suite —
  the capstone records this as an explicit gap, not a silent skip, and asserts the *interface* +
  the Safe-forbidden rule instead (proof 4). If the C NIF **is** built and loads, the two Unsafe
  `Nif` bindings join the matrix and must also reach `fail == 0`. Either way it is **stated**.
- **`portable` and `ceiling` are the named opt-ins (07).** `profiles.portable()` = the
  `threaded_paged`-core binding under Safe with `bif` numerics; `profiles.ceiling()` = Unsafe +
  `atomics` (or `nif`) + `cell` + aggressive optimizer. The matrix run exercises their component
  axes directly so a profile regression shows up assertion-by-assertion.

Each run reduces to the Phase-3 normalized `Outcome` per `(export, args)` (raw bit pattern D5;
trap collapsed to the spec phrase via `rt_trap.spec_trap_message`; `Rejected` for a fail-closed
non-build), so two bindings are compared by a single `==` over spec-observable behaviour — never
over `.core` text or IR shape, which the strategy/tier is *allowed* to change (a threaded function
has a different arity; an `atomics` `Mem` is a different term).

---

## B. Proof 2 — full-matrix conformance (G2/G7)

**The bar (G7).** Phase 4 is **conformance-neutral**: no new IR nodes, no new spec files, so the
counts do not move from **15747 / 411 / 0**. The proof is that the *same* green holds under **every
shipped combination** — WebAssembly is deterministic (the only non-determinism is NaN payload bits,
which D5 pins as raw patterns), so a correct `atomics` store and a correct `paged` store must
produce **byte-identical** memory images, hence identical `Outcome`s (WebAssembly spec §4.4 — every
ill-defined operation traps; there is no undefined behaviour to diverge on).

`conformance_test.gleam` runs the pinned allowlist suite once per matrix binding (§A) and asserts
`fail == 0 && pass > 0` for **each**:

```gleam
// For each binding b in the shipped matrix:
run_suite(driver.pipeline_with(b), label(b))   // asserts total.fail == 0 && total.pass > 0
```

- A single tier or strategy regression on **any** allowlisted assertion (a mis-endianned
  `atomics` load, a threaded record dropped across a call, an `ets` table miss) goes red on that
  file — this is the whole-suite backstop behind unit 09's fine-grained oracle differential (§D).
- The Safe fuel budget (`default_fuel_budget`) is generous enough that no in-scope program trips
  `FuelExhausted`; `threaded` is ordinary BEAM code (G4), so the same budget suffices — the loop
  back-edge is still a tail `apply`, the threaded record is a fixed-size box that does not grow the
  frame, so metering accounting is unchanged.
- **Coverage honesty (G8).** The primary claim is the 4-combination `state_strategy × mem_tier`
  matrix over the **whole** suite; the `table_tier` sweep is meaningful only on the files that
  exercise `call_indirect`/active elements (`call_indirect`, plus the corpus `callind`), so it is
  run there and recorded as such — not padded to look like a full-suite pass it is not.

---

## C. Proof 1 — the runs-anywhere proof (G1/G3/G6 — THE HEADLINE)

The high-level pitch's *"no OTP, no NIF, runs-anywhere, provably unable to take over the VM"* build
is the tier-P `portable` posture: `threaded` state (instance state travels as a **value**, no
process-dictionary cell), `paged` memory (immutable binaries, no native code), `bif` numerics
(pure Gleam over BEAM bignums), Safe policy. Proof 1 establishes it **two ways** — statically
(grep) and dynamically (execute) — because "it ran" and "it used nothing native" are different
claims and the headline needs both.

**(a) Grep-verified — the static property.** Emit the `portable` build of a state-heavy corpus
module (memory + globals + a table, e.g. `mem`/`gvar`/`callind`), and grep both the emitted `.core`
and the **linked runtime module set** (`rt_state`, the paged `rt_mem`, `rt_table`, `rt_num`) for
the native/unsafe primitives — asserting **zero** occurrences:

```gleam
let core = emit_core.emit_module(m, profiles.portable()) |> core_printer.print
// No native memory tier, no shared-memory tier, no persistent term, no NIF — anywhere:
assert count(core, "atomics")         == 0
assert count(core, "ets")             == 0
assert count(core, "persistent_term") == 0
assert count(core, "load_nif")        == 0 && count(core, "erlang_nif") == 0
// No process-dictionary INSTANCE state: the threaded build calls rt_state:'fresh' and threads the
// record; it NEVER emits the cell seam ('seed'/'get'/'put' on rt_state) that the `cell` build does.
assert count(core, "rt_state") > 0            // fresh + threaded accessors are present …
assert count(core, "':'seed'") == 0           // … but the rt_state instance-cell seam is absent (G1)
// NB: we deliberately do NOT assert 0 pdict — the Safe tier-O overlays (rt_meter fuel counter +
// rt_host policy cell) are node-safe process-local pdict and legitimately remain (P or O, never N).
```

- **The one honest caveat (stated, not hidden).** The residual process-dictionary use in a *Safe*
  `portable` build is the **tier-O fuel counter** (`rt_meter`, **mandatory** under Safe — Safe ⇒
  `MeterFuel`, the F5 fail-closed CPU bound; `MeterOff`-under-Safe is **rejected**, so `portable`
  keeps its fuel counter) + the **host-policy cell** (`rt_host`), each seeded once by `instantiate/0`
  (F5/F4, unchanged by state threading). These are
  a **process-local, node-safe policy overlay** — not *instance* state, not native code, cannot
  crash the node — and Safe **permits tier P or O, never N** (G6). So the grep's zero-set is the
  **native/unsafe** primitives (`atomics`/`ets`/`persistent_term`/NIF) **everywhere**, plus the
  **pdict *instance-state* cell** (absent under `threaded`); the metering counter is the one
  documented, node-safe pdict cell that Safe's tier-O metering keeps. This is exactly the keystone
  A.3 framing (metering/host are pdict-seeded, orthogonal to state threading) — the "runs on a bare
  BEAM, provably unable to take over the VM" property is about **no native code and no crashable
  state**, which the `portable` build satisfies in full.

**(b) Executed — the dynamic property.** Compile the acceptance corpus under `profiles.portable()`
and run it through `load → instantiate → invoke` on the bare BEAM (no `atomics`/`ets`/NIF loaded at
all), asserting **byte-identical** results to the `cell`/`paged` oracle:

```gleam
let d = driver.pipeline_with(profiles.portable())
// every corpus program (add/intops/sum_to/fib/fac/mem/gvar/callind/memgrow/growcap/…) green:
assert corpus_test.check_program_with(d, "mem")     == []   // memory round-trip + OOB trap
assert corpus_test.check_program_with(d, "gvar")    == []   // mutable global round-trip
assert corpus_test.check_program_with(d, "callind") == []   // 3-fault indirect dispatch
```

- **Constant space under `threaded` is proven here too (G4).** `sum_to(100000)` and the
  `memloop` store-loop run under `portable` in **constant** process memory — the threaded
  instance-state record is a fixed-size 3-tuple box threaded as a leading `LoopParam`, so the tail
  `apply` back-edge does not grow the stack and each store rebinds the box, not the frame (unit 09
  owns the measured assertion; the capstone re-confirms it holds in the `portable` composition).
- **Bare-BEAM = the security posture (G6).** Because no native code is linked, a bounds bug's
  worst case in `portable` is a wrong/missing trap or a node-safe process crash — **never a host
  escape** (WebAssembly spec §7 *Embedding*: the embedder's memory-safety invariant holds by
  construction when the whole memory subsystem is immutable BEAM binaries).

---

## D. Proof 3 — the tier differential confirmed (unit 09; G2/G4)

Unit 09 owns the fine-grained proof that every shipped `(state_strategy, mem_tier)` combination is
**differentially identical** to the trivially-correct `rebuild` oracle (`rt_mem`'s `o_*` family,
E4): one shared operation trace (`fresh`; a sequence of in-/out-of-bounds `load`/`store`/`grow`/
`init_data`) is driven through each tier **and** the oracle, asserting after every op identical
returned value, identical trap, and identical byte image (`<tier>.to_flat(mem) == o_flat(oracle)`);
plus the constant-space-under-`threaded` loop measurements (G4). The capstone's job is to **confirm
that suite is green and committed** — it is the microscope behind proof 2's whole-suite backstop:

```gleam
// The capstone asserts unit 09's differential + constant-space suites pass as part of `gleam test`;
// it does not re-derive the oracle (that is E4/unit 09). A single unsound tier (an `atomics` grow
// past the pre-allocated max that silently re-allocated, a threaded record that aliased two
// instances) would go red in unit 09's op-by-op image compare AND in this capstone's proof 2.
```

The `atomics` `grow` sharp edge (fixed size at creation → `fresh` pre-allocates to the effective
max, `grow` moves a logical page watermark, `-1` past it) keeps `memory.size`/`memory.grow`
spec-observable and is held to the same oracle — the differential is where that is proven, and the
capstone confirms it lands. Unit 09 also proves `memory.grow`'s **per-delta fuel charge** is
`threaded`-vs-`cell` identical: `memory.grow` is the one runtime-side *dynamic* charge
(`rt_mem.grow`/`t_grow` charge `rt_meter.charge(delta × page_bytes)` on success), so a module grown
past a tight `safe_metered` budget must trap `FuelExhausted` at the same grow under `cell×paged`,
`threaded×paged`, and both `atomics` rows — the threaded `t_grow` replicating Cell's charge (else a
`portable` module could allocate to its page cap with zero CPU accounting). The capstone confirms
that parity lands as part of `gleam test`.

---

## E. Proof 4 — fail-closed composition (G3/G6)

**Safe permits tier P or O, never N (G6).** Tier-N `nif` runs custom C that *can* crash the node,
so it is Unsafe-only, enforced in two fail-closed layers (D4):

1. **Structural — `Safe + Nif` is unconstructible.** Gleam has no default field values, so every
   Safe profile constructor *names* `mem_tier: Paged` (or `Atomics`), **never** `Nif`; only the
   Unsafe `ceiling()` sets `Nif`. The capstone re-asserts (from the keystone freeze test, now over
   the shipped profiles) that no `profiles.safe*`/`portable` constructor yields `mem_tier == Nif`.
2. **Defensive — the linker rejects a hand-built `Safe + Nif`.** `validate_binding` (07) returns
   `Error(SafeForbidsNif)` iff `mode == Safe && mem_tier == Nif`. The capstone confirms the gate
   bites and that every *other* composition of `state_strategy × mem_tier × policy` is admitted:

```gleam
assert profiles.validate_binding(instance.Binding(..profiles.safe(), mem_tier: instance.Nif))
  == Error(profiles.SafeForbidsNif)
assert result.is_ok(profiles.validate_binding(profiles.portable()))   // tier-P Safe: admitted
assert result.is_ok(profiles.validate_binding(profiles.ceiling()))    // Unsafe + Nif: admitted
```

`table_tier` needs no clause — there is no `Nif` table tier, so it cannot violate the rule. The
`portable` (maximally-safe, tier-P) and `ceiling` (Unsafe, tier-N-capable) profiles are the two
explicit, tested opt-ins; `safe()`/`unsafe()` keep their Phase-3 meaning as points in the composed
space (G3).

---

## F. Proof 5 — the honest benchmark confirmed (unit 10; G8)

The one claim Phase 4 makes about the outside world — that tier-O `atomics` **closes most of the
Phase-3 performance gap** — is **measured** by unit 10, never asserted, and committed as
`docs/phase-4-benchmark.md` (methodology + real numbers + limitations) driven by `smoke/bench.sh`
over the existing smoke crates (CRC-32 / SHA-256 / DEFLATE, already differential-checked bit-exact
vs `wasmtime`). The capstone **confirms it is committed and green**, and states the honest reading:

- **What `atomics` measured (the shipped win).** The `atomics` memory build is re-timed against
  `paged` on the memory-heavy kernels (CRC-32's table loads, DEFLATE's `memory.grow`). `atomics`
  gives O(1) load/store with **no custom native code** (cannot crash the node), so it is expected
  to be **materially faster than `paged`** — the report carries the measured multiple vs the
  Phase-3 `paged` baseline and vs hand-written Erlang.
- **What it did not prove (stated, not hidden).** "Faster than hand-written Erlang" remains a
  **measured question**, not a thesis: `atomics` closes much of the ~76× `paged` gap, but whether it
  *beats* hand-written Erlang on every kernel is reported as the number it is (likely still below on
  some, honestly). Tier-N `nif` is the absolute **ceiling**; whether a production C NIF *shipped*
  (vs the interface + skeleton) is stated explicitly (G8) — no "shipped C NIF" claim unless one is
  actually built and timed. No hero number; one table per kernel, caveats inline.

---

## G. Conformance refresh + the honest close (G7/G8)

Refresh `docs/wasm-conformance.svg` (`RUN_VENDOR=1 scripts/gen-conformance-svg.sh`) and update the
generator footnote from "Phase 3: green under BOTH profiles" to **"Phase 4: green under every
shipped tier (`cell`/`threaded` × `paged`/`atomics`, plus the `ets`/`atomics` table tiers) —
conformance-neutral."** The counts are **unchanged** (15747 / 411 / 0) — that is the point: Phase 4
is a pure implementation-tier expansion (G7), so the *scope caption* moves, the numbers do not.

**The honest close of Phase 4 (committed in `state.md`):**

- **Proved:** *runs-anywhere* — the tier-P `portable` build runs the corpus + suite on a bare BEAM
  with **no native code and no crashable instance state** (grep-verified + executed), byte-identical
  to the tier-O oracle; every shipped `state_strategy × mem_tier` combination is spec-correct and
  conformance-neutral; constant-space loops + preemption survive state threading (G4); tier-O
  `atomics` gives a **measured** O(1) memory win over `paged`.
- **Did not prove / explicitly deferred:** whether a **production C NIF shipped** — tier-N is
  defined as an *interface* + Safe-forbidden status + reference/skeleton, with the C impl
  documented-deferred where a native toolchain is required (G8); whether 2core **beats hand-written
  Erlang** — the `atomics` build closes most of the gap but the "faster than hand-written" question
  is reported as the measured number, not asserted. **Threads / shared memory stay a hard non-goal**
  (`atomics` is used process-locally, never shared). The single-`.beam` runtime-dispatch **B1** stays
  deferred (`state_strategy`/`mem_tier` are compile-time, B3). SIMD / reference types / bulk memory /
  multi-memory / `memory64` / the WAT parser / non-function imports are **Phase 5**; the Porffor
  JS→WASM bridge is **Phase 6**.

---

## Effect / soundness / security note

- **No ambient authority survives both new axes (D3a).** The `threaded` seam still emits fixed
  `twocore@runtime@*` module atoms with literal function names; the tier is a build-controlled
  module swap; the threaded table closure is a build-controlled capture; the only runtime-data input
  reaching a control transfer is still the integer `call_indirect` index. Proof 1's grep is the
  structural cross-check; unit 02's security-invariant test is the enforcement.
- **Fail-closed default (D4).** Every run that does not *name* a tier-P/N posture is `cell`/`paged`
  (Safe) — the maximally node-safe default. `portable` (tier-P) and `ceiling` (tier-N) require
  naming; tier-N additionally requires Unsafe (proof 4). No unsafe-by-omission path exists.
- **Tier-N is the one native seam, gated (G6).** Bounds-checks hold in every tier (the §11 security
  invariant); tiers P/O are memory-safe by construction; tier-N runs custom C, can crash the node,
  and is Safe-forbidden — its worst case is a node-safe process crash, never a host escape. The
  `portable` build links **none** of it (proof 1a).
- **A tier cannot be unsound and pass.** An unsound tier (mis-endianned `atomics`, an aliased
  threaded record, a `grow` that silently re-allocated) changes an `Outcome` — "green" means *every
  observable was preserved across every tier*, not "it compiled." Proof 2 is the whole-suite net;
  unit 09's oracle differential (§D) is the op-by-op microscope behind it.
- **Floats-as-bits (D5) unchanged.** Globals are raw-bit-pattern `Int`s in the threaded record;
  memory is raw bytes over the IEEE bit pattern in every tier — never a BEAM-double round-trip — so
  NaN payloads and `-0.0` are byte-identical across `paged`/`atomics`/`threaded`.

---

## Verification — Definition of Done (D8)

- **Proof 1 green (runs-anywhere):** the `portable` emitted `.core` + the linked runtime module set
  grep **zero** `atomics`/`ets`/`persistent_term`/NIF and **zero** `rt_state` pdict-cell seam (the
  documented tier-O `rt_meter`/`rt_host` overlay is the only pdict use, stated); the acceptance
  corpus runs green under `profiles.portable()` through `load → instantiate → invoke`, byte-identical
  to the `cell`/`paged` oracle; `sum_to(100000)` + the store-loop are constant-space under
  `threaded` (WebAssembly spec §7 embedding; exec/instructions bounds/traps).
- **Proof 2 green (full matrix):** the pinned suite is `fail == 0 && pass > 0` under **every**
  shipped `(state_strategy, mem_tier[, table_tier])` binding; any `Nif` combination not run (C impl
  deferred) is recorded as an explicit gap, never a silent skip.
- **Proof 3 confirmed:** unit 09's tier differential + constant-space suites pass in `gleam test`.
- **Proof 4 green (fail-closed):** `validate_binding(Safe + Nif) == Error(SafeForbidsNif)`; no Safe
  constructor yields `mem_tier == Nif`; `portable`/`ceiling` validate `Ok`.
- **Proof 5 confirmed:** `smoke/bench.sh` runs; `docs/phase-4-benchmark.md` carries the re-measured
  `atomics`-vs-`paged`-vs-hand-written-vs-native numbers with methodology + limitations (G8) — no
  marketing claim, no single hero number.
- **Image refreshed:** `docs/wasm-conformance.svg` regenerated; footnote → Phase-4 scope; counts
  unchanged (15747 / 411 / 0, G7).
- **`gleam format --check src test` clean; `gleam build` ZERO warnings; `gleam test` stays green
  (≥ 674, now higher); conformance `fail == 0` across every shipped combination.** Done = **the
  suites pass**, never "it compiles."
- Update `state.md`: announce Phase 4 proven, with the honest close (§G) and the deferred set.

---

## What this unit leaves

Phase 4 is proven: the trust-tier ladder is real. The tier-P `portable` build runs anywhere — no
OTP-native state, no NIF, cannot crash the node — grep-verified and executed; every shipped
`state_strategy × mem_tier` combination is byte-identical spec-correct across the whole suite
(conformance-neutral, G7); constant-space loops + preemption survive state threading (G4); tier-O
`atomics` closes most of the Phase-3 memory gap, measured. **Deferred, stated not dropped:** the
production **C NIF** (tier-N interface + skeleton ship; the C impl is documented-deferred where a
native toolchain is required — G8); the single-`.beam` runtime-dispatch **B1** (`state_strategy`/
`mem_tier` stay compile-time, B3); **Phase 5** — reference types / bulk memory / multi-memory /
`memory64` / the WAT text parser / non-function imports + `spectest` (the complete-WASM-engine
phase); **Phase 6** — the Porffor JS→WASM bridge ("JS on the BEAM"); and later — Arc/Gleam
frontends, exception-handling / GC / stack-switching / the component model. The benchmark's own
numbers set the bar for whether tier-N is ever worth the native seam — a measured decision, the way
Phase 4 measured tier-O.
