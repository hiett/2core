# Unit 03 — `ir_opt` BASELINE passes (trust-neutral)

> **One owner · Wave 0→A · the optimizer's meat.** Freeze deps: `«IROPT-IFACE-FROZEN»`
> (unit 01 publishes `optimize/2`, the `Pass` shape, `pass`/`per_function`/`per_expr`/
> `map_expr`, and the `pipeline`/`run_pipeline` driver) and **unit 02** (`ir/effect`: the
> conservative purity classifier `is_pure`/`classify`/`is_effectful_node`). Read
> [`00-overview.md`](00-overview.md) (F1–F8) and [`01-interface-freeze.md`](01-interface-freeze.md)
> first; Phase-1 D1–D10 and Phase-2 E1–E8 still hold. Const-folding **must** match `rt_num`
> **bit-exact** (D2/D5/D7). This unit ships the vetted set of **trust-neutral** passes that run
> at **both** `Baseline` and `Aggressive` — so they must be sound **unconditionally** (F2), no
> trust assumption anywhere (that is unit 04's job).

---

## Context

`ir_opt` runs **after** `ir_lower` and **before** `emit_core` (F1, high-level §4 M2) over the
language-neutral IR, so every present and future frontend inherits it. Unit 01 froze the machinery
and left `pipeline(Baseline) == []`; unit 02 gave a **sound** effect classifier. **This unit fills
`Baseline`** with the seven trust-neutral passes §00 §1 names — const-fold, copy/const-prop,
dead-`let`/DCE, algebraic identity, block/label simplification, constant-condition `if` — each
semantics-preserving *unconditionally* (F2: identical values by bit pattern (D7) and identical
traps). LICM, range-based bounds-check elimination, SIMD, and inlining are **out** (F8 / unit 04).

---

## Deliverables & freeze milestones

**Consume (frozen upstream):**

- `«IROPT-IFACE-FROZEN»` — `ir_opt.{optimize, Pass, pass, per_function, per_expr, map_expr,
  pipeline, run_pipeline}` (unit 01). Passes are registered by editing **one** arm of
  `pipeline/1`; the driver + fixpoint are already written.
- `ir/effect.{Effect, is_pure, classify, is_effectful_node, function_is_pure}` (unit 02) — the
  soundness gate (F3/E6). `is_pure` is **deep** and **conservative**: `True` only when the whole
  subtree is provably pure *and total* (see the requirement on unit 02 in "What this unit leaves").
- `rt_num` (D2, «RTNUM-SIG-FROZEN»/«RTNUM2-SIG-FROZEN») — the single source of truth for numeric
  semantics. The const-folder **calls these functions directly**, so a folded result and the
  runtime result are bit-identical *by construction*, not by a parallel reimplementation.
- `ir.gleam` («IR2-FROZEN») — no new node types (F7); the optimizer only rewrites existing ones.

**Produce:**

- `src/twocore/middle/ir_opt/baseline.gleam` (**NEW**, owned) — the seven passes + `baseline_passes()`.
- `src/twocore/middle/ir_opt.gleam` — **single-owner-additive** edit: import `baseline`, set
  `pipeline(Baseline) -> baseline.baseline_passes()`. (Unit 04 later sets
  `pipeline(Aggressive) -> baseline.baseline_passes() ++ aggressive.aggressive_passes()`, so
  `Aggressive` stays a strict superset — keystone A.2.)
- `test/twocore/optimize/baseline_test.gleam` (**NEW**) — per-pass spec/property tests + the
  per-pass semantics-preservation differential (F2).

No new freeze token: unit 03 is a leaf on the DAG. It hands unit 04 the `baseline_passes()`
accessor and hands unit 11 a green Baseline pipeline for the corpus-wide differential.

---

## A. Binding to the keystone: registry, traversal, and the effect gate

`baseline_passes()` returns the **ordered** list registered into `pipeline(Baseline)`. Each pass
is built with the keystone constructors; there is exactly one whole-module registration point.

```gleam
//// src/twocore/middle/ir_opt/baseline.gleam — the trust-neutral Baseline pass set (F1/F2).
//// Runs at BOTH Baseline and Aggressive (04 appends to it), so every pass is sound with NO
//// trust assumption. Imports `ir`, `ir/effect` (unit 02), and `rt_num` (D2). The edge
//// baseline → rt_num → ir is acyclic (rt_num imports only `ir`; nothing in the numeric
//// runtime imports the optimizer), so calling the runtime for bit-exact folding is legal.
import twocore/ir
import twocore/ir/effect
import twocore/middle/ir_opt.{type Pass, pass, per_expr, per_function}
import twocore/runtime/rt_num

/// The ordered Baseline pass list (§I fixes the order + the termination argument). This is the
/// value unit 01's `pipeline(Baseline)` returns and unit 04 prepends to `Aggressive`. Total.
pub fn baseline_passes() -> List(Pass) {
  [
    pass("const-fold", const_fold_module),
    per_function("copy-const-prop", propagate_and_drop),
    per_expr("algebraic-identity", algebraic),
    per_expr("const-if", const_condition),
    per_function("block-label-simplify", block_simplify),
    per_expr("dead-code", dce),
    per_function("dead-let", dead_let),
  ]
}
```

**Which passes touch `ir/effect` (the F3 boundary).** The only rewrites that can *drop* or
*reorder* work consult the classifier; the rest are sound because they operate on **atomic
`Value` operands** (intrinsically pure — see §F) or on **provably-unreached** subtrees.

| Pass | Uses `ir/effect`? | Why sound without a trust assumption |
|---|---|---|
| const-fold | no | operands are constants → deterministic; a trapping op folds to its *exact* trap (§B) |
| copy/const-prop | `is_pure(rhs)` (always `Pure` — rhs is `Values`) | substitutes an atomic `Value`; reorders no effect (§C) |
| algebraic identity | no | operands are `Value`s (pure, total); rewrite is value-exact (§F) |
| const-`if`/`switch` | no | the discarded arm is **statically unreached** — its effects never run (§H) |
| block/label | no | structural; preserves every executed effect verbatim (§G) |
| DCE | no | drops only the **unreachable** sequel of a divergent `rhs` (§E) |
| **dead-`let`** | **`is_pure(rhs)`** | the load-bearing gate: an effectful/ trapping `rhs` is **never** dropped (§D, F3) |

`map_expr` (keystone) guarantees complete, faithful bottom-up coverage for the `per_expr` passes;
the `per_function` passes (`propagate_and_drop`, `block_simplify`, `dead_let`) do a scope-aware
walk because they need free-variable / label information the effect-agnostic combinator does not
carry.

---

## B. Constant folding — bit-exact to `rt_num`

**Precondition.** A `Num(op, args)` / `Convert(op, arg)` whose operand `Value`s are **all
`Const*`** of the kind `op` expects. **Postcondition.** The node is replaced by
`Values([folded_const])` on success, or by `Trap(reason)` when the op traps on those exact
operands — never by a wrong value.

**Design decision (D2/D7): fold by calling `rt_num`.** For each op the folder invokes the *same*
`rt_num` function `emit_core` calls at run time, then rewraps the resulting `Int` bits into the
result-typed `Const*`. Because the compile-time folder and the run-time evaluator share one
implementation of two's-complement wrap, div/rem traps, shift masking, and the IEEE
bit-pattern/NaN-canonicalization rules, `optimize(m)` and `m` return **identical bits** for a
folded site *by construction*. Re-deriving the arithmetic in the optimizer would risk drift and
would be a change-detector waiting to happen (D8) — so we do not.

```gleam
/// Fold one `Num`; `Ok(expr')` on a foldable constant site, `Error(Nil)` to leave unchanged.
fn fold_num(op: ir.NumOp, args: List(ir.Value)) -> Result(ir.Expr, Nil) {
  case op, args {
    // total integer op → same-width Const
    ir.IAdd(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      Ok(ir.Values([ir.ConstI32(rt_num.i32_add(a, b))]))
    // comparison → i32 truth value regardless of operand width
    ir.IEq(ir.W64), [ir.ConstI64(a), ir.ConstI64(b)] ->
      Ok(ir.Values([ir.ConstI32(rt_num.i64_eq(a, b))]))
    // float op → same-width float Const, NaN/±0/±Inf handled inside rt_num
    ir.FMul(ir.FW64), [ir.ConstF64(a), ir.ConstF64(b)] ->
      Ok(ir.Values([ir.ConstF64(rt_num.f64_mul(a, b))]))
    // TRAPPING op: fold to the value on Ok, to the exact Trap on Error
    ir.IDivS(ir.W32), [ir.ConstI32(a), ir.ConstI32(b)] ->
      case rt_num.i32_div_s(a, b) {
        Ok(bits) -> Ok(ir.Values([ir.ConstI32(bits)]))
        Error(reason) -> Ok(ir.Trap(reason))
      }
    // … one arm per (NumOp, width); an operand-kind mismatch (ill-typed IR the validator
    // already rejects) falls through to `Error(Nil)` — leave unfolded, never panic.
    _, _ -> Error(Nil)
  }
}
```

**Enumeration (every op is foldable — each is a pure function of its constant operands).**

| Family | Ops | Result `Const*` | `rt_num` |
|---|---|---|---|
| int arith/bitwise/shift/rotate | `IAdd ISub IMul IAnd IOr IXor IShl IShrS IShrU IRotl IRotr IClz ICtz IPopcnt` | `W32→ConstI32`, `W64→ConstI64` | `i{32,64}_*` |
| int comparisons | `IEqz IEq INe ILt{S,U} IGt{S,U} ILe{S,U} IGe{S,U}` | **`ConstI32`** (truth `0/1`) | `i{32,64}_*` |
| **int trapping** | `IDivS IDivU IRemS IRemU` | `ConstI{32,64}` **or `Trap`** | `i{32,64}_{div,rem}_*` (`Result`) |
| float binary/unary | `FAdd FSub FMul FDiv FMin FMax FAbs FNeg FCeil FFloor FTrunc FNearest FSqrt FCopysign` | `FW32→ConstF32`, `FW64→ConstF64` | `f{32,64}_*` |
| float comparisons | `FEq FNe FLt FGt FLe FGe` | **`ConstI32`** (truth `0/1`) | `f{32,64}_*` |
| conversions | `I32WrapI64`, `I64ExtendI32{S,U}`, `I{32,64}Extend{8,16,32}S`, `TruncSat{S,U}`, `Reinterpret{FToI,IToF}`, `Convert{S,U}`, `F32DemoteF64`, `F64PromoteF32` | per target type | matching `rt_num` conv fn |
| **conv trapping** | `TruncS(from,to) TruncU(from,to)` | `ConstI{32,64}` **or `Trap`** | `i{32,64}_trunc_f{32,64}_{s,u}` (`Result`) |
| **NOT folded** | `BoxInt UnboxInt BoxFloat UnboxFloat` | — | there is no constant `Value` for a `TTerm`; leave the node as-is |

Spec anchors: integer wrap / div-rem traps / shift masking — [exec/numerics](https://webassembly.github.io/spec/core/exec/numerics.html)
(`iadd`, `idiv_s` traps on `0` and on `INT_MIN/-1`, `irem_s` never overflow-traps, `ishl` uses
`j mod N`); float NaN nondeterminism resolved to the canonical NaN under the deterministic profile
— [exec/numerics §Floating-point](https://webassembly.github.io/spec/core/exec/numerics.html).
Folding a **constant** trapping op to `Trap(reason)` is exactly F2-preserving: the runtime
semantics of that node on those operands *is* to raise `reason` (via `emit_core`'s
`case`-and-`raise`), and the replacement additionally exposes the now-dead sequel to §E.

---

## C. Copy / constant propagation (`propagate_and_drop`)

**Precondition.** `Let(names, Values(vs), body)` with `length(names) == length(vs)` — a binding
whose `rhs` is a list of **atomic `Value`s** (the shape const-fold and the frontend produce).
**Postcondition.** Each `name_i` is substituted by `v_i` throughout `body`, and the binding is
**dropped** (`Values` is pure — `effect.is_pure(rhs) == Pure` — and after substitution the names
are dead): the whole `Let` rewrites to `subst(body, names ↦ vs)`.

Propagating *and* dropping in one step keeps the pass strictly size-reducing (§I) and matches how
const-fold feeds it: `Let([x], Num(IAdd,[c1,c2]), k)` --fold--> `Let([x], Values([c3]), k)`
--prop--> `subst(k, x ↦ c3)`.

**Soundness (unique-name / per-iteration-SSA invariant, D6 / resolved open-Q#1).** A name denotes
**one** value in its scope: params/locals/`let`s are unique within a function, and a loop variable
is rebound **only** at the `Continue` back-edge, which begins a *fresh* iteration with fresh
bindings. Hence within any straight-line region a `Var(y)` re-reads the same bits everywhere it is
in scope, so substituting a *reference* `v` (constant or `Var`) for `x` is value-exact — even when
`v = Var(y)` and `y` is a loop variable (both the original `x` and the substituted `y` read *that
iteration's* `y`). We substitute references, never snapshots, so no capture or staleness arises.
Only atomic `Value` right-hand sides are propagated; a non-`Values` `rhs` (which might duplicate a
computation or an effect) is left to dead-`let` (§D), never copied.

---

## D. Dead-`let` elimination (`dead_let`) — the F3 gate

**Precondition.** `Let(names, rhs, body)` where (i) **no** `name_i` occurs free in `body`, and
(ii) `effect.is_pure(rhs) == Pure`. **Postcondition.** The binding is removed: rewrite to `body`.

Clause (ii) is the load-bearing safety boundary (F3 / E6). An `rhs` that stores memory
(`MemStore`), writes a global (`GlobalSet`), grows memory (`MemGrow`), calls
(`CallDirect`/`CallIndirect`/`CallHost`), charges fuel (`Charge`), traps (`Trap`), **or can trap**
(the trapping `Num`/`Convert` ops) is **not** pure and is therefore **never** dropped, even when
its result is unused — its `let _ = effect in …` sequencing must survive (E1). This is the one
pass whose correctness rests entirely on unit 02 being sound in the *effectful* direction; the
verification suite pins that (`is_pure(MemStore(..)) == False`, `is_pure(Num(IDivS,..)) == False`).

Multi-name bindings are eliminated only when **all** names are dead (a value-projection that keeps
some results is out of baseline scope — state it, do not half-do it). A single-name pure dead
`let` is the overwhelmingly common case (it is what const-fold + prop leave behind).

---

## E. Dead-code / unreachable elimination (`dce`)

**Precondition.** `Let(names, rhs, body)` where `rhs` is **non-returning** —
`Trap` / `Return` / `Break` / `Continue`. **Postcondition.** `body` is unreachable (ANF evaluates
`rhs` first and it diverts control), so rewrite to `rhs` alone.

The dominant driver is const-fold's `Let(_, Trap(reason), body) → Trap(reason)`. This does **not**
violate F3's "no DCE of an effect": F3 forbids dropping an effect that *would* execute; here `body`
is *provably never reached*, so its (possibly effectful) contents — including any `Charge` — never
run and removing them changes nothing observable, fuel included (§ soundness note). A complementary
peephole: `If(cond, r, Trap(x), Trap(x))` with a pure `Value` `cond` and identical trap arms → 
`Trap(x)` (both outcomes are the same divergence); kept minimal.

---

## F. Algebraic identities (`algebraic`) — only the provably-safe set

Because the IR is **ANF**, every operand of a `Num`/`Convert` is an **atomic `Value`** (`Var` or
`Const*`): reading it has **no side effect and cannot trap**. So the mandate's "only if `x` is pure
and cannot trap" caveat is *automatically satisfied* — operand-level identities are unconditional.
Two operand shapes drive the rewrites: a **specific constant** operand, or two **syntactically
equal** `Value` operands (trivial equality on atoms).

**Safe integer identities** (bit-exact under two's-complement wrap — verify against `rt_num`):

| Constant-operand | → | | Identical-operand `[x,x]` | → |
|---|---|---|---|---|
| `IAdd/IOr/IXor [x,0]`,`[0,x]` | `x` | | `ISub [x,x]`, `IXor [x,x]` | `0` |
| `ISub [x,0]` | `x` | | `IAnd [x,x]`, `IOr [x,x]` | `x` |
| `IMul [x,1]`,`[1,x]` | `x` | | `IEq [x,x]` | `1` (`ConstI32`) |
| `IMul/IAnd [x,0]`,`[0,x]` | `0` | | `INe [x,x]` | `0` |
| `IAnd [x, 2ⁿ−1]` | `x` | | `ILt{S,U}/IGt{S,U} [x,x]` | `0` |
| `IOr [x, 2ⁿ−1]` | `2ⁿ−1` | | `ILe{S,U}/IGe{S,U} [x,x]` | `1` |
| `IShl/IShr{S,U}/IRotl/IRotr [x,0]` | `x` | | | |
| `IDiv{S,U} [x,1]` | `x` | | | |
| `IRem{S,U} [x,1]` | `0` | | | |
| `IDiv{S,U}/IRem{S,U} [_,0]` | `Trap(IntDivByZero)` | | | |

Rationale for the trapping arms: `/1` and `%1` never trap (`INT_MIN/1` is in range;
`x % 1 == 0`), so they are safe identities; division by a **literal 0** always traps
`IntDivByZero` regardless of the dividend, so rewriting to `Trap` is sound *and* exposes §E. A
shift/rotate by count `0` is identity because `rt_num.shift_count(0, N) == 0`.

**Explicitly EXCLUDED (unsound — encode these as *negative* tests):**

- `IDivS [x, -1] → 0 − x` — `INT_MIN / -1` traps `IntOverflow`; the negation would not
  (exec/numerics `idiv_s`). Never rewrite division by `-1`.
- **All float arithmetic identities** — `FAdd/FSub [x, ±0.0]`, `FMul/FDiv [x, 1.0]`, etc. Per
  `rt_num.fadd`/`fmul`, `-0.0 + +0.0 = +0.0 ≠ -0.0` and any NaN operand yields the *canonical*
  NaN, which differs from a non-canonical `x`. `x ∘ id` is therefore **not** the identity on the
  `-0.0`/NaN corners. Fold only when *both* float operands are constant (§B).
- **Float reflexive comparisons** — `FEq/FLt/… [x,x]`: for `x = NaN`, `x ≠ x` (`f*.eq` is `0`,
  `f*.ne` is `1`). Excluded; the integer reflexive identities above do **not** apply to floats.

**Safe but deferred (documented so a later agent knows they are sound):** the pure sign-bit
idempotents `FNeg(FNeg x) → x`, `FAbs(FAbs x) → FAbs x`, `FAbs(FNeg x) → FAbs x` — bit-exact
because `rt_num.f*_neg`/`f*_abs` are pure sign-bit ops that do **not** canonicalize NaN. They need
a `Let`-chain / value-map lookup (the two `FNeg`s sit in separate ANF bindings), so they are
listed here as a safe extension, optionally registered; the core `algebraic` pass stays a clean
`per_expr` operand-level rewrite.

---

## G. Block / label simplification (`block_simplify`) — D6

Consistent with the named-label IR (D6 — labels are unique per function, so no shadowing; a simple
"does `Break(l,_)`/`Continue(l,_)` occur in this body" scan is exact). Spec anchor: the label/branch
semantics of [exec/instructions §Control](https://webassembly.github.io/spec/core/exec/instructions.html).

1. **Transparent-block merge.** `Block(l, result, body)` where `body` contains **no** `Break(l, _)`
   → replace with `body`. A block's only role is to be a break target; with no break to `l`,
   falling off the end yields exactly what evaluating `body` yields. (Drops the now-useless label.)
2. **Non-iterating loop → block.** `Loop(l, params, result, body)` where `body` contains **no**
   `Continue(l, _)` → the loop runs once: bind each param to its `init` and wrap `body` in a block
   carrying `l`, i.e. `Let([p.name…], Values([p.init…]), Block(l, result, body))`. `Break(l, vs)`
   still exits with `vs`; fall-through still yields `result`. Sound and it de-loops dead loops.
3. **Tail-break peephole.** `Block(l, result, Break(l, vs))` → `Values(vs)` (breaking to the block
   you are about to fall off of is just yielding `vs`).

None of these drops or reorders an *executed* effect — the block/loop body is preserved verbatim
(cases 1–2) or replaced by the values it would have produced (case 3) — so F3 is untouched.

---

## H. Constant-condition `if` / `switch` (`const_condition`)

**`If`.** `If(cond, result, then_branch, else_branch)` where `cond` is a constant `Value`
(`ConstI32(n)`, per resolved open-Q#2 the condition is an i32 truth value the emitter tests `≠ 0`)
→ replace with `then_branch` when `n ≠ 0`, else `else_branch`. **`Switch`.**
`Switch(selector, result, arms, default)` with a constant `selector = ConstI32/I64(k)` → replace
with the body of the arm whose `match == k`, else `default`.

**Soundness vs F3.** This is the one baseline rewrite that discards a subtree which *may contain
effects* — and it is sound precisely because that subtree is **statically unreachable**: with a
constant condition the not-taken branch never executes at run time either, so its effects (and any
`Charge`) never fire. F3 forbids eliminating an effect that *would* run; a dead branch's effects
would not. Const-prop (§C) is what turns a `Var` condition bound to a constant into the literal
this pass fires on, so the two compose across the fixpoint.

---

## I. Pass ordering, fixpoint, and termination

**Order (one round of `baseline_passes()`):** const-fold → copy/const-prop → algebraic →
const-`if`/`switch` → block/label → DCE → dead-`let`. The order is chosen so each pass feeds the
next: folding exposes constants for prop; prop turns `Var` conditions into literals for const-`if`;
const-`if` deletes branches, making blocks transparent and `let`s dead; DCE collapses trap sequels;
dead-`let` clears the pure bindings prop left behind.

**Fixpoint.** Unit 01's `run_pipeline(module, passes)` repeats the whole ordered list until a full
round leaves the module structurally unchanged (`==`, cheap on plain-data IR) or `max_rounds` (a
documented safety valve) is hit. A single round rarely reaches the fixpoint — folding an operand
deep in a tree can unlock a const-`if` several rounds later — so iteration is required and provided.

**Termination (the measure, not the valve).** Assign each module the lexicographic measure

```
μ(m) = ( n_loops , n_ops , n_nodes , n_vars )
```

where `n_loops` = number of `Loop` Expr nodes, `n_ops` = number of `Num`/`Convert` Expr nodes,
`n_nodes` = total Expr nodes, `n_vars` = total `Var` occurrences. Every baseline rewrite is
**non-increasing** in `μ`, and any rewrite that *changes* the module strictly decreases it:

- **const-fold / algebraic** replace a `Num`/`Convert` with `Values`/`Trap`/an operand →
  `n_ops` strictly ↓ (one fewer operation node); create no `Loop` and add no `Var`, so `n_loops`
  is unchanged.
- **copy/const-prop** (propagate-**and-drop**) removes one `Let` node → `n_nodes` strictly ↓ (with
  `n_loops`/`n_ops` unchanged); a constant substitution also ↓ `n_vars`; it never adds an op, a
  node, or a `Loop`.
- **const-`if`/`switch`, DCE, dead-`let`, and the transparent-block-merge / tail-break cases of
  block/label** each remove ≥ 1 Expr node while creating no `Loop` and no op → `n_loops`/`n_ops`
  unchanged, `n_nodes` strictly ↓. (Discarding a dead branch may *additionally* drop a `Loop`,
  which only ever lowers `n_loops` further.)
- **de-loop (block/label §G.2, non-iterating `Loop` → `Block`)** is the one baseline rewrite that
  *adds* nodes — it wraps the body as `Let([p…], Values([init…]), Block(l, …))` — but it removes
  exactly one `Loop`, so `n_loops` strictly ↓. Because `n_loops` is the **most-significant**
  component, the extra `Let`/`Block` nodes cannot offset it: `μ` still strictly decreases.

Critically, **no baseline pass ever constructs a `Loop`** — folding, propagation, branch selection,
the block/label merges, and every elimination only remove or shrink structure; de-loop is the sole
pass that touches a `Loop`, and it strictly *removes* one. So `n_loops` is monotonically
non-increasing across every round and de-loop can never be undone. `μ` is bounded below by
`(0,0,0,0)`, so only finitely many *changing* rounds occur and `run_pipeline` reaches the fixpoint
well before `max_rounds`; the valve exists only to bound a hypothetical bug, never the correct
execution (keystone A.2). No pass can undo another (each moves the program toward a strictly smaller
`μ`), so ping-ponging is impossible.

---

## Effect / soundness / metering note

- **F2 is the bar, proven per pass.** Each pass has its own semantics-preservation property test
  (asserting *what it must preserve* against the WASM spec, never the current output — D8), and
  unit 11 runs the corpus-wide `optimize(m) ≡ m` differential at `Baseline` (and `Aggressive`,
  which contains these passes). "Done" = those suites pass.
- **F3 is respected structurally.** Only dead-`let` consults `is_pure`, and it consults it to
  *refuse* dropping effects; const-`if` and DCE drop only **statically unreached** code; fold /
  algebraic / block-label neither drop nor reorder any *executed* effect. No load is ever reused
  across a store, because no baseline pass performs CSE or motion of an effectful node at all.
- **F5 metering is preserved.** `ir_opt` runs *after* `ir_lower`, so in Safe it sees `Charge`
  nodes. `Charge` is effectful (unit 02), hence never dead-`let`-eliminated and never reordered;
  the only `Charge`s baseline ever removes are those on **provably-unreached** paths (a dead branch
  or a post-`Trap` sequel), which contribute **zero** runtime fuel. So the fuel consumed on every
  executed path — and thus the deterministic `FuelExhausted` bound — is unchanged. In Unsafe
  (`MeterOff`) there are no `Charge` nodes at all; baseline behaves identically, just with fewer
  barriers.
- **No ambient authority introduced (D3a).** Baseline is pure IR→IR rewriting; it emits no calls
  and no `apply`, and it never fabricates a host/BIF target.

---

## Verification (Definition of Done — D8)

Tests assert **spec behavior**, cite the spec, and are **not** change-detectors. "Done" = the
suite below passes — never "it compiles".

1. **Const-fold ≡ `rt_num`, bit-exact (F2/D7).** For a representative set across every op family
   (incl. the corner vectors: `i32.add` wrap at `0xFFFFFFFF+1`, `i32.mul` overflow, signed `shr`
   sign-fill, `f64.add` overflow → `+Inf`, `f32.mul` producing canonical NaN, `-0.0`
   round-trips, `f*.min(+0,-0) = -0`, `reinterpret` bit-identity): assert
   `optimize(Num(op,[consts]))` yields `Values([Const])` whose bits **equal** the direct `rt_num`
   call. Property test: random constants, `fold ≡ rt_num` for all folded ops.
2. **Trapping fold (F2).** `i32.div_s(_, 0)` and `i32.div_s(INT_MIN, -1)` and `i32.trunc_f32_s(NaN)`
   with constant operands fold to `Trap(IntDivByZero)` / `Trap(IntOverflow)` /
   `Trap(InvalidConversionToInteger)` respectively — the *same* `TrapReason` `rt_num` returns —
   never to a value. (exec/numerics.)
3. **prop + dead-`let` + F3 (adversarial "must NOT").** `Let([x], Values([c]), body)` propagates
   and drops; a pure dead `let` is removed; but a `Let([_], MemStore(..), body)` /
   `GlobalSet` / `CallHost` / `Charge` / `Num(IDivS,..)` with an unused result is **retained**
   (assert the node survives `optimize`). These are the fixtures the optimizer must *not* break.
4. **Algebraic — positive & negative.** `x+0`, `x*1`, `x*0`, `x&x`, `x^x`, `x<<0`, `x/1`, `x%1`,
   `x/0 → Trap`, reflexive int compares → their identities; and **negative** tests that
   `IDivS[x,-1]`, `FAdd[x,+0.0]`, `FMul[x,1.0]`, and `FEq[x,x]` are **left unchanged** (proving we
   excluded the `-0.0`/NaN/overflow hazards).
5. **Block/label & const-`if` (D6).** A block with no break to its label collapses to its body; a
   loop with no `Continue` de-loops; `If(ConstI32(1), …)` selects the then-branch and *discards*
   an effectful else-branch (allowed — unreached), while `If(Var, …)` is untouched.
6. **Fixpoint / termination.** A nested constant expression (e.g. `((2*3)+4) < 100` guarding a
   loop) optimizes to a single constant / eliminated loop in ≤ `max_rounds`; a random-IR fuzz
   battery never fails to converge and never panics.
7. **Both profiles green + honest DoD.** `gleam format --check src test` clean; `gleam build`
   **zero warnings** (no `todo`/`panic`/`let assert` on any path — every pass total); `gleam test`
   green (≥ current count); every public fn/type carries a `///` contract doc.

**Proof of goal:** const-fold bit-exact to `rt_num` on the corner vectors, each pass individually
semantics-preserving with a spec-cited test, the F3 "must-NOT" fixtures intact, and the Baseline
pipeline converging — so unit 11's corpus-wide `optimize(m) ≡ m` differential stays byte-identical
with identical traps under **both** profiles.

---

## What this unit leaves for others

- **Unit 04** consumes `baseline_passes()` to build `pipeline(Aggressive) = baseline_passes() ++
  aggressive_passes()` (strict superset), and inherits the traversal/measure conventions here; its
  extra passes (inlining, `Charge`-elision) each document a trust assumption — none is needed by
  anything in this unit.
- **Unit 02 requirement (flag).** For §D to be sound, `effect.is_pure`/`classify` **must** return
  non-`Pure` for every potentially-*trapping* node — the trapping `Num` ops
  (`IDivS/IDivU/IRemS/IRemU`), the trapping `Convert`s (`TruncS/TruncU`), and `Trap` itself — in
  addition to the E6 state/`CallHost`/`Charge` barriers. (No keystone signature change: this lives
  in unit 02's classifier body.) The verification suite pins the effectful direction so a future
  narrowing of unit 02 cannot silently make a dropped trap slip through.
- **Unit 11** wires this Baseline pipeline (via `optimize(m, Baseline)` in Safe and, transitively,
  `Aggressive` in Unsafe) into the corpus-wide + spec-suite differential and refreshes the
  conformance image; the per-pass property tests here are its per-pass evidence.
