# Unit 11 — Capstone: the Phase-3 proof-of-goal (differentials, metering, benchmark)

> **1–3 owners · Wave C (last) · depends on the freezes AND the landed work of 01–10.** Read
> [`00-overview.md`](00-overview.md) (F1–F8), [`01-interface-freeze.md`](01-interface-freeze.md)
> (the three frozen contracts you bind to), then Phase-2 [`11`](../phase-2/11-capstone.md) (the
> run-ABI + conformance harness you extend). Phases 1 & 2 are complete and green: **509 tests,
> 0 warnings, conformance 1740 / 1359 / 0.**

---

## Context

Phase 3 makes two claims only a capstone can prove: **the optimizer changes nothing observable**
(F2) and **the two named modes coexist, correct, on one node** (F4). Both are *differential*
claims — they compare two compilations of one program and assert equivalence — so the terminal
unit owns the whole-corpus wiring, as Phase-2's capstone owned `load → instantiate → invoke`.
Phase 3 adds no IR nodes and no spec-suite files (F7), so this unit writes **no new frontend
fixtures**; it re-drives the *existing* Phase-1+Phase-2 corpus and spec suite through the new
policy axis and asserts byte-for-byte sameness. It also closes the last resource-bound gap with a
real-metering trap proof (F5) and publishes Phase 3's one claim about the outside world — a
**measured** performance comparison (F8), methodology and limitations written down.

The proof surface is five differentials + one benchmark:

| # | Proof | Decision |
|---|---|---|
| 1 | **optimizer soundness** — corpus at `OptNone`/`Baseline`/`Aggressive` gives byte-identical results + identical traps | F1/F2 |
| 2 | **Safe ≡ Unsafe** — corpus under `profiles.safe()` and `profiles.unsafe()` gives identical spec-correct results | F4/F6 |
| 3 | **zero-overhead Unsafe** — the Unsafe `.core` contains **no** `charge` calls; the Safe `.core` does | F5 |
| 4 | **real metering** — a runaway loop traps `FuelExhausted` at a deterministic fuel bound, in constant space (Safe) | F5 |
| 5 | **instance = policy** — a Safe and an Unsafe instance of one module run on one node, correct + isolated | F4/B3 |
| 6 | **honest benchmark** — Unsafe vs Safe vs hand-written Erlang (+ `wasmtime`) on real kernels, real numbers | F8 |

---

## Deliverables & freeze milestones

**Consumes** (every Phase-3 freeze + landed unit): `«IROPT-IFACE-FROZEN»`
(`ir_opt.optimize/2`, `OptLevel`), `«UNSAFE-PROFILE-FROZEN»` (`profiles.unsafe()`, the
`Binding` policy fields), `«METER-ENFORCE-FROZEN»` (`ir.FuelExhausted`, `rt_meter.seed_fuel/1`,
enforcing `charge/1`); the landed passes (03/04), the enforcing meter (05), passthrough/open
runtime (06/07), mode-aware `ir_lower` (08), the driver wiring `optimize(m, binding.opt_level)`
(09), and `profiles.unsafe()` coexistence wiring (10).

**Produces** (terminal — nothing downstream depends on it): the differential test suites under
`test/twocore/optimize/**`, the metering-trap + coexistence proofs, the committed benchmark
harness + report (`smoke/bench.sh`, `docs/phase-3-benchmark.md`), and the refreshed conformance
image confirmed green under **both** profiles. No publish-day-1 stub — this unit consumes every
freeze and emits nothing others build on.

---

## Files owned

- `test/twocore/optimize/differential_test.gleam` — proofs 1, 2, 3.
- `test/twocore/optimize/metering_test.gleam` — proof 4.
- `test/twocore/optimize/coexistence_test.gleam` — proof 5.
- `test/twocore/optimize/corpus/spin.wat` (+ `.wasm`) — the runaway tail-loop program for proof 4.
- `test/twocore/optimize/corpus/recurse.wat` (+ `.wasm`) — the runaway **non-tail-recursion**
  program for proof 4 (fuel bounds recursion *depth*, node memory `O(budget)`).
- `test/twocore/conformance/driver.gleam` *(extend, single-owner)* — a **binding-parameterized**
  driver so the harness can run the corpus/suite under any `Binding`.
- `test/twocore/conformance/conformance_test.gleam` *(extend)* — run the spec suite under **both**
  `profiles.safe()` and `profiles.unsafe()`; both `fail == 0`, `pass > 0`.
- `smoke/bench.sh` — the benchmark harness (co-located with the existing `smoke/run.sh`).
- `docs/phase-3-benchmark.md` — the committed perf report (methodology + real numbers + limits).
- `docs/wasm-conformance.svg` + `scripts/gen-conformance-svg.sh` footnote — refreshed to Phase-3
  scope (both profiles green; conformance-neutral, F7).

> The **per-pass** property tests (const-fold bit-exact to `rt_num`, effect-barrier "must NOT
> do this" fixtures) belong to units 02/03/04 under `test/twocore/middle/**` — this unit owns
> only the **whole-corpus** differentials. `test/twocore/optimize/**` is a fresh directory, so
> no ownership collision.

---

## A. The differential seam — one binding-parameterized driver

Every proof here holds the *program* fixed and varies the *`Binding`*. The existing conformance
`driver.pipeline()` hard-codes one posture; the capstone generalizes it so the corpus can be
re-driven under `OptNone`/`Baseline`/`Aggressive`, `safe()`, and `unsafe()` from one code path.
It reuses `pipeline.ir_to_core(_, binding)` — which after unit 09 composes
`ir_lower → ir_opt.optimize(_, binding.opt_level) → emit_core` — so the driver never
re-implements the pipeline; it only threads the binding.

```gleam
import twocore/runtime/instance.{type Binding}
import twocore/runtime/profiles

/// Build a `runner.Driver` that compiles+instantiates every module under `binding` (E5,
/// one-instance-one-process). Generalizes `pipeline()` (= `pipeline_with(profiles.safe())`)
/// so the capstone can drive the SAME corpus under any policy posture: the three optimizer
/// levels (spread `opt_level` over `safe()`) and the two named modes (`safe()`/`unsafe()`).
/// The frontend/instantiate/invoke seams are unchanged — only the linked `Binding` differs.
pub fn pipeline_with(binding: Binding) -> runner.Driver
```

Each proof reduces its runs to one **normalized outcome** per `(export, args)`, so two
compilations are compared by a single `==` over spec-observable behavior — never over `.core`
text or IR shape (which the optimizer/mode is *allowed* to change):

```gleam
/// The spec-observable outcome of compiling+running one program point — the ONLY thing F2
/// requires two compilations to agree on. Values carry the RAW bit pattern (D7): NaN
/// payloads, `-0.0`, and i32/i64 wrap are exact (D5). Trap/instantiation-trap collapse to
/// the spec message PHRASE (via `rt_trap.spec_trap_message`), not our internal atom, so an
/// optimizer that changed *which* trap fired is caught. `Rejected` = failed to build a
/// runnable instance (fail-closed, D4); it must be reached at every level or none.
pub type Outcome {
  Value(bits: List(Int))
  Trap(phrase: String)
  InstantiateTrap(phrase: String)
  Rejected
}
```

---

## B. Proof 1 — the optimizer-soundness differential (F1/F2)

**The bar (F2).** For every program in the Phase-1+Phase-2 acceptance corpus (the authored
`test/twocore/conformance/corpus/*.wat` plus the hand-built IR fixtures of `acceptance_test`),
`optimize(m, level)` and `m` produce **identical observable behavior** — same `Outcome` at
`OptNone`, `Baseline`, and `Aggressive`. The three bindings differ in **exactly one field**, so
the optimizer is the only variable:

```gleam
let base = profiles.safe()                                   // MeterFuel/Allowlist/DenyAll/Own
let none = instance.Binding(..base, opt_level: ir_opt.OptNone)
let base_lvl = instance.Binding(..base, opt_level: ir_opt.Baseline)
let aggr = instance.Binding(..base, opt_level: ir_opt.Aggressive)
// For each corpus program p, for each export e:
//   outcome(none, p, e) == outcome(base_lvl, p, e) == outcome(aggr, p, e)   (cross-level identity)
//   AND that shared outcome == p.expected                                    (spec-correctness)
```

Two assertions, both load-bearing: **cross-level identity** (the optimizer changed nothing) and
**each level matches `.expected`** (the shared outcome is the *spec* answer, sourced from the
`.wast`/wasmtime per `corpus.parse` — not "consistently wrong"). Identity alone could pass on a
mutually-broken pair; `.expected` alone is just the existing acceptance test (D8: no
change-detector). Together they are F2.

- **`Aggressive` runs under a Safe runtime here on purpose.** `Aggressive = Baseline ++`
  charge-elision + inlining (F3). Charge-elision touches only the fuel instrumentation — a
  *policy overlay*, not a WASM semantic (F5) — so eliding it under `MeterFuel` changes fuel
  accounting but **not** the WASM `Outcome`, which is exactly the invariant under test (the
  budget is generous, so `FuelExhausted` never fires — proof 4 tests the trap separately).
  Inlining and every other pass are semantics-preserving unconditionally (F2). Anything that
  could change an `Outcome` is out of Phase 3 by construction (F8: Unsafe ≠ incorrect; WASM has
  no UB — WebAssembly spec §4.4, every ill-defined op traps).
- **This differential is the backstop for the effect classifier (F3).** A single unsound
  CSE-of-a-load-across-a-store (unit 02 misclassifying `MemStore` as pure) would change a `mem`
  or `gvar` corpus result — the differential would go red on that program. Unit 02's adversarial
  "must NOT do this" fixtures catch it earlier; this catches anything that slips past them.
- **Spec-suite half (F2: "corpus **and** spec suite").** The corpus gives fine-grained
  byte-identity; §G runs the whole spec suite under `Baseline` and `Aggressive` at `fail == 0`.

---

## C. Proof 2 — Safe ≡ Unsafe, and proof 3 — zero-overhead Unsafe (F4/F5/F6)

**Proof 2 (F4/F6).** The same corpus under `profiles.safe()` and `profiles.unsafe()` gives the
identical spec-correct `Outcome` for every `(export, args)`. Safe and Unsafe are **two distinct
builds** (B3 monomorphization, not a single `.beam` with a swapped runtime): `ir_lower` compiles
metering in/out and the optimizer runs at build time, so `Safe.beam ≠ Unsafe.beam` — different
code, distinct **output** module atoms — while both share the identical `twocore@runtime@rt_*`
runtime modules. This differential asserts those two builds agree on every spec-observable answer,
bundling the whole Unsafe posture at once — `Aggressive` optimizer, `MeterOff`, `BifOpen`,
`StdlibPassthrough`, `HostOpen` — and that none of them changed an answer:

```gleam
for each corpus program p, each export e:
  outcome(profiles.safe(), p, e) == outcome(profiles.unsafe(), p, e) == p.expected
```

`StdlibPassthrough ≡ StdlibOwn` on every shared function (F6) is exercised transitively wherever
the corpus calls a shared stdlib function; unit 06 owns the *focused* passthrough-vs-own
differential, this owns the *end-to-end* one. `BifOpen`/`HostOpen` widen only a build-controlled
allow-set — **no** data-driven `apply(Mod,F,Args)` with `Mod` from program data (D3a); §"security
note" states the invariant, unit 09's structural test enforces it.

**Proof 3 (F5), zero-overhead Unsafe.** `MeterOff` means `ir_lower` inserts **no `Charge` nodes
at all** — not no-op charges, *absent* ones — so the emitted `.core` differs from Safe by
exactly the instrumentation. Proven as a robust text-level assertion on the emitted Core, not a
brittle whole-text diff:

```gleam
// For a metered corpus function (e.g. sum_to, whose loop is charged under Safe):
let safe_core = emit_core.emit_module(m, profiles.safe())   |> print
let unsafe_core = emit_core.emit_module(m, profiles.unsafe()) |> print
assert count_occurrences(safe_core, "charge") > 0            // Safe instruments
assert count_occurrences(unsafe_core, "charge") == 0         // Unsafe: none, anywhere
assert count_occurrences(unsafe_core, "rt_meter") == 0       // and no seed_fuel either
```

The result differential (proof 2) shows the two `.core`s compute the same answers; this shows
they differ only by the charge sites — together, F5's "differ exactly by the instrumentation."

---

## D. Proof 4 — the real-metering trap (F5)

Phase 1/2 shipped metering **observe-only**; Phase 3 makes CPU fuel **enforce** in Safe. The
capstone proves the resource bound *bites*: a runaway loop traps at a **deterministic** finite
fuel bound, the trap surfaces through the run-ABI, and enforcement stays **constant-space** and
preemptible (F5). A new corpus program `spin.wat` loops with no exit:

```wat
(module (func (export "spin") (loop $l (br $l))))   ;; unbounded back-edge; charged each iter
```

Alongside it, `recurse.wat` runs away through **non-tail recursion** (its call result is consumed,
so a frame must be kept), charged `fn_cost` per call — so fuel bounds recursion **depth**, not just
loop iterations:

```wat
(module (func $r (export "recurse") (param $n i32) (result i32)   ;; result consumed ⇒ non-tail
  (i32.add (i32.const 1) (call $r (i32.const 0)))))               ;; unbounded depth; charged each call
```

The test seeds a **small** budget (via `profiles.safe_metered(budget)`) so each trap fires fast and
deterministically, then asserts the `FuelExhausted` trap and the space behaviour of each shape:

```gleam
// A Safe binding whose fuel budget is lowered to a small finite value via safe_metered, so
// the runaway loop trips the bound in a bounded number of iterations — deterministically,
// because `charge` is applied per the fixed cost model.
let mod = compile_load(read("spin.wasm"), profiles.safe_metered(budget))
let assert Ok(proc) = ffi.start_instance(mod)

// (a) It TRAPS FuelExhausted (our policy trap, NOT a WASM spec trap — keystone C.1).
let assert Error(reason) = ffi.call_instance(proc, atom.create("spin"), [])
assert string.contains(reason, "fuel_exhausted")            // the raised {wasm_trap, fuel_exhausted}
assert rt_trap.spec_trap_message(ir.FuelExhausted) == "fuel exhausted"   // the mapping

// (b) DETERMINISTIC: same budget → the same trap on every run (a runaway is not flaky).
// (c) CONSTANT SPACE: a small budget and a 100×-larger budget both trap using process memory
//     bounded by a small constant (the loop is a tail-`apply` back-edge; fuel is pdict state,
//     never loop-carried — E1/F5). Measured via ffi.gc_and_memory, like the store-loop test.
```

- **Non-tail recursion is bounded too (fuel bounds *depth*).** `recurse` under the same small
  `profiles.safe_metered(budget)` traps `FuelExhausted` after ~`budget/fn_cost` calls — proving
  fuel caps recursion **depth**, not only loop iterations. Unlike the tail-`apply` spin (constant
  space), the process stack grows to `O(budget)` frames before the trap, so node memory at the
  trap is `O(budget)`, **not** constant — the residual node-memory caveat (unit 05 §C.3). The
  bound still *bites*: the runaway terminates deterministically, which is the F5 property tested.
- **`FuelExhausted` stays out of the conformance trap-phrase table.** Its spec message
  `"fuel exhausted"` is deliberately distinct from every WASM phrase (keystone C.1) so the
  harness never mis-maps a real trap to it; the metering test matches the atom `fuel_exhausted`
  directly (`string.contains`), *not* `runner.trap_matches` (which is for spec phrases). Do not
  add `fuel_exhausted` to `runner.spec_phrase_of`.
- **Spec anchor.** `FuelExhausted` is an embedder-imposed CPU bound (WebAssembly spec §7
  *Embedding*, the suite's `assert_exhaustion`): it *aborts*, it never returns a wrong value, so
  it is sound w.r.t. the spec but is not one of the spec's own traps — which is why it carries a
  non-spec message and never appears in an `assert_trap`.

> **Resolved (keystone 01 / profiles 10).** The runaway tests need a **small, deterministic fuel
> budget**. The reconciled decision adds a `fuel_budget: Int` field to `Binding` (keystone 01,
> mirroring `safe_max_pages`) — set by `safe_default()` to `rt_meter.default_fuel_budget`,
> inherited by `unsafe()` (harmless under `MeterOff`) — plus a `profiles.safe_metered(budget)`
> constructor (unit 10) `= Binding(..safe(), fuel_budget: budget)`, mirroring `safe_capped`. This
> test seeds a tiny bound directly via `profiles.safe_metered(budget)` (used above); the
> `emit_core`-synthesized `instantiate/0` (unit 09) bakes `seed_fuel(binding.fuel_budget)` (unit
> 05 §D). This is the **single** fuel-budget channel — there is no `emit_core`-bakes-the-default
> fallback.

---

## E. Proof 5 — instance = the unit of policy (F4/B3)

The headline of F4: a **Safe** instance and an **Unsafe** instance of the *same module* run on
**one node**, concurrently, with correct results and **no** state or capability leakage. The
Instance/Binding API presents this uniformly ("the instance is the unit of policy"), but the
realization is **B3 monomorphization**: Safe and Unsafe are distinct compiled `.beam`s (Safe has
charge sites + allowlist; Unsafe has neither) from the *same source*, given unique **output**
module names, both linking the shared `twocore@runtime@rt_*` runtime modules — **not** one `.beam`
with a swapped linked runtime (that B1 model is Phase-4-deferred). Each instantiates in its own
owned process (E1), which seeds that instance's runtime policy (fuel budget, host policy). The
proof reuses the isolation pattern of `corpus_test.cross_instance_isolation_test`, but across
*profiles*:

```gleam
let safe_mod = compile_load(read("iso.wasm"), profiles.safe())     // metered, allowlist, deny-all
let unsafe_mod = compile_load(read("iso.wasm"), profiles.unsafe()) // no meter, open, passthrough
let assert Ok(s) = ffi.start_instance(safe_mod)
let assert Ok(u) = ffi.start_instance(unsafe_mod)

// Correct + identical: both compute the same spec answer (proof 2 at the instance level).
// Isolated: a global.set + i32.store in the Safe instance is INVISIBLE to the Unsafe instance
//   and vice versa (separate processes → separate cells), and each still sees its own writes.
let assert Ok(_) = ffi.call_instance(s, atom.create("set_global"), [111])
let assert Ok(_) = ffi.call_instance(u, atom.create("set_global"), [222])
assert ffi.call_instance(s, atom.create("get_global"), []) == Ok(111)   // no cross-leak
assert ffi.call_instance(u, atom.create("get_global"), []) == Ok(222)
// Policy is per-instance: the Safe process meters (its fuel advances); the Unsafe one has
// no charge sites at all (proof 3) — same node, two postures, no shared state.
```

No capability leakage: the Safe instance's `HostDenyAll` still rejects a host import even while
an `HostOpen` Unsafe instance of a different module accepts one on the same node — the policy
lives on the instance itself (charge sites + allowlist baked at build time; host policy + fuel
budget seeded per instance at instantiation), never in ambient node state (D3a/D9). (The `iso.wasm`
corpus module is import-free, so capability isolation is asserted with the hand-built host-import
fixtures of `acceptance_test`, run once under each profile.)

---

## F. Proof 6 — the honest benchmark (F8)

The one claim Phase 3 makes about the outside world — "the fastest possible code, potentially
faster than hand-written Erlang" — is **measured**, never asserted. The benchmark is a committed
artifact (`docs/phase-3-benchmark.md`) with methodology, real numbers, and stated limitations,
driven by `smoke/bench.sh` over the **existing** smoke crates (README already differential-checks
them bit-exact vs `wasmtime`):

**What Phase-3 speed does and does not come from (honest scope, F8).** All measured speed here
comes from the **optimizer alone** (Baseline vs Aggressive passes). The passthrough/open-BIF path
ships as a **mechanism with zero active routes** — every shared stdlib function (`gcd` included)
stays **in-house** under *both* profiles, so it contributes **no** speedup in this benchmark (unit
06's passthrough≡own differential proves the *mechanism* and its non-vacuity, not a live route).
"Potentially faster than hand-written Erlang" is therefore a **measured question**, not a thesis:
the honest hand-written-Erlang baseline is **CRC-32 only** (optionally joined by one memory-heavy
hand-written baseline), and the SHA-256/DEFLATE `crypto`/`zlib` figures are a native-NIF
**ceiling** — not hand-written Erlang, and 2core is expected to sit below them.

| Kernel | Crate | Exercises |
|---|---|---|
| `crc32(n)` | `crc32fast` | table-driven CRC-32, memory loads |
| `sha256_word(n)` | `sha2` | 64-round compression, rotations, message schedule |
| `deflate_roundtrip(n)` | `miniz_oxide` + `dlmalloc` | real DEFLATE compress+decompress, `memory.grow` |

**Contenders** (all running the *identical* computation where possible):

1. **2core-Unsafe** — compiled under `profiles.unsafe()` (Aggressive optimizer, `MeterOff`,
   passthrough stdlib, open BIF), `.beam` timed with `gleam run -- exec -n N` (times only the
   invocations — the ABI already exists, `src/twocore.gleam`).
2. **2core-Safe** — compiled under `profiles.safe()` (Baseline optimizer, enforcing fuel,
   allowlist, own stdlib), same `exec -n N` timing.
3. **hand-written Erlang** — a pure-Erlang implementation of at least CRC-32 (table-driven, easy
   to write faithfully) as the honest "hand-written Erlang" baseline; SHA-256/DEFLATE additionally
   report the **native BIF/library** (`crypto:hash(sha256, _)`, `zlib`) as a *native-ceiling
   reference*, clearly labeled — these are NIF-backed C, **not** hand-written Erlang, and 2core is
   expected to sit below them (stated as a limitation, not hidden).
4. **`wasmtime`** — the same `.wasm`, where the executable is on `PATH` (skipped gracefully
   otherwise, exactly as the smoke `run.sh` and Tier-B adapter already do).

**Methodology (written in the report, F8).** State: the input each `n` generates and that
contenders 1/2/4 run byte-identical work (contender 3 is a *different implementation* over
equivalent-size input — a labeled caveat); warmup + repeat `N`; that timing excludes
compile/load/instantiate (`exec` measures invocations only); the machine/OTP/Rust/wasmtime
versions + testsuite pin; and the honest reading — where 2core-Unsafe wins, where the native NIF
ceiling wins, and the Safe-vs-Unsafe delta on the identical kernel (the fuel-instrumentation cost).
No hero number; one table per kernel, caveats inline.

```sh
# smoke/bench.sh (schematic): build+gate the wasm (reuse run.sh), compile it to a .beam under
# EACH profile, exec each N times, run the Erlang baselines + wasmtime, print a labeled table.
gleam run -- to-beam-wasm "$WASM" --profile unsafe smoke.unsafe.beam   # FLAG: profile-selecting compile (unit 09)
gleam run -- to-beam-wasm "$WASM" --profile safe   smoke.safe.beam
gleam run -- exec -n "$N" smoke.unsafe.beam "$fn" "$arg"               # ns/call for Unsafe
gleam run -- exec -n "$N" smoke.safe.beam   "$fn" "$arg"               # ns/call for Safe
```

> **FLAG for unit 09 (CLI).** The bench needs a **profile-selecting compile-to-`.beam`-from-wasm**
> path (`--profile safe|unsafe`, or `-O0|-O2`), since today `run`/`to-core` hard-code
> `profiles.safe()` and `to-beam` takes only `.core`. Unit 09 owns `src/twocore.gleam`; this is a
> small additive verb/flag. If it does not land, `bench.sh` falls back to a tiny Gleam harness that
> calls `pipeline.ir_to_core(_, profiles.unsafe())` directly.

---

## G. Conformance refresh under both profiles (F7)

Phase 3 is **conformance-neutral**: no new IR nodes, no new spec files, so the counts do not move
(1740 / 1359 / 0). The proof is that the *same* green holds under **both** derived profiles —
which also delivers the spec-suite half of F2 (§B):

- `conformance_test.gleam` runs the pinned allowlist suite twice — `driver.pipeline_with(profiles.safe())`
  (Baseline optimizer + enforcing fuel) and `driver.pipeline_with(profiles.unsafe())` (Aggressive
  optimizer + open runtime) — and asserts `fail == 0 && pass > 0` for **each**. A single
  optimizer or mode regression on any allowlisted assertion goes red. The Safe fuel budget for the
  suite is generous enough that no in-scope program trips `FuelExhausted` (finite enough that
  proof 4's runaway traps).
- Refresh `docs/wasm-conformance.svg` (`RUN_VENDOR=1 scripts/gen-conformance-svg.sh`) and update
  the generator footnote from "Phase-2 scope" to "Phase-3: both profiles green, optimizer on" —
  co-located, additive; the numbers are unchanged, the *scope caption* is not.

---

## Effect / soundness / security note

- **No ambient authority survives the Unsafe posture (D3a).** Proof 2 exercises `BifOpen`/
  `HostOpen`/`StdlibPassthrough` end-to-end and gets spec-identical answers; none introduces a
  data-driven `apply(Mod,F,Args)` — "open" widens a build-controlled allow-set. Unit 09's
  structural test is the enforcement; the differential is the behavioral cross-check.
- **Fail-closed default (D4/D9).** Every run that does not *explicitly* pass `profiles.unsafe()`
  is Safe; the Safe-vs-Unsafe differential is the only place Unsafe is constructed — a named
  opt-in, no Unsafe-by-omission path.
- **The optimizer cannot be unsound and pass.** An unsound rewrite (effect misclassification, a
  reorder across a barrier) changes an `Outcome`; "green" means *every observable was preserved*,
  not "it compiled." `FuelExhausted` is sound w.r.t. WASM (F5) — it aborts, never returns a wrong
  value; the suite/corpus budget lets correct programs complete and only a runaway trips it.

---

## Verification — Definition of Done (D8)

- **Proof 1 green:** every corpus program yields one `Outcome` shared across `OptNone`/`Baseline`/
  `Aggressive`, and that outcome equals `.expected` (spec-sourced — no change-detector). Cites the
  WASM spec for each asserted behavior (numerics <https://webassembly.github.io/spec/core/exec/numerics.html>,
  bounds/traps exec/instructions.html) via the reused `corpus.parse` values.
- **Proofs 2 & 3 green:** corpus `Outcome`s identical under `safe()`/`unsafe()` and each ==
  `.expected`; the Unsafe `.core` has zero `charge`/`rt_meter` occurrences, the Safe `.core` has
  them.
- **Proof 4 green:** `spin` traps `fuel_exhausted` under a small `safe_metered(budget)`,
  deterministically, in constant space (`gc_and_memory` bounded across a 100× budget spread), and
  `recurse` (non-tail) traps `fuel_exhausted` too — bounding recursion **depth** (node memory
  `O(budget)`, per unit 05 §C.3's caveat, not constant);
  `rt_trap.spec_trap_message(ir.FuelExhausted) == "fuel exhausted"`.
- **Proof 5 green:** a Safe and an Unsafe instance of `iso.wasm` coexist, correct + isolated
  (no cross-cell leak; per-instance policy).
- **Benchmark committed:** `smoke/bench.sh` runs; `docs/phase-3-benchmark.md` carries real numbers
  with methodology + limitations (F8) — no marketing claim, no single hero number.
- **Conformance:** `fail == 0 && pass > 0` under **both** profiles; image refreshed; counts
  unchanged (F7).
- **`gleam format --check src test` clean; `gleam build` ZERO warnings; `gleam test` stays green
  (≥ 509, now higher).** Done = **the suites pass**, never "it compiles."

---

## What this unit leaves

Phase 3 is proven: the shared optimizer preserves every observable at both levels, the two named
modes coexist correct + isolated on one node, CPU fuel enforces a real bound at zero Unsafe cost,
and the performance claim is measured, not asserted. Deferred (stated, not dropped): **Phase 4** —
tier-P `threaded` "runs-anywhere, no-OTP" state, `rt_mem` `atomics`/`nif` + `rt_table` tiers
(Unsafe *permits* tier N; Phase 3 ships only tier-O), and the wider optimizer (LICM, range-based
bounds-check elimination, SIMD — F8); **Phase 5** — reference types / bulk memory / multi-memory /
memory64 / the WAT parser / non-function imports + `spectest`; **Phase 6** — the Porffor JS→WASM
bridge. The benchmark's own findings motivate the Phase-4 tier ladder, where a NIF-backed `rt_mem`
and threaded state would close the gap this report measures against the native ceiling.
