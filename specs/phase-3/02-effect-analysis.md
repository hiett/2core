# Unit 02 — IR effect & purity analysis (`ir/effect.gleam`)

> **One owner: `src/twocore/ir/effect.gleam`. Realizes F3 (E6 made concrete and
> enforced). On the critical path — it gates 03 and 04.** Read
> [`00-overview.md`](00-overview.md) (F1–F8, esp. **F3**) and the keystone
> [`01-interface-freeze.md`](01-interface-freeze.md) §A.3 first, then
> [`phase-1/00-overview.md`](../phase-1/00-overview.md) (D3a/D4/D5/D6) and
> [`phase-2/00-overview.md`](../phase-2/00-overview.md) (**E6**). The keystone froze the
> classifier's **signature** with maximally-conservative bodies (everything `Effectful`);
> this unit replaces those bodies with the real, still-conservative purity analysis and
> adds the optimizer-facing predicates 03/04 gate their rewrites on. **A single unsound
> `Pure` verdict is a silent memory-corruption bug**, so the whole unit is built and tested
> to make the *false-`Pure`* direction impossible.

---

## Deliverables & freeze milestones

**Consumes** (the frozen keystone surface — bind exactly, never re-shape):
`ir/effect.gleam`'s `type Effect { Pure Effectful }`, `classify/1`, `is_pure/1`,
`is_effectful_node/1`, `function_is_pure/1` (all `«IROPT-IFACE-FROZEN»`, §A.3), plus the
full `ir.Expr`/`NumOp`/`ConvOp`/`TrapReason` surface from `«IR2-FROZEN»` (read-only).

**Produces** — the same file, with real bodies + three additive predicates:

1. **The classification** — `is_effectful_node/1` + `classify/1` + `is_pure/1` bodies that
   assign every `Expr` variant to `Pure` or `Effectful` per §B, sound and conservative.
2. **The optimizer-facing predicates** (single-owner-additive on this file, §D):
   `can_reorder/2`, `can_cse/1`, `can_eliminate_if_unused/1`, and the `function_is_pure/1`
   body. These are the *only* surface 03/04 are allowed to gate a rewrite on.
3. **The adversarial fixture suite** (`test/twocore/ir/effect_test.gleam`, new, owned here)
   — the "the classifier must NOT say this" tests (§G).

**Gates:** 03 (baseline passes) and 04 (aggressive passes) both build on these predicates;
until this unit lands green, the freeze optimizer is a strict identity (every node
`Effectful`) and no pass may narrow. **This unit does not touch `ir_opt.gleam`**, any
runtime module, or `ir.gleam` — it is one file plus its test.

---

## A. Scope, and the one-directional error budget

`classify` answers exactly one question: **may the optimizer treat this expression as if it
had no observable effect?** "Observable" is fixed by F2: the returned values (by **bit
pattern**, D5/D7 — NaN payload / `-0.0` / wrap exact), the trap (its `TrapReason` and
whether one occurs at all), the final memory/global state, and — under Safe — the fuel
consumed. Anything a rewrite could perturb along those axes is an **effect**.

The analysis is deliberately **asymmetric** (F3):

- A **false `Effectful`** (calling an inert node effectful) costs a *missed optimization*.
  Free. The freeze optimizer is entirely false-`Effectful` and is trivially sound.
- A **false `Pure`** (calling a side-effecting or trapping node inert) lets a downstream
  pass delete a store, CSE a load across a write, hoist a trap above its guard, or drop a
  charge — **silent memory corruption or a wrong answer.** Catastrophic.

So every judgement defaults to `Effectful` and is narrowed to `Pure` **only with a
structural proof** (the node is not a barrier *and* every sub-expression is provably
`Pure`). This is the "conservative default: unknown/compound ⇒ effectful unless the node
itself is pure **and** all children are pure" rule from the mandate. The analysis is purely
structural on `Expr` (no `Module`, no runtime binding — matching the frozen `classify(Expr)`
signature), and total: every variant is covered, nothing panics.

---

## B. The classification — every `Expr` variant

The table is the contract. `SHALLOW` is `is_effectful_node` (this node alone, ignoring
sub-expressions); `DEEP` is `classify`/`is_pure` (this node *and* all sub-expressions).

| `Expr` variant | SHALLOW barrier? | DEEP `Pure` when… | Why (spec) |
|---|---|---|---|
| `Values(vs)` | no | always | forwards atomic operands; reads/writes nothing |
| `Num(op, _)`, `op` **non-trapping** | no | always | total function of operands (arith/bitwise/shift/cmp/**all float ops**) |
| `Num(op, _)`, `op ∈ {IDivS,IDivU,IRemS,IRemU}` | **yes** | never | **traps** on `/0` and `div_s INT_MIN/-1` — WASM §4.3.2 |
| `Convert(op, _)`, `op` **non-trapping** | no | always | total (wrap/extend/reinterpret/`trunc_sat`/`convert_*`/demote/promote/box) |
| `Convert(op, _)`, `op ∈ {TruncS,TruncU}` | **yes** | never | **traps** on NaN/±∞/out-of-range — WASM §4.3.3 |
| `TermOp(_, _)` | no | always | pure term construct/destructure (no instance state) |
| `MemSize` | **yes** | never | reads mutable memory size (E6) — not stable across `MemGrow` |
| `MemGrow(_)` | **yes** | never | mutates memory (E6) |
| `MemLoad(_, _, _, _)` | **yes** | never | reads mutable memory + **traps** OOB (E6; WASM §4.4.7) |
| `MemStore(_, _, _, _)` | **yes** | never | writes memory + **traps** OOB (E6; WASM §4.4.7) |
| `GlobalGet(_)` | **yes** | never | reads a mutable global (E6) |
| `GlobalSet(_, _)` | **yes** | never | writes a mutable global (E6) |
| `CallDirect(_, _)` | **yes** | never* | callee may read/write state, trap, host-call, charge, diverge |
| `CallIndirect(_, _, _, _)` | **yes** | never | target unknown; may do anything + **traps** (3 faults) |
| `CallHost(_, _, _)` | **yes** | never | the capability boundary (host effect) |
| `Let(_, rhs, body)` | no | `rhs` **and** `body` pure | shell adds no effect; sequences its parts |
| `Block(_, _, body)` | no | `body` pure | shell adds no effect |
| `If(_, _, t, e)` | no | `t` **and** `e` pure | cond is a `Value`; branches decide |
| `Switch(_, _, arms, d)` | no | every arm **and** `d` pure | selector is a `Value`; bodies decide |
| `Loop(_, _, _, _)` | **yes** | never | may **not terminate** — divergence is observable (F2) |
| `Break(_, _)` / `Continue(_, _)` / `Return(_)` | **yes** | never | control transfer — never eliminable/reorderable |
| `Trap(_)` | **yes** | never | aborts execution |
| `Charge(_, _)` | **yes** | never | fuel effect (F5); ordered, never elided at Baseline |

\* `CallDirect` is *unconditionally* `Effectful` in `classify` because `classify` sees only
an `Expr` and cannot resolve `fn_name` to its callee. The interprocedural escape hatch is
`function_is_pure` (§D), which a pass may consult when it *does* hold the callee's
`Function`.

### B.1 The trapping-op refinement of the keystone (deliberate, documented)

The keystone's `is_effectful_node` doc-comment enumerates `Num`/`Convert` broadly as
non-barriers. **This unit refines that**: the two trapping subsets — `Num` with
`IDivS/IDivU/IRemS/IRemU` and `Convert` with `TruncS/TruncU` — are barriers. This is
*strictly more conservative* than the keystone's enumeration (it never narrows anything the
keystone called effectful), so it is within this unit's remit ("narrow `Effectful→Pure`
only with proof; more conservative is always sound") and requires **no keystone signature
change**. The set is not invented here: `emit_core` already isolates exactly these ops as
the ones that route through `rt_num`'s `Result(Int, TrapReason)` (`is_trapping/1` at
`emit_core.gleam:1530`, `is_trapping_conv/1` at `:1577`) — the effect classifier reuses the
same authoritative partition. A trapping `div` is **referentially transparent** (same
inputs → same result-or-trap) yet **not inert**: deleting it, or hoisting it onto a path
where it did not originally evaluate, *adds or removes a trap*. That is an observable change
(F2), so it must be `Effectful`.

Together with `Trap` itself (unconditionally a barrier), these trapping `Num`
(`IDivS/IDivU/IRemS/IRemU`) and `Convert` (`TruncS/TruncU`) subsets form the **trap-bearing
barrier set**. Because unit 03's dead-`let` elimination drops a binding *only* when
`is_pure(rhs) == True`, classifying every trap-bearer `Effectful` here is precisely what
guarantees **dead-`let` can never drop an observable trap** (F2 counts trap-or-not among the
observables — see §D). This is a *body-only* refinement of the keystone's `is_effectful_node`:
strictly more conservative, no signature change (§A.3).

---

## C. `is_effectful_node`, `classify`, `is_pure` — the bodies

`is_effectful_node` is the shallow primitive; `classify` layers the deep recursion on top;
`is_pure` is the boolean face of `classify`. Coverage mirrors the printer's `print_expr`
traversal (`printer.gleam:300`) variant-for-variant, so exhaustiveness is load-bearing and
compiler-checked (a missed arm fails the build — never a silent `Pure`).

```gleam
//// src/twocore/ir/effect.gleam — the shared purity/effect classifier (F3, unit 02).
//// Conservative: anything not *proven* pure is `Effectful`. The optimizer must never
//// rewrite across an effect barrier (E6): no CSE of a load past a store, no reorder past
//// a MemGrow/GlobalSet/CallIndirect/CallHost/Charge/Trap, no DCE of an effect.
import gleam/list
import twocore/ir.{
  type ConvOp, type Expr, type Function, type NumOp, Block, Break, CallDirect,
  CallHost, CallIndirect, Charge, Continue, Convert, GlobalGet, GlobalSet, IDivS,
  IDivU, IRemS, IRemU, If, Let, Loop, MemGrow, MemLoad, MemSize, MemStore, Num,
  Return, Switch, TermOp, Trap, TruncS, TruncU, Values,
}

pub type Effect {
  Pure
  Effectful
}

/// SHALLOW barrier test (F3): does THIS node — ignoring its sub-expressions — read or
/// write mutable instance state, call out, meter, trap, transfer control, or possibly
/// diverge? The primitive `classify` is built on, and the fast test a pass uses to find
/// the nearest barrier in a straight-line sequence.
///
/// Barriers (`True`): the E6/F3 state ops + the three call kinds + `Charge` + `Trap` +
/// the non-returning transfers + `Loop` (may not terminate) + the TRAPPING `Num`/`Convert`
/// subsets (§B.1). Non-barriers (`False`): `Values`, non-trapping `Num`/`Convert`,
/// `TermOp`, and the `Let`/`Block`/`If`/`Switch` shells — their DEEP verdict is decided by
/// their sub-expressions in `classify`, not here.
pub fn is_effectful_node(e: Expr) -> Bool {
  case e {
    MemSize
    | MemGrow(_)
    | MemLoad(_, _, _, _)
    | MemStore(_, _, _, _)
    | GlobalGet(_)
    | GlobalSet(_, _)
    | CallDirect(_, _)
    | CallIndirect(_, _, _, _)
    | CallHost(_, _, _)
    | Charge(_, _)
    | Trap(_)
    | Break(_, _)
    | Continue(_, _)
    | Return(_)
    | Loop(_, _, _, _) -> True
    Num(op, _) -> trapping_numop(op)
    Convert(op, _) -> trapping_convop(op)
    Values(_)
    | TermOp(_, _)
    | Let(_, _, _)
    | Block(_, _, _)
    | If(_, _, _, _)
    | Switch(_, _, _, _) -> False
  }
}

/// The four TRAPPING integer ops — `div`/`rem`, signed & unsigned — trap on a zero divisor,
/// and `div_s` additionally on `INT_MIN / -1` (WASM spec §4.3.2). Mirrors `emit_core`'s
/// `is_trapping/1`. Every other `NumOp` (arithmetic, bitwise, shifts, comparisons, and ALL
/// float ops — IEEE never traps) is total.
fn trapping_numop(op: NumOp) -> Bool {
  case op {
    IDivS(_) | IDivU(_) | IRemS(_) | IRemU(_) -> True
    _ -> False
  }
}

/// The two TRAPPING float→int conversions — `trunc_s`/`trunc_u` trap on NaN, ±∞, or an
/// out-of-range magnitude (WASM spec §4.3.3). Mirrors `emit_core`'s `is_trapping_conv/1`.
/// The saturating `trunc_sat_*`, width/sign extends, reinterpret, `convert_*`,
/// demote/promote, and the term↔numeric boxing bridge are all total value transforms.
fn trapping_convop(op: ConvOp) -> Bool {
  case op {
    TruncS(_, _) | TruncU(_, _) -> True
    _ -> False
  }
}

/// DEEP classification (F3): `Pure` iff `e` is a non-barrier node AND every sub-expression
/// is `Pure`. The optimizer uses this to decide whether a whole subtree may be
/// folded / CSE'd / eliminated. Total; conservative — see §A.
pub fn classify(e: Expr) -> Effect {
  case is_effectful_node(e) {
    True -> Effectful
    False ->
      case children_all_pure(e) {
        True -> Pure
        False -> Effectful
      }
  }
}

/// Are all of `e`'s SUB-EXPRESSIONS pure? Only the non-barrier recursive shells
/// (`Let`/`Block`/`If`/`Switch`) have sub-expressions; every other non-barrier node
/// (`Values`/`Num`/`Convert`/`TermOp`) is atomic over `Value`s and so has none (vacuously
/// `True`). Barriers never reach here — `classify` short-circuits — so `Loop`/`Charge` need
/// no arm.
fn children_all_pure(e: Expr) -> Bool {
  case e {
    Let(_, rhs, body) -> is_pure(rhs) && is_pure(body)
    Block(_, _, body) -> is_pure(body)
    If(_, _, then_branch, else_branch) ->
      is_pure(then_branch) && is_pure(else_branch)
    Switch(_, _, arms, default) ->
      is_pure(default) && list.all(arms, fn(a) { is_pure(a.body) })
    _ -> True
  }
}

/// `True` iff `classify(e) == Pure`. The master safety oracle (§D).
pub fn is_pure(e: Expr) -> Bool {
  classify(e) == Pure
}
```

`Value` operands (`Var`/`Const*`) never appear as `Expr` and need no arm: a `Var` reads an
SSA-bound local (immutable within the function — not mutable instance state), and a `Const`
is immediate. That is why the state barriers (`MemStore`, `GlobalSet`, …) can be leaves for
the recursion even though they carry `Value`s — those `Value`s are always inert.

---

## D. The optimizer-facing predicates (what 03/04 are allowed to call)

`classify`/`is_pure`/`is_effectful_node` are the *analysis*. Passes should gate their
rewrites on the **named predicates** below, whose names *are* their soundness contract, so a
call site reads as its intent and a future refinement changes one body, not every caller.
This is the "equivalent minimal set" the mandate asks for — justified inline.

```gleam
/// May a `let names = e in body` whose bound `names` are ALL dead in `body` drop the
/// binding (and `e`)? Only when `e` has nothing to preserve — no state write, host call,
/// fuel charge, trap, divergence, or control transfer — i.e. exactly `is_pure`. An
/// effectful `e` (a `MemStore`, a `Charge`, a trapping `div`, a `CallHost`) is KEPT even
/// though its result is unused: E1's ordered `let _ = effect in …` sequencing is
/// load-bearing (F3, "no DCE of an effect").
pub fn can_eliminate_if_unused(e: Expr) -> Bool {
  is_pure(e)
}

/// May occurrences of `e` be shared / hoisted to a common dominator (CSE / value
/// numbering)? Sound only for a `Pure` `e`: it computes the same value in any position and
/// introduces no trap or divergence at the hoist point. A `MemLoad`/`GlobalGet` is NOT pure
/// (it reads mutable state), so this is `False` — the classifier **forbids ALL load/global
/// CSE in Phase 3**. That is a conscious, sound under-approximation (F8): precise load-CSE
/// ("no aliasing store between the two occurrences") needs an alias + reordering analysis
/// scoped as later work. It makes "a load is never CSE'd across a store" hold the strongest
/// way — a load is never CSE'd *at all*.
pub fn can_cse(e: Expr) -> Bool {
  is_pure(e)
}

/// May two ADJACENT, data-INDEPENDENT expressions `a` then `b` swap without changing
/// observable behavior? Yes iff at least one is pure: a pure expression commutes with
/// everything (reads/writes no state, cannot trap or diverge). Two barriers — two stores, a
/// load and a store, a grow and a load, a `Charge` and anything, a `Trap` and anything —
/// keep their order.
///
/// CONTRACT: the caller MUST separately ensure `b` uses no name `a` binds (no data
/// dependency). This predicate answers the EFFECT-ORDERING question only. It uses the DEEP
/// `is_pure`, NEVER the shallow `is_effectful_node`: a `Block` whose body hides a `MemStore`
/// is a non-barrier NODE yet is not reorderable.
pub fn can_reorder(a: Expr, b: Expr) -> Bool {
  is_pure(a) || is_pure(b)
}

/// `True` iff `f`'s whole body is pure — the interprocedural escape hatch (pure-callee
/// reasoning for inlining, unit 04, and pure-call CSE). CONSERVATIVE: it does NOT chase
/// callees, so a body containing any `CallDirect`, `Loop`, state op, or trapping op is
/// `False` even if that callee is itself pure. A call-graph fixpoint on top is unit 04's
/// choice, not this unit's obligation.
pub fn function_is_pure(f: Function) -> Bool {
  is_pure(f.body)
}
```

**Why exactly these.** `can_eliminate_if_unused` and `can_cse` are intentionally thin
aliases of `is_pure` — same value today, distinct *contracts* and distinct future refinement
points (load-CSE will one day relax `can_cse` without touching DCE). `can_reorder` is the one
new shape (`||` over two deep purities); `function_is_pure` is the frozen interprocedural
hook. Anything finer (aliasing, range facts, termination) is out of Phase-3 scope (F8) and
builds *above* this module, never by weakening it.

---

## E. Soundness argument

**Safety invariant.** For every `Expr e`, if `is_pure(e) == True` then evaluating `e` is
*observationally inert modulo its result value*: it (a) reads no mutable instance state,
(b) writes none, (c) makes no host call, (d) consumes no fuel, (e) cannot trap, (f) cannot
diverge, and (g) performs no control transfer. Therefore `e` may be duplicated, deleted,
reordered against any other expression, hoisted, or sunk with **no** change to any F2
observable (returned bits, trap reason/occurrence, memory & global final state, fuel).

**Proof (structural induction on `Expr`).** The barrier set `is_effectful_node` is, by
construction, *exactly* the set of nodes that can themselves do any of (a)–(g) at this node:
the E6 state ops do (a)/(b) (WASM §4.4.7, §4.2 store model); the three call kinds and
`CallHost` may do all of (a)–(g); `Charge` does (d) (F5); `Trap` and the trapping
`Num`/`Convert` do (e) (WASM §4.3.2/§4.3.3); `Break`/`Continue`/`Return` do (g); `Loop` may
do (f). `classify` returns `Pure` only when `is_effectful_node(e) == False` **and**
`children_all_pure(e)`. *Base cases* (`Values`, non-trapping `Num`/`Convert`, `TermOp`): read
only their atomic `Value` operands and compute a total deterministic function → inert.
*Inductive cases* (`Let`/`Block`/`If`/`Switch`): the shell adds no effect and is `Pure` only
when every sub-expression is `Pure`, which by the IH is inert; a composition of inert
sub-terms with an effect-free shell is inert. Every node that could violate (a)–(g) is in the
barrier set and is therefore classified `Effectful`, never `Pure`. ∎

**Conservative (safe) direction.** `classify` may return `Effectful` for a node that is in
fact inert — a provably-terminating pure `Loop`, a `div` by a known-non-zero constant, a
`CallDirect` to a pure helper. Each costs a missed optimization, never soundness; `Pure` is
only ever *earned*. This is the boundary F3 makes the optimizer's DoD: 03 may rewrite only
`is_pure` subtrees; 04 may relax a *named* barrier only under a documented trust assumption
that cannot change a corpus result (e.g. `Charge`-elision when metering is off) — neither may
override a verdict from this module.

---

## F. Effect / soundness / security note

- **No ambient authority (D3a) is affected.** This module reads structure only; it grants no
  capability and performs no `apply`. It exists to *restrain* the optimizer.
- **Fail-closed (D4).** The judgement fails toward `Effectful`. If a future `Expr` variant is
  added, the exhaustive `case`s here **fail to compile** until it is classified — the build
  gate prevents an unclassified (and therefore silently-optimizable) node from ever existing.
- **Bit-exact semantics (D5/D7).** "Same value" throughout means same **bit pattern**; the
  analysis never inspects a `Value`'s bits, so `-0.0`/NaN-payload/wrap distinctions are
  preserved trivially — a pure float op is still only reordered/deleted, never *recomputed
  differently*.
- **The trap subtlety is the crux.** The one non-obvious way to corrupt this module is to
  reason "a `div` is a pure function of its operands, therefore inert" and drop it. It is
  referentially transparent but **not** inert (it may trap). §B.1 classifies it `Effectful`
  for exactly this reason; §G pins it with a fixture.

---

## G. Adversarial tests — fixtures the classifier must NOT get wrong

Per D8 these assert **what the spec/soundness requires**, never what the body happens to
emit. Each targets a specific catastrophic misclassification. Owned in
`test/twocore/ir/effect_test.gleam`.

1. **A store is never pure.** `is_pure(MemStore(MemAccess(4, False), Var("a"), Var("v"), 0))
   == False` and `is_effectful_node(...) == True` (pins the keystone freeze forever, E6).
2. **A load is never pure / never CSE-able.**
   `is_pure(MemLoad(MemAccess(4, False), Var("a"), 0, TI32)) == False` and `can_cse(that) ==
   False` — a load is never shared across *anything*, a fortiori never across a store.
3. **An effect with an unused result is not eliminable.** `can_eliminate_if_unused` is
   `False` for `MemStore(...)`, `GlobalSet("g", Var("v"))`, `CallHost("io","print",[..])`,
   and `Charge(3, Values([]))`.
4. **A trapping `div`/`rem`/`trunc` is not pure and not eliminable** (the B.1 crux).
   `is_pure(Num(IDivS(W32), [Var("a"), ConstI32(0)])) == False`;
   `can_eliminate_if_unused(Num(IDivU(W32), [..])) == False`; `is_pure(Num(IRemS(W64), [..]))
   == False`; `is_pure(Convert(TruncS(FW64, W32), Var("x"))) == False`.
5. **Non-trapping arithmetic IS pure** (not vacuously conservative — it must enable
   Baseline). `is_pure` is `True` for `Num(IAdd(W32), [..])`, `Num(FMul(FW64), [..])`,
   `Convert(I32WrapI64, Var("x"))`, and `Values([Var("a")])`.
6. **Purity is deep, not shallow.** `Let(["t"], MemLoad(...), Values([Var("t")]))` (a
   non-barrier shell over a load) is `is_pure == False`; an `If`/`Block`/`Switch`/`Let` over
   only-pure children is `is_pure == True`.
7. **A `Loop` is never pure** (divergence): `is_pure(Loop("l", [], [], Values([]))) ==
   False`, even with an empty body — and therefore not eliminable.
8. **Control transfers are effectful.** `is_pure` is `False` for `Return([Var("x")])`,
   `Break("b", [])`, `Continue("l", [])`, and `Trap(Unreachable)`.
9. **`can_reorder` respects barriers** and is deep. two stores → `False`; a `Charge` then
   anything → `False`; a pure add then a store → `True`; a `Block` *hiding* a store does
   **not** reorder past another store (proves it uses deep `is_pure`, not the shallow node
   test).
10. **`function_is_pure` is conservative & totality holds.** a straight-line arithmetic body
    → `True`; a body with any `CallDirect`/`Loop`/`MemLoad`/trapping-`div` → `False`; and a
    corpus touching **every** `Expr` variant (reuse the round-trip corpus) classifies without
    panic — proving the `case`s are total.

---

## Verification — Definition of Done (D8)

- **Spec-cited, non-change-detector tests** — §G's fixtures, each asserting the
  spec/soundness requirement (E6, WASM §4.2/§4.3/§4.4), not the body's incidental output. The
  keystone's freeze assertions (`is_pure(MemStore) == False`, `is_effectful_node(MemStore) ==
  True`) still pass unchanged — this unit only *narrows* provably-inert nodes to `Pure`.
- **Every public function documented** (`classify`, `is_pure`, `is_effectful_node`,
  `function_is_pure`, `can_reorder`, `can_cse`, `can_eliminate_if_unused`) with contract,
  the `Pure`/`Effectful` meaning, and — for the derived predicates — what a `True` *licenses*
  and what a `False` *forbids*. The two private helpers (`trapping_numop`/`trapping_convop`)
  documented and cross-referenced to `emit_core`'s authoritative `is_trapping*`.
- **`gleam format --check src test` clean; `gleam build` zero warnings** (all bodies real, no
  `todo`, no unused binds — the exhaustive `case`s underscore what they ignore).
- **`gleam test` green** — the full suite (≥ 509) stays passing; the effect suite is added.
  "Done" = **the effect suite + the whole suite pass**, never "it compiles". The freeze
  changes no observable program behavior (F7: no IR nodes, no grammar), so conformance stays
  **1740 / 1359 / 0**.

**Proving the goal:** the false-`Pure` direction is closed by §G.1–4/7/8 (every effect/trap/
transfer/divergence node asserted non-pure and non-eliminable) and by the fail-closed
exhaustive `case` (§F); the analysis is proven *useful* (not vacuously conservative) by
§G.5–6 (non-trapping arithmetic and fully-pure shells are `Pure`); totality by §G.11.

---

## What this unit leaves

- **03 (Baseline)** gates every trust-neutral rewrite on these predicates: const-fold and
  algebraic identity fire only where `is_pure` holds (a folded `div(4,0)` becomes a `Trap`,
  never a deleted node); dead-`let` elimination uses `can_eliminate_if_unused`; block/label
  and constant-condition simplification never move a node the classifier calls a barrier.
- **04 (Aggressive)** uses `function_is_pure` for pure-callee inlining/CSE and documents, per
  pass, any barrier it relaxes (e.g. `Charge`-elision under `MeterOff`) — always *above* this
  module, never by overriding a verdict.
- **11 (capstone)** the F2 differential over the corpus is the end-to-end proof that these
  verdicts held: if any pass trusted a bad `Pure`, a corpus program changes an answer or a
  trap, and the differential fails. This module is the reason it will not.
