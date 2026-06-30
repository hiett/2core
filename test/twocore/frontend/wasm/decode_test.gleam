//// Spec-based tests for `twocore/frontend/wasm/decode` (Unit 05).
////
//// Assertions target the WebAssembly core spec's BINARY FORMAT, not whatever the
//// implementation happens to emit:
////  - integers/LEB128: https://webassembly.github.io/spec/core/binary/values.html#integers
////  - modules/sections: https://webassembly.github.io/spec/core/binary/modules.html
////  - types:            https://webassembly.github.io/spec/core/binary/types.html
////  - instructions:     https://webassembly.github.io/spec/core/binary/instructions.html
////
//// The `.wasm` fixtures (`add` hand-derived from the unit doc; `sum_to`/`abs`/
//// `fib`/`mv` produced by `wat2wasm`) are embedded as byte literals so the suite
//// needs no external tool at run time. The fail-closed suite proves every
//// malformation yields a typed `DecodeError` (never a panic) and the fuzz test
//// proves TOTALITY over single-byte mutations of the `add` fixture.

import gleam/list
import gleeunit/should
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
        funcs: [
          ast.Func(type_idx: 0, locals: [], body: [
            ast.LocalGet(0),
            ast.LocalGet(1),
            ast.I32Add,
            ast.End,
          ]),
        ],
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
  // 0xFC sub-opcode 8 is outside 0..7.
  decode.decode(bytes(module_with_body([0xFC, 0x08, 0x0B])))
  |> should.equal(Error(ast.UnknownSatOpcode(8)))
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

pub fn skip_out_of_scope_section_test() {
  // Insert a global section (id 6, size 2) between the function(3) and
  // export(7) sections — ascending order holds and it is safely skipped.
  // add_fixture: preamble(8) + type(9) + function(4) = 21 bytes before export.
  let with_global =
    list.flatten([
      list.take(add_fixture, 21),
      [0x06, 0x02, 0x00, 0x00],
      list.drop(add_fixture, 21),
    ])
  decode.decode(bytes(with_global))
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
