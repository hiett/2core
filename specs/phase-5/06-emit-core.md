# Unit 06 — `emit_core` extension (lower IR3 → Core Erlang)

> **One owner. Wave A. The deepest single-owner codegen change of Phase 5 — a critical path.**
> Depends on **FREEZES ONLY** — `«IR3-FROZEN»` (the new `ValType` reftypes, `RefType`, the H2/H3
> `Expr` nodes, `Module.memories`, the mem-index on the memory nodes, `MemoryDecl.idx_type`,
> `TableDecl.ref_ty`, the passive/declarative `ElementSegment`/`DataSegment` model, the new
> import/export state variants, any new `TrapReason`) + `«RT3-SIG-FROZEN»` (the extended
> `rt_table`/`rt_mem`/`rt_state` signatures, doc-frozen, `todo`-free) + `«INSTANTIATE3»` (the
> imported-state/`spectest` link contract — only the *shape* you seed, not the linker body), all
> from the keystone (unit 01). You emit the seam **calls** against the frozen heads; the tier-P/
> multi-mem/reftype **bodies** are 07/08/09. Do **not** serialize behind them — start the day the
> freezes land. Read [`00-overview.md`](00-overview.md) (H1–H8) first, then the Phase-1/2/3/4
> overviews (D1–D10, E1–E8, F1–F8, G1–G8). Analog format:
> [`../phase-2/10-emit-core.md`](../phase-2/10-emit-core.md),
> [`../phase-4/02-emit-threaded-seam.md`](../phase-4/02-emit-threaded-seam.md).

---

## Context

`emit_core` is the backend and the **binding chokepoint** (D3b): it walks an `ir.Module` and
produces a `core_erlang.CModule`, resolving **every** runtime reference through **one** state-access
seam, `seam_call(module, fn_name, args) -> CExpr` (`emit_core.gleam:1206`), which emits
`call '<module>':'<fn_name>'(args)` with `module` a fixed `binding.*_module` atom and `fn_name` a
literal (D3a — no ambient authority, no data-driven `apply(Mod, …)`). Phases 2–4 routed the seven
stateful ops (`MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`GlobalGet`/`GlobalSet`/`CallIndirect`) and
the generated `instantiate/0` through that helper, and Phase 4 taught it a **second state strategy**
— the tier-P `threaded` build threads an `rt_state.InstanceState` record instead of the tier-O
`cell` pdict, keyed on `binding.state_strategy` with the `StateChan` channel
(`emit_core.gleam:199`) and the **state-reaching call-graph closure**
(`state_reaching_closure`/`expr_touches_state`, `emit_core.gleam:506`).

Phase 5 is the **first phase since Phase 2 to grow the IR** (H7). Fourteen new `Expr` nodes land —
references (`RefNull`/`RefFunc`/`RefIsNull`), table ops (`TableGet`/`TableSet`/`TableSize`/
`TableGrow`/`TableFill`/`TableInit`/`TableCopy`/`ElemDrop`), and bulk-memory ops (`MemFill`/
`MemCopy`/`MemInit`/`DataDrop`) — plus a **memory index** on the four existing memory nodes, a
memory **address width** (`idx_type`), passive/declarative **segments** with droppable instance
state, and the `Module.memory: Option → memories: List` change. Growing `Expr` breaks every
exhaustive match in this file. The keystone lands a minimal compile-satisfying arm so the tree stays
green; **this unit fills the real lowering** for all of it — through the seam, under **both** state
strategies, and **byte-identically** for a single-memory-funcref-active module (H7).

## Goal

Lower every new IR3 node to Core Erlang **through the runtime seam** (`rt_ref`/`rt_table`/`rt_mem`/
`rt_state` — never a raw term/apply op, D3a): reference values (null sentinel; `funcref` = the
type-tagged entry; `externref` opaque); `Table*` → `rt_table` calls; `MemFill`/`MemCopy`/`MemInit`/
`DataDrop` → `rt_mem` calls; `TableInit`/`TableCopy`/`ElemDrop` → `rt_table` calls; the **mem index**
on `MemLoad`/`MemStore`/`MemSize`/`MemGrow` → route to the indexed memory in the state; **memory64**
address width passed through transparently. Every state-touching node must (a) work under **both**
`Cell` and `Threaded` (the new state-reaching ops join the P4-02 threaded call-graph closure), (b)
trap fail-closed with **no partial writes** (H6), and (c) remain **byte-identical** to Phase-4 for a
single-memory-index-0, funcref-only-active, function-only-import module (H7). Extend the D3a
structural security-invariant test to prove the new authority is ambient-free. Co-design the `rt_*`
call ABI with 07/08/09 (you emit the calls; they implement the bodies against the keystone-frozen
sigs).

## Files owned (single-owner-additive)

- `src/twocore/backend/emit_core.gleam` — **EXTEND (single owner).** Add the 14 new `emit` arms and
  their per-op cell/threaded lowerings; the mem/table-index routing; the reference-value lowering;
  the passive-segment + memories-vector seeding in `state_decl_term`/`emit_instantiate_*`; extend
  `expr_touches_state`/`direct_callees`/`collect_expr` to descend into the new nodes; extend the
  `ElementSegment` init lowering (`funcs → init: List(Expr)`).
- `test/twocore/backend/emit_core_test.gleam` — AST-shape goldens for every new construct (EXTEND).
- `test/twocore/backend/emit_core_security_test.gleam` — the D3a walk over the new authority
  (EXTEND — grow the `stateful_module()` fixture to exercise ref/table/bulk/multi-mem + passive
  segments; assert the new seam calls present and no data-driven apply).
- `test/twocore/backend/emit_core_e2e_test.gleam` — hand-built IR3 → build → `instantiate` → invoke
  (EXTEND; green once 07/08/09 land — see Concurrency).

## Deliverables & freeze milestones

**Consumes:**

| Freeze | From | What you take | Stub against meanwhile |
|---|---|---|---|
| `«IR3-FROZEN»` | 01 | `RefType`/`TFuncRef`/`TExternRef`; the 14 new `Expr` nodes; `mem: Int` on `MemSize`/`MemGrow`/`MemLoad`/`MemStore`; `Module.memories`; `MemoryDecl.idx_type`; `TableDecl.ref_ty`; `ElementSegment(mode, ref_ty, init)` + `ElemMode`; `DataSegment(mode, bytes)` + `DataMode`; `ImportTable`/`ImportMemory`/`ImportGlobal`; `ExportTable`/`ExportMemory`/`ExportGlobal`; any new `TrapReason`. | The keystone's minimal `emit` arm keeps the tree green — replace it with the real lowering. |
| `«RT3-SIG-FROZEN»` | 01 (bodies 07/08/09) | The extended `rt_table` heads (`get`/`set`/`size`/`grow`/`fill`/`init`/`copy`/`elem_drop`, the multi-table index, the `t_*` threaded variants, the passive-element seed) · `rt_mem` heads (`fill`/`copy`/`init`/`data_drop`, the memories-vector + memidx routing, the passive-data seed, `t_*` variants) · `rt_state`/`rt_ref` heads (`ref_null`/`ref_is_null`, the null sentinel constant, the `StateDecl`/`fresh` memories-vector + passive-segment fields). | Emit calls against the *signatures*; e2e waits on 07/08/09. |
| `«INSTANTIATE3»` | 01/09 | The `StateDecl` **shape** (memories vector, passive data/elem, imported-state slots) you render in `state_decl_term`; the import-index-space ordering (imports-first) you resolve table/mem names against. | You render the Decl term; 09 owns the linker that consumes it and wires imported state. |

**Produces (no downstream freeze, two load-bearing conventions):**
1. the **memidx/table-idx routing convention** — index `0` (single region) emits the *exact* Phase-4
   seam call (no index arg), index `≥1` emits the indexed variant — the H7 byte-identity mechanism
   (§E), which 07/08 bind their two-shape signatures to;
2. the **reference-value term shape** — `RefFunc` = the `{TypeTag, Closure}` build-controlled entry
   (the same one element segments store) and the **shared null sentinel** literal — which 07's table
   storage and `call_indirect`/`table.get` semantics bind to.

**Out of scope (do NOT build here):** the `rt_table`/`rt_mem`/`rt_state`/`rt_ref` **bodies** (07/08/
09 — you emit calls against the frozen heads); the `map`/`ets`/`atomics`/`nif` **tiers** (a tier is a
`*_module` swap the linker resolves, G5 — `emit_core` reads only the module-name fields, never
`mem_tier`); **decode/validate/lower** of the new ops (03/04/05 — you consume IR3, you do not produce
it); the **non-function-import linker + `spectest`** wiring (09 — you render the `StateDecl` import
slots, 09 fills them); the **WAT parser** (10); the **conformance** expansion (11); `ir/effect.gleam`
barrier classification (01/02 own it). No `.ir` grammar change (02 owns the delta). **SIMD is Phase 6.**

## Depends on (freeze milestones)

Start behind `«IR3-FROZEN»` + `«RT3-SIG-FROZEN»`. `«INSTANTIATE3»` gates only the `state_decl_term`
imported-state/passive-segment rendering (§F); the reference/table/bulk **body-op** lowerings (§B–§E)
need only the IR + RT-sig freezes.

---

## A. The dispatch extension + the traversal/classification closure

### A.1 The 14 new `emit` arms

The main dispatcher `emit(expr, cont, sc, state, ctx)` (`emit_core.gleam:613`) gains one arm per new
node, each delegating to a per-op lowering that honors **both** the continuation `cont` and the state
channel `sc` (`NoState` = `Cell` or a pure function; `Threading(cur)` = the threaded record). The
`TermOp` arm stays `Error(UnsupportedNode("term_op"))` (still a later-phase deferral). Sketch:

```gleam
// references (H1/H2) — value-producing, NOT state-reaching (they touch no memory/table/global)
RefNull(ty) -> emit_ref_null(ty, cont, sc, state, ctx)
RefFunc(name) -> emit_ref_func(name, cont, sc, state, ctx)
RefIsNull(arg) -> emit_ref_is_null(arg, cont, sc, state, ctx)
// tables (H2) — state-reaching
TableGet(table, index) -> emit_table_get(table, index, cont, sc, state, ctx)
TableSet(table, index, value) -> emit_table_set(table, index, value, cont, sc, state, ctx)
TableSize(table) -> emit_table_size(table, cont, sc, state, ctx)
TableGrow(table, delta, init) -> emit_table_grow(table, delta, init, cont, sc, state, ctx)
TableFill(table, offset, value, count) -> emit_table_fill(table, offset, value, count, cont, sc, state, ctx)
TableInit(table, seg, dst, src, count) -> emit_table_init(table, seg, dst, src, count, cont, sc, state, ctx)
TableCopy(dt, st, dst, src, count) -> emit_table_copy(dt, st, dst, src, count, cont, sc, state, ctx)
ElemDrop(seg) -> emit_elem_drop(seg, cont, sc, state, ctx)
// bulk memory (H2/H3) — state-reaching
MemFill(mem, dest, value, count) -> emit_mem_fill(mem, dest, value, count, cont, sc, state, ctx)
MemCopy(dm, sm, dst, src, count) -> emit_mem_copy(dm, sm, dst, src, count, cont, sc, state, ctx)
MemInit(mem, seg, dst, src, count) -> emit_mem_init(mem, seg, dst, src, count, cont, sc, state, ctx)
DataDrop(seg) -> emit_data_drop(seg, cont, sc, state, ctx)
```

The four existing memory arms change their **destructuring** (they gain `mem`):
`MemSize(mem)`, `MemGrow(mem, delta)`, `MemLoad(mem, op, addr, offset, result)`,
`MemStore(mem, op, addr, value, offset)` — each threading `mem` into the per-op seam (§E).

### A.2 The three traversal functions MUST descend into every new node

Three exhaustive/closure traversals over `Expr` live in this file and **break** the moment `Expr`
grows; the keystone's minimal arm keeps them compiling but *inert*. This unit gives them the real
behavior — getting any one wrong silently corrupts threaded codegen or gensym uniqueness:

- **`expr_touches_state`** (`:556`) — the state-reaching **seed** test. It must return `True` for
  every **table op** (`TableGet`/`TableSet`/`TableSize`/`TableGrow`/`TableFill`/`TableInit`/
  `TableCopy`/`ElemDrop`) and every **bulk-memory op** (`MemFill`/`MemCopy`/`MemInit`/`DataDrop`) —
  they read and/or write the memories/tables/passive-segment instance state. It must return **False**
  for the reference ops (`RefNull`/`RefFunc`/`RefIsNull`): a reference is produced from a compile-time
  name or a constant sentinel and is pure — it does **not** reach the record. (Getting a reference op
  wrong-classified as state-reaching would needlessly thread the record — correct but a perf/shape
  regression that breaks H7 byte-identity for a module that only holds references; getting a table/
  bulk op wrong-classified as pure would emit a *threaded* body that reads `St` that was never
  threaded in — a compile error / miscompile.)
- **`direct_callees`** (`:583`) — the `CallDirect` edge scan for the fixpoint. The new nodes contain
  no `CallDirect` (their operands are atomic `Value`s), so each new arm returns `acc` unchanged; but
  they must be **matched** so the wildcard does not silently swallow a future nested body.
- **`collect_expr`** (`:2820`) — the gensym-reservation scan (**exhaustive, no wildcard**). Every new
  arm must fold in its operand `Value`s (`RefIsNull(arg)` → `collect_value(arg)`; `TableSet(_, i, v)`
  → both; `MemCopy(_, _, d, s, c)` → all three; `RefNull`/`ElemDrop`/`DataDrop` → `acc`; etc.). A
  missed `Var` lets a gensym collide with an IR name → a silently wrong body.

The `state_reaching_closure` fixpoint (`:506`) is otherwise unchanged: seeding on the new table/bulk
ops and closing over `CallDirect` gives exactly the set of functions that must thread the record under
`Threaded`. A function that only builds references (no table/bulk/existing-stateful op) stays **pure**
(`NoState`), preserving its Phase-1 arity — the H7 neutrality for reference-only code.

---

## B. Reference-value lowering (`RefNull`/`RefFunc`/`RefIsNull`)

References are **term-layer values** (H1) — first-class BEAM values that flow as `Var`s. The
load-bearing decision: the **representation is owned by the runtime**, referenced by `emit_core`
through exactly two shared constructs (a **shared null sentinel literal** and the **`{TypeTag,
Closure}` funcref entry**) so `table.get`/`call_indirect`/an empty table slot all agree.

| IR node | Emitted | Disposition | Spec |
|---|---|---|---|
| `RefNull(ty)` | `null_ref_term()` — the keystone-frozen **null sentinel** literal (a build-controlled Core term, e.g. the atom `'$wasm_null'`), the **same** value an empty funcref/externref slot holds | bare value (pure); state-neutral | ref.null [§4.4.2] |
| `RefFunc(name)` | `func_ref_term(name, ctx)` — the `{TypeTag, Closure}` build-controlled entry, i.e. **exactly `element_entry(name, ctx)`** (`func_type_term(sig)` + a `CFun` capturing the compile-time-literal `f<name>` closure) | bare value (pure); state-neutral | ref.func [§4.4.2] |
| `RefIsNull(arg)` | `seam_call(ref_module, "is_null", [emit_value(arg)])` → i32 `0`/`1` (delegates the sentinel test to the runtime so `externref` opacity + the sentinel shape stay runtime-owned) | bare value (pure); state-neutral | ref.is_null [§4.4.2] |

Three deliberate choices:

1. **`RefNull` is a literal, not a seam call.** A null reference is a *constant* and must be
   const-foldable (it appears in element-segment `init` exprs and global inits — §F). Emitting it as a
   build-controlled literal (referenced through one helper `null_ref_term/0`) keeps it pure, keeps the
   D3a walk clean (a literal is not a `call`), and lets `const_fold` handle it. The sentinel is a
   **single shared constant** co-owned with the keystone/07: `emit_core.null_ref_term()` must render
   the byte-identical term `rt_table` stores in an unfilled slot and compares against in
   `call_indirect` (`UninitializedElement`). (Alternative — a `rt_ref:null(ty)` seam call — is
   recorded in Open questions; it is cleaner for encapsulation but breaks const-folding.)
2. **`RefFunc` reuses `element_entry`.** A `funcref` value *is* what a table slot already holds (H1) —
   the `{TypeTag, Closure}` term. `RefFunc $f` therefore lowers to the **same renderer** the element
   segment uses (`element_entry` / `threaded_element_entry`), so `ref.func $f` stored into a table and
   then `call_indirect`-ed is byte-identical to `$f` placed by an element segment. The closure is a
   build-controlled capture of the **compile-time-literal** `f<name>` name — never a data-driven apply
   (D3a). `Error(UnknownFunction)` if `name` is not defined (mirroring `element_entry`).
3. **`RefIsNull` delegates the test.** `externref` is an **opaque host term** (H1/H6): Safe code may
   null-test it but must not inspect it. Emitting `seam_call(ref_module, "is_null", [arg])` keeps the
   sentinel comparison inside the runtime, so the emitter never pattern-matches a host term. (A pure
   `case arg of <sentinel> -> 1; <_> -> 0` is possible and equally D3a-clean, but couples the sentinel
   shape into two sites — the seam call keeps it in one.)

`ref_module` is a new `binding.ref_module` field (or `rt_table`/`rt_state` reused — keystone picks;
see Open questions). Under `Threading(cur)` all three reference ops are **state-neutral**: `cur` flows
through unchanged exactly as `Charge`/`CallHost` do (§G of the P4-02 doc). Since they are not
state-reaching seeds (§A.2), a reference-only function stays pure `'f'/n` — H7-neutral.

**Worked example.** `Let(["r"], RefFunc("f"), RefIsNull(Var("r")))` under `Cell`:

```erlang
let <r> = {{[i32],[i32]}, fun (Args) -> case Args of <[A0]> when 'true' -> apply 'f'/1(A0) end}
in call 'twocore@runtime@rt_table':'is_null'(r)
```

`funcref`/`externref` typing is a validate concern (04); `emit_core` never distinguishes them for
`RefNull`/`RefIsNull` (the sentinel is one value for all reference types) — `ty` on `RefNull` is
carried only so a future GC-reftype layer could pick a typed sentinel; today it is ignored by the
single-sentinel model (documented, not dropped).

---

## C. Table ops lowering (`rt_table` seam)

Tables are typed reference stores (H1). Each op resolves its `table` **name** to a table **index** in
the WASM table index space (imports-first — §E.2) and routes through the `binding.table_module` seam.
The dispositions **reuse the verified Phase-2/4 shapes** — a trapping value uses `emit_trapping_result`
(`:1222`), a trapping zero-result write uses `trapping_effect`+`emit_zero_effect`
(cell)/`emit_threaded_record_effect` (`:927`, threaded), a `#(value, state)` uses
`emit_value_state_pair` (`:899`), a non-trapping write threads the record like `t_global_set`.

| IR node | `rt_table` fn (idx 0 form) | Result / trap | Disposition (Cell → Threaded) |
|---|---|---|---|
| `TableGet(t, i)` | `get(Idx)` | `Result(ref, TableOutOfBounds)` | trapping value → 1 value; **read-only** (threaded: read `St`, `cur` unchanged, like `MemLoad`) |
| `TableSet(t, i, v)` | `set(Idx, V)` | `Result(_, TableOutOfBounds)` | trapping zero-effect → **rebind** `cur` (like `MemStore`) |
| `TableSize(t)` | `size()` | i32 (never traps) | bare value → read-only |
| `TableGrow(t, d, init)` | `grow(D, Init)` | i32 old-size or `-1` (never traps) | bare value (Cell) → `#(i32, St)` pair `emit_value_state_pair` (Threaded) |
| `TableFill(t, o, v, n)` | `fill(O, V, N)` | `Result(_, TableOutOfBounds)` — **eager** | trapping zero-effect → rebind `cur` |
| `TableInit(t, seg, d, s, n)` | `init(SegIdx, D, S, N)` | `Result(_, TableOutOfBounds)` — **eager** | trapping zero-effect → rebind `cur` |
| `TableCopy(dt, st, d, s, n)` | `copy(DstIdx, SrcIdx, D, S, N)` | `Result(_, TableOutOfBounds)` — **eager, memmove** | trapping zero-effect → rebind `cur` |
| `ElemDrop(seg)` | `elem_drop(SegIdx)` | `Nil` / record (never traps) | zero-effect (Cell) → non-trapping record-rebind (Threaded, like `t_global_set`) |

Spec grounding (all held to the finalized WASM 2.0 semantics, the emitter only *routes* — the traps
live inside `rt_table`, 07):
- **`table.get`/`table.set` trap `TableOutOfBounds`** on index ≥ table size
  ([exec/instructions §table.get/set](https://webassembly.github.io/spec/core/exec/instructions.html#table-instructions)).
  `table.get` on an *in-bounds but unfilled* funcref slot returns `ref.null` — a **value, not a trap**
  (the null sentinel of §B), distinct from `call_indirect`'s `UninitializedElement`.
- **`table.grow` returns the previous size, or `-1`** on failure (declared `max`/Safe cap exceeded);
  **never traps** — identical disposition to `memory.grow`. `init` is the reference written into the
  new slots.
- **`table.fill`/`table.init`/`table.copy` are eager** — bounds-checked before any write, trap with
  **no partial effect** (`TableOutOfBounds`); `table.copy` is **memmove** (overlap-correct in either
  direction) — the runtime's job, mirrored on `rt_mem`'s trap-before-write invariant (H6). `table.init`
  from a **dropped** passive segment with non-zero length traps / is a no-op per spec (§F).
- **`elem.drop`** sets the passive element segment to empty (droppable instance state, §F); a drop on
  an *active/already-dropped* segment index is a no-op.

The **table-index resolution** (`table` name → `Int`) uses a `Dict(String, Int)` built once in
`emit_module` from the imports-first table index space (§E.2). `TableInit`/`TableCopy`'s `seg`/table
indices and `ElemDrop`'s `seg` are static immediates — the only *runtime* data reaching a table op is
the operand `Value`s, and the dispatched target inside `call_indirect` is still a build-controlled
closure (D3a holds — the security walk in §Verification proves it).

---

## D. Bulk-memory lowering (`rt_mem` seam)

Each bulk-memory op carries an explicit **memory index** (H3); it routes through
`binding.mem_module` at that index (§E). Same dispositions as §C.

| IR node | `rt_mem` fn (idx 0 form) | Result / trap | Disposition (Cell → Threaded) |
|---|---|---|---|
| `MemFill(m, d, v, n)` | `fill(D, V, N)` | `Result(_, MemoryOutOfBounds)` — **eager** | trapping zero-effect → rebind `cur` |
| `MemCopy(dm, sm, d, s, n)` | `copy(DstMemIdx, SrcMemIdx, D, S, N)` (idx-0 both → `copy(D, S, N)`) | `Result(_, MemoryOutOfBounds)` — **eager, memmove** | trapping zero-effect → rebind `cur` |
| `MemInit(m, seg, d, s, n)` | `init(SegIdx, D, S, N)` | `Result(_, MemoryOutOfBounds)` — **eager** | trapping zero-effect → rebind `cur` |
| `DataDrop(seg)` | `data_drop(SegIdx)` | `Nil` / record (never traps) | zero-effect (Cell) → non-trapping record-rebind (Threaded) |

Spec grounding
([exec/instructions §memory](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions),
the bulk-memory proposal now folded into the living standard):
- **`memory.fill`/`memory.init` are eager** — trap `MemoryOutOfBounds` before any write if the range
  exceeds bounds (**no partial writes**, H6), matching the existing `rt_mem` trap-before-write
  invariant (the Phase-2 `MemStore` grounded fact).
- **`memory.copy` is memmove** — correct for overlapping ranges in either direction; eager-bounds on
  **both** the source and destination range. With `dst_mem == src_mem` it is intra-memory memmove; with
  distinct indices it copies **between two memories** (multi-memory).
- **`memory.init`/`data.drop`** operate on a **passive data segment** by index; `memory.init` from a
  **dropped** segment with non-zero length traps / a zero-length op is a no-op per spec (§F).
- **A zero-length bulk op with an out-of-bounds index still traps** iff the base index itself is out of
  bounds (spec edge — held inside `rt_mem`, not the emitter).

`emit_core` passes the operand `Value`s and the static seg/mem indices straight through — **no
pre-masking, no pre-add, no pre-check** (that would duplicate and could contradict the security
boundary). The trap-before-write all-or-nothing property is why every bulk write is a trapping
`Result`, never a bare effect.

---

## E. Memory-/table-index routing + memory64 width — and H7 byte-identity via **additive emission**

This is the unit's central load-bearing decision. Multi-memory/multi-table adds an index axis, and
memory64 adds an address-width axis, yet a **single-region, index-0** module must compile
**byte-identically** to Phase-4 (H7). The mechanism is **additive emission**: index 0 emits the
*exact* Phase-4 seam call, and only index ≥1 (or a genuinely new feature) adds an argument or a line.

### E.1 The index-0 shorthand (byte-identity)

Route every memory node through one helper that keys on the index:

```gleam
/// Route a memory-node seam call to the right memory. Index 0 emits the EXACT Phase-4 call
/// (no index arg) so a single-memory module is byte-identical (H7); index >= 1 emits the
/// indexed variant `<fn>_at(memidx, …)`. The `t_`-prefixed threaded family is chosen the
/// same way, orthogonally to the index (strategy switch, G5).
fn mem_seam(ctx, sc, memidx, fn0, args) -> CExpr {
  let base = case sc { NoState -> fn0  Threading(_) -> "t_" <> fn0 }
  case memidx {
    0 -> seam_call(ctx.binding.mem_module, base, threaded_args(sc, args))
    _ -> seam_call(ctx.binding.mem_module, base <> "_at", threaded_args(sc, [CInt(memidx), ..args]))
  }
}
```

So `MemLoad(0, …)` emits the byte-identical `call rt_mem:load(Bytes,Signed,W,Addr,Off)`, and
`MemLoad(1, …)` emits `call rt_mem:load_at(1, Bytes,Signed,W,Addr,Off)`. **07/08 must publish the two
signatures** (`load`/`load_at`, `store`/`store_at`, `size`/`size_at`, `grow`/`grow_at`, `fill`/
`fill_at`, `init`/`init_at`, `copy`/`copy_at`, `data_drop`/`data_drop_at`, and the `t_*` mirrors) — the
index-0 head is the frozen Phase-4 one, unchanged. `memory.copy` between two memories is inherently
indexed (`copy_at(DstMemIdx, SrcMemIdx, …)`); its index-0/index-0 case must degenerate to the Phase-4
`copy(D, S, N)` so an intra-single-memory copy is byte-identical. The **table** ops route the same way
through a `table_seam` helper keyed on the table index (index-0 `call_indirect`/`get`/… unchanged).

*(Precise ABI shape — a separate `_at` head vs. an always-present optional leading index — is a
co-design with 07/08; the invariant this unit fixes is: **the index-0 emission is byte-for-byte
Phase-4**. The two-head form is the recommendation because an always-index form changes every Phase-4
call site.)*

### E.2 The index space (imports-first)

`MemLoad`/etc. already carry a resolved `mem: Int` from `lower` (05). **Table** ops carry a `table:
String` name (provisional asymmetry — flagged in Open questions), so `emit_module` builds a
`Dict(String, Int)` table-name → index over the **imports-first** WASM index space: imported tables
(in import order) then defined tables (in `module.tables` order). The same ordering seeds the tables in
the `StateDecl` (§F), so a name resolves to the slot the runtime holds. `ExportTable`/`ExportMemory`
carry an index/name resolved the same way (09 consumes them at the export boundary). For the H7 case
(no imported tables, one table) every name resolves to `0` → byte-identical.

### E.3 memory64 is transparent to the emitter

`MemoryDecl.idx_type ∈ {Idx32, Idx64}` (H3). For a 64-bit memory the address operand is an `i64` bit
pattern and offsets may exceed 2³². **`emit_core` needs no change for memory64**: it already passes
`Addr` and `Off = CInt(offset)` as raw bignum `Int`s to `rt_mem`, which computes `ea =
unsigned(addr) + offset` as a bignum and traps iff `ea + bytes > byte_len` (the Phase-2 grounded
fact — no wrap, the runtime's job). The memory's `idx_type` travels **in the state handle** (seeded via
the `StateDecl`, §F), so `rt_mem` reads the width from the memory it routes to, **not** from an emitter
argument. The one obligation: emit the (possibly > 2³²) `offset` as a plain `CInt` (already true — Core
integers are bignums) and never assume a 32-bit address. This keeps memory64 confined to frontend +
runtime (H3/G5) with the emitter passing raw operands through — 32-bit memories are byte-identical. *(If
07/08 find they need an explicit width hint at the seam rather than in the handle, that is one extra
static immediate; recorded in Open questions. Per H8 memory64 is the deferrable half — if cut, this
section is inert and 32-bit routing stands unchanged.)*

---

## F. Passive/droppable segments + the extended `instantiate`/`StateDecl` seam

`ElementSegment` becomes `ElementSegment(mode, ref_ty, init)` with `init: List(Expr)` (each a
`RefFunc`/`RefNull` const-expr) and `mode ∈ {ElemActive(table, offset), ElemPassive, ElemDeclarative}`;
`DataSegment` becomes `DataSegment(mode, bytes)` with `mode ∈ {DataActive(mem, offset), DataPassive}`.
Passive segments carry **droppable instance state** (H2): a runtime value that `data.drop`/`elem.drop`
mark empty, and `memory.init`/`table.init` copy from. This state **threads the existing state seam**
(`cell` in the pdict, `threaded` in the record — no new seam), so `emit_core` must **seed it** at
instantiation. The extended `instantiate/0` (both `emit_instantiate_cell` and
`emit_instantiate_threaded`) does, in WASM instantiation order
([exec/modules §instantiation](https://webassembly.github.io/spec/core/exec/modules.html#instantiation)):

1. **Seed the `StateDecl`** (`state_decl_term`, §F.1) — now carrying the **memories vector**, the
   **passive data/element** segment contents (keyed by global segment index), the **imported-state**
   slots, and (unchanged) the first table + globals.
2. **Active element segments** (`ElemActive`): map each `init` expr to a table entry
   (`RefFunc` → `element_entry`, `RefNull` → the sentinel) and `rt_table:init_elem(TblIdx, Off,
   Entries)` — then the segment is **dropped** (marked empty), per spec.
3. **Active data segments** (`DataActive`): `rt_mem:init_data(MemIdx, Off, Bytes)` — then dropped.
4. **`start`** — unchanged (threaded-start threads the record, §E of the P4-02 doc).

`ElemDeclarative` segments produce **no runtime effect** (validation-only — they declare functions
`ref.func`-usable); the emitter skips them entirely.

### F.1 `state_decl_term` — additive so H7 holds

The current `state_decl_term` (`:2408`) builds `{state_decl, Mem, Globals, Table}` from
`module.memory`. Under IR3 it renders the frozen `StateDecl` shape (owned with 09/keystone), extended
with a **memories vector**, **passive-segment maps**, and **imported-state slots**. The H7 rule: the
rendered term is **byte-identical to Phase-4 when** `len(memories) ≤ 1`, there are no passive/declarative
segments, and no non-function imports. Concretely, the recommendation (to be pinned with 09):

- `Mem` stays the single `rt_mem:fresh(Min, Max, Cap)` handle when `len(memories) == 1` (or the 0-page
  form when `[]`); a **memories vector** term `[fresh0, fresh1, …]` is rendered **only** when `len ≥ 2`
  — so the neutral Decl is unchanged. Each additional memory renders its `idx_type` (`Idx32`/`Idx64`)
  so `rt_mem` knows the width (§E.3).
- **Passive data/element** contents render as `[{SegIdx, Bytes}…]` / `[{SegIdx, Entries}…]` lists,
  **empty (and therefore byte-identical to an omitted field) when there are none.** Active segments do
  **not** appear here (they are written then dropped in steps 2–3) — the runtime records their index as
  already-dropped so `init`-from-them is a no-op.
- **Imported-state** slots (`ImportGlobal`/`ImportTable`/`ImportMemory`) render as placeholder
  references the linker (09) fills from the import map; **absent when function-only** (the H7 case). An
  imported global's init is **not** const-folded here (it is provided state, not a constant) — a
  `GlobalGet` in a const-init still fails closed with `Error(NonConstInit)` unless 09's contract
  supplies it.

Because the additions are **empty/omitted in the neutral case**, `emit_module(phase4_module, safe())`
prints byte-for-byte the pre-P5 `.core` (H7). `const_fold` (`:2603`) extends to accept `RefFunc`/
`RefNull` (returning the entry term / sentinel) for element-segment `init` exprs — the only new
const-expr shapes; every other non-constant shape still fails closed.

### F.2 Both strategies

The `Cell` path chains the new seeds as zero-result ordered effects (`chain_effects`, `:2389`); the
`Threaded` path threads them as record-rebinds (`threaded_elem_wrappers`/`threaded_data_wrappers`,
`:2145`), reusing `record_result_case`. Passive-segment seeding is one added seam call
(`rt_mem:seed_passive_data`/`rt_table:seed_passive_elem`, or a `StateDecl` field — co-design with
08/07/09) emitted **only when passive segments exist**, so the neutral instantiate is byte-identical.

---

## G. Both state strategies — the seam-reuse map

Every new state-touching op has a `Cell` arm and a `Threading(cur)` arm, chosen exactly as the Phase-4
seam (`is_threaded`/`sc`). The lowering **shapes are already built** — this unit only wires the new ops
to them:

| Runtime shape | Cell helper | Threaded helper | New ops using it |
|---|---|---|---|
| trapping value → 1 value, read-only | `emit_trapping_result` | `emit_trapping_result` (read `St`, `cur` unchanged) | `TableGet` |
| trapping zero-result write | `trapping_effect`+`emit_zero_effect` | `emit_threaded_record_effect` (rebind `cur`) | `TableSet`/`TableFill`/`TableInit`/`TableCopy`/`MemFill`/`MemCopy`/`MemInit` |
| `#(value, state)` | bare value | `emit_value_state_pair` (rebind `cur`) | `TableGrow` |
| non-trapping write | `emit_zero_effect` | rebind `cur` (like `t_global_set`, `:876`) | `ElemDrop`/`DataDrop` |
| bare pure value | `apply_cont` | `apply_cont`, `cur` unchanged | `RefNull`/`RefFunc`/`RefIsNull`, `TableSize` |

Under `Threaded`, the state-reaching new ops **rebind `cur`** on every write, making bulk-op ordering a
visible dataflow edge through `St` (the §G stronger-than-Cell barrier from P4-02) — no optimizer can
reorder a `memory.fill` past a dependent `memory.copy`. The record stays a fixed-size box, so a
bulk-op loop threads in **constant space** (the G4 template, unchanged — the new ops add no loop-carried
data beyond the box).

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives the surface growth.** Every new op is `seam_call(binding.{ref,
  mem,table,state}_module, "<fn>"/"t_<fn>", […])` — a fixed runtime-module atom, a literal function
  atom, operands as ordinary Core values/immediates. The `RefFunc`/element closures are still
  build-controlled captures of compile-time-literal `f<name>` names; the memidx/table-idx/seg indices
  are **static immediates**, not runtime dispatch keys. The only runtime data reaching a control
  transfer is still the `call_indirect` integer index. The structural walk
  (`assert_calls_are_runtime` + the `apply`-is-`FName` walk) passes with the **same** allow-set (plus
  `binding.ref_module` if the keystone adds one).
- **Fail-closed for the new surface (H6).** A table access out of range traps `TableOutOfBounds`; a
  null reference used where a value is required (a null `call_indirect` slot) traps
  `UninitializedElement`; a bulk op out of range traps `MemoryOutOfBounds`/`TableOutOfBounds` **before
  any write** (eager, no partial effect); `memory.init`/`table.init` from a dropped segment traps.
  Every trap is a `rt_*` `{error, R}` → `raise_trap` (`:1336`) → the catchable `{wasm_trap, Kind}`
  channel. The worst case of a bounds bug is a wrong/missing trap or a node-safe crash — **never a host
  escape**.
- **`externref` opacity** is preserved: `emit_core` never pattern-matches a reference term; `RefIsNull`
  delegates the sentinel test to the runtime, and a reference flows as an opaque `Var`. Safe code can
  hold/pass/store/null-test it but cannot forge or read it.
- **Floats-as-bits (D5) and const-space (G4) unchanged.** References are BEAM terms, not doubles;
  memory stays raw bytes; the new ops are ordinary reduction-consuming BEAM calls, so preemption and
  constant-space loops are unaffected.
- **H7 conformance-neutrality is a security-relevant invariant too:** the additive-emission rule means
  a Phase-1..4 module's authority surface is *unchanged* — no new call, no new argument — so the prior
  D3a proof carries over unmodified.

---

## Verification — Definition of Done (D8)

Tests assert **WebAssembly-spec behavior**, not whatever the code emits (no change-detector tests);
cite the spec section / H-decision in each. "Done" = the suite below passes + the conformance gate
(`fail == 0`), never "it compiles."

1. **AST-shape goldens** (`emit_core_test`), one per new construct, asserting *structure* (not a
   brittle string), under **both** `Cell` and `Threaded`:
   - `RefNull` → the shared sentinel literal (pure, no `call`); `RefFunc` → the `{TypeTag, CFun …}`
     entry byte-identical to the same function's element-segment entry (assert equality of the two
     rendered terms); `RefIsNull` → a bare `call ref:is_null/1`. Cite §4.4.2.
   - `TableGet` → a `case`/`raise` over `rt_table:get` (trapping value); `TableSet` → a zero-effect /
     record-rebind over `rt_table:set`; `TableSize` → bare `rt_table:size`; `TableGrow` → bare i32
     (Cell) / `{V,St2}` (Threaded); `TableFill`/`TableInit`/`TableCopy` → eager trapping writes;
     `ElemDrop` → a non-trapping effect / record-rebind. Cite §4.4.6 + table.grow-returns-`-1`.
   - `MemFill`/`MemCopy`/`MemInit` → eager trapping writes; `DataDrop` → non-trapping. Cite §4.4.7.
   - A **state-reaching** function using any table/bulk op emits `'f'/(n+1)` threading the record under
     `Threaded`; a **reference-only** function stays pure `'f'/n` (assert `RefFunc` alone does **not**
     force threading — the H7-neutral classification of §A.2).
2. **Memory-index routing** (`emit_core_test`): `MemLoad(0, …)` emits the **byte-identical** Phase-4
   `rt_mem:load(...)` (no index arg); `MemLoad(1, …)` emits `rt_mem:load_at(1, …)`; `MemCopy(0,0,…)` →
   `copy(D,S,N)`, `MemCopy(1,0,…)` → `copy_at(1,0,…)`. Cite H3/H7 + multi-memory (memory instructions
   carry a memidx).
3. **`instantiate/0` goldens** for the new segment surface: an **active funcref** element segment via
   `init: [RefFunc …]` seeds byte-identically to the Phase-4 `funcs`-based output (H7 regression); a
   **passive** data/element segment seeds droppable state (a `seed_passive_*` line / `StateDecl` field
   present) and is **absent** when there are none; a **declarative** element segment produces no seed;
   element **before** data **before** start (cite instantiation order). Under `Threaded` each is a
   record-rebind returning the final `InstanceState`.
4. **H7 byte-identity** (the non-negotiable): `emit_module(phase4_fixture, safe())` and
   `emit_module(phase4_fixture, Threaded)` printed to `.core` are **bit-for-bit** unchanged from the
   pre-P5 emission — for a fixture with one 32-bit memory, funcref-only active elements, function-only
   imports, and **no** bulk/ref ops. The existing `emit_core_test`, `emit_core_security_test`, and
   conformance goldens stay green under every shipped `(state_strategy × mem_tier)`.
5. **D3a security walk extended & green** (`emit_core_security_test`): grow the `stateful_module()`
   fixture to exercise `RefNull`/`RefFunc`/`RefIsNull`, every table op, every bulk-memory op, a
   **second** memory (memidx 1), a **passive** data + element segment, and `TableCopy` between two
   tables — then assert (a) every `CCall` targets a fixed `Binding` runtime atom with a literal
   function atom (extend `runtime_modules` with `ref_module` if added); (b) every `CApply` is a static
   local `FName` (the `RefFunc`/element closures are literal — no data-driven apply); (c) the new seam
   calls are delegated to the runtime (`assert has_call(m, table_module, "fill")`,
   `has_call(m, mem_module, "copy_at")`, `has_call(m, table_module, "elem_drop")`, …) and the
   `call_indirect`/bulk faults reach `rt_trap:raise`. Run it under `Cell`, `Threaded`, **and** the
   `unsafe()` posture — all three must pass with the same allow-set.
6. **End-to-end** (`emit_core_e2e_test`; green once 07/08/09 land — Concurrency), hand-built IR3 →
   `emit_module` → `build_beam` → `instantiate/0` → invoke, asserting **spec-correct** results and
   **byte-identical `Cell` vs `Threaded`**:
   - `ref.func`/`ref.is_null`: a non-null `funcref` is not null; `ref.null` is null; a `table.get` of an
     unfilled funcref slot returns a **null** ref (not a trap) and `ref.is_null` of it is `1`.
   - `table.set` then `table.get` round-trips a reference; `table.get` out of range **traps**
     `TableOutOfBounds`; `table.grow` returns the **old** size then a get of a grown slot returns the
     `init` ref; grow past the cap returns `-1`.
   - `memory.fill` writes the byte run; `memory.copy` is **overlap-correct** (a forward-overlapping copy
     matches memmove, not a naive forward loop); an out-of-range `memory.fill`/`copy`/`init` **traps
     with no partial write** (read the untouched bytes after the trap).
   - `memory.init` from a passive segment writes it; `data.drop` then `memory.init` from the dropped
     segment with non-zero length **traps**; the same for `elem.drop` + `table.init`.
   - a **two-memory** module: `i32.store` to memory 1 then `i32.load` from memory 1 round-trips and does
     **not** disturb memory 0 (`memory.size` of each is independent).
   - (memory64, if not cut per H8) a 64-bit memory: a store/load at an address ≥ 2³² round-trips and a
     large-offset access beyond bounds traps.
   Each case is diffed against the `Cell` oracle (same IR, `state_strategy: Cell`) — the H7 bar.
7. **No regression.** `gleam format --check src test` clean; `gleam build` **zero warnings**;
   `gleam test` stays green (≥906, conformance 15747/411/0 on the pre-P5 corpus — the neutral path is
   untouched). Every new public/private function carries a contract doc comment (D8).

**Proof of goal:** tests 1–3 + 6 are the unit's proof — a WASM module hand-built as IR3 that uses
references, typed tables, bulk memory, and a second memory compiles, instantiates, and runs
spec-correctly on the BEAM under **both** state strategies, with every new trap fail-closing, the
security walk green, and a Phase-4 module still byte-identical.

## What this unit leaves

- **Units 07/08/09** implement the `rt_table`/`rt_mem`/`rt_state`/`rt_ref` **bodies** behind the seam
  calls this unit emits (the two-head `_at` ABI, the passive-segment state, the null sentinel, the
  memories vector, the imported-state wiring); this unit's e2e is their integration check.
- **Unit 05 (lower)** produces the IR3 this unit consumes — the resolved `mem: Int` indices and the
  `init: List(Expr)` element form; the table-name→index resolution lives here (unless 05 pre-resolves,
  per Open questions).
- **Unit 09** owns the linker that fills the `StateDecl` imported-state slots and the `spectest`
  provider; this unit renders the slot term shape and the imports-first index ordering it consumes.
- **Unit 11** proves the conformance-expansion headline (reftypes/bulk/multi-mem/mem64/spectest/WAT
  categories light up, `fail == 0`) under the full `(mode × state_strategy × mem_tier)` matrix.

## Open questions (for the planner / cross-unit sync)

- **The null sentinel: shared literal vs. seam call.** This unit recommends a **keystone-frozen shared
  literal** (`null_ref_term/0`) so `ref.null` is a pure, const-foldable value equal to an unfilled
  table slot and to `call_indirect`'s null test. That couples the sentinel *shape* into `emit_core`
  and `rt_table` (they must agree byte-for-byte). Alternative: a `rt_ref:null(ty)` seam call (full
  encapsulation) — but then element/global const-inits cannot const-fold and the `StateDecl` must carry
  an unevaluated marker. **Pin the sentinel constant + its owner (keystone) so both sides agree.**
- **`ref_module` — new `Binding` field or reuse?** `RefIsNull` needs a runtime home. Adding
  `binding.ref_module` (a new `rt_ref` module) is cleanest and keeps the D3a allow-set explicit;
  reusing `table_module`/`state_module` avoids a `Binding`/`runtime_modules` change. Keystone/07 to
  decide; either way the security walk must include it.
- **The `_at`-head ABI vs. an always-indexed head.** Byte-identity (H7) forces the index-0 call to be
  the *exact* Phase-4 head. The two-head recommendation (`load`/`load_at`) preserves it without
  touching Phase-4 call sites; an always-leading-index head would require rewriting every Phase-4
  emission and rt_mem body. **Confirm the two-head shape with 07/08** so the frozen sigs match what
  this unit emits.
- **Table nodes carry a `String` name, memory nodes an `Int` index (provisional asymmetry).** This unit
  builds an imports-first name→index map for tables. Cleaner would be for **05 (lower) to pre-resolve
  table nodes to `Int` indices** (symmetry with memory), removing the emitter's need to know the import
  ordering. Propose the IR carry `table: Int` on the table nodes; recorded for the reconcile pass.
- **`StateDecl` memories-vector + passive-segment + imported-state ownership (08/09/keystone).** The
  overview §4 already flags the `rt_state` memories-vector ownership as a reconcile seam. This unit
  *renders* the Decl term (`state_decl_term` lives here) but the `StateDecl` **type** is 09/keystone.
  Pin: (a) the Decl degenerates to the Phase-4 bare-handle form at `len(memories) ≤ 1` (H7); (b) the
  passive-segment index keying (global data/elem index space); (c) whether passive seeding is a Decl
  field or a separate seam line (this unit prefers a separate line so the neutral Decl is untouched).
- **memory64 width hint at the seam (if 08 needs it).** This unit routes memory64 transparently (width
  lives in the memory handle). If `rt_mem`'s `_at` bodies need the width as an explicit immediate, that
  is one static arg on the indexed head — decide with 08. Per H8, if memory64 is cut, §E.3 is inert and
  32-bit routing stands.
- **`RefNull(ty)` ignores `ty` under the single-sentinel model.** Today one sentinel serves both
  reference types (they are only null-tested, never typed-dispatched in Phase 5). Confirm the keystone
  does not want a per-type sentinel (a future GC-reftype layer might) — if it does, `null_ref_term`
  takes `ty` and the two-site agreement widens.
