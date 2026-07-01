# Unit 01 — Interface Freeze (Phase-3 keystone)

> **One owner. Design + compiling stubs only. On the critical path of everything.** Read
> [`00-overview.md`](00-overview.md) (F1–F8) first, then [`phase-1/00-overview.md`](../phase-1/00-overview.md)
> (D1–D10) and [`phase-2/00-overview.md`](../phase-2/00-overview.md) (E1–E8). This unit freezes the
> **three** contracts the Phase-3 swarm binds to — the **optimizer public interface**
> (`«IROPT-IFACE-FROZEN»`), the **Unsafe profile policy extension**
> (`«UNSAFE-PROFILE-FROZEN»`), and the **enforcing metering contract**
> (`«METER-ENFORCE-FROZEN»`) — and lands them GREEN (the build compiles, `gleam test` passes,
> zero warnings) before the parallel units begin.

The build is currently zero-warning with **509 passing tests** (conformance 1740 / 1359 / 0).
**It must stay that way after this unit.** Phase 3 adds **no** `Expr`/`NumOp`/`ConvOp` variants
and **no** `.ir` grammar change (F7) — the only IR touch is one *runtime* `TrapReason`
(`FuelExhausted`). Because Gleam has no default field values, extending `Binding` with the
policy fields breaks its one full constructor (`safe_default`), and adding `FuelExhausted`
breaks every exhaustive `TrapReason` match (printer, parser, emit_core, rt_trap) — so this is
one coherent unit with a few deliberate, documented cross-file reaches (§D).

---

## Deliverables & freeze milestones

1. `«IROPT-IFACE-FROZEN»` — `OptLevel` + `optimize/2` + the `Pass` shape + the pass
   pipeline/fixpoint driver (`middle/ir_opt.gleam` + the leaf `middle/ir_opt/pass.gleam`, all
   real & green), and the **signature** of the effect classifier (`ir/effect.gleam`,
   conservative-sound bodies). Unblocks 02, 03, 04, 09.
2. `«UNSAFE-PROFILE-FROZEN»` — the five policy enums + the `Binding` policy extension +
   the updated `safe_default()` (Safe posture) + `profiles.unsafe()` landing green and
   **tested as an explicit opt-in**. Settles F7 (OptLevel lives on `Binding`). Unblocks 06, 07, 08, 09, 10.
3. `«METER-ENFORCE-FROZEN»` — the `FuelExhausted` runtime `TrapReason` + its
   `spec_trap_message` + the enforcing `rt_meter` signatures (`seed_fuel/1`; `charge/1`'s
   enforcing contract documented, ABI unchanged). Unblocks 05, 08.

**Out of scope:** any optimizer pass logic, effect-classification logic, enforcing-`charge`
body, passthrough/open runtime, or mode-application in `ir_lower`/`emit_core` — those are
units 02–10. This unit ships *signatures with sound, total freeze bodies* (never `todo`, so
the build stays zero-warning) and the land-green reaches.

---

## A. `«IROPT-IFACE-FROZEN»` — the optimizer public interface (`middle/ir_opt.gleam`)

`ir_opt` is a **new** shared middle-end stage (F1), between `ir_lower` and `emit_core`. It
rewrites the language-neutral IR (frontend-agnostic), so every future frontend inherits it. Its
public surface is **one** entry point (`optimize/2` + `pipeline/1`, in `ir_opt.gleam`) plus the
pass machinery units 03/04 register into — the `Pass` type, its combinators, and the fixpoint
driver live in the **leaf** module `middle/ir_opt/pass.gleam` (imports `ir` ONLY), which
`ir_opt`, `baseline` (03), and `aggressive` (04) all import, so registering passes can never
form an import cycle.

### A.1 `OptLevel` and `optimize/2`

```gleam
//// src/twocore/middle/ir_opt.gleam — the shared IR→IR optimizer entry point (F1). Owns
//// `optimize/2` + `pipeline/1`; the `Pass` type, its combinators, and the fixpoint driver
//// (`run_pipeline`) live in the leaf module `middle/ir_opt/pass` (imports `ir` ONLY). The
//// import chain stays acyclic — `pass → ir`; `ir_opt → {ir, pass}`; `instance → ir_opt`;
//// `ir_lower → instance` — so nothing here depends on the runtime binding.
import twocore/ir.{type Module}
import twocore/middle/ir_opt/pass.{type Pass, run_pipeline}

/// The optimization level a build profile selects (F1). `OptNone` is the identity (the
/// Phase-1/2 build path with the optimizer bypassed — the differential baseline of F2).
///
/// **Naming (settled decision).** F1's prose calls the identity level `None`; it is frozen
/// here as the constructor `OptNone` to avoid colliding with `gleam/option.None`, which the
/// files that thread the level (`instance`, `emit_core`, `pipeline`) all import. `Baseline`
/// and `Aggressive` are collision-free and importable unqualified.
pub type OptLevel {
  OptNone
  Baseline
  Aggressive
}

/// Optimize `module` at `level` (F1) — the single public entry point of the stage.
///
/// - `module`: the IR module from `ir_lower`.
/// - `level`: `OptNone` (identity), `Baseline` (trust-neutral passes), or `Aggressive`
///   (baseline + Unsafe-only passes). Read from `binding.opt_level` by the driver (F7).
/// - Return: a **semantics-preserving** rewrite of `module` (F2 — identical returned values by
///   bit pattern per D7, and identical traps, over the whole acceptance corpus + spec suite).
///   Total; never fails and never introduces an unsound rewrite.
///
/// **Precondition (`Aggressive ⟹ MeterOff`, §B.5).** Calling `optimize` with `Aggressive` over
/// a `Charge`-bearing module is **illegal**: `Aggressive` may only pair with `MeterOff`, the
/// posture under which `ir_lower` inserts no `Charge` nodes (§C, F5). So a module reaching the
/// `Aggressive` pipeline is provably metering-free — which is what makes unit 04's `Charge`-
/// elision / inlining sound. On real pipeline input `charge_elide` is therefore a defense-in-
/// depth no-op (nothing to elide), never a metering-defeating rewrite.
///
/// FREEZE BODY: `run_pipeline(module, pipeline(level))` (`run_pipeline` from `ir_opt/pass`). At
/// the freeze `pipeline(level)` is empty for every level, so `optimize` is the observable
/// identity; units 03/04 register the real passes (single-owner-additive on this file).
pub fn optimize(module: Module, level: OptLevel) -> Module {
  run_pipeline(module, pipeline(level))
}
```

### A.2 The `Pass` shape, registration, ordering, and fixpoint

A pass is a **named**, IR→IR rewrite. Units 03/04 build passes with the constructors below and
register them by editing `pipeline/1` only — so passes never race on the driver. All of this
machinery (the `Pass` type, its combinators, and the fixpoint driver `run_pipeline`) lives in the
**leaf** module `middle/ir_opt/pass.gleam`, which imports `ir` ONLY. Hosting it below `ir_opt`
lets `ir_opt`, `baseline` (03), and `aggressive` (04) all import it without forming a cycle
(passes need the constructors; `ir_opt` needs `Pass`/`run_pipeline`; none imports the others).

```gleam
//// src/twocore/middle/ir_opt/pass.gleam — the `Pass` type, its combinators, and the fixpoint
//// driver (F1). Imports `ir` ONLY (leaf), so `ir_opt`, `baseline`, and `aggressive` can all
//// import it without an import cycle.
import twocore/ir.{type Expr, type Function, type Module}

/// One optimizer pass: a named IR→IR rewrite. Opaque so its invariant (a pass is a *pure
/// function on the IR*, F2) cannot be bypassed and per-pass tests bind to `pass_name`.
pub opaque type Pass {
  Pass(name: String, run: fn(Module) -> Module)
}

/// Build a whole-module pass from a `name` and its `run` transform. Total.
pub fn pass(name: String, run: fn(Module) -> Module) -> Pass

/// The pass's registered name (pipeline logging / per-pass differential tests). Total.
pub fn pass_name(p: Pass) -> String

/// Lift a **per-function** rewrite to a `Pass` (maps `rewrite` over `module.functions`).
pub fn per_function(name: String, rewrite: fn(Function) -> Function) -> Pass

/// Lift a **per-node** rewrite to a `Pass`: applies `rewrite` **bottom-up** to every `Expr` in
/// every function body via `map_expr`. The author decides legality (via `ir/effect`); the
/// traversal only guarantees complete, faithful coverage.
pub fn per_expr(name: String, rewrite: fn(Expr) -> Expr) -> Pass

/// The shared bottom-up traversal combinator: rebuild `e` with `rewrite` applied to each
/// already-rewritten sub-expression, then to the node itself. **Effect-agnostic** — it never
/// drops/reorders/duplicates a node (a pass that elides/CSEs an effect must gate that on
/// `ir/effect`, F3). Total; covers every `Expr` variant (control forms recurse, leaves return
/// as-is). Exhaustiveness is load-bearing (a missed variant is a silently-unoptimized, never
/// *unsound*, subtree), so it is frozen here with a full match and its own test.
pub fn map_expr(e: Expr, rewrite: fn(Expr) -> Expr) -> Expr

/// Run `passes` in order to a **fixpoint**: repeat the whole ordered list until a full round
/// leaves `module` structurally unchanged (`==`, cheap since the IR is plain data) or
/// `max_rounds` (a documented safety bound) is reached. Convergence is guaranteed because the
/// baseline passes are size-reducing (fold/DCE/prop) over a well-founded measure; the bound is
/// a valve, not the termination argument. FREEZE: an empty `passes` converges in round 0.
pub fn run_pipeline(module: Module, passes: List(Pass)) -> Module
```

**Ordering & registration (frozen).** The pipeline is the **ordered list per level** — it
stays in `ir_opt.gleam` (it names `Pass` from `ir_opt/pass`, so `ir_opt` imports the leaf):

```gleam
/// The ordered pass list for `level` (the ONE registration point — units 03/04 append here).
/// FREEZE: every level is `[]` (identity). `OptNone` stays `[]` forever (F1);
/// `Baseline` → the trust-neutral passes (unit 03); `Aggressive` → `baseline ++` the
/// Unsafe-only passes (unit 04), so aggressive is a strict superset of baseline.
fn pipeline(level: OptLevel) -> List(Pass) {
  case level {
    OptNone -> []
    Baseline -> []
    Aggressive -> []
  }
}
```

Units 03/04 add passes **only** by (a) writing a `pass`/`per_function`/`per_expr` value and (b)
appending it to the correct arm of `pipeline/1`. They never touch `optimize`, `run_pipeline`, or
`map_expr` — so two optimizer units cannot collide on the driver.

### A.3 The effect classifier signature (`ir/effect.gleam` — unit 02 fills)

The optimizer's soundness rests on E6/F3: **effects are the reorder/CSE/DCE barrier.** This unit
freezes the classifier's *signature* with **sound conservative** bodies (everything effectful —
so the freeze optimizer legally rewrites nothing); unit 02 replaces the bodies with the real,
still-conservative purity analysis. Bodies are real (not `todo`) to keep the build zero-warning.

```gleam
//// src/twocore/ir/effect.gleam — the shared purity/effect classifier (F3, owner: unit 02).
//// Conservative: anything not *proven* pure is `Effectful`. The optimizer must never rewrite
//// across an effect barrier (E6): no CSE of a load past a store, no reorder past a
//// `MemGrow`/`GlobalSet`/`CallIndirect`/`CallHost`/`Charge`/`Trap`, no DCE of an effect.
import twocore/ir.{type Expr, type Function}

/// Whether an expression is observably pure or side-effecting (F3).
pub type Effect {
  Pure
  Effectful
}

/// DEEP classification: `Pure` iff `e` AND every sub-expression are pure. The optimizer uses
/// this to decide whether a whole subtree may be folded/CSE'd/eliminated.
/// FREEZE body: `Effectful` (sound conservative default). Unit 02 refines.
pub fn classify(e: Expr) -> Effect

/// `True` iff `classify(e) == Pure`. FREEZE: always `False` (safe). Unit 02 refines.
pub fn is_pure(e: Expr) -> Bool

/// SHALLOW barrier test: is THIS node an effect barrier, ignoring its children? (Used to test
/// whether two effectful nodes may swap.) `MemLoad/MemStore/MemGrow/MemSize/GlobalGet/
/// GlobalSet/CallDirect/CallIndirect/CallHost/Charge/Trap` are barriers; `Num/Convert/Values`
/// and the structured-control *shells* are not (their children may still be effectful).
/// FREEZE body: `True` (treat every node as a barrier → the freeze optimizer moves nothing).
pub fn is_effectful_node(e: Expr) -> Bool

/// `True` iff `f`'s whole body is pure — enables pure-callee reasoning for inlining (unit 04)
/// and pure-call CSE. FREEZE body: `False` (sound). Unit 02 refines.
pub fn function_is_pure(f: Function) -> Bool
```

> **Spec anchor.** WASM has a defined store/evaluation model (WebAssembly spec §4.2 *Runtime
> Structure* and §4.4 *Instructions*): memory and global operations read/write the store in
> program order. E6/F3 make that order the optimizer's hard barrier. `is_pure`/`classify` are
> the *sound* side of the contract — misclassifying an effectful node as pure is a
> memory-corruption bug, so unit 02 tests the effectful direction adversarially.

---

## B. `«UNSAFE-PROFILE-FROZEN»` — the Binding policy extension (`runtime/instance.gleam`)

### B.1 The five policy enums (new, in `instance.gleam`)

```gleam
/// Whether CPU fuel metering ENFORCES a budget (F5).
/// - `MeterFuel`: enforcing — `charge` advances the seeded per-instance budget and raises
///   `FuelExhausted` on exhaustion (Safe). `ir_lower` inserts `Charge` nodes.
/// - `MeterOff`: no metering — `ir_lower` inserts NO `Charge` nodes at all (F5 zero-overhead;
///   the emitted `.core` has no charge calls). Unsafe.
pub type MeterMode {
  MeterFuel
  MeterOff
}

/// The BEAM-function allowlist gate posture (F6).
/// - `BifAllowlist`: the build-time allowlist gate is enforced fail-closed (Safe).
/// - `BifOpen`: the allowlist gate is removed — full BUILD-CONTROLLED BEAM access (Unsafe).
///   Even open, generated code never does a data-driven `apply(Mod,F,Args)` with `Mod` from
///   program data (D3a): "open" widens the build-time allow-set, it adds no ambient authority.
pub type BifGate {
  BifAllowlist
  BifOpen
}

/// Which standard-library implementation shared stdlib calls resolve to (F6).
/// - `StdlibOwn`: the vetted `rt_stdlib` implementations (Safe).
/// - `StdlibPassthrough`: route to BEAM stdlib/BIFs where faster + trusted (Unsafe) —
///   OBSERVABLY IDENTICAL to `own` on every shared function (a differential unit 06 owns).
pub type StdlibMode {
  StdlibOwn
  StdlibPassthrough
}

/// The host/capability dispatch policy (F4/F7).
/// - `HostDenyAll`: every host import is denied at run time (Safe, fail-closed).
/// - `HostWhitelist(allow)`: only the listed `#(capability, name)` pairs are permitted.
/// - `HostOpen`: all host imports permitted (Unsafe). Still no ambient authority (D3a) — the
///   allow-set is build-controlled, never a data-driven module/atom from program input.
pub type HostPolicy {
  HostDenyAll
  HostWhitelist(allow: List(#(String, String)))
  HostOpen
}
```

### B.2 The `Binding` extension and the Safe default

`Binding` gains **six** fields the middle-end and backend read to realise Safe vs Unsafe (F7):
five policy enums plus `fuel_budget: Int` (the metering seed value, #3). `OptLevel` is imported
from `ir_opt` (acyclic, §A.1).

```gleam
import twocore/middle/ir_opt.{type OptLevel, Baseline}

pub type Binding {
  Binding(
    mode: Mode,
    // … existing module-name fields (num/trap/host/meter/stdlib/mem/table/state) …
    safe_max_pages: Int,
    // ── Phase-3 policy fields (F7) ──────────────────────────────────────────
    opt_level: OptLevel,      // which passes the driver runs (F1/F7)
    meter: MeterMode,         // enforcing fuel vs off (F5)
    fuel_budget: Int,         // the seed for rt_meter.seed_fuel under MeterFuel (F5); the
                              // instance's CPU bound. Ignored under MeterOff (no seed emitted).
    bif_gate: BifGate,        // allowlist vs open (F6)
    stdlib: StdlibMode,       // own vs passthrough (F6) — distinct from `stdlib_module`
    host_policy: HostPolicy,  // deny-all / whitelist / open (F4)
  )
}
```

`stdlib` (mode) is orthogonal to the existing `stdlib_module` (which names the `own` impl
module): `StdlibOwn` uses `stdlib_module`; `StdlibPassthrough` routes shared functions to the
BEAM instead (unit 06/08 decide the target). Document that distinction inline.

`safe_default()` (the **one** full `Binding` constructor — the land-green reach) sets the
fail-closed Safe posture:

```gleam
opt_level: Baseline,                        // Safe gets the trust-neutral optimizer
meter: MeterFuel,                           // enforcing CPU fuel (F5)
fuel_budget: rt_meter.default_fuel_budget,  // the finite Safe CPU bound, armed at instantiate (F5)
bif_gate: BifAllowlist,                     // allowlist gate on (fail-closed)
stdlib: StdlibOwn,                          // vetted stdlib
host_policy: HostDenyAll,                   // deny every host import
```

`safe_default()` reads the finite default from `rt_meter` (the single source of the budget — the
numeric bound is a seed value, not a field of `MeterMode`; §C.2), so `instance` imports
`runtime/rt_meter` for `default_fuel_budget`. That edge is acyclic (`rt_meter` imports neither
`instance` nor `ir_opt`). This is the ONE channel for the budget: there is no `emit_core`-bakes-
the-default fallback — `instantiate/0` seeds exactly `binding.fuel_budget` (§C.2/#2).

### B.3 F7 settled: `OptLevel` lives on `Binding`, not as a separate pipeline argument

**Decision: on `Binding`.** The profile is the single source of truth for *all* policy (opt
level, metering, gates, host, stdlib); threading a separate `level` argument alongside the
`Binding` would let the two disagree (a build could optimize aggressively while metering Safe).
Putting `opt_level` on the binding means `profiles.safe()`/`profiles.unsafe()` fix the level
together with the rest of the posture, and the driver (unit 09) reads `binding.opt_level` at the
one `optimize(module, binding.opt_level)` call site. Cost: `runtime/instance` imports
`middle/ir_opt` for the `OptLevel` type — an acyclic edge (the `ir_opt` subtree, `ir_opt` and its
leaf `ir_opt/pass`, imports only `ir`), and the right trade for a single-source-of-truth profile.

### B.4 `profiles.unsafe()` — the tested explicit opt-in (reach into `profiles.gleam`)

`profiles.safe()` (= `safe_default()`) and `profiles.safe_capped(_)` (=
`Binding(..safe_default(), safe_max_pages: capped)`) **compile unchanged**: their record-spread
constructors absorb the six new fields automatically. The *only* additive change to
`profiles.gleam` is the new `unsafe()` constructor (spread over `safe_default()`, overriding the
posture). It keeps the identical `twocore@runtime@rt_*` module names — the shared runtime module
atoms are the same under both profiles — but Safe and Unsafe are **different builds** (B3
monomorphization): the posture fields (`opt_level`/`meter`/…) drive different build-time codegen
(metering compiled in/out, optimizer run at build time), so the emitted OUTPUT module differs
(distinct output atoms). The Instance/Binding API presents that coexistence uniformly ("the
instance is the unit of policy"), while the realization is B3 builds seeded with per-instance
runtime policy at `instantiate/0`:

```gleam
import twocore/middle/ir_opt.{Aggressive}

/// The named **Unsafe** profile (F4): the aggressive optimizer + no metering + open BIF gate +
/// passthrough stdlib + open host, keeping the vetted `twocore@runtime@rt_*` module names. It
/// is an EXPLICIT, TESTED opt-in — there is no path to an Unsafe posture by omission (D4/D9):
/// the default (`safe()`/`safe_default()`/`safe_capped`) stays Safe, and only this constructor
/// yields `mode: Unsafe`. `fuel_budget` is left **inherited** from `safe_default()` (the spread
/// carries it) — harmless under `MeterOff`, which inserts no `Charge` and emits no `seed_fuel`.
/// Total.
pub fn unsafe() -> Binding {
  Binding(
    ..safe_default(),
    mode: Unsafe,
    opt_level: Aggressive,
    meter: MeterOff,
    bif_gate: BifOpen,
    stdlib: StdlibPassthrough,
    host_policy: HostOpen,
  )
}
```

**Fail-closed proof (tested).** A `profiles` test asserts `safe()`, `safe_capped(n)`,
`safe_default()`, and `safe_instance()` are **all** the full Safe posture (mode `Safe`,
`Baseline`/`MeterFuel`/`BifAllowlist`/`StdlibOwn`/`HostDenyAll`), and that `unsafe()` is the
**only** constructor returning `mode: Unsafe` with the aggressive posture. Unsafe by accident is
impossible.

### B.5 `Aggressive ⟹ MeterOff` — the opt/meter coupling invariant (frozen)

`opt_level == Aggressive` **requires** `meter == MeterOff`: only `Baseline` (or `OptNone`) may
pair with `MeterFuel`. The Unsafe-only passes unit 04 appends under `Aggressive` (inlining,
`Charge`-elision) are sound only over a module that carries **no** `Charge` nodes, and `MeterOff`
is exactly the posture under which `ir_lower` inserts none (§C, F5). So any module reaching the
`Aggressive` pipeline is provably metering-free, and `optimize`'s precondition (§A.1) holds by
construction.

This is why the shipped constructors pair the levels as they do — `safe_default()` is
`Baseline`/`MeterFuel`, `unsafe()` is `Aggressive`/`MeterOff` — and **no shipped profile
constructor yields `Aggressive` + `MeterFuel`.** A freeze test asserts exactly that over every
shipped constructor (`safe()`, `safe_capped(_)`, `safe_default()`, `safe_instance()`,
`unsafe()`): the illegal pairing is unrepresentable in a profile, so unit 04's `charge_elide` is
a defense-in-depth no-op on real pipeline input, never a metering-defeating rewrite.

---

## C. `«METER-ENFORCE-FROZEN»` — the enforcing `rt_meter` + the `FuelExhausted` trap

### C.1 `FuelExhausted` — a runtime resource-limit `TrapReason` (reach into `ir.gleam`)

Add one variant to `ir.TrapReason` (F5/F7). It is a **runtime** reason raised by `rt_meter`,
**never emitted as an IR `Trap` node** — no lowering ever produces `Trap(FuelExhausted)`. It
exists in `TrapReason` so it rides the existing catchable `{wasm_trap, Kind}` channel
(`rt_trap.raise`) and surfaces through the run-ABI as an ordinary `Trapped(reason)` (unit 11's
runner catches it with no new plumbing).

```gleam
pub type TrapReason {
  // … the existing nine …
  /// The 2core CPU-fuel resource bound was exhausted (F5). This is OUR policy trap, NOT a
  /// WebAssembly spec trap — no `.wasm` operation raises it and no `assert_trap` expects it.
  /// Raised only by `rt_meter.charge` when a seeded budget is spent.
  FuelExhausted
}
```

`rt_trap.spec_trap_message(FuelExhausted)` → **`"fuel exhausted"`** (reach into
`rt_trap.gleam`). This string is deliberately **distinct** from every WASM spec trap-message
substring — including the spec's `"call stack exhausted"` (`assert_exhaustion`) — so the
conformance harness can never mis-map a real WASM trap to it or vice versa. Document at the
mapping site that it is a policy message, present only for our own audit/diagnostics.

> **Spec anchor.** The WebAssembly spec's traps are enumerated in §4.2/§4.4 and asserted by the
> suite's `assert_trap`; the spec separately permits an embedder to abort on *resource
> exhaustion* (§7 Embedding; the suite's `assert_exhaustion`). `FuelExhausted` is exactly such
> an embedder-imposed CPU bound — sound with respect to the spec (it aborts, it never returns a
> wrong value) but not one of the spec's own trap reasons, which is why it carries a non-spec
> message.

### C.2 The enforcing `rt_meter` signatures (`rt_meter.gleam` — unit 05 fills the enforcement)

The ABI `charge/1` codegen calls is **unchanged** (arity 1, returns `Nil`), so no generated
code changes when metering becomes enforcing. The freeze adds the `seed_fuel/1` seam and
documents the enforcing contract; `charge/1`, `fuel_consumed/0`, `reset_fuel/0` keep their
Phase-1/2 bodies at the freeze (so all 509 tests stay green), and **unit 05** adds the
budget-check + `FuelExhausted` raise.

```gleam
/// Seed this instance's CPU-fuel BUDGET (F5). Called once by the generated `instantiate/0`,
/// which **emit_core (unit 09)** synthesizes and is the sole owner of the per-instance seeds:
/// as a documented exception to emit_core's posture-agnosticism, when `binding.meter ==
/// MeterFuel` it emits `seed_fuel(binding.fuel_budget)` as `instantiate/0`'s FIRST effect (and
/// always emits `rt_host:seed_policy(...)`). (`ir_lower` (08) cannot emit `instantiate/0`; it
/// only inserts/omits the hot-path `Charge` sites.) It runs inside the instance's OWNED process,
/// so the budget lives in that process's dictionary alongside the Phase-2 cell (one-instance-
/// one-process, E1) — isolated per instance and GC'd with the process. Resets `fuel_consumed`
/// to 0.
///
/// - `budget`: the finite reduction-style fuel bound — `instantiate/0` passes
///   `binding.fuel_budget` (§B.2), which `safe_default()` seeds from
///   `rt_meter.default_fuel_budget` and a metered profile (unit 10's `safe_metered(budget)`) may
///   lower, exactly as `safe_max_pages` bounds memory; the numeric bound is a seed value on the
///   `Binding`, NOT a field of `MeterMode`.
/// FREEZE body: store the budget in a per-process cell + reset consumed (real, trivial). Total.
pub fn seed_fuel(budget: Int) -> Nil

/// Charge `cost` fuel (ABI UNCHANGED — arity 1, returns `Nil`; codegen is identical to Phase 2).
///
/// ENFORCING CONTRACT (unit 05): advance the running consumed total by `cost`; if a budget was
/// seeded and the total exceeds it, **raise `FuelExhausted`** (via `rt_trap.raise`, surfacing
/// as `{wasm_trap, fuel_exhausted}`).
///
/// **Fail-closed (D4).** A `MeterFuel` artifact must never run silently unbounded. Its
/// `instantiate/0` ALWAYS seeds the budget (§C.2/#2) and the shipped run-ABI instantiates before
/// every invoke, so the production CPU bound is always armed. The unseeded case is therefore an
/// explicit **legacy/test** posture, NOT the default of a metered build. PREFER making an
/// unseeded charge under a metered build fail-closed (treat it as exhausted); the accumulate-
/// only fallback survives ONLY as far as needed to keep the 509 legacy tests (which charge
/// without seeding) green — unit 05 resolves the back-compat mechanics against the real suite,
/// but no metered artifact may run unbounded by default. This mirrors the fail-closed host
/// boundary (unseeded host policy denies all). FREEZE body: the existing accumulate-only body
/// (kept green); unit 05 adds the budget check + raise + spec-cited tests.
pub fn charge(cost: Int) -> Nil

/// The running fuel total in the current process (observability, unchanged). `>= 0`; `0` before
/// any charge. Still exposed after enforcement lands (F5: `fuel_consumed()` stays observable).
pub fn fuel_consumed() -> Int

/// Zero the current process's fuel counter (test/reset support, unchanged).
pub fn reset_fuel() -> Nil
```

**Why constant space + preemption survive (F5).** The budget is *process-dictionary state*,
seeded at instantiation and read/written only by `charge` — it is **not** threaded through
generated function signatures, so the loop back-edge stays a bare tail-`apply` (constant space,
preemptible), exactly as Phase 2's cell state. `charge` remains an ordinary
reduction-consuming op that either returns `Nil` or diverges by raising.

**Zero-overhead Unsafe (F5, enforced in unit 08).** Freeze the decision here, implement it in
`ir_lower` (unit 08): when `binding.meter == MeterOff`, `ir_lower` inserts **no `Charge` nodes**
— the emitted `.core` for a function under Unsafe differs from Safe by *exactly* the charge
instrumentation (the F2 differential proves it). `MeterOff` is not a no-op charge; it is the
*absence* of charge sites, so there is no `seed_fuel` and no `rt_meter` call at all under Unsafe.

---

## D. Land-green cross-file reaches (enumerate EVERY one)

Extending `Binding` and adding `FuelExhausted` break exhaustive constructors/matches. Every
reach below is edited by this unit so the build stays green (zero warnings, 509 tests):

| # | File | Reach | Why it breaks / what to add |
|---|---|---|---|
| 1 | `middle/ir_opt.gleam` | **new** | `OptLevel`, `pipeline` (empty per level), `optimize` — all real, zero `todo`. Imports `ir` + the leaf `middle/ir_opt/pass`. |
| 1b | `middle/ir_opt/pass.gleam` | **new** (leaf) | `Pass`, `pass`/`pass_name`/`per_function`/`per_expr`/`map_expr`, `run_pipeline` — all real, zero `todo`. Imports `ir` ONLY; `ir_opt`, `baseline` (03), and `aggressive` (04) all import it (no cycle). |
| 2 | `ir/effect.gleam` | **new** | `Effect`, `classify`/`is_pure`/`is_effectful_node`/`function_is_pure` — conservative-sound freeze bodies (no `todo`). |
| 3 | `runtime/instance.gleam` | owner-additive | 5 enums + 6 `Binding` fields (5 policy enums + `fuel_budget: Int`) + `safe_default` Safe posture; import `ir_opt.{type OptLevel, Baseline}` and `runtime/rt_meter` (for `default_fuel_budget`). |
| 4 | `runtime/profiles.gleam` | reach (additive) | ADD `unsafe()`; `safe()`/`safe_capped()` compile unchanged (record-spread absorbs new fields). |
| 5 | `ir.gleam` | reach | add `FuelExhausted` to `TrapReason`. |
| 6 | `runtime/rt_trap.gleam` | reach | `spec_trap_message`: `FuelExhausted -> "fuel exhausted"` (+ import the ctor). |
| 7 | `ir/printer.gleam` | reach | `trapreason_to_string` (~L597): `FuelExhausted -> "fuel_exhausted"` (+ import). Never emitted, but the match is exhaustive. |
| 8 | `ir/parser.gleam` | reach | `string_to_trapreason` (~L1468): `"fuel_exhausted" -> Ok(FuelExhausted)` (+ import). |
| 9 | `backend/emit_core.gleam` | reach | `trap_ctor_name` (~L1619): `FuelExhausted -> "FuelExhausted"` (+ import). |
| 10 | `runtime/rt_meter.gleam` | owner-additive | add `seed_fuel/1` + the `default_fuel_budget` constant (the finite Safe seed) (real trivial bodies); keep `charge`/`fuel_consumed`/`reset_fuel`. |

**Tests that stay green *unedited* (verify, don't skip):**
- `test/twocore/middle/ir_lower_test.gleam:217` builds `Binding(..safe_default(), mode: Unsafe)`
  — the spread absorbs the new fields; `ir_lower` still keys off `mode`, so it stays green. (Unit
  08 revisits when metering keys off `binding.meter`.)
- `test/twocore/runtime/profiles_test.gleam` — `safe() == safe_default()` and
  `safe().safe_max_pages == safe_max_pages()` still hold (same constructor). Extend it with the
  §B.4 fail-closed opt-in assertions.

**Tests to extend for coverage (recommended, not required to compile):** add `FuelExhausted` to
`all_trapreasons()` in `test/twocore/ir/roundtrip_test.gleam:357` (proves the new printer/parser
arms round-trip) and a `trap_reason_atom(FuelExhausted) == "fuel_exhausted"` line in
`test/twocore/backend/emit_core_test.gleam:483`. These lists are explicit, so they compile
without the addition — but adding it keeps the taxonomy fully covered.

Announce all three milestones in `state.md` with this reach list.

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives the new posture.** `BifOpen`/`HostOpen`/`StdlibPassthrough`
  widen a *build-controlled* allow-set; none introduces a data-driven `apply(Mod,F,Args)` with
  `Mod` from program data. The freeze only *names* the postures; units 06–08 must preserve D3a
  (unit 09 extends the structural security test for `open`).
- **Fail-closed default (D4/D9).** The default profile is Safe; `unsafe()` is the sole explicit,
  tested opt-in. `MeterFuel`/`BifAllowlist`/`HostDenyAll`/`StdlibOwn`/`Baseline` are the defaults.
- **Effects are the optimizer's boundary (F3).** The freeze classifier is maximally conservative
  (`Effectful` everywhere), so the freeze optimizer is a strict identity — it *cannot* be unsound.
  Unit 02 may only ever *narrow* `Effectful → Pure` with proof; the freeze test pins the
  never-narrow direction (`MemStore` is effectful forever).
- **`FuelExhausted` is sound w.r.t. WASM.** It aborts execution; it never returns a wrong value,
  and it is unreachable for any correct program under a sufficiently-large budget (the capstone
  sets the Safe budget high enough that the corpus/spec suite completes, finite enough that a
  runaway loop traps).

---

## Verification (Definition of Done for unit 01)

- `gleam build` compiles with **zero warnings** — every freeze body is real and total (no
  `todo`, no unused-variable warnings: conservative stubs underscore-prefix unused params, as
  Phase-1's `rt_num` stubs did). The five exhaustive `TrapReason` matches and the one full
  `Binding` constructor all updated.
- `gleam format --check src test` clean; **`gleam test` stays green (509, conformance
  1740/1359/0)** — the freeze changes no observable behavior (F7: no IR nodes, no grammar).
- **The scratch freeze test** (`test/twocore/middle/opt_iface_freeze_test.gleam`, mirroring
  Phase-2's `ir2_freeze_test`) proves the frozen surface typechecks and upholds the contracts —
  spec assertions, not change-detectors (D8):
  - constructs an Unsafe `Binding` via `profiles.unsafe()` and asserts `mode == Unsafe` + all
    five policy fields = the aggressive posture; asserts `profiles.safe()` = the Safe posture.
  - calls `ir_opt.optimize(m, OptNone)`, `optimize(m, Baseline)`, `optimize(m, Aggressive)` at
    the type level and asserts each **equals `m`** — the correct assertion for the *empty* freeze
    pipeline (F1); units 03/04 replace it with the F2 semantics-preserving differential.
  - asserts the **`Aggressive ⟹ MeterOff` coupling** (§B.5): no shipped constructor
    (`safe()`/`safe_capped(_)`/`safe_default()`/`safe_instance()`/`unsafe()`) yields
    `opt_level == Aggressive` together with `meter == MeterFuel` — the illegal pairing is
    unrepresentable in a profile.
  - asserts the **bounded metered default** (D4): `safe()` has `meter == MeterFuel` **and** a
    finite `fuel_budget == rt_meter.default_fuel_budget` (a `MeterFuel` profile is never seeded
    unbounded), and `unsafe()` inherits that same `fuel_budget` (harmless under `MeterOff`).
  - asserts the effect **soundness direction** that holds at freeze AND forever:
    `effect.is_pure(MemStore(...)) == False` and `effect.is_effectful_node(MemStore(...)) == True`
    (E6) — never a lock-in of the conservative stub's output.
  - asserts `rt_trap.spec_trap_message(ir.FuelExhausted) == "fuel exhausted"` and that
    `rt_meter.seed_fuel(_)`/`charge(_)`/`fuel_consumed()` are callable.
- **Done = the freeze test + the full suite pass** (D8) — not "it compiles."

---

## What this unit leaves

- **02** fills `ir/effect.gleam` (real conservative purity analysis + adversarial "must NOT do
  this" fixtures); unblocks 03/04.
- **03** registers the `Baseline` passes into `pipeline/1` (from `baseline.gleam`, importing
  `ir_opt/pass` for `pass`/`per_expr`/`map_expr` + `ir/effect`; const-fold bit-exact to
  `rt_num`); **04** appends the Unsafe-only `Aggressive` passes (inlining, `Charge`-elision, from
  `aggressive.gleam`, also over `ir_opt/pass`), each documenting its trust assumption.
- **05** fills enforcing `charge` (budget check + `FuelExhausted` raise) and tunes the magnitude
  of `rt_meter.default_fuel_budget` — the seed channel (`binding.fuel_budget` → `seed_fuel`) is
  frozen here in unit 01, and there is no second budget path.
- **06/07** implement `StdlibPassthrough`/`BifOpen`/`HostWhitelist`/`HostOpen`; **08** makes
  `ir_lower` mode-aware (skip `Charge` on `MeterOff`; passthrough; open gate); **09** wires
  `optimize(m, binding.opt_level)` into the driver, honors the Unsafe `Binding`, adds the CLI
  `opt` stage.
- **10** assembles `profiles.unsafe()` + proves Safe/Unsafe coexistence on one node; **11** runs
  the Safe-vs-Unsafe + optimizer-soundness differentials, the metering-trap proof, and the
  honest benchmark.
</content>
</invoke>
