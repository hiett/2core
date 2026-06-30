//// The WebAssembly 1.0 binary decoder (the Phase-1 slice) — turns an untrusted
//// `BitArray` of `.wasm` bytes into the `twocore/frontend/wasm/ast` model.
////
//// THREAT MODEL: the input is attacker-controlled. Every function in this module
//// is total over arbitrary bytes — any malformation returns a typed
//// `DecodeError`, and there are NO `let assert`/`panic`/partial matches reachable
//// from untrusted input (overview D4, D5). LEB128 numbers are validated against
//// the spec's width bounds (no silent wraparound).
////
//// Scope: preamble, the type(1), function(3), export(7) and code(10) sections.
//// Custom(0) and every other section are SKIPPED safely via their declared size.
//// Lowering/validation are Unit 10; this module only decodes.
////
//// The decoder uses Gleam's (Erlang-target) bit syntax throughout, so this
//// module is Erlang-target-only. Spec references are cited inline.
////
//// Spec:
////  - modules:      https://webassembly.github.io/spec/core/binary/modules.html
////  - types:        https://webassembly.github.io/spec/core/binary/types.html
////  - instructions: https://webassembly.github.io/spec/core/binary/instructions.html
////  - values:       https://webassembly.github.io/spec/core/binary/values.html

import gleam/bit_array
import gleam/list
import gleam/result
import twocore/frontend/wasm/ast.{
  type BlockType, type Export, type Func, type FuncType, type Instr, type Module,
  type ValType,
}

// ---------------------------------------------------------------------------
// LEB128 primitives (sub-task A)
// ---------------------------------------------------------------------------

/// Decode one unsigned LEB128 integer of `width` bits from the front of `bytes`.
///
/// `width` is the number of value bits (e.g. `32` or `64`). The encoding is
/// little-endian base-128 with bit 7 of each byte the continuation flag.
///
/// Returns `Ok(#(value, rest))` where `value` is in `[0, 2^width)` and `rest` is
/// the unconsumed tail. Failure modes:
///  - `Error(ast.LebTooLong)`   — more than `ceil(width/7)` bytes are used;
///  - `Error(ast.LebOverflow)`  — the terminal byte sets bits above `width`;
///  - `Error(ast.Truncated)`    — the input ends mid-number.
/// Per the spec's integer grammar the terminal byte must satisfy
/// `n < 2^(remaining width)`; these two rejections are exactly that bound.
pub fn decode_u_n(
  bytes: BitArray,
  width: Int,
) -> Result(#(Int, BitArray), ast.DecodeError) {
  decode_u_go(bytes, width)
}

fn decode_u_go(
  bytes: BitArray,
  remaining: Int,
) -> Result(#(Int, BitArray), ast.DecodeError) {
  case bytes {
    <<byte:8, rest:bytes>> -> {
      let continues = byte >= 0x80
      let data = byte % 0x80
      case continues {
        True ->
          // Another byte follows; the width must still have room (> 7 bits).
          case remaining > 7 {
            True ->
              case decode_u_go(rest, remaining - 7) {
                Ok(#(higher, tail)) -> Ok(#(data + higher * 0x80, tail))
                Error(e) -> Error(e)
              }
            False -> Error(ast.LebTooLong)
          }
        False ->
          // Terminal byte: its 7 data bits must fit the remaining width.
          case remaining >= 7 || data < two_pow(remaining) {
            True -> Ok(#(data, rest))
            False -> Error(ast.LebOverflow)
          }
      }
    }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one signed LEB128 integer of `width` bits (two's-complement) from the
/// front of `bytes`, sign-extended from the terminal byte's bit 6.
///
/// Returns `Ok(#(value, rest))` with `value` in `[-2^(width-1), 2^(width-1))`.
/// Failure modes mirror `decode_u_n`, except the OVERFLOW check is that the
/// terminal byte's unused bits must ALL equal the sign bit (else
/// `Error(ast.LebOverflow)`). Used with `width = 32` for `i32.const`, `64` for
/// `i64.const`, and `33` for blocktypes.
pub fn decode_s_n(
  bytes: BitArray,
  width: Int,
) -> Result(#(Int, BitArray), ast.DecodeError) {
  decode_s_go(bytes, width)
}

fn decode_s_go(
  bytes: BitArray,
  remaining: Int,
) -> Result(#(Int, BitArray), ast.DecodeError) {
  case bytes {
    <<byte:8, rest:bytes>> -> {
      let continues = byte >= 0x80
      let data = byte % 0x80
      case continues {
        True ->
          case remaining > 7 {
            True ->
              case decode_s_go(rest, remaining - 7) {
                Ok(#(higher, tail)) -> Ok(#(data + higher * 0x80, tail))
                Error(e) -> Error(e)
              }
            False -> Error(ast.LebTooLong)
          }
        False -> {
          // Terminal byte (`data` in 0..127). Bit 6 is the sign.
          let negative = data >= 0x40
          case negative {
            False ->
              // Non-negative: unused high bits must be 0.
              case remaining >= 7 || data < two_pow(remaining - 1) {
                True -> Ok(#(data, rest))
                False -> Error(ast.LebOverflow)
              }
            True ->
              // Negative: unused high bits must be 1 (i.e. equal the sign).
              case remaining >= 7 || data >= 0x80 - two_pow(remaining - 1) {
                True -> Ok(#(data - 0x80, rest))
                False -> Error(ast.LebOverflow)
              }
          }
        }
      }
    }
    _ -> Error(ast.Truncated)
  }
}

/// `2^n` for small non-negative `n` (a total helper used by the LEB width
/// bounds). Returns `1` for `n <= 0`.
fn two_pow(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * two_pow(n - 1)
  }
}

// ---------------------------------------------------------------------------
// Module / section framing (sub-task B)
// ---------------------------------------------------------------------------

/// Mutable-free accumulator threaded through the section loop. Each field is
/// filled by at most one section (sections are strictly ascending, so no
/// duplicates). `func_type_idxs` (from the function section) and `codes` (from
/// the code section) are paired into `Func`s once decoding finishes.
type DecodeState {
  DecodeState(
    types: List(FuncType),
    func_type_idxs: List(Int),
    exports: List(Export),
    codes: List(#(List(ValType), List(Instr))),
  )
}

fn empty_state() -> DecodeState {
  DecodeState(types: [], func_type_idxs: [], exports: [], codes: [])
}

/// Decode a complete `.wasm` binary into the AST.
///
/// Returns `Ok(module)` iff `bytes` is a well-formed Phase-1 module; otherwise
/// `Error(_)` with the specific reason. Never panics on any input.
///
/// Steps (spec module grammar `magic version section*`):
///  1. match the preamble (`BadMagic`/`BadVersion`/`Truncated` otherwise);
///  2. decode sections in order, each `[id][u32 size][contents]`, honoring the
///     size to slice/skip; enforce strictly-ascending non-custom ids;
///  3. pair the function and code sections into `Func`s.
pub fn decode(bytes: BitArray) -> Result(Module, ast.DecodeError) {
  case bytes {
    <<m0:8, m1:8, m2:8, m3:8, after_magic:bytes>> ->
      case m0, m1, m2, m3 {
        0x00, 0x61, 0x73, 0x6D -> decode_after_magic(after_magic)
        _, _, _, _ -> Error(ast.BadMagic)
      }
    _ -> Error(ast.BadMagic)
  }
}

fn decode_after_magic(bytes: BitArray) -> Result(Module, ast.DecodeError) {
  case bytes {
    <<v0:8, v1:8, v2:8, v3:8, body:bytes>> ->
      case v0, v1, v2, v3 {
        0x01, 0x00, 0x00, 0x00 -> {
          use state <- result.try(decode_sections(body, 0, empty_state()))
          assemble(state)
        }
        _, _, _, _ -> Error(ast.BadVersion)
      }
    // Magic present but fewer than 4 version bytes.
    _ -> Error(ast.Truncated)
  }
}

/// The section loop. `last_id` is the id of the most recent NON-custom section
/// (`0` before any). Custom(0) sections may appear anywhere/any number of times
/// and are dropped without affecting `last_id`. Reaching an empty input ends the
/// module cleanly.
fn decode_sections(
  bytes: BitArray,
  last_id: Int,
  state: DecodeState,
) -> Result(DecodeState, ast.DecodeError) {
  case bytes {
    <<>> -> Ok(state)
    <<id:8, after_id:bytes>> -> {
      use #(size, after_size) <- result.try(decode_u_n(after_id, 32))
      case after_size {
        <<contents:size(size)-bytes, tail:bytes>> ->
          case id == 0 {
            // Custom section: skip, keep last_id.
            True -> decode_sections(tail, last_id, state)
            False ->
              case id <= last_id {
                True -> Error(ast.SectionOrder)
                False -> {
                  use next <- result.try(dispatch_section(id, contents, state))
                  decode_sections(tail, id, next)
                }
              }
          }
        // Declared size exceeds the remaining bytes.
        _ -> Error(ast.Truncated)
      }
    }
    // Unreachable for byte-aligned input; kept for totality.
    _ -> Error(ast.Truncated)
  }
}

/// Run the sub-decoder for a known in-scope section over its exact `contents`
/// slice, asserting full consumption (`SectionSizeMismatch` on under-run). Known
/// out-of-scope sections (import/table/memory/global/start/element/data) are
/// skipped by discarding `contents`.
fn dispatch_section(
  id: Int,
  contents: BitArray,
  state: DecodeState,
) -> Result(DecodeState, ast.DecodeError) {
  case id {
    // type section
    1 -> {
      use #(types, rest) <- result.try(decode_vec(contents, decode_functype))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, types: types))
    }
    // function section: vec(typeidx)
    3 -> {
      use #(idxs, rest) <- result.try(
        decode_vec(contents, fn(b) { decode_u_n(b, 32) }),
      )
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, func_type_idxs: idxs))
    }
    // export section
    7 -> {
      use #(exports, rest) <- result.try(decode_vec(contents, decode_export))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, exports: exports))
    }
    // code section
    10 -> {
      use #(codes, rest) <- result.try(decode_vec(contents, decode_code))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, codes: codes))
    }
    // import(2) table(4) memory(5) global(6) start(8) element(9) data(11):
    // out of scope for Phase 1 — already sliced by the caller, so just drop.
    _ -> Ok(state)
  }
}

/// `Ok(Nil)` iff `bytes` is empty, else `Error(ast.SectionSizeMismatch)`. Used to
/// assert a section sub-decoder consumed exactly its slice.
fn expect_empty(bytes: BitArray) -> Result(Nil, ast.DecodeError) {
  case bytes {
    <<>> -> Ok(Nil)
    _ -> Error(ast.SectionSizeMismatch)
  }
}

/// Pair the function section's type indices with the code section's bodies into
/// `Func`s, then build the `Module`. `Error(ast.FuncCodeCountMismatch)` if the two
/// vectors differ in length (the spec requires them equal).
fn assemble(state: DecodeState) -> Result(Module, ast.DecodeError) {
  use funcs <- result.try(zip_funcs(state.func_type_idxs, state.codes))
  Ok(ast.Module(
    imported_func_count: 0,
    types: state.types,
    funcs: funcs,
    exports: state.exports,
  ))
}

fn zip_funcs(
  idxs: List(Int),
  codes: List(#(List(ValType), List(Instr))),
) -> Result(List(Func), ast.DecodeError) {
  case idxs, codes {
    [], [] -> Ok([])
    [ti, ..ts], [#(locals, body), ..cs] -> {
      use rest <- result.try(zip_funcs(ts, cs))
      Ok([ast.Func(type_idx: ti, locals: locals, body: body), ..rest])
    }
    _, _ -> Error(ast.FuncCodeCountMismatch)
  }
}

// ---------------------------------------------------------------------------
// Generic vector + leaf decoders
// ---------------------------------------------------------------------------

/// Decode a spec vector `vec(X) = [u32 count][X…]`: a `u32` element count
/// followed by that many `elem`-decoded items. Returns the items in order plus
/// the unconsumed tail. Propagates any `elem`/count error.
fn decode_vec(
  bytes: BitArray,
  elem: fn(BitArray) -> Result(#(a, BitArray), ast.DecodeError),
) -> Result(#(List(a), BitArray), ast.DecodeError) {
  use #(count, rest) <- result.try(decode_u_n(bytes, 32))
  decode_vec_n(rest, count, elem, [])
}

fn decode_vec_n(
  bytes: BitArray,
  remaining: Int,
  elem: fn(BitArray) -> Result(#(a, BitArray), ast.DecodeError),
  acc: List(a),
) -> Result(#(List(a), BitArray), ast.DecodeError) {
  case remaining <= 0 {
    True -> Ok(#(list.reverse(acc), bytes))
    False -> {
      use #(item, rest) <- result.try(elem(bytes))
      decode_vec_n(rest, remaining - 1, elem, [item, ..acc])
    }
  }
}

/// Decode one value type byte: `0x7F→I32 0x7E→I64 0x7D→F32 0x7C→F64`. Any other
/// byte is `Error(ast.BadValType)`; empty input is `Error(ast.Truncated)`.
fn decode_valtype(
  bytes: BitArray,
) -> Result(#(ValType, BitArray), ast.DecodeError) {
  case bytes {
    <<b:8, rest:bytes>> ->
      case b {
        0x7F -> Ok(#(ast.I32, rest))
        0x7E -> Ok(#(ast.I64, rest))
        0x7D -> Ok(#(ast.F32, rest))
        0x7C -> Ok(#(ast.F64, rest))
        _ -> Error(ast.BadValType)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one function type `0x60 vec(valtype) vec(valtype)`. `Error(
/// ast.BadFuncTypeForm)` if the leading tag is not `0x60`.
fn decode_functype(
  bytes: BitArray,
) -> Result(#(FuncType, BitArray), ast.DecodeError) {
  case bytes {
    <<b:8, after_tag:bytes>> ->
      case b {
        0x60 -> {
          use #(params, r1) <- result.try(decode_vec(after_tag, decode_valtype))
          use #(results, r2) <- result.try(decode_vec(r1, decode_valtype))
          Ok(#(ast.FuncType(params: params, results: results), r2))
        }
        _ -> Error(ast.BadFuncTypeForm)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode a length-prefixed UTF-8 name `[u32 len][len bytes]`. The bytes are NOT
/// null-terminated and MUST be valid UTF-8 (`Error(ast.InvalidUtf8)` otherwise).
fn decode_name(
  bytes: BitArray,
) -> Result(#(String, BitArray), ast.DecodeError) {
  use #(len, after_len) <- result.try(decode_u_n(bytes, 32))
  case after_len {
    <<raw:size(len)-bytes, rest:bytes>> ->
      case bit_array.to_string(raw) {
        Ok(s) -> Ok(#(s, rest))
        Error(_) -> Error(ast.InvalidUtf8)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one export `[name][kind:8][idx u32]`. Kind byte `0x00`..`0x03` maps to
/// the four `ExportKind`s; anything else is `Error(ast.BadExportKind)`.
fn decode_export(
  bytes: BitArray,
) -> Result(#(Export, BitArray), ast.DecodeError) {
  use #(name, after_name) <- result.try(decode_name(bytes))
  case after_name {
    <<kind_byte:8, after_kind:bytes>> -> {
      use kind <- result.try(case kind_byte {
        0x00 -> Ok(ast.ExportFunc)
        0x01 -> Ok(ast.ExportTable)
        0x02 -> Ok(ast.ExportMemory)
        0x03 -> Ok(ast.ExportGlobal)
        _ -> Error(ast.BadExportKind)
      })
      use #(index, rest) <- result.try(decode_u_n(after_kind, 32))
      Ok(#(ast.Export(name: name, kind: kind, index: index), rest))
    }
    _ -> Error(ast.Truncated)
  }
}

// ---------------------------------------------------------------------------
// Code section: locals (RLE) + the instruction stream
// ---------------------------------------------------------------------------

/// Decode one code entry `[u32 size][vec(locals)][expr]`. The `size` bounds the
/// entry; `Error(ast.SectionSizeMismatch)` if the locals+expr do not consume it
/// exactly. Returns `#(expanded_locals, body)` (see `decode_locals`,
/// `decode_expr`).
fn decode_code(
  bytes: BitArray,
) -> Result(#(#(List(ValType), List(Instr)), BitArray), ast.DecodeError) {
  use #(size, after_size) <- result.try(decode_u_n(bytes, 32))
  case after_size {
    <<body_bytes:size(size)-bytes, rest:bytes>> -> {
      use #(locals, after_locals) <- result.try(decode_locals(body_bytes))
      use #(instrs, after_expr) <- result.try(decode_expr(after_locals, 0, []))
      case after_expr {
        <<>> -> Ok(#(#(locals, instrs), rest))
        _ -> Error(ast.SectionSizeMismatch)
      }
    }
    _ -> Error(ast.Truncated)
  }
}

/// Decode `vec(locals)` and RLE-EXPAND it: a count of groups, each
/// `[u32 n][valtype]`, producing `n` copies of the valtype, concatenated in
/// declaration order.
fn decode_locals(
  bytes: BitArray,
) -> Result(#(List(ValType), BitArray), ast.DecodeError) {
  use #(group_count, rest) <- result.try(decode_u_n(bytes, 32))
  use #(groups, rest2) <- result.try(
    decode_locals_groups(rest, group_count, []),
  )
  Ok(#(list.flatten(groups), rest2))
}

fn decode_locals_groups(
  bytes: BitArray,
  remaining: Int,
  acc: List(List(ValType)),
) -> Result(#(List(List(ValType)), BitArray), ast.DecodeError) {
  case remaining <= 0 {
    True -> Ok(#(list.reverse(acc), bytes))
    False -> {
      use #(n, r1) <- result.try(decode_u_n(bytes, 32))
      use #(vt, r2) <- result.try(decode_valtype(r1))
      decode_locals_groups(r2, remaining - 1, [list.repeat(vt, n), ..acc])
    }
  }
}

/// Decode a structured-control blocktype: one signed-LEB(33). A non-negative
/// value is a `BlockTypeIdx`; `-64` is `BlockEmpty`; `-1`..`-4` are the four
/// `BlockVal` valtypes; any other negative value is `Error(ast.BadBlockType)`.
fn decode_blocktype(
  bytes: BitArray,
) -> Result(#(BlockType, BitArray), ast.DecodeError) {
  use #(v, rest) <- result.try(decode_s_n(bytes, 33))
  case v {
    _ if v >= 0 -> Ok(#(ast.BlockTypeIdx(v), rest))
    _ if v == -64 -> Ok(#(ast.BlockEmpty, rest))
    _ if v == -1 -> Ok(#(ast.BlockVal(ast.I32), rest))
    _ if v == -2 -> Ok(#(ast.BlockVal(ast.I64), rest))
    _ if v == -3 -> Ok(#(ast.BlockVal(ast.F32), rest))
    _ if v == -4 -> Ok(#(ast.BlockVal(ast.F64), rest))
    _ -> Error(ast.BadBlockType)
  }
}

/// Decode a function expression into a FLAT instruction list, tracking block
/// nesting `depth`. Each `block`/`loop`/`if` deepens nesting (its closing `End`
/// pops it); the `End` encountered at `depth = 0` terminates the expression and
/// is INCLUDED as the final element of the returned list (matching `Func.body`).
fn decode_expr(
  bytes: BitArray,
  depth: Int,
  acc: List(Instr),
) -> Result(#(List(Instr), BitArray), ast.DecodeError) {
  use #(instr, rest) <- result.try(decode_instr(bytes))
  case instr {
    ast.End ->
      case depth {
        0 -> Ok(#(list.reverse([ast.End, ..acc]), rest))
        _ -> decode_expr(rest, depth - 1, [ast.End, ..acc])
      }
    ast.Block(_) | ast.Loop(_) | ast.If(_) ->
      decode_expr(rest, depth + 1, [instr, ..acc])
    _ -> decode_expr(rest, depth, [instr, ..acc])
  }
}

/// Decode exactly one instruction (opcode byte plus its immediates). Unknown
/// opcodes are `Error(ast.UnknownOpcode(byte))`; a `0xFC` sub-opcode outside
/// `0..7` is `Error(ast.UnknownSatOpcode(sub))`. `0xFC` is a PREFIX FAMILY: it
/// reads a `u32` sub-opcode after the prefix (never treated as a leaf).
fn decode_instr(
  bytes: BitArray,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case bytes {
    <<op:8, rest:bytes>> ->
      case op {
        // control
        0x00 -> Ok(#(ast.Unreachable, rest))
        0x01 -> Ok(#(ast.Nop, rest))
        0x02 -> {
          use #(bt, r) <- result.try(decode_blocktype(rest))
          Ok(#(ast.Block(bt), r))
        }
        0x03 -> {
          use #(bt, r) <- result.try(decode_blocktype(rest))
          Ok(#(ast.Loop(bt), r))
        }
        0x04 -> {
          use #(bt, r) <- result.try(decode_blocktype(rest))
          Ok(#(ast.If(bt), r))
        }
        0x05 -> Ok(#(ast.Else, rest))
        0x0B -> Ok(#(ast.End, rest))
        0x0C -> {
          use #(l, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.Br(l), r))
        }
        0x0D -> {
          use #(l, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.BrIf(l), r))
        }
        0x0E -> {
          use #(targets, r1) <- result.try(
            decode_vec(rest, fn(b) { decode_u_n(b, 32) }),
          )
          use #(default, r2) <- result.try(decode_u_n(r1, 32))
          Ok(#(ast.BrTable(targets: targets, default: default), r2))
        }
        0x0F -> Ok(#(ast.Return, rest))
        0x10 -> {
          use #(f, r) <- result.try(decode_u_n(rest, 32))
          Ok(#(ast.Call(f), r))
        }
        0x11 -> {
          use #(ty, r1) <- result.try(decode_u_n(rest, 32))
          use #(table, r2) <- result.try(decode_u_n(r1, 32))
          Ok(#(ast.CallIndirect(type_idx: ty, table: table), r2))
        }
        // parametric
        0x1A -> Ok(#(ast.Drop, rest))
        0x1B -> Ok(#(ast.Select, rest))
        // variable access
        0x20 -> idx_instr(rest, ast.LocalGet)
        0x21 -> idx_instr(rest, ast.LocalSet)
        0x22 -> idx_instr(rest, ast.LocalTee)
        0x23 -> idx_instr(rest, ast.GlobalGet)
        0x24 -> idx_instr(rest, ast.GlobalSet)
        // constants
        0x41 -> {
          use #(v, r) <- result.try(decode_s_n(rest, 32))
          Ok(#(ast.I32Const(v), r))
        }
        0x42 -> {
          use #(v, r) <- result.try(decode_s_n(rest, 64))
          Ok(#(ast.I64Const(v), r))
        }
        // Float consts are kept as RAW LE bit patterns (overview D5) — extracted
        // as unsigned ints so NaN/Infinity payloads survive (never `:float`).
        0x43 ->
          case rest {
            <<bits:32-unsigned-little, r:bytes>> -> Ok(#(ast.F32Const(bits), r))
            _ -> Error(ast.Truncated)
          }
        0x44 ->
          case rest {
            <<bits:64-unsigned-little, r:bytes>> -> Ok(#(ast.F64Const(bits), r))
            _ -> Error(ast.Truncated)
          }
        // leaf numeric / comparison / sign-extension opcodes (no immediates)
        _ ->
          case leaf_instr(op) {
            Ok(instr) -> Ok(#(instr, rest))
            Error(Nil) ->
              case op {
                // 0xFC prefix family: read a u32 sub-opcode and dispatch.
                0xFC -> {
                  use #(sub, r) <- result.try(decode_u_n(rest, 32))
                  case sat_instr(sub) {
                    Ok(instr) -> Ok(#(instr, r))
                    Error(Nil) -> Error(ast.UnknownSatOpcode(sub))
                  }
                }
                _ -> Error(ast.UnknownOpcode(op))
              }
          }
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode a `u32` index immediate and wrap it with `make` (the variable-access
/// instructions `0x20`..`0x24`).
fn idx_instr(
  bytes: BitArray,
  make: fn(Int) -> Instr,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  use #(i, r) <- result.try(decode_u_n(bytes, 32))
  Ok(#(make(i), r))
}

/// Map a leaf opcode byte (comparison / numeric / sign-extension, all with NO
/// immediates) to its `Instr`. `Error(Nil)` for any byte not in those ranges —
/// the caller then tries the `0xFC` prefix or reports `UnknownOpcode`.
fn leaf_instr(op: Int) -> Result(Instr, Nil) {
  case op {
    // i32 comparisons 0x45..0x4F
    0x45 -> Ok(ast.I32Eqz)
    0x46 -> Ok(ast.I32Eq)
    0x47 -> Ok(ast.I32Ne)
    0x48 -> Ok(ast.I32LtS)
    0x49 -> Ok(ast.I32LtU)
    0x4A -> Ok(ast.I32GtS)
    0x4B -> Ok(ast.I32GtU)
    0x4C -> Ok(ast.I32LeS)
    0x4D -> Ok(ast.I32LeU)
    0x4E -> Ok(ast.I32GeS)
    0x4F -> Ok(ast.I32GeU)
    // i64 comparisons 0x50..0x5A
    0x50 -> Ok(ast.I64Eqz)
    0x51 -> Ok(ast.I64Eq)
    0x52 -> Ok(ast.I64Ne)
    0x53 -> Ok(ast.I64LtS)
    0x54 -> Ok(ast.I64LtU)
    0x55 -> Ok(ast.I64GtS)
    0x56 -> Ok(ast.I64GtU)
    0x57 -> Ok(ast.I64LeS)
    0x58 -> Ok(ast.I64LeU)
    0x59 -> Ok(ast.I64GeS)
    0x5A -> Ok(ast.I64GeU)
    // i32 numeric 0x67..0x78
    0x67 -> Ok(ast.I32Clz)
    0x68 -> Ok(ast.I32Ctz)
    0x69 -> Ok(ast.I32Popcnt)
    0x6A -> Ok(ast.I32Add)
    0x6B -> Ok(ast.I32Sub)
    0x6C -> Ok(ast.I32Mul)
    0x6D -> Ok(ast.I32DivS)
    0x6E -> Ok(ast.I32DivU)
    0x6F -> Ok(ast.I32RemS)
    0x70 -> Ok(ast.I32RemU)
    0x71 -> Ok(ast.I32And)
    0x72 -> Ok(ast.I32Or)
    0x73 -> Ok(ast.I32Xor)
    0x74 -> Ok(ast.I32Shl)
    0x75 -> Ok(ast.I32ShrS)
    0x76 -> Ok(ast.I32ShrU)
    0x77 -> Ok(ast.I32Rotl)
    0x78 -> Ok(ast.I32Rotr)
    // i64 numeric 0x79..0x8A
    0x79 -> Ok(ast.I64Clz)
    0x7A -> Ok(ast.I64Ctz)
    0x7B -> Ok(ast.I64Popcnt)
    0x7C -> Ok(ast.I64Add)
    0x7D -> Ok(ast.I64Sub)
    0x7E -> Ok(ast.I64Mul)
    0x7F -> Ok(ast.I64DivS)
    0x80 -> Ok(ast.I64DivU)
    0x81 -> Ok(ast.I64RemS)
    0x82 -> Ok(ast.I64RemU)
    0x83 -> Ok(ast.I64And)
    0x84 -> Ok(ast.I64Or)
    0x85 -> Ok(ast.I64Xor)
    0x86 -> Ok(ast.I64Shl)
    0x87 -> Ok(ast.I64ShrS)
    0x88 -> Ok(ast.I64ShrU)
    0x89 -> Ok(ast.I64Rotl)
    0x8A -> Ok(ast.I64Rotr)
    // sign extension 0xC0..0xC4
    0xC0 -> Ok(ast.I32Extend8S)
    0xC1 -> Ok(ast.I32Extend16S)
    0xC2 -> Ok(ast.I64Extend8S)
    0xC3 -> Ok(ast.I64Extend16S)
    0xC4 -> Ok(ast.I64Extend32S)
    _ -> Error(Nil)
  }
}

/// Map a `0xFC` sub-opcode `0..7` to its saturating-truncation `Instr`.
/// `Error(Nil)` for any other sub-opcode (caller reports `UnknownSatOpcode`).
fn sat_instr(sub: Int) -> Result(Instr, Nil) {
  case sub {
    0 -> Ok(ast.I32TruncSatF32S)
    1 -> Ok(ast.I32TruncSatF32U)
    2 -> Ok(ast.I32TruncSatF64S)
    3 -> Ok(ast.I32TruncSatF64U)
    4 -> Ok(ast.I64TruncSatF32S)
    5 -> Ok(ast.I64TruncSatF32U)
    6 -> Ok(ast.I64TruncSatF64S)
    7 -> Ok(ast.I64TruncSatF64U)
    _ -> Error(Nil)
  }
}
