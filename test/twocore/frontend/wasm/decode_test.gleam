//// Spec-based tests for `twocore/frontend/wasm/decode` (Unit 05).
////
//// Assertions target the WebAssembly core spec's BINARY FORMAT, not whatever the
//// implementation happens to emit:
////  - integers/LEB128: https://webassembly.github.io/spec/core/binary/values.html#integers
////  - modules/sections: https://webassembly.github.io/spec/core/binary/modules.html
////  - types:            https://webassembly.github.io/spec/core/binary/types.html
////  - instructions:     https://webassembly.github.io/spec/core/binary/instructions.html
////
//// The `.wasm` fixtures (`add` hand-derived from the unit doc; the rest —
//// `sum_to`/`abs`/`fib`/`mv` and the Phase-2 `mem`/`ci`/`glob`/`conv`/`startdata`
//// fixtures — produced by `wat2wasm`) are embedded as byte literals so the suite
//// needs no external tool at run time. The fail-closed suite proves every
//// malformation (Phase-1 and the new Phase-2 sections/opcodes) yields a typed
//// `DecodeError` (never a panic), and the fuzz tests prove TOTALITY over
//// single-byte mutations and truncations of the `add`, `mem`, and `conv`
//// fixtures.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import simplifile
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode

// ───────────────────────────── helpers ─────────────────────────────

/// Build a `BitArray` from a list of byte values (each truncated to 8 bits),
/// in order. Used to author fixtures and craft malformed inputs.
fn bytes(ints: List(Int)) -> BitArray {
  list.fold(ints, <<>>, fn(acc, b) { <<acc:bits, b:8>> })
}

/// Inclusive integer range `[from, to]` (empty if `from > to`). Local helper so
/// the suite does not depend on a stdlib range function.
fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}

/// Replace the byte at index `idx` of `ints` with `val` (a fresh list).
fn replace(ints: List(Int), idx: Int, val: Int) -> List(Int) {
  list.index_map(ints, fn(b, i) {
    case i == idx {
      True -> val
      False -> b
    }
  })
}

// The worked `add(i32,i32)->i32` fixture from the unit doc (section 05), as raw
// bytes. Kept as a List(Int) so the fuzz/negative tests can mutate it.
const add_fixture: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02,
  0x7F, 0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x61,
  0x64, 0x64, 0x00, 0x00, 0x0A, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01,
  0x6A, 0x0B,
]

// ──────────────────────── LEB128 unsigned vectors ────────────────────────
// Spec: https://webassembly.github.io/spec/core/binary/values.html#integers

pub fn uleb_zero_test() {
  decode.decode_u_n(<<0x00>>, 32)
  |> should.equal(Ok(#(0, <<>>)))
}

pub fn uleb_127_test() {
  decode.decode_u_n(<<0x7F>>, 32)
  |> should.equal(Ok(#(127, <<>>)))
}

pub fn uleb_128_test() {
  decode.decode_u_n(<<0x80, 0x01>>, 32)
  |> should.equal(Ok(#(128, <<>>)))
}

pub fn uleb_624485_test() {
  decode.decode_u_n(<<0xE5, 0x8E, 0x26>>, 32)
  |> should.equal(Ok(#(624_485, <<>>)))
}

pub fn uleb_u32_max_test() {
  decode.decode_u_n(<<0xFF, 0xFF, 0xFF, 0xFF, 0x0F>>, 32)
  |> should.equal(Ok(#(4_294_967_295, <<>>)))
}

pub fn uleb_overflow_test() {
  // Terminal byte 0x1F sets bit 4, exceeding the 32-bit width.
  decode.decode_u_n(<<0xFF, 0xFF, 0xFF, 0xFF, 0x1F>>, 32)
  |> should.equal(Error(ast.LebOverflow))
}

pub fn uleb_too_long_test() {
  // Six bytes for a 32-bit value (max is ceil(32/7) = 5).
  decode.decode_u_n(<<0x80, 0x80, 0x80, 0x80, 0x80, 0x00>>, 32)
  |> should.equal(Error(ast.LebTooLong))
}

pub fn uleb_truncated_test() {
  // Continuation bit set but no following byte.
  decode.decode_u_n(<<0x80>>, 32)
  |> should.equal(Error(ast.Truncated))
}

pub fn uleb_leaves_rest_test() {
  decode.decode_u_n(<<0x01, 0xAA, 0xBB>>, 32)
  |> should.equal(Ok(#(1, <<0xAA, 0xBB>>)))
}

// u64 boundary: the maximum 64-bit value is ten bytes (nine 0xFF + 0x01).
pub fn uleb_u64_max_test() {
  decode.decode_u_n(
    <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01>>,
    64,
  )
  |> should.equal(Ok(#(18_446_744_073_709_551_615, <<>>)))
}

pub fn uleb_u64_overflow_test() {
  // Terminal byte 0x02 sets a bit above the 64-bit width.
  decode.decode_u_n(
    <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02>>,
    64,
  )
  |> should.equal(Error(ast.LebOverflow))
}

// ──────────────────────── LEB128 signed vectors ────────────────────────

pub fn sleb_neg1_test() {
  decode.decode_s_n(<<0x7F>>, 32)
  |> should.equal(Ok(#(-1, <<>>)))
}

pub fn sleb_neg64_test() {
  decode.decode_s_n(<<0x40>>, 32)
  |> should.equal(Ok(#(-64, <<>>)))
}

pub fn sleb_neg128_test() {
  decode.decode_s_n(<<0x80, 0x7F>>, 32)
  |> should.equal(Ok(#(-128, <<>>)))
}

pub fn sleb_neg123456_test() {
  decode.decode_s_n(<<0xC0, 0xBB, 0x78>>, 32)
  |> should.equal(Ok(#(-123_456, <<>>)))
}

pub fn sleb_i32_max_test() {
  decode.decode_s_n(<<0xFF, 0xFF, 0xFF, 0xFF, 0x07>>, 32)
  |> should.equal(Ok(#(2_147_483_647, <<>>)))
}

pub fn sleb_i32_min_test() {
  decode.decode_s_n(<<0x80, 0x80, 0x80, 0x80, 0x78>>, 32)
  |> should.equal(Ok(#(-2_147_483_648, <<>>)))
}

pub fn sleb_overflow_test() {
  // Negative terminal byte 0x4F whose sign-fill bits don't all equal the sign.
  decode.decode_s_n(<<0xFF, 0xFF, 0xFF, 0xFF, 0x4F>>, 32)
  |> should.equal(Error(ast.LebOverflow))
}

pub fn sleb_positive_small_test() {
  decode.decode_s_n(<<0x00>>, 32)
  |> should.equal(Ok(#(0, <<>>)))
}

// s64 boundary: INT64_MIN encodes as nine 0x80 then 0x7F.
pub fn sleb_i64_min_test() {
  decode.decode_s_n(
    <<0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7F>>,
    64,
  )
  |> should.equal(Ok(#(-9_223_372_036_854_775_808, <<>>)))
}

pub fn sleb_i64_max_test() {
  decode.decode_s_n(
    <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00>>,
    64,
  )
  |> should.equal(Ok(#(9_223_372_036_854_775_807, <<>>)))
}

// ──────────── s33 blocktype boundary (spec binary/instructions) ────────────
// A blocktype is one s33: >= 0 is a typeidx, the small negatives are
// valtype/empty encodings.

pub fn s33_zero_is_typeidx_test() {
  decode.decode_s_n(<<0x00>>, 33)
  |> should.equal(Ok(#(0, <<>>)))
}

pub fn s33_positive_typeidx_test() {
  decode.decode_s_n(<<0x05>>, 33)
  |> should.equal(Ok(#(5, <<>>)))
}

pub fn s33_valtype_i32_test() {
  // 0x7F is the valtype byte for i32; as an s33 it is -1.
  decode.decode_s_n(<<0x7F>>, 33)
  |> should.equal(Ok(#(-1, <<>>)))
}

pub fn s33_valtype_f64_test() {
  // 0x7C is the valtype byte for f64; as an s33 it is -4.
  decode.decode_s_n(<<0x7C>>, 33)
  |> should.equal(Ok(#(-4, <<>>)))
}

pub fn s33_empty_test() {
  // 0x40 is the empty blocktype; as an s33 it is -64.
  decode.decode_s_n(<<0x40>>, 33)
  |> should.equal(Ok(#(-64, <<>>)))
}

// ───────────────────── worked `add` fixture: exact AST ─────────────────────

pub fn decode_add_fixture_test() {
  decode.decode(bytes(add_fixture))
  |> should.equal(
    Ok(
      ast.Module(
        imported_func_count: 0,
        types: [ast.FuncType(params: [ast.I32, ast.I32], results: [ast.I32])],
        imports: [],
        tables: [],
        memories: [],
        globals: [],
        funcs: [
          ast.Func(type_idx: 0, locals: [], body: [
            ast.LocalGet(0),
            ast.LocalGet(1),
            ast.I32Add,
            ast.End,
          ]),
        ],
        start: None,
        elements: [],
        data: [],
        data_count: None,
        exports: [ast.Export(name: "add", kind: ast.ExportFunc, index: 0)],
      ),
    ),
  )
}

// ───────────────────── wat2wasm fixtures: structure ─────────────────────

// sum_to: a `block`/`loop` with EMPTY blocktypes, two declared i32 locals
// (RLE count=2), `br_if`/`br` with labels, and the trailing function `End`.
const sum_to_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0A, 0x01, 0x06, 0x73, 0x75,
  0x6D, 0x5F, 0x74, 0x6F, 0x00, 0x00, 0x0A, 0x25, 0x01, 0x23, 0x01, 0x02, 0x7F,
  0x02, 0x40, 0x03, 0x40, 0x20, 0x02, 0x20, 0x00, 0x4E, 0x0D, 0x01, 0x20, 0x01,
  0x20, 0x02, 0x6A, 0x21, 0x01, 0x20, 0x02, 0x41, 0x01, 0x6A, 0x21, 0x02, 0x0C,
  0x00, 0x0B, 0x0B, 0x20, 0x01, 0x0B,
>>

pub fn decode_sum_to_test() {
  let assert Ok(m) = decode.decode(sum_to_wasm)
  m.exports
  |> should.equal([ast.Export(name: "sum_to", kind: ast.ExportFunc, index: 0)])
  let assert [func] = m.funcs
  // Two i32 locals, RLE-expanded from a single (count=2, i32) group.
  func.locals
  |> should.equal([ast.I32, ast.I32])
  func.body
  |> should.equal([
    ast.Block(ast.BlockEmpty),
    ast.Loop(ast.BlockEmpty),
    ast.LocalGet(2),
    ast.LocalGet(0),
    ast.I32GeS,
    ast.BrIf(1),
    ast.LocalGet(1),
    ast.LocalGet(2),
    ast.I32Add,
    ast.LocalSet(1),
    ast.LocalGet(2),
    ast.I32Const(1),
    ast.I32Add,
    ast.LocalSet(2),
    ast.Br(0),
    ast.End,
    ast.End,
    ast.LocalGet(1),
    ast.End,
  ])
}

// abs: an `if (result i32)` — a single-valtype blocktype — with an `else`.
const abs_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x61, 0x62,
  0x73, 0x00, 0x00, 0x0A, 0x14, 0x01, 0x12, 0x00, 0x20, 0x00, 0x41, 0x00, 0x48,
  0x04, 0x7F, 0x41, 0x00, 0x20, 0x00, 0x6B, 0x05, 0x20, 0x00, 0x0B, 0x0B,
>>

pub fn decode_abs_if_else_test() {
  let assert Ok(m) = decode.decode(abs_wasm)
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.LocalGet(0),
    ast.I32Const(0),
    ast.I32LtS,
    ast.If(ast.BlockVal(ast.I32)),
    ast.I32Const(0),
    ast.LocalGet(0),
    ast.I32Sub,
    ast.Else,
    ast.LocalGet(0),
    ast.End,
    ast.End,
  ])
}

// fib: a direct self-`call` (Call index 0).
const fib_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x66, 0x69,
  0x62, 0x00, 0x00, 0x0A, 0x1E, 0x01, 0x1C, 0x00, 0x20, 0x00, 0x41, 0x02, 0x48,
  0x04, 0x7F, 0x20, 0x00, 0x05, 0x20, 0x00, 0x41, 0x01, 0x6B, 0x10, 0x00, 0x20,
  0x00, 0x41, 0x02, 0x6B, 0x10, 0x00, 0x6A, 0x0B, 0x0B,
>>

pub fn decode_fib_call_test() {
  let assert Ok(m) = decode.decode(fib_wasm)
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.LocalGet(0),
    ast.I32Const(2),
    ast.I32LtS,
    ast.If(ast.BlockVal(ast.I32)),
    ast.LocalGet(0),
    ast.Else,
    ast.LocalGet(0),
    ast.I32Const(1),
    ast.I32Sub,
    ast.Call(0),
    ast.LocalGet(0),
    ast.I32Const(2),
    ast.I32Sub,
    ast.Call(0),
    ast.I32Add,
    ast.End,
    ast.End,
  ])
}

// mv: a `block (type $t)` whose blocktype is the POSITIVE s33 typeidx branch
// (multi-value). `$t` is type index 0, so the blocktype byte 0x00 decodes to
// BlockTypeIdx(0).
const mv_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x00,
  0x02, 0x7F, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x06, 0x01, 0x02, 0x6D, 0x76,
  0x00, 0x00, 0x0A, 0x0B, 0x01, 0x09, 0x00, 0x02, 0x00, 0x41, 0x01, 0x41, 0x02,
  0x0B, 0x0B,
>>

pub fn decode_mv_blocktype_idx_test() {
  let assert Ok(m) = decode.decode(mv_wasm)
  // type 0 is () -> (i32, i32).
  m.types
  |> should.equal([ast.FuncType(params: [], results: [ast.I32, ast.I32])])
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.Block(ast.BlockTypeIdx(0)),
    ast.I32Const(1),
    ast.I32Const(2),
    ast.End,
    ast.End,
  ])
}

// ─────────────── Phase-2 worked fixtures (wat2wasm): exact AST ───────────────
// Each `.wasm` is produced by `wat2wasm` and asserted against the binary-format
// spec: memory/limits (binary/types.html §limits, §memtype), load/store + memarg
// (binary/instructions.html §memory), table/element (binary/modules.html §elem),
// global (binary/types.html §globaltype), the 0xA7..0xBF conversion block, and
// start + active data (binary/modules.html §start, §data).

// (memory 1) + i32.store/i32.load. Natural alignment of i32 is log2(4) = 2.
// Kept as `List(Int)` so the fail-closed fuzz sweep can mutate it.
const mem_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02,
  0x7F, 0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01,
  0x07, 0x07, 0x01, 0x03, 0x6D, 0x65, 0x6D, 0x00, 0x00, 0x0A, 0x10, 0x01, 0x0E,
  0x00, 0x20, 0x00, 0x20, 0x01, 0x36, 0x02, 0x00, 0x20, 0x00, 0x28, 0x02, 0x00,
  0x0B,
]

pub fn decode_memory_store_load_test() {
  let assert Ok(m) = decode.decode(bytes(mem_ints))
  // Memory section: one memory, limits flag 0x00 → min 1 page, no max, Idx32.
  m.memories
  |> should.equal([ast.MemType(ast.Limits(min: 1, max: None), ast.Idx32)])
  let assert [func] = m.funcs
  // store/load carry the natural-alignment memarg (align = log2(4) = 2, offset 0,
  // default memory index 0 — byte-identical to Phase 4).
  func.body
  |> should.equal([
    ast.LocalGet(0),
    ast.LocalGet(1),
    ast.I32Store(ast.MemArg(align: 2, offset: 0, mem: 0)),
    ast.LocalGet(0),
    ast.I32Load(ast.MemArg(align: 2, offset: 0, mem: 0)),
    ast.End,
  ])
}

// (table 1 funcref) + (elem (i32.const 0) $f) + call_indirect (type 0).
const ci_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7F, 0x01, 0x7F, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00,
  0x01, 0x07, 0x06, 0x01, 0x02, 0x63, 0x69, 0x00, 0x01, 0x09, 0x07, 0x01, 0x00,
  0x41, 0x00, 0x0B, 0x01, 0x00, 0x0A, 0x10, 0x02, 0x04, 0x00, 0x20, 0x00, 0x0B,
  0x09, 0x00, 0x20, 0x00, 0x41, 0x00, 0x11, 0x00, 0x00, 0x0B,
>>

pub fn decode_table_elem_call_indirect_test() {
  let assert Ok(m) = decode.decode(ci_wasm)
  // Table section: one funcref table, limits min 1, no max.
  m.tables
  |> should.equal([ast.TableType(ast.FuncRef, ast.Limits(min: 1, max: None))])
  // Active (flag-0) element segment: table 0, constant offset i32.const 0, funcidx
  // list [0] ($f) — the byte-identical Phase-4 shape.
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemActive(0, [ast.I32Const(0)]),
      ast.FuncRef,
      ast.ElemFuncs([0]),
    ),
  ])
  // The exported `ci` function is the SECOND defined function (funcidx 1).
  let assert [_f, ci] = m.funcs
  // call_indirect binary immediates are typeidx-then-tableidx (0x11 y x).
  ci.body
  |> should.equal([
    ast.LocalGet(0),
    ast.I32Const(0),
    ast.CallIndirect(type_idx: 0, table: 0),
    ast.End,
  ])
}

// (global (mut i32) (i32.const 42)) — a mutable i32 global with a const init.
const glob_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x06, 0x06, 0x01, 0x7F, 0x01, 0x41, 0x2A,
  0x0B, 0x07, 0x05, 0x01, 0x01, 0x67, 0x00, 0x00, 0x0A, 0x06, 0x01, 0x04, 0x00,
  0x23, 0x00, 0x0B,
>>

pub fn decode_global_test() {
  let assert Ok(m) = decode.decode(glob_wasm)
  // mut byte 0x01 → mutable; init is the structurally-decoded const-expr
  // (terminating End consumed), a single i32.const 42 (0x2A).
  m.globals
  |> should.equal([
    ast.Global(ty: ast.I32, mutable: True, init: [ast.I32Const(42)]),
  ])
}

// The 0xA7..0xBF conversion block: INT conversions (wrap/extend/reinterpret) AND
// FLOAT conversions (trunc f→i, convert i→f) — proving the block is not read as
// float-only (E7). Five functions: wrap/ext/trunc/conv/reint.
const conv_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x60, 0x01,
  0x7E, 0x01, 0x7F, 0x60, 0x01, 0x7F, 0x01, 0x7E, 0x60, 0x01, 0x7C, 0x01, 0x7F,
  0x60, 0x01, 0x7F, 0x01, 0x7D, 0x60, 0x01, 0x7D, 0x01, 0x7F, 0x03, 0x06, 0x05,
  0x00, 0x01, 0x02, 0x03, 0x04, 0x07, 0x25, 0x05, 0x04, 0x77, 0x72, 0x61, 0x70,
  0x00, 0x00, 0x03, 0x65, 0x78, 0x74, 0x00, 0x01, 0x05, 0x74, 0x72, 0x75, 0x6E,
  0x63, 0x00, 0x02, 0x04, 0x63, 0x6F, 0x6E, 0x76, 0x00, 0x03, 0x05, 0x72, 0x65,
  0x69, 0x6E, 0x74, 0x00, 0x04, 0x0A, 0x1F, 0x05, 0x05, 0x00, 0x20, 0x00, 0xA7,
  0x0B, 0x05, 0x00, 0x20, 0x00, 0xAC, 0x0B, 0x05, 0x00, 0x20, 0x00, 0xAA, 0x0B,
  0x05, 0x00, 0x20, 0x00, 0xB2, 0x0B, 0x05, 0x00, 0x20, 0x00, 0xBC, 0x0B,
]

pub fn decode_conversion_block_int_and_float_test() {
  let assert Ok(m) = decode.decode(bytes(conv_ints))
  let bodies = list.map(m.funcs, fn(f) { f.body })
  bodies
  |> should.equal([
    // i32.wrap_i64 (0xA7) — integer conversion
    [ast.LocalGet(0), ast.I32WrapI64, ast.End],
    // i64.extend_i32_s (0xAC) — integer conversion
    [ast.LocalGet(0), ast.I64ExtendI32S, ast.End],
    // i32.trunc_f64_s (0xAA) — trapping float→int
    [ast.LocalGet(0), ast.I32TruncF64S, ast.End],
    // f32.convert_i32_s (0xB2) — int→float
    [ast.LocalGet(0), ast.F32ConvertI32S, ast.End],
    // i32.reinterpret_f32 (0xBC) — integer (bit) reinterpret
    [ast.LocalGet(0), ast.I32ReinterpretF32, ast.End],
  ])
}

// (start $s) + active (data (i32.const 0) "hi").
const startdata_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x08, 0x01, 0x00,
  0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B, 0x0B, 0x08, 0x01, 0x00, 0x41, 0x00, 0x0B,
  0x02, 0x68, 0x69,
>>

pub fn decode_start_and_active_data_test() {
  let assert Ok(m) = decode.decode(startdata_wasm)
  // Start section: funcidx 0.
  m.start
  |> should.equal(Some(0))
  // Active data segment (flag 0): mem 0, const offset i32.const 0, "hi" payload —
  // the byte-identical Phase-4 shape.
  m.data
  |> should.equal([
    ast.DataSegment(ast.DataActive(0, [ast.I32Const(0)]), <<0x68, 0x69>>),
  ])
}

// A couple of leaf opcodes (no immediates) decoded precisely via a hand-built
// `() -> ()` body, locking the float/conversion `leaf_instr` rows.
// Spot-check representative + BOUNDARY opcodes of every new no-immediate
// `leaf_instr` range, decoded via a hand-built body (decode is structural, so
// type-validity is irrelevant). A wrong row in the opcode table mismatches here.
pub fn decode_float_leaf_test() {
  // float compares 0x5B/0x66; f32 numeric 0x8B/0x92/0x98; f64 numeric 0x99/0xA6;
  // conversion block 0xA7/0xBD/0xBF (range ends + a midpoint each).
  let body = [0x5B, 0x66, 0x8B, 0x92, 0x98, 0x99, 0xA6, 0xA7, 0xBD, 0xBF, 0x0B]
  let assert Ok(m) = decode.decode(bytes(module_with_body(body)))
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.F32Eq,
    ast.F64Ge,
    ast.F32Abs,
    ast.F32Add,
    ast.F32Copysign,
    ast.F64Abs,
    ast.F64Copysign,
    ast.I32WrapI64,
    ast.I64ReinterpretF64,
    ast.F64ReinterpretI64,
    ast.End,
  ])
}

// ───────────────── hand-built modules: 0xFC family + br_table ─────────────────

// Minimal module `() -> ()` whose body is `<instr> end`.
fn module_with_body(body: List(Int)) -> List(Int) {
  let type_section = [0x01, 0x04, 0x01, 0x60, 0x00, 0x00]
  let function_section = [0x03, 0x02, 0x01, 0x00]
  let code_entry_body = list.append([0x00], body)
  let code_entry = list.append([list.length(code_entry_body)], code_entry_body)
  let code_vec = list.append([0x01], code_entry)
  let code_section = list.append([0x0A, list.length(code_vec)], code_vec)
  list.flatten([
    [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
    type_section,
    function_section,
    code_section,
  ])
}

pub fn decode_trunc_sat_ok_test() {
  // 0xFC sub-opcode 0 = i32.trunc_sat_f32_s.
  let assert Ok(m) = decode.decode(bytes(module_with_body([0xFC, 0x00, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.I32TruncSatF32S, ast.End])
}

pub fn decode_trunc_sat_unknown_sub_test() {
  // 0xFC sub-opcode 32 is outside the known range (0..7 sat, 8..17 bulk). (Sub 8 is
  // now `memory.init`, so the old sub-8 rejection no longer applies.)
  decode.decode(bytes(module_with_body([0xFC, 0x20, 0x0B])))
  |> should.equal(Error(ast.UnknownSatOpcode(32)))
}

pub fn decode_br_table_test() {
  // br_table [0,1,2] default 3, then end.
  let assert Ok(m) =
    decode.decode(
      bytes(module_with_body([0x0E, 0x03, 0x00, 0x01, 0x02, 0x03, 0x0B])),
    )
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.BrTable(targets: [0, 1, 2], default: 3), ast.End])
}

// ───────────────── section skipping (custom + out-of-scope) ─────────────────

pub fn skip_custom_section_test() {
  // Insert a custom section (id 0, size 3, contents "abc") right after the
  // preamble; decode must ignore it and yield the same AST as `add`.
  let with_custom =
    list.flatten([
      list.take(add_fixture, 8),
      [0x00, 0x03, 0x61, 0x62, 0x63],
      list.drop(add_fixture, 8),
    ])
  decode.decode(bytes(with_custom))
  |> should.equal(decode.decode(bytes(add_fixture)))
}

pub fn empty_import_section_neutral_test() {
  // The import section (id 2) is now DECODED (Phase 5). An EMPTY import section
  // (count 0) adds no imports, so the AST is identical to `add` (imports == [],
  // imported_func_count == 0) — the neutrality property. Insert `[0x02, 0x01, 0x00]`
  // (id 2, size 1, count 0) between type(1, 17 bytes in) and function(3).
  let with_import =
    list.flatten([
      list.take(add_fixture, 17),
      [0x02, 0x01, 0x00],
      list.drop(add_fixture, 17),
    ])
  decode.decode(bytes(with_import))
  |> should.equal(decode.decode(bytes(add_fixture)))
}

// ─────────────────────── fail-closed negative suite ───────────────────────
// Every malformation must return a typed DecodeError (never a panic).

pub fn bad_magic_test() {
  decode.decode(<<0x00, 0x61, 0x73, 0x6C, 0x01, 0x00, 0x00, 0x00>>)
  |> should.equal(Error(ast.BadMagic))
}

pub fn bad_magic_short_test() {
  decode.decode(<<0x00, 0x61>>)
  |> should.equal(Error(ast.BadMagic))
}

pub fn empty_input_test() {
  decode.decode(<<>>)
  |> should.equal(Error(ast.BadMagic))
}

pub fn bad_version_test() {
  decode.decode(<<0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00>>)
  |> should.equal(Error(ast.BadVersion))
}

pub fn truncated_version_test() {
  decode.decode(<<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00>>)
  |> should.equal(Error(ast.Truncated))
}

pub fn truncated_section_size_test() {
  // Type section declares size 7 but no contents follow.
  decode.decode(<<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07>>)
  |> should.equal(Error(ast.Truncated))
}

pub fn overflow_section_size_test() {
  // Section size LEB overflows u32.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x1F],
      ]),
    ),
  )
  |> should.equal(Error(ast.LebOverflow))
}

pub fn section_size_mismatch_test() {
  // Type section size 5, but the functype only consumes 4 bytes, leaving 1.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x05, 0x01, 0x60, 0x00, 0x00, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.SectionSizeMismatch))
}

pub fn section_order_test() {
  // Two type sections: the second's id (1) is not strictly greater.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.SectionOrder))
}

pub fn bad_functype_form_test() {
  // functype must begin with 0x60; here it is 0x61.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x02, 0x01, 0x61],
      ]),
    ),
  )
  |> should.equal(Error(ast.BadFuncTypeForm))
}

pub fn bad_valtype_test() {
  // A param valtype byte 0x00 is not a value type.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x05, 0x01, 0x60, 0x01, 0x00, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.BadValType))
}

pub fn unknown_opcode_test() {
  // Replace the I32Add (0x6A) byte of `add` with 0xD5 (not in the op set).
  decode.decode(bytes(replace(add_fixture, 39, 0xD5)))
  |> should.equal(Error(ast.UnknownOpcode(0xD5)))
}

pub fn bad_export_kind_test() {
  // Replace the export kind byte (index 28, 0x00=func) with 0x05.
  decode.decode(bytes(replace(add_fixture, 28, 0x05)))
  |> should.equal(Error(ast.BadExportKind))
}

pub fn invalid_utf8_name_test() {
  // Replace the first byte of the "add" export name (index 25) with 0xFF, which
  // can never begin a valid UTF-8 sequence.
  decode.decode(bytes(replace(add_fixture, 25, 0xFF)))
  |> should.equal(Error(ast.InvalidUtf8))
}

pub fn func_code_count_mismatch_test() {
  // function section declares 1 function but there is no code section.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x03, 0x02, 0x01, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.FuncCodeCountMismatch))
}

pub fn code_entry_size_mismatch_test() {
  // A code entry whose declared size leaves trailing bytes after the expr's End.
  // body = locals(00) + nop(01) + end(0B) = 3 bytes, but declare size 4 with an
  // extra trailing byte inside the entry.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x03, 0x02, 0x01, 0x00],
        [0x0A, 0x06, 0x01, 0x04, 0x00, 0x01, 0x0B, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.SectionSizeMismatch))
}

// ───────────── fail-closed negative suite: NEW Phase-2 surface ─────────────
// Each malformation of a new section/opcode returns a SPECIFIC typed DecodeError
// (binary/types.html limits/reftype/globaltype; binary/modules.html elem/data;
// binary/instructions.html memarg, memory.size/grow, select_t). Never a panic.

/// Wrap a single non-custom section (its raw bytes) right after the preamble.
fn module_with_section(section: List(Int)) -> List(Int) {
  list.flatten([[0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00], section])
}

pub fn memarg_truncated_test() {
  // i32.load (0x28) with the input ending before its memarg's align LEB.
  decode.decode(bytes(module_with_body([0x28])))
  |> should.equal(Error(ast.Truncated))
}

// Phase 5: memory.size/grow now carry a `u32` memidx (was a reserved 0x00 byte);
// any index decodes (multi-memory). Spec binary/instructions §memory.
pub fn memory_grow_memidx_test() {
  let assert Ok(m) = decode.decode(bytes(module_with_body([0x40, 0x00, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.MemoryGrow(0), ast.End])
}

pub fn memory_size_memidx_test() {
  let assert Ok(m) = decode.decode(bytes(module_with_body([0x3F, 0x00, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.MemorySize(0), ast.End])
}

pub fn bad_limits_flag_test() {
  // Memory section: limits flag 0x02 (shared/threads) is out of scope. (0x04/0x05
  // are now accepted memory64 forms; shared is not — spec/threads proposal.)
  decode.decode(bytes(module_with_section([0x05, 0x02, 0x01, 0x02])))
  |> should.equal(Error(ast.BadLimitsFlag))
}

pub fn table_limits_bad_flag_test() {
  // Table section: a table limits flag with the index-type bit (0x04) is out of
  // scope (table64) → BadLimitsFlag. Section 4, count 1, funcref (0x70), flag 0x04.
  decode.decode(bytes(module_with_section([0x04, 0x03, 0x01, 0x70, 0x04])))
  |> should.equal(Error(ast.BadLimitsFlag))
}

pub fn externref_table_accepted_test() {
  // Table section: element-type byte 0x6F (externref) is now a valid reftype (was
  // BadRefType in Phase 2). Section 4, count 1, externref (0x6F), limits min 1.
  let assert Ok(m) =
    decode.decode(
      bytes(module_with_section([0x04, 0x04, 0x01, 0x6F, 0x00, 0x01])),
    )
  m.tables
  |> should.equal([ast.TableType(ast.ExternRef, ast.Limits(min: 1, max: None))])
}

pub fn bad_heap_type_table_test() {
  // Table section: element-type byte 0x7B (v128, SIMD) is not a reftype →
  // BadHeapType (reftype-only position). Section 4, count 1, byte 0x7B.
  decode.decode(bytes(module_with_section([0x04, 0x02, 0x01, 0x7B])))
  |> should.equal(Error(ast.BadHeapType))
}

pub fn bad_mutability_test() {
  // Global section: i32 global with mut byte 0x02 (not 0x00/0x01).
  decode.decode(bytes(module_with_section([0x06, 0x03, 0x01, 0x7F, 0x02])))
  |> should.equal(Error(ast.BadMutability))
}

pub fn bad_elem_kind_flag_test() {
  // Element section: a leading flag 0x08 is beyond the 0..7 grammar → BadElemKind.
  decode.decode(bytes(module_with_section([0x09, 0x02, 0x01, 0x08])))
  |> should.equal(Error(ast.BadElemKind))
}

pub fn bad_elemkind_byte_test() {
  // Element flag 1 (passive funcidx) with an elemkind byte 0x01 (not 0x00 funcref)
  // → BadElemKind. Section 9, count 1, flag 0x01, elemkind 0x01.
  decode.decode(bytes(module_with_section([0x09, 0x03, 0x01, 0x01, 0x01])))
  |> should.equal(Error(ast.BadElemKind))
}

pub fn bad_data_kind_test() {
  // Data section: a leading flag 0x03 is outside the 0/1/2 grammar → BadDataKind.
  decode.decode(bytes(module_with_section([0x0B, 0x02, 0x01, 0x03])))
  |> should.equal(Error(ast.BadDataKind))
}

pub fn oversized_vec_count_test() {
  // Element section whose funcidx vector declares a ~4-billion count but supplies
  // no entries: the first element read hits EOF → Truncated (no loop, no panic).
  decode.decode(
    bytes(
      module_with_section([
        0x09, 0x0A, 0x01, 0x00, 0x41, 0x00, 0x0B, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F,
      ]),
    ),
  )
  |> should.equal(Error(ast.Truncated))
}

pub fn truncated_data_payload_test() {
  // Data segment (form 0x00, offset i32.const 0) declaring 5 payload bytes but
  // supplying only 2 → Truncated (the byte-vector slice never over-reads).
  decode.decode(
    bytes(
      module_with_section([
        0x0B, 0x08, 0x01, 0x00, 0x41, 0x00, 0x0B, 0x05, 0x68, 0x69,
      ]),
    ),
  )
  |> should.equal(Error(ast.Truncated))
}

// ─────────────────────────── totality / fuzz ───────────────────────────
// The decoder must be TOTAL over untrusted input: every byte sequence yields
// Ok(_) or Error(_), never a crash/panic (overview D4).

/// Forces full evaluation of a decode result and confirms it is a Result value.
fn is_total(r: Result(ast.Module, ast.DecodeError)) -> Bool {
  case r {
    Ok(_) -> True
    Error(_) -> True
  }
}

pub fn fuzz_single_byte_mutations_test() {
  let len = list.length(add_fixture)
  // For every byte position, replace it with every value 0..255 and decode.
  let positions = int_range(0, len - 1)
  let values = int_range(0, 255)
  let all_total =
    list.all(positions, fn(pos) {
      list.all(values, fn(v) {
        is_total(decode.decode(bytes(replace(add_fixture, pos, v))))
      })
    })
  all_total
  |> should.equal(True)
}

pub fn fuzz_truncation_test() {
  // Every prefix of the fixture decodes to a Result (never crashes); the full
  // fixture is Ok and every shorter prefix is an Error.
  let len = list.length(add_fixture)
  let prefixes = int_range(0, len)
  list.all(prefixes, fn(n) {
    let r = decode.decode(bytes(list.take(add_fixture, n)))
    case n == len {
      True -> r == decode.decode(bytes(add_fixture))
      False -> is_total(r) && r != decode.decode(bytes(add_fixture))
    }
  })
  |> should.equal(True)
}

/// Single-byte-mutation totality sweep over an arbitrary fixture (every position
/// × every byte value 0..255 → a Result, never a panic). Shared by the new-surface
/// fuzz tests.
fn sweep_single_byte_mutations(fixture: List(Int)) -> Bool {
  let positions = int_range(0, list.length(fixture) - 1)
  let values = int_range(0, 255)
  list.all(positions, fn(pos) {
    list.all(values, fn(v) {
      is_total(decode.decode(bytes(replace(fixture, pos, v))))
    })
  })
}

pub fn fuzz_mem_fixture_mutations_test() {
  // The memory fixture exercises a new SECTION (5) and new opcodes (load/store +
  // memarg). Every single-byte mutation stays total (fail-closed, never panics).
  sweep_single_byte_mutations(mem_ints)
  |> should.equal(True)
}

pub fn fuzz_conv_fixture_mutations_test() {
  // The conversion fixture exercises the full 0xA7..0xBF block. Every single-byte
  // mutation stays total.
  sweep_single_byte_mutations(conv_ints)
  |> should.equal(True)
}

pub fn fuzz_mem_fixture_truncation_test() {
  // Every prefix of the memory fixture decodes to a Result (never a crash); the
  // full fixture is Ok, every shorter prefix is an Error.
  let len = list.length(mem_ints)
  list.all(int_range(0, len), fn(n) {
    let r = decode.decode(bytes(list.take(mem_ints, n)))
    case n == len {
      True -> r == decode.decode(bytes(mem_ints))
      False -> is_total(r) && r != decode.decode(bytes(mem_ints))
    }
  })
  |> should.equal(True)
}

// ═══════════════════ Phase 5 («WASM-AST3») worked fixtures ═══════════════════
// Each `.wasm` is produced by `wat2wasm --enable-multi-memory --enable-memory64`
// and asserted against the binary-format spec (cited per fixture). Reference types
// and bulk memory are default-on in this wat2wasm; `--enable-all` is deliberately
// AVOIDED (it would turn on the experimental compact-import encoding). Bytes are
// embedded so the suite needs no external tool at run time.

// (global externref (ref.null extern)) — binary/types.html §reftype/globaltype,
// binary/instructions.html §reference (ref.null 0xD0 <heaptype>).
const glob_extern_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x06, 0x06, 0x01, 0x6F, 0x00,
  0xD0, 0x6F, 0x0B,
]

pub fn decode_global_externref_test() {
  let assert Ok(m) = decode.decode(bytes(glob_extern_ints))
  m.globals
  |> should.equal([
    ast.Global(ty: ast.ExternRef, mutable: False, init: [
      ast.RefNull(ast.ExternRef),
    ]),
  ])
}

// (func $f) (global funcref (ref.func $f)) — ref.func (0xD2 <funcidx>).
const glob_funcref_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x06, 0x06, 0x01, 0x70, 0x00, 0xD2, 0x00, 0x0B,
  0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B,
]

pub fn decode_global_funcref_test() {
  let assert Ok(m) = decode.decode(bytes(glob_funcref_ints))
  m.globals
  |> should.equal([
    ast.Global(ty: ast.FuncRef, mutable: False, init: [ast.RefFunc(0)]),
  ])
}

// (table 1 externref) + table.set 0 (0x26) / table.get 0 (0x25).
// binary/types.html §tabletype, binary/instructions.html §table.
const tableops_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60, 0x01,
  0x6F, 0x00, 0x60, 0x00, 0x01, 0x6F, 0x03, 0x03, 0x02, 0x00, 0x01, 0x04, 0x04,
  0x01, 0x6F, 0x00, 0x01, 0x0A, 0x11, 0x02, 0x08, 0x00, 0x41, 0x00, 0x20, 0x00,
  0x26, 0x00, 0x0B, 0x06, 0x00, 0x41, 0x00, 0x25, 0x00, 0x0B,
]

pub fn decode_externref_table_and_table_get_set_test() {
  let assert Ok(m) = decode.decode(bytes(tableops_ints))
  m.tables
  |> should.equal([ast.TableType(ast.ExternRef, ast.Limits(min: 1, max: None))])
  let assert [setter, getter] = m.funcs
  setter.body
  |> should.equal([
    ast.I32Const(0),
    ast.LocalGet(0),
    ast.TableSet(0),
    ast.End,
  ])
  getter.body
  |> should.equal([ast.I32Const(0), ast.TableGet(0), ast.End])
}

// ref.null func (0xD0 0x70), ref.is_null (0xD1), ref.func $f (0xD2).
const ref_instrs_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0C, 0x03, 0x60, 0x00,
  0x00, 0x60, 0x00, 0x01, 0x7F, 0x60, 0x00, 0x01, 0x70, 0x03, 0x04, 0x03, 0x00,
  0x01, 0x02, 0x0A, 0x0F, 0x03, 0x02, 0x00, 0x0B, 0x05, 0x00, 0xD0, 0x70, 0xD1,
  0x0B, 0x04, 0x00, 0xD2, 0x00, 0x0B,
]

pub fn decode_reference_instructions_test() {
  let assert Ok(m) = decode.decode(bytes(ref_instrs_ints))
  let assert [_f, isnull, reffunc] = m.funcs
  isnull.body
  |> should.equal([ast.RefNull(ast.FuncRef), ast.RefIsNull, ast.End])
  reffunc.body
  |> should.equal([ast.RefFunc(0), ast.End])
}

// select (result i32) — typed select 0x1C with a one-element valtype vector.
// binary/instructions.html §parametric.
const select_t_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x01, 0x60, 0x03,
  0x7F, 0x7F, 0x7F, 0x01, 0x7F, 0x03, 0x02, 0x01, 0x00, 0x0A, 0x0D, 0x01, 0x0B,
  0x00, 0x20, 0x00, 0x20, 0x01, 0x20, 0x02, 0x1C, 0x01, 0x7F, 0x0B,
]

pub fn decode_typed_select_test() {
  let assert Ok(m) = decode.decode(bytes(select_t_ints))
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.LocalGet(0),
    ast.LocalGet(1),
    ast.LocalGet(2),
    ast.SelectT([ast.I32]),
    ast.End,
  ])
}

pub fn decode_untyped_select_still_test() {
  // The untyped `select` (0x1B) still decodes to the nullary `Select`.
  let assert Ok(m) = decode.decode(bytes(module_with_body([0x1B, 0x0B])))
  let assert [func] = m.funcs
  func.body
  |> should.equal([ast.Select, ast.End])
}

// (memory 1) + two passive data + memory.init/data.drop/memory.copy/memory.fill.
// binary/instructions.html §bulk; datacount section (id 12) present.
// ANTI-SWAP (R3): memory.init here is `FC 08 01 00` = dataidx 1 THEN memidx 0, so
// the decode MUST be MemoryInit(data: 1, mem: 0). A field swap would give data 0.
const mem_bulk_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x0C, 0x01, 0x02,
  0x0A, 0x24, 0x01, 0x22, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x02, 0xFC, 0x08,
  0x01, 0x00, 0xFC, 0x09, 0x00, 0x41, 0x00, 0x41, 0x04, 0x41, 0x02, 0xFC, 0x0A,
  0x00, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x04, 0xFC, 0x0B, 0x00, 0x0B, 0x0B,
  0x09, 0x02, 0x01, 0x02, 0x68, 0x69, 0x01, 0x02, 0x79, 0x6F,
]

pub fn decode_memory_bulk_ops_test() {
  let assert Ok(m) = decode.decode(bytes(mem_bulk_ints))
  // datacount == length(data) == 2; both data segments passive.
  m.data_count
  |> should.equal(Some(2))
  m.data
  |> should.equal([
    ast.DataSegment(ast.DataPassive, <<0x68, 0x69>>),
    ast.DataSegment(ast.DataPassive, <<0x79, 0x6F>>),
  ])
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.I32Const(0),
    ast.I32Const(0),
    ast.I32Const(2),
    // ANTI-SWAP: dataidx(1) decoded first, memidx(0) second.
    ast.MemoryInit(data: 1, mem: 0),
    ast.DataDrop(0),
    ast.I32Const(0),
    ast.I32Const(4),
    ast.I32Const(2),
    ast.MemoryCopy(dst_mem: 0, src_mem: 0),
    ast.I32Const(0),
    ast.I32Const(0),
    ast.I32Const(4),
    ast.MemoryFill(0),
    ast.End,
  ])
}

// Two funcref tables + one passive elem + the six table ops.
// ANTI-SWAP (R3): table.init here is `FC 0C 00 01` = elemidx 0 THEN tableidx 1, so
// the decode MUST be TableInit(elem: 0, table: 1). table.copy `FC 0E 00 01` is
// dst-table 0 THEN src-table 1 → TableCopy(dst_table: 0, src_table: 1).
const table_bulk_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04, 0x07, 0x02, 0x70, 0x00, 0x01, 0x70,
  0x00, 0x02, 0x09, 0x05, 0x01, 0x01, 0x00, 0x01, 0x00, 0x0A, 0x33, 0x02, 0x02,
  0x00, 0x0B, 0x2E, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xFC, 0x0C, 0x00,
  0x01, 0xFC, 0x0D, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xFC, 0x0E, 0x00,
  0x01, 0xD0, 0x70, 0x41, 0x01, 0xFC, 0x0F, 0x00, 0x1A, 0xFC, 0x10, 0x00, 0x1A,
  0x41, 0x00, 0xD0, 0x70, 0x41, 0x00, 0xFC, 0x11, 0x00, 0x0B,
]

pub fn decode_table_bulk_ops_test() {
  let assert Ok(m) = decode.decode(bytes(table_bulk_ints))
  m.tables
  |> should.equal([
    ast.TableType(ast.FuncRef, ast.Limits(min: 1, max: None)),
    ast.TableType(ast.FuncRef, ast.Limits(min: 2, max: None)),
  ])
  // Passive funcidx element segment.
  m.elements
  |> should.equal([
    ast.ElementSegment(ast.ElemPassive, ast.FuncRef, ast.ElemFuncs([0])),
  ])
  let assert [_f, ops] = m.funcs
  ops.body
  |> should.equal([
    ast.I32Const(0),
    ast.I32Const(0),
    ast.I32Const(0),
    // ANTI-SWAP: elemidx(0) decoded first, tableidx(1) second.
    ast.TableInit(elem: 0, table: 1),
    ast.ElemDrop(0),
    ast.I32Const(0),
    ast.I32Const(0),
    ast.I32Const(0),
    ast.TableCopy(dst_table: 0, src_table: 1),
    ast.RefNull(ast.FuncRef),
    ast.I32Const(1),
    ast.TableGrow(0),
    ast.Drop,
    ast.TableSize(0),
    ast.Drop,
    ast.I32Const(0),
    ast.RefNull(ast.FuncRef),
    ast.I32Const(0),
    ast.TableFill(0),
    ast.End,
  ])
}

// (memory 1)(memory 1) + i32.store into memory 1 — the bit-6 memarg memidx.
// The store's flags byte is 0x42 (bit 6 set): align = 0x42 ^ 0x40 = 2, memidx 1.
const multimem_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x05, 0x02, 0x00, 0x01, 0x00, 0x01, 0x0A,
  0x0C, 0x01, 0x0A, 0x00, 0x41, 0x00, 0x41, 0x2A, 0x36, 0x42, 0x01, 0x00, 0x0B,
]

pub fn decode_multi_memory_memarg_test() {
  let assert Ok(m) = decode.decode(bytes(multimem_ints))
  // Two memories declared (section 5).
  list.length(m.memories)
  |> should.equal(2)
  let assert [func] = m.funcs
  func.body
  |> should.equal([
    ast.I32Const(0),
    ast.I32Const(42),
    ast.I32Store(ast.MemArg(align: 2, offset: 0, mem: 1)),
    ast.End,
  ])
}

// (memory i64 1) — memory64 limits flag 0x04 → Idx64. binary/types.html §limits.
const mem64_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x05, 0x03, 0x01, 0x04, 0x01,
]

pub fn decode_memory64_test() {
  let assert Ok(m) = decode.decode(bytes(mem64_ints))
  m.memories
  |> should.equal([ast.MemType(ast.Limits(min: 1, max: None), ast.Idx64)])
}

pub fn decode_memory32_idx_type_test() {
  // An i32 memory decodes Idx32 (neutrality): (memory 1) flag 0x00.
  let assert Ok(m) = decode.decode(bytes(mem_ints))
  m.memories
  |> should.equal([ast.MemType(ast.Limits(min: 1, max: None), ast.Idx32)])
}

// Element-segment flag grammar (binary/modules.html §element-section).
const elem_passive_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x09, 0x05, 0x01, 0x01, 0x00, 0x01, 0x00, 0x0A,
  0x04, 0x01, 0x02, 0x00, 0x0B,
]

const elem_declarative_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x09, 0x05, 0x01, 0x03, 0x00, 0x01, 0x00, 0x0A,
  0x04, 0x01, 0x02, 0x00, 0x0B,
]

const elem_flag2_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x04, 0x07, 0x02, 0x70, 0x00, 0x01, 0x70, 0x00,
  0x01, 0x09, 0x09, 0x01, 0x02, 0x01, 0x41, 0x00, 0x0B, 0x00, 0x01, 0x00, 0x0A,
  0x04, 0x01, 0x02, 0x00, 0x0B,
]

const elem_flag4_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00, 0x01, 0x09, 0x0C,
  0x01, 0x04, 0x41, 0x00, 0x0B, 0x02, 0xD2, 0x00, 0x0B, 0xD0, 0x70, 0x0B, 0x0A,
  0x04, 0x01, 0x02, 0x00, 0x0B,
]

const elem_flag5_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x09, 0x07, 0x01, 0x05, 0x6F,
  0x01, 0xD0, 0x6F, 0x0B,
]

const elem_flag6_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x04, 0x07, 0x02, 0x70, 0x00, 0x01, 0x70, 0x00,
  0x01, 0x09, 0x0B, 0x01, 0x06, 0x01, 0x41, 0x00, 0x0B, 0x70, 0x01, 0xD0, 0x70,
  0x0B, 0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B,
]

pub fn decode_element_flag1_passive_funcidx_test() {
  let assert Ok(m) = decode.decode(bytes(elem_passive_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(ast.ElemPassive, ast.FuncRef, ast.ElemFuncs([0])),
  ])
}

pub fn decode_element_flag3_declarative_test() {
  let assert Ok(m) = decode.decode(bytes(elem_declarative_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(ast.ElemDeclarative, ast.FuncRef, ast.ElemFuncs([0])),
  ])
}

pub fn decode_element_flag2_active_tableidx_funcidx_test() {
  // Flag 2: active into an EXPLICIT table index (1) via a funcidx list.
  let assert Ok(m) = decode.decode(bytes(elem_flag2_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemActive(1, [ast.I32Const(0)]),
      ast.FuncRef,
      ast.ElemFuncs([0]),
    ),
  ])
}

pub fn decode_element_flag4_active_expr_test() {
  // Flag 4: active into table 0 with an EXPRESSION-list init (ref.func / ref.null).
  let assert Ok(m) = decode.decode(bytes(elem_flag4_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemActive(0, [ast.I32Const(0)]),
      ast.FuncRef,
      ast.ElemExprs([[ast.RefFunc(0)], [ast.RefNull(ast.FuncRef)]]),
    ),
  ])
}

pub fn decode_element_flag5_passive_externref_expr_test() {
  // Flag 5: passive, EXPLICIT reftype (externref), expression init.
  let assert Ok(m) = decode.decode(bytes(elem_flag5_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemPassive,
      ast.ExternRef,
      ast.ElemExprs([[ast.RefNull(ast.ExternRef)]]),
    ),
  ])
}

pub fn decode_element_flag6_active_tableidx_expr_test() {
  // Flag 6: active into an explicit table index (1), reftype + expression init.
  let assert Ok(m) = decode.decode(bytes(elem_flag6_ints))
  m.elements
  |> should.equal([
    ast.ElementSegment(
      ast.ElemActive(1, [ast.I32Const(0)]),
      ast.FuncRef,
      ast.ElemExprs([[ast.RefNull(ast.FuncRef)]]),
    ),
  ])
}

// Data-segment flag grammar (binary/modules.html §data-section).
const data_passive_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x0C, 0x01, 0x01,
  0x0A, 0x07, 0x01, 0x05, 0x00, 0xFC, 0x09, 0x00, 0x0B, 0x0B, 0x05, 0x01, 0x01,
  0x02, 0x78, 0x78,
]

const data_active_memidx_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x05, 0x05, 0x02, 0x00, 0x01,
  0x00, 0x01, 0x0B, 0x09, 0x01, 0x02, 0x01, 0x41, 0x00, 0x0B, 0x02, 0x68, 0x69,
]

pub fn decode_data_flag1_passive_test() {
  // Passive data (flag 1) + a datacount section (count 1) + a data.drop.
  let assert Ok(m) = decode.decode(bytes(data_passive_ints))
  m.data_count
  |> should.equal(Some(1))
  m.data
  |> should.equal([ast.DataSegment(ast.DataPassive, <<0x78, 0x78>>)])
}

pub fn decode_data_flag2_active_memidx_test() {
  // Flag 2: active into an EXPLICIT memory index (1, multi-memory), offset i32 0.
  let assert Ok(m) = decode.decode(bytes(data_active_memidx_ints))
  list.length(m.memories)
  |> should.equal(2)
  m.data
  |> should.equal([
    ast.DataSegment(ast.DataActive(1, [ast.I32Const(0)]), <<0x68, 0x69>>),
  ])
}

// Non-function imports (binary/modules.html §import-section): func/global/table/mem.
const imports_ints: List(Int) = [
  0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x02, 0x1F, 0x04, 0x01, 0x6D, 0x01, 0x66, 0x00, 0x00, 0x01, 0x6D, 0x01,
  0x67, 0x03, 0x7F, 0x00, 0x01, 0x6D, 0x01, 0x74, 0x01, 0x70, 0x00, 0x01, 0x01,
  0x6D, 0x03, 0x6D, 0x65, 0x6D, 0x02, 0x00, 0x01,
]

pub fn decode_non_function_imports_test() {
  let assert Ok(m) = decode.decode(bytes(imports_ints))
  m.imports
  |> should.equal([
    ast.Import("m", "f", ast.ImportFunc(0)),
    ast.Import("m", "g", ast.ImportGlobal(ast.I32, False)),
    ast.Import(
      "m",
      "t",
      ast.ImportTable(ast.TableType(ast.FuncRef, ast.Limits(min: 1, max: None))),
    ),
    ast.Import(
      "m",
      "mem",
      ast.ImportMemory(ast.MemType(ast.Limits(min: 1, max: None), ast.Idx32)),
    ),
  ])
  // imported_func_count is COMPUTED = number of func imports (1 of 4).
  m.imported_func_count
  |> should.equal(1)
}

pub fn decode_import_section_neutral_func_count_test() {
  // Neutrality: a module with NO import section keeps imported_func_count == 0.
  let assert Ok(m) = decode.decode(bytes(add_fixture))
  m.imported_func_count
  |> should.equal(0)
}

// ═══════════════════ Phase 5: fail-closed negative suite ═══════════════════
// Each malformation of the NEW surface returns a SPECIFIC typed DecodeError, never
// a panic/loop. Spec: binary/types.html, binary/instructions.html, §5.5.14.

pub fn ref_null_bad_heaptype_test() {
  // ref.null with a heaptype byte 0x7F (i32, not a reftype) → BadHeapType.
  decode.decode(bytes(module_with_body([0xD0, 0x7F, 0x0B])))
  |> should.equal(Error(ast.BadHeapType))
}

pub fn bulk_unknown_sub_opcode_test() {
  // A 0xFC sub-opcode 18 is outside the 0..17 range → UnknownSatOpcode(18).
  decode.decode(bytes(module_with_body([0xFC, 0x12, 0x0B])))
  |> should.equal(Error(ast.UnknownSatOpcode(18)))
}

pub fn memory_init_truncated_test() {
  // memory.init with dataidx present but memidx at EOF → Truncated.
  decode.decode(bytes(module_with_body([0xFC, 0x08, 0x00])))
  |> should.equal(Error(ast.Truncated))
}

pub fn memarg_memidx_truncated_test() {
  // i32.load whose memarg flags set bit 6 (0x42) but the memidx LEB is missing.
  decode.decode(bytes(module_with_body([0x28, 0x42])))
  |> should.equal(Error(ast.Truncated))
}

pub fn bad_import_kind_test() {
  // importdesc kind byte 0x04 (not 0x00..0x03) → BadImportKind. Import "a" "b" 0x04.
  decode.decode(
    bytes(module_with_section([0x02, 0x06, 0x01, 0x01, 0x61, 0x01, 0x62, 0x04])),
  )
  |> should.equal(Error(ast.BadImportKind))
}

pub fn select_t_overrun_test() {
  // A typed-select vec count of ~4 billion with no valtypes → Truncated (no loop).
  decode.decode(bytes(module_with_body([0x1C, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F])))
  |> should.equal(Error(ast.Truncated))
}

pub fn datacount_missing_test() {
  // R13 / spec §5.5.14: memory.init present but NO datacount section → malformed.
  decode.decode(bytes(module_with_body([0xFC, 0x08, 0x00, 0x00, 0x0B])))
  |> should.equal(Error(ast.DataCountMissing))
}

pub fn data_drop_missing_datacount_test() {
  // R13: data.drop also requires a datacount section.
  decode.decode(bytes(module_with_body([0xFC, 0x09, 0x00, 0x0B])))
  |> should.equal(Error(ast.DataCountMissing))
}

pub fn datacount_mismatch_test() {
  // spec §5.5.14: a datacount section (count 1) with NO data section (length 0) is
  // malformed. type + func + datacount(1) + code, no data section.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x03, 0x02, 0x01, 0x00],
        [0x0C, 0x01, 0x01],
        [0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B],
      ]),
    ),
  )
  |> should.equal(Error(ast.DataCountMismatch))
}

pub fn datacount_after_code_section_order_test() {
  // The datacount section (12) must precede code (10); placed AFTER code its
  // canonical rank (10) is <= code's rank (11) → SectionOrder.
  decode.decode(
    bytes(
      list.flatten([
        [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00],
        [0x01, 0x04, 0x01, 0x60, 0x00, 0x00],
        [0x03, 0x02, 0x01, 0x00],
        [0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B],
        [0x0C, 0x01, 0x00],
      ]),
    ),
  )
  |> should.equal(Error(ast.SectionOrder))
}

// ═══════════════════ Phase 5: totality sweeps over new fixtures ═══════════════════
// Every single-byte mutation and every truncation of a new-surface fixture yields a
// Result (never a crash). The property is TOTALITY (overview D4/H6).

pub fn fuzz_new_surface_mutations_test() {
  [
    glob_extern_ints,
    tableops_ints,
    ref_instrs_ints,
    select_t_ints,
    mem_bulk_ints,
    table_bulk_ints,
    multimem_ints,
    elem_flag4_ints,
    data_passive_ints,
    imports_ints,
  ]
  |> list.all(sweep_single_byte_mutations)
  |> should.equal(True)
}

pub fn fuzz_new_surface_truncation_test() {
  [mem_bulk_ints, table_bulk_ints, imports_ints, elem_flag4_ints]
  |> list.all(fn(fixture) {
    let full = decode.decode(bytes(fixture))
    let len = list.length(fixture)
    list.all(int_range(0, len), fn(n) {
      let r = decode.decode(bytes(list.take(fixture, n)))
      case n == len {
        True -> r == full
        False -> is_total(r) && r != full
      }
    })
  })
  |> should.equal(True)
}

// The decoder must contain no partial constructs (D4/H6): no `let assert`, `panic`,
// or `todo` is reachable from untrusted input. We assert their textual absence in the
// CODE (comment-only lines, which may name them in prose, are stripped first).
pub fn decode_has_no_partial_constructs_test() {
  let assert Ok(src) = simplifile.read("src/twocore/frontend/wasm/decode.gleam")
  let code =
    src
    |> string.split("\n")
    |> list.filter(fn(line) {
      !string.starts_with(string.trim_start(line), "//")
    })
    |> string.join("\n")
  string.contains(code, "let assert")
  |> should.equal(False)
  string.contains(code, "panic")
  |> should.equal(False)
  string.contains(code, "todo")
  |> should.equal(False)
}
