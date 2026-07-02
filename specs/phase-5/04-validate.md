# Unit P5-04 — WASM `validate` extension (typing the Phase-5 surface; the security boundary)

> **One owner · Wave A · AST-only.** Gates on **`«WASM-AST3»`** (unit **P5-03** decode's type
> stub, published day 1) — *not* on completed decoding — and runs in **parallel** with all the
> IR/runtime work (it never imports `twocore/ir`). Read [`00-overview.md`](00-overview.md)
> (decisions **H1–H8**) and the EM's provisional surface first; D1 (single-owner-per-file) and the
> Definition of Done still hold. This unit **extends** the existing
> [`phase-2/08-validate.md`](../phase-2/08-validate.md) validator — the Phase-1/2 polymorphic-stack
> / label / else-less-`if` / `max_locals` machinery is kept **verbatim**.

---

## Context

`validate.gleam` is the **security boundary** (overview D4/D9, H6). Its input AST is populated by
`frontend/wasm/decode.gleam` from **UNTRUSTED** bytes; everything downstream — `lower` (P5-05),
`emit_core` (P5-06), the runtime — *trusts* that a module which validated is well-typed, so it can
emit straight-line code with no re-checks. Phase 1 shipped a faithful transcription of the spec's
abstract stack-typing algorithm; Phase 2 extended it to the full WASM-1.0 op set (the load/store
matrix, `memory.size/grow`, `global.*` + mutability, `call_indirect`, the float and conversion
blocks, untyped `select`, const-expr validation, the `start` signature, limits, and the
`≤1 memory / ≤1 table` MVP caps).

Phase 5 completes the standardized surface (minus SIMD). The validator must now type-check — and,
critically, **fail-closed-reject** — the whole reference-types + bulk-memory + multi-memory +
memory64 + non-function-imports surface:

- **Reference types** (`funcref`/`externref` as first-class value types; `ref.null t`, `ref.func x`
  with its **declared-reference** (`C.refs`) requirement, `ref.is_null`; the reftype/heaptype
  relation).
- **Typed `select t`** (0x1C) and the **restriction** that *untyped* `select` (0x1B) is invalid for
  reference operands.
- **Tables typed by reftype** — `table.get/set/size/grow/fill` operand+result types; **multiple
  tables**; `tableidx` bounds.
- **Bulk memory & table ops** — `memory.init/copy/fill`, `data.drop`, `table.init/copy`,
  `elem.drop`: the `i32`/`i64` index+count operand types, `dataidx`/`elemidx`/`memidx`/`tableidx`
  bounds, the reftype-match rule for `table.init`/`table.copy`.
- **Multi-memory** — every memory instruction's `memidx` in bounds; **>1 memory allowed** (the
  Phase-2 `TooManyMemories`/`TooManyTables` caps are lifted).
- **memory64** — an `i64` address operand when the memory is 64-bit; the align cap follows the
  *access* width; the `memory.copy` count uses the **minimum** of the two memories' index types.
- **Segment validation** — active-offset const-expr type = the memory's index type (`i32` for
  tables); passive/declarative element reftypes; the element/data mode variants.
- **Import/export typing** — imported globals/tables/memories populate the module's index spaces
  (imports precede definitions); `global.get` of an **imported immutable** global becomes a legal
  constant expression; export indices are range-checked.

The validator gates **independently of the IR**: a type-unsafe module must be rejected here even if
the backend would have coincidentally produced something. Every ill-typed fixture must be rejected
with a **spec-cited** `ValidateError`; the worst case of a bounds/type bug must be a wrong/missing
*validation* rejection, **never** a host escape (H6).

## Goal

Extend the abstract-stack validator to every Phase-5 op so that (a) every well-typed module is
accepted and carries the typing facts lowering needs, and (b) every ill-typed module is rejected
with the `ValidateError` the spec rule demands — **without** touching the Phase-1/2 polymorphic-stack
/ label algorithm. A measurable outcome: the spec suite's `assert_invalid` corpora for
`ref_null`/`ref_func`/`ref_is_null`/`select`/`table_*`/`elem`/`bulk`/`memory_init`/`memory_copy`/
`memory_fill`/`imports`/`linking`/`data`/`global` land on this validator and go **green** (rejected
for the spec-correct reason, not silently skipped); every valid module in those files is accepted.

## Files owned

| File | Action |
|---|---|
| `src/twocore/frontend/wasm/validate.gleam` | **EXTEND** (single-owner; AST-only — the security boundary). |
| `test/twocore/frontend/wasm/validate_test.gleam` | **EXTEND** — spec-cited acceptance + rejection tests for the new ops. |

No other file. This unit imports `twocore/frontend/wasm/ast` **only** (grep-proven: **no
`twocore/ir` import**), so its conformance gates independently of the backend.

## Deliverables & freeze milestones

This unit produces **no** cross-unit freeze milestone of its own — it is a *consumer* of
`«WASM-AST3»` and a *producer* of the extended `TypedModule` that **P5-05 (lower)** consumes. It
must, however, **freeze the `TypedModule` + `ValidateError` + `Ctx` shapes early** (a mini-freeze,
day 1 of Wave A) so P5-05 can target them. Deliverables:

1. New `ValidateError` variants (§B) — additive; every Phase-1/2 variant kept.
2. The extended `TypedModule` (§B) carrying the reference/table/memory typing facts lowering needs.
3. The extended `Ctx` (§B) threaded into `validate_instr` (index spaces + reftypes + `C.refs`).
4. Per-op typing (§C–§K) transcribed from the spec, each with a spec citation.
5. Spec-cited acceptance + rejection tests (§Verification).

## Depends on (freeze milestones)

- **`«WASM-AST3»`** (P5-03 decode, published day 1) — the extended `frontend/wasm/ast.gleam`: the
  reference value types, the `0xFC`-prefix bulk/table opcodes, the ref instructions, the
  memory-index immediates, the memory64 limits flags/idx-type, the passive/declarative segment
  encodings, the non-function imports/exports, typed `select`, and the expression-form element
  encoding. **Stub against it meanwhile** — P5-03 owns the *exact* spelling. Write the typing tables
  keyed by the spec **mnemonic + reftype/idx-type**; if P5-03's constructor names differ, only the
  `case` patterns change, not the rules. Confirm field names the moment `«WASM-AST3»` lands (§A is
  this unit's precise expectation of that shape — the seam to reconcile with P5-03).
- It does **NOT** depend on `«IR3-FROZEN»`, `«RT3-SIG»`, or `«INSTANTIATE3»` (AST-only boundary).

## Scope — in / out for Phase 5

**In:** typing for `ref.null`/`ref.func`/`ref.is_null`; typed `select t` + the untyped-`select`
reference restriction; `table.get/set/size/grow/fill`; `memory.init/copy/fill` + `data.drop`;
`table.init/copy` + `elem.drop`; multi-memory `memidx` bounds (>1 memory allowed); memory64 `i64`
address/size/grow/fill/copy/init typing; multiple tables + `tableidx` bounds; active/passive/
declarative element segments + active/passive data segments; the extended constant-expression
grammar (`ref.null`/`ref.func`/`global.get` of an imported immutable global); non-function
import/export index-space wiring; the `C.refs` declared-reference set.

**Out (defer — state it, don't drop it):**
- **SIMD** (`v128`, typed `select` of a vector, `table.*`/`memory.*` over v128) → **Phase 6**. A
  `v128` value type / a lane instruction stays whatever P5-03 emits (decoder-rejected or a
  `Unsupported` leaf); this validator does **not** grow a v128 arm.
- **GC-proposal reference types** — typed function references (`ref $t`, `ref null $t`), `struct`/
  `array`/`i31`, non-trivial reftype subtyping → later. Phase 5 reftypes are the two MVP nullable
  reftypes `funcref`/`externref`, with **no subtyping** between them (§C).
- **The extended-const proposal** (`i32.add`/`global.get` arithmetic in const exprs) stays rejected
  as `NonConstantExpr`, exactly as Phase 2 (the conformance runner skips those valid-under-
  extended-const asserts honestly — see [`phase-2/08-validate.md`](../phase-2/08-validate.md)).
- **All runtime trap behavior** (table/memory OOB, `uninitialized element`, indirect-call type
  mismatch, out-of-bounds bulk ops) is **dynamic**, *not* validation — validate only checks static
  operand/result types and index bounds.
- **The data-count section presence rule** for `memory.init`/`data.drop` is a *decode* structural
  concern (P5-03); this unit checks only `dataidx < |data segments|` (§F, Open questions).

---

## A. The `«WASM-AST3»` surface this unit consumes (the P5-03 seam)

This is the **precise shape** the typing rules below assume. P5-03 owns the final spelling; where a
name is provisional it is flagged. If P5-03 diverges, keep the *rules* and re-map the `case`
patterns. (Contrast the EM's provisional-surface doc, which frozen the **IR3** shapes; this section
is the parallel **AST3** expectation, since `validate` reads the AST, never the IR.)

### A.1 Value & reference types

```gleam
// ast.gleam — extended
pub type ValType {
  I32  I64  F32  F64
  FuncRef        // NEW — 0x70 funcref  (≡ ref null func)
  ExternRef      // NEW — 0x6F externref (≡ ref null extern)
}

/// The subset of ValType that is a reference type. Used by table decls, element
/// segments, ref.null, and select_t's annotation.
pub type RefType { RFuncRef  RExternRef }
```

`RefType → ValType` is total (`RFuncRef → FuncRef`, `RExternRef → ExternRef`); a helper
`ref_valtype(RefType) -> ValType` lives in `validate` if `ast` does not expose it. **Reftype/heaptype
relation (MVP):** each reftype is *nullable* (`ref null ht`); the heap types are `func`/`extern`;
there is **no subtyping** between `funcref` and `externref`, so reftype matching is plain equality
(spec [`valid/types` — Reference Types](https://webassembly.github.io/spec/core/valid/types.html)).

### A.2 Declarations (index spaces now include imports)

```gleam
pub type IdxType { Idx32  Idx64 }                        // NEW — memory address width

pub type MemType  { MemType(limits: Limits, idx_type: IdxType) }        // idx_type NEW (default Idx32)
pub type TableType{ TableType(ref_ty: RefType, limits: Limits) }        // ref_ty NEW (default RFuncRef)

pub type Import {                                                        // NEW section (was absent)
  ImportFunc(module: String, name: String, type_idx: Int)
  ImportGlobal(module: String, name: String, ty: ValType, mutable: Bool)
  ImportTable(module: String, name: String, ty: TableType)
  ImportMemory(module: String, name: String, ty: MemType)
}

pub type ExportKind { ExportFunc  ExportTable  ExportMemory  ExportGlobal }   // as today
pub type Export     { Export(name: String, kind: ExportKind, index: Int) }    // as today

pub type ElemMode {                                                     // NEW
  ElemActive(table: Int, offset: List(Instr))
  ElemPassive
  ElemDeclarative
}
pub type ElementSegment {                                              // CHANGED shape
  ElementSegment(mode: ElemMode, ref_ty: RefType, init: List(List(Instr)))
  // each `init` entry is a constant expression producing a value of `ref_ty`
}

pub type DataMode { DataActive(mem: Int, offset: List(Instr))  DataPassive }   // NEW
pub type DataSegment { DataSegment(mode: DataMode, bytes: BitArray) }          // CHANGED shape

pub type Module {
  Module(
    imported_func_count: Int,       // now DERIVED from `imports` (may be > 0)
    imports: List(Import),          // NEW
    types: List(FuncType),
    tables: List(TableType),        // may be > 1 (multi-table)
    memories: List(MemType),        // may be > 1 (multi-memory)
    globals: List(Global),
    funcs: List(Func),
    start: Option(Int),
    elements: List(ElementSegment),
    data: List(DataSegment),
    exports: List(Export),
    data_count: Option(Int),        // NEW — the data-count section value, if present
  )
}
```

### A.3 Instructions (new leaves the validator must type)

Memory load/store/`size`/`grow` gain a **memidx** (provisionally on the `MemArg`, or as a separate
field — P5-03's call). The typing rule reads it as `memidx: Int` regardless.

```gleam
pub type MemArg { MemArg(align: Int, offset: Int, mem: Int) }   // `mem` NEW (default 0)

// references
RefNull(RefType)              // 0xD0
RefIsNull                     // 0xD1
RefFunc(func: Int)            // 0xD2
// parametric
SelectT(types: List(ValType)) // 0x1C  (Select, 0x1B, already exists — now restricted)
// tables
TableGet(table: Int)          // 0x25
TableSet(table: Int)          // 0x26
TableSize(table: Int)         // 0xFC 16
TableGrow(table: Int)         // 0xFC 15
TableFill(table: Int)         // 0xFC 17
TableInit(elem: Int, table: Int)   // 0xFC 12  (binary immediate order elemidx,tableidx — see Open Q)
TableCopy(dst: Int, src: Int)      // 0xFC 14
ElemDrop(elem: Int)                // 0xFC 13
// bulk memory
MemoryInit(data: Int, mem: Int)    // 0xFC 8
DataDrop(data: Int)                // 0xFC 9
MemoryCopy(dst: Int, src: Int)     // 0xFC 10
MemoryFill(mem: Int)               // 0xFC 11
```

Opcode bytes are cited from [`binary/instructions`](https://webassembly.github.io/spec/core/binary/instructions.html);
their decode is P5-03's concern — listed here only to anchor the mnemonics.

---

## B. New `ValidateError` variants, the extended `Ctx`, and `TypedModule`

### B.1 `ValidateError` (additive — keep every Phase-1/2 variant)

```gleam
pub type ValidateError {
  // … existing: TypeMismatch, Underflow, UnknownLocal, UnknownGlobal, UnknownFunc,
  //   UnknownType, UnknownLabel, UnknownMemory, UnknownTable, ImmutableGlobal,
  //   BadAlignment, NonConstantExpr, BadLimits, TooManyMemories, TooManyTables,
  //   BadStartType, BranchArityMismatch, IfElseMismatch, UnexpectedEnd,
  //   TooManyLocals, Unsupported …
  UnknownData(index: Int)          // NEW — dataidx out of range (memory.init / data.drop)
  UnknownElem(index: Int)          // NEW — elemidx out of range (table.init / elem.drop)
  UndeclaredFunctionRef(index: Int)// NEW — ref.func x where x ∉ C.refs (x may still be in range)
  RefTypeMismatch                  // NEW — a reftype disagreement (table.init/copy/select_t/table op)
  BadSelectType                    // NEW — untyped select on a reference operand, or select_t arity ≠ 1
  UnknownImportKind(detail: String)// NEW — an import/export whose referent index is out of its space
}
```

Notes on variant choice (spec-honest, diagnosable):
- `UnknownMemory(index)` / `UnknownTable(index)` now carry the **real** `memidx`/`tableidx` (not
  always `0`) and fire on any out-of-range index, not merely "module declares none".
- `RefTypeMismatch` is used where the spec calls for a reference-type disagreement that is *not* a
  numeric width mismatch (e.g. `table.init` into a `funcref` table from an `externref` elem). Reusing
  `TypeMismatch` would also be spec-honest ("type mismatch"); a dedicated variant is kept for
  diagnosis and because the conformance runner asserts *a* rejection, never message text. **A
  single, consistent choice must be made and documented** — pick `RefTypeMismatch` for reference
  disagreements and `TypeMismatch` for numeric ones.
- `TooManyMemories` / `TooManyTables` are **retained in the type but no longer produced** by the
  default path (multi-memory/multi-table are in scope, H3). A public constructor left unused does
  **not** warn in Gleam, so DoD "zero warnings" holds. (They may be reused if a future "single-memory
  profile" flag is added; do not delete — that is an API break.)

### B.2 The extended `Ctx`

The Phase-2 `Ctx` carried `types`, `func_types`, `globals`, `has_memory`, `has_table`, `locals`.
Phase 5 replaces the two booleans with **full index spaces** and adds the segment/ref facts:

```gleam
type Ctx {
  Ctx(
    types: List(FuncType),
    func_types: List(FuncType),        // per-funcidx signatures — IMPORTS ++ defined
    globals: List(#(ValType, Bool)),   // (type, mutable?) by globalidx — imports ++ defined
    tables: List(#(RefType, Limits)),  // reftype + limits by tableidx — imports ++ defined
    memories: List(IdxType),           // address width by memidx — imports ++ defined
    data_count: Int,                   // number of data segments (dataidx bound)
    elem_types: List(RefType),         // reftype of each element segment (elemidx → reftype)
    refs: set.Set(Int),                // C.refs — the module's declared function references
    locals: List(ValType),             // current function's expanded local types
  )
}
```

`has_memory`/`has_table` become `ctx.memories != []` / `ctx.tables != []`; the *index-in-range*
lookups (`nth ctx.memories memidx`, `nth ctx.tables tableidx`) subsume them and give the precise
`UnknownMemory(memidx)`/`UnknownTable(tableidx)`.

### B.3 `TypedModule` (what lowering consumes)

Lowering (P5-05) needs, beyond the Phase-2 facts, the **reftypes** of tables and element segments,
the **idx types** of memories, and the resolved import counts. Add exactly what is not trivially
re-derivable:

```gleam
pub type TypedModule {
  TypedModule(
    module: Module,
    imported_func_count: Int,          // now real (imports may exist)
    imported_global_count: Int,        // NEW — globalidx offset for imports
    imported_table_count: Int,         // NEW
    imported_memory_count: Int,        // NEW
    func_types: List(FuncType),        // imports ++ defined
    func_locals: List(List(ValType)),  // per defined function
    global_types: List(ValType),       // by globalidx (imports ++ defined)
    table_types: List(RefType),        // NEW — reftype by tableidx
    memory_idx_types: List(IdxType),   // NEW — address width by memidx
    elem_types: List(RefType),         // NEW — reftype by elemidx
    refs: set.Set(Int),                // NEW — C.refs (lower needs it for ref.func lowering guards)
  )
}
```

Load result widths still live on the opcode; `table.get`/`global.get` result types remain
re-derivable from `table_types`/`global_types`, so no per-instruction annotation map is added
(the Phase-2 discipline).

---

## C. Reference types — value types, `ref.*` instructions, and `C.refs`

Spec: [`valid/instructions` — Reference Instructions](https://webassembly.github.io/spec/core/valid/instructions.html#reference-instructions).

### C.1 The declared-reference set `C.refs`

Per the spec, `ref.func x` is valid **only if `x ∈ C.refs`** — the set of function indices *declared*
in the module. `C.refs` is the set of `funcidx` that occur outside function bodies, specifically in:
element segments (any mode — active, passive, **declarative**), global initializer expressions, and
function exports (spec [`valid/modules` — Modules](https://webassembly.github.io/spec/core/valid/modules.html),
the `funcidx(module)` free-occurrence collection). Declarative element segments exist **solely** to
add indices to `C.refs` so a program may `ref.func x` inside code without also materializing a table
entry. Function bodies do **not** contribute (a `ref.func` in a body *requires*, never *declares*).

Compute `C.refs` **once, up front**, before validating bodies and const-exprs:

```
refs := ∅
for each global g:      for each `RefFunc(x)` in g.init:          refs := refs ∪ {x}
for each element seg e: for each init-expr ie, each `RefFunc(x)`: refs := refs ∪ {x}
                        (and each funcidx-form item x)             refs := refs ∪ {x}
for each export ex where ex.kind == ExportFunc:                    refs := refs ∪ {ex.index}
```

`start` funcidx does **not** join `refs` (it is a call, not a reference). Store the finished set in
`Ctx.refs` and `TypedModule.refs`.

### C.2 The `ref.*` typing table

| instr | operands → result | rule / failure |
|---|---|---|
| `ref.null t` (0xD0) | `[] → [t]` (t a reftype) | always valid; pushes the reftype `t`. |
| `ref.is_null` (0xD1) | `[t] → [i32]` (t **any** reftype) | pop one operand; it must be a reference type (`Known(FuncRef)`/`Known(ExternRef)` or `Unknown`); push `i32`. A **numeric** operand → `TypeMismatch`. |
| `ref.func x` (0xD2) | `[] → [funcref]` | `x` in funcidx range **and** `x ∈ C.refs`; else `UnknownFunc(x)` (out of range) / `UndeclaredFunctionRef(x)` (in range but not declared). Push `FuncRef`. |

`ref.is_null` is *reference-polymorphic*: it accepts either reftype. Implement by popping one value
and asserting it is a reference type (or `Unknown`) — do **not** hard-code `FuncRef`. Cite
[`ref_is_null.wast`](https://github.com/WebAssembly/spec/blob/main/test/core/ref_is_null.wast),
[`ref_func.wast`](https://github.com/WebAssembly/spec/blob/main/test/core/ref_func.wast) (the
`assert_invalid` for an undeclared `ref.func`).

---

## D. `select` — typed and the untyped-reference restriction

Spec: [`valid/instructions` — Parametric](https://webassembly.github.io/spec/core/valid/instructions.html#parametric-instructions).

- **Untyped `select` (0x1B):** `[t t i32] → [t]` where **`t` is a number type** (or vector — SIMD,
  out of scope). The two value operands must agree. Under Phase 5 this now **must reject reference
  operands**: after popping the `i32` and the two values, if the resolved operand type is a `Known`
  **reference** type → `BadSelectType`. (This is the one behavior change to an existing arm: the
  Phase-2 `Select` accepted any matching pair; with reftypes present that would wrongly accept
  `select` of two `funcref`s.) A `Known` numeric type is fine; both `Unknown` (post-`unreachable`)
  stays polymorphic and yields `Unknown`.
- **Typed `select t` (0x1C):** carries an annotation vector. Per the current spec the vector must
  have **exactly one** value type; a length ≠ 1 → `BadSelectType`. Signature `[t t i32] → [t]` with
  `t` the annotated type — which **may be a reference type**. Pop `i32`, pop `t`, pop `t`, push `t`.

```gleam
ast.SelectT(types) ->
  case types {
    [t] -> {
      use st1 <- result.try(pop_expect(st, ast.I32))
      use st2 <- result.try(pop_expect(st1, t))
      use st3 <- result.try(pop_expect(st2, t))
      Ok(push_val(st3, t))
    }
    _ -> Error(BadSelectType)      // spec: select annotation arity must be 1
  }
```

Cite [`select.wast`](https://github.com/WebAssembly/spec/blob/main/test/core/select.wast) — both the
`assert_invalid` for untyped `select` of references and the valid typed-`select` cases.

---

## E. Tables typed by reftype — `table.get/set/size/grow/fill` + multiple tables

Spec: [`valid/instructions` — Table Instructions](https://webassembly.github.io/spec/core/valid/instructions.html#table-instructions).
Tables are always **`i32`-indexed** (table64 is a separate later proposal — out of scope). Let
`t = reftype(C.tables[x])` (via `nth ctx.tables x`; out of range → `UnknownTable(x)`).

| instr | operands → result | notes |
|---|---|---|
| `table.get x` (0x25) | `[i32] → [t]` | pop `i32` index, push the table's reftype. |
| `table.set x` (0x26) | `[i32 t] → []` | pop value `t` (top), then `i32` index. |
| `table.size x` (0xFC 16) | `[] → [i32]` | push `i32`. |
| `table.grow x` (0xFC 15) | `[t i32] → [i32]` | pop `i32` delta (top), then init value `t`; push `i32` (old size / −1 at runtime). |
| `table.fill x` (0xFC 17) | `[i32 t i32] → []` | pop `i32` count (top), value `t`, `i32` offset. |

**Multiple tables:** the Phase-2 `check_tables` `≤1` cap is **removed**; instead validate *each*
table's limits (`check_limits(_, table_entry_limit)`), and every table instruction routes through its
`tableidx` (no implicit `0`). `call_indirect y x` (Phase 2) now reads its real `tableidx x`, checks
`x` in range, and requires that table's reftype be **`funcref`** (an `externref` table cannot back an
indirect call) — else `RefTypeMismatch`. Cite
[`table_get.wast`/`table_set.wast`/`table_size.wast`/`table_grow.wast`/`table_fill.wast`](https://github.com/WebAssembly/spec/tree/main/test/core).

---

## F. Bulk memory & table ops — `memory.init/copy/fill`, `data.drop`, `table.init/copy`, `elem.drop`

Spec: [`valid/instructions` — Memory](https://webassembly.github.io/spec/core/valid/instructions.html#memory-instructions)
and Table Instructions. Let `at(m) = i32/i64` be the address type of memory `m` (§H); `i32` for a
32-bit memory. Segment index bounds: `dataidx < ctx.data_count` else `UnknownData(d)`;
`elemidx < |ctx.elem_types|` else `UnknownElem(e)`.

| instr | operands → result | index checks |
|---|---|---|
| `memory.init d m` (0xFC 8) | `[at(m) i32 i32] → []` | `m` in memory range; `d < data_count`. |
| `data.drop d` (0xFC 9) | `[] → []` | `d < data_count`. |
| `memory.copy dm sm` (0xFC 10) | `[at(dm) at(sm) at3] → []`, `at3 = min(at(dm),at(sm))` | both mems in range. |
| `memory.fill m` (0xFC 11) | `[at(m) i32 at(m)] → []` | `m` in range. |
| `table.init t e` (0xFC 12) | `[i32 i32 i32] → []` | `t`,`e` in range; `reftype(e) == reftype(t)` else `RefTypeMismatch`. |
| `elem.drop e` (0xFC 13) | `[] → []` | `e < |elem_types|`. |
| `table.copy dt st` (0xFC 14) | `[i32 i32 i32] → []` | both tables in range; `reftype(dt) == reftype(st)` else `RefTypeMismatch`. |

Key subtleties, transcribed exactly:
- **`memory.copy` count uses the *minimum* index type** of the two memories (`i32 < i64`): copying
  from a 64-bit into a 32-bit memory bounds the length to `i32` (spec/[memory64] copy rule). With
  both memories 32-bit this is the plain `[i32 i32 i32]`. **Operand order** (bottom→top):
  `dest_addr(at(dm))`, `src_addr(at(sm))`, `count(at3)`; pop count first.
- **`memory.fill` value byte is `i32`** even for a 64-bit memory: `[dest:at(m), value:i32, count:at(m)]`.
- **`memory.init` src/len index the data segment**, which is always `i32`: `[dest:at(m), src:i32, len:i32]`.
- **`table.*` bulk ops are all `i32`** (tables are `i32`-indexed regardless of memory64).
- **`table.init`/`table.copy` reftype match**: an `externref` elem into a `funcref` table (or a
  `funcref`→`externref` copy) is invalid.

`memory.init`/`data.drop` additionally require the module to carry a **data-count section**; the
count itself (`ctx.data_count`) is derived from that section by P5-03. If a `memory.init`/`data.drop`
occurs but no data-count section was present, the module is **invalid** — but that presence check is
a *decode* structural rule (P5-03), so this unit validates only `dataidx < data_count` (Open Q 3).
Cite [`bulk.wast`/`memory_init.wast`/`memory_copy.wast`/`memory_fill.wast`/`table_init.wast`/`table_copy.wast`](https://github.com/WebAssembly/spec/tree/main/test/core).

---

## G. Multi-memory — `memidx` bounds & routing

H3: `Module.memories` may hold **>1** memory; every memory-touching instruction carries a `memidx`.
The validator:
1. **Lifts the `≤1 memory` cap** — `check_memories` validates *each* memory's limits (§H for the
   range) and no longer returns `TooManyMemories`.
2. **Routes by `memidx`** — every load/store/`memory.size`/`memory.grow` and every bulk-memory op
   resolves its memory via `nth ctx.memories memidx`; out of range → `UnknownMemory(memidx)`. This
   supersedes the Phase-2 `require_memory` boolean (which assumed index 0). The single-memory case
   is `memidx == 0` and validates identically to Phase 4 (conformance-neutral, H7).
3. **Active data segments** likewise carry a `memidx` (`DataActive(mem, offset)`); the memory must be
   in range and the offset's const-expr type is that memory's index type (§I).

Cite [`memory.wast`/`memory_grow.wast`](https://github.com/WebAssembly/spec/tree/main/test/core) and
the multi-memory proposal.

---

## H. memory64 — `i64` address typing & the min-index-type rule

H3 (deferrable half, H8): a memory's `idx_type ∈ {Idx32, Idx64}` comes from the limits' index-type
flag (decode). Its **address type** is `at = i32` (`Idx32`) or `i64` (`Idx64`):

```gleam
fn addr_type(it: IdxType) -> ast.ValType {
  case it { Idx32 -> ast.I32   Idx64 -> ast.I64 }
}
fn mem_addr_type(ctx: Ctx, memidx: Int) -> Result(ast.ValType, ValidateError) {
  case nth(ctx.memories, memidx) {
    Ok(it) -> Ok(addr_type(it))
    Error(_) -> Error(UnknownMemory(memidx))
  }
}
```

Typing consequences (all cited from the [memory64 proposal](https://github.com/WebAssembly/memory64)
/ the merged core spec):

| instr | 32-bit memory | 64-bit memory |
|---|---|---|
| `t.load` / `t.store` | address `i32` | address `i64` |
| `memory.size` | `[] → [i32]` | `[] → [i64]` |
| `memory.grow` | `[i32] → [i32]` | `[i64] → [i64]` |
| `memory.fill` | `[i32 i32 i32] → []` | `[i64 i32 i64] → []` |
| `memory.init` | `[i32 i32 i32] → []` | `[i64 i32 i32] → []` |
| `memory.copy dm sm` | `[i32 i32 i32] → []` | `[at(dm) at(sm) min(...)] → []` |

**Alignment cap unchanged:** the memarg `2^align ≤ N/8` rule follows the **access** width (the
natural byte width of the load/store), *not* the address width — so `check_align` (Phase 2) is reused
verbatim for both 32- and 64-bit memories. The **limits range** does change: a 32-bit memory's limit
range is `2^16` pages; a 64-bit memory's is `2^48` pages (address space `2^64` bytes ÷ 64 KiB). Add:

```gleam
pub const memory64_page_limit: Int = 281_474_976_710_656   // 2^48

fn check_memory(m: ast.MemType) -> Result(Nil, ValidateError) {
  let range = case m.idx_type { Idx32 -> memory_page_limit  Idx64 -> memory64_page_limit }
  check_limits(m.limits, range)
}
```

> **H8 honesty:** memory64 is the deferrable half. If the runtime/lower side is cut from Phase 5,
> this validator still *types* memory64 correctly (rejecting an over-range 64-bit limit, requiring
> `i64` addresses) — but do not claim memory64 done unless the `memory64.wast` files actually run
> end-to-end. The typing here is spec-correct regardless.

---

## I. Segment validation — elements, data, offsets & index types

Spec: [`valid/modules` — Element/Data Segments](https://webassembly.github.io/spec/core/valid/modules.html).

### I.1 Element segments (`elements: List(ElementSegment)`, each `mode`/`ref_ty`/`init`)

For every segment, **each init entry** is a **constant expression** producing a value of `ref_ty`
(§K); a `ref.func`/`ref.null`/`global.get` mismatch → `TypeMismatch`/`RefTypeMismatch`. Then, by
mode:
- **`ElemActive(table, offset)`** — `table < |ctx.tables|` else `UnknownTable(table)`; the target
  table's reftype must **equal** `ref_ty` (`RefTypeMismatch`); `offset` is an **`i32`** constant
  expression (tables are `i32`-indexed, even alongside memory64).
- **`ElemPassive`** — no table, no offset; only the reftype + init-expr checks. Usable by
  `table.init` (reftype must match the target table there).
- **`ElemDeclarative`** — no table, no offset; its funcidxs join `C.refs` (§C.1) and it is otherwise
  inert (dropped at instantiation). Init exprs still type-check.

`ctx.elem_types` is `list.map(module.elements, fn(e) { e.ref_ty })` — used by `table.init`/`elem.drop`.

### I.2 Data segments (`data: List(DataSegment)`, each `mode`/`bytes`)

- **`DataActive(mem, offset)`** — `mem < |ctx.memories|` else `UnknownMemory(mem)`; `offset` is a
  constant expression of **that memory's index type** (`i32` for a 32-bit memory, **`i64`** for a
  64-bit one — the one place a data offset is not `i32`).
- **`DataPassive`** — no memory, no offset; only counts toward `data_count` and is usable by
  `memory.init`.

`ctx.data_count = |module.data|` (or the decoded data-count section — they must agree; P5-03).

Cite [`elem.wast`/`data.wast`](https://github.com/WebAssembly/spec/tree/main/test/core).

---

## J. Import/export typing — index spaces & non-function imports

Spec: [`valid/modules` — Imports/Exports](https://webassembly.github.io/spec/core/valid/modules.html).

### J.1 Index spaces are `imports ++ defined`

Build each space with **imports first**, in import order, then definitions:

```gleam
let imp_funcs   = // ImportFunc → types[type_idx]      (UnknownType if OOB)
let imp_globals = // ImportGlobal → #(ty, mutable)
let imp_tables  = // ImportTable → #(ty.ref_ty, ty.limits)
let imp_memories= // ImportMemory → ty.idx_type

func_types  = imp_funcs   ++ list.map(module.funcs,   fn(f){ types[f.type_idx] })
globals     = imp_globals ++ list.map(module.globals, fn(g){ #(g.ty, g.mutable) })
tables      = imp_tables  ++ list.map(module.tables,  fn(t){ #(t.ref_ty, t.limits) })
memories    = imp_memories++ list.map(module.memories,fn(m){ m.idx_type })
imported_func_count   = |imp_funcs|
imported_global_count = |imp_globals|   // and table/memory counts likewise
```

`imported_func_count` therefore becomes **real** (was hard-`0`). Every `call f` / `ref.func x` /
`table`/`memory`/`global` index now addresses the combined space; the existing `nth ctx.func_types f`
et al. already index correctly once the spaces are built imports-first. An imported function's
`type_idx` out of range → `UnknownType`.

Import **limits** are validated like defined ones (memory range per idx type, table range
`2^32−1`). An import whose `type_idx` (for a function) is out of range → `UnknownType`.

### J.2 Exports

Each `Export(name, kind, index)` must have `index` in range of the space its `kind` selects
(`ExportFunc → func_types`, `ExportTable → tables`, `ExportMemory → memories`,
`ExportGlobal → globals`); out of range → the matching `Unknown*` (or `UnknownImportKind` if no
better fit). The spec also forbids **duplicate export names**: all export names must be distinct
(spec `valid/modules`) → reject a duplicate with `UnknownImportKind("duplicate export")` or a
dedicated variant (choose one, document). Function exports feed `C.refs` (§C.1).

Cite [`imports.wast`/`linking.wast`/`exports.wast`](https://github.com/WebAssembly/spec/tree/main/test/core).

---

## K. Constant expressions extended

Spec: [`valid/instructions` — Constant Expressions](https://webassembly.github.io/spec/core/valid/instructions.html#constant-expressions).
A constant expression is a straight-line sequence terminating in `end`; Phase 5 permits a **single**
producing instruction from:

| const instr | produces | validity |
|---|---|---|
| `t.const c` | `t` | always. |
| `ref.null t` | reftype `t` | always. |
| `ref.func x` | `funcref` | `x` in funcidx range **and** `x ∈ C.refs`. |
| `global.get x` | `globals[x].0` | `x` refers to an **imported, immutable** global (else `NonConstantExpr`). |

Everything else (extended-const `i32.add`/…, a `global.get` of a *defined* or *mutable* global) →
`NonConstantExpr`. The produced type must equal `expected` (§I / global decl) — a mismatch is
`TypeMismatch` (numeric) or `RefTypeMismatch` (reference). Extend `validate_const_expr` to take
`ctx` (for `refs` and imported-global lookup):

```gleam
fn validate_const_expr(
  init: List(Instr), expected: ValType, ctx: Ctx,
) -> Result(Nil, ValidateError) {
  case init {
    [ast.I32Const(_)] -> expect_const_type(ast.I32, expected)
    [ast.I64Const(_)] -> expect_const_type(ast.I64, expected)
    [ast.F32Const(_)] -> expect_const_type(ast.F32, expected)
    [ast.F64Const(_)] -> expect_const_type(ast.F64, expected)
    [ast.RefNull(rt)] -> expect_const_type(ref_valtype(rt), expected)
    [ast.RefFunc(x)]  -> {
      use _ <- result.try(check_ref_declared(ctx, x))       // range + x ∈ refs
      expect_const_type(ast.FuncRef, expected)
    }
    [ast.GlobalGet(x)] -> const_global_get(ctx, x, expected) // imported & immutable only
    _ -> Error(NonConstantExpr)
  }
}
```

`const_global_get` is valid **only** for `x < imported_global_count` **and**
`globals[x].mutable == False` — else `NonConstantExpr` (a *defined* or *mutable* global in a const
expr is not constant). Apply `validate_const_expr` to: each global init (`expected` = the global's
type), each active element offset (`expected` = `i32`), each element init entry (`expected` =
the segment's reftype), each active data offset (`expected` = the target memory's index type §I.2).

---

## Effect / soundness / security note (H6)

- **Fail-closed is the whole point.** Every new instruction has an **explicit** typing arm; the
  `numeric_sig` fallthrough (`_ -> #([], [])`) must **not** silently accept a new op — every ref/
  table/bulk op is handled in `validate_instr` *before* the numeric fallthrough, so an unhandled
  opcode can only be an unreachable decode state. Keep `validate` **total**: never `panic`/
  `let assert`/diverge on any decodable AST (a decodable-but-ill-typed module is a typed `Error`).
- **The boundary is what makes the runtime traps sound.** Validate guarantees table/memory
  instructions carry in-range static indices and correctly-typed operands; the runtime then need only
  perform the **dynamic** bounds/null/type-mismatch checks (`TableOutOfBounds`, `MemoryOutOfBounds`,
  `UninitializedElement`, `IndirectCallTypeMismatch`) — a validated module can never reach the
  runtime with an out-of-range `memidx`/`tableidx`/`dataidx`/`elemidx` or a wrong-typed reference,
  so the worst case of a validator bug is a wrong/missing *validation* rejection, never a host
  escape.
- **`externref` opacity is preserved structurally:** the validator only ever *types* an `externref`
  (accept/reject); it never inspects a value, so it cannot leak or forge one.
- **Imports are fail-closed at link time, not here.** This unit types the *shape* of imports
  (their contribution to the index spaces); the *satisfaction* of an import (link-time
  fail-closed) is P5-09's instantiation contract. A module that imports a non-existent thing still
  type-checks against its declared import types — the link fails, not validation. Note this seam so
  the two units do not double-own it.

---

## Verification — Definition of Done (spec-cited tests)

Tests assert the **spec rule**, not the implementation (no change-detector tests). Cite the spec
section / `.wast` file each test encodes. Fixtures: valid `.wasm` via `wat2wasm --enable-all` (or the
Phase-5 WAT parser P5-10 once it lands); invalid-but-decodable via `wat2wasm --no-check` (decode
succeeds; only typing fails). Keep the Phase-1/2 suite green (regression).

**Acceptance (must be `Ok`, and carry correct `TypedModule` facts):**
- `ref.null func` / `ref.null extern` producing the right reftype; `ref.is_null` on each; `ref.func`
  of a **declared** function (declared via a declarative element or a function export).
- `select (result funcref)` (typed) of two funcrefs; untyped `select` of two i32s (still accepted).
- a `table.get`/`table.set` on a `funcref` table and on an `externref` table; `table.size`/
  `table.grow`/`table.fill` with the correct init reftype; a module with **two tables** of different
  reftypes routed by index.
- `memory.init`/`data.drop`/`memory.copy`/`memory.fill` on a 32-bit memory; `table.init`/`elem.drop`/
  `table.copy` with matching reftypes; a module with **two memories** using `memidx 1`.
- a **memory64** module: `i64.load`/`i64` `memory.size`/`memory.grow`; a `memory.copy` between a
  64-bit and a 32-bit memory (count typed `i32`); a 64-bit limit of `2^48` accepted, `2^48 + 1`
  rejected.
- a module importing a global/table/memory: the index spaces resolve imports-first; a `global.get`
  of an **imported immutable** global in a global init is accepted.

**Rejection (must be the cited `Error`):**
- `UndeclaredFunctionRef` — `ref.func x` where `x` is a valid funcidx but **not** in `C.refs`
  (`ref_func.wast` `assert_invalid`; spec ref.func rule). `UnknownFunc` — `ref.func` past the funcidx
  space.
- `BadSelectType` — untyped `select` of two `funcref`s (`select.wast`; parametric rule); `select t`
  with an annotation vector of length ≠ 1.
- `RefTypeMismatch` — `table.init`/`table.copy` across mismatched reftypes; an active element segment
  whose reftype ≠ its target table's; `call_indirect` through an `externref` table.
- `TypeMismatch` — `table.set` fed the wrong reftype; `ref.is_null` on an `i32`; a global init
  `ref.null extern` for a `funcref` global; a memory64 `i32.load` address on a 64-bit memory (wants
  `i64`).
- `UnknownData` — `memory.init`/`data.drop` dataidx past the data segments (`bulk.wast`).
  `UnknownElem` — `table.init`/`elem.drop` elemidx past the element segments.
- `UnknownMemory(memidx)` — a load/`memory.*`/bulk-memory op with `memidx` past the memories.
  `UnknownTable(tableidx)` — a `table.*`/`call_indirect` op with `tableidx` past the tables.
- `BadLimits` — a 64-bit memory limit `> 2^48`; a 32-bit memory `> 2^16`; a table `> 2^32−1`; any
  `min > max`.
- `NonConstantExpr` — a const expr using `global.get` of a **defined** or **mutable** global; an
  extended-const `i32.add` chain (still rejected, honest skip in the runner).
- start-function type ≠ `[] → []` still rejected (`valid/modules` start rule).

**Properties:**
- **AST-only:** grep the source to prove **no `twocore/ir` import** (gates independently of the
  backend).
- **Total:** never panics / `let assert`s / diverges on any decodable AST (fuzz the new instruction
  arms; a hostile ref/table/bulk stream produces a typed `Error`).
- **Conformance-neutral (H7):** a Phase-1..4 module (one 32-bit memory, funcref-only active
  elements, function-only imports, no bulk/ref ops) validates **identically** — assert a Phase-4
  fixture's `TypedModule` is unchanged shape (the new `TypedModule` fields are empty/`Idx32`/`[]`).
- `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test` green
  (≥ the current 906-derived count; the manager gates conformance `fail=0`).

**Prove the boundary end-to-end:** the conformance harness routes `assert_invalid` →
`check_frontend` (decode + validate). So the new negative corpora from
`ref_func`/`select`/`table_*`/`bulk`/`memory_init`/`memory_copy`/`memory_fill`/`elem`/`imports`/
`linking` flow here automatically; validate's rejection is what makes each `assert_invalid` pass.
Unit **P5-11** wires the allowlist; **this** unit's job is that the rejections are **spec-correct**
so those assertions go green (not silently skipped).

---

## What this unit leaves for others

- **P5-05 (lower)** consumes the extended `TypedModule` — reads `table_types`/`memory_idx_types`/
  `elem_types`/`refs`/the import counts, trusts all types are sound, and never re-validates. (`select`/
  `select_t` lower to `If`; load/table.get result types are read off the opcode / `table_types`.)
- **P5-06 (emit_core)** trusts the boundary: it emits ref/table/bulk calls with no type re-checks;
  the only runtime guards are the dynamic traps.
- **P5-09 (imports + spectest + linker)** owns the **link-time** import satisfaction (fail-closed
  unsatisfied import); this unit only types the import *shapes* into the index spaces — the two must
  not double-own the import contract.
- **P5-11 (conformance)** adds the Phase-5 `.wast` allowlist; document any `assert_invalid` this
  validator does *not* yet cover (SIMD, GC reftypes, extended-const) as an explicit, categorized
  skip.

---

## Open questions (for the planner / cross-unit sync)

1. **`ValidateError` granularity — `RefTypeMismatch`/`BadSelectType`/`UnknownData`/`UnknownElem`/
   `UndeclaredFunctionRef` vs. reusing `TypeMismatch`/`UnknownFunc`.** I add the five for
   diagnosability and because reference disagreements read differently from numeric ones. The
   conformance runner only needs *a* rejection, so reusing `TypeMismatch` everywhere would also pass.
   Recommend keeping the five; reconcile with whatever the manager wants the error vocabulary to be.
2. **`select_t` annotation arity.** The current core spec fixes the `select t` annotation vector at
   length 1. If P5-03 decodes it as a `List(ValType)`, a length ≠ 1 is `BadSelectType`. Confirm P5-03
   does not pre-collapse it to a single `ValType` (which would move this check into decode).
3. **The data-count section presence rule.** `memory.init`/`data.drop` require a data-count section;
   its *presence* is a decode structural rule (P5-03). This unit validates only `dataidx <
   data_count`. Confirm P5-03 rejects `memory.init`/`data.drop` with no data-count section at decode
   (else a module could reach validate with `data_count` un-derivable) — and confirm
   `Module.data_count: Option(Int)` is the seam.
4. **`TableInit` immediate order.** The binary encodes `table.init` immediates as *elemidx then
   tableidx* (`0xFC 12 e x`); I model `TableInit(elem, table)`. Confirm P5-03's field order/naming so
   the `case` binds the right index to the right space (a swap would silently validate the wrong
   bound — a real bug). Same care for `memory.init d m` (dataidx then memidx).
5. **Multi-memory / multi-table caps.** I **lift** `TooManyMemories`/`TooManyTables` (H3). If the
   manager wants a "single-memory profile" (a build flag rejecting >1), that reintroduces the caps
   behind a `Binding`/`Ctx` flag — but that is a linker/profile concern, not the default validator.
   Flagging so the removal is intentional and not read as a regression.
6. **memory64 (H8 deferrable half).** The typing here is spec-complete regardless of whether the
   runtime lands memory64. If memory64 is cut from Phase 5, keep the typing (it is conformance-
   neutral for 32-bit modules) but ensure P5-11 categorizes the `memory64.wast` files as a skip, not
   a fail. Confirm whether `IdxType`/`memory64_page_limit` should still ship in the frozen surface.
7. **`C.refs` exact membership.** I collect from element segments (all modes), global inits, and
   function exports, per the spec's `funcidx(module)` free-occurrence function; `start` is excluded.
   If the reconcile pass reads the spec appendix as also including some other position (e.g. a
   funcidx in a data segment — it does not), adjust — but this enumeration matches wabt/wasmtime.
8. **Duplicate-export-name rule.** The spec forbids duplicate export names. I fold it into export
   validation with a chosen error (`UnknownImportKind("duplicate export")` or a dedicated
   `DuplicateExport`). Confirm which; a dedicated variant is cleaner if the runner distinguishes it.
