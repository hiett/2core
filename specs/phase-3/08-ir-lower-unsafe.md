# Unit 08 — `ir_lower` Unsafe policy application (F4/F5/F6)

> **One owner. Extends `src/twocore/middle/ir_lower.gleam` (single-owner, additive).
> Wave — parallels 05 (`rt_meter`), 06 (passthrough + open bif), 07 (`rt_host`), 09
> (`emit_core`) once the keystone freezes the `Binding` policy fields.** Read
> [`00-overview.md`](00-overview.md) (F1–F8) and [`01-interface-freeze.md`](01-interface-freeze.md)
> first, then the Phase-1/2 overviews (D1–D10, E1–E8). Freeze deps: **`«UNSAFE-PROFILE-FROZEN»`**
> (the `Binding` policy fields + the five policy enums) and **`«METER-ENFORCE-FROZEN»`** (the
> `MeterMode` semantics). This unit makes the *one* middle-end policy pass **posture-aware** so
> the Unsafe profile is realised at IR-lowering time — without touching a single line of Safe
> behaviour.

---

## Context

`ir_lower.lower/2` is the platform's **only** middle-end policy pass (high-level §4 `M3`). It
runs *after* the frontend lowering (`frontend/wasm/lower.gleam`) and *before* the backend
(`emit_core`), and today it does two build-time, fail-closed jobs (Phase-1 unit 11a): a
**`CallHost` capability gate** (a `"std"` call is resolved against the `own` surface and gated
through the `rt_bif` allowlist; a declared host import is left to run-time deny; anything else is
rejected `ForbiddenHost`) and **metering insertion** (every function body wrapped in
`Charge(fn_cost, body)`, every `Loop` body in `Charge(loop_cost, body)`).

The pass currently switches on the coarse `binding.mode` (`Safe` runs the full pass; `Unsafe`
returns the module unchanged — a lock-now placeholder, never reachable because Phase-1/2
`profiles` cannot produce an `Unsafe` binding). Phase 3 makes `Unsafe` a **real** profile (F4),
so this branch can no longer be a stub. Per F7 the profile carries the policy in **explicit
`Binding` fields**; this unit rewires `ir_lower` to read those fields instead of the coarse
`mode`, applying three Unsafe levers — **no metering** (F5), **passthrough stdlib resolution**
(F6), and the **open BIF gate** (F6) — while keeping the **Safe posture byte-identical to
Phase-2**.

Two things this unit does **not** touch: it adds **no** IR node types and **no** `.ir` grammar
(F7 — the same `Charge`/`CallHost` nodes, differently *inserted* and *resolved*), and it does
**not** import any runtime **impl** module (`rt_meter`/`rt_stdlib`/`rt_host`) — those are called
by *generated* code at run time, never by this build-time pass (D3a). It reads `ir.gleam`, the
`Binding` type, and the build-time `rt_bif` gate only.

## Goal

After this unit, `ir_lower.lower(module, binding)` realises **both** profiles from one code path
keyed on the frozen policy fields:

- **Safe** (`meter: MeterFuel`, `stdlib: StdlibOwn`, `bif_gate: BifAllowlist`) reproduces the
  Phase-2 output **exactly** — same `Charge` sites, same allowlist rejection, same `own`
  resolution. Zero observable change; the 509-test suite and the conformance image stay green.
- **Unsafe** (`meter: MeterOff`, `stdlib: StdlibPassthrough`, `bif_gate: BifOpen`) emits **no
  `Charge` nodes at all** (F5 zero-overhead), resolves shared stdlib calls to their
  in-`stdlib_module` shims (the **same** module atom as `own`, F6), and admits the resolved
  build-controlled BIF target without an allowlist check (F6) — with the corpus producing
  **byte-identical results** (F2).

## Files owned

- `src/twocore/middle/ir_lower.gleam` — **EXTEND** (single owner, additive).
- `test/twocore/middle/ir_lower_test.gleam` — the unit's tests (mirrors `src/`).

No freeze/publish-day-1 stub: `ir_lower` is downstream of two keystone freezes and publishes
nothing others *block* on. It does leave one **seam** for unit 09 (§C.3).

## Deliverables & freeze milestones

**Consumes** (from unit 01, already frozen and GREEN):

- `«UNSAFE-PROFILE-FROZEN»` — the five policy enums + `Binding` policy fields
  ([`01`](01-interface-freeze.md) §B). This unit reads `binding.meter`/`stdlib`/`bif_gate`; it
  does **not** read `opt_level` (unit 09's driver) or `host_policy` (unit 07's `rt_host` — §A.3).
- `«METER-ENFORCE-FROZEN»` — the `MeterMode` contract ([`01`](01-interface-freeze.md) §C): the
  *decision* that `MeterOff` inserts **no** `Charge` is frozen there, **implemented here** (the
  keystone flags "enforced in unit 08").

**Coordinates with** unit 06 (`rt_stdlib` passthrough + `rt_bif` open): the passthrough surface
(§C) is pinned with unit 06 and cross-checked so the two cannot drift, exactly as the `own`
surface is cross-checked against `rt_bif.allowlist()` today.

**Produces** — nothing downstream *freezes* on, but §C.3 records the resolution seam `emit_core`
(unit 09) consumes so Safe/Unsafe emission and this gate cannot disagree.

---

## A. The seam — the profile reaches `ir_lower` through `Binding`, not `mode` (F7)

### A.1 Read the policy fields; retire the `mode` branch

Today `lower/2` opens with `case binding.mode { Unsafe -> Ok(module); Safe -> …run… }`. Under F7
the *individual* policy fields — not the coarse `mode` label — drive the middle-end. Replace the
`mode` dispatch with a single unconditional pass that reads the fields:

```gleam
import twocore/runtime/instance.{
  type Binding, BifAllowlist, BifOpen, MeterFuel, MeterOff, StdlibOwn,
  StdlibPassthrough,
}

/// Apply the build-time capability/stdlib/metering POLICY to `module`, returning the
/// rewritten module or the FIRST policy violation. Total — never panics.
///
/// Posture is read from `binding`'s Phase-3 policy fields (F7), NOT from `binding.mode`:
/// - `binding.meter`   — `MeterFuel` inserts `Charge` (Phase-2 cost model); `MeterOff` inserts
///   NONE (F5 zero-overhead — the emitted `.core` has no charge calls).
/// - `binding.stdlib`  — BOTH postures resolve shared calls to `stdlib_module` (F6); the emitted
///   module atom is invariably `stdlib_module`. `StdlibPassthrough` only selects a vetted
///   in-`rt_stdlib` shim (which may call a faster BIF); it NEVER emits a raw `'erlang':…` target.
/// - `binding.bif_gate`— `BifAllowlist` rejects a resolved target off the `rt_bif` allowlist
///   (fail-closed); `BifOpen` admits any build-controlled resolved target (F6).
///
/// The `CallHost` provenance gate (`ForbiddenHost` for an undeclared capability) is applied
/// under EVERY posture — it is a well-formedness check, independent of `host_policy` (§A.3).
pub fn lower(module: Module, binding: Binding) -> Result(Module, LowerError) {
  let imports = import_set(module)
  case list.try_map(module.functions, lower_function(_, binding, imports)) {
    Error(e) -> Error(e)
    Ok(fns) -> Ok(ir.Module(..module, functions: fns))
  }
}
```

**Safe stays byte-identical.** With the Safe posture (`MeterFuel`/`StdlibOwn`/`BifAllowlist`) the
three field switches below take exactly their Phase-2 arms, so the rewritten module is
*structurally identical* to what Phase-2 produced — the correct DoD is a differential
(`lower(m, safe()) == lower_phase2(m)`), not "it compiles" (§Verification). `binding.mode`
remains on the record for other consumers (the linker's coexistence dispatch, unit 10; audit),
but `ir_lower` no longer branches on it.

### A.2 The Unsafe `Binding` is a genuine input now

The freeze test constructs `profiles.unsafe()` = `Binding(..safe_default(), mode: Unsafe,
opt_level: Aggressive, meter: MeterOff, bif_gate: BifOpen, stdlib: StdlibPassthrough,
host_policy: HostOpen)` ([`01`](01-interface-freeze.md) §B.4). This unit is the first middle-end
consumer to act on `meter`/`stdlib`/`bif_gate`; the pass must be exercised with a **real**
`profiles.unsafe()` binding, not a hand-hacked one.

### A.3 Boundary — `host_policy` is **not** this pass's lever

The mandate scopes unit 08 to metering, stdlib, and the BIF gate. `host_policy`
(`HostDenyAll`/`HostWhitelist`/`HostOpen`) is a **run-time** decision made by `rt_host` (unit
07), reached by generated code — not a build-time rewrite. `ir_lower`'s build-time `CallHost`
handling is unchanged in structure and **independent** of `host_policy`:

- A **declared** host import (`(cap, name) ∈ module.imports`, non-stdlib capability) is left as-is
  and denied/permitted **at run time** by `rt_host` according to `host_policy`. `ir_lower` does
  not pre-judge it.
- An **undeclared** non-stdlib capability has no provenance and is rejected here with
  `ForbiddenHost` under **every** posture — a malformed `CallHost` is malformed whether the host
  is deny-all or open. This keeps the fail-closed provenance invariant even under Unsafe: `open`
  widens *declared* host access at run time, it does not license calls the module never imported.

> **Spec anchor.** Imports are named `(module, name)` pairs the module explicitly declares
> ([WASM spec §2.5.11 Imports](https://webassembly.github.io/spec/core/syntax/modules.html#imports);
> instantiation resolves them, §4.5). `ir_lower`'s provenance gate mirrors that: a capability with
> no declared import is not a well-formed host reference, so it is rejected structurally,
> regardless of the run-time host posture.

---

## B. Metering application (F5) — `MeterOff` inserts zero `Charge`; `MeterFuel` = Phase-2

### B.1 Gate every insertion site on `binding.meter`

`Charge` is inserted at exactly two sites (Phase-1 unit 11a): once per function body, once per
`Loop` body. Both become conditional on `binding.meter`:

```gleam
/// Lower one function: gate its `CallHost`s and meter its loop bodies, then — under
/// `MeterFuel` — wrap the whole rewritten body in `Charge(fn_cost, _)` so each call meters
/// once on entry. Under `MeterOff` NO wrapping `Charge` is emitted (F5).
fn lower_function(f, binding, imports) -> Result(Function, LowerError) {
  case lower_expr(f.body, binding, imports) {
    Error(e) -> Error(e)
    Ok(body) ->
      case binding.meter {
        MeterFuel -> Ok(ir.Function(..f, body: ir.Charge(fn_cost, body)))
        MeterOff -> Ok(ir.Function(..f, body:))
      }
  }
}

// …in lower_expr, the Loop arm:
ir.Loop(label, params, result, body) ->
  case lower_expr(body, binding, imports) {
    Error(e) -> Error(e)
    Ok(body2) ->
      case binding.meter {
        MeterFuel -> Ok(ir.Loop(label, params, result, ir.Charge(loop_cost, body2)))
        MeterOff -> Ok(ir.Loop(label, params, result, body2))
      }
  }
```

The cost values (`fn_cost`, `loop_cost`) are unchanged — the Phase-2 cost model owns the
*magnitudes*, and unit 05 (`rt_meter` enforce) refines the budget/model. This unit only decides
*whether* a `Charge` node exists.

### B.2 Zero-overhead is *absence*, not a no-op (F5)

`MeterOff` is **not** "insert `Charge(0, …)`" — it inserts **no `Charge` node at all**. So under
Unsafe `emit_core` never sees a `Charge`, never emits `let _ = rt_meter:charge(c) in …`, and the
generated `.core` has literally no charge call sites. This is exactly what F2's Safe-vs-Unsafe
differential proves: the `.core` for a metered function under Safe and under Unsafe **differ by
precisely the charge instrumentation** and nothing else. There is likewise no `seed_fuel` call
under Unsafe (no budget to seed).

### B.3 Constant space + preemption are untouched either way

Under `MeterFuel` the loop `Charge` sits *inside* the `Loop` body (as in Phase-2) and lowers to
`let _ = rt_meter:charge(c) in body` — it neither changes results nor moves the back-edge out of
tail position, so the constant-space, preemptible tail-`apply` loop template (E1/§9.2) survives
metering. Under `MeterOff` the body is strictly smaller (one fewer wrapper), so tail position is
trivially preserved. Neither posture threads fuel through generated signatures — the budget lives
in the instance process (`«METER-ENFORCE-FROZEN»` §C.2), so the back-edge is identical in both.

> **Spec anchor.** Fuel is **not** a WebAssembly-observable quantity — no `.wasm` instruction
> reads or writes it, and no `assert_return`/`assert_trap` depends on it. Metering is an
> **embedder** resource bound ([WASM spec appendix §A.7 Embedding](https://webassembly.github.io/spec/core/appendix/embedding.html);
> the suite's `assert_exhaustion` is the only place the spec acknowledges resource limits).
> Eliding `Charge` under `MeterOff` is therefore semantics-preserving by construction — it removes
> a policy overlay, never a WASM effect (F3: `Charge` is effectful *for the optimizer's* barrier
> purposes, but its *result-observability* is `Nil`, so its presence/absence cannot change a
> corpus answer).

---

## C. Stdlib passthrough resolution (F6) — same triple, same module, in-module shim

### C.1 Resolve the `own`-stdlib capability posture-aware

A `CallHost("std", name, args)` names a *shared* stdlib function by its IR name. Today `ir_lower`
resolves it to a single `own` target (`binding.stdlib_module` + the `own` fn name). Phase 3 makes
resolution read `binding.stdlib` — the **same `("std", name)` triple, resolved to the same
`binding.stdlib_module`** under both postures; `StdlibPassthrough` only re-points the *function*
to a vetted in-`rt_stdlib` shim (which internally may call a faster BIF), never to a raw BEAM
module (F6). The emitted module atom is invariably `stdlib_module` (a `twocore@runtime@rt_*`
module in the D3a runtime set), so the F5 differential and the D3a structural guard hold
permanently:

```gleam
/// Resolve a shared-stdlib IR `name` to its concrete `module:function`, posture-aware. The
/// module is ALWAYS `binding.stdlib_module` (a `twocore@runtime@rt_*` module) — never a raw
/// BEAM module — under both postures (F6/D3a).
///
/// - `StdlibOwn`: the vetted `own` implementation — `#(binding.stdlib_module, own_fn)`.
/// - `StdlibPassthrough`: `#(binding.stdlib_module, shim_fn)`, where `shim_fn` is a vetted
///   in-`rt_stdlib` shim that may call a faster BIF (F6). Where a shared function has NO faster
///   BEAM equivalent its shim IS the `own` function itself, so the passthrough target EQUALS the
///   own target byte-for-byte — passthrough is a superset of own, never less capable, and never
///   a different module.
///
/// Returns `Error(Nil)` iff `name` is not on the selected surface (→ `UnknownStdlibFn`).
/// The gate ARITY is taken from the actual `args` at the call site (§C.2), not the surface —
/// the surface supplies only the in-module function name.
fn resolve_stdlib_fn(name: String, binding: Binding) -> Result(#(String, String), Nil) {
  case binding.stdlib {
    StdlibOwn ->
      case list.find(own_stdlib_surface(), fn(e) { e.0 == name }) {
        Ok(#(_ir, fn_name, _arity)) -> Ok(#(binding.stdlib_module, fn_name))
        Error(_) -> Error(Nil)
      }
    StdlibPassthrough ->
      case list.find(passthrough_stdlib_surface(), fn(e) { e.0 == name }) {
        Ok(#(_ir, shim_fn, _arity)) -> Ok(#(binding.stdlib_module, shim_fn))
        Error(_) -> Error(Nil)
      }
  }
}

/// The passthrough surface (F6): `#(ir_name, shim_fn, arity)`, where `shim_fn` names the vetted
/// function INSIDE `stdlib_module` (`rt_stdlib`) — never a raw BEAM module. Pinned WITH unit 06
/// (`rt_stdlib`/`rt_bif`) and cross-checked (§Verification) so the resolution here and the
/// passthrough shims there cannot drift. Each entry MUST be observably identical to its `own`
/// counterpart (F6 differential, owned by unit 06/11) — bit-exact per D5/D7.
///
/// Phase-3 corpus: the only shared function is `gcd`, for which the BEAM has no faster/trusted
/// primitive, so its shim IS the `own` `rt_stdlib:gcd/2` itself — the mechanism is exercised
/// (zero active routes, per the honest-scope decision) while the corpus stays byte-identical.
/// Unit 06 adds BIF-backed entries (e.g. a future `abs` whose shim `rt_stdlib:abs` internally
/// calls `erlang:abs/1`) whose *implementation* differs from own — but whose emitted target is
/// still `stdlib_module`, never `'erlang':…`.
fn passthrough_stdlib_surface() -> List(#(String, String, Int)) {
  [#("gcd", "gcd", 2)]
}
```

### C.2 The `CallHost` node is **not** rewritten (F7)

Consistent with the frozen architecture, `ir_lower` does **not** mutate the `CallHost` node — it
stays `CallHost("std", name, args)`. Resolution produces the *target* used (a) here for the gate
(§D) and (b) by `emit_core` for the actual `call '<module>':'<fn>'(Args…)`. No new IR node is
introduced (F7); the passthrough is a change of *resolved target*, not of *IR shape*. This
preserves the Phase-1 invariant that the mechanical stdlib-vs-host routing is `emit_core`'s
(`resolve_stdlib`), and this pass is the *policy* that decides which resolved targets are
*permitted*.

### C.3 The seam for `emit_core` (unit 09) — one source of truth

Because the node is not rewritten, `emit_core` must resolve the *same* target this gate resolved,
or Safe/Unsafe emission and this gate could disagree (emit the `own` target while the gate
approved passthrough, or vice-versa). Two acceptable realisations, both keeping a single source of
truth — unit 09 picks:

1. **Preferred:** `emit_core` calls `ir_lower.resolve_stdlib_fn(name, binding)` (make it `pub`)
   for its emission target, so there is *one* resolver.
2. **Aligned duplication:** `emit_core` keeps its own `resolve_stdlib` but reads `binding.stdlib`
   the same way, and the **anti-drift cross-check** (§Verification) fails the build if the two
   surfaces diverge — exactly the discipline already in force for the `own` surface vs
   `rt_bif.allowlist()`.

`resolved_stdlib_targets/1` (the existing audit hook) becomes posture-aware so the cross-check
covers both surfaces:

```gleam
/// The concrete `rt_bif` targets this pass resolves its shared-stdlib surface to, under
/// `binding` — posture-aware. Every target's module is `binding.stdlib_module` (a
/// `twocore@runtime@rt_*` module), under BOTH postures. Exposed for the anti-drift cross-check
/// (§Verification):
/// - `StdlibOwn`   ⇒ the `own` targets (must equal `rt_bif.allowlist()`).
/// - `StdlibPassthrough` ⇒ the passthrough targets (must equal unit 06's published passthrough
///   surface — all `stdlib_module` targets; unit 06's `'erlang':…` emit-target option is struck).
///   Total.
pub fn resolved_stdlib_targets(binding: Binding) -> List(rt_bif.BifTarget)
```

---

## D. BIF-gate application (F6) — `open` admits, `allowlist` rejects (unchanged fail-closed)

The stdlib branch of `classify_call_host` gates the resolved target on `binding.bif_gate`:

```gleam
// reserved stdlib capability → resolve, then gate on the BIF posture
True ->
  case resolve_stdlib_fn(name, binding) {
    Error(_) -> Error(UnknownStdlibFn(capability, name))
    Ok(#(module, fn_name)) -> {
      let target =
        rt_bif.BifTarget(module:, function: fn_name, arity: list.length(args))
      case binding.bif_gate {
        // Safe: fail-closed allowlist membership (a wrong arity / non-vetted target rejected)
        BifAllowlist ->
          case rt_bif.check(target) {
            Ok(Nil) -> Ok(Nil)
            Error(_) -> Error(BifNotAllowed(name))
          }
        // Unsafe: the allowlist gate is removed — a BUILD-CONTROLLED resolved target is admitted
        BifOpen -> Ok(Nil)
      }
    }
  }
```

- **`BifAllowlist`** is Phase-1/2 behaviour, **untouched**: the resolved `module:fn/arity` must be
  on `rt_bif.allowlist()` or the call is rejected `BifNotAllowed` (fail-closed — a wrong arity or
  a non-vetted `stdlib_module` is caught here, since the gate arity is `list.length(args)`, §C.1).
- **`BifOpen`** removes the allowlist *membership* check only. It does **not** widen *how* a target
  is obtained: the target still comes from `resolve_stdlib_fn`, i.e. a fixed IR-name → fixed
  `module:fn` mapping. The generated code never performs a data-driven `apply(Mod, F, Args)` with
  `Mod`/`F` from program data (D3a) — `open` widens the *build-controlled allow-set*, it adds no
  ambient authority. This is the F6 invariant restated at the enforcement point.

`BifOpen` affects **only** the resolved-stdlib branch. The non-stdlib branch (declared-import vs
`ForbiddenHost`) is unchanged (§A.3) — the open BIF gate is orthogonal to host provenance.

---

## Effect / soundness / security note

- **Safe is byte-identical (the hard gate).** With `MeterFuel`/`StdlibOwn`/`BifAllowlist` every
  new `case` takes its Phase-2 arm; the DoD is a differential `lower(m, safe()) ==
  lower_phase2(m)` over the corpus, never "it compiles". Any Safe divergence is a regression.
- **No ambient authority under the open postures (D3a).** `BifOpen`/`StdlibPassthrough` widen a
  *build-controlled* allow-set; every resolved target is a fixed `module:fn` from a static
  surface, never a program-data module/atom. The freeze only *named* these postures; this unit
  preserves D3a at the enforcement site (unit 09 extends the structural security test for `open`).
- **Fail-closed default survives (D4/D9).** The default profile is Safe; there is no path to an
  Unsafe posture by omission — only `profiles.unsafe()` sets `MeterOff`/`BifOpen`/`StdlibPassthrough`.
  The provenance gate (`ForbiddenHost`) stays fail-closed under every posture (§A.3).
- **`MeterOff` is semantics-preserving.** Fuel is an embedder overlay, not a WASM effect, so its
  absence cannot change a corpus answer (§B.2 spec anchor) — the Unsafe differential (F2) proves it.
- **Passthrough correctness is delegated but pinned.** Observational identity of a passthrough
  target is unit 06/11's differential; this unit only re-points resolution and cross-checks the
  surface so it cannot silently diverge from unit 06 (D5/D7 bit-exact per F6).

---

## Verification (Definition of Done, D8)

Tests assert the **policy/spec behaviour**, not the emitter's byte output (no change-detector
tests). Use hand-written `ir.Module` fixtures for the structural properties and the Safe pipeline
for the differential.

1. **`MeterOff` yields zero `Charge` (F5).** Lower a module (a plain function + a function
   containing a `Loop`) under `profiles.unsafe()`; assert a recursive walk of every function body
   finds **no `ir.Charge` node** — neither the function-entry wrapper nor the per-loop `Charge`.
   (A structural `count_charge(module) == 0` predicate, cited to F5's zero-overhead guarantee.)
2. **`MeterFuel` matches Phase-2 charge insertion.** Lower the same module under `profiles.safe()`;
   assert each function body is wrapped in exactly one `Charge(fn_cost, _)` and each `Loop` body in
   exactly one `Charge(loop_cost, _)` — i.e. `count_charge` equals `#functions + #loops`. This is
   the Phase-2 metering contract re-asserted, not a lock-in of magnitudes.
3. **Passthrough resolution picks the right target (F6).** Assert `resolve_stdlib_fn("gcd",
   profiles.unsafe())` resolves to the passthrough target and `resolve_stdlib_fn("gcd",
   profiles.safe())` to the `own` target; assert `resolved_stdlib_targets(unsafe())` equals unit
   06's published passthrough surface and `resolved_stdlib_targets(safe())` still equals
   `rt_bif.allowlist()` (the extended anti-drift cross-check — proves own/passthrough cannot drift
   from unit 06).
4. **Open admits, allowlist rejects (F6).** With a `CallHost("std", name, args)` whose resolved
   target is **off** the allowlist (e.g. a wrong arity, or a non-vetted `stdlib_module`): under
   `BifAllowlist` (Safe) `lower` returns `Error(BifNotAllowed(_))`; under `BifOpen` (Unsafe) the
   *same* call is admitted (`Ok`, node unchanged). Assert both, citing F6.
5. **D3a preserved under `open`.** Assert that even under `BifOpen` a `CallHost` to an *unknown*
   stdlib name still fails `UnknownStdlibFn` (open does not admit an unresolved target), and an
   *undeclared non-stdlib* capability still fails `ForbiddenHost` (open BIF ≠ open provenance,
   §A.3).
6. **Safe byte-identical differential.** For the Phase-2 acceptance fixtures, assert
   `lower(m, profiles.safe())` equals the module Phase-2 produced (same `Charge` sites, same gate
   outcomes) — the F2/Safe-preservation gate. (The full corpus differential is unit 11's; this is
   the unit-local proof.)
7. **Update the stale Unsafe test.** `unsafe_mode_passthrough_test` asserts the old
   `Binding(..safe_default(), mode: Unsafe)` returns the module unchanged. Under F7 that hybrid
   has `meter: MeterFuel` (Safe posture on every field but `mode`), so it now *meters and gates*
   like Safe — the old assertion is wrong. Replace it with the real `profiles.unsafe()` posture
   tests (1–5 above); the keystone flagged exactly this ("Unit 08 revisits when metering keys off
   `binding.meter`").
8. `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test` stays
   green (≥509, conformance 1740/1359/0 unchanged — Safe is byte-identical). Every new/changed
   function carries a doc comment stating its contract (D8). **Done = the unit's suite passes**,
   never "it compiles".

---

## What this unit leaves

- **Unit 09 (`emit_core` + pipeline)** consumes the §C.3 resolution seam — it resolves the *same*
  stdlib target this gate resolved (preferably by calling `ir_lower.resolve_stdlib_fn`), reads the
  Unsafe `Binding`, and (separately) wires `optimize(m, binding.opt_level)` into the driver and
  extends the structural security-invariant test for `BifOpen`.
- **Unit 06** provides the `rt_stdlib` passthrough impls + `rt_bif` open gate whose published
  passthrough surface this unit's `passthrough_stdlib_surface()` is pinned and cross-checked
  against; unit 06/11 own the F6 observational-identity differential for each passthrough target.
- **Unit 05** fills the enforcing `charge` (budget + `FuelExhausted`) behind the `MeterFuel`
  `Charge` nodes this unit inserts; `MeterOff` needs none of it.
- **Unit 11 (capstone)** runs the whole-corpus Safe-vs-Unsafe differential (identical results and
  traps), proving that switching every policy field this unit reads never changes an observable
  answer, and the honest benchmark that motivates the passthrough/open levers.
