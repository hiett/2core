# Unit 04 — `ir_opt` AGGRESSIVE passes (Unsafe-only)

> **One owner · the second optimizer unit · Unsafe-only.** Owns
> `src/twocore/middle/ir_opt/aggressive.gleam`. Read [`00-overview.md`](00-overview.md)
> (F1–F8), [`01-interface-freeze.md`](01-interface-freeze.md) (the frozen `Pass` machinery +
> `OptLevel` + `effect.gleam` signatures + `MeterMode`), and unit **03**'s baseline passes
> before starting. Phase-1 D1–D10 and Phase-2 E1–E8 still hold. These passes run **only** at
> `OptLevel = Aggressive`, which is reachable **only** from `profiles.unsafe()` (F4) — the Safe
> default (`Baseline`) never executes a line of this file.

---

## Context

The baseline optimizer (unit 03) ships the **trust-neutral** passes — const-fold, copy/const-
prop, dead-`let`/DCE, algebraic identity, block/label simplification, constant-condition `if` —
each **unconditionally** semantics-preserving (F2), each forbidden from crossing an effect
barrier (F3/E6). This unit adds the passes that are **sound but scoped to Unsafe**: they either
interact with the Safe metering overlay (so they are not observationally transparent under Safe)
or are size-expanding heuristics that F8 deliberately keeps out of the vetted baseline set. Every
pass here carries an **explicit, documented trust assumption** and a proof it **cannot change a
corpus result** — because Unsafe is *not* a licence to break WebAssembly semantics. WASM has **no
C-style undefined behaviour**: every ill-defined operation traps
([spec §4.4](https://webassembly.github.io/spec/core/exec/instructions.html),
[§4.3 numerics](https://webassembly.github.io/spec/core/exec/numerics.html)). An Aggressive pass
may **not** "assume no div-by-zero" and drop the trap, may **not** drop an OOB `MemStore` trap.
The trust is confined to **toolchain well-formedness** (the callee body faithfully implements the
function; names are unique per-function, `ir.gleam` open-question #1) and **policy overlays**
(fuel metering is a policy, not a WASM semantic).

**The profile coupling (Aggressive ⟹ MeterOff).** Both shipped passes are sound *only because*
`OptLevel = Aggressive` implies `MeterMode = MeterOff`: only `Baseline`/`OptNone` may pair with
`MeterFuel`, and a keystone test asserts **no shipped profile constructor ever yields
`Aggressive + MeterFuel`**. A legal Aggressive build is therefore always `MeterOff`, so it carries
**no `Charge` nodes** (unit 08 emits none under `MeterOff`) and no seeded fuel budget — inlining
cannot perturb a fuel observable (§B.5) and `Charge`-elision cannot drop a `FuelExhausted` trap
(§C). `optimize`'s contract (units 01/03) documents that running Aggressive over a `Charge`-bearing
module is **illegal**; on real pipeline input `charge_elide` is a defense-in-depth **no-op** (§C.1).

## Goal

Register the Aggressive-only passes into the `ir_opt` pipeline: **(1)** function inlining with a
size/recursion-guarded heuristic and correct capture-avoiding renaming; **(2)** `Charge`-elision
under the `MeterOff` trust assumption; **(3)** post-inlining cleanup — achieved for free by the
fixpoint driver re-running unit 03's baseline passes over the enlarged bodies. Prove each
result-preserving over the full acceptance corpus + spec suite (F2's differential, owned by unit
11), and state honestly (F8) what is **not** here: no LICM, no range-based bounds-check
elimination, no SIMD, no pure-call CSE.

## Files owned

- `src/twocore/middle/ir_opt/aggressive.gleam` — **NEW.** The Unsafe-only passes + their
  `passes()` list. Imports the frozen `Pass` machinery + `ir` + `ir/effect` **only**; never
  imports a `runtime/*` impl module (D3a — this is a build-time IR→IR pass).
- `test/twocore/middle/ir_opt_aggressive_test.gleam` — **NEW.** Per-pass property tests +
  the "must NOT change a result/trap" fixtures.

## Deliverables & freeze milestones

**Consumes** (`«IROPT-IFACE-FROZEN»`, unit 01 · `«IROPT-BASELINE»`, unit 03):

- `ir_opt.{type Pass, pass, per_function, per_expr, map_expr}` — the frozen pass constructors
  and the bottom-up traversal combinator (§01.A.2). `pass/2` builds a **whole-module**
  `fn(Module) -> Module` pass (inlining needs the whole module to resolve callees); `per_expr/2`
  builds a bottom-up node rewrite (Charge-elision).
- `ir_opt.{type OptLevel, Aggressive}` — the level this unit's passes are gated to.
- `ir/effect.{is_pure, is_effectful_node, function_is_pure}` — the F3 soundness oracle (unit 02).
- `instance.{type MeterMode, MeterOff}` — the trust-assumption anchor for Charge-elision (F5).
- unit 03's `baseline.passes() -> List(Pass)` — the trust-neutral list the Aggressive arm reuses.

**Produces** — `pub fn passes() -> List(Pass)`: the ordered Unsafe-only passes appended after the
baseline passes to form the `Aggressive` pipeline arm (F1). This is a **leaf** deliverable: no
new milestone gates on it; unit 11's differential is the acceptance proof.

**Out of scope:** the baseline passes themselves (unit 03); the effect classifier (unit 02); the
`optimize`/`run_pipeline`/`pipeline` driver (unit 01); mode application in `ir_lower`/`emit_core`
(units 08/09); the differential corpus harness (unit 11).

---

## A. Registration — the Aggressive arm is `baseline ++ aggressive.passes()`

The frozen pipeline (§01.A.2) is an ordered list per level, re-run to a fixpoint by
`run_pipeline`. `Aggressive` is a **strict superset** of `Baseline`:

```gleam
//// src/twocore/middle/ir_opt/aggressive.gleam — the Unsafe-only optimizer passes (F1/F2/F4).
//// Imports the frozen `Pass` machinery + `ir` + `ir/effect` ONLY. Every pass here runs solely
//// at `OptLevel.Aggressive`, reachable ONLY from `profiles.unsafe()` (F4), so the Safe default
//// never executes it. Each pass documents its TRUST ASSUMPTION and is proven not to change any
//// returned value (by bit pattern, D7) or any trap (reason + trap-or-not) on the corpus (F2).
import twocore/ir
import twocore/ir/effect
import twocore/middle/ir_opt.{type Pass, pass, per_expr}

/// The ordered Unsafe-only passes, appended after the baseline passes to build the `Aggressive`
/// pipeline arm: `pipeline(Aggressive) == baseline.passes() ++ aggressive.passes()`.
///
/// Order: `[charge_elide(), inline()]`. Charge-elision first normalises away any metering
/// instrumentation (belt-and-suspenders — §C), so inlining and the fixpoint's baseline sweep see
/// Charge-free bodies. Post-inlining copy-prop/const-fold/DCE are **not** new passes here: the
/// `run_pipeline` fixpoint (§01.A.2) re-runs the WHOLE arm — baseline included — until the module
/// is structurally unchanged, so inlining's newly-exposed constants are folded by unit 03's
/// passes for free (§D). Total.
pub fn passes() -> List(Pass) {
  [charge_elide(), inline()]
}
```

**Registration reach (flag for keystone/unit 03).** The one-line append lives in `ir_opt.pipeline/1`
(owned by unit 01/03): `Aggressive -> list.append(baseline.passes(), aggressive.passes())`.
Because that makes `ir_opt` import `middle/ir_opt/aggressive` **while** `aggressive` imports the
`Pass` type + constructors + `map_expr`, hosting the `Pass` machinery *inside* `ir_opt.gleam`
would create an **import cycle** (Gleam forbids these). The keystone must host `Pass` /
`pass` / `per_function` / `per_expr` / `map_expr` in a **leaf** module
(`middle/ir_opt/pass.gleam`) that both `ir_opt.gleam` and the leaf pass modules import. This is
the single binding adjustment unit 04 needs; the frozen *signatures* are unchanged — only their
home moves. Unit 04 imports the machinery from wherever the keystone finally lands it.

---

## B. Pass 1 — function inlining (`inline/0`)

Inlining replaces a `CallDirect(f, args)` with a capture-avoiding copy of `f`'s body. It is a
**whole-module** pass (`pass("inline", run)`) because it must resolve the callee by name.

### B.1 Eligibility heuristic (leaf / small-body / single-call-site)

```gleam
/// The maximum callee body size (Expr-node count) eligible for inlining at a non-unique call
/// site. Bodies larger than this are inlined ONLY when single-call-site (size-neutral). A knob,
/// not a correctness bound — termination rests on the guards in §B.3, not on this number.
const small_body_nodes: Int = 24
```

A `CallDirect(f, args)` at site `s` is **eligible** iff **all** hold:

1. `f` is a **defined** function of this module (never an import — those are `CallHost`, the
   capability boundary, and are out of inlining's scope entirely).
2. `f` is **not recursive** — neither self-recursive nor on a call-graph cycle. Compute the
   `CallDirect` call graph once per `run`; refuse any callee whose strongly-connected component
   has size > 1 or that calls itself. (This is the termination guard, §B.3.)
3. **Heuristic gate** — at least one of: `f` is a **leaf** (its body contains no
   `CallDirect`/`CallIndirect`/`CallHost`); `f`'s body is **small** (node count ≤
   `small_body_nodes`); or `f` is called from **exactly one** site module-wide (inline-and-delete
   is size-neutral, so the small/leaf bound is waived).
4. The running **size budget** (§B.3) is not yet exhausted.

Purity is *not* required — inlining is value/trap-preserving regardless (§B.4). `effect`'s
`function_is_pure(f)` is consulted only as a bonus: an inlined pure callee whose result is unused
becomes eligible for baseline DCE on the next fixpoint round (a pure subtree may be dropped, F3);
an effectful callee's body is preserved verbatim and never DCE'd.

### B.2 The transform (capture-avoiding; single-exit via a fresh Block)

Inlining rewrites the enclosing `Let(names, CallDirect(f, args), cont)` (the canonical ANF shape
a call appears in). The steps, in order:

1. **Alpha-rename** every name *bound inside* `f`'s body — locals, `Let` names, `Block`/`Loop`
   labels, `LoopParam` names — to fresh names unique in the caller (prefix `inl$<f>$<n>$…`; a
   per-`run` counter guarantees uniqueness, satisfying `ir.gleam` open-question #1). This is the
   capture-avoidance step: without it a callee local could shadow a caller binding.
2. **Substitute params** — replace each `Var(f.params[i].name)` with `args[i]` (a `Value`)
   throughout the renamed body. Because ANF operands are **atomic `Value`s**, substitution
   **never duplicates or reorders a computation** — a `Var`/const arg used twice is just
   referenced twice, with no re-evaluation of any effect.
3. **Single-exit rewrite** — wrap the renamed, substituted body in a fresh
   `Block(exit_label, f.result, body')` and rewrite every `Return(vs)` in it to
   `Break(exit_label, vs)`. This is the crux: a callee `Return` returns from **f**, but after
   inlining it must yield to the *inlined region*, not the caller — so it becomes a `Break` to the
   wrapping block, whose result is the call's result. Fall-through bodies need no rewrite. The
   callee's own internal `Break`/`Continue` target renamed labels defined within the body and are
   untouched.
4. **Rebind** — the rewritten `Block` becomes the new `rhs`: `Let(names, Block(exit_label, …),
   cont)`. Arity of `names` already matches `f.result` (the call was well-typed).

```gleam
/// Inline eligible `CallDirect` sites (§B.1) with a capture-avoiding copy of the callee body
/// (§B.2), then delete any callee left with zero remaining call sites and no export.
///
/// TRUST ASSUMPTION (documented, F2): `binding.meter == MeterOff` — i.e. NO `Charge` nodes are
/// present (F5: `ir_lower` inserts none under Unsafe). Guaranteed by the profile coupling
/// `Aggressive ⟹ MeterOff` (§Context): `Aggressive` is reachable only from `profiles.unsafe()`
/// (F4) and no shipped profile pairs `Aggressive` with `MeterFuel`. Under this assumption inlining
/// is observationally transparent (§B.5) — sound ONLY because of the coupling, not for any input. The pass ALSO assumes toolchain well-formedness (the
/// callee body faithfully implements `f`; names unique per-function) — it never inspects or
/// depends on WASM value/trap semantics, which it preserves exactly (§B.4).
///
/// SOUNDNESS: preserves every returned value (by bit pattern, D7) and every trap (same reason,
/// same order) — see §B.4. TERMINATION: the recursion guard + size budget (§B.3) make `run`
/// reach a no-op round, so the `run_pipeline` fixpoint converges. Total.
pub fn inline() -> Pass
```

### B.3 Termination (why the fixpoint converges)

Inlining grows the module, so termination is not automatic. Two guards make it well-founded:

- **No recursive callee (§B.1.2).** A call-graph-cycle callee is never eligible, so inlining
  cannot chase an unbounded recursive expansion.
- **Global size budget.** `run` carries a budget `B` (total Expr-nodes it may *add* across the
  whole module, e.g. `8 × original_node_count + 4096`). Once `B` is spent, no further site is
  eligible and `run` returns the module **structurally unchanged**.

The **well-founded termination measure is the remaining size budget** `B_remaining` — a
non-negative integer initialised to `B` and decremented by the node-count of every body it inlines.
Each inline transplants a callee body of **≥ 1** node, so each step strictly decreases
`B_remaining` by at least 1, and it is bounded below by 0; therefore **at most `B` inline steps ever
occur** across the whole `run_pipeline` fixpoint. The **eligible-site count is only a heuristic**
for choosing *which* site to take next — **not** the well-founded measure: inlining can *expose*
new callee-of-callee sites, so the site count may *rise*, whereas `B_remaining` can only fall. The
acyclic-call-graph guard (§B.1.2) supplies the other half of well-foundedness — no callee is ever
re-entered, so the budget is spent across a finite acyclic frontier rather than an unbounded
recursive one. When `B_remaining` reaches 0 (or no site is eligible), `run` is the identity → the
pipeline round is a no-op → `run_pipeline` converges (its `max_rounds` valve is a backstop, not the
argument). No `let assert`/`panic`: an ineligible or malformed shape is simply left unchanged
(fail-safe, D4).

### B.4 Proof: inlining preserves values and traps (WASM has no UB)

A direct `call` in WASM evaluates its (already-computed) arguments, then runs the callee to
completion, propagating any trap at the call site
([spec §4.4.7 Control Instructions](https://webassembly.github.io/spec/core/exec/instructions.html#control-instructions)).
The inlined region reproduces exactly this:

- **Same effects, same order.** Args are ANF `Value`s already evaluated *before* the call, so
  substitution introduces no new evaluation. The callee body is transplanted **verbatim** (only
  renamed) into the exact position the call held, so its `MemLoad`/`MemStore`/`GlobalGet`/
  `GlobalSet`/`MemGrow`/`CallIndirect`/`CallHost` execute in the identical relative order (F3/E6
  respected — no node is reordered, dropped, or duplicated across an effect barrier).
- **Same traps — none dropped.** A div-by-zero (`IntDivByZero`), signed overflow (`IntOverflow`),
  OOB access (`MemoryOutOfBounds`), indirect type mismatch, or `Unreachable` inside `f` fires at
  the same program point with the same `TrapReason`. Inlining is **not** licensed by Unsafe to
  elide any of these — the trust assumption (§B.2) is about metering, not WASM semantics (F8).
- **Same values, bit-exact.** No arithmetic is performed; `Value`s (including float bit patterns,
  D5) are moved unchanged. `Return` → `Break` to the wrapping block yields the same result list.
- **No capture.** Alpha-renaming (§B.2.1) makes callee-bound names disjoint from caller names, so
  no reference is re-bound.

### B.5 Why inlining is Unsafe-only, not Baseline

Inlining is *unconditionally* value/trap-preserving — so why not baseline? Two legitimate reasons:

1. **It is not observationally transparent under Safe.** Under Safe (`MeterFuel`), `ir_lower`
   wraps every function body in `Charge(fn_cost, …)` and every loop in `Charge(loop_cost, …)`
   (unit 08). Inlining changes *how many* `Charge` sites execute per call — which changes the
   observable `fuel_consumed()` **and** can change *whether/when* a seeded budget is exhausted,
   i.e. it can add or remove a `FuelExhausted` trap (F5). Adding/removing a trap violates F2. So
   under Safe, inlining is categorically unsound. Under Unsafe (`MeterOff`, no `Charge` nodes)
   there is no fuel observable and no fuel trap, so the call boundary carries nothing to disturb.
2. **F8 bounds the baseline set.** Baseline is the deliberately-minimal, trust-neutral,
   **μ-decreasing** vetted set — every baseline rewrite strictly lowers unit 03's lexicographic
   measure `(n_loops, n_ops, n_nodes, n_vars)` (even de-loop, the one baseline pass that *adds*
   nodes, still strictly drops `n_loops`; see 03 §I). Inlining is different in kind: a size-
   *expanding*, cost-model-driven heuristic that grows `n_nodes` with no offsetting drop in a
   more-significant component, so its termination rests on the separate size budget `B_remaining`
   (§B.3), not on `μ`. Its payoff is realised only alongside the rest of the Unsafe posture
   (passthrough stdlib, no metering). It belongs in Aggressive by design.

---

## C. Pass 2 — `Charge`-elision (`charge_elide/0`)

```gleam
/// Elide every `Charge(cost, body)` node, rewriting it to `body` (bottom-up, so nested charges
/// collapse). Implemented as `per_expr("charge-elide", …)` over `map_expr`.
///
/// TRUST ASSUMPTION (documented, F2/F3): `binding.meter == MeterOff`. Under `MeterOff` no fuel
/// budget is ever seeded (unit 05), so `rt_meter.charge` neither raises `FuelExhausted` nor
/// participates in any observable — `fuel_consumed()` is not a contract of the Unsafe profile.
/// Removing the node therefore changes NO returned value and NO trap. Sound ONLY under the profile
/// coupling `Aggressive ⟹ MeterOff` (§Context): guaranteed reachable only from `profiles.unsafe()`
/// (F4), never on a `MeterFuel` build. Total.
pub fn charge_elide() -> Pass {
  per_expr("charge-elide", fn(e) {
    case e {
      ir.Charge(_cost, body) -> body
      other -> other
    }
  })
}
```

`Charge` is classified **`Effectful`** by `effect.is_effectful_node` (F3/§01.A.3), and baseline
is **forbidden** from DCE-ing an effect (F3: "no dead-code elimination of an effect"). Charge-
elision is the **canonical F3 example** of Aggressive relaxing a *specific, named* barrier under a
documented trust assumption: "eliding `Charge` when metering is off — a policy overlay, not a WASM
semantic" (F3, verbatim). It is **Unsafe-only** for the sharpest possible reason: under Safe
(`MeterFuel`) the identical elision would remove the `Charge` sites whose exhaustion raises
`FuelExhausted`, so a runaway loop that *should* trap at the fuel bound would no longer trap —
**that is dropping a trap**, forbidden by F2. Under Unsafe there is no budget, so `charge` cannot
trap and elision is transparent.

### C.1 Reconcile: is Charge-elision even needed? — decision + justification

The cleaner path is that `ir_lower` under `MeterOff` inserts **no `Charge` nodes at all** (F5,
unit 08) — so in the **production WASM pipeline the Aggressive input is already Charge-free**, and
`charge_elide` finds nothing to do (a no-op). **Decision: keep the pass — as a cheap, provably-
sound normalisation / defence-in-depth, not as the primary mechanism.** Justification:

- **F5 owns the zero-overhead guarantee; this pass does not.** The "no `charge` calls at all"
  differential (overview "zero-overhead Unsafe") is proven by `ir_lower` *not emitting* Charge,
  **not** by this pass deleting it. If this pass were the mechanism, an intermediate stage would
  still carry Charge nodes and the guarantee would be fragile. So `charge_elide` is explicitly
  **belt-and-suspenders**, and the doc says so.
- **It hardens two off-pipeline entry points.** Running Aggressive over a `Charge`-bearing module
  is **illegal** by the profile coupling (Aggressive ⟹ MeterOff, §Context) — a legal `MeterOff`
  build never carries `Charge`. But a hand-written `.ir` fed straight to `optimize(m, Aggressive)`
  (bypassing `ir_lower`), or a future frontend that inserts `Charge` unconditionally, could violate
  that precondition. This pass makes the Aggressive **postcondition** — *the output contains no
  `Charge` node* — hold **structurally** even for such malformed input, which inlining (§B) also
  relies on for its `MeterOff` trust assumption. Its *soundness*, however, still rests on the
  coupling, **not** on the input: eliding a `Charge` preserves behaviour only because Aggressive
  implies `MeterOff` (no seeded budget, so no `FuelExhausted` to drop). On real pipeline input it is
  a plain **no-op**.
- **It is nearly free.** One `per_expr` bottom-up sweep; on the (common) Charge-free input it
  allocates nothing new. The cost of keeping it is a few lines; the cost of *not* having it is a
  latent unsoundness if any producer ever emits Charge into an Aggressive build.

A test asserts the postcondition directly: `contains_charge(optimize(m, Aggressive)) == False`
for an `m` that *does* contain hand-inserted `Charge` nodes — proving the pass, not the absence.

---

## D. Pass 3 — post-inlining cleanup (reuse baseline; no new trust)

The mandate's third item — "a small set of trust-assuming simplifications … e.g. post-inlining
copy-prop/fold reuse of the baseline passes" — is delivered **without a new pass**, and this unit
is honest (F8) that it carries **no trust assumption beyond baseline's** (those passes are
unconditionally sound). Mechanism: the Aggressive arm is `baseline.passes() ++ [charge_elide,
inline]`, and `run_pipeline` re-runs the **whole arm to a fixpoint** (§01.A.2). So after inlining
substitutes a constant argument into a callee body, the *next* round's baseline const-fold /
copy-prop / dead-`let` / algebraic-identity passes clean it up — automatically, over the enlarged
bodies, with zero new code. This is the correct place for "trust-assuming simplifications": there
are none that are *both* new *and* sound-only-under-a-new-assumption that Phase 3 is willing to
ship (F8). The only genuinely trust-assuming Aggressive rewrites are §B (inlining, `MeterOff`
assumption) and §C (Charge-elision, `MeterOff` assumption). Anything stronger is deferred (§E).

---

## E. Honest scope — what is NOT here (F8)

The trust-assumption ledger, and the explicitly-deferred:

| Pass | Trust assumption | Why sound (cannot change a corpus result) | Why Unsafe-only |
|---|---|---|---|
| **inline** (§B) | `MeterOff`; toolchain well-formed | ANF Values ⇒ no effect dup/reorder; verbatim body transplant ⇒ same traps, same order; alpha-rename ⇒ no capture; `Return→Break` ⇒ same result (§B.4) | changes `Charge`-site count ⇒ changes `fuel_consumed()`/`FuelExhausted` under Safe (§B.5) |
| **charge_elide** (§C) | `MeterOff` (no seeded budget) | under `MeterOff` `charge` never traps and fuel is unobserved ⇒ removal changes no value/trap | under Safe it would drop the `FuelExhausted` trap of a runaway loop (§C) |
| *post-inline cleanup* (§D) | **none** (baseline) | unconditionally sound baseline passes, merely re-run post-inline by the fixpoint | not Unsafe-only; runs at Baseline too — listed only to explain the fixpoint reuse |

**Explicitly deferred (state it, don't drop it — F8):** **LICM** (hoisting a `MemLoad` out of a
loop needs a richer aliasing/effect model than the conservative `effect.gleam` — unsound without
proving no intervening store, F3); **range-based bounds-check elimination** (dropping a
`MemoryOutOfBounds` guard needs a range solver, and WASM has no UB, so a wrong proof *changes a
trap*); **SIMD vectorisation / reg-alloc tricks** (no SIMD IR surface, F7); **pure-call CSE /
compile-time call evaluation** (`effect.function_is_pure` enables it, but folding a user call needs
a partial evaluator — the natural next Aggressive pass, not shipped).

---

## Effect / soundness / security note

- **No WASM semantics relaxed.** Both shipped passes' trust assumptions are about the **fuel
  metering policy overlay** (`MeterOff`) and **toolchain well-formedness** — never about WASM
  value/trap behaviour. No div-by-zero, OOB, overflow, or `Unreachable` trap is ever elided
  (F8; §B.4/§C). This is the whole point: Unsafe ≠ incorrect.
- **F3/E6 barriers honoured by inlining, relaxed by name for Charge only.** Inlining moves nothing
  across an effect barrier (verbatim transplant, ANF args). Charge-elision is the single, *named*
  barrier relaxation, sanctioned by F3 exactly because metering is a policy, not a semantic.
- **No ambient authority (D3a).** This pass rewrites only `CallDirect` (same-module, build-
  controlled by name) and `Charge` nodes. It never touches `CallIndirect`/`CallHost` dispatch and
  never introduces a data-driven `apply(Mod, F, Args)`. It imports no `runtime/*` impl module.
- **Fail-closed default (D4/D9/F4).** Reachable only from `profiles.unsafe()`. The Safe default
  (`Baseline`) never runs these passes; there is no path to inlining/Charge-elision by omission.
- **Floats as bit patterns (D5).** `Value`s (including `ConstF32`/`ConstF64` NaN/`-0.0` bit
  patterns) are moved verbatim; no float is decoded, so NaN payloads survive inlining exactly.
- **Named-label IR (D6).** Fresh names/labels from alpha-renaming and the single-exit `Block` are
  ordinary unique `String`s — no numeric depths introduced.

---

## Verification (Definition of Done)

Spec-cited, spec-behaviour tests (D8) — **not** change-detectors: assert *what each transform must
preserve*, never the current output. Done = **the suite passes**, not "it compiles".

1. **Inlining preserves values + traps (the F2 property, per-pass).** For a battery of modules —
   leaf callee, small non-leaf callee, single-call-site callee, callee with an early `Return`
   inside an `If`, callee containing an effectful `MemStore`, callee containing a **trapping** op
   (`IDivS` by zero; an OOB `MemLoad`) — assert `optimize(m, Aggressive)` and `m` produce
   **identical results (by bit pattern, D7)** and **identical traps (reason + trap-or-not)** on
   representative inputs, including the input that makes the callee trap (proving the trap is
   **not** dropped). Cite [spec §4.4.7](https://webassembly.github.io/spec/core/exec/instructions.html#control-instructions).
2. **Capture-avoidance.** A caller and callee that share a local name (`"x"`) inline **without**
   the callee's `x` rebinding the caller's `x` — assert the observable result matches the
   un-inlined module. A callee with an early `Return` inside a branch inlines to the same result
   (the `Return→Break` single-exit rewrite is correct).
3. **Termination.** A mutually-recursive pair and a self-recursive function are **never** inlined
   (call-graph guard); a chain that would blow the size budget stops at the budget with the module
   still well-formed. Assert `run_pipeline` converges (no timeout) and `pass_name` appears once.
4. **Charge-elision soundness + postcondition (§C).** For an `m` with hand-inserted `Charge`
   nodes: `optimize(m, Aggressive)` yields a module with **no `Charge` node** and **identical
   results/traps** to `m` interpreted under `MeterOff`. Assert the pass is a **no-op** on the
   already-Charge-free output of `ir_lower(MeterOff)` (reconciliation, §C.1).
5. **Fixpoint reuse (§D).** A module where inlining exposes a constant argument folds it: after
   `optimize(m, Aggressive)` the inlined body contains the folded constant (baseline re-run by the
   fixpoint), demonstrating post-inline cleanup with no new pass.
6. **Unsafe-only gating (F4).** `optimize(m, Baseline)` and `optimize(m, OptNone)` contain **no**
   inlining and **no** Charge-elision (the Baseline arm excludes `aggressive.passes()`; a `Charge`
   present in `m` survives `Baseline`). This pins §B.5/§C's "why Unsafe-only".
7. `gleam format --check src test` clean; `gleam build` **zero warnings** (every function total —
   no `todo`/`panic`/`let assert` on any path; ineligible shapes are left unchanged); `gleam test`
   stays green and the corpus differential (unit 11) is byte-identical at `Aggressive`. Every
   public function/type carries a `///` contract doc (intent / params / return / the trust
   assumption + its soundness argument for each pass).

**Proof of goal:** every shipped pass is proven result-preserving over the acceptance corpus +
spec suite at `Aggressive` (unit 11's differential), each with its trust assumption documented at
its definition site and each shown — by the trapping-callee and runaway-loop fixtures — **not** to
drop a WASM trap.

## What this unit leaves

- **Unit 03 (+ keystone)** registers the Aggressive arm: `pipeline(Aggressive) =
  list.append(baseline.passes(), aggressive.passes())`, and resolves the §A import-cycle by hosting
  the `Pass` machinery in a leaf module (`middle/ir_opt/pass.gleam`).
- **Unit 08** owns the *primary* zero-overhead guarantee (`ir_lower(MeterOff)` inserts no
  `Charge`); this unit's `charge_elide` is belt-and-suspenders, not the mechanism (§C.1).
- **Unit 11** wires the corpus/spec differential that is these passes' acceptance proof and refutes
  any "Unsafe changed an answer" regression. LICM / BCE / SIMD / pure-call CSE stay deferred (§E).
