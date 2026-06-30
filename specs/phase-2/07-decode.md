# Unit 07 — decode extension + WASM-AST2 (the full opcode/section set)

> **One owner. Wave A. Depends on nothing** (extends the Phase-1 `ast.gleam` /
> `decode.gleam`). **Publish the extended `ast.gleam` types as `«WASM-AST2»` on
> day 1** → unblocks **08 (validate)** and **09 (lower)**. Read
> [`00-overview.md`](00-overview.md) (E1–E8) and [`phase-1/00-overview.md`](../phase-1/00-overview.md)
> (D1–D10) first.

---

## Context

Phase-1's decoder (`src/twocore/frontend/wasm/decode.gleam`) handles only the
preamble + type(1)/function(3)/export(7)/code(10) sections and the integer/control
opcode slice. It **skips** table(4)/memory(5)/global(6)/start(8)/element(9)/data(11)
by discarding their bytes (`dispatch_section`, decode.gleam:280–283) and **rejects**
every memory, float, and conversion opcode as `UnknownOpcode`. The AST (`ast.gleam`,
`«WASM-AST»`) has no table/memory/global/element/data/start declarations and no
memory/float/conversion instructions.

Phase 2 needs all of WASM 1.0 decoded. This unit closes the decode gap. It is the
**front door for untrusted binaries** — the same threat model as Phase-1's decoder
(D4/D5): every malformation returns a typed `DecodeError`; **no `let assert`,
`panic`, `todo`, or partial match is reachable from input bytes.**

This unit is purely structural. It does **not** type-check, validate alignment,
bounds-check segments, or lower anything — those belong to 08 (validate) and 09
(lower). Its job is: bytes → the extended WASM AST, faithfully and fail-closed.

## Goal

Decode every WASM 1.0 section and opcode Phase-1 skipped into an extended
`ast.Module`: the table/memory/global/start/element/data sections, the full
load/store matrix, `memory.size`/`memory.grow`, `global.get`/`global.set` (already
present), the complete `0xA7–0xBF` conversion block (int **and** float), and the
float arithmetic/unary/comparison opcodes. Keep `select` (0x1B); decode-reject
`select_t` (0x1C). Prove it by decoding real `wat2wasm` fixtures to an exact AST
and by fuzzing the new surface to typed errors with zero panics.

## Files owned

| File | Action |
|---|---|
| `src/twocore/frontend/wasm/ast.gleam` | **Extend** (single-owner). New `Module` fields + section types + ~70 new `Instr` constructors + new `DecodeError` variants. **This is `«WASM-AST2»`, published day 1.** |
| `src/twocore/frontend/wasm/decode.gleam` | **Extend** (single-owner). Un-skip sections 4/5/6/8/9/11; decode the new opcodes; new leaf/section sub-decoders. |
| `test/twocore/frontend/wasm/decode_test.gleam` (+ fixtures) | **Extend.** Worked-fixture AST assertions + fail-closed fuzz over the new surface. |

**Day-1 publish:** commit the `ast.gleam` *type* additions first (a compiling stub —
the new `Module` fields and `Instr`/`DecodeError` variants), announce `«WASM-AST2»`
in `state.md`, **then** implement `decode.gleam`. 08/09 bind to the types, not the
decode bodies.

## Depends on

**Nothing upstream.** This unit extends the Phase-1 AST and is independent of the
IR2 freeze and the cell ABI (it never touches the IR or the runtime). It can start
immediately. The only coupling is the **other direction**: it must publish
`«WASM-AST2»` early so 08 and 09 unblock.

## Scope — in / out for Phase 2

**In (decode to AST):**
- Sections: table(4), memory(5), global(6), start(8), element(9, active flag 0),
  data(11, active forms 0x00/0x02).
- Opcodes: load/store matrix `0x28–0x3E` (with `memarg`), `memory.size`(0x3F),
  `memory.grow`(0x40), the `0xA7–0xBF` conversion block, float compares
  `0x5B–0x66`, float numeric `0x8B–0xA6`. Keep `select`(0x1B).
- Const-expr decode for global init + element/data offset (structural; the const
  restriction is **validate's** — see below).

**Out (defer; document, fail-closed):**
- **Non-function imports** — section 2 (import) **stays skipped** (E7). Imported
  memory/table/global → Phase 3. `imported_func_count` keeps its offset model
  (stays 0; consumers must still apply it — see Grounded facts).
- **`select_t`** (0x1C), **externref** (0x6F), reftype/GC/SIMD/multi-memory opcodes,
  table.get/set/copy/fill, `ref.null`/`ref.func` → reference types/GC, Phase 3.
- **Passive/declarative element** (flags 1–7) and **passive data** (form 0x01),
  `data.drop`, `memory.init/copy/fill` → bulk memory, Phase 3.
- **Multi-memory / memory64** memarg encodings (offset u64, align bit-6 memidx) →
  Phase 3. Decode strictly to the MVP two-`u32` `memarg`.
- **Semantic checks** — `min ≤ max ≤ 65536` limits, `2^align ≤ N`, const-expr
  typing/immutability, ≤1 table/memory, funcidx range → **validate (unit 08)**.
  Decode parses structure faithfully; validate is the security boundary for
  semantics (matches the spec's decode-vs-validate layering and the conformance
  harness's `assert_invalid → validate` routing).

## Deliverables

### 1. `ast.gleam` — `«WASM-AST2»` types

Add `import gleam/option.{type Option}`. New section types:

```gleam
/// Resizable-limits (memory & table). `max = None` is the open-ended form.
/// Units: memory = 64KiB pages, table = entries. The spec bound
/// (`min <= max <= range`) is checked by validate (unit 08), not here.
pub type Limits { Limits(min: Int, max: Option(Int)) }

/// A table type. MVP element type is always `funcref` (0x70) — externref is
/// rejected at decode (`BadRefType`), so no reftype field is needed yet.
pub type TableType { TableType(limits: Limits) }

/// A memory type (just its limits, in 64KiB pages).
pub type MemType { MemType(limits: Limits) }

/// A global declaration. `mutable` is the `mut` byte (False=const, True=var).
/// `init` is the decoded constant-expression instruction list (the terminating
/// `End` is consumed, not stored). Validate enforces it is a real const-expr.
pub type Global { Global(ty: ValType, mutable: Bool, init: List(Instr)) }

/// An ACTIVE element segment (binary flag 0): table 0, a constant `offset`
/// expression, and `funcs` = the funcidx vector to write. `offset` excludes
/// its terminating `End`. Passive/declarative forms are decode-rejected.
pub type ElementSegment { ElementSegment(table: Int, offset: List(Instr), funcs: List(Int)) }

/// An ACTIVE data segment (binary forms 0x00 → mem 0, 0x02 → explicit memidx).
/// `offset` is the constant offset expr (no trailing `End`); `bytes` is the raw
/// payload. Passive form 0x01 is decode-rejected (bulk memory, Phase 3).
pub type DataSegment { DataSegment(mem: Int, offset: List(Instr), bytes: BitArray) }
```

Extend `Module` (labeled fields — every construction/pattern site updates; the
decoder's `assemble` and the tests are yours, 08/09 update theirs):

```gleam
pub type Module {
  Module(
    imported_func_count: Int,
    types: List(FuncType),
    tables: List(TableType),     // NEW (section 4)
    memories: List(MemType),     // NEW (section 5)
    globals: List(Global),       // NEW (section 6)
    funcs: List(Func),
    start: Option(Int),          // NEW (section 8: a funcidx)
    elements: List(ElementSegment), // NEW (section 9)
    data: List(DataSegment),     // NEW (section 11)
    exports: List(Export),
  )
}
```

A `memarg` immediate on every load/store:

```gleam
/// A load/store memory immediate. `align` is the RAW log2 alignment exponent
/// (actual alignment = 2^align) — kept for validate's `2^align <= N` check, then
/// discarded (non-semantic). `offset` is the static byte offset added to the
/// dynamic address. Both are decoded as `u32` LEB128.
pub type MemArg { MemArg(align: Int, offset: Int) }
```

New `Instr` constructors (one per opcode, mirroring the existing style):

```gleam
// memory load/store 0x28..0x3E — each carries a MemArg
I32Load(MemArg)  I64Load(MemArg)  F32Load(MemArg)  F64Load(MemArg)
I32Load8S(MemArg)  I32Load8U(MemArg)  I32Load16S(MemArg)  I32Load16U(MemArg)
I64Load8S(MemArg)  I64Load8U(MemArg)  I64Load16S(MemArg)  I64Load16U(MemArg)
I64Load32S(MemArg)  I64Load32U(MemArg)
I32Store(MemArg)  I64Store(MemArg)  F32Store(MemArg)  F64Store(MemArg)
I32Store8(MemArg)  I32Store16(MemArg)  I64Store8(MemArg)  I64Store16(MemArg)  I64Store32(MemArg)
MemorySize  // 0x3F 0x00
MemoryGrow  // 0x40 0x00
// float comparisons 0x5B..0x66
F32Eq F32Ne F32Lt F32Gt F32Le F32Ge   F64Eq F64Ne F64Lt F64Gt F64Le F64Ge
// f32 numeric 0x8B..0x98 / f64 numeric 0x99..0xA6
F32Abs F32Neg F32Ceil F32Floor F32Trunc F32Nearest F32Sqrt F32Add F32Sub F32Mul F32Div F32Min F32Max F32Copysign
F64Abs F64Neg F64Ceil F64Floor F64Trunc F64Nearest F64Sqrt F64Add F64Sub F64Mul F64Div F64Min F64Max F64Copysign
// conversion block 0xA7..0xBF (int + float, do NOT split)
I32WrapI64
I32TruncF32S I32TruncF32U I32TruncF64S I32TruncF64U     // trapping (distinct from the Sat block)
I64ExtendI32S I64ExtendI32U
I64TruncF32S I64TruncF32U I64TruncF64S I64TruncF64U      // trapping
F32ConvertI32S F32ConvertI32U F32ConvertI64S F32ConvertI64U F32DemoteF64
F64ConvertI32S F64ConvertI32U F64ConvertI64S F64ConvertI64U F64PromoteF32
I32ReinterpretF32 I64ReinterpretF64 F32ReinterpretI32 F64ReinterpretI64
```

> `I32TruncF32S` (0xA8) is the **trapping** truncation — keep it distinct from the
> already-present **saturating** `I32TruncSatF32S` (0xFC 0). `F32Const`/`F64Const`
> already exist; do not re-add.

New `DecodeError` variants (extend the existing enum; `rt_trap`/validate map later):

```gleam
BadRefType        // table element type byte is not funcref (0x70)
BadLimitsFlag     // limits flag byte is not 0x00/0x01 (e.g. memory64 0x04/0x05)
BadMutability     // global mut byte is not 0x00/0x01
BadElemKind       // element segment flag is not 0 (passive/declarative/expr-list — Phase 3)
BadDataKind       // data segment flag is not 0x00/0x02 (passive 0x01 — Phase 3)
BadMemoryIndex    // a reserved memory-index byte (memory.size/grow, data 0x02) is non-zero
```

### 2. `decode.gleam` — un-skip the sections, decode the opcodes

- **`DecodeState`** gains tables/memories/globals/start/elements/data fields;
  `assemble` populates the new `Module` fields (`imported_func_count` stays 0).
- **`dispatch_section`**: route 4/5/6/9/11 to `decode_vec(<sub-decoder>)` and 8 to
  one `u32` funcidx → `start = Some(_)`, each followed by `expect_empty`
  (→ `SectionSizeMismatch`). Keep **2 (import)** in the skip arm.
- **`decode_limits`**: `0x00`→`Limits(min, None)`, `0x01`→`Limits(min, Some(max))`,
  else `BadLimitsFlag` (min/max are `u32`). **`decode_tabletype`**: reftype byte
  `0x70` (else `BadRefType`) then limits. **`decode_memtype`**: limits.
  **`decode_global`**: valtype, mut byte `0x00`→False/`0x01`→True (else
  `BadMutability`), then `decode_const_expr`.
- **`decode_const_expr`**: an instruction sequence terminated by a depth-0 `End`
  (0x0B), block-nesting tracked **exactly like `decode_expr`**; returns the instrs
  **before** that `End`. Structural only — it does **not** reject non-const opcodes
  (validate owns the const-expr restriction). Stays total.
- **`decode_elemseg`**: flag `0` → const-expr offset + `vec(u32 funcidx)` →
  `ElementSegment(table: 0, …)`; else `BadElemKind`. **`decode_dataseg`**: `0x00`
  → offset + `vec(byte)` (mem 0); `0x02` → `u32 memidx` (require 0, else
  `BadMemoryIndex`) + offset + `vec(byte)`; else `BadDataKind`. `vec(byte)` =
  `u32 count` then `count` raw bytes → `BitArray`.
- **`decode_instr`**: `0x28..0x3E` → read `MemArg` (`align:u32` then `offset:u32`)
  → matching constructor; `0x3F`/`0x40` → next byte must be `0x00` (else
  `BadMemoryIndex`/`Truncated`) → `MemorySize`/`MemoryGrow` (**not** a memarg);
  `0x1C` (`select_t`) → `UnknownOpcode(0x1C)` (deferred).
- **`leaf_instr`** (no-immediate): add `0x5B..0x66`, `0x8B..0xA6`, `0xA7..0xBF`,
  one arm per opcode → the matching constructor.

## Grounded facts you MUST honor

*(Transcribed from the verified research, topics 1 & 2; cite these spec URLs in
tests.)*

**Section ids** (must be strictly ascending; loop already enforces it):
`type=1, import=2, function=3, table=4, memory=5, global=6, export=7, start=8,
element=9, code=10, data=11`. (binary/modules.html)

**Limits** (binary/types.html): flag `0x00` → `{min:u32}` (no max); flag `0x01` →
`{min:u32, max:u32}`, both LEB128. `0x04/0x05` are memory64 i64-indexed forms →
reject. **funcref = 0x70**, externref = 0x6F (reject). **global mut byte:**
`0x00`=const(immutable), `0x01`=var(mutable).

**Load/store opcodes — each immediately followed by `memarg = align:u32 offset:u32`**
(binary/instructions.html):

```
0x28 i32.load     0x29 i64.load     0x2A f32.load     0x2B f64.load
0x2C i32.load8_s  0x2D i32.load8_u  0x2E i32.load16_s 0x2F i32.load16_u
0x30 i64.load8_s  0x31 i64.load8_u  0x32 i64.load16_s 0x33 i64.load16_u
0x34 i64.load32_s 0x35 i64.load32_u
0x36 i32.store    0x37 i64.store    0x38 f32.store    0x39 f64.store
0x3A i32.store8   0x3B i32.store16  0x3C i64.store8   0x3D i64.store16  0x3E i64.store32
0x3F memory.size  0x40 memory.grow            <-- each followed by ONE 0x00 byte, NOT a memarg
```

**Conversion block `0xA7–0xBF` (int + float interleaved — DO NOT read as float-only):**

```
0xA7 i32.wrap_i64        0xA8 i32.trunc_f32_s   0xA9 i32.trunc_f32_u
0xAA i32.trunc_f64_s     0xAB i32.trunc_f64_u   0xAC i64.extend_i32_s
0xAD i64.extend_i32_u    0xAE i64.trunc_f32_s   0xAF i64.trunc_f32_u
0xB0 i64.trunc_f64_s     0xB1 i64.trunc_f64_u   0xB2 f32.convert_i32_s
0xB3 f32.convert_i32_u   0xB4 f32.convert_i64_s 0xB5 f32.convert_i64_u
0xB6 f32.demote_f64      0xB7 f64.convert_i32_s 0xB8 f64.convert_i32_u
0xB9 f64.convert_i64_s   0xBA f64.convert_i64_u 0xBB f64.promote_f32
0xBC i32.reinterpret_f32 0xBD i64.reinterpret_f64
0xBE f32.reinterpret_i32 0xBF f64.reinterpret_i64
```

**Float compares** `0x5B–0x60` = f32 `eq ne lt gt le ge`; `0x61–0x66` = f64
`eq ne lt gt le ge`. **f32 numeric** `0x8B–0x98` = `abs neg ceil floor trunc
nearest sqrt add sub mul div min max copysign`; **f64 numeric** `0x99–0xA6` = the
same in f64 order.

**Element/data active forms** (binary/modules.html): element flag `0` = active,
table 0, `offset-expr vec(funcidx)`. data form `0x00` = active mem 0,
`offset-expr vec(byte)`; form `0x02` = `memidx offset-expr vec(byte)`. Const-expr
= `instr* 0x0B` (binary grammar accepts any expr; MVP const-exprs are in practice a
single `t.const`, validated downstream). **call_indirect** `0x11` immediates are
**typeidx `y` FIRST, then tableidx `x`** — the existing decoder already reads
`ty`-then-`table` (decode.gleam:567–571); **do not swap them.**

**Pitfalls (each one is a real escape if dropped):**
- **The `0xA7–0xBF` interleaving** mixes int and float. Decode the integer ops
  (`i32.wrap_i64`, `i64.extend_i32_s/u`, the four reinterprets) too — they are not
  yet decoded today (E7). Dropping them silently truncates valid modules.
- **`memory.size`/`memory.grow` take a single `0x00` byte, NOT a memarg.** Reading
  a memarg there corrupts the following instruction stream. A non-zero reserved
  byte → `BadMemoryIndex` (MVP allows only memory 0).
- **Keep the `imported_func_count` offset model.** Section 2 stays skipped, so it
  stays `0`; but `assemble` must keep the field and consumers (09) must keep
  applying `funcidx = imported_func_count + defined_index`. Do not hardcode the
  assumption `funcidx == defined index` away.
- **memarg `align` is a non-semantic hint.** Keep it in the AST for validate's
  `2^align ≤ N` check; it never affects results. Unaligned and chunk-crossing
  accesses are fully legal — never reject on alignment at decode.
- **Don't enforce `min ≤ max ≤ 65536` at decode.** It's a validation rule
  (valid/types.html), owned by 08. Decode reads `min`/optional `max` as `u32`
  faithfully (a `2^16+1` page count is a valid `u32`, an invalid *limit*).
- **Float consts stay raw bit patterns** (D5): `F32Const`/`F64Const` already read
  4/8 LE bytes as unsigned ints. New float ops carry no value — they're leaf
  opcodes; the bit-pattern discipline is rt_num's, not decode's.
- **`select_t` (0x1C), externref (0x6F), element flags 1–7, data form 0x01** are
  beyond MVP — decode-reject with a typed error (or `UnknownOpcode` for 0x1C),
  never half-decode their immediates.

## Verification — Definition of Done (D8)

**Spec behavior, not change-detector.** Drive decode from `wat2wasm`-produced
binaries and assert the AST against the **binary-format spec** (cite the exact
section per fixture); never assert "whatever decode emits."

1. **Worked fixtures (exact AST).** Hand-write `.wat`, run `wat2wasm`, decode, and
   assert the precise AST for at least:
   - **memory store/load** (`(memory 1)` + `i32.store`/`i32.load`) →
     `memories == [MemType(Limits(1, None))]`, body has
     `I32Store(MemArg(align: 2, offset: 0))` and `I32Load(MemArg(align: 2,
     offset: 0))` (natural align of i32 = log2(4) = 2).
   - **call_indirect + table + element** (`(table 1 funcref)`,
     `(elem (i32.const 0) $f)`, `call_indirect (type 0)`) →
     `tables == [TableType(Limits(1, None))]`,
     `elements == [ElementSegment(table: 0, offset: [I32Const(0)], funcs: [<idx>])]`,
     body has `CallIndirect(type_idx: 0, table: 0)`.
   - **global** (`(global (mut i32) (i32.const 42))`) →
     `globals == [Global(ty: I32, mutable: True, init: [I32Const(42)])]`.
   - At least one **conversion** fixture covering an integer conv (`i32.wrap_i64` /
     `i64.extend_i32_s` / a reinterpret) **and** a float convert/trunc — proving
     the `0xA7–0xBF` block is not read float-only.
   - A **start** + active **data** fixture: `start == Some(<idx>)`,
     `data == [DataSegment(mem: 0, offset: [I32Const(0)], bytes: <…>)]`.
2. **Fail-closed fuzz on the NEW surface** (extend the Phase-1 fuzz battery): a
   truncated `memarg` (opcode then EOF mid-LEB), a `memory.grow` with a non-zero
   reserved byte, a bad limits flag, a bad reftype byte, a non-zero `mut` byte, an
   element flag ≥ 1, a data flag 0x01, an oversized `vec` count (count ≫ remaining
   bytes), a truncated data payload. Each must return a **specific `DecodeError`**;
   the single-byte-mutation + truncation sweep over every fixture must **never**
   panic/`let assert`/loop. Assert `decode.gleam` contains no `let assert`,
   `panic`, or `todo` (grep in a test or by inspection).
3. **Round-trip count.** `gleam test` stays green (≥313, plus the new tests); the
   embedded conformance numbers do not regress (decode feeds more fixtures but
   08/09 gate their use).
4. **Clean build.** `gleam format --check src test` clean; `gleam build` **zero
   warnings** (no leftover `todo`/unused). Every new public type/function has a
   `///` doc comment stating its contract + failure modes (D8).
5. **`«WASM-AST2»` announced** in `state.md` the moment the types compile (day 1),
   with the new `Module` fields and `DecodeError` variants listed for 08/09.

Spec citations to use in tests: binary/modules.html (sections, segments, start),
binary/types.html (limits, reftype, globaltype), binary/instructions.html
(load/store + memarg, memory.size/grow, conversion block, float ops, call_indirect),
binary/values.html (LEB128, vec, byte vectors).

## Concurrency

Three roughly-independent sub-tasks after the **day-1 type freeze** (do the
`ast.gleam` type additions first, as one commit, so 08/09 unblock):

- **07a — sections:** `decode_limits`/`tabletype`/`memtype`/`global`/`elemseg`/
  `dataseg`/`const_expr`, `dispatch_section` wiring, `DecodeState`/`assemble`.
- **07b — opcodes:** the load/store matrix + memarg, `memory.size`/`grow`, and the
  `leaf_instr` additions (float + conversion block).
- **07c — tests/fixtures:** worked-fixture AST assertions + the fail-closed fuzz
  extension.

07a and 07b touch disjoint parts of `decode.gleam` (section sub-decoders vs
`decode_instr`/`leaf_instr`) but share the one file (single owner) — coordinate the
merge. 07c follows both. The `ast.gleam` type stub must be frozen before any of
them lands behavior.

## What this leaves for others

- **08 (validate)** consumes `«WASM-AST2»`: it owns `min ≤ max ≤ 65536`,
  `2^align ≤ N` alignment, ≤1 table/≤1 memory, funcidx/typeidx range, global
  immutability (`global.set` on a const), and the **const-expr restriction**
  (only `t.const`/`global.get` of an immutable imported global, correct type,
  single result) over the structurally-decoded `offset`/`init` lists.
- **09 (lower)** maps the new `Instr`s to IR2: load/store → `MemLoad`/`MemStore`
  (+ result width), `MemorySize`/`MemoryGrow` → `MemSize`/`MemGrow`, the float ops
  → the new `NumOp`s, the conversion block → `ConvOp`s (trapping `TruncS/U`,
  `ConvertS/U`, `Demote`/`Promote`, `WrapI64`/`ExtendI32*`/reinterprets), and the
  table/global/element/data/start sections → the IR2 module + instantiation inputs;
  it resolves element `funcs` (funcidx → `f<idx>`, applying `imported_func_count`).
- **11 (capstone)** sources the Phase-2 `.wast` allowlist (memory_trap, address,
  endianness, float_memory, memory_size, call_indirect, global, the scalar-float
  files, …) now that these binaries decode.
