//// The decoded WebAssembly 1.0 module model. Originally the `«WASM-AST»` Phase-1
//// slice (Unit 05); extended by Unit 07 to the full WASM 1.0 surface —
//// `«WASM-AST2»` — adding the table/memory/global/element/data/start sections and
//// the memory, float, and conversion instruction groups consumed by units 08
//// (validate) and 09 (lower).
////
//// This AST is deliberately **WASM-shaped**: it mirrors the binary format's
//// structure (a flat instruction stream, an operand-stack op set, numeric
//// blocktypes, a funcidx address space). It is the WASM frontend's *private*
//// representation and is NOT the neutral shared IR (`twocore/ir`). Unit 10
//// (`validate` + `lower`) consumes this AST: `validate.gleam` reads it as the
//// security boundary, and `lower.gleam` lowers it into the IR. Nothing in this
//// module knows about the IR.
////
//// Threat model: these types are populated by `twocore/frontend/wasm/decode`
//// from UNTRUSTED bytes. Every malformation is reported as a typed
//// `DecodeError` (below) — the decoder never panics, `let assert`s, or wraps a
//// value silently (fail-closed, overview D4). This type module is frozen on day
//// 1 so Unit 10 can target it immediately.
////
//// References (WebAssembly core spec, binary format):
////  - modules:      https://webassembly.github.io/spec/core/binary/modules.html
////  - types:        https://webassembly.github.io/spec/core/binary/types.html
////  - instructions: https://webassembly.github.io/spec/core/binary/instructions.html
////  - values:       https://webassembly.github.io/spec/core/binary/values.html

import gleam/option.{type Option}

/// A WebAssembly value type — the four Phase-1 number types.
///
/// In the binary format each is a single byte (the 1-byte signed-LEB of a small
/// negative number): `i32 = 0x7F`, `i64 = 0x7E`, `f32 = 0x7D`, `f64 = 0x7C`.
/// No reference types (`funcref`/`externref`) or vector types in Phase 1.
pub type ValType {
  I32
  I64
  F32
  F64
}

/// A function type (signature): the parameter value types and the result value
/// types, in order. Phase-1 modules may declare multi-result types (decoded
/// faithfully here); whether a given function/block is *valid* is Unit 10's job.
///
/// - `params`: parameter types, left-to-right. Parameters occupy local indices
///   `0..length(params)-1`.
/// - `results`: result types, in stack order.
pub type FuncType {
  FuncType(params: List(ValType), results: List(ValType))
}

/// A single defined (non-imported) function.
///
/// - `type_idx`: index into the module's `types` vector giving this function's
///   signature. Range `0..length(types)-1` for a valid module (the decoder does
///   not range-check it — that is validation, Unit 10).
/// - `locals`: the **RLE-EXPANDED** list of DECLARED locals only. The binary
///   format run-length-encodes locals as `(count, valtype)` groups; this field
///   holds them already expanded into one `ValType` per local, in declaration
///   order. Parameters are NOT included here: params occupy local indices
///   `0..param_count-1`, and these declared locals follow at
///   `param_count..param_count+length(locals)-1`.
/// - `body`: the flat instruction stream of the function's expression, including
///   the `Else`/`End` markers of any nested `block`/`loop`/`if` AND the
///   function-terminating `End` as the final element.
pub type Func {
  Func(type_idx: Int, locals: List(ValType), body: List(Instr))
}

/// What an export refers to. Phase 1 only ever *resolves* `ExportFunc`, but the
/// binary kind byte may legally be any of these (`0x00`..`0x03`); the decoder
/// records the kind faithfully and leaves use-site checks to Unit 10.
pub type ExportKind {
  ExportFunc
  ExportTable
  ExportMemory
  ExportGlobal
}

/// A single export entry: a UTF-8 name, the kind of thing exported, and its
/// index in the relevant index space.
///
/// - `name`: the export's name, already validated as UTF-8 (the binary form is a
///   length-prefixed, NOT null-terminated, UTF-8 byte string).
/// - `kind`: which index space `index` addresses.
/// - `index`: the index of the exported item within its space.
pub type Export {
  Export(name: String, kind: ExportKind, index: Int)
}

/// The type annotation on a structured control instruction (`block`/`loop`/`if`).
///
/// In the binary format this is encoded as a single signed-LEB of width 33:
///  - `0x40` (decodes to `-64`)        → `BlockEmpty` (no params, no results);
///  - a valtype byte (`-1`..`-4`)      → `BlockVal(_)` (no params, one result);
///  - a non-negative value             → `BlockTypeIdx(_)` (a `types` index, the
///                                        multi-value / with-params form).
pub type BlockType {
  BlockEmpty
  BlockVal(ValType)
  BlockTypeIdx(Int)
}

/// Resizable limits (the shared shape of a memory type and a table type).
///
/// - `min`: the minimum size — memory in 64KiB **pages**, table in **entries**.
///   Decoded as a `u32` LEB128.
/// - `max`: the optional maximum (`None` is the open-ended `0x00` form; `Some(m)`
///   is the `0x01` form). Also a `u32`.
///
/// The spec bound (`min <= max <= range`, `range = 2^16` pages for a memory) is a
/// VALIDATION rule (unit 08), NOT enforced here — decode reads the numbers
/// faithfully even when they violate the limit (a `2^16+1` page count is a valid
/// `u32`, an invalid *limit*).
pub type Limits {
  Limits(min: Int, max: Option(Int))
}

/// A table type (table section, id 4). The MVP element type is always `funcref`
/// (`0x70`); `externref` (`0x6F`) is rejected at decode (`BadRefType`), so no
/// reftype field is needed yet — only the resizable `limits` (in entries).
pub type TableType {
  TableType(limits: Limits)
}

/// A memory type (memory section, id 5) — just its resizable `limits`, in 64KiB
/// pages.
pub type MemType {
  MemType(limits: Limits)
}

/// A global declaration (global section, id 6).
///
/// - `ty`: the global's value type.
/// - `mutable`: the `mut` byte — `False` for `const` (`0x00`), `True` for `var`
///   (`0x01`).
/// - `init`: the decoded constant-expression instruction list (its terminating
///   `End`/`0x0B` is consumed, NOT stored). Decode is purely structural here; that
///   `init` is a *valid* const-expr (only `t.const` / `global.get` of an immutable
///   imported global) is enforced by validate (unit 08), not decode.
pub type Global {
  Global(ty: ValType, mutable: Bool, init: List(Instr))
}

/// An ACTIVE element segment (element section, id 9; binary flag `0`).
///
/// - `table`: the target table index — always `0` for the flag-`0` form.
/// - `offset`: the constant offset expression's instruction list (its trailing
///   `End` is consumed, NOT stored). Structural only (const-ness is validate's).
/// - `funcs`: the `funcidx` vector written into the table starting at `offset`.
///
/// Passive/declarative forms (flags 1–7) and the expr-list forms are
/// decode-rejected (`BadElemKind`) — reference types / bulk memory, Phase 3.
pub type ElementSegment {
  ElementSegment(table: Int, offset: List(Instr), funcs: List(Int))
}

/// An ACTIVE data segment (data section, id 11; binary forms `0x00`/`0x02`).
///
/// - `mem`: the target memory index — always `0` in the MVP (form `0x00` is mem 0;
///   form `0x02` carries an explicit memidx that must be `0`, else
///   `BadMemoryIndex`).
/// - `offset`: the constant offset expression's instruction list (trailing `End`
///   consumed, not stored).
/// - `bytes`: the raw payload (`vec(byte)`), as a `BitArray`.
///
/// Passive form `0x01` is decode-rejected (`BadDataKind`) — bulk memory, Phase 3.
pub type DataSegment {
  DataSegment(mem: Int, offset: List(Instr), bytes: BitArray)
}

/// A load/store memory immediate (`memarg`).
///
/// - `align`: the RAW log2 alignment EXPONENT (the actual alignment is `2^align`).
///   Kept only so validate can enforce `2^align <= access-byte-width`; it is
///   NON-SEMANTIC (never affects a result) and may be discarded after validation.
/// - `offset`: the static byte offset added to the dynamic address operand.
///
/// Both are decoded as `u32` LEB128. The MVP form is exactly these two `u32`s;
/// the memory64/multi-memory encodings (u64 offset, memidx in align bit 6) are
/// out of scope.
pub type MemArg {
  MemArg(align: Int, offset: Int)
}

/// A whole decoded module.
///
/// - `imported_func_count`: the number of *imported* functions. Always `0` in
///   Phase 1/2 (import parsing is deferred to Phase 3), but kept EXPLICIT on
///   purpose: a `funcidx` addresses the combined space `imports ++ defined`, so
///   the funcidx of defined function `i` is `imported_func_count + i`. `funcidx ==
///   defined index` holds ONLY because there are no imports yet — consumers (units
///   08/09) must use this offset rather than assume `0`.
/// - `types`: the type section's function types, in declaration order.
/// - `tables`: the table section's table types (section 4). MVP: at most one
///   (validate enforces `<= 1`); always `funcref`.
/// - `memories`: the memory section's memory types (section 5). MVP: at most one.
/// - `globals`: the global section's global declarations (section 6), in order.
/// - `funcs`: the defined functions, in order. `funcs[i]` pairs the function
///   section's `i`-th type index with the code section's `i`-th body.
/// - `start`: the start section's funcidx (section 8), or `None` if absent — run
///   last at instantiation.
/// - `elements`: the active element segments (section 9), in order.
/// - `data`: the active data segments (section 11), in order.
/// - `exports`: the export entries, in order.
pub type Module {
  Module(
    imported_func_count: Int,
    types: List(FuncType),
    tables: List(TableType),
    memories: List(MemType),
    globals: List(Global),
    funcs: List(Func),
    start: Option(Int),
    elements: List(ElementSegment),
    data: List(DataSegment),
    exports: List(Export),
  )
}

/// A single decoded instruction (one constructor per Phase-1 opcode).
///
/// The constructors are grouped by the binary opcode ranges they decode from
/// (comments give the opcode). Immediates are carried as fields:
///  - branch labels and indices are relative `u32` values (kept as `Int`);
///  - `I32Const`/`I64Const` carry the decoded SIGNED value;
///  - `F32Const`/`F64Const` carry the RAW little-endian IEEE-754 BIT PATTERN as
///    an unsigned `Int` (NEVER a BEAM float — overview D5: BEAM doubles cannot
///    represent NaN/Infinity payloads, so floats are kept as bits end-to-end).
///
/// This is a flat list per `Func.body`; `block`/`loop`/`if` introduce their own
/// `End` (and `if` an optional `Else`) marker into the same stream rather than
/// nesting — structure is recovered by Unit 10.
pub type Instr {
  // --- control (0x00..0x11) ---
  Unreachable
  // 0x00
  Nop
  // 0x01
  Block(BlockType)
  // 0x02
  Loop(BlockType)
  // 0x03
  If(BlockType)
  // 0x04
  Else
  // 0x05
  End
  // 0x0B
  Br(label: Int)
  // 0x0C
  BrIf(label: Int)
  // 0x0D
  BrTable(targets: List(Int), default: Int)
  // 0x0E
  Return
  // 0x0F
  Call(func: Int)
  // 0x10
  CallIndirect(type_idx: Int, table: Int)

  // 0x11
  // --- parametric (0x1A..0x1B) ---
  Drop
  // 0x1A
  Select

  // 0x1B
  // --- variable access (0x20..0x24) ---
  LocalGet(index: Int)
  // 0x20
  LocalSet(index: Int)
  // 0x21
  LocalTee(index: Int)
  // 0x22
  GlobalGet(index: Int)
  // 0x23
  GlobalSet(index: Int)

  // 0x24
  // --- constants (0x41..0x44) ---
  I32Const(value: Int)
  // 0x41 (signed-LEB s32)
  I64Const(value: Int)
  // 0x42 (signed-LEB s64)
  F32Const(bits: Int)
  // 0x43 (4 raw LE bytes)
  F64Const(bits: Int)

  // 0x44 (8 raw LE bytes)
  // --- i32 comparisons (0x45..0x4F) ---
  I32Eqz
  I32Eq
  I32Ne
  I32LtS
  I32LtU
  I32GtS
  I32GtU
  I32LeS
  I32LeU
  I32GeS
  I32GeU

  // --- i64 comparisons (0x50..0x5A) ---
  I64Eqz
  I64Eq
  I64Ne
  I64LtS
  I64LtU
  I64GtS
  I64GtU
  I64LeS
  I64LeU
  I64GeS
  I64GeU

  // --- i32 numeric (0x67..0x78) ---
  I32Clz
  I32Ctz
  I32Popcnt
  I32Add
  I32Sub
  I32Mul
  I32DivS
  I32DivU
  I32RemS
  I32RemU
  I32And
  I32Or
  I32Xor
  I32Shl
  I32ShrS
  I32ShrU
  I32Rotl
  I32Rotr

  // --- i64 numeric (0x79..0x8A) ---
  I64Clz
  I64Ctz
  I64Popcnt
  I64Add
  I64Sub
  I64Mul
  I64DivS
  I64DivU
  I64RemS
  I64RemU
  I64And
  I64Or
  I64Xor
  I64Shl
  I64ShrS
  I64ShrU
  I64Rotl
  I64Rotr

  // --- sign extension (0xC0..0xC4) ---
  I32Extend8S
  I32Extend16S
  I64Extend8S
  I64Extend16S
  I64Extend32S

  // --- saturating truncation (0xFC prefix, sub-opcodes 0..7) ---
  I32TruncSatF32S
  // 0xFC 0
  I32TruncSatF32U
  // 0xFC 1
  I32TruncSatF64S
  // 0xFC 2
  I32TruncSatF64U
  // 0xFC 3
  I64TruncSatF32S
  // 0xFC 4
  I64TruncSatF32U
  // 0xFC 5
  I64TruncSatF64S
  // 0xFC 6
  I64TruncSatF64U

  // 0xFC 7
  // --- memory load (0x28..0x35) — each carries a `MemArg` immediate ---
  // The load suffix encodes the access WIDTH and SIGN: e.g. `I32Load8S` reads one
  // byte and sign-extends to i32; `F32Load`/`I32Load` are byte-identical (raw
  // bits). The result width is implied by the constructor (unit 09 maps it).
  I32Load(MemArg)
  // 0x28
  I64Load(MemArg)
  // 0x29
  F32Load(MemArg)
  // 0x2A
  F64Load(MemArg)
  // 0x2B
  I32Load8S(MemArg)
  // 0x2C
  I32Load8U(MemArg)
  // 0x2D
  I32Load16S(MemArg)
  // 0x2E
  I32Load16U(MemArg)
  // 0x2F
  I64Load8S(MemArg)
  // 0x30
  I64Load8U(MemArg)
  // 0x31
  I64Load16S(MemArg)
  // 0x32
  I64Load16U(MemArg)
  // 0x33
  I64Load32S(MemArg)
  // 0x34
  I64Load32U(MemArg)

  // 0x35
  // --- memory store (0x36..0x3E) — each carries a `MemArg` immediate ---
  // `StoreN` writes only the low N bits of the value (sign is irrelevant).
  I32Store(MemArg)
  // 0x36
  I64Store(MemArg)
  // 0x37
  F32Store(MemArg)
  // 0x38
  F64Store(MemArg)
  // 0x39
  I32Store8(MemArg)
  // 0x3A
  I32Store16(MemArg)
  // 0x3B
  I64Store8(MemArg)
  // 0x3C
  I64Store16(MemArg)
  // 0x3D
  I64Store32(MemArg)

  // 0x3E
  // --- memory size/grow (0x3F/0x40) — NOT a memarg: a single 0x00 mem-index byte ---
  MemorySize
  // 0x3F 0x00 — current size in pages
  MemoryGrow

  // 0x40 0x00 — grow by delta pages; result is old size or -1
  // --- float comparisons (0x5B..0x66) → i32 0/1 ---
  F32Eq
  // 0x5B
  F32Ne
  // 0x5C
  F32Lt
  // 0x5D
  F32Gt
  // 0x5E
  F32Le
  // 0x5F
  F32Ge
  // 0x60
  F64Eq
  // 0x61
  F64Ne
  // 0x62
  F64Lt
  // 0x63
  F64Gt
  // 0x64
  F64Le
  // 0x65
  F64Ge

  // 0x66
  // --- f32 numeric (0x8B..0x98): abs neg ceil floor trunc nearest sqrt
  //     add sub mul div min max copysign ---
  F32Abs
  // 0x8B
  F32Neg
  // 0x8C
  F32Ceil
  // 0x8D
  F32Floor
  // 0x8E
  F32Trunc
  // 0x8F
  F32Nearest
  // 0x90
  F32Sqrt
  // 0x91
  F32Add
  // 0x92
  F32Sub
  // 0x93
  F32Mul
  // 0x94
  F32Div
  // 0x95
  F32Min
  // 0x96
  F32Max
  // 0x97
  F32Copysign

  // 0x98
  // --- f64 numeric (0x99..0xA6): same order in f64 ---
  F64Abs
  // 0x99
  F64Neg
  // 0x9A
  F64Ceil
  // 0x9B
  F64Floor
  // 0x9C
  F64Trunc
  // 0x9D
  F64Nearest
  // 0x9E
  F64Sqrt
  // 0x9F
  F64Add
  // 0xA0
  F64Sub
  // 0xA1
  F64Mul
  // 0xA2
  F64Div
  // 0xA3
  F64Min
  // 0xA4
  F64Max
  // 0xA5
  F64Copysign

  // 0xA6
  // --- conversion block (0xA7..0xBF): INT and FLOAT interleaved — DO NOT split ---
  // The trapping `Trunc*` here are DISTINCT from the saturating `TruncSat*`
  // (0xFC) above (same source/target, different overflow/NaN behaviour).
  I32WrapI64
  // 0xA7
  I32TruncF32S
  // 0xA8 (trapping)
  I32TruncF32U
  // 0xA9 (trapping)
  I32TruncF64S
  // 0xAA (trapping)
  I32TruncF64U
  // 0xAB (trapping)
  I64ExtendI32S
  // 0xAC
  I64ExtendI32U
  // 0xAD
  I64TruncF32S
  // 0xAE (trapping)
  I64TruncF32U
  // 0xAF (trapping)
  I64TruncF64S
  // 0xB0 (trapping)
  I64TruncF64U
  // 0xB1 (trapping)
  F32ConvertI32S
  // 0xB2
  F32ConvertI32U
  // 0xB3
  F32ConvertI64S
  // 0xB4
  F32ConvertI64U
  // 0xB5
  F32DemoteF64
  // 0xB6
  F64ConvertI32S
  // 0xB7
  F64ConvertI32U
  // 0xB8
  F64ConvertI64S
  // 0xB9
  F64ConvertI64U
  // 0xBA
  F64PromoteF32
  // 0xBB
  I32ReinterpretF32
  // 0xBC
  I64ReinterpretF64
  // 0xBD
  F32ReinterpretI32
  // 0xBE
  F64ReinterpretI64
  // 0xBF
}

/// Every reason the decoder rejects a binary. UNTRUSTED input maps to EXACTLY
/// one of these — never a panic (overview D4). Variants carry enough context to
/// debug where sensible.
///
/// - `BadMagic`: the leading 4 bytes are not `00 61 73 6D` (also covers an input
///   too short to contain the magic).
/// - `BadVersion`: magic is present but the 4 version bytes are not
///   `01 00 00 00`.
/// - `Truncated`: the input ended in the middle of a structure (a section,
///   LEB128 number, name, instruction, or const).
/// - `LebOverflow`: a LEB128 value does not fit its declared width — the
///   terminal byte's bits above the width are set (unsigned), or the unused bits
///   do not all equal the sign bit (signed). Never wraps silently.
/// - `LebTooLong`: a LEB128 number spans more than `ceil(width/7)` bytes.
/// - `SectionOrder`: a non-custom section id is not strictly greater than the
///   previous non-custom section's id.
/// - `SectionSizeMismatch`: a section/code sub-decoder did not consume EXACTLY
///   the declared length (it left bytes inside the slice). The corruption guard.
/// - `TrailingBytes`: bytes remain after the module is fully decoded. Reserved:
///   the greedy section loop instead reports leftover bytes as a more specific
///   error (`Truncated`/`SectionOrder`/…); kept in the vocabulary for Unit 10.
/// - `BadValType`: a value-type byte is not one of `0x7C`..`0x7F`.
/// - `BadFuncTypeForm`: a functype did not begin with the `0x60` tag.
/// - `BadExportKind`: an export kind byte is not `0x00`..`0x03`.
/// - `InvalidUtf8`: an export name's bytes are not valid UTF-8.
/// - `BadBlockType`: a blocktype's signed-LEB(33) is negative but not one of the
///   recognised valtype/empty encodings (`-1`..`-4`, `-64`).
/// - `UnknownOpcode(Int)`: an opcode byte is outside the Phase-1 set (carries the
///   offending byte).
/// - `UnknownSatOpcode(Int)`: a `0xFC`-prefixed sub-opcode is outside `0..7`
///   (carries the offending sub-opcode).
/// - `FuncCodeCountMismatch`: the function section and code section declared
///   different numbers of functions, so their entries cannot be paired. (Spec:
///   the binary module decoding requires the two vectors to have equal length.)
/// - `BadRefType`: a table element-type byte is not `funcref` (`0x70`) — e.g.
///   `externref` (`0x6F`), a reference-types feature deferred to Phase 3.
/// - `BadLimitsFlag`: a limits flag byte is not `0x00`/`0x01` (e.g. the memory64
///   `0x04`/`0x05` i64-indexed forms).
/// - `BadMutability`: a global `mut` byte is not `0x00` (const) / `0x01` (var).
/// - `BadElemKind`: an element-segment leading flag is not `0` (passive /
///   declarative / expr-list forms 1–7 — reference types / bulk memory, Phase 3).
/// - `BadDataKind`: a data-segment leading flag is not `0x00`/`0x02` (the passive
///   form `0x01` is bulk memory, Phase 3).
/// - `BadMemoryIndex`: a reserved memory-index byte is non-zero where the MVP
///   permits only memory 0 (`memory.size`/`memory.grow`'s `0x00` byte, or a data
///   segment's `0x02` explicit memidx).
pub type DecodeError {
  BadMagic
  BadVersion
  Truncated
  LebOverflow
  LebTooLong
  SectionOrder
  SectionSizeMismatch
  TrailingBytes
  BadValType
  BadFuncTypeForm
  BadExportKind
  InvalidUtf8
  BadBlockType
  UnknownOpcode(Int)
  UnknownSatOpcode(Int)
  FuncCodeCountMismatch
  BadRefType
  BadLimitsFlag
  BadMutability
  BadElemKind
  BadDataKind
  BadMemoryIndex
}
