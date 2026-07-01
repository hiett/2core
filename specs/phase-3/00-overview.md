# Phase 3 — Overview & Shared Contracts

> **Read this after [`phase-1/00-overview.md`](../phase-1/00-overview.md) (D1–D10) and
> [`phase-2/00-overview.md`](../phase-2/00-overview.md) (E1–E8).** Every decision on those
> pages **still holds** — one owner per file, runtime layers as Gleam modules reached through
> the binding chokepoint with **no ambient authority**, per-stage error types, floats-as-bit-
> patterns, named-label IR, the tier-O `cell` state strategy, spec-first tests, and the strict
> Definition of Done. This page adds the Phase-3 decisions **F1–F8** and the work breakdown.
> Phases 1 & 2 are complete and green: **509 tests, 0 warnings, conformance 1740 / 1359 / 0**.

---

## 0. Where Phase 3 sits (the platform, one paragraph)

Phases 1–2 proved the platform **correct and sandboxed**: a real `.wasm` module — integer &
float arithmetic, linear memory, tables + `call_indirect`, globals, instantiation — compiles
through the shared IR to Core Erlang and runs **spec-correctly on the BEAM in Safe mode**,
preemptibly, in constant space. That is the *faithfulness* half of the high-level thesis
(§00 "faithfulness beats raw speed"). Phase 3 builds the **other** half: **speed and the
second named mode.** It ships the shared **optimizer** (`ir_opt`, high-level §4 M2), the
**Unsafe** profile (§6), and turns metering from observe-only into a **real CPU resource
bound** — pursuing the high-level §6 aspiration of "the fastest possible code, near-native,
potentially faster than hand-written Erlang" (a claim Phase 3 sets out to *measure*, not assert)
*and* keeping a fail-closed sandbox available on the same node. No new frontend surface, no new IR
node types: Phase 3 is a **middle-end + runtime + linker** phase, and its correctness bar is that
**both profiles stay green** on the existing corpus and spec suite.

---

## 1. The Phase-3 goal (concrete and measurable)

> **Make the generated code fast, and make the two modes real.** The shared IR-level
> **optimizer** rewrites IR→IR (semantics-preserving, effect-aware), driven by an **optimization
> level** selected by the build profile — and it is where Phase-3 speed comes from. The
> **Unsafe** profile bundles the aggressive optimizer + passthrough stdlib + a **widened admitted
> BIF set** (the passthrough/own surface only, **not** arbitrary BIFs) + no metering + host
> whitelist/open; the **Safe** profile gains the baseline optimizer + **enforcing** CPU fuel. Both
> profiles compile the full Phase-2 acceptance corpus and spec suite to **identical, spec-correct
> results** (Unsafe must never change an observable answer), and **coexist on one node** — the
> instance is the unit of policy (§13), realized as **distinct B3-monomorphized builds** with
> **per-instance seeded runtime policy**. The "faster than hand-written Erlang" claim is a
> **measured** question, not a thesis.

### Acceptance (owned by the capstone, unit 11)

| Area | Must demonstrate |
|---|---|
| **optimizer soundness** | `optimize(m, level)` and `m` produce **byte-identical results and identical traps** for every program in the Phase-1+Phase-2 acceptance corpus, at **both** `Baseline` and `Aggressive` — a differential over the whole corpus, not a spot check |
| **baseline passes** | constant-folding matches `rt_num` **bit-exact** (folded `i32.add`/`f64.mul`/… equal the runtime result incl. NaN bits, wrap, `-0.0`); dead-`let`/dead-code/unreachable removed; copy/const propagation; algebraic identities — each pass **individually** semantics-preserving and each backed by a spec-referenced test |
| **effect safety (E6)** | a load is **never** CSE'd across a store; no effectful node is reordered across `MemGrow`/`GlobalSet`/`CallIndirect`/`CallHost`/`Charge`/`Trap`; no effect is dead-code-eliminated — proven by targeted IR fixtures the optimizer must *not* break |
| **aggressive (Unsafe-only)** | inlining, `Charge`-elision (metering off), and trust-assuming simplifications run **only** at `Aggressive`; each pass documents its trust assumption and still produces spec-correct results on every corpus input (Unsafe does not license breaking WASM semantics — WASM has no C-style UB) |
| **real CPU metering (Safe)** | a runaway loop **traps deterministically** at a finite fuel bound (`FuelExhausted`) in Safe mode, in **constant space**, preemptibly; the bound is **always armed** — `instantiate/0` seeds the fuel budget and the run-ABI instantiates before invoke, so **no metered artifact runs unbounded by default** (fail-closed); the trap propagates through the run-ABI; `fuel_consumed()` still observable |
| **zero-overhead Unsafe** | Unsafe emits **no `charge` calls at all** (not no-ops — *absent*): the emitted `.core` for a metered function body under Safe and under Unsafe differ exactly by the charge instrumentation (every non-`instantiate` function is byte-identical across postures; `instantiate/0` additionally carries the once-per-instance seed) |
| **passthrough ≡ own** | `rt_stdlib: passthrough` is **observably identical** to `own` on every shared stdlib function (differential) — this proves the passthrough **mechanism** and its non-vacuity self-test, **not a live route** (Phase 3 ships **zero active passthrough routes**; `gcd` stays in-house); `rt_bif: open` **widens the build-controlled admitted set** **only** under Unsafe — Safe's fail-closed allowlist is untouched |
| **instance = unit of policy** | a **Safe** build and an **Unsafe** build of the *same module* run on **one node**, concurrently, with correct results and no state or capability leakage between them — the same source module compiled to two **distinct B3-monomorphized builds** (`Safe.beam ≠ Unsafe.beam`, sharing the `twocore@runtime@rt_*` runtime modules), each instance carrying its own seeded runtime policy |
| **honest benchmark** | a committed benchmark reports Unsafe-optimized vs Safe vs hand-written Erlang (and, where available, `wasmtime`) on a few kernels — **real numbers**, with methodology, not a marketing claim; the hand-written-Erlang baseline is **CRC-32 only** (labelled as such; optionally one memory-heavy hand-written baseline alongside) |

### Honest scope (F8 — do not overstate)

- **This is the policy/optimization axis, not the trust-tier axis.** Phase 3 runs on Phase-2's
  **tier-O** runtime (`cell` state, `paged` memory). The **trust-tier ladder** — tier-P
  `threaded` state (the "runs-anywhere, no-OTP" build), tier-O/N `rt_mem` (`atomics`/`nif`),
  `rt_table` tiers — is **Phase 4**. Unsafe *permits* tier N; Phase 3 does not *ship* it. Say so.
- **Optimizer breadth is deliberately bounded.** `baseline` ships a vetted set of trust-neutral
  passes (const-fold, copy/const-prop, dead-let/DCE, algebraic identity, block/label
  simplification, constant-condition `if`); `aggressive` adds inlining + charge-elision + a small
  set of trust-assuming simplifications. **Loop-invariant code motion, full bounds-check
  elimination under a range solver, SIMD vectorization, register-allocation-level tricks are
  NOT in Phase 3** — they need dataflow machinery scoped as later work. The bar is *sound and
  measurably useful*, not *maximal*.
- **Unsafe does not mean incorrect.** WASM has no undefined behavior — every ill-defined
  operation traps. So Unsafe's optimizer may not "assume no div-by-zero" and drop the trap;
  its trust assumptions are confined to *toolchain well-formedness* (e.g. inlining is always
  sound; charge-elision is sound because metering is a policy overlay, not a semantic).
  Anything that could change a corpus result is out.
- **Phase-3 speed comes from the optimizer alone.** `passthrough` stdlib and the widened BIF set
  ship as a **mechanism with zero active routes** — `gcd` and every shared stdlib function stay
  in-house, so the `passthrough ≡ own` differential proves the mechanism (and guards against a
  vacuous self-test), **not a live fast path**. "Faster than hand-written Erlang" is therefore a
  **measured question**, benchmarked (CRC-32 baseline first), not a thesis Phase 3 asserts.
- **Deferred (state it, don't drop it):** the tier ladder + runs-anywhere build (Phase 4);
  reference types / bulk memory / multi-memory / memory64 / the WAT text parser / non-function
  imports + `spectest` (Phase 5 — WASM-surface completion); the Porffor JS→WASM bridge (Phase 6);
  Arc & Gleam frontends, exception-handling / GC / stack-switching / component-model (later).

---

## 2. The Phase-3 decisions (F1–F8)

These are frozen for Phase 3. If you believe one is wrong, raise it with the planner **before**
building on it — do not silently diverge (the D1 rule).

### F1 — The optimizer (`ir_opt`) is the keystone: IR→IR, level-driven, pass-structured

`ir_opt` is a new shared **middle-end** stage (high-level §4 M2), between `ir_lower` and
`emit_core`. Its public surface is one function —
`optimize(module: ir.Module, level: OptLevel) -> ir.Module` — where
`OptLevel = None | Baseline | Aggressive`. Internally it is a **pipeline of named passes**,
each `fn(ir.Module) -> ir.Module` (some phrased per-function or per-expression), each with a
**documented precondition and postcondition** and its own tests. It is **frontend-agnostic**:
it rewrites the language-neutral IR, so every future frontend (JS, Gleam) inherits it for free
— which is exactly why it lives at the IR level and not in the WASM path. `None` is the
identity (a Phase-1/2 build path with the optimizer bypassed, for differential baselines).

### F2 — Semantics preservation is the optimizer's Definition of Done, proven differentially

A pass is **not done** until `optimize(m)` and `m` produce **identical observable behavior** —
same returned values (compared **by bit pattern**, per D7, so NaN payloads/`-0.0`/wrap are
exact) and **same traps** (same `TrapReason`, same trap-or-not) — over the full acceptance
corpus **and** the spec suite. This is a **differential harness** (unit 11 owns the corpus
wiring; each optimizer unit owns per-pass property tests). `baseline` passes preserve semantics
**unconditionally**; `aggressive` passes preserve semantics **under a documented trust
assumption** stated in the pass's doc comment, and are proven not to alter any corpus result.
No change-detector tests (D8): assert *what the transformation must preserve*, not what the
current output happens to be.

### F3 — Effects are the optimizer's safety boundary (E6 made concrete and enforced)

Phase-2's E6 declared `MemLoad/MemStore/MemGrow/MemSize/GlobalGet/GlobalSet/CallIndirect`
side-effecting. Phase 3 turns that declaration into a **shared IR effect-classification module**
(`ir/effect.gleam`, unit 02) that the optimizer's soundness rests on. It classifies every
`Expr` as **pure** or **effectful**, where effectful additionally includes `CallHost`, `Charge`,
`Trap`, and any `CallDirect`/`CallIndirect` (may trap or touch state), and is **conservative**:
anything it cannot prove pure is effectful. The optimizer's contract:

- **No CSE / no reorder / no hoist / no sink across an effect barrier.** A load may not be
  reused across an intervening store; effectful nodes keep their relative order; a trap is never
  speculatively hoisted above a guard.
- **No dead-code elimination of an effect.** `MemStore`/`GlobalSet`/`Charge`/`CallHost` whose
  result is unused are **still emitted** (E1's ordered `let _ = effect in …` sequencing is
  load-bearing).
- **Baseline** may only rewrite provably-**pure** subtrees. **Aggressive** may relax a *specific,
  named* barrier only under a documented trust assumption that cannot change a corpus result
  (e.g. eliding `Charge` when metering is off — a policy overlay, not a WASM semantic).

Getting this module right is cheap now and catastrophic to retrofit after passes ship (a single
unsound CSE-across-store is a silent memory-corruption bug), so it is its own unit with adversarial
"the optimizer must NOT do this" fixtures.

### F4 — The Unsafe profile is the second named mode; the instance is the unit of policy

`Unsafe` (the `Mode` variant already present in `instance.gleam` for lock-now completeness)
becomes real. It bundles: `ir_opt: Aggressive`, `rt_stdlib: passthrough`, `rt_bif: open`,
`rt_meter: none`, `rt_host: whitelist | open`, and permits trust tiers O/N (Phase 3 uses O). The
**Binding** record gains the explicit policy fields the middle-end reads to realise this (F7),
and `profiles.unsafe()` constructs it. **Coexistence is realized by B3 monomorphization, not
runtime dispatch.** Safe and Unsafe are **different builds**: `ir_lower` compiles metering in or
out (`Charge` present under `MeterFuel`, absent under `MeterOff`) and the optimizer runs at
**build time** (`Baseline` vs `Aggressive`), so `Safe.beam ≠ Unsafe.beam` — different code, with
**distinct output module atoms**. Both builds share the **identical `twocore@runtime@rt_*` runtime
module names** and coexist on one node as distinct loaded modules; each instance is one process
carrying its **own pdict cell**. Per-instance **runtime** state (fuel budget, host policy) is
**seeded at instantiation** and read at run time. The Instance/Binding API presents this
uniformly — *"the instance is the unit of policy"* (high-level §10/§13) — but there is **no
single-`.beam` runtime dispatch** that swaps Safe/Unsafe; that model ("same generated code, a
swapped linked runtime", B1) is **Phase-4-deferred**. **Fail-closed still governs (D4/D9):** the
*default* profile is Safe; `profiles` exposes no way to obtain an Unsafe posture by omission —
Unsafe is an explicit, tested opt-in, exactly as `safe_capped` can only *lower* the page cap.

### F5 — Real CPU metering makes fuel a real bound (Safe), at zero Unsafe cost

Phase 1/2 shipped metering **observe-only**; Phase 2 fixed **memory** exhaustion (the max-pages
cap). Phase 3 makes **CPU fuel enforce** in Safe mode: `charge` decrements a per-instance fuel
**budget** and, on exhaustion, raises a **new `FuelExhausted` trap** (an internal resource-limit
trap distinct from every WASM `TrapReason`; it is *our* policy, not a WASM spec trap). The budget
is a real, **single channel**: `Binding` gains `fuel_budget: Int` (set by `safe_default()` to
`rt_meter.default_fuel_budget`), and `emit_core`'s synthesized `instantiate/0` bakes
`rt_meter:seed_fuel(binding.fuel_budget)` as its **first** effect under `MeterFuel`. Because the
shipped run-ABI always instantiates before invoke, the bound is **always armed** — this is
**fail-closed**: no metered artifact runs unbounded by default (an *unseeded* charge accumulating
observe-only is an explicit legacy/test posture, never the default of a metered build; it mirrors
the host boundary, where an unseeded policy defaults to deny-all).

Properties: a runaway loop traps at a **deterministic** fuel bound and the trap surfaces through
the run-ABI. **Fuel bounds CPU-time (reductions), not stack/heap space:** a tail-iterating spin
runs in **constant space** (the tail-`apply` back-edge is unchanged; the budget lives in the
instance cell, like Phase-2 state; charge is an ordinary reduction-consuming op), and non-tail
**recursion depth is bounded by the (tunable) fuel budget** — each frame costs ≥1 fuel — with a
**residual node-memory caveat** (fuel caps time, so it does not, on its own, *close the last
resource-bound gap*). **Unsafe pays exactly nothing:** with `rt_meter: none`, `ir_lower` inserts
**no `Charge` nodes**, so the emitted code has no charge calls at all; the seed is emitted only in
`instantiate/0` and only under `MeterFuel`, so **hot-path function bodies stay posture-agnostic**
(F2's differential proves a metered function body differs from Safe by exactly the instrumentation,
and every non-`instantiate` function is byte-identical across postures). The cost model is
documented and spec-neutral.

### F6 — `passthrough` stdlib & the widened BIF set are the Unsafe speed *mechanism* — differentially equivalent

`rt_stdlib: passthrough` is realized as a thin, **vetted shim inside `rt_stdlib`** that calls the
faster BEAM BIF; `emit_core` **always** emits `call '<stdlib_module>':'<fn>'(...)`,
**byte-identical under both profiles** (the emitted module atom is invariably `stdlib_module`, a
`twocore@runtime@rt_*` module — only the in-module *implementation* differs, `own` vs
passthrough). It must be **observably identical** to the vetted `own` implementation on every
shared function (a differential the unit owns) — which proves the **mechanism** and guards its
non-vacuity, **not a live route** (Phase 3 ships **zero active passthrough routes**; `gcd` stays
in-house). `rt_bif: open` **widens the admitted set to the targets the build-time resolver
constructs — the passthrough/own surface only, NOT arbitrary BIFs** — and is reachable **only**
under Unsafe; Safe's fail-closed `allowlist` gate (unit 09/Phase-1) is untouched and still rejects
a non-allowlisted call. **Node-safety rests on per-route human vetting**, and the emitted call
**form** stays a static `call '<mod>':'<fn>'(...)` — **never** a data-driven `apply(Mod, F, Args)`
with `Mod` from program data (D3a). So any "faster than hand-written Erlang" margin is a
**measured** result of the optimizer (§1), with this passthrough/BIF surface a shipped mechanism
awaiting its first vetted route — not a live fast path Phase 3 relies on.

### F7 — No new IR node types, no new frontend surface: the profile carries the policy

Phase 3 adds **no** `Expr`/`NumOp`/`ConvOp` variants and **no** `.ir` grammar changes (the
optimizer rewrites existing nodes; there is nothing new to print). The only structural change is
the **`Binding` policy extension**: explicit fields — `opt_level: OptLevel`, `meter: MeterMode`,
`bif_gate: BifGate`, `stdlib: StdlibMode`, `host_policy: HostPolicy`, and `fuel_budget: Int` — that
the middle-end (`ir_lower`, the pipeline) and backend (`emit_core`) read to realise Safe vs Unsafe.
This keeps Phase 3 conformance-neutral: the existing corpus/spec suite must stay green under
**both** derived profiles. (The one new `TrapReason`, `FuelExhausted`, is a *runtime*
resource-limit reason with a `spec_trap_message`, not a new IR operation — it is raised by
`rt_meter`, never emitted as an IR node.) **Settled at freeze:** `OptLevel` lives on `Binding` (so
the profile is the single source of truth), and `fuel_budget` mirrors `safe_max_pages` as the
single per-instance budget channel `emit_core`'s `instantiate/0` bakes into `rt_meter:seed_fuel`.
The `Aggressive ⟹ MeterOff` coupling (F4/keystone §B.5) means only `Baseline`/`OptNone` may pair
with `MeterFuel`.

### F8 — Honest scope

See §1. Optimizer breadth is bounded (no LICM / range-based bounds-check elimination / SIMD);
Unsafe never changes an observable result; the tier ladder + runs-anywhere build are Phase 4;
WASM-surface completion is Phase 5; the Porffor bridge is Phase 6. **Phase-3 speed comes from the
optimizer alone** — passthrough/open-BIF ship as a mechanism with zero active routes — so "faster
than hand-written Erlang" is a **measured question**, benchmarked (CRC-32 baseline first) with
methodology and limitations written down, not a thesis asserted.

---

## 3. Dependency DAG — freeze milestones

```
WAVE 0   01 KEYSTONE (one owner):
            «IROPT-IFACE-FROZEN»   (OptLevel + optimize/2 signature + Pass shape + effect.gleam sig)
            «UNSAFE-PROFILE-FROZEN» (Binding policy fields + profiles.unsafe() lands GREEN)
            «METER-ENFORCE-FROZEN»  (rt_meter enforcing-charge signature + FuelExhausted trap reason)
                 │                          │                              │
   ┌─────────────┼──────────────┬───────────┼──────────────┬───────────────┴──────────┐
   ▼ «IROPT»     ▼ «IROPT»       ▼ «METER»   ▼ «UNSAFE»      ▼ «UNSAFE»                  ▼ «UNSAFE»
 ┌──────────┐ ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
 │02 effect │ │03 ir_opt │  │05 rt_    │  │06 pass-  │  │07 rt_host│  │08 ir_    │  │10 linker │
 │analysis  │→│ baseline │  │ meter    │  │ through  │  │ whitelist│  │ lower    │  │ + profile│
 │(purity)  │ │ passes   │  │ enforce  │  │ stdlib + │  │ / open   │  │ Unsafe   │  │ + B3     │
 └──────────┘ └────┬─────┘  └──────────┘  │ open bif │  └──────────┘  │ policy   │  │ coexist  │
      │            ▼                       └──────────┘                └──────────┘  └──────────┘
      │       ┌──────────┐                                                  │
      └──────▶│04 ir_opt │                                     ┌──────────┐ │
              │ aggressive│                                    │09 emit + │◀┘ (emit reads the
              │ (Unsafe)  │                                    │ pipeline │    Unsafe Binding +
              └──────────┘                                     │ opt-stage│    wires ir_opt into
                                                               │ + CLI opt│    the driver)
                                                               └──────────┘
        ┌──────────────────────────────────────────────────────────────────────────┐
WAVE C  │ 11 CAPSTONE: Safe-vs-Unsafe differential (identical results/traps) +       │
        │  the optimizer-soundness differential over the corpus + real-metering trap │
        │  proof + the honest performance benchmark + instance-as-policy coexistence │
        │  proof + refresh the conformance image + write the perf report             │
        └──────────────────────────────────────────────────────────────────────────┘
```

- **The optimizer (02→03→04) is the critical path** and the phase's meat; start it first. `02`
  (effect analysis) gates `03`/`04` — an unsound classifier makes every downstream pass unsound.
- **The Unsafe-mode units (05–10) parallelize** once the keystone freezes the `Binding` policy
  fields — they are independent runtime/middle-end/backend changes that only need the *frozen
  signatures*, not each other. `rt_meter` enforce (05), passthrough stdlib + open bif (06), and
  host whitelist/open (07) are pure runtime work; `ir_lower` (08) and `emit_core`+pipeline (09)
  are the middle-/back-end mode application; the linker (10) assembles `profiles.unsafe()` and
  proves coexistence.
- **emit_core (09) does not block on the optimizer** — it needs only the frozen `Binding`
  extension + the `OptLevel` plumbing point. Do not serialize it behind 03/04.

---

## 4. File-ownership map (D1)

> Single owner per file. Several units **extend** existing files (single-owner, additive). The
> keystone makes deliberate, documented cross-file reaches (it must, to land green — Gleam has
> no default field values, so extending `Binding` breaks every constructor).

| Unit | File(s) | Notes |
|---|---|---|
| **01** keystone | `src/twocore/middle/ir_opt.gleam` (interface + `OptLevel`, `todo` passes) · `src/twocore/middle/ir_opt/pass.gleam` (leaf pass combinators — `Pass`/`pass`/`per_function`/`per_expr`/`map_expr`/`run_pipeline`; imports `ir` **only**, so `ir_opt`/`baseline`/`aggressive` all import it with no cycle) · `src/twocore/ir/effect.gleam` (signature stub) · `runtime/instance.gleam` (`Binding` policy fields — incl. `fuel_budget: Int` — + `OptLevel`/`MeterMode`/`BifGate`/`StdlibMode`/`HostPolicy` types) · `runtime/profiles.gleam` *(reach)* (`unsafe()` green) · `ir.gleam` + `rt_trap.gleam` *(reach)* (`FuelExhausted` + its `spec_trap_message`) | `«IROPT-IFACE-FROZEN»` / `«UNSAFE-PROFILE-FROZEN»` / `«METER-ENFORCE-FROZEN»`. **Land green** — see below. |
| **02** effect analysis | `src/twocore/ir/effect.gleam` | The purity/effect classifier (F3). Conservative; adversarially tested. Unblocks 03/04. |
| **03** ir_opt baseline | `src/twocore/middle/ir_opt.gleam` (+ `middle/ir_opt/baseline.gleam` if split) | Trust-neutral passes. Const-fold **must** match `rt_num` bit-exact. |
| **04** ir_opt aggressive | `src/twocore/middle/ir_opt/aggressive.gleam` | Unsafe-only passes; each documents its trust assumption. |
| **05** rt_meter enforce | `src/twocore/runtime/rt_meter.gleam` (extend) | Enforcing `charge` + budget seeding + cost model + `FuelExhausted`. Preserves constant space. |
| **06** passthrough + open bif | `src/twocore/runtime/rt_stdlib.gleam` (extend) · `src/twocore/runtime/rt_bif.gleam` (extend) | `passthrough` ≡ `own` differential; `open` gate (Unsafe-only). |
| **07** rt_host whitelist/open | `src/twocore/runtime/rt_host.gleam` (extend) | The remaining host-dispatch impls; deny-all default preserved. |
| **08** ir_lower Unsafe | `src/twocore/middle/ir_lower.gleam` (extend) | Mode-aware: skip `Charge` when `meter: none`; passthrough stdlib resolution; open BIF gate (no rejection). |
| **09** emit + pipeline | `src/twocore/backend/emit_core.gleam` (extend) · `src/twocore/pipeline.gleam` (extend) · `src/twocore.gleam` (CLI `opt` verb) | Honor the Unsafe `Binding`; wire `ir_opt` into the driver (level from profile); expose the `opt` stage (`.ir → .ir`, decision #5). **`emit_core` synthesizes `instantiate/0` and is the sole owner of the per-instance seeds** — the *documented exception* to posture-agnosticism: `instantiate/0` emits `rt_meter:seed_fuel(binding.fuel_budget)` (first, under `MeterFuel`) and always `rt_host:seed_policy(binding.host_policy)`; every *other* function body stays byte-identical across postures. Extend the security-invariant test for `open`. |
| **10** linker + profile | `src/twocore/runtime/profiles.gleam` (extend) | `profiles.unsafe()` full wiring; `profiles.safe_metered(budget)` (= `Binding(..safe(), fuel_budget: budget)`, mirroring `safe_capped`); **B3-monomorphization coexistence** (Safe+Unsafe builds on one node, distinct output module atoms, shared `twocore@runtime@rt_*` runtime). `instance.gleam` is keystone(01)-owned. |
| **11** capstone | `test/twocore/conformance/**` · `test/twocore/optimize/**` · a benchmark harness · `docs/` (perf report + refreshed conformance image) | Both-profile differential + optimizer-soundness differential + metering trap + benchmark + coexistence proof. |

**Land green (the keystone's cross-file reaches).** Extending `Binding` with policy fields breaks
`safe_default` (`instance.gleam`), `safe()`/`safe_capped()` (`profiles.gleam`), and every test
constructor — the keystone updates them all (Safe = `opt_level: Baseline`, `meter: Fuel`,
`fuel_budget: rt_meter.default_fuel_budget`, `bif_gate: Allowlist`, `stdlib: Own`,
`host_policy: DenyAll`; `unsafe()` inherits `fuel_budget`, harmless under `MeterOff`). Adding the
`FuelExhausted` `TrapReason` breaks `rt_trap.spec_trap_message`'s exhaustive match (add the
mapping) and the IR printer/parser's `TrapReason` matches (add an arm — even though no IR node
references it, the type is exhaustively matched). `unsafe()` in `profiles.gleam` must land
compiling and **tested to be an explicit opt-in** (no accidental Unsafe by omission). The keystone
also lands the `src/twocore/middle/ir_opt/pass.gleam` leaf (pass combinators, `ir`-only import) so
`baseline`/`aggressive` share a cycle-free home. Document every reach in `state.md`.

---

## 5. How to claim & complete (same as Phases 1 & 2)

Read this page → your unit doc → [`specs/state.md`](../state.md). Set status `in-progress`;
confirm your freeze milestones; build to the Definition of Done (D8: **spec-cited** tests, doc
comments on every public function, `gleam format --check src test` clean, **zero warnings**, and
your unit's conformance/interface suite passing — "done" is *the suite passes*, never "it
compiles"). Update `state.md` with what you leave for the next agent. When in doubt about a
foundational decision, **ask the planner** rather than guessing. The manager QA-gates
(`format`/`build`/`test` + a spec-DoD read) and commits+pushes each unit to `main`.

---

## 6. Deferred to Phase 4+ (explicit — stated, not dropped)

- **Phase 4 (the trust-tier ladder & the runs-anywhere build):** tier-P `threaded` state (the
  `state_strategy` seam expansion Phase-2 E1 flagged — a purely-functional instance record
  threaded through every function, "no OTP, no NIF, runs anywhere"); tier-O/N `rt_mem`
  (`atomics` O(1) process-local, `nif` raw ceiling — Unsafe-only); `rt_table` `ets`/`atomics`
  tiers. Phase 3's benchmark motivates it; Phase 3's Unsafe profile *permits* tier N but does not
  ship it.
- **Phase 5 (a complete WASM engine):** reference types (externref/funcref, `table.get/set/copy/
  fill`, typed `select_t`, `elem.wast`); bulk memory (`memory.fill/copy/init`, `data.drop`);
  multi-memory; `memory64`; the WAT text parser; non-function imports + the `spectest` module.
- **Phase 6 (the second frontend):** the Porffor JS→WASM bridge (+ the Porffor-ABI `rt_host`
  shim) → "JS on the BEAM."
- **Later:** Arc as a native JS frontend; the Erlang/Gleam frontend; exception-handling, GC,
  stack-switching, the component model.
