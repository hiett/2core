# Unit P5-05 — WASM lower extension (AST3 → IR3)

> **One owner. Extends `src/twocore/frontend/wasm/lower.gleam` (single-owner, additive).
> Wave A — runs behind the keystone freeze, in parallel with 03 (decode), 04 (validate),
> 06 (emit_core), 07/08 (runtime).** Read [`00-overview.md`](00-overview.md) (H1–H8) and the
> keystone doc (P5-01) first. Freeze deps: **`«IR3-FROZEN»`** (the IR3 node shapes you emit)
> and **`«WASM-AST3»`** (P5-03's day-1 type stub — the new AST constructors you match).

---

## Context

`lower.gleam` already does the two WASM-frontend jobs together in one SSA naming context
(`lower/1` → `go/3`): stack-elimination/SSA (the operand stack becomes named `ir.Value`
bindings — there is **no runtime stack**) and structure → **named-label IR** (a numeric branch
depth NEVER reaches the IR — D6). Phase 1 lowered the integer/control slice; Phase 2 (unit
P2-09) completed WASM 1.0 — linear memory (`MemLoad`/`MemStore`/`MemSize`/`MemGrow`), one table +
`call_indirect`, globals, the full float/conversion surface, `select` (→ the existing `If`, no
new node), and the module-level table/element/global/data declarations. It returns a typed
`LowerError` (never a panic) for anything out of scope — today `select_t`/reference ops and any
non-constant-literal init expression.

Phase 5 is the first phase since Phase 2 to **grow the IR**, and lower is where the new
WebAssembly *instruction* surface becomes IR3. This unit is still a **pure syntactic mapping**:
validation (P5-04) has already proved the module well-typed and in scope; lowering produces IR3
nodes faithful to each opcode's spec meaning. The **runtime behaviour** — bounds checks, the
overlap-correct copy, the eager trap-before-write, passive-segment drop state, the reference
value representation, the memory-index vector, `i64` addressing — belongs to the runtime units
(P5-07 `rt_table`, P5-08 `rt_mem`) and emit_core (P5-06). Lower emits the **tier-agnostic** IR3
node and nothing else. Per **H2** every new node is an **effect** (a barrier): lower must
preserve their program order and never drop a zero-result effect. lower already does this
structurally — it is a straight-line walk, and zero-result effects are sequenced into the
continuation as `Let([], …, cont)`, never discarded (the P2-09 `emit_effect` shape).

The new surface lower must map: the reference instructions (`ref.null`/`ref.func`/`ref.is_null`),
the table instructions (`table.get/set/size/grow/fill` + the `0xFC` `table.init/copy` +
`elem.drop`), the bulk-memory `0xFC` ops (`memory.init/copy/fill` + `data.drop`), typed `select`
(`select_t`, → the existing `If` merge — still no new node), the memory-index immediate on every
memory-touching node (multi-memory), the `i64` address width (memory64 — a value-width fact, not
a lower branch), and the module-shape growth: `Module.memories` (a list), reference-typed
`TableDecl`, passive/declarative element segments and passive data segments (→ IR `ElemMode`/
`DataMode`), element items as ref-producing const-exprs, and the non-function import/export
variants. Throughout it preserves the existing named-label + stack-elim/SSA discipline and the
`funcidx → "f<idx>"` / `globalidx → "g<idx>"` / `tableidx → "t<idx>"` naming conventions.

## Goal

Lower every new Phase-5 WASM op and every grown module section into IR3, preserving the existing
named-label + stack-elim/SSA model and the Phase-1 mutable-locals → `LoopParam` mechanism. After
this unit a validated Phase-5 `.wasm`/`.wat` module produces a complete `ir.Module` — memories
(list), reference-typed tables, active/passive/declarative elements with ref-init, active/passive
data, non-function imports/exports, and every reference/table/bulk instruction lowered — ready
for emit_core (P5-06). **Conformance-neutral by default (H7):** a module with one 32-bit memory,
funcref-only active elements, function-only imports, and no bulk/ref ops lowers to **byte-identical**
IR3 to Phase-4 (every new immediate defaults away — `mem` index `0`, `FuncRef` reftype,
`ElemActive`/`DataActive`).

## Files owned

- `src/twocore/frontend/wasm/lower.gleam` — **EXTEND** (single owner).
- `test/twocore/frontend/wasm/lower_test.gleam` — the unit's tests (mirrors `src/`; extend).

No freeze/publish-day-1 stub: lower is downstream of two freezes; it publishes nothing others
depend on (P5-06 emit_core consumes the IR3 nodes it emits, but via `«IR3-FROZEN»`, not via lower).

## Depends on (freeze milestones)

- **`«IR3-FROZEN»`** (P5-01) — the IR3 node shapes you emit. Concretely (per the provisional
  surface; the keystone is authoritative):
  - `ir.ValType` gains `TFuncRef`, `TExternRef`; a new `ir.RefType { FuncRef ExternRef }`.
  - New `ir.Expr` nodes: `RefNull(ty)`, `RefFunc(fn_name)`, `RefIsNull(arg)`; `TableGet`/
    `TableSet`/`TableSize`/`TableGrow`/`TableFill`/`TableInit`/`TableCopy`/`ElemDrop`;
    `MemFill`/`MemCopy`/`MemInit`/`DataDrop`.
  - Existing memory nodes gain a leading `mem: Int` field: `MemSize(mem)`, `MemGrow(mem, delta)`,
    `MemLoad(mem, op, addr, offset, result)`, `MemStore(mem, op, addr, value, offset)`.
  - `ir.Module.memory: Option(MemoryDecl)` becomes `ir.Module.memories: List(MemoryDecl)`;
    `MemoryDecl(min_pages, max_pages, idx_type)` gains `idx_type: IdxType` (`Idx32`/`Idx64`);
    `TableDecl(name, ref_ty, min, max)` gains `ref_ty: RefType`; `ElementSegment(mode, ref_ty,
    init)` becomes mode-tagged with `ElemMode { ElemActive(table, offset) ElemPassive
    ElemDeclarative }` and `init: List(Expr)`; `DataSegment(mode, bytes)` with `DataMode {
    DataActive(mem, offset) DataPassive }`; `ImportDecl` gains `ImportGlobal`/`ImportTable`/
    `ImportMemory`; `ExportDecl` gains `ExportGlobal`/`ExportTable`/`ExportMemory`.
  Until it lands, stub against §A/§B of the keystone doc; the *opcode→IR* mapping below is fixed
  regardless of the exact field spelling.
- **`«WASM-AST3»`** (P5-03, published day 1) — the new AST constructors you match (§A). Until it
  lands, stub against the names in §A and re-sync when 03 publishes; the mapping is fixed.
- **P5-04 (validate)** — the `TypedModule` this unit consumes. lower needs three **new** carried
  facts from the validator (a seam — see Open questions): `table_types: List(ir.RefType)` (per
  tableidx, imports ++ defined — to type a `table.get` result and populate `TableDecl.ref_ty`),
  and the per-kind import offsets `imported_global_count`/`imported_table_count`/
  `imported_mem_count` (the index-space offsets, mirroring the existing `imported_func_count`).
  Until they land, derive them locally from `module.imports` (fail-closed) and re-sync.

## Scope — in / out for Phase 5

**In:**
- **Reference instructions** → `RefNull`/`RefFunc`/`RefIsNull` (§B).
- **Table instructions** → `TableGet`/`TableSet`/`TableSize`/`TableGrow`/`TableFill`/`TableInit`/
  `TableCopy`/`ElemDrop` (§C).
- **Bulk memory** `memory.init/copy/fill` + `data.drop` → `MemInit`/`MemCopy`/`MemFill`/`DataDrop`
  (§D).
- **Typed `select`** (`select_t`, 0x1C) → the existing `If` value-merge, using the immediate type
  (§E) — **no new IR node** (as with plain `select`).
- **The memory-index immediate** threaded onto `MemLoad`/`MemStore`/`MemSize`/`MemGrow` and the
  bulk-memory nodes (multi-memory, §F). Default `0`.
- **memory64** — the address/count operands flow as-is (they are `ir.Value`s the validator typed
  `TI64`); lower carries the `IdxType` only on `MemoryDecl` (§F/§G). No instruction-level branch.
- **Module-shape growth** (§G): `Module.memories` (list), reference-typed `TableDecl`, active/
  passive/declarative `ElementSegment` with ref-producing `init`, active/passive `DataSegment`,
  the non-function `ImportDecl`/`ExportDecl` variants, index-space threading (imports ++ defined).
- **Reference/`i64` const-expr lowering** for element items, global inits, and active offsets (§H).

**Out (cite the deferral):**
- **SIMD** (`v128` + lane ops) — **Phase 6** (H8). Any SIMD op ⇒ `Error(Unsupported(_))`.
- **GC-proposal reference types** (typed function refs, `struct`/`array`/`i31`, `ref.as_non_null`,
  `br_on_null`, `call_ref`) — later (H8). Reference types are `funcref`/`externref` **only**.
- lower does **not** validate (P5-04), does not optimize (no `ir_opt` — this is a syntactic map),
  and does not enforce bounds/overlap/drop semantics (the runtime + emit_core — P5-06/07/08).
- The **actual import wiring / link contract** (`«INSTANTIATE3»`) is P5-09's; lower only surfaces
  the `ImportDecl`/`ExportDecl` declarations from the AST.

---

## A. The AST3 constructors this unit matches (the P5-03 seam)

lower matches `frontend/wasm/ast.gleam` constructors; the byte encoding is P5-03's. These are the
names lower expects (stub against them; re-sync when P5-03 publishes `«WASM-AST3»`). Opcodes are
given for cross-reference to [binary/instructions](https://webassembly.github.io/spec/core/binary/instructions.html);
they are **not** lower's concern — they anchor which AST node each maps to.

| WASM instruction | opcode | assumed AST3 constructor |
|---|---|---|
| `ref.null t` | `0xD0 t:reftype` | `ast.RefNull(ref_ty: ast.RefType)` |
| `ref.is_null` | `0xD1` | `ast.RefIsNull` |
| `ref.func x` | `0xD2 x:funcidx` | `ast.RefFunc(func: Int)` |
| `table.get x` | `0x25 x:tableidx` | `ast.TableGet(table: Int)` |
| `table.set x` | `0x26 x:tableidx` | `ast.TableSet(table: Int)` |
| `table.init x y` | `0xFC 12 y:elemidx x:tableidx` | `ast.TableInit(elem: Int, table: Int)` |
| `elem.drop x` | `0xFC 13 x:elemidx` | `ast.ElemDrop(elem: Int)` |
| `table.copy x y` | `0xFC 14 x:tableidx y:tableidx` | `ast.TableCopy(dst: Int, src: Int)` |
| `table.grow x` | `0xFC 15 x:tableidx` | `ast.TableGrow(table: Int)` |
| `table.size x` | `0xFC 16 x:tableidx` | `ast.TableSize(table: Int)` |
| `table.fill x` | `0xFC 17 x:tableidx` | `ast.TableFill(table: Int)` |
| `memory.init x` | `0xFC 8 x:dataidx 0x00` | `ast.MemoryInit(data: Int, mem: Int)` |
| `data.drop x` | `0xFC 9 x:dataidx` | `ast.DataDrop(data: Int)` |
| `memory.copy` | `0xFC 10 0x00 0x00` | `ast.MemoryCopy(dst_mem: Int, src_mem: Int)` |
| `memory.fill` | `0xFC 11 0x00` | `ast.MemoryFill(mem: Int)` |
| `select t` (typed) | `0x1C vec(valtype)` | `ast.SelectT(types: List(ast.ValType))` |

**Memory-index immediate on load/store/size/grow.** Under multi-memory the memarg's high align
bit signals a following memidx ([binary/instructions](https://webassembly.github.io/spec/core/binary/instructions.html);
the multi-memory proposal). lower assumes the decoded index lands on the memarg: `ast.MemArg(align,
offset, mem)` gains `mem: Int` (default `0`), and `ast.MemorySize(mem: Int)` / `ast.MemoryGrow(mem:
Int)` gain the index (were nullary). If P5-03 instead threads memidx as a separate instruction
field, only the *accessor* in each `go` arm changes — the mapping is fixed.

**Module-shape growth (AST3).** lower assumes: `ast.ValType` gains `FuncRef`/`ExternRef` and an
`ast.RefType { FuncRef ExternRef }`; `ast.TableType(ref_ty, limits)` gains `ref_ty`;
`ast.MemType(limits, idx_type)` gains an index type (from the limits flag — the memory64 bit);
`ast.ElementSegment` becomes mode-tagged (`ElemActiveSeg(table, offset, init)` / `ElemPassiveSeg(
ref_ty, init)` / `ElemDeclarativeSeg(ref_ty, init)` where `init` is a list of const-expr
instruction lists, or the legacy `funcs: List(Int)` sugar for the flag-0 form); `ast.DataSegment`
gains a passive form; `ast.Module` gains `imports: List(Import)` with non-function kinds and the
per-kind imported counts. The exact spelling is P5-03's; lower reads the mode + reftype + init and
maps them (§G). **These are provisional AST3 shapes — the concrete constructors are P5-03's to
freeze; this doc names them so the mapping is unambiguous.**

---

## B. Reference instruction lowering

References are **term-layer values** (H1): a `funcref` is `null | #(FuncType, target)` (the
Phase-2 type-tagged table entry, promoted to a first-class value); an `externref` is `null | any
opaque BEAM term`. lower does not construct those representations — it emits the three
value-producing `Expr` nodes and lets emit_core/runtime realise them. Per
[exec/instructions#reference-instructions](https://webassembly.github.io/spec/core/exec/instructions.html#reference-instructions).

New `go/3` arms (inserted before the numeric fall-through `_`):

```gleam
ast.RefNull(rt) ->
  emit_nullary(ir.RefNull(to_ir_reftype(rt)), reftype_valtype(rt), tail, ctx, st)
ast.RefFunc(f) ->
  emit_nullary(ir.RefFunc("f" <> int.to_string(f)), ir.TFuncRef, tail, ctx, st)
ast.RefIsNull ->
  emit_value_op_t(1, ir.TI32, fn(a) { ir.RefIsNull(one(a)) }, tail, ctx, st)
```

| op | stack type | operands (push order) | IR node | result `ValType` |
|---|---|---|---|---|
| `ref.null t` | `[] → [t]` | — | `RefNull(to_ir_reftype(t))` | `reftype_valtype(t)` (`TFuncRef`/`TExternRef`) |
| `ref.func x` | `[] → [funcref]` | — | `RefFunc("f"<>x)` | `TFuncRef` |
| `ref.is_null` | `[t] → [i32]` | `[r]` | `RefIsNull(r)` | `TI32` |

- `RefNull`/`RefFunc` pop nothing and push one reference value (reuse `emit_nullary`); `RefIsNull`
  pops one reference and pushes an i32 `0/1` (reuse `emit_value_op_t`). Every one records its
  result type in `var_types` (§I), so a later `select`/`select_t`/`table.set` recovers the operand
  reftype.
- `RefFunc`'s target `"f"<>x` is the **same** name `lower_func` gives funcidx `x` (§G's naming
  convention), so the reference resolves to a real `Function`. `x` is the absolute funcidx (imports
  ++ defined); with a host-imported target the name still resolves through the instance's function
  space (P5-06/09's job).
- **`ref.func`'s declared-funcref set** is a *validation* rule ([valid/instructions](https://webassembly.github.io/spec/core/valid/instructions.html):
  `ref.func x` is valid only if `x ∈ C.refs`). lower does **not** re-check it. The declared set is
  surfaced to the runtime through the **declarative element segments** (§G) — lower preserves them
  as `ElemDeclarative`, so emit_core/instantiate knows which funcs must be constructible as
  funcrefs. lower keeps its defensive `Error(UnknownFuncIndex)` only as fail-closed insurance.

Helpers:

```gleam
/// Map an AST reftype to the IR reftype.
fn to_ir_reftype(rt: ast.RefType) -> ir.RefType {
  case rt { ast.FuncRef -> ir.FuncRef  ast.ExternRef -> ir.ExternRef }
}
/// The IR value type carrying a given reference type.
fn reftype_valtype(rt: ast.RefType) -> ir.ValType {
  case rt { ast.FuncRef -> ir.TFuncRef  ast.ExternRef -> ir.TExternRef }
}
```

`to_ir_vt/1` (the existing WASM→IR value-type map) gains the two reftype arms (`ast.FuncRef ->
ir.TFuncRef`, `ast.ExternRef -> ir.TExternRef`) so blocktypes, params, and locals of reference
type lower correctly.

---

## C. Table instruction lowering

Tables are typed reference stores (H1). A `table.get`'s result type is the **table's element
reference type**, so lower needs the per-tableidx reftype — carried in `LCtx.table_types` (from
`TypedModule`, §Depends-on). Per
[exec/instructions#table-instructions](https://webassembly.github.io/spec/core/exec/instructions.html#table-instructions).

Operand orders follow the spec stack types exactly (the value nearest the top is popped first;
`take_push_order(stack, n)` returns them **deepest-first**, matching the type notation left→right):

| op | stack type | operands (push order) | IR node | shape |
|---|---|---|---|---|
| `table.get x` | `[i32] → [t]` | `[i]` | `TableGet("t"<>x, i)` | value, result `reftype_valtype(t)` |
| `table.set x` | `[i32 t] → []` | `[i, v]` | `TableSet("t"<>x, i, v)` | zero-result effect |
| `table.size x` | `[] → [i32]` | — | `TableSize("t"<>x)` | nullary value, `TI32` |
| `table.grow x` | `[t i32] → [i32]` | `[init, n]` | `TableGrow("t"<>x, n, init)` | value, `TI32` |
| `table.fill x` | `[i32 t i32] → []` | `[i, v, n]` | `TableFill("t"<>x, i, v, n)` | zero-result effect |
| `table.init x y` | `[i32 i32 i32] → []` | `[d, s, n]` | `TableInit("t"<>x, y, d, s, n)` | zero-result effect |
| `table.copy x y` | `[i32 i32 i32] → []` | `[d, s, n]` | `TableCopy("t"<>x, "t"<>y, d, s, n)` | zero-result effect |
| `elem.drop y` | `[] → []` | — | `ElemDrop(y)` | zero-result effect |

Note the **field order** the IR3 nodes fix (provisional surface): `TableGrow(table, delta, init)`
— `delta` is the i32 count `n` (top of stack), `init` the reference filled into new slots (deeper);
`TableFill(table, offset, value, count)`. `TableGrow` returns the **old size** (or `-1`) — a value
producer. Sketch of the value arms:

```gleam
ast.TableGet(x) -> {
  let rt = table_reftype(ctx, x)
  emit_value_op_t(1, reftype_valtype(rt), fn(a) { ir.TableGet(tname(x), one(a)) },
    tail, ctx, st)
}
ast.TableSize(x) -> emit_nullary(ir.TableSize(tname(x)), ir.TI32, tail, ctx, st)
ast.TableGrow(x) ->
  emit_value_op_t(2, ir.TI32, fn(a) {
    case a { [init, n] -> ir.TableGrow(tname(x), n, init)
             _ -> ir.TableGrow(tname(x), ir.ConstI32(0), ir.ConstI32(0)) }
  }, tail, ctx, st)
```

and the zero-result effects (reuse `emit_effect`, which binds `Let([], build(args), cont)` and
pushes nothing):

```gleam
ast.TableSet(x) ->
  emit_effect(2, fn(a) {
    case a { [i, v] -> ir.TableSet(tname(x), i, v)  _ -> defensive } }, tail, ctx, st)
ast.TableFill(x) ->
  emit_effect(3, fn(a) {
    case a { [i, v, n] -> ir.TableFill(tname(x), i, v, n)  _ -> defensive } }, tail, ctx, st)
ast.TableInit(y, x) ->
  emit_effect(3, fn(a) {
    case a { [d, s, n] -> ir.TableInit(tname(x), y, d, s, n)  _ -> defensive } }, tail, ctx, st)
ast.TableCopy(x, y) ->
  emit_effect(3, fn(a) {
    case a { [d, s, n] -> ir.TableCopy(tname(x), tname(y), d, s, n)  _ -> defensive } },
    tail, ctx, st)
ast.ElemDrop(y) -> emit_effect(0, fn(_) { ir.ElemDrop(y) }, tail, ctx, st)
```

- `table_reftype(ctx, x)` reads `LCtx.table_types` at absolute tableidx `x`, falling back to
  `ir.FuncRef` for an out-of-range index (only reachable on an unvalidated module — fail-closed).
- The **eager bounds check** (trap-before-any-write for `table.init/copy/fill`), the **memmove**
  overlap-correctness of `table.copy`, the **dropped-segment ⇒ zero-length** rule for `elem.drop`,
  and `table.grow` returning `-1` on failure are all **runtime** (P5-07) — lower emits the node,
  nothing more. The trap reasons (`TableOutOfBounds`, `UninitializedElement`) are the runtime's.
- `elem.drop`/`data.drop` carry a passive-segment index only; the drop *state* is instance state
  threaded through the existing state seam (H2) — lower emits `ElemDrop(seg)` and is done.

---

## D. Bulk-memory lowering

The `0xFC` memory ops mirror the table ops; every one carries the memory index (default `0`).
Per [exec/instructions#memory-instructions](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions)
and the finalized bulk-memory semantics (WASM 2.0).

| op | stack type | operands (push order) | IR node |
|---|---|---|---|
| `memory.fill` (mem `m`) | `[a v n] → []` | `[dest, value, count]` | `MemFill(m, dest, value, count)` |
| `memory.copy` (dst `d`, src `s`) | `[a a n] → []` | `[dst, src, count]` | `MemCopy(d, s, dst, src, count)` |
| `memory.init x` (mem `m`) | `[a a n] → []` | `[dst, src, count]` | `MemInit(m, x, dst, src, count)` |
| `data.drop x` | `[] → []` | — | `DataDrop(x)` |

```gleam
ast.MemoryFill(m) ->
  emit_effect(3, fn(a) {
    case a { [d, v, n] -> ir.MemFill(m, d, v, n)  _ -> defensive } }, tail, ctx, st)
ast.MemoryCopy(dst_mem, src_mem) ->
  emit_effect(3, fn(a) {
    case a { [d, s, n] -> ir.MemCopy(dst_mem, src_mem, d, s, n)  _ -> defensive } },
    tail, ctx, st)
ast.MemoryInit(x, m) ->
  emit_effect(3, fn(a) {
    case a { [d, s, n] -> ir.MemInit(m, x, d, s, n)  _ -> defensive } }, tail, ctx, st)
ast.DataDrop(x) -> emit_effect(0, fn(_) { ir.DataDrop(x) }, tail, ctx, st)
```

- All four are zero-result effects — sequenced into the continuation, never dropped (H2/E6).
- **memory64.** For a 64-bit memory the `dest`/`src`/`count` operands are `i64` values (the
  validator typed them `TI64`; §F). lower does **not** branch on address width — it forwards
  whatever `ir.Value`s the SSA stack holds. The `IdxType` lives on `MemoryDecl` (§G), and 64-bit
  address arithmetic + large-offset bounds are the runtime's (P5-08). This is the whole of
  memory64 in lower: a value-width fact, confined to the seam + runtime (H3).
- The eager trap-before-write, the **memmove** overlap-correct copy (`memory.copy` for overlapping
  ranges in either direction), and dropped-segment ⇒ zero-length are runtime (P5-08). Trap reason:
  `MemoryOutOfBounds`.

---

## E. Typed `select` (`select_t`, 0x1C) → the existing `If` merge

Plain `select` (0x1B) is unchanged — it lowers to `If(cond,[t],Values([v1]),Values([v2]))` with
the operand type recovered from `value_type` (§I). It is defined only for **numeric** operands.
`select_t` carries an **explicit result type** immediate (a `vec(valtype)` of length exactly one
in the MVP) and is the form that admits **reference** operands
([exec/instructions](https://webassembly.github.io/spec/core/exec/instructions.html), select). It
lowers the same way — **no new IR node** — but takes its type from the immediate:

```gleam
ast.SelectT(types) -> lower_select_t(types, tail, ctx, st)

fn lower_select_t(types, tail, ctx, st) {
  use t <- result.try(case types {
    [ty] -> Ok(to_ir_vt(ty))                 // MVP: exactly one result type
    _ -> Error(Malformed("select_t arity"))  // fail-closed; validate guarantees arity 1
  })
  use #(cond, stack1) <- result.try(pop1(st.stack))
  case take_push_order(stack1, 2) {
    [val1, val2] -> // bind fresh name to If(cond, [t], Values([val1]), Values([val2]))
    _ -> Error(StackUnderflow)
  }
}
```

- `select`/`select_t` pop `cond` (top), then `val2` (nearer top), then `val1` (deeper); the result
  is `val1` iff `cond ≠ 0` — so then-arm = `val1`, else-arm = `val2`, exactly the spec. The result
  type list has **arity 1**; `t` for `select_t` comes from the immediate (robust for reftypes,
  which `value_type` also now tracks but which the spec pins explicitly).
- This reuses `lower_select`'s body; factor the shared `#(cond, val1, val2, t) → If` core into one
  helper both arms call, to avoid drift.

---

## F. Memory-index threading (multi-memory) + memory64 address width

**Multi-memory (H3).** Every memory-touching node carries `mem: Int` (default `0`). The existing
`emit_load`/`emit_store` gain a leading `mem` parameter, and the size/grow arms carry the index:

```gleam
fn emit_load(mem, op, result, offset, tail, ctx, st) ->
  emit_value_op_t(1, result, fn(a) { ir.MemLoad(mem, op, one(a), offset, result) }, …)
fn emit_store(mem, op, offset, tail, ctx, st) ->
  emit_effect(2, fn(a) { case a { [addr, value] -> ir.MemStore(mem, op, addr, value, offset) … } }, …)

ast.I32Load(m)  -> emit_load(m.mem, ir.MemAccess(4, False), ir.TI32, m.offset, tail, ctx, st)
// … all 14 loads and 9 stores gain the leading `m.mem` argument (the full width matrix is
//    unchanged otherwise — MemAccess(bytes,signed) + result ValType per the P2-09 opcode table)
ast.MemorySize(m) -> emit_nullary(ir.MemSize(m), ir.TI32, tail, ctx, st)
ast.MemoryGrow(m) -> emit_value_op_t(1, ir.TI32, fn(a) { ir.MemGrow(m, one(a)) }, tail, ctx, st)
```

The `mem` index is a **static immediate** (never a runtime handle — the tier-agnostic rule G5),
so it flows straight onto the node; the state seam routes by index at emit_core/runtime (P5-06/08).

**Byte-identical default (H7).** For a single-memory module every `m.mem == 0`, so `MemSize(0)`/
`MemGrow(0, δ)`/`MemLoad(0, …)`/`MemStore(0, …)`/`MemFill(0, …)`/`MemCopy(0, 0, …)`/`MemInit(0, …)`
must print/emit **byte-identically** to Phase-4. This is the keystone's responsibility (the
default-`0` field is invisible in the `.core`); lower's obligation is simply to always pass `0` for
a legacy module — which falls out of `m.mem` defaulting to `0` in AST3. A lower_test asserts the
Phase-4 corpus lowers to the same IR3 (modulo the reconstructed `mem: 0` field) — see DoD.

**memory64 (H3, deferrable half).** The **only** lower-visible fact is `MemoryDecl.idx_type`
(§G). Address/count operands are already typed by the validator; lower forwards them unchanged.
There is **no** `i32`/`i64` branch in any instruction arm — the width difference is entirely in the
value the SSA name holds and in the runtime's bounds arithmetic (P5-08). If memory64 is cut (H8),
this section is a no-op beyond carrying `Idx32` on every `MemoryDecl`.

---

## G. Module-level declarations (the grown module shape)

`lower/1` builds `ir.Module(…)`. Every changed field is updated; defaults keep a legacy module
byte-identical (H7).

```gleam
ir.Module(
  name: "twocore@wasm@" <> module_base(module),
  uses_numerics: True,
  memories: lower_memories(module),          // CHANGED: was `memory: Option`
  globals: globals,
  imports: lower_imports(module),            // CHANGED: was `[]`
  functions: functions,
  exports: exports,                          // CHANGED: all four export kinds
  data_segments: data_segments,              // CHANGED: active | passive
  tables: lower_tables(module, ctx),         // CHANGED: reftype tag
  elements: elements,                        // CHANGED: modes + ref-init
  start: lower_start(module),
)
```

### G.1 Memories (list) + memory64 index type

```gleam
/// Lower the memory section to a list of `MemoryDecl` in index order. Each carries its
/// `IdxType` (Idx32 default; Idx64 for a memory64). Imported memories occupy the low indices
/// (surfaced as ImportMemory, §G.5); this list is the *defined* memories, appended after.
fn lower_memories(module: ast.Module) -> List(ir.MemoryDecl) {
  list.map(module.memories, fn(m) {
    ir.MemoryDecl(m.limits.min, m.limits.max, to_ir_idxtype(m.idx_type))
  })
}
fn to_ir_idxtype(it: ast.IdxType) -> ir.IdxType {
  case it { ast.Idx32 -> ir.Idx32  ast.Idx64 -> ir.Idx64 }
}
```

A single 32-bit memory ⇒ `[MemoryDecl(min, max, Idx32)]` — the keystone's default makes this
print byte-identically to the Phase-4 `Some(MemoryDecl(min, max))`.

### G.2 Tables (reference-typed)

```gleam
/// table i → TableDecl("t<abs_i>", ref_ty, min, max). ref_ty from the AST table type
/// (funcref default). abs_i is the absolute tableidx (imported tables occupy the low indices).
fn lower_tables(module, ctx) -> List(ir.TableDecl) {
  list.index_map(module.tables, fn(t, i) {
    ir.TableDecl(tname(ctx.imported_table_count + i), to_ir_reftype(t.ref_ty),
      t.limits.min, t.limits.max)
  })
}
```

### G.3 Element segments (active | passive | declarative; ref-producing init)

`ElementSegment(mode, ref_ty, init)` where `init: List(ir.Expr)` — **each item is a ref-producing
const-expr node** (`RefFunc`/`RefNull`), generalizing the old `funcs: List(String)`. Per
[syntax/modules#element-segments](https://webassembly.github.io/spec/core/syntax/modules.html#element-segments).

```gleam
fn lower_elements(module) -> Result(List(ir.ElementSegment), LowerError) {
  list.try_map(module.elements, fn(e) {
    use init <- result.try(list.try_map(elem_items(e), lower_ref_const_expr))
    let mode = case e {
      ElemActive  -> use off <- ...; ir.ElemActive(tname(e.table), off)
      ElemPassive -> ir.ElemPassive
      ElemDecl    -> ir.ElemDeclarative
    }
    Ok(ir.ElementSegment(mode, to_ir_reftype(elem_reftype(e)), init))
  })
}
```

- **Active** → `ElemActive(tname(table), offset_expr)` where `offset_expr = lower_const_expr(offset)`
  (an `i32.const`; §H). Items written into the table at instantiation.
- **Passive** → `ElemPassive`; items are the source for a later `table.init`.
- **Declarative** → `ElemDeclarative`; produces no runtime content — it exists solely to declare
  its funcs into the reference set (H1; the `ref.func` declared set, §B). lower preserves it so
  emit_core knows the declared funcs.
- **Item lowering** (`lower_ref_const_expr`, §H): the legacy flag-0 `vec(funcidx)` form maps each
  funcidx `x` → `ir.RefFunc("f"<>x)` (the same funcidx→name convention — element targets resolve);
  the expression form maps each const-expr — `ref.func x` → `RefFunc`, `ref.null t` → `RefNull(rt)`.
  A funcref-only active segment therefore lowers to `init = [RefFunc("f0"), RefFunc("f1"), …]`,
  which the keystone can print byte-identically to the Phase-4 `funcs: ["f0","f1",…]` form
  (default-neutral).

### G.4 Data segments (active | passive)

```gleam
fn lower_data(module) -> Result(List(ir.DataSegment), LowerError) {
  list.try_map(module.data, fn(d) {
    case d {
      DataActive  -> { use off <- result.try(lower_const_expr(d.offset))
                       Ok(ir.DataSegment(ir.DataActive(d.mem, off), d.bytes)) }
      DataPassive -> Ok(ir.DataSegment(ir.DataPassive, d.bytes))
    }
  })
}
```

- **Active** → `DataActive(mem, offset_expr)` — `mem` the memory index (default `0`); `offset_expr`
  an `i32.const` (or `i64.const` for a 64-bit target memory; §H). A `DataActive(0, off)` prints
  byte-identically to the Phase-4 `DataSegment(off, bytes)`.
- **Passive** → `DataPassive`; the bytes are the source for a later `memory.init`.

### G.5 Non-function imports & exports (index spaces)

**Exports** — extend the `list.filter_map` to all four kinds
([syntax/modules#exports](https://webassembly.github.io/spec/core/syntax/modules.html#exports)):

```gleam
case e.kind {
  ast.ExportFunc   -> Ok(ir.ExportFn(e.name, "f" <> int.to_string(e.index)))
  ast.ExportTable  -> Ok(ir.ExportTable(e.name, tname(e.index)))
  ast.ExportGlobal -> Ok(ir.ExportGlobal(e.name, gname(e.index)))
  ast.ExportMemory -> Ok(ir.ExportMemory(e.name, e.index))  // raw memidx per the provisional
}
```

**Imports** — `lower_imports` maps each AST import to its `ImportDecl` variant:

```gleam
ast.ImportFunc(mod, nm, tyidx)     -> ir.ImportFn(mod, nm, ir_functype(module.types, tyidx))
ast.ImportGlobal(mod, nm, ty, mut) -> ir.ImportGlobal(mod, nm, to_ir_vt(ty), mut)
ast.ImportTable(mod, nm, rt, lim)  -> ir.ImportTable(mod, nm, to_ir_reftype(rt), lim.min, lim.max)
ast.ImportMemory(mod, nm, lim, it) -> ir.ImportMemory(mod, nm, lim.min, lim.max, to_ir_idxtype(it))
```

**Index spaces (the load-bearing rule).** A WASM index space is `imports ++ defined`. lower
already honours this for functions (`funcidx = imported_func_count + defined_idx`). Phase 5 extends
it to globals/tables/memories: an imported global/table/memory occupies the **low** indices, and a
`GlobalGet`/`table.*`/`MemLoad` referencing index `i` must resolve to the same `g<i>`/`t<i>`/mem-`i`
whether `i` is imported or defined. Concretely:

- `lower_globals` names **defined** global `j` (0-based in `module.globals`) at its **absolute**
  index `imported_global_count + j` → `GlobalDecl("g<abs>", …)`. Imported globals become
  `ImportGlobal` and occupy `g0..g(imported_global_count-1)`.
- `lower_tables`/`lower_memories` likewise offset by `imported_table_count`/`imported_mem_count`.
- `gname/tname` stay **absolute-index** based (unchanged spelling), so instruction lowering
  (`GlobalGet(gname(i))`, `table.get "t"<>i`) references the right slot regardless of imports.

The **wiring** of a provided import value into the instance under that `g<i>`/`t<i>`/mem-`i` name is
P5-09's (`«INSTANTIATE3»`) — lower only declares. *Note the seam gap in the provisional
`ImportGlobal`/`ImportTable`/`ImportMemory`: they carry no IR-local name, so the `g<i>`/`t<i>`
binding is currently **positional** (import order). See Open questions — recommend the keystone add
an IR name field for robustness.*

`lower_start` is unchanged: `Some(idx) → Some("f"<>idx)`; `idx` is already the absolute funcidx.

---

## H. Const-expr & reference-init lowering

`lower_const_expr` (offsets, and numeric/imported-global global inits) and a new
`lower_ref_const_expr` (element items, reference-typed global inits) implement the constant
expression grammar ([valid/instructions#constant-expressions](https://webassembly.github.io/spec/core/valid/instructions.html#constant-expressions)):
a const-expr is a sequence of `t.const` / `ref.null` / `ref.func` / `global.get` (of an immutable
imported global), then `end`.

```gleam
/// Numeric / imported-global const-expr → ir.Expr (a `Values([...])` or a `GlobalGet`).
/// Offsets (active elem = i32; active data = i32, or i64 for a 64-bit memory) and numeric
/// global inits. Integers → raw unsigned bits; floats → raw IEEE bits (D5).
fn lower_const_expr(instrs) -> Result(ir.Expr, LowerError) {
  case strip_end(instrs) {
    [ast.I32Const(v)] -> Ok(ir.Values([ir.ConstI32(unsigned_bits(v, 32))]))
    [ast.I64Const(v)] -> Ok(ir.Values([ir.ConstI64(unsigned_bits(v, 64))]))
    [ast.F32Const(b)] -> Ok(ir.Values([ir.ConstF32(b)]))
    [ast.F64Const(b)] -> Ok(ir.Values([ir.ConstF64(b)]))
    [ast.GlobalGet(i)] -> Ok(ir.GlobalGet(gname(i)))   // NEW: imported immutable global init
    _ -> Error(NonConstInitExpr("non-constant init expression"))
  }
}

/// Reference const-expr (element items, funcref/externref global inits) → ir.Expr.
fn lower_ref_const_expr(instrs) -> Result(ir.Expr, LowerError) {
  case strip_end(instrs) {
    [ast.RefFunc(x)] -> Ok(ir.RefFunc("f" <> int.to_string(x)))
    [ast.RefNull(rt)] -> Ok(ir.RefNull(to_ir_reftype(rt)))
    [ast.GlobalGet(i)] -> Ok(ir.GlobalGet(gname(i)))
    _ -> Error(NonConstInitExpr("non-constant ref init expression"))
  }
}
```

- **The `ConstNull` decision (§I / Open questions).** The provisional leaves open whether the IR
  needs a `ConstNull(RefType)` **Value**. lower does **not** require one: element items and
  reference-typed global inits are `Expr`s (`GlobalDecl.init: Expr`, `ElementSegment.init:
  List(Expr)`), so `ir.RefNull(rt)`/`ir.RefFunc(name)` slot in directly; and a reference value only
  ever reaches the operand stack as a **`Var`** bound to `RefNull`/`RefFunc`/`TableGet` — never as a
  bare constant — so the branch/merge machinery (`fallthrough`, the synthesised `else`) forwards
  `Var`s and needs no null `Value`. The one remaining site is **declared-local zero-init** (§I),
  handled by emitting `RefNull` as the init `Expr`. **Recommendation:** the keystone need **not**
  add `ConstNull` on lower's account (keeps `Value` conformance-neutral); if another unit (e.g.
  emit_core's default-init for `table.grow`/`table.fill`) wants a uniform null `Value`, add it
  there. Flagged for reconcile.
- `global.get` in a const-expr (an **immutable imported** global) is now **accepted** (was
  `Error(NonConstInitExpr)` in Phase 2 with no imports). Validation (P5-04) enforces the
  immutable-imported restriction; lower emits `GlobalGet(gname(i))`. Extended-const (`i32.add` in a
  const-expr — a separate proposal) stays rejected fail-closed.

---

## I. SSA value-type tracking (references) + reference-typed declared locals

**`value_type`/`var_types` (§ the P2-09 mechanism).** Reference results now flow through
`var_types` too: `RefNull`/`RefFunc` record `TFuncRef`/`TExternRef`, `TableGet` records its table's
reftype, `RefIsNull` records `TI32`. `value_type/2` already looks up `Var` names in `var_types`
(with a defensive `TI32` fallback), so a plain `select` over reference operands — though rare;
`select_t` is the spec form for reftypes — still recovers the operand type. No structural change to
`value_type` beyond the new binders recording their types (which `emit_nullary`/`emit_value_op_t`
already do via `record_type`).

**Reference-typed declared locals.** A declared local of reference type is zero-initialised to
**`ref.null`** ([exec/instructions](https://webassembly.github.io/spec/core/exec/instructions.html),
local initialization; a reference local defaults to null of its type). Today `wrap_zero_inits`
binds `Let([name], Values([zero_value(ty)]), …)`, and `zero_value` returns an `ir.Value` — but there
is no null `Value` (see §H). So the zero-init path becomes per-local **Expr**-valued:

```gleam
/// The zero-initialising Expr for a declared local of IR type `ty`.
fn zero_init_expr(ty: ir.ValType) -> ir.Expr {
  case ty {
    ir.TFuncRef   -> ir.RefNull(ir.FuncRef)
    ir.TExternRef -> ir.RefNull(ir.ExternRef)
    _ -> ir.Values([zero_value(ty)])            // numeric: unchanged (byte-identical)
  }
}
```

`wrap_zero_inits` binds `Let([name], zero_init_expr(ty), acc)`. Numeric locals are unchanged
(byte-identical). `zero_value` keeps its numeric arms; its `TFuncRef`/`TExternRef` arms are now
unreachable from the zero-init path (declared reftype locals go through `zero_init_expr`), but must
still exist for exhaustiveness — keep them mapping to `RefNull`-equivalent defensively (or delegate
`zero_value` callers to `zero_init_expr`). `var_types` still records each declared local's type at
entry (so a `select` reading it recovers the reftype).

**No new control frames, no LoopParam entanglement.** Every new op is **flat** (non-structural), so
`scan_modified`/`consume_dead`/`build_transfer` handle them through their existing wildcard arms —
no change to the depth-tracking scanners (exactly the P2-09 pitfall note). `table.set`/`table.fill`/
`memory.fill`/… mutate **instance state** (the cell / threaded record), not a WASM local, so — like
`global.set`/`*.store` — they must **never** enter `scan_modified`/`carried`/`LoopParam`. They do
not, because those scanners only track `local.set`/`local.tee`.

**`LCtx` additions.** Add `table_types: List(ir.RefType)` (absolute tableidx → reftype, from
`TypedModule`) and the three imported-count offsets (`imported_global_count`/`imported_table_count`/
`imported_mem_count`). Populate them in `lower_func`/`lower/1` from the (extended) `TypedModule`;
derive locally from `module.imports` as a fail-closed fallback until P5-04 carries them.

---

## Effect / soundness / security note

- **Every new node is an effect barrier (H2).** lower emits them faithfully and in program order;
  the barrier classification is `ir/effect.gleam`'s (P5-01/02 reach), not lower's. lower's only
  obligation is the P2-09 one: never drop a zero-result effect (it sequences each as `Let([], …,
  cont)`), and never reorder (a straight-line walk preserves order). *Note:* `RefNull`/`RefFunc`/
  `RefIsNull` are arguably **pure** (referentially transparent); the keystone conservatively
  classifies them as barriers. This costs a missed optimization, never correctness (F2). lower is
  agnostic — it emits the same node either way. Flagged for the keystone (Open questions).
- **lower enforces no runtime invariant.** Bounds/overlap/eager-trap/drop-state/type-check/opacity
  are the runtime's + emit_core's (P5-06/07/08) and the validator's (P5-04). lower is a syntactic
  map; its worst failure is a wrong-shaped node caught by the differential oracle, never a host
  escape (H6). The security boundary is upstream (validate rejects ill-typed/out-of-scope
  fail-closed) and in the runtime (trap-checked ops).
- **Fail-closed, total (D-rule).** Out-of-scope (SIMD/GC ops) ⇒ `Error(Unsupported(_))`;
  non-const init ⇒ `Error(NonConstInitExpr(_))`; a malformed `select_t` arity or a stray marker ⇒
  `Error(Malformed(_))`; an out-of-range index ⇒ the matching `LowerError`. **Never** `panic`/`let
  assert`. No new `LowerError` variant is required (the existing set covers the new failures); if
  the reconcile pass finds a case that needs one, it is additive.
- **Conformance-neutral by default (H7).** The obligation is *negative*: a legacy module lowers to
  byte-identical IR3. Enforced by the default-away immediates (`mem: 0`, `FuncRef`, `ElemActive`,
  `DataActive(0,_)`) and by keeping numeric zero-init/const-expr/select paths untouched.

## Verification — Definition of Done (D8)

Tests assert **spec behaviour / the spec's opcode meaning**, not whatever the code emits (no
change-detector tests). Fixtures are `wat2wasm`/`wat.gleam` programs decoded+validated through
P5-03/04, then lowered. Cite the WASM spec section in each test.

1. **Reference instructions (spec opcode meaning).** `ref.null funcref` ⇒ a `RefNull(FuncRef)`
   bound value of type `TFuncRef`; `ref.null externref` ⇒ `RefNull(ExternRef)`/`TExternRef`;
   `ref.func $f` ⇒ `RefFunc("f<abs_funcidx>")` (name equals the target `Function`'s) of type
   `TFuncRef`; `ref.is_null` ⇒ `RefIsNull(arg)` of type `TI32`. Cite
   [exec/instructions#reference-instructions].
2. **Table instructions (semantics table §C).** Assert each op lowers to its node with the **exact
   operand order**: `table.get x` ⇒ `TableGet("t<x>", i)` typed to the table's reftype;
   `table.grow x` ⇒ `TableGrow("t<x>", n, init)` (delta = the i32, init = the reference) typed
   `TI32`; `table.fill x` ⇒ `TableFill("t<x>", i, v, n)`; `table.init x y` ⇒ `TableInit("t<x>", y,
   d, s, n)`; `table.copy x y` ⇒ `TableCopy("t<x>","t<y>", d, s, n)`; `table.set`/`elem.drop` ⇒
   zero-result effects (`Let([], …)`). Cite [exec/instructions#table-instructions] and the `0xFC`
   sub-opcodes.
3. **Bulk memory (semantics table §D).** `memory.fill` ⇒ `MemFill(m, dest, value, count)`;
   `memory.copy` ⇒ `MemCopy(dst_mem, src_mem, dst, src, count)`; `memory.init x` ⇒ `MemInit(m, x,
   dst, src, count)`; `data.drop x` ⇒ `DataDrop(x)`. All zero-result effects, correct memidx.
4. **Typed select.** `select_t (result funcref)` over two funcrefs ⇒ `If(cond,[TFuncRef],
   Values([v1]),Values([v2]))` with then = `v1` (cite exec/instructions: `v1` when `c≠0`). A
   numeric `select_t (result i32)` matches the plain-`select` shape with `t = TI32`.
5. **Multi-memory + byte-identical default (H7).** A two-memory module: a load/store/fill against
   memory `1` carries `mem: 1`; against memory `0` carries `mem: 0`. **Regression:** the entire
   Phase-1..4 acceptance corpus lowers to IR3 that is **byte-identical** to Phase-4 (reconstruct the
   `mem: 0`/`FuncRef`/`ElemActive`/`DataActive(0,_)` defaults) — the negative obligation. Prove via
   `.ir` round-trip equality (P5-02) or structural `ir.Module` equality against the Phase-4 golden.
6. **memory64 (if not cut, H8).** A 64-bit memory ⇒ `MemoryDecl(min, max, Idx64)`; an `i64`-address
   load/store lowers with the `i64` address `Value` forwarded unchanged (no width branch). A 32-bit
   memory ⇒ `Idx32`, byte-identical.
7. **Module decls populated.** A module with multiple memories, a reftype table, active + passive +
   declarative element segments, passive data, and non-function imports/exports lowers to a
   `Module` whose `memories`/`tables`/`elements`/`data_segments`/`imports`/`exports` are populated
   with the right variants: element items = `RefFunc("f<idx>")`/`RefNull(rt)` resolving to real
   functions; a declarative segment ⇒ `ElemDeclarative` (no active table write); a passive data
   segment ⇒ `DataPassive`; `ExportTable`/`ExportGlobal`/`ExportMemory` present; `ImportGlobal`/
   `ImportTable`/`ImportMemory` present; global/table/memory instruction names honour the
   `imports ++ defined` index space.
8. **Reference-typed const-init & declared locals.** A `funcref` global initialised to `ref.func
   $f` ⇒ `GlobalDecl("g<i>", TFuncRef, _, RefFunc("f<..>"))`; to `ref.null func` ⇒ `RefNull(FuncRef)`
   init. A function with a declared `externref` local zero-inits it to `RefNull(ExternRef)` (spec:
   reference locals default to null). Numeric global inits / declared locals stay bit-exact
   (NaN payload / `-0.0` preserved — D5) and byte-identical.
9. **Fail-closed (no panic).** A SIMD op ⇒ `Error(Unsupported(_))`; an extended-const global init
   ⇒ `Error(NonConstInitExpr(_))`; an out-of-range table/func/type/local index ⇒ the matching
   `LowerError`. **Never** `panic`/`let assert`.
10. **End-to-end (proven at the capstone, P5-11/12):** the reftype/bulk/multi-mem/mem64 spec
    programs (`table.get`/`set`/`grow`/`fill`, `memory.fill`/`copy`/`init`, `table.init`/`copy`,
    passive segments + drop, a two-memory round-trip, a `funcref`/`externref` `select_t`) run
    spec-correctly through the full pipeline. lower is on that path; its output is the input to the
    differential oracle.
11. `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test` stays
    green with **no Phase-1..4 regression** (conformance `fail == 0`). Every new/changed
    public/private function carries a doc comment stating its contract (what/params/returns/failure
    modes — D8).

## What this unit leaves for others

- **P5-03 (decode)** publishes `«WASM-AST3»` — the constructors §A matches (ref/table/bulk ops,
  memidx on memargs, reftype/idxtype/segment-mode module fields, non-function imports/exports).
  lower re-syncs on the exact spelling; the opcode→IR mapping is fixed.
- **P5-04 (validate)** is the security boundary upstream: it type-checks reftypes/tables/bulk ops,
  the `ref.func` declared set, multi-memory memidx bounds, memory64 `i64` typing, `select_t` arity,
  and const-expr rules **before** lower runs. lower assumes a validated, in-scope module and keeps
  its `LowerError`s only as fail-closed insurance. lower **needs** the extended `TypedModule`
  (`table_types`, per-kind imported counts) — the seam in §Depends-on.
- **P5-06 (emit_core)** consumes every node lower emits: `RefNull`/`RefFunc`/`RefIsNull` → the
  reference value layer; `TableGet/Set/Size/Grow/Fill/Init/Copy` + `ElemDrop` → `rt_table`;
  `MemFill/Copy/Init` + `DataDrop` → `rt_mem`; the `mem` index → the state-seam routing; the
  reference-typed `GlobalDecl.init`/`ElementSegment.init` exprs and `RefNull` zero-init → the
  instance builder; `ImportGlobal/Table/Memory` + `ExportGlobal/Table/Memory` → the
  instantiation/link contract (with P5-09).
- **P5-07/08 (rt_table/rt_mem)** implement the trap-checked, overlap-correct, eager-bounds,
  passive-drop semantics of the nodes lower shapes.
- **P5-09 (imports + spectest + linker)** wires the provided import values into the instance under
  the `g<i>`/`t<i>`/mem-`i` names lower's index-space convention establishes, and owns
  `«INSTANTIATE3»`.

## Open questions (for the planner / cross-unit sync)

1. **`ConstNull(RefType)` `Value` — needed?** lower does **not** require it (§H/§I): reference
   inits are `Expr`s (`RefNull`/`RefFunc`), and a reference value only reaches the operand stack as
   a `Var`, so merges forward `Var`s and declared-local zero-init emits a `RefNull` `Expr`.
   **Recommendation:** do not add `ConstNull` on lower's account (keeps `Value` conformance-neutral).
   If emit_core's default-init for `table.grow`/`table.fill` or a uniform const-init `Value` wants
   one, add it and I'll consume it — but the current mapping is complete without it.
2. **`ImportGlobal`/`ImportTable`/`ImportMemory` carry no IR-local name.** `GlobalGet(g<i>)`/
   `table.*("t<i>")`/`MemLoad(i,…)` reference imported state by the same `g<i>`/`t<i>`/mem-`i` name,
   but the provisional import variants have no name field, so the binding is **positional** (import
   order). **Recommendation:** the keystone add an explicit IR name (`g<i>`/`t<i>`) to each state
   import variant, so the `imports ++ defined` index-space naming is explicit and robust rather than
   relying on emit_core/P5-09 reconstructing it positionally. If kept positional, P5-06/09 must own
   the derivation and document it. (Also: `ExportMemory` carries a raw `mem_index: Int` while
   `ExportTable`/`ExportGlobal` carry names — asymmetric; consider a `mem<i>` name for uniformity.)
3. **`TypedModule` extension (P5-04 seam).** lower needs `table_types: List(ir.RefType)` and the
   per-kind imported counts (`imported_global_count`/`imported_table_count`/`imported_mem_count`).
   Confirm P5-04 carries them (mirroring `global_types`/`imported_func_count`); otherwise lower
   derives them from `module.imports` locally (fine, but duplicated work).
4. **`RefNull`/`RefFunc`/`RefIsNull` barrier classification.** They are referentially transparent;
   classifying them as effect barriers (H2) is conservative and blocks CSE of e.g. a repeated
   `ref.func $f`. This is `ir/effect.gleam`'s call (P5-01/02), not lower's — flagged so the keystone
   decides deliberately. lower emits the same node regardless.
5. **memidx placement in AST3 (P5-03 seam).** §A assumes the memory index lands on `MemArg.mem`
   (and on `MemorySize`/`MemoryGrow`). If P5-03 threads it as a distinct instruction field, only the
   per-arm accessor changes. Confirm the shape at `«WASM-AST3»` publish.
6. **Element-item form (P5-03 seam).** §G.3 assumes AST3 exposes element items as const-expr
   instruction lists (with the legacy flag-0 `vec(funcidx)` sugar). Confirm whether the flag-0 form
   is pre-desugared to `ref.func` items by decode or left as `funcs: List(Int)` for lower to
   desugar (lower handles either — but the golden byte-identical test depends on which).
