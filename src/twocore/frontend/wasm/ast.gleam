//// The decoded WebAssembly 1.0 module model (the Phase-1 slice) — the
//// `«WASM-AST»` milestone produced by Unit 05.
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

/// A whole decoded module (the Phase-1 sections only).
///
/// - `imported_func_count`: the number of *imported* functions. Always `0` in
///   Phase 1 (import parsing is deferred), but kept EXPLICIT on purpose: a
///   `funcidx` addresses the combined space `imports ++ defined`, so the funcidx
///   of defined function `i` is `imported_func_count + i`. `funcidx == defined
///   index` holds ONLY because Phase 1 has no imports — consumers (Unit 10,
///   Phase 2) must use this offset rather than assume `0`.
/// - `types`: the type section's function types, in declaration order.
/// - `funcs`: the defined functions, in order. `funcs[i]` pairs the function
///   section's `i`-th type index with the code section's `i`-th body.
/// - `exports`: the export entries, in order.
pub type Module {
  Module(
    imported_func_count: Int,
    types: List(FuncType),
    funcs: List(Func),
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
}
