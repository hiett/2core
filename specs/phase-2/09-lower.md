# Unit 09 — lower extension (WASM AST → IR2)

> **One owner. Extends `src/twocore/frontend/wasm/lower.gleam` (single-owner, additive).
> Wave B — runs in parallel with 07 (decode), 08 (validate), 10 (emit_core).** Read
> [`00-overview.md`](00-overview.md) (E1–E8) and [`01-interface-freeze.md`](01-interface-freeze.md)
> first. Freeze deps: **`«IR2-FROZEN»`** (the IR2 node shapes you emit) and **`«WASM-AST2»`**
> (P2-07's day-1 type stub — the new AST constructors you match).

---

## Context

`lower.gleam` already does the two WASM-frontend jobs (stack-elimination/SSA → named IR
`Value`s, and structured control → **named labels**, never a branch depth — D6). Phase 1
lowers the integer/control slice and **returns `Unsupported`** for `call_indirect`, `select`,
`global.get/set`, and every memory op (see `go/3`, lines ~380–383). Phase 2 completes WASM 1.0:
linear memory, tables + `call_indirect`, globals, the full float + conversion surface, and the
module-level table/element/global/data declarations that drive instantiation.

This unit is a **pure syntactic mapping**: validation (unit 08) already proved the module
well-typed; lowering produces IR2 nodes faithful to the opcode's spec meaning. The *runtime*
behaviour (bounds-checks, the cell, the 3-fault dispatch, trapping converts) belongs to the
runtime units + emit_core — lower emits the tier-agnostic IR2 node and nothing else. Per **E6**
the mem/global/table nodes lower produces are **effects** — lower must preserve their order and
never drop a zero-result effect (it is a straight-line walk, so order is naturally preserved;
the one rule is that zero-result effects are sequenced into the continuation, never discarded).

## Goal

Lower every new WASM op and module section to IR2, preserving the existing named-label +
stack-elim/SSA model and the Phase-1 mutable-locals→`LoopParam` mechanism. After this unit a
validated Phase-2 `.wasm` module produces a complete `ir.Module` (memory/globals/tables/
elements/data populated) ready for emit_core (unit 10).

## Files owned

- `src/twocore/frontend/wasm/lower.gleam` — **EXTEND** (single owner).
- `test/twocore/frontend/wasm/lower_test.gleam` — the unit's tests (mirrors `src/`).

No freeze/publish-day-1 stub: lower is downstream of two freezes; it publishes nothing others
depend on.

## Depends on

- **`«IR2-FROZEN»`** (P2-01) — the node shapes you emit: `MemLoad(op,addr,offset,result)` (the
  `result: ValType` field is **new**), `MemSize`, `MemGrow(delta)`, the float `NumOp`s, the new
  `ConvOp`s, `Module.tables`/`Module.elements`, `TableDecl`, `ElementSegment`. Until it lands,
  stub against §A of the freeze doc.
- **`«WASM-AST2»`** (P2-07, published day 1) — the new AST constructors you match: the load/
  store instructions (with a `MemArg`), `MemorySize`/`MemoryGrow`, the float ops, the 0xA7–0xBF
  conversions, plus `ast.Module` gaining `memory`, `globals`, `tables`, `elems`, `datas`. Until
  it lands, stub against the names below (taken from the topic-2 research recipe) and re-sync
  when 07 publishes — the *opcode→IR* mapping is fixed regardless of the exact constructor
  spelling.

`ast.CallIndirect(type_idx, table)`, `ast.Select`, `ast.GlobalGet(idx)`, `ast.GlobalSet(idx)`
already exist in the Phase-1 AST.

## Scope — in / out for Phase 2

**In:** load/store (full width matrix) → `MemLoad`/`MemStore`; `memory.size`/`memory.grow` →
`MemSize`/`MemGrow`; `global.get`/`global.set` → `GlobalGet`/`GlobalSet` (index→stable name);
`call_indirect` → `CallIndirect` (single MVP table → fixed name); the float ops → the new
`NumOp`s; the full 0xA7–0xBF conversion block (wrap/extend/reinterpret → **existing** ConvOps;
trapping trunc → `TruncS/U`; convert → `ConvertS/U`; demote/promote → `F32DemoteF64`/
`F64PromoteF32`); `select` (0x1B) → the existing `If` (**no new emit node**); the module decls
`TableDecl`, `ElementSegment` (funcidx→IR fn name), `GlobalDecl` (const-literal init), the
single memory decl, and `DataSegment` — populating `Module.tables/elements/globals/data_segments`
and `Module.memory`.

**Out (cite E-decisions):** reference types / `select_t` (0x1C) / `externref` — Phase 3 (E8);
bulk memory (`memory.fill/copy/init`) — Phase 3; multi-memory / multi-table — Phase 3 (MVP =
exactly one memory, one table); **imported globals** in const exprs — deferred with imports (E7,
E5): const-expr lowering is **constant literals only** (`t.const`). lower does not validate
(unit 08) or optimize (no `ir_opt` this phase, E6).

## Deliverables

### 1. New `go/3` arms (replace the four `Unsupported` arms; add the memory arms)

```gleam
// memory loads — pop addr, bind MemLoad, push (1 result). result type from the opcode.
ast.I32Load(m)     -> emit_load(ir.MemAccess(4, False), ir.TI32, m.offset, tail, ctx, st)
ast.I64Load(m)     -> emit_load(ir.MemAccess(8, False), ir.TI64, m.offset, tail, ctx, st)
ast.F32Load(m)     -> emit_load(ir.MemAccess(4, False), ir.TF32, m.offset, tail, ctx, st)
ast.F64Load(m)     -> emit_load(ir.MemAccess(8, False), ir.TF64, m.offset, tail, ctx, st)
ast.I32Load8S(m)   -> emit_load(ir.MemAccess(1, True),  ir.TI32, m.offset, tail, ctx, st)
ast.I32Load8U(m)   -> emit_load(ir.MemAccess(1, False), ir.TI32, m.offset, tail, ctx, st)
ast.I32Load16S(m)  -> emit_load(ir.MemAccess(2, True),  ir.TI32, m.offset, tail, ctx, st)
ast.I32Load16U(m)  -> emit_load(ir.MemAccess(2, False), ir.TI32, m.offset, tail, ctx, st)
ast.I64Load8S(m)   -> emit_load(ir.MemAccess(1, True),  ir.TI64, m.offset, tail, ctx, st)
ast.I64Load8U(m)   -> emit_load(ir.MemAccess(1, False), ir.TI64, m.offset, tail, ctx, st)
ast.I64Load16S(m)  -> emit_load(ir.MemAccess(2, True),  ir.TI64, m.offset, tail, ctx, st)
ast.I64Load16U(m)  -> emit_load(ir.MemAccess(2, False), ir.TI64, m.offset, tail, ctx, st)
ast.I64Load32S(m)  -> emit_load(ir.MemAccess(4, True),  ir.TI64, m.offset, tail, ctx, st)
ast.I64Load32U(m)  -> emit_load(ir.MemAccess(4, False), ir.TI64, m.offset, tail, ctx, st)

// memory stores — pop [addr, value], sequence MemStore as a zero-result effect.
// `signed` is irrelevant for stores → always False (document it). bytes = low N bits.
ast.I32Store(m)    -> emit_store(ir.MemAccess(4, False), m.offset, tail, ctx, st)
ast.I64Store(m)    -> emit_store(ir.MemAccess(8, False), m.offset, tail, ctx, st)
ast.F32Store(m)    -> emit_store(ir.MemAccess(4, False), m.offset, tail, ctx, st)
ast.F64Store(m)    -> emit_store(ir.MemAccess(8, False), m.offset, tail, ctx, st)
ast.I32Store8(m)   -> emit_store(ir.MemAccess(1, False), m.offset, tail, ctx, st)
ast.I32Store16(m)  -> emit_store(ir.MemAccess(2, False), m.offset, tail, ctx, st)
ast.I64Store8(m)   -> emit_store(ir.MemAccess(1, False), m.offset, tail, ctx, st)
ast.I64Store16(m)  -> emit_store(ir.MemAccess(2, False), m.offset, tail, ctx, st)
ast.I64Store32(m)  -> emit_store(ir.MemAccess(4, False), m.offset, tail, ctx, st)

ast.MemorySize     -> emit_nullary(ir.MemSize, ir.TI32, tail, ctx, st)         // 0-pop, push i32
ast.MemoryGrow     -> emit_value_op_t(1, ir.TI32, fn(a){ ir.MemGrow(one(a)) }, tail, ctx, st)

ast.GlobalGet(i)   -> emit_nullary(ir.GlobalGet(gname(i)), global_ty(ctx, i), tail, ctx, st)
ast.GlobalSet(i)   -> emit_effect(1, fn(a){ ir.GlobalSet(gname(i), one(a)) }, tail, ctx, st)

ast.CallIndirect(ty, table) -> lower_call_indirect(ty, table, tail, ctx, st)
ast.Select         -> lower_select(tail, ctx, st)
```

- `emit_load(op, result, offset, …)`: `args = take_push_order(stack, 1)` = `[addr]`; bind a
  fresh name `n` to `ir.MemLoad(op, addr, offset, result)`; push `Var(n)` recording its type
  `result`; lower the continuation. (Reuse the `emit_value_op` shape; carry the result type.)
- `emit_store(op, offset, …)`: `take_push_order(stack, 2)` = `[addr, value]` (value is on top
  of the WASM stack, so it is the *second* in push order); drop 2; emit a **zero-result
  effect** `ir.Let([], ir.MemStore(op, addr, value, offset), <cont>)` — see `emit_effect`. The
  freeze fixes evaluation order **addr, then value, then store**; emit_core realises the
  ordered `let _ = … in …`. lower must not push anything.
- `emit_effect(n, build, …)`: like `emit_value_op` but binds **zero** names —
  `wrap_let([], build(args), <cont>)` — and pushes nothing. Used by `MemStore` and `GlobalSet`.
- `gname(i) = "g" <> int.to_string(i)`; `global_ty(ctx, i)` = the declared IR type of global `i`
  (carry the module's global types into `LCtx`, mirroring `local_types`).

### 2. `lower_call_indirect` (the 3-fault dispatch is the *runtime's* job — lower just shapes it)

```gleam
fn lower_call_indirect(type_idx, table, tail, ctx, st) {
  use sig <- result.try(nth_err(ctx.types, type_idx, UnknownTypeIndex(type_idx)))
  let ir_ty = ir.FuncType(list.map(sig.params, to_ir_vt), list.map(sig.results, to_ir_vt))
  use #(index, stack1) <- result.try(pop1(st.stack))            // table index is on top
  let args = take_push_order(stack1, list.length(sig.params))   // then the call args
  // bind `list.length(sig.results)` fresh result names, push them (reversed), continue:
  // ir.CallIndirect(tname(table), index, ir_ty, args)
}
```

`tname(table) = "t" <> int.to_string(table)`; MVP `table` is the reserved `0` → `"t0"`. The
`ir_ty` is the **structural** expected type — the runtime does the per-call type check against
it (E3). lower carries no funcidx and no `apply` — D3a is preserved structurally.

### 3. `lower_select` — 0x1B lowers to the existing `If` (no new node)

`select` pops `cond` (top), then `val2`, then `val1`; returns `val1` iff `cond ≠ 0`
([exec/instructions](https://webassembly.github.io/spec/core/exec/instructions.html), select).

```gleam
use #(cond, stack1) <- result.try(pop1(st.stack))         // cond on top
let [val1, val2] = take_push_order(stack1, 2)             // val1 deeper, val2 nearer top
let t = value_type(st, val1)                              // both operands share one type
// bind fresh name to:  ir.If(cond, [t], ir.Values([val1]), ir.Values([val2]))
```

then-branch = `val1` (cond true), else = `val2` — exactly the spec. The result type list must
have **arity 1**; `t` is the operand's `ValType`. See §5 for `value_type`.

### 4. Opcode→op table extensions

Extend `num_op/1` (returns `#(arity, ir.NumOp)`) with the float ops — unary arity 1, binary
arity 2, comparisons arity 2 (comparisons yield **i32**, not a float — relevant for type
tracking):

| WASM | NumOp | | WASM | NumOp |
|---|---|---|---|---|
| `f{32,64}.abs` | `FAbs(w)` | | `f{32,64}.add` | `FAdd(w)` |
| `f{32,64}.neg` | `FNeg(w)` | | `f{32,64}.sub` | `FSub(w)` |
| `f{32,64}.ceil` | `FCeil(w)` | | `f{32,64}.mul` | `FMul(w)` |
| `f{32,64}.floor` | `FFloor(w)` | | `f{32,64}.div` | `FDiv(w)` |
| `f{32,64}.trunc` | `FTrunc(w)` | | `f{32,64}.min` | `FMin(w)` |
| `f{32,64}.nearest` | `FNearest(w)` | | `f{32,64}.max` | `FMax(w)` |
| `f{32,64}.sqrt` | `FSqrt(w)` | | `f{32,64}.copysign` | `FCopysign(w)` |
| `f{32,64}.eq` | `FEq(w)` | | `f{32,64}.gt` | `FGt(w)` |
| `f{32,64}.ne` | `FNe(w)` | | `f{32,64}.le` | `FLe(w)` |
| `f{32,64}.lt` | `FLt(w)` | | `f{32,64}.ge` | `FGe(w)` |

where `w = FW32` for the `f32.*` opcode, `FW64` for `f64.*`. (`FAdd/FSub/FMul/FDiv/FMin/FMax`
already exist; this adds the other 14 NumOp constructors per width from `«IR2-FROZEN»`.)

Extend `conv_op/1` (returns `ir.ConvOp`, arity 1) with the **full 0xA7–0xBF block**:

| WASM | ConvOp | new? |
|---|---|---|
| `i32.wrap_i64` | `I32WrapI64` | existing |
| `i64.extend_i32_s` / `_u` | `I64ExtendI32S` / `I64ExtendI32U` | existing |
| `i32.reinterpret_f32` / `i64.reinterpret_f64` | `ReinterpretFToI(FW32)` / `ReinterpretFToI(FW64)` | existing |
| `f32.reinterpret_i32` / `f64.reinterpret_i64` | `ReinterpretIToF(W32)` / `ReinterpretIToF(W64)` | existing |
| `i32.trunc_f32_s/u` | `TruncS/U(FW32, W32)` | **new** |
| `i32.trunc_f64_s/u` | `TruncS/U(FW64, W32)` | **new** |
| `i64.trunc_f32_s/u` | `TruncS/U(FW32, W64)` | **new** |
| `i64.trunc_f64_s/u` | `TruncS/U(FW64, W64)` | **new** |
| `f32.convert_i32_s/u` | `ConvertS/U(W32, FW32)` | **new** |
| `f32.convert_i64_s/u` | `ConvertS/U(W64, FW32)` | **new** |
| `f64.convert_i32_s/u` | `ConvertS/U(W32, FW64)` | **new** |
| `f64.convert_i64_s/u` | `ConvertS/U(W64, FW64)` | **new** |
| `f32.demote_f64` | `F32DemoteF64` | **new** |
| `f64.promote_f32` | `F64PromoteF32` | **new** |

Field order is fixed by the freeze: `TruncS(from: FloatWidth, to: IntWidth)`,
`ConvertS(from: IntWidth, to: FloatWidth)`. The **trapping** trunc lowers exactly like any other
`Convert` — lower does **not** mark it; emit_core (unit 10) learns which ConvOps trap and wires
`case`/`raise`. `select_t` (0x1C) and any reftype op stay `Unsupported` (Phase 3, E8).

### 5. SSA value-type tracking (needed for `select`)

Every IR result type in Phase-2 lowering is opcode-determined **except** `select`, whose result
type equals its operands' type. Add `var_types: Dict(String, ir.ValType)` to `LState`: whenever
lower mints a fresh SSA name for a value, record `name → its type` (the binder already knows it —
param types, declared-local types, an op's result type, a load's `result`, `MemSize`/`MemGrow`/
comparison → `TI32`, a call's result types, a construct's `result_types`, loop-param types).
Then:

```gleam
fn value_type(st, v) -> ir.ValType {
  case v {
    ir.ConstI32(_) -> ir.TI32   ir.ConstI64(_) -> ir.TI64
    ir.ConstF32(_) -> ir.TF32   ir.ConstF64(_) -> ir.TF64
    ir.Var(n) -> dict.get(st.var_types, n) |> result.unwrap(ir.TI32)  // validated: always present
  }
}
```

`var_types` keys are stable names (never reshuffled), so this is robust across the stack
reshaping in `finish_construct`/`lower_loop`/`lower_if`. (Alternative, if unit 08 cooperates:
have `validate.TypedModule` annotate each `select` with its resolved `ValType`. The lower-local
dict keeps unit 09 self-contained — prefer it.)

### 6. Module-level declarations (in `lower/1`)

`«IR2-FROZEN»` adds `tables` and `elements` to `ir.Module`, so the existing `ir.Module(…)`
constructor call **must** be updated to pass them (Gleam has no default fields). Populate:

```gleam
ir.Module(
  name: "twocore@wasm@" <> module_base(module),
  uses_numerics: True,
  memory: lower_memory(module),              // Some(MemoryDecl(min,max)) | None
  globals: lower_globals(module),            // List(GlobalDecl)
  tables: lower_tables(module),              // List(TableDecl)   — NEW field
  elements: lower_elements(module),          // List(ElementSegment) — NEW field
  imports: [],
  functions: functions,
  exports: exports,
  data_segments: lower_data(module),         // List(DataSegment)
)
```

- `lower_memory`: the MVP single memory → `Some(ir.MemoryDecl(min_pages, max_pages))`, else
  `None`. (`max_pages: Option(Int)` straight from the limits.)
- `lower_globals`: global `i` → `ir.GlobalDecl("g"<>i, to_ir_vt(g.ty), g.mutable,
  lower_const_expr(g.init))`. Order = declaration order (= index order). No imported globals in
  Phase 2, so global index = defined index.
- `lower_tables`: table `i` → `ir.TableDecl("t"<>i, min, max)` (funcref implicit). MVP ⇒ one,
  named `"t0"`.
- `lower_elements`: active segment → `ir.ElementSegment("t"<>table, lower_const_expr(offset),
  list.map(funcs, fn(idx){ "f"<>int.to_string(idx) }))`. `"f"<>funcidx` is **the same** name
  `lower_func` gives funcidx (`name: "f"<>funcidx`), so element targets resolve.
- `lower_data`: active segment → `ir.DataSegment(lower_const_expr(offset), bytes)` (`bytes:
  BitArray`).
- `lower_const_expr(instrs) -> Result(ir.Expr, LowerError)`: Phase-2 MVP accepts a **single**
  `t.const` (optionally followed by `End`) → `ir.Values([the_const_value])` (reuse
  `unsigned_bits` for ints; floats are raw bits). Anything else (notably `global.get`, the
  imported-global form) → `Error(NonConstInitExpr(detail))` — a new, additive `LowerError`
  variant. Fail-closed, never panic.

> **Pitfall — global/memory mutation is NOT an SSA local.** `global.set`/`*.store` mutate the
> instance **cell** at runtime (E1), not a WASM local. They must **not** enter `scan_modified`/
> `carried`/`LoopParam`. Only mutable WASM *locals* keep using the Phase-1 LoopParam mechanism.
> The new ops are all flat (non-structural), so `scan_modified`/`consume_dead` handle them via
> their existing wildcard arm — no change to the depth-tracking scanners.

## Grounded facts you MUST honor

Transcribed from the verified research (topics 1, 2, 4) and the WASM spec. **Cite these in
tests.**

- **Load/store opcodes** ([binary/instructions](https://webassembly.github.io/spec/core/binary/instructions.html)):
  `0x28 i32.load … 0x35 i64.load32_u`, `0x36 i32.store … 0x3E i64.store32`. Each is **followed by
  a memarg** `{align:u32, offset:u32}`. `memory.size = 0x3F`, `memory.grow = 0x40`, each followed
  by a single `0x00` memory-index byte (not a memarg). Decode (unit 07) handles the bytes; lower
  consumes the AST. **Alignment is a non-semantic hint** — lower **drops `m.align`** and carries
  only `m.offset` (validation already checked `2^align ≤ N/8`, unit 08).
- **Load result width+sign disambiguation (E2):** `i32.load8_s` and `i64.load8_s` are the same
  bytes+sign but **different result bits** — that is exactly why `MemLoad` carries `result:
  ValType`. Set it from the opcode (table above). `load8_s/16_s/32_s` ⇒ `signed: True`; `_u` and
  full-width ⇒ `signed: False`. `f32.load`==`i32.load` and `f64.load`==`i64.load` at the byte
  level (floats are raw bits, D5) — they differ only in `result`.
- **Store** writes the low N bits; `op.signed` is **irrelevant** — set `False` and document it.
  Evaluation order is **addr, then value** (the freeze) — `take_push_order(stack,2) =
  [addr,value]`.
- **`call_indirect` = 0x11**, immediates `typeidx y` **then** `tableidx x` (the decoder already
  reads `ty` then `table` — do not swap). The static type is `C.types[y]`; the per-call type
  check is **dynamic** (runtime, E3). MVP table immediate is the reserved `0` ⇒ `"t0"`.
- **Conversion block 0xA7–0xBF interleaves int+float** (E7): `0xA7 wrap`, `0xA8–0xAB i32.trunc_f*`,
  `0xAC/0xAD i64.extend_i32_s/u`, `0xAE–0xB1 i64.trunc_f*`, `0xB2–0xB5 f32.convert_i*`, `0xB6
  demote`, `0xB7–0xBA f64.convert_i*`, `0xBB promote`, `0xBC–0xBF reinterpret`. wrap/extend/
  reinterpret reuse **existing** ConvOps and need **no new rt_num**; trunc/convert/demote/promote
  are the new ConvOps.
- **`select` 0x1B** ([exec/instructions](https://webassembly.github.io/spec/core/exec/instructions.html)):
  pops `c` (i32), `v2`, `v1`; result `v1` if `c≠0` else `v2`. Lower to `If(c,[t],Values([v1]),
  Values([v2]))` — **no new IR node**. `select_t` 0x1C is deferred (E7/E8).
- **Globals** ([binary/instructions](https://webassembly.github.io/spec/core/binary/instructions.html)):
  `global.get = 0x23`, `global.set = 0x24`. Index→name must be **stable** and match emit/
  instantiate — `"g"<>idx`. mutability is enforced at validation (unit 08), not lower. f32/f64
  global init values stay **raw IEEE bit patterns** (D5).
- **Const expressions** ([valid/instructions](https://webassembly.github.io/spec/core/valid/instructions.html)):
  MVP permits only `t.const` and `global.get` of an **immutable imported** global. With no
  imports in Phase 2, a valid const expr is effectively a single `t.const` — lower accepts that
  and rejects the rest (extended-const `i32.add` etc. is a *proposal*, correctly rejected).
- **Sections** ([binary/modules](https://webassembly.github.io/spec/core/binary/modules.html)):
  table=4, global=6, element=9, data=11; MVP active element = flag 0 (`offset-expr` + `vec(funcidx)`);
  MVP active data = form 0 (`offset-expr` + `vec(byte)`). lower consumes the decoded AST; it does
  not re-parse. Instantiation order (globals→elements→data→start) is unit 10/11's concern — lower
  only supplies the declarations.
- **Float comparison ops return i32 0/1** (record `TI32` in `var_types`, not the float width).
  Float arith/unary return the float width.

## Verification — Definition of Done (D8)

Tests assert **spec behaviour / the spec's opcode meaning**, not whatever the code emits — no
change-detector tests. Use `wat2wasm` fixtures decoded+validated through units 07/08, then lower.

1. **Structural faithfulness (spec opcode meaning).** A memory program lowers to `MemLoad`/
   `MemStore` with the **right `MemAccess(bytes,signed)` and `result`** per the opcode table
   (assert `i32.load8_s` ⇒ `MemAccess(1,True)`+`TI32`; `i64.load8_s` ⇒ `MemAccess(1,True)`+`TI64`;
   `f32.load` ⇒ `MemAccess(4,False)`+`TF32`) — cite binary/instructions. `call_indirect` ⇒ one
   `CallIndirect("t0", index, ir_ty, args)` with `ir_ty` = the structural `C.types[y]`. `select`
   ⇒ `If(cond,[t],Values([a]),Values([b]))` with then=`a` (cite exec/instructions: `v1` when
   `c≠0`). A module with `memory.grow` ⇒ contains `MemGrow`; `memory.size` ⇒ `MemSize`. The full
   conversion block: assert each 0xA7–0xBF opcode maps to its row.
2. **Module decls populated.** A module with a table+element+global+data+memory lowers to a
   `Module` whose `tables`/`elements`/`globals`/`data_segments` are non-empty and whose `memory`
   is `Some`; element target names equal `"f"<>funcidx` and resolve to a real `Function`; global
   names equal `"g"<>idx` and match every `GlobalGet/Set`. A const-literal global init lowers to
   `Values([Const…])` with the **bit-exact** value (NaN payload / `-0.0` preserved for float
   globals — D5).
3. **Round-trip through `.ir` (unit 02).** Lowered IR with the new variants `parse(print(m))==m`
   (gated on unit 02 implementing them; lower's output must be well-formed — bit-exact float
   compare per D7).
4. **Fail-closed (no panic).** An extended-const init (`i32.add` in a global) ⇒ typed
   `Error(NonConstInitExpr(_))`; `select_t`/any reftype op ⇒ `Error(Unsupported(_))`; an
   out-of-range type/func/local index ⇒ the corresponding `LowerError`. **Never** `panic`/`let
   assert`. (Re-use the existing fail-closed discipline.)
5. **End-to-end (proven at the capstone, unit 11):** the Phase-2 acceptance programs
   (`i32.store`→`i32.load` round-trip, a width-matrix load, `memory.grow` returns old size /
   `-1`, `call_indirect` to the right type, a mutable-global round-trip, the float op set) run
   spec-correctly. lower is on that path.
6. `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test` stays
   green (≥313, no Phase-1 regression). Every new public/private function gets a doc comment
   (the contract, per D8).

## Concurrency

Single file ⇒ mostly serial, but the additive pieces split cleanly once the two freezes land:

- **A — opcode tables:** extend `num_op` (14 float NumOps) + `conv_op` (10 new ConvOps + wire the
  existing wrap/extend/reinterpret arms). Pure, isolated; testable alone.
- **B — memory + select + call_indirect arms:** `emit_load`/`emit_store`/`emit_effect`/
  `emit_nullary` + the `var_types` tracking + `lower_call_indirect` + `lower_select`.
- **C — module decls:** `lower_memory/globals/tables/elements/data` + `lower_const_expr` +
  the `LCtx` global-types carry + the `ir.Module(…)` field update.

**Freeze first:** `«IR2-FROZEN»` must land before any arm emits a new node; `«WASM-AST2»` before
the arms can match the new constructors (stub against the names above meanwhile, re-sync on 07).

## What this leaves for others

- **Unit 08 (validate)** is the security boundary upstream: it type-checks the new ops, validates
  memarg alignment, global mutability, and const-expr rules **before** lower runs. lower assumes a
  validated module and keeps its defensive `LowerError`s only as fail-closed insurance.
- **Unit 10 (emit_core)** consumes every node lower emits: `MemLoad/MemStore/MemSize/MemGrow` →
  the cell state-access seam; `CallIndirect` → the 3-fault `rt_table` dispatch; `GlobalGet/Set` →
  `rt_state`; the trapping `TruncS/U` → `case`/`raise`; the float `NumOp`/`ConvOp`s → `rt_num`;
  and the `instantiate/N` entry built from `Module.memory/globals/tables/elements/data_segments`.
- **Unit 06** fills the float `rt_num` bodies; **unit 11** wires the `load→instantiate→invoke`
  run-ABI and the conformance allowlist (float/memory/global/call_indirect files).
