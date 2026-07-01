# Unit 02 — `emit_core` threaded-seam expansion (tier-P `threaded` state)

> **One owner. Wave A. The deepest codegen change of Phase 4 — the critical path.** Depends
> on **FREEZES ONLY** — `«STATE-STRATEGY-FROZEN»` (`Binding.state_strategy`, the tier-P
> `InstanceState` record, the `rt_state`/`rt_mem`/`rt_table` **threaded signatures**, and the
> `emit_core` seam-expansion contract) from the keystone (unit 01). You need those *signatures*,
> not the tier-P bodies (03/04/06), so **do not serialize behind them** — the seam emits calls
> against the frozen heads. Read [`00-overview.md`](00-overview.md) (G1–G8) and
> [`01-interface-freeze.md`](01-interface-freeze.md) (§A, the frozen surface) first, then the
> Phase-1/2/3 overviews (D1–D10, E1–E8, F1–F8). Analog format:
> [`../phase-2/10-emit-core.md`](../phase-2/10-emit-core.md),
> [`../phase-3/09-emit-pipeline-opt.md`](../phase-3/09-emit-pipeline-opt.md).

---

## Context

`emit_core` is the backend and the binding chokepoint (D3b): it walks an `ir.Module` and
produces a `core_erlang.CModule`, resolving every runtime reference through **one** state-access
seam, `seam_call(module, fn_name, args) -> CExpr` (`emit_core.gleam:622`), which emits
`call '<module>':'<fn_name>'(args)` with `module` a fixed `binding.*_module` atom and `fn_name` a
literal (D3a — no ambient authority). Phase 2 (E1) deliberately routed **every** stateful op —
`MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`GlobalGet`/`GlobalSet`/`CallIndirect` and the
`instantiate/0` seeds — through that one helper *precisely so the tier-P `threaded` build would
be a **seam expansion**, not a scattered rewrite*. This unit cashes that promise (G1).

Today the seam is the tier-O **`cell`** strategy: it emits `call '<mem_module>':'store'(…)` etc.
against the per-process `rt_state` process-dictionary cell; generated function arities are
unchanged (the state handle is hidden in the pdict). Phase 4 adds the tier-P **`threaded`**
strategy (the runs-anywhere build): a purely-functional `rt_state.InstanceState` record threaded
through generated code — **no process dictionary, no OTP-native state**. Selection is a new
`Binding` field, `state_strategy: StateStrategy` (`Cell | Threaded`, frozen by the keystone §A.1);
it is a **codegen-shape** switch confined to `emit_core` + the runtime (G5) — **no IR change, no
frontend change, no new node types** (G7). The IR's memory/global/table nodes carry **no handle
operand** (E1/G5), which is exactly what makes threading a record through every function a
*localized* seam expansion rather than a platform rewrite.

## Goal

When `binding.state_strategy == Threaded`, lower the state-access seam and function emission so
that every **state-reaching** function takes the `InstanceState` record as its leading parameter
and **returns the (possibly updated) record** (the uniform-threading rule, keystone §10/§A.3); a
store threads `addr → value → t_store → new-record`; a load reads from the record and leaves it
unchanged; the `instantiate/0` entry **builds and returns the initial record** (via `rt_state:fresh`)
instead of seeding the pdict cell; and the loop back-edge threads the record in **constant space**
(G4). When `state_strategy == Cell`, emit **byte-identical** code to Phase 2/3 (the strategy is
the only switch — the cell path must not change by one atom). Extend the structural
security-invariant test to prove the threaded lowering is free of ambient authority (D3a).

## Files owned (single-owner-additive)

- `src/twocore/backend/emit_core.gleam` — **EXTEND (single owner).** Add the state-reaching
  call-graph closure; thread the record through function emission, the per-op seam callers,
  control flow (loop/join points), and `instantiate/0`; gate every change on
  `binding.state_strategy`.
- `test/twocore/backend/emit_core_test.gleam` — threaded AST-shape goldens (EXTEND).
- `test/twocore/backend/emit_core_security_test.gleam` — the D3a walk under `Threaded` (EXTEND).
- `test/twocore/backend/emit_core_e2e_test.gleam` — hand-built-IR → build → `instantiate` →
  invoke, under `Threaded` (EXTEND; green once 03/04/06 land — see Concurrency).

## Deliverables & freeze milestones

**Consumes:** `«STATE-STRATEGY-FROZEN»` — `Binding.state_strategy`; `rt_state.InstanceState`
(`InstanceState(mem: Dynamic, globals: Dict(String, Int), table: Dynamic)`, `rt_state.gleam:90`);
and the tier-P threaded signatures (keystone §A.2), all frozen as heads by unit 01 (bodies:
03/04/06):

```gleam
// rt_state (03):   fresh(StateDecl) -> InstanceState
//                  t_global_get(InstanceState, String) -> Int
//                  t_global_set(InstanceState, String, Int) -> InstanceState
// rt_mem  (04):    t_load(st, bytes, signed, result_width, addr, offset) -> Result(Int, TrapReason)
//                  t_store(st, bytes, addr, value, offset)               -> Result(InstanceState, TrapReason)
//                  t_size(st) -> Int
//                  t_grow(st, delta) -> #(Int, InstanceState)
//                  t_init_data(st, offset, bytes) -> Result(InstanceState, TrapReason)
// rt_table(06):    t_init_elem(st, offset,
//                    List(#(FuncType, fn(InstanceState, List(Int)) -> #(List(Int), InstanceState))))
//                                                  -> Result(InstanceState, TrapReason)
//                  t_call_indirect(st, index, expected_type, args)
//                                                  -> Result(#(List(Int), InstanceState), TrapReason)
```

**Produces (no downstream *freeze*, but one load-bearing convention):** the **emitted threaded
calling convention** — a state-reaching function is `'f'/(n+1) = fun(St, A…) -> {ResultPackage, St'}`
and an exported function under `Threaded` is uniformly threaded (§B.4) — which **unit 08's run-ABI
binds to** (it passes the `instantiate`-returned record as the leading `invoke` arg and threads
`St'` forward). This unit *emits* the shape; unit 08 *drives* it. It is application/wiring, not a
new contract, so it needs no `state.md` freeze — but the run-ABI handoff (§B.4, §E) is announced.

**Out of scope (do NOT build here):** the tier-P `rt_state`/`rt_mem`/`rt_table` **bodies**
(03/04/06 — this unit emits calls against their frozen heads); the `atomics`/`nif`/`ets` memory &
table **tiers** (04/05/06 — a tier is a `mem_module`/`table_module` swap the linker resolves, G5;
`emit_core` reads only the module name, never `mem_tier`); the `portable`/`ceiling` **profiles** +
`validate_binding` (07); the pipeline/CLI `state_strategy` **selection** and the run-ABI St
threading (08); the constant-space-under-threaded **differential** and the tier differential (09).
No new IR node, no `.ir` grammar change (G7).

## Depends on (freeze milestones)

| Freeze | From | What you take | Stub against meanwhile |
|---|---|---|---|
| `«STATE-STRATEGY-FROZEN»` | 01 | `Binding.state_strategy`; `InstanceState`; the threaded `rt_state`/`rt_mem`/`rt_table` heads (`fresh`/`t_*`); the seam-expansion contract (§A.3) and the uniform-threading rule (§10). | Heads land green (bodies are 03/04/06); emit the calls against the *signatures*. e2e waits on 03/04/06 (Concurrency). |
| `«MEM-TIER-FROZEN»` | 01 | that `emit_core` keys the seam on `binding.mem_module`/`table_module`/`state_module` **only** (never `mem_tier`/`state_strategy`-as-module) — so a tier is a module swap and the strategy is a shape switch, cleanly orthogonal (G5). | Nothing to stub — you read the module-name fields exactly as today. |

---

## A. The threaded emission channel + the state-reaching classification

### A.1 `state_strategy` is the ONLY switch; `Cell` is byte-identical

`emit_module` gains **one** read of `binding.state_strategy`. Under `Cell`, every function in this
document's contract is *literally today's code* — the existing `emit`/`emit_instantiate`/
`seam_call` paths, unchanged to the atom (§F). Under `Threaded`, the paths below apply. No other
`Binding` field gates codegen shape (the tier is a module-name swap, G5); the strategy never picks
a *module*, only the *function family* (`store` vs `t_store`) and whether functions thread a record.

### A.2 The state channel (threaded alongside `cont`)

The emitter walks the IR in tail position under a continuation `Cont` and a monotonic
`EmitState` (gensym counter, reserved names, label stack). Threading a record needs one more
thing at every emission point: **the Core variable currently holding the live `InstanceState`.**
This is *environment*, not accumulator — it flows down, is **rebound** after each mutating op, and
**branches** (each `if` arm has its own current record). So it is passed as a parameter, not stored
in `EmitState`:

```gleam
/// The state-threading channel carried alongside `cont` under `state_strategy: Threaded`.
/// - `NoState`: `Cell` strategy (or a PURE function under `Threaded`) — emit today's code; no
///   record is threaded, functions keep their Phase-1 arity, `KReturn` yields the bare package.
/// - `Threading(cur)`: `cur` names the Core variable holding the CURRENT `InstanceState`. Reads
///   pass `cur`; mutators rebind a fresh var and continue under `Threading(fresh)`; `KReturn`
///   pairs the package with `cur` into `{Package, cur}`.
type StateChan {
  NoState
  Threading(cur: String)
}
```

`emit(expr, cont, sc, state, ctx)` gains the `sc: StateChan` parameter. The `Cell` path and every
pure function pass `NoState` and are unaffected. Fresh state-vars come from the existing
`fresh_var` (so they never collide with IR names or other gensyms).

### A.3 The state-reaching call-graph closure

`Ctx` gains `fn_state_reaching: Set(String)`, computed **once** in `emit_module`. A function is
**state-reaching** iff (transitive fixpoint over `CallDirect` edges):

1. its body contains any of the seven stateful nodes —
   `MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`GlobalGet`/`GlobalSet`/`CallIndirect` (reads count:
   `MemLoad`/`MemSize`/`GlobalGet` need the record to read *from*); **or**
2. it (transitively) `CallDirect`s a state-reaching function.

`CallHost` and `Charge` are **not** seeding conditions — the host boundary (`rt_host:call_host`)
and the fuel counter (`rt_meter`) never touch the instance-state record (§ note, and Open
questions on metering + the runs-anywhere pdict). `CallIndirect` **targets** (element-segment
functions) are **not** seeded either: the `t_init_elem` closure adapter (§C, §E) threads the
record *around* a pure target, so a pure table target stays pure and only the closure absorbs the
ABI (exactly as today's `element_closure` adapts `fn(List(Int)) -> List(Int)`). Under `Cell` the
set is unused. Computing it as a closure (not just "direct") is what makes a caller of a
memory-touching helper thread the record even though the caller has no stateful node of its own —
the correctness crux of uniform threading.

---

## B. The uniform-threading rule (keystone §10) — function shape, returns, calls

### B.1 State-reaching function shape (the leading-in / trailing-out convention)

A state-reaching `Function(name, params=[A,B], result, body)` is emitted as

```erlang
'f'/(n+1) = fun (St, A, B) -> {ResultPackage, St'}
```

— the record threaded as the **leading parameter** (keystone §A.3), the normal Phase-1 return
package (`function_return`: 0 results → `'ok'`, 1 → bare, N≥2 → an N-tuple) wrapped with the
**outgoing** record `St'` into a **2-tuple `{Package, St'}`**. This mirrors the frozen runtime
signatures exactly — **the record comes in leading and goes out trailing**:
`t_load(st, …)`/`t_store(st, …)`/`t_grow(st, …) -> #(Int, InstanceState)`/`t_call_indirect(st, …)
-> …#(List(Int), InstanceState)`. A **pure** function keeps its Phase-1 `'f'/n = fun(A,B) -> Package`
signature (channel `NoState`) — pure numeric leaves and `sum_to`-style loops pay **nothing** (§D).

`emit_function` reads `set.contains(ctx.fn_state_reaching, f.name)`: state-reaching ⇒ prepend a
fresh `St0` param, set `sc = Threading(St0)`, emit the body under `KReturn`; pure ⇒ `sc = NoState`,
emit exactly as today. The emitted `FName` arity is `len(params) + 1` for a state-reaching
function (the seam that resolves `CallDirect` arities, `fn_arity`, is consulted with the `+1`).

### B.2 `KReturn` / `Return` under `Threading(cur)`

`apply_cont(KReturn, vals)` currently yields `function_return(vals)`. Under `Threading(cur)` it
yields `CTuple([function_return(vals), CVar(cur)])` — the `{Package, St'}` 2-tuple. `Return(vs)`
(the non-continuation transfer) yields the same tuple with the *current* `cur`. `Trap(reason)` is
**unchanged** — it raises and never returns, so it pairs no state (a trapped instance's record is
abandoned with the crashing process). This is the whole extent of the return-boundary change.

### B.3 `CallDirect` — thread the record; preserve cross-function tail calls

Let `g` be the callee, `r = ctx.fn_results[g]`.

- **`g` pure** (from a state-reaching or pure caller) → `apply 'g'/n(args…)` exactly as today;
  the caller's `cur` flows **around** it unchanged; unpack `r` via `apply_cont_call`.
- **`g` state-reaching**, caller under `Threading(cur)` → `apply 'g'/(n+1)(cur, args…)` yields
  `{Package, St'}`.
  - **`cont == KReturn` and `r == caller's result arity`** → emit the `apply` **straight through**
    (no destructure/repack): `{Package, St'}` is *already* exactly what the caller must return. So a
    tail `CallDirect` to a state-reaching `g` stays a **tail call** — cross-function tail recursion
    and trampolines keep constant stack (the Phase-1 property, preserved).
  - **otherwise** → `case apply 'g'/(n+1)(cur, args…) of <{Pkg, St'}> when 'true' -> …`, then unpack
    `Pkg` into `r` values (the existing `apply_cont_call` r∈{0,1,≥2} logic) and continue under
    `Threading(St')`.

### B.4 Exports are uniformly threaded (the run-ABI handoff)

Under `Threaded`, the **export boundary** is made uniform so unit 08's run-ABI can *always* pass
the record and *always* receive `{Package, St'}` — no per-export classification at the harness. The
uniform threaded export ABI is therefore: **every export presents at arity `n+1`, takes `St`
leading, and returns `{Package, St'}`.** `emit_exports` reaches that shape while **mirroring the
`Cell` name-equality check** (`emit_core.gleam:315`), so it never re-defines a name it has already
emitted. For each `ExportFn(export_name, fn_name)`:

- `fn_name` **state-reaching** *and* `export_name == fn_name` → **export the internal
  `'fn_name'/(n+1)` DIRECTLY — no wrapper.** `emit_function` already emitted `'fn_name'/(n+1) =
  fun(St, A…) -> {Package, St'}` (§B.1), which *is* the run-ABI export shape, so the export list
  simply names it (exactly as `Cell` exports `'fn_name'/arity` directly when the names match,
  `emit_core.gleam:315`). Synthesizing a wrapper here would emit a **second** `'fn_name'/(n+1)` that
  self-applies — a **duplicate `FunDef`** (invalid Core, the build fails) that also **recurses
  infinitely**. The pervasive `ExportFn(f.name, f.name)` shape takes this branch, so this is the
  common case, not an edge case.
- `fn_name` **state-reaching** *and* `export_name != fn_name` → synthesize the forwarding wrapper
  `'export_name'/(n+1) = fun(St, A…) -> apply 'fn_name'/(n+1)(St, A…)` (already `{Pkg, St'}`). The
  distinct `export_name` cannot collide with the internal `'fn_name'/(n+1)`.
- `fn_name` **pure** (either name relation) → synthesize the adapting wrapper
  `'export_name'/(n+1) = fun(St, A…) -> {apply 'fn_name'/n(A…), St}` (thread `St` straight through).
  Even when `export_name == fn_name` this is safe: the wrapper is arity `n+1` while the internal
  function is `'fn_name'/n`, so **distinct arity** keeps `'g'/n` and `'g'/(n+1)` apart — no collision.

Internal (non-exported) pure functions stay pure `'g'/n`; a pure exported function coexists as both
`'g'/n` (internal callers) and `'export'/(n+1)` (the threaded wrapper) — distinct by arity, no
collision. Under `Cell`, `emit_exports` is unchanged (direct export when names match, else a bare
forwarding wrapper). **Unit 08 owns** capturing the `instantiate`-returned record and threading
`St'` across successive invokes; this unit only emits the uniform-threaded export shape and the
state-reaching classification it keys on.

---

## C. The per-op threaded lowering (the seam expansion)

The module comes from the binding (unchanged, G5); the strategy picks the `t_`-prefixed function
family and threads `St`. `W(result)` = 32 for `TI32`/`TF32`, 64 for `TI64`/`TF64`. All calls remain
`seam_call(binding.<X>_module, <fn>, [St, …])` — `St` is an ordinary argument, never a module/func
selector (D3a). Under `Threading(cur)`, `St = CVar(cur)`:

| IR node | Threaded Core (schematic) | Disposition & state |
|---|---|---|
| `MemLoad(op, addr, off, result)` | `V = case '<mem>':'t_load'(St, op.bytes, op.signed, W, Addr, off) of {ok,X}->X; {error,R}->raise(R) end` | trapping `Result` → 1 value; **read-only**, `cur` unchanged |
| `MemStore(op, addr, value, off)` | `St2 = case '<mem>':'t_store'(St, op.bytes, Addr, Val, off) of {ok,S}->S; {error,R}->raise(R) end` | ordered effect; addr→value→store; **rebind** `cur := St2` |
| `MemSize` | `V = '<mem>':'t_size'(St)` | bare i32; read-only |
| `MemGrow(delta)` | `{V, St2} = '<mem>':'t_grow'(St, Delta)` | bare i32 value `V` (old pages), **rebind** `cur := St2` |
| `GlobalGet(name)` | `V = '<state>':'t_global_get'(St, NameBin)` | bare value; read-only |
| `GlobalSet(name, value)` | `St2 = '<state>':'t_global_set'(St, NameBin, Val)` | ordered effect (non-trapping — returns the record directly); **rebind** `cur := St2` |
| `CallIndirect(_, index, ty, args)` | `{Rs, St2} = case '<table>':'t_call_indirect'(St, Idx, TypeTag, ArgList) of {ok,P}->P; {error,R}->raise(R) end` | 3-fault trapping `Result` → unpack `len(ty.results)` from list `Rs`; **rebind** `cur := St2` |

Reuse the existing dispositions, extended to rebind/thread `cur`:

- `MemLoad` / trapping `CallIndirect` use the verified `case`-and-`raise` shape
  (`emit_trapping_result` / the `emit_call_indirect` list unpack), reading `St`; `cur` unchanged.
- `MemStore` becomes a **record-rebinding** `let St2 = <t_store case reduced to the record> in …`.
  The reduction differs from `trapping_effect` (which yields a discardable `'ok'`): under threaded
  the `{ok,S}` arm yields the **record `S`**, the `{error,R}` arm raises. Then continue under
  `Threading(St2)` disposing zero values. `NameBin`/`TypeTag`/`func_type_term`/`core_binary_string`
  are **unchanged** (the type tag is structural, strategy-agnostic).
- `MemGrow` binds `{V, St2}` from `t_grow`'s `#(Int, InstanceState)` (a `case … of <{V,St2}> -> …`),
  continues with `V` under `Threading(St2)`. **`emit_core` only *calls* `t_grow(St, Delta)`; the
  success-path fuel charge lives *inside* `t_grow` (unit 04), not in emit.** `memory.grow` fuel is
  per-*actual*-delta — the `Cell` `rt_mem.grow` charges `rt_meter:charge(delta * page_bytes)` on
  success (`result != -1`), the **only** runtime-side dynamic fuel charge (it cannot be a static IR
  `Charge` node, since the granted delta is known only at runtime). The threaded `t_grow` (unit 04)
  **replicates that same charge** on the success path, so `emit` emits **no** grow-specific charge and
  metered+`threaded` stays byte-identical to metered+`cell` (G7); unit 09 owns the `memory.grow`
  trap-parity differential across strategies under a tight `safe_metered` budget.
- `GlobalSet` binds `St2` from `t_global_set`'s bare record return, continues under `Threading(St2)`.

`CallIndirect` slot targets: under `Threaded`, `element_closure` emits
`fun(St, ArgsList) -> {ResultList, StOut}` matching the frozen entry type
`fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)`: unpack args to the target's static
arity, and — for a pure target — `{wrap(apply 'f'/n(args…)), St}` (thread `St` through untouched);
for a state-reaching target — `{Pkg, St'} = apply 'f'/(n+1)(St, args…)` then `{wrap(Pkg), St'}`.
The integer index is still the only runtime data reaching a control transfer; the closure is a
build-controlled capture of a compile-time-literal `f<idx>` name (D3a) — `St` is a *parameter*, not
a dispatch key.

**Spec grounding (unchanged from Phase 2, tier/strategy-agnostic):** no-wrap effective address and
trap-before-write are the runtime's job — pass `(bytes, signed, W, addr, offset)` straight through
([exec/memory](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions));
`memory.grow` returns the previous page count or `-1`; the three `call_indirect` faults are
distinct and ordered (bounds → null → type,
[exec/instructions](https://webassembly.github.io/spec/core/exec/instructions.html#control-instructions));
`t_load`/`t_store`/`t_grow`/`t_call_indirect` reproduce those traps identically — a trapping op
raises via `rt_trap` and abandons the record (the `{error,R}` arm never threads state).

---

## D. Constant space under `threaded` (G4) — the loop back-edge

Threading a record adds a **loop-carried parameter** and rebinds a **new record per store** — the
exact E1 concern. It is proven, not asserted.

**Control flow threads the record through join points and loops.** Under `Threading(cur)`, a
state-reaching multi-exit construct (`If`/`Switch`/`Block`/`Loop`) whose exits must merge the
updated record has its materialized join point widened by **one leading state slot**, and every
exit appends `cur` to the value list it passes (`Break` and fall-through pass `[St, vs…]`; the join
binds `fun(StOut, V1…Vn) -> <continue under Threading(StOut)>`). Because different branches carry
different current records, `StOut` **unifies** them at the merge — the natural functional join. A
provably-state-neutral subtree (no store/grow/global.set/state-reaching-call/`call_indirect` in it)
may keep its Phase-1 join arity and flow `cur` around unchanged (a sound optional refinement; the
baseline threads uniformly through the state-reaching function).

**The loop template (the G4 crux).** `emit_loop` today emits the verified §5 template
`letrec 'L'/arity = fun(params…) -> <body>` applied to the param inits, with `Continue → apply 'L'(vs)`
(a tail call → constant space) and exits through the materialized cont. Under `Threading(St_entry)`
for a state-reaching loop, `L` carries the record as a **leading loop param**:

```erlang
letrec 'L'/(k+1) = fun (St, P1, …, Pk) ->
          <body emitted under Threading(St), exits via the k+1-arity merge cont>
in apply 'L'(St_entry, Init1, …, Initk)
%% Continue(label, vs)  →  apply 'L'(St_at_continue, V1, …, Vk)      (the back-edge threads the LIVE record)
%% Break(label, vs) / fall-through  →  <merge cont applied to [St_at_exit, V1, …, Vk]>
```

**Why constant space holds.** `InstanceState` is a **fixed-size box** — a 3-tuple `{mem, globals,
table}` (`rt_state.gleam:90`) of pointers to immutable/handle structures. The back-edge
`apply 'L'(St', vs…)` is still a Core `apply` in **tail position**, so BEAM last-call optimization
keeps the stack flat; adding one word-sized loop param (a boxed pointer to the 3-tuple) does not
grow the frame. Each store **rebinds the box** — `let St2 = <t_store …> in …` builds a *new*
3-tuple sharing two of three fields (structural sharing; only the `mem` slot changes), and the
superseded box is immediately garbage. So per-iteration extra heap is O(1) *for the box* (plus
whatever the linked `mem` backend allocates per store — one chunk copy under `paged`, **zero**
under `atomics`/`nif`, which mutate the same handle in place and return it, keystone §A.2 uniform
rule). The loop is ordinary BEAM code, so **preemption is unchanged** (reduction-counted, yields
mid-loop). Therefore `sum_to(100000)` — **pure**, so *not* state-reaching, `NoState`, byte-identical
to `Cell` — and a memory-store loop — state-reaching, carrying the box — both run in **constant
space**. This is unit 09's tested acceptance property (a store-loop over `sum_to(100000)` iterations
with a bounded live set), not an assertion; this unit's job is to emit the template that satisfies it.

---

## E. The record-returning `instantiate/0` (keystone §A.3)

Under `Cell`, `emit_instantiate` is **byte-identical** to today: seed the pdict cell
(`seam_call(state_module, "seed", [Decl])` as a `let`-discard) and return `'ok'` (§F). Under
`Threaded`, it **builds and returns the record**:

```erlang
'instantiate'/0 = fun () ->
   let _  = call '<meter>':'seed_fuel'(Budget) in      %% (0a) only under meter == MeterFuel (unchanged, F5)
   let _  = call '<host>':'seed_policy'(Policy) in      %% (0b) always (unchanged, F4)
   let St0 = call '<state>':'fresh'(Decl) in            %% (1) BUILD the record (NOT seed) — no pdict write
   let St1 = case '<table>':'t_init_elem'(St0, Off, Entries) of {ok,S}->S; {error,R}->raise end in  %% (2) elements
   let St2 = case '<mem>':'t_init_data'(St1, Off, Bytes) of {ok,S}->S; {error,R}->raise end in       %% (3) data
   let {_, St3} = <start: apply 'f<start>'/(a+1)(St2) if state-reaching, else apply/…()> in           %% (4) start
   St3                                                  %% RETURN the InstanceState (not 'ok')
```

Key points:

- `Decl` (`state_decl_term`) is **identical** to `Cell` — `mem = '<mem>':'fresh'(Min, Max, SafeCap)`,
  `table = '<table>':'new'(Min, Max)`, `globals = [{NameBin, InitBits}…]` (constant-folded, D5).
  Only the **consumer** changes: `fresh(Decl) -> InstanceState` (bound to `St0`) instead of
  `seed(Decl) -> Nil` (discarded). Non-constant init/offset still fails closed with
  `Error(NonConstInit)`; an undefined element/`start` target still `Error(UnknownFunction)`.
- Element **before** data **before** start (WASM instantiation order,
  [exec/modules/instantiation](https://webassembly.github.io/spec/core/exec/modules.html#instantiation)),
  now each threading `St` (`t_init_elem`/`t_init_data` return the record; a segment-OOB or trapping
  start raises and **fails instantiation**, abandoning the record).
- **`start` threads the record** if state-reaching: `{_, St3} = apply 'f<start>'/(a+1)(St2)` (WASM
  `start` is `[]→[]`, so the package is `'ok'`, discarded); a pure start is `apply 'f<start>'/a()`
  with `St` unchanged. `Entries` are the threaded closures (§C).
- **`seed_fuel`/`seed_policy` are unchanged** (metering/host are pdict-seeded, F5/F4 — orthogonal
  to *state* threading). They stay `instantiate`'s first effects and target fixed `meter_module`/
  `host_module` atoms (D3a-clean). *(That these two remain pdict-based under a `portable` build is
  a runs-anywhere-pdict tension owned by 07/11 — see Open questions; it is **not** this unit's to
  resolve, and it does not affect the state-threading shape.)*

Unit 08's run-ABI captures the returned `InstanceState` and passes it as the leading arg to each
`invoke`, threading the returned `St'` forward; one instance = one process still holds, but the
state travels **as a value**, not in the pdict.

---

## F. `Cell` stays byte-identical (the non-negotiable)

The strategy is the **only** switch, gated once per shape decision. Under `Cell`: `emit_function`
adds no param and passes `NoState`; every per-op arm emits the current `store`/`load`/`size`/`grow`/
`global_get`/`global_set`/`call_indirect` calls with today's arities; `emit_instantiate` seeds and
returns `'ok'`; `emit_exports` is unchanged. Pin this with a **byte-identity** regression: for the
`stateful_module()` fixture, `emit_module(m, profiles.safe())` (Cell) is unchanged from the Phase-2/3
emission (the existing `emit_core_test` / conformance goldens stay green, and the printed `.core` is
compared bit-for-bit against the pre-unit-02 output). No cell atom may move.

---

## G. Multi-value & effect-sequencing interplay with the record

- **Multi-value returns nest cleanly.** A state-reaching N-result function (N≥2) returns
  `{{V1,…,Vn}, St'}` — the outer 2-tuple's first slot is the `function_return` N-tuple package. The
  caller destructures `{Pkg, St'}` then destructures `Pkg` into N values (the existing
  `apply_cont_call` r≥2 path, applied to `Pkg`). No ambiguity: the outer shape is *statically*
  `{Package, State}`, and the callee's result arity is known from `fn_results`. `t_call_indirect`
  likewise returns `#(List(Int), InstanceState)` — the results **list** `Rs` is unpacked to
  `len(ty.results)` and `St2` rebinds `cur`.
- **Effect ordering becomes an explicit data dependency (stronger than `Cell`).** Under `Cell`, the
  ordering of pdict effects rests on the strict `let`-discard convention (a hidden effect the
  optimizer must treat as an E6 barrier). Under `Threaded`, each mutator **rebinds `cur`** and every
  subsequent op **consumes the new `cur`**, so the store-before-load order is a *visible* dataflow
  edge through `St` — no optimizer (even the Phase-3 aggressive one) can reorder a store past a
  dependent load, because the load's `St` argument names the post-store record. Reads
  (`t_load`/`t_size`/`t_global_get`) do not rebind `cur`, so independent reads may commute (sound —
  reads of the same record version are pure); a read cannot cross a write because it would name a
  different `St`. This makes E6's "state ops are barriers" a *functional* property of the threaded
  IR-to-Core lowering, not merely a convention. `Charge`/`CallHost` are state-neutral: they emit as
  today, and `cur` flows through them unchanged.

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives threading.** Every threaded seam call is
  `seam_call(binding.{mem,state,table}_module, "t_*"/"fresh", [St, …])` — a fixed runtime module
  atom, a literal function atom, and `St` as an **ordinary argument** (a Core var), never a
  module/function selector. The `t_call_indirect` closures are still build-controlled captures of
  compile-time-literal `f<idx>` names; the integer index remains the sole runtime-data input to a
  control transfer; `St` is a closure *parameter*. So the structural walk
  (`assert_calls_are_runtime` + the `apply`-is-`FName` walk) passes under `Threaded` with the SAME
  `runtime_modules(binding)` allow-set (state/mem/table modules already in it). This unit adds
  `no_ambient_authority_under_threaded_test` exercising the `stateful_module()` fixture under a
  `Threaded` binding.
- **Fail-closed defaults (D4).** `safe_default().state_strategy == Cell` (keystone) — the tier-P
  posture requires naming it. Threading changes shape, never the trap set (G7): a bounds bug's worst
  case is still a wrong/missing trap or a node-safe crash, never a host escape (tier-P is
  memory-safe by construction).
- **Threads / shared memory stay a hard non-goal.** The threaded record is process-local (threaded
  through one process's call chain); it is never shared across processes. `atomics`/`nif` handles in
  the `mem` slot are used process-locally (unit 04/05), never cross-process.
- **Floats-as-bits (D5) unchanged.** Globals stay raw-bit-pattern `Int`s in the record's `globals`
  dict; memory is raw bytes over the IEEE bit pattern in every tier — never a BEAM-double round-trip.

---

## Verification — Definition of Done (D8)

Tests assert **spec/decision behavior**, not whatever the code emits (no change-detector tests);
cite the spec/G-decision in each. "Done" = the suite below passes, not "it compiles."

1. **Threaded AST-shape goldens** (`emit_core_test`), one per construct, asserting *structure*:
   a state-reaching `f(A,B)` emits `'f'/(n+1)` returning a `{Package, St'}` 2-tuple; `MemStore` →
   a `let St2 = case t_store(St,…) of {ok,S}->S; {error,R}->raise` rebinding the record; `MemLoad`/
   `MemSize`/`GlobalGet` → a read that does **not** rebind (`case t_load(St,…)` / `t_size(St)` /
   `t_global_get(St,…)`); `MemGrow`/`CallIndirect` → `{V,St2}`/`{Rs,St2}` binds; a **pure** function
   emits its Phase-1 `'g'/n` shape (no `St`). **Export name-collision (§B.4):** a state-reaching
   `ExportFn(f, f)` (`export_name == fn_name`) yields **exactly one** `'f'/(n+1)` `FunDef` — the
   internal one, exported directly, with **no** self-applying wrapper (assert no duplicate
   `FName("f", n+1)` def and that the build is valid Core); `ExportFn(g, f)` with distinct names
   emits a separate `'g'/(n+1)` forwarder; a **pure** export emits an `'export'/(n+1)` adapter
   coexisting with the internal `'g'/n`. Cite keystone §10 / §A.3 and the `emit_core.gleam:315`
   name-equality mirror.
2. **Constant-space loop template** (structural; the runtime proof is unit 09): a state-reaching
   `Loop` emits `letrec 'L'/(k+1)` with `St` a leading loop param, the `Continue` back-edge a tail
   `apply 'L'(St', vs…)`, and the exit merge cont widened by the state slot. Assert the back-edge is
   a tail `CApply` (no wrapping `case`/`let` between it and the loop head). Cite G4 / high-level §9.2.
3. **`instantiate/0` threaded golden**: under `Threaded`, the body binds `St0 = fresh(Decl)` (not a
   `seed` discard), threads `t_init_elem` → `t_init_data` → start in that order, each a
   record-rebinding `let`, and **returns the `InstanceState`** (the final `St`), not `'ok'`; the
   `Decl` term is bit-identical to the `Cell` `Decl`; `seed_fuel`/`seed_policy` still lead. Cite
   [instantiation order](https://webassembly.github.io/spec/core/exec/modules.html#instantiation),
   keystone §A.3.
4. **`Cell` byte-identity** (§F): `emit_module(stateful_module(), profiles.safe())` printed to
   `.core` is bit-for-bit unchanged from the pre-unit-02 emission; the existing `emit_core_test`,
   `emit_core_security_test` Safe arm, and conformance goldens stay green.
5. **D3a under `Threaded`** (`emit_core_security_test`): `no_ambient_authority_under_threaded_test`
   — `assert_calls_are_runtime` and the `apply`-is-compile-time-`FName` walk both pass under a
   `Threaded` binding for the `stateful_module()` fixture; assert every threaded seam call targets a
   `binding.{mem,state,table}_module` atom with a literal `t_*`/`fresh` function and that no `CApply`
   targets a non-literal name. Cite D3a / high-level §5.
6. **End-to-end** (`emit_core_e2e_test`; green once 03/04/06 land — Concurrency): hand-built IR →
   `emit_module(_, Threaded)` → `build_beam` → call `instantiate/0` to obtain the record → invoke an
   export threading the record, asserting **byte-identical results and traps to the `Cell` build**:
   a store-then-load round-trip (incl. a `load8_s`/`load16_u` sign-extension width); `memory.grow`
   returns the old size then a load of the grown zero region returns `0`; a mutable global round-trips
   `global.set`/`global.get`; a `call_indirect` to the right type runs and each of the three faults
   traps with the spec reason; an OOB active data/element segment traps at instantiation. Every case
   is diffed against the `Cell` oracle (same IR, `state_strategy: Cell`) — the G7 byte-identical bar.
7. **No regression.** `gleam format --check src test` clean; `gleam build` **zero warnings**;
   `gleam test` stays green (≥674, conformance 15747/411/0 under both profiles — the `Cell`/default
   path is untouched). Every new public/private function carries a contract doc comment (D8).

**Proof of goal:** tests 1–3 + 6 are the unit's proof — a stateful WASM module hand-built as IR
compiles under `state_strategy: Threaded` to a purely-functional record-threading `.core` that
instantiates, runs, and traps **byte-identically to the `cell` build**, in constant space, with the
security walk green and the pdict cell nowhere in the linked output.

---

## Concurrency

- **Sub-task A (no tier-P bodies needed):** the state channel + the state-reaching closure + the
  per-op threaded arms + the threaded function/return/call/loop/instantiate emission + the AST-shape
  goldens + the security walk. These build against the **frozen threaded signatures alone**
  (keystone §A.2) — start immediately, do not wait for 03/04/06.
- **Sub-task B (gated on 03+04+06 landing):** the e2e `Threaded`-vs-`Cell` differential. Stub/`@pending`
  it until the `rt_state`/`rt_mem`/`rt_table` threaded **bodies** exist; keep A's goldens green so a
  regression in emission is caught without the runtime.
- Coordinate the **threaded element-entry closure shape** (`fun(St, Args) -> {Results, St'}`) with
  unit 06 and the **`fresh(Decl) -> InstanceState`** consumer with unit 03 (you emit what they
  consume), and hand unit 08 the **state-reaching classification** + the uniform-threaded export
  shape (§B.4) it drives.

## What this unit leaves

- **Unit 03** fills `rt_state.fresh`/`t_global_get`/`t_global_set` + the `rt_mem`/`rt_table` threaded
  wrappers over the existing pure core (`fresh_mem`/`mem_load`/`mem_store`/`mem_grow`/`mem_size`/
  `mem_init_data`, `rt_mem.gleam:209+`) — NO pdict; this unit's e2e is their integration check.
- **Unit 08** selects `state_strategy` per profile in the pipeline/CLI and **owns the run-ABI**:
  capture the `instantiate`-returned record, pass it leading to each `invoke`, thread `St'` forward
  (§B.4, §E) — binding to the emitted threaded convention this unit produces.
- **Unit 09** runs the tier differential and the **constant-space-under-threaded** proof (G4 — a
  store-loop over `sum_to(100000)` iterations in constant space; the template this unit emits).
- **Unit 11** proves every `(state_strategy × mem_tier)` conformance-green + the runs-anywhere grep
  proof (a `Threaded`+`Paged` build links no `rt_state` pdict cell and no OTP-native *state*).

## Open questions (for the planner / cross-unit sync)

- **Metering pdict vs the runs-anywhere property.** `portable` is `Threaded`+`Paged`+`bif`+**Safe**,
  and Safe implies `MeterFuel`, whose `rt_meter` fuel counter is a **process-dictionary** cell. The
  runs-anywhere acceptance greps for "zero … process-dictionary state." This unit keeps `Charge`/
  `seed_fuel` state-neutral and pdict-based (F5, unchanged) — the tension between the metering pdict
  and the runs-anywhere grep is **owned by 07 (profiles) / 11 (the proof)**, not the threaded seam.
  Flagged to the keystone/EM: does `portable` scope the grep to *instance* state, or does it need a
  meter mode with no pdict? Either way, the state-threading shape here is unaffected.
- **Selective vs uniform join-point threading.** The baseline threads the record through every
  state-reaching function uniformly (§D). The precise "does this subtree touch state" refinement
  (skip threading through provably-state-neutral subtrees) is a sound optional optimization — build
  the uniform baseline first; only refine if a join-arity concern surfaces.
