# Unit P5-03 — WASM decode extension (+ «WASM-AST3»)

> **One owner. Wave A. Depends on nothing** upstream (extends the Phase-1/2
> `frontend/wasm/ast.gleam` + `decode.gleam`). **Publish the extended `ast.gleam`
> types as `«WASM-AST3»` on day 1** → unblocks **04 (validate)**, **05 (lower)**,
> and **10 (WAT text parser)**. Read [`00-overview.md`](00-overview.md) (H1–H8), the
> EM's provisional-surface note (IR3/WASM-AST3 shapes), and the Phase-2 decode doc
> [`phase-2/07-decode.md`](../phase-2/07-decode.md) first.

---

## Context

Phase-2's decoder (`src/twocore/frontend/wasm/decode.gleam`, `«WASM-AST2»`) handles
all of WASM 1.0 + sign-extension + the saturating `0xFC 0..7` trunc block: the
preamble, sections type(1)/table(4)/memory(5)/global(6)/function(3)/export(7)/
start(8)/element(9, active flag 0)/code(10)/data(11, forms 0x00/0x02), the full
load/store matrix, `memory.size`/`memory.grow`, the `0xA7..0xBF` conversion block,
and the float ops. It **skips** the import section (2) and **decode-rejects** every
reference-types / bulk-memory / multi-memory / memory64 construct with a typed
`DecodeError` (`select_t` → `UnknownOpcode(0x1C)`, `externref` → `BadRefType`,
element flags 1–7 → `BadElemKind`, data form 0x01 → `BadDataKind`, memory64 limits
flags 0x04/0x05 → `BadLimitsFlag`, a non-zero reserved mem-index byte →
`BadMemoryIndex`). The AST has no reference value types, no import declarations, no
passive/declarative/expression-form segments, and no reference/table/bulk
instructions.

Phase 5 completes the standardized binary surface (minus SIMD). This unit is the
**front door for that surface**: it un-skips section 2, adds the datacount section
(12), decodes every reference/table/bulk opcode with **precise, spec-verified byte
encodings**, threads a memory index through every memory op (multi-memory), reads
the memory64 index-type flag, and decodes the full element/data segment grammar
(flags 0–7 / 0–2). It publishes the AST it produces as **`«WASM-AST3»`**.

The threat model is unchanged (Phase-1 D4 / Phase-2): **the input is
attacker-controlled**. Every function stays total over arbitrary bytes — any
malformation returns a typed `DecodeError`, and **no `let assert`, `panic`, `todo`,
or partial match is reachable from input bytes**. This unit is purely *structural*:
it does **not** type-check, bounds-check indices, validate alignment, enforce
`min ≤ max`, or check the datacount against the data section — those are **04
(validate)**'s security-boundary job. Its contract is: bytes → the extended WASM
AST, faithfully and fail-closed.

## Goal

Decode the full Phase-5 binary surface into an extended `ast.Module`:

- the **reftype value types** (`0x70 funcref`, `0x6F externref`) wherever a valtype
  or reftype appears (globals, tables, typed `select`, `ref.null`, segments);
- the **reference instructions** `ref.null` (0xD0), `ref.is_null` (0xD1),
  `ref.func` (0xD2);
- **`table.get` (0x25)** / **`table.set` (0x26)**;
- the **`0xFC`-prefixed misc ops** `memory.init` (8), `data.drop` (9),
  `memory.copy` (10), `memory.fill` (11), `table.init` (12), `elem.drop` (13),
  `table.copy` (14), `table.grow` (15), `table.size` (16), `table.fill` (17);
- **typed `select`** (0x1C) with its `vec(valtype)`;
- the **multi-memory memarg** (bit-6 of the alignment flags → explicit memidx) and
  **> 1 memory** in the memory section; the memory index on `memory.size`/`grow`/
  `.init`/`.copy`/`.fill`;
- the **memory64 limits flags** (0x04/0x05, the index-type bit) → an `IdxType`, and
  the `u64` memarg offset width;
- the **new element-segment encodings** (flags 0–7: active/passive/declarative ×
  funcidx-vs-expr × explicit-tableidx) and **data-segment encodings** (flags 0/1/2:
  active-mem0 / passive / active-with-memidx), plus the **datacount section (12)**;
- **non-function imports** (importdesc func/table/mem/global, section 2) and the
  full **exportdesc** kinds.

Prove it by decoding real `wat2wasm` fixtures to an exact AST for each new
construct and by extending the fail-closed fuzz battery to the new surface (typed
errors, zero panics).

## Files owned

| File | Action |
|---|---|
| `src/twocore/frontend/wasm/ast.gleam` | **Extend** (single-owner). Reftype `ValType`s; `IdxType`; `Import`/`ImportDesc`; reworked `ElementSegment`/`ElemMode`/`ElemInit` and `DataSegment`/`DataMode`; `MemArg` + memidx; `MemType` + idx_type; `TableType` + reftype; the ref/table/bulk `Instr` constructors; `Module` gains `imports`/`data_count`; new `DecodeError` variants. **This is `«WASM-AST3»`, published day 1.** |
| `src/twocore/frontend/wasm/decode.gleam` | **Extend** (single-owner). Un-skip section 2; add section 12; the ref/table/bulk sub-decoders; multi-memory memarg; memory64 flag; the flag-0..7 element and flag-0/1/2 data grammar; section-ordering fix for datacount. |
| `test/twocore/frontend/wasm/decode_test.gleam` (+ embedded fixtures) | **Extend.** Worked-fixture AST assertions per construct + the fail-closed fuzz extension. |

**Day-1 publish (the freeze milestone `«WASM-AST3»`):** land the `ast.gleam` *type*
additions first as one compiling commit (the new/changed types with the constructor
arms filled in `decode.gleam` enough to compile — a stub is acceptable), announce
`«WASM-AST3»` in `state.md` with the full type delta listed, **then** implement the
decode bodies. Units 04/05/10 bind to the types, not the decode bodies.

## Deliverables & freeze milestones

1. **`«WASM-AST3»`** — the extended `ast.gleam` type surface (§A), day 1. The
   single milestone this unit *produces*; it is on the critical path for 04/05/10.
2. **`decode.gleam` bodies** — §§B–K decoded, fail-closed.
3. **Tests** — worked fixtures + fuzz (§Verification).

## Depends on

**Nothing upstream.** This unit extends the Phase-2 AST/decoder and touches neither
the IR (`ir.gleam`), the runtime, nor validate/lower. It can start immediately. The
only coupling is the **other direction**: publish `«WASM-AST3»` early. It does *not*
depend on the P5-01 keystone (`«IR3-FROZEN»`) — the WASM AST is the frontend's
private model, and lowering AST3 → IR3 is unit 05's seam. (Scope §A against the
provisional IR3 shapes so lower's job is mechanical, but do not import `ir.gleam`.)

## Scope — in / out for Phase 5

**In (decode to AST3):**
- Section 2 (import): all four importdescs (func/table/mem/global).
- Section 12 (datacount): the `u32` segment count, with the correct ordering rule.
- Reftype valtypes `0x70`/`0x6F` in every valtype/reftype position.
- `ref.null`/`ref.is_null`/`ref.func`; `table.get`/`table.set`; the ten `0xFC 8..17`
  bulk/table ops; typed `select` (0x1C).
- Multi-memory: the bit-6 memidx in memarg; the explicit memidx on
  `memory.size`/`grow`/`init`/`copy`/`fill`; `> 1` `MemType` in section 5.
- memory64: the `0x04`/`0x05` limits flags → `IdxType`; the `u64` memarg offset.
- Element flags 0–7; data flags 0/1/2.

**Out (defer; document, fail-closed):**
- **SIMD** (`v128 = 0x7B`, the `0xFD`-prefix ops) → Phase 6. `0x7B` in a valtype
  position → `BadValType`; `0xFD` → `UnknownOpcode(0xFD)`.
- **GC-proposal reftypes** — typed function references (`ref null ht` long forms,
  `0x63`/`0x64` heaptype encodings), `struct`/`array`/`i31`, `call_ref` → later. A
  reftype/heaptype byte other than `0x70`/`0x6F` → `BadRefType`.
- **Shared (threads) memories** — limits flags `0x02`/`0x03` → `BadLimitsFlag`.
- **`table64`** (i64-indexed tables, memory64's table half) — table limits stay
  `0x00`/`0x01`; a table limits flag with the index-type bit → `BadLimitsFlag`.
- **All semantic checks** — index ranges, `min ≤ max ≤ range`, `2^align ≤ N`,
  reftype ↔ table-elemtype agreement, const-expr typing, datacount ↔ data-section
  count, `≤ 1` memory unless multi-memory, funcidx range in `ref.func`/elements →
  **validate (unit 04)**. Decode parses structure faithfully; validate is the
  security boundary for semantics (matches the spec's decode-vs-validate layering
  and the conformance harness's `assert_invalid → validate` / `assert_malformed →
  decode` routing).

---

## A. `«WASM-AST3»` — the type surface (day-1 freeze)

Scope every new shape against the provisional IR3 (so lower is mechanical) but keep
the AST **WASM-shaped** (funcidx spaces, binary flags, raw bit patterns).

### A.1 Reference value types

Extend `ValType` with the two MVP reference types. In the binary format each is a
single byte in *the same encoding position as a number valtype*: `funcref = 0x70`,
`externref = 0x6F` (spec [binary/types.html#reference-types](https://webassembly.github.io/spec/core/binary/types.html#binary-reftype)).

```gleam
/// A WebAssembly value type. Phase 1/2: the four number types. Phase 5 adds the
/// two MVP reference types (`funcref`/`externref`); no `v128` (SIMD, Phase 6) and
/// no GC-proposal reftypes. Binary bytes: i32=0x7F i64=0x7E f32=0x7D f64=0x7C,
/// funcref=0x70, externref=0x6F.
pub type ValType {
  I32
  I64
  F32
  F64
  FuncRef
  ExternRef
}
```

There is **no separate `RefType` type** in the AST — a reftype is just the
`FuncRef`/`ExternRef` subset of `ValType`, validated positionally by `decode_reftype`
(§B). (The IR3 does introduce a distinct `RefType`; that split happens at lower, not
here — see Open questions Q1.) Rationale: reusing `ValType` means `decode_valtype`
serves globals, typed `select` vectors, and every other valtype site with one
decoder, and reftype-only positions call the stricter `decode_reftype`.

### A.2 The memory-index axis & memory64

```gleam
/// A memory's address width, from the limits' index-type flag bit (bit 2, 0x04).
/// `Idx32` = 32-bit (i32 addresses, MVP); `Idx64` = 64-bit (memory64). Default and
/// only value for a Phase-4 module is `Idx32`.
pub type IdxType {
  Idx32
  Idx64
}

/// A memory type: resizable limits (in 64KiB pages) + the address width.
/// `idx_type` is `Idx64` iff the limits flag set the index-type bit; validate owns
/// `min ≤ max ≤ range` (range = 2^16 pages for Idx32, 2^48 for Idx64).
pub type MemType {
  MemType(limits: Limits, idx_type: IdxType)
}
```

`Limits` is unchanged (`Limits(min: Int, max: Option(Int))`) — the index-type and
shared bits are consumed by the flag decoder, not stored on `Limits`.

### A.3 Tables carry a reftype

```gleam
/// A table type: its element reference type (`FuncRef`/`ExternRef`) + limits (in
/// entries). Pre-Phase-5 tables were always funcref; the field defaults to
/// `FuncRef` for a Phase-4 module. Tables stay i32-indexed (table64 out of scope).
pub type TableType {
  TableType(elem_type: ValType, limits: Limits)
}
```

`elem_type` is guaranteed a reftype by `decode_reftype`; validate checks table
element ↔ element-segment reftype agreement.

### A.4 The memarg gains a memory index

```gleam
/// A load/store memory immediate (`memarg`).
///  - `align`: the RAW log2 alignment exponent WITH the memidx flag bit (0x40)
///    already stripped. Non-semantic; kept for validate's `2^align ≤ N` check.
///  - `offset`: the static byte offset added to the dynamic address. Decoded as a
///    `u64` (the memory64 width); for an i32 memory validate enforces `< 2^32`.
///  - `mem`: the memory index (0 unless bit 6 of the alignment flags was set and an
///    explicit memidx followed). Default 0 → byte-identical to Phase 4.
pub type MemArg {
  MemArg(align: Int, offset: Int, mem: Int)
}
```

### A.5 Imports (section 2) & exports

```gleam
/// One import: the two-level name plus what is imported. (Binary: mod:name nm:name
/// importdesc — spec binary/modules.html#import-section.)
pub type Import {
  Import(module: String, name: String, desc: ImportDesc)
}

/// An import descriptor. `0x00 typeidx` func; `0x01 tabletype` table; `0x02 memtype`
/// mem; `0x03 valtype mut` global.
pub type ImportDesc {
  ImportFunc(type_idx: Int)
  ImportTable(TableType)
  ImportMemory(MemType)
  ImportGlobal(ty: ValType, mutable: Bool)
}
```

`Export`/`ExportKind` are **unchanged** — the four kind bytes `0x00`..`0x03`
already decode to `ExportFunc`/`ExportTable`/`ExportMemory`/`ExportGlobal` (the
exportdesc is already complete). What was missing was *resolution* of non-func
kinds, which is validate/lower/instantiate's job, not decode's.

### A.6 Element segments (flags 0–7)

The reference-types proposal generalizes the element grammar. Model the two axes
the binary distinguishes — **mode** (active/passive/declarative) and **init form**
(funcidx list vs const-expr list) — faithfully; lower unifies them into IR3's
`init: List(Expr)`.

```gleam
/// An element segment. `mode` is active (with a table index + offset expr), passive,
/// or declarative; `ref_ty` is the element reference type; `init` is either a
/// funcidx vector (flags 0–3, implicitly funcref) or a const-expr vector (flags 4–7).
pub type ElementSegment {
  ElementSegment(mode: ElemMode, ref_ty: ValType, init: ElemInit)
}

pub type ElemMode {
  ElemActive(table: Int, offset: List(Instr))
  ElemPassive
  ElemDeclarative
}

/// Element init: `ElemFuncs` = the funcidx vector (flags 0–3; each is a `ref.func`);
/// `ElemExprs` = a vector of const-expressions (flags 4–7; each ends at its own
/// depth-0 `End`, which is consumed not stored).
pub type ElemInit {
  ElemFuncs(List(Int))
  ElemExprs(List(List(Instr)))
}
```

### A.7 Data segments (flags 0/1/2) + datacount

```gleam
/// A data segment. `mode` is active (memory index + offset expr) or passive.
pub type DataSegment {
  DataSegment(mode: DataMode, bytes: BitArray)
}

pub type DataMode {
  DataActive(mem: Int, offset: List(Instr))
  DataPassive
}
```

### A.8 The `Module`

```gleam
pub type Module {
  Module(
    imported_func_count: Int,   // now COMPUTED = count of ImportFunc in `imports`
    types: List(FuncType),
    imports: List(Import),      // NEW (section 2)
    tables: List(TableType),
    memories: List(MemType),
    globals: List(Global),
    funcs: List(Func),
    start: Option(Int),
    elements: List(ElementSegment),
    data: List(DataSegment),
    data_count: Option(Int),    // NEW (section 12); validate checks it == length(data)
    exports: List(Export),
  )
}
```

`imported_func_count` stops being hard-wired to `0`: `assemble` sets it to the
number of `ImportFunc` importdescs. For a module with no import section this stays
`0` — **byte-identical to Phase 4** (H7). The imported table/memory/global counts
(needed for the tableidx/memidx/globalidx spaces) are derivable from `imports` by
validate/lower; decode does not pre-compute them (Open question Q2).

### A.9 New `Instr` constructors

```gleam
// --- reference instructions (0xD0..0xD2) ---
RefNull(ref_ty: ValType)   // 0xD0 <reftype byte 0x70|0x6F>
RefIsNull                  // 0xD1
RefFunc(func: Int)         // 0xD2 <funcidx u32>

// --- table access (0x25/0x26) ---
TableGet(table: Int)       // 0x25 <tableidx u32>
TableSet(table: Int)       // 0x26 <tableidx u32>

// --- typed select (0x1C) ---
SelectT(types: List(ValType))   // 0x1C <vec(valtype)>

// --- 0xFC bulk memory & table (sub-opcodes 8..17) ---
MemoryInit(data_idx: Int, mem: Int)         // 0xFC 8  <dataidx> <memidx>
DataDrop(data_idx: Int)                     // 0xFC 9  <dataidx>
MemoryCopy(dst_mem: Int, src_mem: Int)      // 0xFC 10 <memidx dst> <memidx src>
MemoryFill(mem: Int)                        // 0xFC 11 <memidx>
TableInit(table: Int, elem_idx: Int)        // 0xFC 12 <elemidx> <tableidx>
ElemDrop(elem_idx: Int)                     // 0xFC 13 <elemidx>
TableCopy(dst_table: Int, src_table: Int)   // 0xFC 14 <tableidx dst> <tableidx src>
TableGrow(table: Int)                       // 0xFC 15 <tableidx>
TableSize(table: Int)                       // 0xFC 16 <tableidx>
TableFill(table: Int)                       // 0xFC 17 <tableidx>
```

**Changed existing constructors** (memory index added — every construction/pattern
site in decode & tests updates; validate/lower are 04/05):

```gleam
MemorySize(mem: Int)   // 0x3F <memidx>   (was: MemorySize, nullary)
MemoryGrow(mem: Int)   // 0x40 <memidx>   (was: MemoryGrow, nullary)
```

Load/store constructors are unchanged in *shape* (they still carry one `MemArg`);
only `MemArg` grew a `mem` field, so their pattern sites are unaffected except where
they read the memarg fields.

### A.10 New `DecodeError` variants

```gleam
BadHeapType         // a ref.null / reftype byte is not 0x70/0x6F (e.g. a GC heaptype)
BadElemKind         // (kept) an element `elemkind` byte is not 0x00, or a flag > 7
BadDataKind         // (kept) a data-segment flag is not 0/1/2
BadImportKind       // an importdesc byte is not 0x00..0x03
BadMemArgFlags      // the memarg alignment flags set a reserved bit (not bit 6)
DataCountMismatch   // RESERVED for validate — kept out of decode (see §K); do NOT add
                    //   unless the reconcile pass moves the check into decode
```

`BadRefType` (element-type byte not a reftype), `BadLimitsFlag`, `BadMutability`,
`BadMemoryIndex` are **kept** but their *meaning tightens*: `BadLimitsFlag` now
fires only for genuinely unknown flags (shared `0x02`/`0x03`, table64, or `≥ 0x06`),
since `0x04`/`0x05` are now accepted for memories; `BadMemoryIndex` is no longer
raised for `memory.size`/`grow`/`init`/`copy`/`fill` (they now accept any memidx —
multi-memory), only where the encoding still reserves a fixed byte, if any. Prefer
**reusing** existing variants over adding new ones; every added variant must be
justified against a distinct malformation the tests exercise.

---

## B. Reftype bytes & the `decode_reftype` / `decode_valtype` split

`decode_valtype` (existing) gains two arms; a stricter `decode_reftype` guards
reftype-only positions.

| Byte | valtype | reftype-only |
|---|---|---|
| `0x7F 0x7E 0x7D 0x7C` | I32 I64 F32 F64 | → `BadHeapType` |
| `0x70` | FuncRef | FuncRef |
| `0x6F` | ExternRef | ExternRef |
| `0x7B` (v128) | `BadValType` | `BadHeapType` |
| other | `BadValType` | `BadHeapType` |

```gleam
/// Decode a reftype byte: 0x70 → FuncRef, 0x6F → ExternRef. Any other byte (a number
/// type, v128, a GC heaptype, EOF) is Error(BadHeapType)/Truncated. Used by ref.null,
/// element flag-5/6/7 reftypes, tabletype element types.
fn decode_reftype(bytes) -> Result(#(ValType, BitArray), ast.DecodeError)
```

`decode_valtype` adds `0x70 → FuncRef`, `0x6F → ExternRef`; all else `BadValType`
as before. Spec: [binary/types.html#reference-types](https://webassembly.github.io/spec/core/binary/types.html).

---

## C. Reference instructions — 0xD0 / 0xD1 / 0xD2

Verified against [binary/instructions.html#reference-instructions](https://webassembly.github.io/spec/core/binary/instructions.html).

| Opcode | Bytes | Immediates | `Instr` |
|---|---|---|---|
| `ref.null t` | `0xD0` reftype | one reftype byte (0x70/0x6F) | `RefNull(ref_ty)` |
| `ref.is_null` | `0xD1` | — | `RefIsNull` |
| `ref.func x` | `0xD2` funcidx | `u32` funcidx | `RefFunc(x)` |

`ref.null`'s operand is a **heaptype** in the general grammar; for Phase-5 scope it is
exactly a reftype byte, so `decode_reftype` decodes it (a GC heaptype → `BadHeapType`).
These are added to `decode_instr` (not `leaf_instr`, since two carry immediates). Note
`0xD0`/`0xD2` are the two immediate-bearing ones; `0xD1` could live in `leaf_instr`
but keep the three together in `decode_instr` for locality.

---

## D. `table.get` (0x25) / `table.set` (0x26)

| Opcode | Bytes | `Instr` |
|---|---|---|
| `table.get x` | `0x25` tableidx | `TableGet(x)` |
| `table.set x` | `0x26` tableidx | `TableSet(x)` |

Both take one `u32` tableidx. Add to `decode_instr` via the existing `idx_instr`
helper (`0x25 -> idx_instr(rest, ast.TableGet)`).

---

## E. The `0xFC` prefix family — bulk memory & table (sub-opcodes 8–17)

`0xFC` is **already** a prefix family in the decoder (`sat_instr` for sub 0–7). Extend
its dispatch: after reading the `u32` sub-opcode, sub 0–7 → `sat_instr` (unchanged),
sub 8–17 → the bulk decoder, anything else → `UnknownSatOpcode(sub)`.

**Verified encodings** (order matters — confirmed against the spec):

| Sub | Op | Bytes after `0xFC <sub>` | `Instr` |
|---|---|---|---|
| 8  | `memory.init x` | `dataidx:u32` then `memidx:u32` | `MemoryInit(data_idx, mem)` |
| 9  | `data.drop x`   | `dataidx:u32` | `DataDrop(data_idx)` |
| 10 | `memory.copy`   | `memidx:u32` (dst) then `memidx:u32` (src) | `MemoryCopy(dst_mem, src_mem)` |
| 11 | `memory.fill`   | `memidx:u32` | `MemoryFill(mem)` |
| 12 | `table.init x y`| **`elemidx:u32` then `tableidx:u32`** | `TableInit(table, elem_idx)` |
| 13 | `elem.drop x`   | `elemidx:u32` | `ElemDrop(elem_idx)` |
| 14 | `table.copy x y`| `tableidx:u32` (dst) then `tableidx:u32` (src) | `TableCopy(dst_table, src_table)` |
| 15 | `table.grow x`  | `tableidx:u32` | `TableGrow(table)` |
| 16 | `table.size x`  | `tableidx:u32` | `TableSize(table)` |
| 17 | `table.fill x`  | `tableidx:u32` | `TableFill(table)` |

**Two order pitfalls, both verified — do not swap:**
- **`table.init` reads elemidx FIRST, then tableidx** (mnemonic `table.init x y` =
  `table.init tableidx elemidx`; binary is `y:elemidx x:tableidx`). Store
  `table` = the tableidx, `elem_idx` = the elemidx.
- **`memory.init` reads dataidx FIRST, then memidx** (`x:dataidx m:memidx`).
- **`memory.copy`/`table.copy` read destination FIRST, then source.**

**Multi-memory note:** the trailing memidx bytes for `memory.init`/`copy`/`fill`
were a *reserved `0x00`* in MVP. Under multi-memory they are genuine `u32` memidxs —
decode them as `u32` and do **not** require `0x00`. (Pre-multi-memory this byte was
`0x00`, so single-memory fixtures still decode `mem: 0` byte-identically.)

Pseudocode:

```gleam
0xFC -> {
  use #(sub, r) <- result.try(decode_u_n(rest, 32))
  case sat_instr(sub) {
    Ok(instr) -> Ok(#(instr, r))          // sub 0..7 (unchanged)
    Error(Nil) -> decode_bulk(sub, r)     // sub 8..17, else UnknownSatOpcode
  }
}
```

---

## F. Typed `select` (0x1C)

| Opcode | Bytes | `Instr` |
|---|---|---|
| `select` (untyped) | `0x1B` | `Select` (unchanged) |
| `select t*` (typed) | `0x1C` `vec(valtype)` | `SelectT(types)` |

`0x1C` reads a `vec(valtype)` (each via `decode_valtype`, so reftypes are allowed).
The spec permits any vector length in the binary grammar but validation requires
exactly one result type — that length check is **validate's**, not decode's. Replace
the current `0x1C -> Error(ast.UnknownOpcode(0x1C))` arm.

Spec: [binary/instructions.html#parametric-instructions](https://webassembly.github.io/spec/core/binary/instructions.html).

---

## G. Multi-memory memarg + memory64 limits

### G.1 The memarg encoding (verified)

The memarg is `n:u32` (alignment flags) then, **iff bit 6 of `n` is set**, a
`memidx:u32`, then `o:u64` (offset):

```
memarg ::= n:u32 o:u64            (bit 6 of n clear)  ⇒ {align n,     offset o, mem 0}
         | n:u32 x:memidx o:u64   (bit 6 of n set)    ⇒ {align n−0x40, offset o, mem x}
```

- The real alignment exponent is `n` with **bit 6 (value `0x40`) cleared**.
- **Offset is a `u64`** (the memory64 width). Decode with `decode_u_n(_, 64)`. For an
  i32 memory validate enforces `offset < 2^32`. This does not change any Phase-4
  fixture's decoded value (offsets that fit u32 decode identically), so it is
  conformance-neutral.
- Bits other than 0–5 (alignment) and 6 (memidx flag) must be clear — bit 7+ set →
  `BadMemArgFlags` (a reserved-bit malformation). Practically, since `n` is a `u32`
  and alignment is at most ~3, any `n ≥ 0x80` with unexpected high bits is rejected;
  keep the check permissive (only reject if a genuinely reserved bit is set), and
  flag the exact mask in Open questions Q3.

```gleam
/// Decode a memarg: align flags (u32) → optional memidx (u32, iff bit 6 set) →
/// offset (u64). Returns MemArg{align (bit-6 stripped), offset, mem}.
fn decode_memarg(bytes) -> Result(#(MemArg, BitArray), ast.DecodeError)
```

`memarg_instr` calls `decode_memarg` and wraps with the load/store constructor. All
`0x28..0x3E` opcodes are unchanged except they now route through `decode_memarg`.

### G.2 `memory.size` / `memory.grow` — the memidx

`0x3F`/`0x40` were a single reserved `0x00` byte; under multi-memory they are a
`u32` memidx. Decode as `u32` → `MemorySize(mem)` / `MemoryGrow(mem)`. A
single-memory fixture encodes `0x00` here, so `mem == 0` — byte-identical.

### G.3 memory64 limits flags

`decode_limits` for **memories** must accept the index-type bit (spec / memory64
proposal, [binary/types.html#limits](https://webassembly.github.io/spec/core/binary/types.html)).
The flag byte is a bitfield: bit 0 (`0x01`) = has-max, bit 1 (`0x02`) = shared
(threads, out of scope), bit 2 (`0x04`) = i64 index type.

| Flag | max? | idx_type | in scope |
|---|---|---|---|
| `0x00` | no  | Idx32 | yes |
| `0x01` | yes | Idx32 | yes |
| `0x04` | no  | Idx64 | yes (memory64) |
| `0x05` | yes | Idx64 | yes (memory64) |
| `0x02`/`0x03` | — | — | **no** (shared) → `BadLimitsFlag` |
| ≥ `0x06` | — | — | **no** → `BadLimitsFlag` |

**Tables** keep the MVP limits decoder (`0x00`/`0x01` only) — a table limits flag
with the index-type or shared bit → `BadLimitsFlag` (table64 out of scope). Provide
two entry points: `decode_mem_limits` (returns `#(Limits, IdxType)`) for memories and
imported memories; `decode_limits` (returns `Limits`, i32-only) for tables and
imported tables.

---

## H. The import section (2) — non-function imports

Un-skip section 2 (route it in `dispatch_section` to `decode_vec(_, decode_import)`).
Add `imports` to `DecodeState`; `assemble` populates `Module.imports` and computes
`imported_func_count`.

```
import      ::= mod:name nm:name d:importdesc
importdesc  ::= 0x00 x:typeidx      ⇒ func x
              | 0x01 tt:tabletype   ⇒ table tt
              | 0x02 mt:memtype     ⇒ mem mt
              | 0x03 gt:globaltype  ⇒ global gt
globaltype  ::= t:valtype m:mut     (mut: 0x00 const, 0x01 var)
```

```gleam
fn decode_import(bytes) -> Result(#(Import, BitArray), ast.DecodeError) {
  use #(module, r1) <- result.try(decode_name(bytes))
  use #(name, r2) <- result.try(decode_name(r1))
  case r2 {
    <<kind:8, r3:bytes>> ->
      case kind {
        0x00 -> { use #(ti, r) <- ...; Ok(#(Import(.., ImportFunc(ti)), r)) }
        0x01 -> { use #(tt, r) <- decode_tabletype(r3); ... ImportTable(tt) }
        0x02 -> { use #(mt, r) <- decode_memtype(r3); ... ImportMemory(mt) }
        0x03 -> { valtype + mut; ... ImportGlobal(ty, mutable) }
        _ -> Error(ast.BadImportKind)
      }
    _ -> Error(ast.Truncated)
  }
}
```

Reuse `decode_tabletype` (now reftype-carrying), `decode_memtype` (now idx_type-
carrying), `decode_valtype`, and the existing mut-byte logic. Spec:
[binary/modules.html#import-section](https://webassembly.github.io/spec/core/binary/modules.html).

**`imported_func_count`:** `assemble` sets it to
`list.count(imports, is_import_func)`. This is the single behavioral seam that
changes for modules *with* an import section — but the Phase-4 corpus has none, so
it stays `0` and byte-identical. **Do not** hard-wire it any longer.

---

## I. `tabletype` / `memtype` / `global` — reftype & idx_type

`decode_tabletype` decodes a **reftype** element byte (`decode_reftype`, so
`externref` is now accepted) then i32 limits → `TableType(elem_type, limits)`. This
replaces the current `0x70`-only check (`externref` used to be `BadRefType`).

`decode_memtype` decodes `decode_mem_limits` → `MemType(limits, idx_type)`.

`decode_global` is unchanged except it reads the new `ValType` set (reftype globals
are now legal — e.g. an `externref` global). Its init const-expr may now contain
`ref.null`/`ref.func`/`global.get` (still decoded structurally; const-ness is
validate's).

---

## J. Element segments — flags 0–7

The element grammar (verified against [binary/modules.html#element-section](https://webassembly.github.io/spec/core/binary/modules.html)).
A leading `u32` flag; its bits mean: **bit 0** = passive-or-declarative (not
active-table-0); **bit 1** = (if bit0=0) explicit tableidx, (if bit0=1)
declarative-vs-passive; **bit 2** = expression init + explicit reftype (vs funcidx +
`elemkind`).

```
0 ⇒ 0:u32 e:expr            y*:vec(funcidx)   ⇒ active,  table 0, funcref, ElemFuncs y*
1 ⇒ 1:u32 et:elemkind       y*:vec(funcidx)   ⇒ passive,          elemkind, ElemFuncs y*
2 ⇒ 2:u32 x:tableidx e:expr et:elemkind y*:vec(funcidx) ⇒ active, table x, ElemFuncs y*
3 ⇒ 3:u32 et:elemkind       y*:vec(funcidx)   ⇒ declarative,      ElemFuncs y*
4 ⇒ 4:u32 e:expr            el*:vec(expr)      ⇒ active,  table 0, funcref, ElemExprs el*
5 ⇒ 5:u32 et:reftype        el*:vec(expr)      ⇒ passive,          reftype, ElemExprs el*
6 ⇒ 6:u32 x:tableidx e:expr et:reftype el*:vec(expr) ⇒ active, table x, ElemExprs el*
7 ⇒ 7:u32 et:reftype        el*:vec(expr)      ⇒ declarative,      ElemExprs el*
```

- `elemkind ::= 0x00` (funcref). Any other elemkind byte → `BadElemKind`.
- Flags 0/4 fix `table 0` and `ref_ty = FuncRef` (no tableidx/reftype byte on the
  wire).
- Flags 2/6 read the tableidx BEFORE the offset expr.
- `e:expr` (the offset) is a const-expr: `decode_const_expr` (existing).
- `el:expr` (each init) is a const-expr terminated by its own depth-0 `End`: decode a
  `vec` of const-exprs (`decode_vec(_, decode_const_expr)`). Each is typically
  `ref.func x End` or `ref.null t End`.
- A flag `> 7` → `BadElemKind`.

Result `ElementSegment(mode, ref_ty, init)`:
- mode: `ElemActive(table, offset)` / `ElemPassive` / `ElemDeclarative`;
- ref_ty: `FuncRef` for flags 0–4 & elemkind forms; the decoded reftype for 5/6/7;
- init: `ElemFuncs(y*)` for 0–3, `ElemExprs(el*)` for 4–7.

Replace `decode_elemseg` wholesale (it currently only handles flag 0).

---

## K. Data segments (flags 0/1/2) + the datacount section (12)

### K.1 Data grammar

```
0 ⇒ 0:u32 e:expr        b*:vec(byte)   ⇒ active, mem 0, offset e
1 ⇒ 1:u32               b*:vec(byte)   ⇒ passive
2 ⇒ 2:u32 x:memidx e:expr b*:vec(byte) ⇒ active, mem x, offset e
```

`decode_dataseg`: flag `0x00` → `DataActive(0, offset)`; `0x01` → `DataPassive`
(**new** — no offset, no memidx, just `vec(byte)`); `0x02` → `DataActive(memidx,
offset)` where **memidx may now be non-zero** (multi-memory — drop the old
`memidx == 0` requirement). Any other flag → `BadDataKind`. `vec(byte)` via the
existing `decode_vec_bytes`. Spec: [binary/modules.html#data-section](https://webassembly.github.io/spec/core/binary/modules.html).

### K.2 The datacount section (id 12) + the ordering fix

The bulk-memory proposal adds a **data count section**, id `12`, a single `u32`
giving the number of data segments. It is **required** if `memory.init`/`data.drop`
appear (so the validator knows the segment count before the code section, since data
comes after code). Store it as `Module.data_count: Option(Int)`; the check
`data_count == length(data)` is **validate's** (do not add `DataCountMismatch` to
decode unless reconcile decides otherwise — Open question Q4).

**Ordering — the sharp edge.** Section 12 appears in the binary **after element(9)
and before code(10)/data(11)** — it is *not* in ascending id order. The current
`decode_sections` enforces `id <= last_id → SectionOrder`, which would reject
`code(10)` after `datacount(12)`. Fix by ordering on a **canonical rank**, not the
raw id:

```gleam
/// The canonical position of a non-custom section for the ascending-order check.
/// The datacount section (12) sits between element (9) and code (10) per the spec.
fn section_rank(id: Int) -> Int {
  case id {
    12 -> 10   // datacount: after element(9), before code
    10 -> 11   // code
    11 -> 12   // data
    _ -> id    // 1..9 keep their id
  }
}
```

Track `last_rank` (not `last_id`); custom(0) stays exempt. This keeps
`type<import<...<element<datacount<code<data` strictly ascending and rejects a
misplaced datacount (e.g. after code) with `SectionOrder`. Route id 12 in
`dispatch_section` to `decode_u_n(contents, 32)` + `expect_empty` →
`data_count: Some(_)`.

---

## Effect / soundness / security note

- **Fail-closed over hostile bytes (D4/H6).** Every new sub-decoder returns a typed
  `DecodeError` on malformation; `decode.gleam` remains free of `let assert`,
  `panic`, `todo`, and non-exhaustive matches reachable from input. The
  `vec`/`vec_bytes` helpers already reject oversized counts by failing the slice
  match (`Truncated`), never over-reading — the new element-expr vectors and import
  vectors inherit this. A truncated LEB (memidx, sub-opcode, dataidx, offset u64,
  reftype byte) → `Truncated`/`LebTooLong`/`LebOverflow`, never a wrap.
- **Decode is not the security boundary; it is the parser.** It deliberately does
  *not* range-check indices, enforce `min ≤ max`, check reftype ↔ table agreement,
  reject a length-≠1 `select t*`, or verify `data_count`. Those are validate's
  (unit 04) — the spec's `assert_malformed` (decode) vs `assert_invalid` (validate)
  split. Decode's soundness obligation is **totality + faithful structure**: a
  well-formed binary decodes to the *exact* AST the spec's grammar prescribes, and
  every ill-formed binary is rejected without a crash.
- **Conformance-neutral defaults (H7).** A Phase-4 module — one i32 memory,
  funcref-only active (flag-0) elements, active (flag-0) data, no import section, no
  datacount, no ref/table/bulk ops, memidx 0 everywhere — decodes to a
  *structurally identical* AST3: `MemArg.mem == 0`, `MemType.idx_type == Idx32`,
  `TableType.elem_type == FuncRef`, `ElemMode == ElemActive(0, _)` with
  `ElemFuncs`, `DataMode == DataActive(0, _)`, `imports == []`,
  `imported_func_count == 0`, `data_count == None`. Lower must then re-emit
  byte-identical IR/`.core` (the H7 obligation is discharged jointly with 05/06; the
  AST-level neutrality is this unit's part).
- **No new authority.** Decoding non-function imports records *declarations* only —
  it grants nothing. The link/instantiation contract (unit 09) decides what a
  declared import resolves to; an unsatisfied import fails closed there, not here.

---

## Verification — Definition of Done (D8)

**Spec behavior, not change-detector.** Drive decode from `wat2wasm`-produced
binaries (embed the `.wasm` bytes as `BitArray` literals so tests need no external
tool at run time) and assert the AST against the **binary-format spec** (cite the
exact section per fixture). Never assert "whatever decode emits."

### 1. Worked fixtures (exact AST), at least one per new construct

- **reftype global + externref:** `(global externref (ref.null extern))` →
  `globals == [Global(ty: ExternRef, mutable: False, init: [RefNull(ExternRef)])]`;
  `(global funcref (ref.func $f))` → `init: [RefFunc(<idx>)]`.
- **typed table + table.get/set:** `(table 1 externref)` →
  `tables == [TableType(elem_type: ExternRef, limits: Limits(1, None))]`; a body with
  `table.get 0` / `table.set 0` → `TableGet(0)` / `TableSet(0)`.
- **ref instructions:** a function using `ref.null func`, `ref.is_null`,
  `ref.func $f` → `[RefNull(FuncRef), RefIsNull, ...]` and `RefFunc(<idx>)`.
- **typed select:** `select (result i32)` → `SelectT([I32])`; assert the untyped
  `0x1B` still decodes to `Select`.
- **each 0xFC bulk op** (the ORDER assertions are the point):
  - `memory.init 0` → `MemoryInit(data_idx: 0, mem: 0)`;
  - `data.drop 0` → `DataDrop(0)`;
  - `memory.copy` → `MemoryCopy(dst_mem: 0, src_mem: 0)`;
  - `memory.fill` → `MemoryFill(0)`;
  - `table.init 1 0` (table 1, elem 0) → `TableInit(table: 1, elem_idx: 0)` —
    proving the **elemidx-then-tableidx** decode order;
  - `elem.drop 0` → `ElemDrop(0)`;
  - `table.copy 0 1` → `TableCopy(dst_table: 0, src_table: 1)` — proving
    **dst-before-src**;
  - `table.grow`/`table.size`/`table.fill 0` → the three tableidx forms.
- **multi-memory:** a module with two memories and a `(i32.store (memory 1) ...)` →
  `memories` length 2, and the store's `MemArg.mem == 1` (proves the bit-6 memidx);
  a single-memory store → `MemArg.mem == 0` (neutrality).
- **memory64:** `(memory i64 1)` → `memories == [MemType(Limits(1, None), Idx64)]`;
  assert an i32 memory decodes `Idx32`. *(If memory64 is cut per H8, keep the
  limits-flag decode + this fixture; the runtime half is 08's.)*
- **element flags:** one fixture each for a **passive funcidx** segment (flag 1) →
  `ElementSegment(ElemPassive, FuncRef, ElemFuncs([...]))`; a **declarative** (flag
  3); an **active expr** (flag 4) → `ElemExprs([[RefFunc(_)], ...])`; a **passive
  externref expr** (flag 5) → `ref_ty: ExternRef`, `ElemExprs([[RefNull(ExternRef)]])`;
  an **active-with-tableidx expr** (flag 6). Keep an active flag-0 fixture asserting
  the neutral shape.
- **data flags + datacount:** a **passive data** segment (flag 1) →
  `DataMode == DataPassive`; an **active-with-memidx** (flag 2, memidx 0) →
  `DataActive(0, _)`; a module with a **datacount section** → `data_count == Some(n)`
  with `n == length(data)`; assert the datacount-before-code ordering *accepts*.
- **non-function imports:** `(import "m" "g" (global i32))` / `(table 1 funcref)` /
  `(memory 1)` / `(func (type 0))` → the four `ImportDesc`s in `Module.imports`, and
  `imported_func_count` equal to the number of func imports (e.g. 1 func import + 1
  global import → `imported_func_count == 1`, `length(imports) == 2`).

### 2. Fail-closed fuzz on the NEW surface (extend the Phase-1/2 battery)

Each must return a **specific `DecodeError`**, never a panic/`let assert`/loop:
- `ref.null` with a bad heaptype byte → `BadHeapType`;
- a `0xFC` sub-opcode of `18`+ → `UnknownSatOpcode(18)`;
- a truncated `memory.init` (dataidx present, memidx EOF) → `Truncated`;
- a memarg with the memidx flag (bit 6) set but the memidx LEB truncated →
  `Truncated`;
- an element flag `8` → `BadElemKind`; an elemkind byte `0x01` → `BadElemKind`;
- a data flag `3` → `BadDataKind`;
- an importdesc kind byte `0x04` → `BadImportKind`;
- a memory limits flag `0x02` (shared) → `BadLimitsFlag`; a **table** limits flag
  `0x04` → `BadLimitsFlag` (table64 out of scope);
- a `select t*` vector count that over-runs the section → `Truncated`;
- a datacount section placed **after** the code section → `SectionOrder`.
- The **single-byte-mutation + truncation sweep** over every new fixture must always
  yield `Ok(_) | Error(DecodeError)` — the property is *totality*.
- Assert (grep in a test or by inspection) that `decode.gleam` contains no
  `let assert`, `panic`, or `todo`.

### 3. Neutrality

The full Phase-1..4 decode fixture suite still decodes to the **same** (up to the
mechanical field additions — `MemArg.mem: 0`, `MemType.idx_type: Idx32`,
`TableType.elem_type: FuncRef`, the new `ElemMode`/`DataMode`/`ElemInit` wrappers)
AST. `gleam test` stays green (≥ the current count + the new tests). Embedded
conformance numbers do not regress (04/05 gate the new fixtures' use downstream).

### 4. Clean build & docs

`gleam format --check src test` clean; `gleam build` **zero warnings** (no leftover
`todo`/unused). Every new/changed public type, constructor, and function has a `///`
doc comment stating its contract, immediate order, accepted byte ranges, and failure
modes (D8).

### 5. `«WASM-AST3»` announced

In `state.md` the moment the types compile (day 1), listing the changed `Module`
fields, the reftype `ValType`s, the `Import`/`ImportDesc`/`ElementSegment`/
`DataSegment`/`MemType`/`TableType`/`MemArg` shape changes, the new `Instr`
constructors, and the new `DecodeError` variants — for 04/05/10.

**Spec citations to use in tests:** binary/types.html (reftype bytes, limits flags,
globaltype, tabletype/memtype), binary/instructions.html (ref/table/select ops, the
`0xFC` bulk family + immediate order, memarg bit-6 memidx + u64 offset),
binary/modules.html (import section, element flags 0–7, data flags 0/1/2, the
datacount section id 12 & ordering), and the reference-types & bulk-memory proposal
overviews (now folded into the WASM 2.0 living standard) for the finalized grammar.

## What this unit leaves for others

- **04 (validate)** consumes `«WASM-AST3»`: it owns reftype typing
  (`funcref`/`externref` + null), table element ↔ element-segment reftype agreement,
  `select t*` length-1, the bulk/table op typings, multi-memory memidx range,
  memory64 `i64` address typing, `2^align ≤ N`, `min ≤ max ≤ range` per idx_type, the
  `data_count == length(data)` check, and non-function import/export typing. It
  rejects ill-typed modules fail-closed (the security boundary).
- **05 (lower)** maps AST3 → IR3: the ref/table/bulk `Instr`s → the H2/H3 `Expr`
  nodes; `ElemFuncs`/`ElemExprs` → IR `ElementSegment.init: List(Expr)`; `ElemMode`/
  `DataMode` → the IR modes; `MemArg.mem` / `MemorySize.mem` → the IR memory index;
  `MemType.idx_type` → the IR address width; `imports` + `imported_func_count` → the
  IR import declarations and the funcidx/tableidx/memidx/globalidx offsets;
  `data_count` informs the passive-segment table.
- **10 (WAT text parser)** targets the same `«WASM-AST3»` `Module`, so `wat_parse`
  and `decode` produce the same AST for validate/lower to serve unchanged.
- **11 (conformance)** sources the newly-decodable `.wast` allowlist (reftype,
  ref_null, ref_func, ref_is_null, table_*, elem, select, bulk, memory_fill/copy/init,
  table_init/copy, the multi-memory & memory64 files, the spectest-importing files).

## Open questions (for the planner / cross-unit sync)

- **Q1 — `RefType` vs `ValType` in the AST.** The provisional IR3 introduces a
  distinct `RefType { FuncRef ExternRef }`; this doc keeps reftypes as the
  `FuncRef`/`ExternRef` subset of the *AST's* `ValType` (one decoder for every
  valtype position; a positional `decode_reftype` guards reftype-only sites).
  **Objection/alternative if reconcile prefers symmetry:** add a WASM-AST `RefType`
  and make `TableType.elem_type`/`ElementSegment.ref_ty`/`RefNull.ref_ty` carry it.
  I recommend keeping the subset form in the AST (it is closer to the binary, where a
  reftype *is* a valtype byte) and letting **lower** perform the `ValType → RefType`
  narrowing into IR3. Flag for P5-01/P5-05.
- **Q2 — imported index-space counts.** I compute only `imported_func_count` in the
  AST (back-compat with validate). The imported table/memory/global counts (needed
  for the tableidx/memidx/globalidx spaces once non-function imports exist) are left
  derivable from `imports` by validate/lower. If 04/05 would rather the AST expose
  `imported_table_count`/`imported_mem_count`/`imported_global_count` precomputed,
  that is a cheap `assemble` addition — decide in reconcile.
- **Q3 — memarg reserved-bit strictness.** The spec constrains the alignment flags to
  bits 0–5 (alignment) + bit 6 (memidx flag). How strict should decode be about a
  *huge* alignment value or a set bit ≥ 7? I propose accepting any `align` (validate
  enforces `2^align ≤ N`) but reserving `BadMemArgFlags` only if a *non-alignment,
  non-flag* bit is set in a way the spec forbids. If the spec/tests show
  `assert_malformed` cases here, tighten. Flag for P5-04.
- **Q4 — where the `data_count == length(data)` check lives.** I place it in validate
  (decode only records `data_count`). The spec frames the datacount mismatch as a
  *malformed* (decode-time) error in some readings and an *invalid* (validate-time)
  one in others. If reconcile rules it decode-time, add `DataCountMismatch` and check
  it in `assemble`; otherwise it stays validate's. Flag for P5-04.
- **Q5 — `imported_func_count` behavior change.** Un-skipping section 2 changes
  `imported_func_count` from a hard `0` to a computed count. This is
  conformance-neutral for the current corpus (no import sections) but is a genuine
  seam with validate/lower's funcidx resolution. Confirm 04/05 already apply the
  `imported_func_count` offset (they document that they do) so the flip is safe.
- **Q6 — memory64 offset width & the H8 cut.** I decode the memarg offset as `u64`
  unconditionally (harmless for i32 memories, required for i64). If memory64 is cut
  from Phase 5 (§H8), keep the `u64` offset decode and the `idx_type` flag decode
  anyway (they are cheap and conformance-neutral); only the runtime/validate halves
  need deferring. Confirm with P5-08.
