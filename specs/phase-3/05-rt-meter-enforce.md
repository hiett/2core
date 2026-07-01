# Unit 05 — rt_meter: real CPU-fuel enforcement + the cost model

> **One owner · parallel wave (with 06/07 runtime work) · gated on `«METER-ENFORCE-FROZEN»`
> and `«UNSAFE-PROFILE-FROZEN»`.** This unit closes the platform's last **CPU-time**
> resource-bound gap (memory was already bounded by `rt_mem`'s max-pages cap, E3): metering
> flips from **observe-only** to a **real CPU-time bound**. In Safe mode `charge` decrements a
> per-instance fuel **budget** and, on exhaustion,
> raises `FuelExhausted` (F5) — while the generated code and the tail-`apply` loop back-edge
> stay **byte-identical** (E1) and constant-space. Unsafe pays **exactly nothing** (`MeterOff`
> ⇒ no `Charge` nodes at all). Read [`00-overview.md`](00-overview.md) (F5, F7, F8),
> [`01-interface-freeze.md`](01-interface-freeze.md) §C, and Phase-2
> [`03-rt-state-lifecycle.md`](../phase-2/03-rt-state-lifecycle.md) (the cell precedent) first.

---

## Context — the observe-only gap, and what the keystone froze

Phase 1/2 shipped `rt_meter` as an **accumulator**: `charge(cost)` does a process-dictionary
read-add-write into one counter and always returns `Nil`; `fuel_consumed()` exposes the total
(`src/twocore/runtime/rt_meter.gleam`). There is **no budget, no trap-on-exhaustion, no CPU
bound** — a runaway loop runs forever (well, until the node is killed). Phase 2 fixed *memory*
exhaustion (the `rt_mem` max-pages cap, E3); **CPU** was left as a deliberate seam (D9/E8).

The keystone (unit 01, §C — `«METER-ENFORCE-FROZEN»`) has already landed the **signatures and
the trap taxonomy** this unit fills:

- `ir.TrapReason` gained `FuelExhausted` — a **runtime resource-limit** reason, *never* emitted
  as an IR `Trap` node, raised only by `rt_meter`. `rt_trap.spec_trap_message(FuelExhausted) ->
  "fuel exhausted"` (a *policy* message, deliberately distinct from every WASM spec trap phrase).
- `runtime/instance.gleam` gained `MeterMode { MeterFuel, MeterOff }` and the `Binding.meter`
  field. `safe_default()` → `meter: MeterFuel`; `profiles.unsafe()` → `meter: MeterOff`.
- `rt_meter` gained `seed_fuel(budget: Int) -> Nil` (a trivial freeze body) and the **documented
  enforcing contract** on `charge/1` — arity and return type **unchanged** (arity 1, returns
  `Nil`), so generated code and the loop back-edge do not move a byte.

This unit implements the **enforcement body**: the budget cell, the exhaustion raise, the
deterministic cost model that makes the bound meaningful, and the instantiate-time seeding
coordination. It changes **no** ABI, **no** IR grammar, and **no** frontend surface (F7).

---

## Deliverables & freeze milestones

**Consumes** (already frozen, do not re-open): `«METER-ENFORCE-FROZEN»` (the `seed_fuel/1` and
`charge/1` signatures + `FuelExhausted` + its message) and `«UNSAFE-PROFILE-FROZEN»` (the
`MeterMode`/`Binding.meter` posture; `MeterFuel` = enforce, `MeterOff` = no charge sites).

**Produces**: an **enforcing** `rt_meter` — a per-instance finite fuel budget seeded at
instantiation, a `charge` that raises `FuelExhausted` on exhaustion, a documented deterministic
cost model, and the emit-side seeding contract. No new freeze milestone: downstream units bind
to the keystone's frozen signatures, not to this unit's bodies.

## Files owned

- `src/twocore/runtime/rt_meter.gleam` — **extend** (single-owner-additive). Add the budget
  cell + `seed_fuel` body + enforcing `charge` + `default_fuel_budget`; keep `fuel_consumed`
  and `reset_fuel` observable and unchanged.
- `test/twocore/runtime/rt_meter_test.gleam` — **extend** with the spec-first enforcement suite.

**Not owned (coordination only):** `ir_lower.gleam` (the `Charge`-insertion + `fn_cost`/
`loop_cost` cost *values*) is unit 08's; `emit_core.gleam`'s `instantiate/0` (which must call
`seed_fuel`) is unit 09's. This unit **specifies** what they call and names the value channel
(§D), but does not edit them.

---

## A. The per-instance fuel BUDGET (tier-O cell, like Phase-2 rt_state)

The budget is **per-instance / per-process state**, held exactly where Phase-2's mutable state
lives: the **owning process's dictionary** (E1, one-instance-one-process). It is **not** a field
of `MeterMode` and **not** threaded through any generated function signature — so the loop
back-edge stays a bare tail-`apply` (§B). Two pdict keys, both the unique-atom
0-field-constructor pattern `rt_meter` already uses (`TwocoreRtMeterFuel → twocore_rt_meter_fuel`):

```gleam
/// The two process-dictionary keys this instance's metering uses. Each 0-field constructor
/// compiles to a unique, namespace-hygienic atom, so neither can clash with `rt_state`'s cell
/// key (`twocore_rt_state`) or any other pdict use.
type MeterKey {
  TwocoreRtMeterFuel    // the running CONSUMED total (existing; keeps fuel_consumed observable)
  TwocoreRtMeterBudget  // the seeded BUDGET; ABSENT ⇒ observe-only sentinel (legacy/test posture, §A.2)
}

/// The default finite Safe fuel budget, in cost units (see §C). Large enough that the entire
/// Safe acceptance corpus + spec suite completes (the heaviest corpus program, `sum_to(100000)`,
/// consumes ~100_001 units), finite enough that a runaway loop traps. The capstone (unit 11)
/// CALIBRATES this against the corpus; the linker may LOWER it per instance (§D), exactly as
/// `safe_max_pages` bounds memory. This is the single source of truth for "how much CPU a Safe
/// instance may spend before `FuelExhausted`."
pub const default_fuel_budget: Int = 1_000_000_000
```

### A.1 `seed_fuel` — install the budget, reset the counter (per (re)instantiation)

```gleam
/// Seed this instance's CPU-fuel BUDGET (F5), resetting the consumed counter to 0.
///
/// - `budget`: the finite fuel bound in cost units (§C). Called ONCE by the generated
///   `instantiate/0` (unit 09), when `binding.meter == MeterFuel`, INSIDE the instance's owned
///   process — so the budget lives in that process's dictionary alongside the Phase-2 cell
///   (one-instance-one-process, E1), isolated per instance and GC'd with the process. A
///   (re)instantiation re-seeds ⇒ a FRESH budget; two seed cycles in one reused process never
///   observe each other's remaining fuel (the reset is atomic — one `put` per key).
/// - Return: always `Nil`. Total; never raises.
pub fn seed_fuel(budget: Int) -> Nil {
  let _ = erlang_put(TwocoreRtMeterBudget, budget)
  reset_fuel()
}
```

### A.2 Fail-closed posture — a metered build is BOUNDED by default (D4)

**The requirement (D4): no `MeterFuel` artifact runs unbounded by default.** A metered build's
default posture must be **bounded**, never silently unbounded — mirroring the correctly
fail-closed host boundary, where an un-seeded host policy defaults to **deny-all**. Two facts
guarantee this for every shipped Safe instance:

- A **Safe / `MeterFuel`** instance seeds the budget as the **first effect** of `instantiate/0`,
  *before* any element/data segment, `start`, or export runs (§D), and the shipped run-ABI
  **always** instantiates before it invokes — so the production CPU bound is armed from the very
  first `charge`; **no charged code in a Safe instance ever executes against an un-seeded budget**.
- An **Unsafe / `MeterOff`** instance has **no `Charge` nodes at all** (unit 08) — there is
  nothing to under-enforce.

Therefore there is **no reachable execution in a metered build where enforcement is intended but
the budget is un-seeded**.

**The observe-only sentinel is an explicit legacy/test posture — NOT the default of a metered
build.** An **un-seeded** budget (the `TwocoreRtMeterBudget` key absent) making `charge`
accumulate without raising is a back-compat allowance for the Phase-1/2 tests (and any code that
`charge`s without seeding); it is reachable only where enforcement is *not* intended, and never on
a shipped metered artifact. **Prefer making `charge` itself fail-closed** — treat an un-seeded
charge *inside a metered build* as already-exhausted — if that is achievable without breaking the
**509** legacy tests; the implementer resolves the back-compat mechanics against the real suite,
but the requirement stands regardless of the mechanism: no metered artifact runs unbounded by
default. (This mirrors `rt_state`'s "un-seeded cell is unreachable under the harness contract"
framing, E3.) The seed-before-charge ordering is a Verification item and a hand-off to unit 09/11.

---

## B. The enforcing `charge` — ABI unchanged, constant space, preemptible

`charge/1` keeps its **exact** Phase-1/2 shape — arity 1, returns `Nil` — so the emitted
`let _ = call '…rt_meter':'charge'(Cost) in body` and the tail-`apply` back-edge are
**byte-identical** to Phase 2 (E1; the constant-space property proven for `sum_to(100000)`).
The only change is that, when a budget is present, an over-budget total **diverges by raising**:

```gleam
import twocore/ir.{FuelExhausted}
import twocore/runtime/rt_trap

/// Charge `cost` fuel against this process's running total (ABI UNCHANGED — arity 1, `Nil`).
///
/// - `cost`: a non-negative cost-model unit (§C) for the work about to run.
/// - Effect: advance the consumed total by `cost` (recorded first, so `fuel_consumed()` stays
///   accurate even at the trap). THEN, iff a budget was seeded and the new total exceeds it,
///   raise `FuelExhausted` via `rt_trap.raise` — surfacing as the catchable error-class
///   `{wasm_trap, fuel_exhausted}` that the run-ABI already catches (F5/F7). If NO budget was
///   seeded (the observe-only sentinel), never raise — accumulate only. Per §A.2 this un-seeded
///   path is the Phase-1/2 legacy/test posture, NEVER a shipped metered build (which always
///   seeds first); the implementer MAY harden it to fail-closed — treat un-seeded-in-a-metered-
///   build as exhausted — where the 509 legacy tests permit.
/// - Return: `Nil` on a within-budget charge; DIVERGES (never returns) on exhaustion. Typed
///   `-> Nil` because the raise arm has bottom type `a`, which unifies with `Nil`.
pub fn charge(cost: Int) -> Nil {
  let consumed = fuel_consumed() + cost
  let _ = erlang_put(TwocoreRtMeterFuel, consumed)
  case budget() {
    Ok(b) if consumed > b -> rt_trap.raise(FuelExhausted)
    _ -> Nil
  }
}

/// This process's seeded budget, or `Error(Nil)` when un-seeded (the observe-only sentinel).
/// Private: the enforcement chokepoint `charge` consults.
fn budget() -> Result(Int, Nil) {
  case decode.run(erlang_get(TwocoreRtMeterBudget), decode.int) {
    Ok(b) -> Ok(b)
    Error(_) -> Error(Nil)
  }
}
```

`fuel_consumed/0` and `reset_fuel/0` are **unchanged** (F5: `fuel_consumed()` stays observable
after enforcement lands). The comparison is strict (`consumed > b`): a run that spends *exactly*
the budget completes; the charge that would push it **over** traps. This makes the trap point a
sharp, deterministic function of the budget (§C).

**Why constant space + preemption survive (E1).** The budget and counter are *process-dictionary
state*, read/written only by `charge`/`seed_fuel` — **not** loop-carried, **not** in any function
signature. `erlang:get`/`put` read/replace a root by reference (no copy), push no return address,
and do not change tail-call structure; the loop back-edge `apply L(vars)` stays in tail position
(the `rt_meter` + `sum_to(100000)` precedent, constant-space on OTP 29 — `state.md`). `charge`
is still an ordinary reduction-consuming op that either returns `Nil` or **diverges** — a raise
is not a value the loop must thread, so the constant-space letrec template is untouched. Because
`get`/`put`/compare cost reductions like ordinary BIFs, the scheduler still **preempts** a
metered loop mid-flight (§9.2 preemptive execution).

**Import note.** `rt_meter` newly imports `rt_trap` and `ir.{FuelExhausted}`. This is **acyclic**:
`rt_trap → ir` only, `ir` imports no runtime module, so `rt_meter → rt_trap → ir` has no back-edge.
Raising through `rt_trap.raise` (not a bare `erlang:error`) keeps the error term shape frozen with
unit 07 (`{wasm_trap, Kind}`), so the conformance runner catches `FuelExhausted` with **no new
plumbing** (F7).

---

## C. The deterministic per-op COST MODEL (our policy, spec-neutral)

WebAssembly defines **no** notion of fuel or cost — the spec only permits an embedder to abort on
**resource exhaustion** (WebAssembly spec [§7 Embedding](https://webassembly.github.io/spec/core/appendix/embedding.html);
the test suite's `assert_exhaustion`). The cost model is therefore **entirely 2core policy**. Its
contract is not a particular magnitude but a **determinism property** and a **soundness property**.

### C.1 Where costs are assigned (the seam)

Costs are assigned at **IR lowering**, not in `rt_meter`. `ir_lower` inserts a
`Charge(cost, body)` node at two sites (`src/twocore/middle/ir_lower.gleam`, `fn_cost`/`loop_cost`):

- **Function entry** — every function body is wrapped `Charge(fn_cost, body)`, so `fn_cost` is
  charged **once per call/entry** (recursion charges per recursive call).
- **Loop back-edge** — every `Loop` body is wrapped `Charge(loop_cost, body)`, so `loop_cost` is
  charged **once per iteration** (the back-edge re-evaluates the `Charge`).

Phase 3 keeps the Phase-1/2 fixed values (`fn_cost = loop_cost = 1`); the model is intentionally
**coarse** (per-construct, not per-instruction). Finer per-op weights are a *future* refinement
that this unit's contract already accommodates (any non-negative cost is legal). Unit 08 gates
the *insertion* on `binding.meter`: **`MeterFuel`** inserts the `Charge` sites; **`MeterOff`**
inserts **none** — the `.core` under Unsafe differs from Safe by *exactly* the charge
instrumentation (F2's differential proves it; zero overhead, F5).

### C.2 The determinism property (the test target — F5)

> Fuel consumed by an execution is a **pure function of its control-flow trace** — the number of
> function entries times `fn_cost` plus the number of loop iterations times `loop_cost` — and is
> **independent of wall-clock time, scheduler decisions, or BEAM reduction counts**.

Consequently the trap point is **deterministic and reproducible**: for a budget `B` with
`fn_cost = loop_cost = 1`, a top-level function whose body is a single counting loop consumes `1`
(entry) `+ k` (after `k` iterations); it raises `FuelExhausted` on the first iteration where
`1 + k > B`, i.e. after exactly `B` iterations — the **same** number on every run, on every node,
under any scheduling. Tests assert *this bound*, not whatever the code happens to emit (D8).

### C.3 The soundness property — why this coarse model actually bounds CPU

Every unbounded computation expressible in WASM 1.0 must pass through **either** a loop back-edge
**or** a (recursive) call — both charged. Straight-line code without loops or calls is bounded by
program size (finite, charged once at entry). Therefore **any execution that consumes unbounded
CPU also consumes unbounded fuel**, so a **finite** budget guarantees *terminate-or-trap*. This is
the whole justification for flipping observe-only → enforce: the cost model need not weight every
opcode to be a sound CPU bound, only to charge every construct that can iterate or recurse.
`FuelExhausted` is sound w.r.t. the spec — it **aborts**, it never returns a wrong value
(WebAssembly spec §7), and it is unreachable for any correct program under a sufficiently large
budget (the capstone calibrates `default_fuel_budget` so the whole corpus/spec suite completes).

**What fuel bounds — CPU-*time*, not space.** Fuel is a bound on *work* (reductions), **not** on
stack/heap *footprint*; memory is bounded **separately** by `rt_mem`'s max-pages cap (E3). For
**tail iteration** (the loop back-edge template, §B) the distinction is moot: the loop runs in
**constant space**, so a finite budget bounds time *and* space. For **non-tail recursion** each
call charges `fn_cost ≥ 1`, so a finite budget bounds recursion **depth** — the process cannot
recurse deeper than ~`budget/fn_cost` frames before `FuelExhausted` fires — but the *node memory*
held at that depth is `O(budget)`, not `O(1)` (a residual caveat, exercised by unit 11's non-tail
runaway fixture). So fuel is a sound **CPU-time** bound, and a space bound only for tail loops; it
does **not** unconditionally close every space gap.

---

## D. Budget-seeding coordination with `instantiate/0` (what emit_core/linker must call)

This unit owns the **rt_meter side**; the **sole call site** is the `emit_core`-synthesized
`instantiate/0` (unit 09 — the **confirmed** owner of emitting per-instance seeds; `ir_lower`,
unit 08, cannot emit `instantiate`). The contract this unit fixes for them:

1. **When `binding.meter == MeterFuel`**, `instantiate/0` emits `call
   '…rt_meter':'seed_fuel'(Budget)` as its **first** effect — before `rt_state:seed`'s
   element/data segments and before `start` (so the budget is live before *any* charge, incl. a
   metered `start`). It is `let`-sequenced like the other instantiate effects (E1 ordered
   effects; non-DCE). When `binding.meter == MeterOff`, `instantiate/0` emits **no** `seed_fuel`
   and there are **no** `Charge` sites — rt_meter is never called (zero overhead).
2. **The `Budget` value channel (exactly one channel).** `seed_fuel/1` takes an `Int` baked by
   the emitter. The channel mirrors `safe_max_pages`: a `Binding.fuel_budget: Int` field — added
   to the (now-reconciled) frozen `Binding` by the keystone (unit 01) — set by `safe_default()`/
   `profiles.safe()` to `rt_meter.default_fuel_budget` and inherited by `profiles.unsafe()`
   (harmless under `MeterOff`), lowerable per instance by `profiles.safe_metered(budget)` (unit
   10, `= Binding(..safe(), fuel_budget: budget)`, mirroring `safe_capped`) or the linker, so the
   `emit_core`-synthesized `instantiate/0` bakes `seed_fuel(binding.fuel_budget)` (single source
   of truth; the profile fixes CPU alongside the page cap). `default_fuel_budget` (this unit) is
   the canonical default. There is **exactly one channel** — the earlier "fallback: `emit_core`
   bakes `rt_meter.default_fuel_budget` directly" is **struck**.

This unit ships a **local proof** of the seam — `seed_fuel(n)` then `charge` enforces at bound
`n` — and hands the full *load → instantiate → invoke* propagation (test §3) and the two-live-
instances coexistence proof to units 09/11, which own the run-ABI harness.

---

## Effect / soundness / security note

- **Fail-closed default (D4/D9).** Safe = `MeterFuel` = a finite budget seeded first at
  instantiation; there is **no** path to unbounded CPU in a Safe instance. Unsafe's `MeterOff` is
  the sole way to disable metering and is an explicit, tested opt-in (`profiles.unsafe()`), never
  reachable by omission.
- **No ambient authority (D3a).** `charge` raises through `rt_trap.raise`, a *build-controlled*
  runtime call — no data-driven `apply(Mod,F,Args)`. The budget is process-local pdict state,
  unreadable by any other process; nothing widens the codegen's authority.
- **Effect classification (E6/F3).** `Charge` is an **effect barrier**: the optimizer may not
  CSE, reorder, hoist, sink, or dead-code-eliminate it (a charged-then-elided loop would silently
  disable the CPU bound). `ir/effect` (unit 02) already classifies `Charge` as `Effectful`; the
  *only* legal elision is **whole-program** at `Aggressive` under `MeterOff`, where charge sites
  are never inserted in the first place (unit 04's documented trust assumption).
- **`FuelExhausted` is not a WASM trap.** Its message `"fuel exhausted"` is deliberately distinct
  from every spec trap phrase (incl. `"call stack exhausted"`), so the conformance harness can
  never mis-map it. No `.wast` `assert_trap`/`assert_exhaustion` expects it.
- **Determinism is a security property, not just a nicety.** A budget bound that depended on
  scheduling would let a co-tenant influence another instance's trap point; the trace-only cost
  model (§C.2) makes the bound tamper-independent.

---

## Verification — Definition of Done (D8: assert the spec/property, not the impl)

Spec/property-grounded tests in `rt_meter_test.gleam` (each doc comment cites F5 / WebAssembly
spec §7 / the determinism property — never "what the code currently emits"). "Done" = **the suite
passes**, not "it compiles."

1. **Deterministic exhaustion bound.** `reset_fuel()`; `seed_fuel(b)` for a small `b`; charge `1`
   in a loop and assert `charge` raises `FuelExhausted` on **exactly** the spec-derived iteration
   (`consumed > b`), and that **two** runs with the same `b` trap after the **same** count. Assert
   the raised term is `{wasm_trap, fuel_exhausted}` via the test-FFI catch shim
   (`twocore_emit_test_ffi:catch_apply`, as `rt_state_test` does). *(F5 determinism; §7.)*
2. **Within-budget completes; boundary is exact.** `seed_fuel(b)`; charging a total `== b` never
   raises and `fuel_consumed() == b`; the next unit-charge (`b+1 > b`) raises. Pins the strict
   `>` boundary (no off-by-one), i.e. a program that spends its whole budget still returns.
3. **Observe-only sentinel (back-compat).** Without `seed_fuel` (un-seeded budget), `charge`
   **never** raises and `fuel_consumed()` accumulates exactly the summed cost — the Phase-1/2
   behavior the keystone froze; the existing rt_meter/ir_lower fuel tests stay green **unedited**.
4. **`fuel_consumed()` stays observable at exhaustion.** After a `FuelExhausted` raise (caught via
   the shim), `fuel_consumed()` reflects the over-budget total (recorded before the raise).
5. **Re-seed resets (per (re)instantiation).** `seed_fuel(5)`, charge to exhaustion; `seed_fuel(3)`
   again ⇒ a FRESH budget (`fuel_consumed() == 0`, enforcement at `3`) — no leakage from the prior
   cycle. *(WASM instantiation installs fresh state — exec/modules; E1 reset.)*
6. **Two instances meter independently (process isolation).** Seed different budgets and charge in
   **two separate processes**; assert each traps at its **own** bound and neither sees the other's
   consumed/budget (pdict is strictly per-process — the E1 basis for two live instances on one
   node; the full run-ABI coexistence proof is unit 11's).
7. **Interleave with `rt_state` — no key collision (objective).** In one process, interleave
   `seed_fuel`/`charge` with `rt_state.seed`/`global_set`: assert charging never changes a global
   and a global write never changes `fuel_consumed()` — proving `twocore_rt_meter_budget`/`_fuel`
   are hygienic and distinct from `twocore_rt_state` (D3a key hygiene).
8. **`spec_trap_message` distinctness.** `rt_trap.spec_trap_message(FuelExhausted) == "fuel
   exhausted"` and is **not a substring** of any other trap message (guards the harness against a
   mis-map). *(Keystone §C.1.)*

**Handed to the capstone (unit 11), noted in `state.md`:** the **constant-space-with-enforcement**
proof — `sum_to(100000)` under Safe (`MeterFuel`, `default_fuel_budget`) runs to completion in
**constant** process memory (asserting the budget cell did not move the loop back-edge out of tail
position, E1), and the **`FuelExhausted`-through-the-run-ABI** proof — a runaway-loop module
`load → instantiate → invoke` returns `Trapped("{wasm_trap,fuel_exhausted}")`. Both need the full
pipeline (unit 09's seeded `instantiate/0` + the process harness); at this unit the properties rest
on the `rt_meter` precedent and the local seam proof (tests 1–2).

**Gate:** `gleam format --check src test` clean; `gleam build` **zero warnings** (no `todo`, no
unused-var — the new `rt_trap`/`ir` imports are used); `gleam test` stays green (the frozen
observe-only paths unchanged); every new public function/const carries a `///` contract doc
(what / params + ranges / return + raise modes). Update `state.md` with the two capstone hand-offs
and the `fuel_budget` value-channel decision.

---

## What this unit leaves

- **Unit 08 (`ir_lower`)** gates `Charge` insertion on `binding.meter`: `MeterFuel` inserts the
  `fn_cost`/`loop_cost` sites (unchanged); `MeterOff` inserts **none** (zero-overhead Unsafe). The
  cost *values* remain ir_lower's; this unit fixed only their *enforcement* meaning.
- **Unit 09 (`emit_core` + pipeline)** — the **confirmed** seed owner — emits, under `MeterFuel`,
  `seed_fuel(binding.fuel_budget)` as the first `instantiate/0` effect (§D), baking the budget from
  the one `Binding.fuel_budget` channel; adds it to the security-invariant read of the instantiate
  body.
- **Unit 10 (linker/profiles)** adds `profiles.safe_metered(budget)` to lower the per-instance
  budget below `default_fuel_budget` (mirroring `safe_capped`), and wires `profiles.unsafe()`'s
  `MeterOff` end-to-end.
- **Unit 11 (capstone)** runs the constant-space-with-enforcement proof, the runaway-loop
  `FuelExhausted`-through-the-run-ABI proof, and the two-live-instances-on-one-node independence
  proof; calibrates `default_fuel_budget` so the whole Safe corpus/spec suite completes.
</content>
</invoke>
