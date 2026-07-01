# Unit 09 — `emit_core` Unsafe binding + pipeline optimizer wiring + CLI `opt` stage

> **One owner. Wave B. The middle-/back-end mode-application seam.** Depends on
> **FREEZES ONLY** — `«IROPT-IFACE-FROZEN»` (`ir_opt.optimize/2` + `OptLevel`) and
> `«UNSAFE-PROFILE-FROZEN»` (`Binding.opt_level` + `profiles.unsafe()`), both from unit 01.
> It needs those *signatures*, not the real passes (03/04) or the Unsafe runtime (05–08), so
> **it does not serialize behind the optimizer or the runtime units** (overview §3). Read
> [`00-overview.md`](00-overview.md) (F1–F8), [`01-interface-freeze.md`](01-interface-freeze.md)
> (the frozen surface), then [`phase-1/00-overview.md`](../phase-1/00-overview.md) (D1–D10) and
> [`phase-2/00-overview.md`](../phase-2/00-overview.md) (E1–E8).

---

## Context

Three plumbing jobs converge here, all downstream of the keystone freeze and none of them a
new IR node (F7):

1. **`emit_core` must honor the Unsafe `Binding`.** The backend is the binding chokepoint
   (D3b): every runtime reference already resolves to a fixed `call '<binding.*_module>':…`.
   `profiles.unsafe()` keeps the **identical** `*_module` names (keystone §B.4), so every
   **non-instantiate** function body is **posture-agnostic**: `emit_core` emits identical code
   for identical IR and reads none of the policy fields there. The **one documented exception**
   is the synthesized `instantiate/0`, which emit_core owns (§A.4): it bakes the per-instance
   seeds — `rt_meter:seed_fuel(binding.fuel_budget)` under `MeterFuel` and always
   `rt_host:seed_policy(binding.host_policy)` — so it reads `meter`/`fuel_budget`/`host_policy`
   there, and there only. The work is to (a) *document and lock* that split, (b) **emit the
   `instantiate/0` seeds**, and (c) **extend the structural security-invariant test** so `open`
   (`BifOpen`/`HostOpen`) is *proven* to add no ambient authority (D3a) — the same walk that
   guards Safe must pass under the Unsafe binding.

2. **Wire `ir_opt.optimize` into the pipeline driver**, between `ir_lower` and `emit_core`
   (F1), with the level read from `binding.opt_level` (F7). `OptNone` bypasses. The pipeline
   stays a **chain of independently-invokable stages** (decision #5) — the optimizer is one
   more composable `pipeline.gleam` function, not a hidden step baked into `ir_to_core`.

3. **Add an `opt` CLI verb** (`.ir → optimized .ir`) so the optimizer stage is independently
   driveable from the command line (decision #5), plus a `--unsafe` **profile flag** that
   selects `profiles.unsafe()` (else the fail-closed `profiles.safe()`, D4) for the compile
   verbs `run` / `to-core` / `emit` / `opt`.

The load-bearing correctness claim this unit sets up (proven end-to-end by capstone 11, F2/F5):
**for the same source, a metered *function body* under Safe and under Unsafe differs by
*exactly* the charge instrumentation** — because `emit_core` emits identical code for identical
IR in every non-instantiate body, and the only IR difference there is the `Charge` nodes
`ir_lower` inserts under `MeterFuel` and omits under `MeterOff` (unit 08). The synthesized
`instantiate/0` is the one documented exception: it additionally differs by the once-per-instance
seed lines (§A.4). `emit_core` never branches a *body* on the mode.

---

## Deliverables & freeze milestones

**Consumes:** `«IROPT-IFACE-FROZEN»` (`ir_opt.optimize(m, level)`, `OptLevel = OptNone |
Baseline | Aggressive`), `«UNSAFE-PROFILE-FROZEN»` (`Binding.opt_level`, `profiles.unsafe()`,
`profiles.safe()`). Both land green at the freeze with empty pass pipelines, so **`optimize`
is the observable identity at every level** until 03/04 register passes — which is exactly
what lets this unit wire and test the plumbing without the passes existing yet.

**Produces (no downstream freeze — this is application/wiring, not a contract):**

- `pipeline.optimize_ir/2` — the new independently-invokable optimizer stage, threaded into
  `ir_to_core` between `lower_ir` and `emit_core`.
- The `opt` CLI verb + the `--unsafe` profile flag on the compile verbs.
- `emit_core` bodies locked posture-agnostic; `instantiate/0` extended to bake the per-instance
  seeds (`seed_fuel` under `MeterFuel`, `seed_policy` always) — the one documented exception.
- The security-invariant test extended to `profiles.unsafe()` (D3a holds under `open`).

---

## Files owned (single-owner-additive)

- `src/twocore/pipeline.gleam` — **EXTEND.** Add `optimize_ir/2`; thread it into `ir_to_core`.
  (Unit 11c's owner; this is the additive Phase-3 growth of that file.)
- `src/twocore.gleam` — **EXTEND.** Add the `opt` verb, the `--unsafe` flag on `run`/`to-core`/
  `emit`/`opt`, the profile selector, and the usage text.
- `src/twocore/backend/emit_core.gleam` — **EXTEND.** Add the `instantiate/0` per-instance seeds
  (`seed_fuel(binding.fuel_budget)` under `MeterFuel`; always `seed_policy(binding.host_policy)`)
  and the module-doc note that every NON-instantiate body stays posture-agnostic (the seeds are
  the one documented exception).
- `test/twocore/backend/emit_core_security_test.gleam` — **EXTEND.** Add the under-Unsafe D3a
  walk.
- `test/twocore/pipeline_test.gleam` (or a new `test/twocore/pipeline_opt_test.gleam`) and
  `test/twocore/cli_test.gleam` — the new wiring tests (both-profile e2e, charge differential,
  `opt` round-trip).

---

## Depends on (freeze milestones)

| Freeze | From | What you take | Stub against meanwhile |
|---|---|---|---|
| `«IROPT-IFACE-FROZEN»` | 01 | `ir_opt.optimize/2`, `OptLevel`. | Empty pipelines → `optimize == identity`; the wiring + `opt` verb are testable immediately. |
| `«UNSAFE-PROFILE-FROZEN»` | 01 | `Binding.opt_level`, `profiles.unsafe()`, `profiles.safe()`. | `unsafe()` lands green as a tested explicit opt-in (keystone §B.4). |

**Not blocked on:** 03/04 (real passes), 05 (`rt_meter` enforce), 06/07 (passthrough/open
runtime), 08 (`ir_lower` `MeterOff`). The `instantiate/0` seeds emit calls to the seed ABIs
coordinated with 05/07 (`seed_fuel`/`seed_policy`) — emitting the calls needs only those frozen
signatures, not their enforcing bodies (`seed_fuel` is a trivial freeze body until 05;
`seed_policy` defaults deny-all until 07). Their absence otherwise only means the optimizer is
currently identity and the Unsafe runtime posture is not yet realized — the *plumbing* this unit
adds is correct regardless, and capstone 11 proves the full-fidelity differential once they land.

---

## Scope — in / out

**In:** the `optimize_ir` stage + its insertion in `ir_to_core`; the `opt` verb + `--unsafe`
flag; the `emit_core` non-instantiate posture-agnostic lock (doc) + the `instantiate/0`
per-instance seed emission (`seed_fuel`/`seed_policy`, §A.4) + the extended security walk; the
three wiring tests (both-profile e2e, charge differential, `opt` round-trip).

**Out (do not build here):** any optimizer **pass** (03/04); the `MeterOff` charge-skip in
`ir_lower` (08 — this unit *consumes* the resulting IR difference, it does not implement it);
`rt_meter` enforcement + the `seed_fuel`/`seed_policy` function **bodies** (05/07 — this unit
only *emits the calls* to them in `instantiate/0`, against their frozen ABIs);
`StdlibPassthrough`/`BifOpen`/`HostOpen`/`HostWhitelist` runtime bodies (06/07);
`profiles.unsafe()`'s construction (01) and full linker wiring / coexistence
proof (10); the corpus-wide Safe-vs-Unsafe and optimizer-soundness differentials + the
benchmark (11). No new IR node, no `.ir` grammar change (F7).

---

## A. `emit_core` honors the Unsafe `Binding` — bodies stay posture-agnostic, `instantiate/0` seeds

### A.1 Why (nearly) no behavioral change is needed (and why that is the point)

`emit_core.emit_module(module, binding)` reads **only** the `binding.*_module` name fields and
`binding.safe_max_pages` (grounded in the current source: `num_module`, `trap_module`,
`host_module`, `meter_module`, `stdlib_module`, `mem_module`, `table_module`, `state_module`)
when it emits an ordinary **function body**. No non-instantiate body reads any of the policy
fields (`opt_level`, `meter`, `bif_gate`, `stdlib`, `host_policy`, `fuel_budget`). Per keystone
§B.4, `profiles.unsafe()` is `Binding(..safe_default(), mode: Unsafe, opt_level: Aggressive,
meter: MeterOff, …)` — it **overrides the posture but keeps the identical `*_module` names**.
Therefore:

> **Invariant (locked by this unit).** For any IR module `m`, `emit_module(m, profiles.safe())`
> and `emit_module(m, profiles.unsafe())` produce a `CModule` that is **structurally identical
> in every function EXCEPT the synthesized `instantiate/0`**, which differs only by its
> once-per-instance seed lines (§A.4). No *non-instantiate body* observes Safe vs Unsafe.

Safe and Unsafe are **different builds** (B3 monomorphization, unit 10): the linker renames the
Unsafe IR module before emit, so the two artifacts load as **distinct output module atoms**
while sharing the **identical** `twocore@runtime@rt_*` runtime module names. There is **no**
single-`.beam` runtime-dispatch that swaps postures — that model (keeping `Charge` sites and a
hot-path meter flag in one build) is Phase-4-deferred (unit 10 §C). The `Instance`/`Binding`
API still presents coexistence uniformly (*the instance is the unit of policy*, F4), but the
realization is per-profile builds + per-instance seeded runtime policy.

This is what makes the F5 acceptance tractable: "a metered *function body* under Safe and under
Unsafe differs **exactly** by the charge instrumentation" (overview §1) is only true because
`emit_core` is posture-blind **for bodies**. **If a future unit needs a non-instantiate body to
branch on a policy field, that breaks this invariant and the F5 differential — it must go back
to the planner** (see Open questions).

The deliverable is a module-doc paragraph in `emit_core.gleam` stating this, e.g.:

```gleam
//// ## Phase 3 — posture-agnostic BODIES, seeded `instantiate/0` (F4/F6/F7)
////
//// For every NON-instantiate function body, `emit_module` reads ONLY the `binding.*_module`
//// names (+ `safe_max_pages`); it reads NONE of the policy fields
//// (`opt_level`/`meter`/`bif_gate`/`stdlib`/`host_policy`/`fuel_budget`). Because
//// `profiles.unsafe()` keeps the SAME `*_module` names as `safe()`, those bodies are
//// structurally identical under both profiles for the same IR (Safe and Unsafe are distinct
//// B3 builds; the instance is the unit of policy). The optimizer runs BEFORE emit (F1) and the
//// `Charge`-skip lives in `ir_lower` (F5) — so a metered body's Safe/Unsafe `.core` differs
//// only by charge, never by anything emit_core decides. The ONE documented exception is the
//// synthesized `instantiate/0`, which bakes the per-instance seeds:
//// `rt_meter:seed_fuel(binding.fuel_budget)` FIRST when `meter == MeterFuel`, and ALWAYS
//// `rt_host:seed_policy(binding.host_policy)`. Do NOT branch any non-instantiate body on a
//// policy field: that would break the F5 zero-overhead differential.
```

### A.2 `StdlibPassthrough` does not change the emitted target (a constraint this unit relies on)

`emit_call_host` resolves a vetted `own`-stdlib call to `call '<stdlib_module>':'<fn>'(…)` via
`resolve_stdlib` (grounded: `("std","gcd") -> "gcd"`). `StdlibPassthrough` (F6) must be
realized **behind that same call target** — i.e. inside `rt_stdlib` / by which module the
`stdlib_module` field names (units 06/08) — **not** by `emit_core` emitting a different module
(`'erlang':…`, `'lists':…`). Emitting a raw BEAM module here would (i) inject a non-runtime
atom into the D3a call set and (ii) make the `.core` differ under Unsafe by more than charge,
breaking A.1's invariant and the F5 acceptance. This unit therefore emits the stdlib call
identically under both profiles; the emitted module atom is invariably `stdlib_module` and the
own-vs-passthrough choice is a vetted in-`rt_stdlib` shim (**resolved** with units 06/08 — no
longer an open question).

### A.3 The security-invariant test extended to `open` (D3a under Unsafe)

The existing structural test (`emit_core_security_test.gleam`) walks the emitted AST and
asserts, for `instance.safe_default()`: every `CCall` module position is a fixed `Binding`
runtime atom, every function position is a literal atom, and every `CApply` targets a
compile-time-local `FName` (never a data-driven `apply(Mod,F,Args)`). **Extend it to run the
*same* walk under `profiles.unsafe()`**, proving F6's claim — "even `open`, the codegen never
performs a data-driven `apply(Mod,F,Args)` with `Mod` from program data; `open` widens the
*build-controlled* allow-set, it adds no ambient authority" (F6/keystone §B.1):

```gleam
import twocore/runtime/profiles

/// D3a holds under the UNSAFE posture (F6): with `open` BIF gate + `open` host + passthrough
/// stdlib, the emitted module STILL targets only fixed `Binding` runtime atoms with literal
/// function atoms, and every `apply` is a compile-time-local `FName`. "Open" is a runtime
/// gate posture (rt_host/rt_bif bodies), NOT an emit-time capability — emit_core is
/// posture-agnostic (A.1), so the identical no-ambient-authority walk that guards Safe must
/// pass here. Uses the SAME `stateful_module()` fixture (call_indirect + every mem/global/
/// table op + instantiate/0) as the Safe walk.
pub fn no_ambient_authority_under_unsafe_test() {
  let binding = profiles.unsafe()
  let assert Ok(m) = emit_core.emit_module(stateful_module(), binding)
  assert_calls_are_runtime(m, binding)
  // and re-run the CApply walk of `call_indirect_dispatch_is_ambient_safe_test` under `binding`.
}
```

Because `runtime_modules(profiles.unsafe())` is the same fixed set as under Safe (identical
`*_module` names), the walk is definitional — and that *is* the proof: an Unsafe caller cannot
coax `emit_core` into a program-driven module dispatch, because the module names are
build-controlled `Binding` fields, not program data. (Spec/authority basis: high-level §5
codegen security invariants; D3a; WASM spec §7 *Embedding* — the embedder chooses the host
surface at build time, never the module.) The Unsafe `instantiate/0` seed lines (§A.4) are
themselves calls to fixed runtime atoms (`meter_module`/`host_module`), so they pass this same
walk under `profiles.unsafe()` unchanged.

### A.4 The one documented exception — `instantiate/0` bakes the per-instance seeds

`emit_core` synthesizes the module's `instantiate/0` entry, and is the **sole owner** of emitting
the per-instance seeds — correcting keystone §C.2's "(unit 08)" attribution: `ir_lower` (08)
cannot emit `instantiate/0`, so the seeds are emit_core's (09). This is the **one** place
emit_core reads a policy field, and it is confined to
`instantiate/0`; every ordinary body stays posture-blind (§A.1). Two seed effects, mirroring the
run-ABI contracts frozen by units 05/07:

- **When `binding.meter == MeterFuel`**, emit `call 'twocore@runtime@rt_meter':'seed_fuel'(B)` as
  the **first** effect of `instantiate/0` — before any element/data segment, `start`, or export —
  where `B` is `binding.fuel_budget` baked as a Core Erlang integer literal (unit 05 §D). The
  fail-closed CPU bound is thus armed before the first `charge`, so **no `MeterFuel` artifact runs
  unbounded by default** (D4). When `binding.meter == MeterOff` emit **no** `seed_fuel` (there are
  no `Charge` sites to bound — unit 08).
- **Always** emit `call 'twocore@runtime@rt_host':'seed_policy'(P)`, where `P` is
  `binding.host_policy` baked as a Core Erlang literal (unit 07 §D). Safe seeds `host_deny_all`
  (fail-closed), Unsafe seeds `host_open`; an unseeded policy already defaults deny-all, so seeding
  always keeps the boundary explicit.

These seed lines are the **only** difference between `emit_module(m, safe())` and
`emit_module(m, unsafe())` beyond the `Charge` nodes already differing in the incoming IR. They
run **once per instance** at instantiation — never on a hot path — so F5 zero-overhead on metered
*functions* is untouched (the seed is instantiate-only). Both seeds are `let`-sequenced (non-DCE,
E1 ordered effects) and both target fixed `Binding` runtime atoms (`meter_module`/`host_module`),
so they pass the §A.3 no-ambient-authority walk unchanged.

---

## B. Wire `ir_opt.optimize` into the pipeline driver (F1/F7)

### B.1 The new stage — `optimize_ir/2`

`ir_opt` is the shared middle-end stage **between `ir_lower` and `emit_core`** (F1). Add it to
`pipeline.gleam` as a first-class, independently-invokable stage (decision #5), mirroring the
existing `lower_ir`/`ir_to_core`/`core_to_beam` composable drivers:

```gleam
import twocore/middle/ir_opt

/// Run the shared IR→IR optimizer over `m` at the level carried by the profile (F1/F7).
///
/// The optimizer sits BETWEEN `ir_lower` and `emit_core`: `source_to_ir → ir_lower →
/// optimize_ir → emit_core`. The level is read from `binding.opt_level` (F7 — the profile is
/// the single source of truth), so `profiles.safe()` optimizes at `Baseline` (trust-neutral
/// passes) and `profiles.unsafe()` at `Aggressive` (baseline + Unsafe-only passes).
///
/// - `m`: the IR module (post-`ir_lower`, so `Charge` metering nodes are already present under
///   `MeterFuel` and absent under `MeterOff` — the optimizer must PRESERVE the charges it sees,
///   F3, and only the `Aggressive` charge-elision pass may remove them, unit 04).
/// - `binding`: the build-time profile; only `binding.opt_level` is read here.
/// - Return: a semantics-preserving rewrite of `m` (F2). `OptNone` is the identity, so a
///   profile with `opt_level: OptNone` BYPASSES the optimizer (the Phase-1/2 build path / F2
///   differential baseline). TOTAL — `ir_opt.optimize` never fails, so this returns a bare
///   `ir.Module`, not a `Result` (no new `PipelineError` variant, F7).
pub fn optimize_ir(m: ir.Module, binding: Binding) -> ir.Module {
  ir_opt.optimize(m, binding.opt_level)
}
```

`OptNone` is the bypass *by construction*: `ir_opt.pipeline(OptNone) == []` forever (keystone
§A.2), so `optimize(m, OptNone) == m`. Calling `optimize` unconditionally is therefore the
clean encoding of "None ⇒ bypass" — no special-case branch in the driver, and the single
`optimize(m, binding.opt_level)` call site (keystone §B.3) stays the one place the level is
read.

### B.2 Threading it into `ir_to_core`

`ir_to_core` currently runs `lower_ir` then `emit_module`. Insert `optimize_ir` between them —
the F1 order — leaving the rest untouched:

```gleam
/// IR → `.core` text: `ir_lower` (Safe policy pass / metering) → `ir_opt` (level from
/// `binding.opt_level`, F1) → `emit_core`, printed by `core_printer`. The canonical
/// "IR → backend" path the CLI's `to-core`/`run` use, now with the optimizer in-chain.
pub fn ir_to_core(m: ir.Module, binding: Binding) -> Result(String, PipelineError) {
  case lower_ir(m, binding) {
    Error(e) -> Error(e)
    Ok(lowered) -> {
      let optimized = optimize_ir(lowered, binding)
      case emit_core.emit_module(optimized, binding) {
        Error(e) -> Error(EmitFailed(e))
        Ok(cmod) -> Ok(core_printer.print_module(cmod))
      }
    }
  }
}
```

`run_source` is unchanged: it already delegates to `ir_to_core`, so the optimizer rides through
the end-to-end path automatically. The stage chain stays fully decomposed — `source_to_ir`,
`lower_ir`, `optimize_ir`, `ir_to_core`, `core_to_beam`, `instantiate`, `invoke_instance` are
each callable in isolation (decision #5), so a caller can stop after `optimize_ir` and inspect
the optimized IR (which the `opt` verb, §C, does).

### B.3 Ordering rationale (metering before optimization)

Placing `ir_opt` **after** `ir_lower` is deliberate and effect-safe (F3):

- `ir_lower(Safe)` inserts `Charge` nodes; the optimizer then sees them and, because
  `effect.is_effectful_node(Charge) == True` (E6/F3), must **not** dead-code-eliminate or
  reorder them under `Baseline`. The only licensed remover is unit 04's `Aggressive`
  charge-elision pass, and it fires **only** at `opt_level: Aggressive`.
- Under Unsafe, `ir_lower(MeterOff)` (unit 08) inserts **no** `Charge` at all — so the
  `Aggressive` charge-elision pass has nothing to elide (belt-and-suspenders). The zero-overhead
  property (F5) is therefore delivered by *absence at insertion*, not by *removal at optimize*;
  the pipeline just carries it through.
- Running the optimizer over the *lowered* IR (resolved stdlib calls, metering, allowlist
  gating already applied) means every future frontend's post-lowering IR is optimized uniformly
  (F1 frontend-agnostic) with no re-analysis of capability policy.

---

## C. The `opt` CLI verb + the `--unsafe` profile flag (decision #5)

### C.1 `opt <in.ir> [--unsafe]`

Expose the optimizer stage independently (decision #5), exactly as `ir-lower`/`emit` expose
their stages: parse `.ir` → `optimize_ir` at the selected profile's level → print `.ir`.

```gleam
/// `opt <in.ir> [--unsafe]` — parse `.ir` (unit 02) → run the optimizer stage ALONE at the
/// selected profile's `opt_level` (Safe ⇒ Baseline, Unsafe ⇒ Aggressive) → print the
/// optimized `.ir`. The independently-driveable optimizer stage (decision #5). The output is
/// always valid `.ir` that re-parses (F2 — the optimizer produces well-formed IR); at
/// `OptNone`/freeze it is byte-identical to the input.
fn cmd_opt(path: String, binding: Binding) -> Result(String, String) {
  use text <- result.try(read_text(path))
  case pipeline.parse_ir(text) {
    Error(e) -> Error("parse .ir: " <> string.inspect(e))
    Ok(m) -> Ok(ir_printer.print_module(pipeline.optimize_ir(m, binding)))
  }
}
```

### C.2 The `--unsafe` flag and the profile selector

The default profile is `profiles.safe()` (fail-closed, D4/F4) — an Unsafe posture is only ever
reachable via an **explicit** `--unsafe` flag, never by omission. Add the flag to the compile
verbs `run`, `to-core`, `emit`, and `opt`; dispatch a `Binding` down to the command handlers
(which currently hard-code `profiles.safe()`):

```gleam
// in `run/1`, before the existing (Safe) arms — Gleam matches top-to-bottom:
["opt", "--unsafe", path] -> cmd_opt(path, profiles.unsafe())
["opt", path]             -> cmd_opt(path, profiles.safe())

["run", "--unsafe", path, export, ..args] -> cmd_run(path, export, args, profiles.unsafe())
["run", path, export, ..args]             -> cmd_run(path, export, args, profiles.safe())

["to-core", "--unsafe", path] -> cmd_to_core(path, profiles.unsafe())
["to-core", path]             -> cmd_to_core(path, profiles.safe())

["emit", "--unsafe", path] -> cmd_emit(path, profiles.unsafe())
["emit", path]             -> cmd_emit(path, profiles.safe())
```

`cmd_run`/`cmd_to_core`/`cmd_emit` gain a trailing `binding: Binding` parameter and drop the
hard-coded `profiles.safe()`. Notes:

- **`to-beam` / `build` take no profile flag** — they compile already-emitted `.core` → `.beam`
  and carry no `Binding` (document this in usage). The profile is chosen upstream, at the
  `.ir → .core` stage (`emit`/`to-core`) or the whole `run`.
- **`emit --unsafe` demonstrates body posture-agnosticism (A.1):** `emit` runs `emit_core`
  *alone* (no `ir_lower`, no optimizer), so its `.core` is **identical** with or without
  `--unsafe` for the same `.ir` in every function body — differing **only** in `instantiate/0`'s
  seed lines (`seed_policy` literal Safe-vs-Unsafe; `seed_fuel` present under Safe, absent under
  Unsafe). That is the CLI-visible proof that bodies are posture-blind.
- **`to-core --unsafe` demonstrates the charge differential (F5):** `to-core` runs
  `ir_lower → optimize → emit`, so its `.core` under `--unsafe` differs from Safe by exactly
  the `charge` lines **plus `instantiate/0`'s once-per-instance seed lines** (§A.4) — nothing
  else (once unit 08's `MeterOff` lands; today the Unsafe arm of `ir_lower` already returns the
  module un-metered, so the differential is already visible).

Add the verbs to `usage()`:

```
  gleam run -- opt      <in.ir> [--unsafe]              optimizer stage → .ir (Safe=Baseline, Unsafe=Aggressive)
  ... --unsafe on run/to-core/emit selects profiles.unsafe() (default: safe, fail-closed)
```

---

## Effect / soundness / security note

- **No ambient authority survives the Unsafe posture (D3a).** The extended security walk (§A.3)
  proves it structurally under `profiles.unsafe()`: `BifOpen`/`HostOpen`/`StdlibPassthrough`
  widen a *build-controlled* allow-set realized in the runtime module bodies (06/07), never a
  data-driven `apply(Mod,F,Args)` at the emit site. `emit_core` targets the fixed `Binding`
  atoms identically under both profiles.
- **Fail-closed default (D4/F4).** Every CLI compile verb defaults to `profiles.safe()`; Unsafe
  is a single explicit `--unsafe` token. There is no code path that yields an Unsafe binding by
  omission — matching the keystone's tested "no accidental Unsafe" property.
- **The optimizer never changes an observable answer (F2), and effects are its barrier (F3).**
  The pipeline runs `ir_opt` over already-metered IR so charges are preserved by the effect
  classifier; `OptNone` is a proven identity; the semantics-preserving differential over the
  corpus is capstone 11's DoD. This unit only guarantees the *wiring* is order-correct and
  bypass-correct.
- **F5 zero-overhead is a composition, not an emit decision.** `emit_core` bodies are
  posture-blind (A.1); the charge delta is `ir_lower`'s (F5/unit 08). The only backend
  policy-read is `instantiate/0`'s once-per-instance seed (§A.4), off every hot path — so
  "a metered body differs exactly by charge" stays a clean, testable invariant.

---

## Verification — Definition of Done (D8)

Tests assert **spec/decision behavior**, not whatever the code emits (no change-detector
tests). "Done" = the suite below passes, not "it compiles."

1. **The pipeline runs end-to-end under BOTH profiles.** A pure module (e.g. hand-built `add`
   IR, or the `add.wasm` fixture) compiled+invoked through `pipeline.run_source(_,
   profiles.safe(), …)` and `run_source(_, profiles.unsafe(), …)` returns the **same
   spec-correct result** (`add(2,3) == 5`). Proves the optimizer is threaded and both bindings
   drive a working chain (F2 identity at freeze; the Unsafe binding names working runtime
   modules). Self-contained at unit-09 landing.
2. **Unsafe emit differs from Safe emit for a metered fn by exactly the charge instrumentation +
   the `instantiate/0` seeds (F5).** Take a module with a metered function (a `Loop` and a body →
   `ir_lower(Safe)` inserts `Charge`). Compare `pipeline.ir_to_core(m, profiles.safe())` and
   `ir_to_core(m, profiles.unsafe())`; assert the two `.core` texts are **line-for-line identical
   except for (i) the `call 'twocore@runtime@rt_meter':'charge'(_)` lines** (present under Safe,
   absent under Unsafe) **and (ii) the once-per-instance `instantiate/0` seed lines** —
   `seed_fuel` present under Safe / absent under Unsafe, and the `seed_policy` literal
   `host_deny_all` (Safe) vs `host_open` (Unsafe) (§A.4). Every *body* is byte-identical. Cite
   F5 / overview §1 ("differ exactly by the charge instrumentation") with the instantiate-seed
   exception. Green when unit 08's `MeterOff` lands; today it already passes because `ir_lower`'s
   `mode: Unsafe` arm returns the module un-metered — note the transition in a comment. Back it
   with a self-contained emit-level golden: for a single `Charge(c, body)` IR node, `emit_module`
   emits exactly one `rt_meter:charge` call wrapping `body`, and for the same IR without the
   `Charge` wrapper, **zero** charge calls — proving emit is faithful and body-posture-blind.
3. **The `opt` CLI round-trips (decision #5).** `twocore.run(["opt", file])` on a valid `.ir`
   file yields text that **re-parses** to a well-formed `ir.Module` (F2 — the optimizer emits
   valid IR), and at the freeze/`OptNone` level equals the input module (compared by bit
   pattern per D7, so float payloads are exact). Also assert `run(["opt", "--unsafe", file])`
   succeeds and re-parses. (Once real passes land, the equality relaxes to
   *semantics-preserving*, owned by 03/04/11; the round-trip-validity assertion stays.)
4. **D3a under Unsafe (F6).** `no_ambient_authority_under_unsafe_test` (§A.3): the security walk
   passes under `profiles.unsafe()` — every `CCall` targets a fixed `Binding` runtime atom with
   a literal function atom; every `CApply` is a compile-time-local `FName`. Self-contained.
5. **`emit --unsafe` bodies are posture-agnostic (A.1).** `run(["emit", file])` and `run(["emit",
   "--unsafe", file])` produce `.core` that is **identical in every function body** for the same
   `.ir`, differing **only** in `instantiate/0`'s seed lines (§A.4). emit_core reads a policy
   field (`meter`/`fuel_budget`/`host_policy`) only to synthesize those seeds.
6. **No regression.** `gleam format --check src test` clean; `gleam build` **zero warnings**;
   `gleam test` stays green (≥509, conformance 1740/1359/0). The existing Safe security test,
   `profiles_test`, and `ir_lower_test` are untouched-and-green (they key off `mode`, which is
   unchanged here). Every new public/private function carries a doc comment stating its
   contract (D8).

**Proof of goal:** tests 1–3 are the unit's proof — the optimizer is a wired, bypass-correct,
independently-invokable stage; the CLI can drive it and select the profile; and the Safe/Unsafe
`.core` bodies differ by exactly the metering (with the `instantiate/0` seeds the one documented
exception, §A.4), the backend proven body-posture-blind (4–5).

---

## Open questions (for the planner / cross-unit sync)

- **Does `StdlibPassthrough` change the emitted call *target*?** **Resolved — no (decision-5).**
  Passthrough is realized behind the same `stdlib_module` call — a vetted in-`rt_stdlib` shim — so
  the emitted module atom is invariably `stdlib_module`, the F5 "differ exactly by charge"
  differential and the D3a `runtime_modules` set hold permanently, and unit 06's `'erlang':…`
  emit-target option is struck (units 06/08 constrained to match).
- **Should any *non-instantiate body* branch codegen on a policy field?** **No (A.1)** — if a
  later unit needs it, it breaks the F5 differential and must return to the planner. The **only**
  sanctioned policy-field read is `instantiate/0`'s per-instance seeds (§A.4, decision-2).

---

## What this unit leaves

- **Unit 03/04:** the moment passes register into `ir_opt.pipeline/1`, they flow through
  `optimize_ir` → `ir_to_core` → `run`/`to-core`/`opt` with **no** further pipeline change — the
  seam is done. Their per-pass differential (F2) is theirs; the wiring is here.
- **Unit 08:** `ir_lower(MeterOff)` turns test 2's differential from "already visible via the
  `mode: Unsafe` pass-through arm" into "keyed off `binding.meter`" — same assertion, refined
  source. This unit's charge-differential test is its integration check.
- **Unit 10:** `profiles.unsafe()` full wiring + Safe/Unsafe coexistence on one node; the `opt`
  verb and `--unsafe` flag are the CLI surface it hardens.
- **Unit 11 (capstone):** the corpus-wide Safe-vs-Unsafe differential (identical results/traps)
  and the optimizer-soundness differential run *through* the pipeline this unit assembled; the
  `opt` verb is a fixture-generation and inspection tool for that harness.
