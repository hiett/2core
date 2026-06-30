# Unit 05 — WASM Binary Decoder & WASM AST

> **2 sub-tasks (LEB128 primitives; AST + section/instruction decoder). Wave A.**
> No upstream freeze: the WASM binary format is the spec. Publishes **«WASM-AST»**
> on day 1. Read [`00-overview.md`](00-overview.md) first; this doc assumes D1–D10.

## Context

You sit at the **mouth of the WASM frontend** (high-level §4 row `FW`, §8.1 "Decode").
Your output — a typed WASM AST — is consumed *only* by Unit 10 (`validate` reads
`ast.gleam`; `lower` reads it too). You are **independent of the shared IR**: lowering
to IR is Unit 10's job, not yours. You decode the WASM 1.0 binary format (the Phase-1
slice) using Gleam's inherited Erlang **bit-syntax**, and you do it under an
**untrusted-input threat model**. See `00-overview.md` for D1–D10 and the file map; do
not re-derive them here.

## Goal

Given an arbitrary `BitArray`, produce `Ok(Module)` for every well-formed Phase-1
`.wasm` binary and a **typed `DecodeError`** for every malformed one — **never** a
panic, `let assert` blow-up, or silent wraparound (fail-closed, D4). Proven by decoding
the worked `add` fixture to an exact AST, decoding `wat2wasm`-produced loop/if/call
fixtures, the LEB128 spec vectors, and a negative/fuzz corpus that must produce typed
errors only.

## Files owned

| File | Role |
|---|---|
| `src/twocore/frontend/wasm/ast.gleam` | The decoded WASM module model + `DecodeError`. **FREEZE DAY 1** as «WASM-AST» to unblock Unit 10's validator. |
| `src/twocore/frontend/wasm/decode.gleam` | Binary `.wasm` → AST, incl. generic LEB128. |
| `test/twocore/frontend/wasm/decode_test.gleam` | LEB128 vectors, fixture decode, fail-closed negative/fuzz suite. |

## Depends on

**Nothing upstream.** Start immediately. The only milestone you *produce* is «WASM-AST»
(`ast.gleam` + `DecodeError`). Publish those types — compiling, with stub/real decoder —
on day 1 so Unit 10 can begin against them. The official reference is the spec itself:
<https://webassembly.github.io/spec/core/binary/> (cite section URLs in tests).

## Scope — in / out for Phase 1

**In:**
- Preamble (magic + version).
- Sections **type(1)**, **function(3)**, **export(7)**, **code(10)** — decoded.
- **Custom(0)** and any other section: **safely skipped** via its size field (real
  toolchains emit `name`/`producers` custom sections).
- LEB128 `u32`/`u64`/`s32`/`s33`/`s64` (one generic primitive parameterized by width).
- valtypes, functype, locals (RLE — expanded), the Phase-1 opcode set (below).

**Out (defer / stub):**
- **WAT text parsing** — Phase 2 (§12). Use `wat2wasm` to make `.wasm` fixtures.
- **import / table / memory / global / element / data** parsing — stubbed/deferred
  (D9: Phase-1 corpus uses no memory/tables/globals). Their **section framing must
  still skip them safely** by honoring the size field.
- Lowering to IR, validation, stack-elimination — all Unit 10.

## Deliverables

### `ast.gleam` — the model (freeze day 1)

```gleam
//// The decoded WASM 1.0 module (Phase-1 slice). WASM-shaped on purpose — this is the
//// frontend's private AST, NOT the neutral IR. Unit 10 lowers it into ir.gleam.

pub type ValType { I32  I64  F32  F64 }

pub type FuncType { FuncType(params: List(ValType), results: List(ValType)) }

/// A defined function. `type_idx` indexes the module's type vector. `locals` is the
/// RLE-EXPANDED list of DECLARED locals only (params are NOT included here — params
/// occupy local indices 0..param_count-1, declared locals follow). `body` is the flat
/// instruction stream including nested block/loop/if End/Else markers AND the
/// function-terminating `End` (last element).
pub type Func { Func(type_idx: Int, locals: List(ValType), body: List(Instr)) }

pub type ExportKind { ExportFunc  ExportTable  ExportMemory  ExportGlobal }
pub type Export { Export(name: String, kind: ExportKind, index: Int) }

pub type BlockType { BlockEmpty  BlockVal(ValType)  BlockTypeIdx(Int) }

/// A whole module. `imported_func_count` is the count of imported functions (0 in
/// Phase 1 — import parsing is deferred). KEEP IT EXPLICIT: a `funcidx` addresses the
/// space `imports ++ defined`, so the funcidx of defined function `i` is
/// `imported_func_count + i`. funcidx == defined index ONLY because Phase 1 has no
/// imports — do NOT bake that assumption into consumers.
pub type Module {
  Module(
    imported_func_count: Int,
    types: List(FuncType),
    funcs: List(Func),
    exports: List(Export),
  )
}

pub type Instr {
  // one constructor per Phase-1 opcode — see the opcode table below
  Unreachable  Nop  Block(BlockType)  Loop(BlockType)  If(BlockType)  Else  End
  Br(label: Int)  BrIf(label: Int)  BrTable(targets: List(Int), default: Int)
  Return  Call(func: Int)  CallIndirect(type_idx: Int, table: Int)
  Drop  Select
  LocalGet(Int)  LocalSet(Int)  LocalTee(Int)  GlobalGet(Int)  GlobalSet(Int)
  I32Const(value: Int)  I64Const(value: Int)  F32Const(bits: Int)  F64Const(bits: Int)
  // … comparison / numeric / sign-ext / trunc_sat constructors (table below) …
}

/// Every reason a binary is rejected. Untrusted input → exactly one of these, never a
/// panic (D4). Each variant should carry enough to debug (e.g. a byte offset/Int).
pub type DecodeError {
  BadMagic            BadVersion
  Truncated           // input ended mid-structure
  LebOverflow         // value exceeds the width's range (terminal-byte unused bits set)
  LebTooLong          // > ceil(width/7) bytes
  SectionOrder        // non-custom section out of strictly-ascending order
  SectionSizeMismatch // section sub-decoder did not consume exactly the declared length
  TrailingBytes       // bytes left after the final section
  BadValType          BadFuncTypeForm   // functype not 0x60
  BadExportKind       InvalidUtf8       // export name not valid UTF-8
  BadBlockType
  UnknownOpcode(Int)  UnknownSatOpcode(Int)
}
```

### `decode.gleam` — the algorithm

```gleam
/// Decode a complete .wasm binary into the AST. Ok(module) iff the bytes are a
/// well-formed Phase-1 module; Error(_) for ANY malformation. Never panics.
pub fn decode(bytes: BitArray) -> Result(Module, DecodeError)

/// Decode one unsigned LEB128 integer of `width` bits (32 | 33 | 64). Returns
/// `#(value, rest)` with `value` in [0, 2^width). Error(LebTooLong) if it spans more
/// than ceil(width/7) bytes; Error(LebOverflow) if the terminal byte's bits above the
/// width are nonzero; Error(Truncated) if the bytes end mid-number.
pub fn decode_uN(bytes: BitArray, width: Int) -> Result(#(Int, BitArray), DecodeError)

/// Decode one signed LEB128 integer of `width` bits (two's-complement, sign-extended
/// from the terminal byte's bit 6). Same length/overflow/truncation rejections, except
/// the terminal byte's unused bits must ALL equal the sign bit (else LebOverflow).
pub fn decode_sN(bytes: BitArray, width: Int) -> Result(#(Int, BitArray), DecodeError)
```

**Top-level shape of `decode`:**
1. **Preamble** — match `<<0x00,0x61,0x73,0x6D, 0x01,0x00,0x00,0x00, rest:bytes>>`;
   else `BadMagic` / `BadVersion`. Reject anything else.
2. **Section loop** — repeatedly: read `<<id:8, rest>>`, then `size` via
   `decode_uN(_, 32)`, then **slice exactly `size` bytes** as the section contents
   (`<<contents:bytes-size(size), tail:bytes>>`) and continue on `tail`. Enforce
   strictly-ascending non-custom ids (track `last_id`; `id != 0 && id <= last_id →
   SectionOrder`); custom(0) is allowed anywhere/any number of times and is dropped.
3. **Dispatch** ids 1/3/7/10 to their sub-decoders, run on the *sliced contents*, and
   **assert full consumption** of the slice (`SectionSizeMismatch` otherwise — the
   corruption guard). Skip 2/4/5/6/8/9/11 by discarding the slice.
4. After the loop, `tail` must be empty (`TrailingBytes` otherwise).

**Generic vector helper** (spec `vec(X) = [u32 count][X…]`):
```gleam
fn decode_vec(
  bytes: BitArray,
  elem: fn(BitArray) -> Result(#(a, BitArray), DecodeError),
) -> Result(#(List(a), BitArray), DecodeError)
```

Sub-decoders to write: `decode_functype` (`0x60`, vec(valtype) params, vec(valtype)
results), `decode_valtype`, `decode_func_section` (vec(typeidx u32)), `decode_code`
(`[u32 size][vec(locals)][expr]`, slice by `size`, **RLE-expand** each `[u32 count]
[valtype]` locals group), `decode_export` (`[name][kind:8][idx u32]`, `name =
[u32 len][UTF-8]`), `decode_blocktype`, and `decode_instr`/`decode_expr`.

## Grounded facts you MUST honor

These were verified against the WASM core spec / the real toolchain. Honor them exactly.

### Preamble & sections
- Magic `00 61 73 6D`, version `01 00 00 00`. **Reject anything else.**
- Section = `[1-byte id][u32 LEB size][contents]`. Non-custom sections appear in
  **strictly ascending id order**; **custom(0) may appear anywhere, any number of
  times**. **Always honor the size field** to skip unknown/custom sections.
- **Slice the BitArray to exactly the declared length and assert full consumption** —
  a sub-decoder that under- or over-runs its slice is `SectionSizeMismatch` (corruption
  guard). Spec: <https://webassembly.github.io/spec/core/binary/modules.html>.
- IDs: `custom0 type1 import2 function3 table4 memory5 global6 export7 start8 element9
  code10 data11`.

### Types
- valtype bytes: `i32=0x7F i64=0x7E f32=0x7D f64=0x7C` (the 1-byte sLEB of −1..−4).
  Any other byte → `BadValType`. functype tag = `0x60` (else `BadFuncTypeForm`).
  `vec(X) = [u32 count][X…]`. Spec:
  <https://webassembly.github.io/spec/core/binary/types.html>.

### Code & exports
- `FUNCTION` section = `vec(typeidx u32)`. `CODE` section = `vec(code)`;
  `code = [u32 size][vec(locals)][expr]`; a locals group = `[u32 count][valtype]`
  (**RLE — EXPAND** into `count` copies). **Params occupy local indices `0..k-1`
  BEFORE declared locals** (params come from the FuncType; `Func.locals` holds only the
  expanded declared locals). `expr` is terminated by `0x0B end`.
- `EXPORT` = `vec([name][kind:8][idx u32])`; `name = [u32 len][UTF-8 bytes]`,
  **NOT null-terminated** — **validate UTF-8** (`InvalidUtf8` on failure). func kind
  tag = `0x00`. Spec:
  <https://webassembly.github.io/spec/core/binary/modules.html#export-section>.

### LEB128 — HARD spec validity, not hygiene (build into the primitive)
- Unsigned `uN`: little-endian base-128, bit7 = continuation. **REJECT:** more than
  `ceil(N/7)` bytes; **the terminal byte's bits above the width must be 0.**
- Signed `sN`: two's-complement, **sign-extend from the terminal byte's bit 6.**
  **REJECT:** more than `ceil(N/7)` bytes; the terminal byte's unused bits must **all
  equal the sign bit.**
- `ceil(N/7)`: **u32/s32/s33 → 5 bytes; u64/s64 → 10 bytes.**
- Return `Error(LebOverflow)` / `Error(LebTooLong)` / `Error(Truncated)` — **never a
  silent wraparound.** Spec:
  <https://webassembly.github.io/spec/core/binary/values.html#integers> (the grammar's
  terminal-byte bound `n < 2^(remaining width)` *is* these rejections).

### LEB128 test vectors (assert these — spec-derived, not impl-derived)
| Input bytes | `decode_uN(_,32)` |
|---|---|
| `0x00` | `0` |
| `0x7F` | `127` |
| `0x80 0x01` | `128` |
| `0xE5 0x8E 0x26` | `624485` |
| `0xFF 0xFF 0xFF 0xFF 0x0F` | `4294967295` |
| `0xFF 0xFF 0xFF 0xFF 0x1F` | **`Error` (overflow)** |
| `0x80 0x80 0x80 0x80 0x80 0x00` | **`Error` (too long)** |

| Input bytes | `decode_sN(_,32)` |
|---|---|
| `0x7F` | `-1` |
| `0x40` | `-64` |
| `0x80 0x7F` | `-128` |
| `0xC0 0xBB 0x78` | `-123456` |
| `0xFF 0xFF 0xFF 0xFF 0x07` | `2147483647` |
| `0x80 0x80 0x80 0x80 0x78` | `-2147483648` |
| `0xFF 0xFF 0xFF 0xFF 0x4F` | **`Error` (overflow)** |

### Immediates: pick the right width
- `i32.const` → **`s32`**; `i64.const` → **`s64`**; `f32.const` → **4 raw LE bytes**;
  `f64.const` → **8 raw LE bytes**.
- **BLOCKTYPE** (after `block 0x02` / `loop 0x03` / `if 0x04`): `0x40` = empty |
  a valtype byte (`0x7C`–`0x7F`) | else an **`s33`** typeidx (`>= 0`). **Decode ONE
  `s33`**: `>= 0` ⇒ `BlockTypeIdx`, otherwise it is the sLEB of a valtype/empty (the
  multi-value branch — Phase 1 MUST decode it). **Use `s33` here, NOT `s32`.** Spec:
  <https://webassembly.github.io/spec/core/binary/instructions.html#binary-blocktype>.

### D5 PITFALL — float consts are RAW BIT PATTERNS, never BEAM doubles
Read `f32.const`/`f64.const` as a **little-endian UNSIGNED integer** of the raw bits and
store it in `F32Const(bits)`/`F64Const(bits)`:
```gleam
case bytes { <<bits:32-unsigned-little, rest:bytes>> -> Ok(#(F32Const(bits), rest)) ... }
```
**Do NOT** extract with `:float` — `<<X:32/float>>` / `<<X:64/float>>` **cannot match
NaN/Infinity bit patterns** and will fail the decode (D5; high-level §9.1). Unsigned
integer extraction always succeeds for any 4/8 bytes.

### Phase-1 opcode table (one Instr per opcode)
| Opcode(s) | Instr |
|---|---|
| `0x00 0x01` | `Unreachable` `Nop` |
| `0x02 0x03 0x04` `bt` | `Block` `Loop` `If` (each reads a blocktype) |
| `0x05 0x0B` | `Else` `End` |
| `0x0C 0x0D` `u32` | `Br` `BrIf` |
| `0x0E` `vec(u32)+u32` | `BrTable(targets, default)` |
| `0x0F` | `Return` |
| `0x10` `u32` | `Call` |
| `0x11` `u32,u32` | `CallIndirect(type_idx, table)` (table u32 is `0` in 1.0) |
| `0x1A 0x1B` | `Drop` `Select` |
| `0x20 0x21 0x22` `u32` | `LocalGet` `LocalSet` `LocalTee` |
| `0x23 0x24` `u32` | `GlobalGet` `GlobalSet` |
| `0x41` `s32` / `0x42` `s64` | `I32Const` / `I64Const` |
| `0x43` 4 LE / `0x44` 8 LE | `F32Const(bits)` / `F64Const(bits)` |
| `0x45`–`0x4F` | i32 cmp: `I32Eqz I32Eq I32Ne I32LtS I32LtU I32GtS I32GtU I32LeS I32LeU I32GeS I32GeU` |
| `0x50`–`0x5A` | i64 cmp: `I64Eqz … I64GeU` (same order) |
| `0x67`–`0x78` | i32 num: `I32Clz I32Ctz I32Popcnt I32Add I32Sub I32Mul I32DivS I32DivU I32RemS I32RemU I32And I32Or I32Xor I32Shl I32ShrS I32ShrU I32Rotl I32Rotr` |
| `0x79`–`0x8A` | i64 num: `I64Clz … I64Rotr` (same order) |
| `0xC0`–`0xC4` | `I32Extend8S I32Extend16S I64Extend8S I64Extend16S I64Extend32S` |
| `0xFC` + `u32` sub `0`–`7` | trunc_sat: `I32TruncSatF32S(0) …S F32U(1) F64S(2) F64U(3) I64…F32S(4) F32U(5) F64S(6) F64U(7)` |

**0xFC PITFALL — it is a PREFIX FAMILY, not a leaf.** After `0xFC`, read a `u32`
sub-opcode and dispatch; reject any sub-opcode outside `0..7` with
`UnknownSatOpcode`. If you treat `0xFC` as a leaf you **mis-frame every following
instruction.** Any byte not in the table above → `UnknownOpcode(byte)`.

### Worked fixture (the FIRST decoder test — valid minimal `add`)
```
00 61 73 6D 01 00 00 00
01 07 01 60 02 7F 7F 01 7F
03 02 01 00
07 07 01 03 61 64 64 00 00
0A 09 01 07 00 20 00 20 01 6A 0B
```
Must decode to (assert structurally):
```gleam
Module(
  imported_func_count: 0,
  types: [FuncType(params: [I32, I32], results: [I32])],
  funcs: [Func(type_idx: 0, locals: [],
               body: [LocalGet(0), LocalGet(1), I32Add, End])],
  exports: [Export(name: "add", kind: ExportFunc, index: 0)],
)
```

### Gleam bit-syntax (VERIFIED full on the Erlang target — decoder is Erlang-only)
- Patterns: `<<len:size(8), body:size(len)-bytes, rest:bytes>>`; computed sizes
  `<<b:size(n*8)-bits, …>>`; `signed`/`unsigned`/`little`/`big`; `:bytes` (=binary,
  byte-aligned) and `:bits` (=bitstring, sub-byte tail); `<<x:float-size(64)-little>>`.
- `bit_array.byte_size` / `bit_array.slice` for non-pattern work.
- Bit syntax is **limited on the JS target** — keep this module Erlang-target-only.

## Verification — Definition of Done (D8)

Tests assert **spec behavior**, not whatever the code emits (no change-detector tests).
Cite the spec URLs above in the test bodies.

- **LEB128 unit tests** — every vector in the two tables above (positive *and* the
  overflow/too-long `Error` cases). Add the `s33` blocktype boundary (`-1`/`-2`/… valtypes
  vs `0`/`1` typeidx) and `u64`/`s64` boundary values.
- **Worked `add` fixture** — embed the bytes as a `BitArray` literal; assert the exact
  `Module` above.
- **`wat2wasm` fixtures** — produce small `loop`, `if`, and `call` modules with
  `wat2wasm` (wabt; not installed here — `brew install wabt`), check the **`.wasm`
  bytes into the test tree** (or embed as literals) so tests need no external tool at
  run time; assert the decoded instruction structure (blocktypes, `Br`/`BrIf` labels,
  `Call` index, the trailing `End`).
- **FAIL-CLOSED negative/fuzz suite — every case returns a typed `DecodeError`, never a
  panic or `let assert`:** bad magic, bad version, truncated section (size > remaining),
  over-long / overflowing LEB, section-length mismatch (sub-decoder leaves bytes),
  out-of-order non-custom sections, `0x60`-less functype, unknown opcode, lone `0xFC`
  with a bad sub-opcode, bad export kind byte, **invalid UTF-8 export name**. Drive a
  fuzzer by byte-mutating the `add` fixture and assert the result is always
  `Ok(_) | Error(DecodeError)` — the property is *totality*, never a crash.
- **Totality (D4):** no `let assert`/`panic` reachable from untrusted input. If one is
  used for a genuinely-impossible state, document why (overview §5).
- **Docs (D8):** `////` module doc on each file; `///` contract on every public function
  / type / constructor — what / parameters & ranges / `Result` semantics / failure
  modes.
- `gleam format --check src test` clean; `gleam build` with **no warnings**;
  `gleam test` green.

## Concurrency

Clean two-agent split along the LEB128 seam (freeze `ast.gleam` first):

- **Day 1 (one owner):** publish `ast.gleam` (`Module`, `FuncType`, `Func`, `Export`,
  `Instr`, `ValType`, `BlockType`, `DecodeError`) → announce **«WASM-AST»**. This
  unblocks Unit 10 immediately.
- **Sub-task A — LEB128 primitives.** `decode_uN`/`decode_sN` + their spec-vector
  tests. Fully self-contained; depends on nothing but `DecodeError`. Land it first.
- **Sub-task B — framing + decoders.** Preamble, section loop, the four section
  sub-decoders, `decode_instr`, blocktype, the fixture + fuzz suite. Consumes A's
  primitives (stub them against the signatures meanwhile).

## What this leaves for others

- **«WASM-AST»** (`ast.gleam` + `DecodeError`) → **Unit 10**: `validate.gleam` reads
  `ast.gleam` only (the security boundary), and `lower.gleam` reads it + `ir.gleam`.
- A reusable, spec-strict LEB128 primitive for any future binary-format frontend.
