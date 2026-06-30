//// The WebAssembly 1.0 binary decoder (the Phase-1 slice) — turns an untrusted
//// `BitArray` of `.wasm` bytes into the `twocore/frontend/wasm/ast` model.
////
//// THREAT MODEL: the input is attacker-controlled. Every function in this module
//// is total over arbitrary bytes — any malformation returns a typed
//// `DecodeError`, and there are NO `let assert`/`panic`/partial matches reachable
//// from untrusted input (overview D4, D5). LEB128 numbers are validated against
//// the spec's width bounds (no silent wraparound).
////
//// Scope (Phase 2 — `«WASM-AST2»`): the preamble plus the type(1), table(4),
//// memory(5), global(6), function(3), export(7), start(8), element(9), code(10)
//// and data(11) sections, and the full WASM 1.0 opcode set (the load/store
//// matrix, `memory.size`/`memory.grow`, the `0xA7..0xBF` int+float conversion
//// block, and the float arithmetic/comparison ops). The import(2) section (and
//// custom(0)) are SKIPPED safely via their declared size — non-function imports
//// are deferred to Phase 3. Reference-types / bulk-memory / multi-memory forms
//// (`select_t`, externref, passive element/data, the memory64 limits/memarg
//// encodings) are decode-rejected with a typed error. Lowering/validation are
//// units 08/09; this module only decodes structure (no semantic checks).
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
import gleam/option.{type Option, None, Some}
import gleam/result
import twocore/frontend/wasm/ast.{
  type BlockType, type DataSegment, type ElementSegment, type Export, type Func,
  type FuncType, type Global, type Instr, type Limits, type MemArg, type MemType,
  type Module, type TableType, type ValType,
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
    tables: List(TableType),
    memories: List(MemType),
    globals: List(Global),
    func_type_idxs: List(Int),
    start: Option(Int),
    elements: List(ElementSegment),
    data: List(DataSegment),
    exports: List(Export),
    codes: List(#(List(ValType), List(Instr))),
  )
}

fn empty_state() -> DecodeState {
  DecodeState(
    types: [],
    tables: [],
    memories: [],
    globals: [],
    func_type_idxs: [],
    start: None,
    elements: [],
    data: [],
    exports: [],
    codes: [],
  )
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
/// slice, asserting full consumption (`SectionSizeMismatch` on under-run). The
/// import section (2) stays out of scope (non-function imports → Phase 3) and is
/// skipped by discarding `contents`.
fn dispatch_section(
  id: Int,
  contents: BitArray,
  state: DecodeState,
) -> Result(DecodeState, ast.DecodeError) {
  case id {
    // type section: vec(functype)
    1 -> {
      use #(types, rest) <- result.try(decode_vec(contents, decode_functype))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, types: types))
    }
    // table section: vec(tabletype)
    4 -> {
      use #(tables, rest) <- result.try(decode_vec(contents, decode_tabletype))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, tables: tables))
    }
    // memory section: vec(memtype)
    5 -> {
      use #(memories, rest) <- result.try(decode_vec(contents, decode_memtype))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, memories: memories))
    }
    // global section: vec(global)
    6 -> {
      use #(globals, rest) <- result.try(decode_vec(contents, decode_global))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, globals: globals))
    }
    // function section: vec(typeidx)
    3 -> {
      use #(idxs, rest) <- result.try(
        decode_vec(contents, fn(b) { decode_u_n(b, 32) }),
      )
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, func_type_idxs: idxs))
    }
    // export section: vec(export)
    7 -> {
      use #(exports, rest) <- result.try(decode_vec(contents, decode_export))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, exports: exports))
    }
    // start section: a single funcidx
    8 -> {
      use #(idx, rest) <- result.try(decode_u_n(contents, 32))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, start: Some(idx)))
    }
    // element section: vec(elem)
    9 -> {
      use #(elements, rest) <- result.try(decode_vec(contents, decode_elemseg))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, elements: elements))
    }
    // code section: vec(code)
    10 -> {
      use #(codes, rest) <- result.try(decode_vec(contents, decode_code))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, codes: codes))
    }
    // data section: vec(data)
    11 -> {
      use #(data, rest) <- result.try(decode_vec(contents, decode_dataseg))
      use _ <- result.try(expect_empty(rest))
      Ok(DecodeState(..state, data: data))
    }
    // import(2) (non-function imports → Phase 3) and any unknown id: already
    // sliced by the caller, so just drop the contents.
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
    tables: state.tables,
    memories: state.memories,
    globals: state.globals,
    funcs: funcs,
    start: state.start,
    elements: state.elements,
    data: state.data,
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
// Section 4/5/6/9/11 leaf decoders (table / memory / global / element / data)
// ---------------------------------------------------------------------------

/// Decode a `limits` (spec binary/types.html): flag `0x00` → `Limits(min, None)`;
/// flag `0x01` → `Limits(min, Some(max))`; `min`/`max` are `u32`. Any other flag
/// (e.g. the memory64 `0x04`/`0x05` forms) is `Error(ast.BadLimitsFlag)`. The
/// spec bound `min <= max` is NOT checked here — that is validate's job.
fn decode_limits(
  bytes: BitArray,
) -> Result(#(Limits, BitArray), ast.DecodeError) {
  case bytes {
    <<flag:8, after_flag:bytes>> ->
      case flag {
        0x00 -> {
          use #(min, rest) <- result.try(decode_u_n(after_flag, 32))
          Ok(#(ast.Limits(min: min, max: None), rest))
        }
        0x01 -> {
          use #(min, r1) <- result.try(decode_u_n(after_flag, 32))
          use #(max, r2) <- result.try(decode_u_n(r1, 32))
          Ok(#(ast.Limits(min: min, max: Some(max)), r2))
        }
        _ -> Error(ast.BadLimitsFlag)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one `tabletype` = `reftype limits`. The reftype byte must be `funcref`
/// (`0x70`); `externref` (`0x6F`) and anything else are `Error(ast.BadRefType)`.
fn decode_tabletype(
  bytes: BitArray,
) -> Result(#(TableType, BitArray), ast.DecodeError) {
  case bytes {
    <<reftype:8, after_ref:bytes>> ->
      case reftype {
        0x70 -> {
          use #(limits, rest) <- result.try(decode_limits(after_ref))
          Ok(#(ast.TableType(limits: limits), rest))
        }
        _ -> Error(ast.BadRefType)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one `memtype` = `limits` (in 64KiB pages).
fn decode_memtype(
  bytes: BitArray,
) -> Result(#(MemType, BitArray), ast.DecodeError) {
  use #(limits, rest) <- result.try(decode_limits(bytes))
  Ok(#(ast.MemType(limits: limits), rest))
}

/// Decode one `global` = `valtype mut const-expr`. The `mut` byte is `0x00`
/// (const → `False`) or `0x01` (var → `True`); anything else is
/// `Error(ast.BadMutability)`. The const-expr is decoded structurally
/// (`decode_const_expr`); its const-ness is validate's job.
fn decode_global(
  bytes: BitArray,
) -> Result(#(Global, BitArray), ast.DecodeError) {
  use #(ty, after_ty) <- result.try(decode_valtype(bytes))
  case after_ty {
    <<mut_byte:8, after_mut:bytes>> -> {
      use mutable <- result.try(case mut_byte {
        0x00 -> Ok(False)
        0x01 -> Ok(True)
        _ -> Error(ast.BadMutability)
      })
      use #(init, rest) <- result.try(decode_const_expr(after_mut))
      Ok(#(ast.Global(ty: ty, mutable: mutable, init: init), rest))
    }
    _ -> Error(ast.Truncated)
  }
}

/// Decode a constant expression: an instruction sequence terminated by a depth-0
/// `End` (`0x0B`), block-nesting tracked exactly like `decode_expr`. Returns the
/// instructions BEFORE that terminating `End` (the `End` is consumed, not
/// stored). PURELY STRUCTURAL — it does not reject non-const opcodes (the
/// const-expr restriction is validate's, unit 08). Total over any bytes.
fn decode_const_expr(
  bytes: BitArray,
) -> Result(#(List(Instr), BitArray), ast.DecodeError) {
  decode_const_go(bytes, 0, [])
}

fn decode_const_go(
  bytes: BitArray,
  depth: Int,
  acc: List(Instr),
) -> Result(#(List(Instr), BitArray), ast.DecodeError) {
  use #(instr, rest) <- result.try(decode_instr(bytes))
  case instr {
    ast.End ->
      case depth {
        0 -> Ok(#(list.reverse(acc), rest))
        _ -> decode_const_go(rest, depth - 1, [ast.End, ..acc])
      }
    ast.Block(_) | ast.Loop(_) | ast.If(_) ->
      decode_const_go(rest, depth + 1, [instr, ..acc])
    _ -> decode_const_go(rest, depth, [instr, ..acc])
  }
}

/// Decode one ACTIVE element segment. Only the legacy flag-`0` form is in scope:
/// `0x00 offset-expr vec(funcidx)` → `ElementSegment(table: 0, …)`. Any other
/// leading flag (passive/declarative/expr-list, 1–7) is `Error(ast.BadElemKind)`.
fn decode_elemseg(
  bytes: BitArray,
) -> Result(#(ElementSegment, BitArray), ast.DecodeError) {
  case bytes {
    <<flag:8, after_flag:bytes>> ->
      case flag {
        0x00 -> {
          use #(offset, r1) <- result.try(decode_const_expr(after_flag))
          use #(funcs, r2) <- result.try(
            decode_vec(r1, fn(b) { decode_u_n(b, 32) }),
          )
          Ok(#(ast.ElementSegment(table: 0, offset: offset, funcs: funcs), r2))
        }
        _ -> Error(ast.BadElemKind)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode one ACTIVE data segment. Forms in scope: `0x00 offset-expr vec(byte)`
/// (memory 0); `0x02 memidx offset-expr vec(byte)` where `memidx` MUST be `0`
/// (else `Error(ast.BadMemoryIndex)`). The passive form `0x01` and anything else
/// are `Error(ast.BadDataKind)`.
fn decode_dataseg(
  bytes: BitArray,
) -> Result(#(DataSegment, BitArray), ast.DecodeError) {
  case bytes {
    <<form:8, after_form:bytes>> ->
      case form {
        0x00 -> {
          use #(offset, r1) <- result.try(decode_const_expr(after_form))
          use #(payload, r2) <- result.try(decode_vec_bytes(r1))
          Ok(#(ast.DataSegment(mem: 0, offset: offset, bytes: payload), r2))
        }
        0x02 -> {
          use #(memidx, r1) <- result.try(decode_u_n(after_form, 32))
          case memidx == 0 {
            False -> Error(ast.BadMemoryIndex)
            True -> {
              use #(offset, r2) <- result.try(decode_const_expr(r1))
              use #(payload, r3) <- result.try(decode_vec_bytes(r2))
              Ok(#(ast.DataSegment(mem: 0, offset: offset, bytes: payload), r3))
            }
          }
        }
        _ -> Error(ast.BadDataKind)
      }
    _ -> Error(ast.Truncated)
  }
}

/// Decode a `vec(byte)` = `[u32 count][count raw bytes]` into a `BitArray`. An
/// oversized `count` (more than the remaining bytes) fails the slice match and is
/// reported `Error(ast.Truncated)` (fail-closed; never over-reads).
fn decode_vec_bytes(
  bytes: BitArray,
) -> Result(#(BitArray, BitArray), ast.DecodeError) {
  use #(count, rest) <- result.try(decode_u_n(bytes, 32))
  case rest {
    <<payload:size(count)-bytes, tail:bytes>> -> Ok(#(payload, tail))
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
        // `select_t` (typed select) is a reference-types op, deferred to Phase 3;
        // reject rather than half-decode its valtype-vector immediate.
        0x1C -> Error(ast.UnknownOpcode(0x1C))
        // variable access
        0x20 -> idx_instr(rest, ast.LocalGet)
        0x21 -> idx_instr(rest, ast.LocalSet)
        0x22 -> idx_instr(rest, ast.LocalTee)
        0x23 -> idx_instr(rest, ast.GlobalGet)
        0x24 -> idx_instr(rest, ast.GlobalSet)
        // memory load/store (0x28..0x3E): each followed by a `memarg`.
        0x28 -> memarg_instr(rest, ast.I32Load)
        0x29 -> memarg_instr(rest, ast.I64Load)
        0x2A -> memarg_instr(rest, ast.F32Load)
        0x2B -> memarg_instr(rest, ast.F64Load)
        0x2C -> memarg_instr(rest, ast.I32Load8S)
        0x2D -> memarg_instr(rest, ast.I32Load8U)
        0x2E -> memarg_instr(rest, ast.I32Load16S)
        0x2F -> memarg_instr(rest, ast.I32Load16U)
        0x30 -> memarg_instr(rest, ast.I64Load8S)
        0x31 -> memarg_instr(rest, ast.I64Load8U)
        0x32 -> memarg_instr(rest, ast.I64Load16S)
        0x33 -> memarg_instr(rest, ast.I64Load16U)
        0x34 -> memarg_instr(rest, ast.I64Load32S)
        0x35 -> memarg_instr(rest, ast.I64Load32U)
        0x36 -> memarg_instr(rest, ast.I32Store)
        0x37 -> memarg_instr(rest, ast.I64Store)
        0x38 -> memarg_instr(rest, ast.F32Store)
        0x39 -> memarg_instr(rest, ast.F64Store)
        0x3A -> memarg_instr(rest, ast.I32Store8)
        0x3B -> memarg_instr(rest, ast.I32Store16)
        0x3C -> memarg_instr(rest, ast.I64Store8)
        0x3D -> memarg_instr(rest, ast.I64Store16)
        0x3E -> memarg_instr(rest, ast.I64Store32)
        // memory.size/grow (0x3F/0x40): a single reserved `0x00` mem-index byte
        // (NOT a memarg). A non-zero reserved byte is `BadMemoryIndex`.
        0x3F -> mem_index_instr(rest, ast.MemorySize)
        0x40 -> mem_index_instr(rest, ast.MemoryGrow)
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

/// Decode a `memarg = align:u32 offset:u32` and wrap it with `make` (every
/// load/store opcode `0x28`..`0x3E`). BOTH `u32`s are read; `align` is kept for
/// validate's `2^align <= N` check (non-semantic), `offset` is the static byte
/// offset. `Error(ast.Truncated)`/LEB errors if either number is malformed.
fn memarg_instr(
  bytes: BitArray,
  make: fn(MemArg) -> Instr,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  use #(align, r1) <- result.try(decode_u_n(bytes, 32))
  use #(offset, r2) <- result.try(decode_u_n(r1, 32))
  Ok(#(make(ast.MemArg(align: align, offset: offset)), r2))
}

/// Decode the single reserved memory-index byte of `memory.size`/`memory.grow`
/// (NOT a memarg) and yield the bare `instr`. The byte MUST be `0x00` (MVP allows
/// only memory 0); a non-zero byte is `Error(ast.BadMemoryIndex)` and an absent
/// byte is `Error(ast.Truncated)`.
fn mem_index_instr(
  bytes: BitArray,
  instr: Instr,
) -> Result(#(Instr, BitArray), ast.DecodeError) {
  case bytes {
    <<0x00, rest:bytes>> -> Ok(#(instr, rest))
    <<_:8, _:bytes>> -> Error(ast.BadMemoryIndex)
    _ -> Error(ast.Truncated)
  }
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
    // float comparisons 0x5B..0x66 (yield i32)
    0x5B -> Ok(ast.F32Eq)
    0x5C -> Ok(ast.F32Ne)
    0x5D -> Ok(ast.F32Lt)
    0x5E -> Ok(ast.F32Gt)
    0x5F -> Ok(ast.F32Le)
    0x60 -> Ok(ast.F32Ge)
    0x61 -> Ok(ast.F64Eq)
    0x62 -> Ok(ast.F64Ne)
    0x63 -> Ok(ast.F64Lt)
    0x64 -> Ok(ast.F64Gt)
    0x65 -> Ok(ast.F64Le)
    0x66 -> Ok(ast.F64Ge)
    // f32 numeric 0x8B..0x98
    0x8B -> Ok(ast.F32Abs)
    0x8C -> Ok(ast.F32Neg)
    0x8D -> Ok(ast.F32Ceil)
    0x8E -> Ok(ast.F32Floor)
    0x8F -> Ok(ast.F32Trunc)
    0x90 -> Ok(ast.F32Nearest)
    0x91 -> Ok(ast.F32Sqrt)
    0x92 -> Ok(ast.F32Add)
    0x93 -> Ok(ast.F32Sub)
    0x94 -> Ok(ast.F32Mul)
    0x95 -> Ok(ast.F32Div)
    0x96 -> Ok(ast.F32Min)
    0x97 -> Ok(ast.F32Max)
    0x98 -> Ok(ast.F32Copysign)
    // f64 numeric 0x99..0xA6
    0x99 -> Ok(ast.F64Abs)
    0x9A -> Ok(ast.F64Neg)
    0x9B -> Ok(ast.F64Ceil)
    0x9C -> Ok(ast.F64Floor)
    0x9D -> Ok(ast.F64Trunc)
    0x9E -> Ok(ast.F64Nearest)
    0x9F -> Ok(ast.F64Sqrt)
    0xA0 -> Ok(ast.F64Add)
    0xA1 -> Ok(ast.F64Sub)
    0xA2 -> Ok(ast.F64Mul)
    0xA3 -> Ok(ast.F64Div)
    0xA4 -> Ok(ast.F64Min)
    0xA5 -> Ok(ast.F64Max)
    0xA6 -> Ok(ast.F64Copysign)
    // conversion block 0xA7..0xBF (int + float interleaved)
    0xA7 -> Ok(ast.I32WrapI64)
    0xA8 -> Ok(ast.I32TruncF32S)
    0xA9 -> Ok(ast.I32TruncF32U)
    0xAA -> Ok(ast.I32TruncF64S)
    0xAB -> Ok(ast.I32TruncF64U)
    0xAC -> Ok(ast.I64ExtendI32S)
    0xAD -> Ok(ast.I64ExtendI32U)
    0xAE -> Ok(ast.I64TruncF32S)
    0xAF -> Ok(ast.I64TruncF32U)
    0xB0 -> Ok(ast.I64TruncF64S)
    0xB1 -> Ok(ast.I64TruncF64U)
    0xB2 -> Ok(ast.F32ConvertI32S)
    0xB3 -> Ok(ast.F32ConvertI32U)
    0xB4 -> Ok(ast.F32ConvertI64S)
    0xB5 -> Ok(ast.F32ConvertI64U)
    0xB6 -> Ok(ast.F32DemoteF64)
    0xB7 -> Ok(ast.F64ConvertI32S)
    0xB8 -> Ok(ast.F64ConvertI32U)
    0xB9 -> Ok(ast.F64ConvertI64S)
    0xBA -> Ok(ast.F64ConvertI64U)
    0xBB -> Ok(ast.F64PromoteF32)
    0xBC -> Ok(ast.I32ReinterpretF32)
    0xBD -> Ok(ast.I64ReinterpretF64)
    0xBE -> Ok(ast.F32ReinterpretI32)
    0xBF -> Ok(ast.F64ReinterpretI64)
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
