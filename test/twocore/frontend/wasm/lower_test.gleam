//// Tests for `twocore/frontend/wasm/lower` (Unit 10b).
////
//// Two kinds of assertion, both against the spec rather than the implementation:
////
//// 1. **Structural** — decode → validate → lower a real `wat2wasm` fixture and assert
////    the shared-IR shape the spec/IR demand: numerics on & memory off; a WASM `loop`
////    with mutable locals becomes an `ir.Loop` carrying `LoopParam`s; branches resolve
////    to NAMED labels (`Break`/`Continue`), never a numeric depth (D6); a self-`call`
////    becomes `CallDirect`.
//// 2. **End-to-end** — lower → `emit_core` → `build_beam` → RUN the export on the BEAM
////    and assert SPEC-CORRECT results (`add(2,3)=5`, two's-complement wrap,
////    `sum_to(100)=5050`, `fib(10)=55`). This exercises the whole frontend+backend chain
////    on real `.wasm` bytes.

import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleeunit/should
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/ir
import twocore/ir/parser
import twocore/ir/printer
import twocore/runtime/instance

// Test-only FFI (shared with the unit-08 e2e suite): apply `M:F(Args)` and capture a
// trap as `Error(text)` instead of crashing the runner.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

// ───────────────────────────── pipeline plumbing ─────────────────────────────

/// Decode → validate → lower `bytes` into a shared-IR module. Each stage must
/// succeed (these are valid fixtures); a failure is a genuine test failure.
fn build(bytes: BitArray) -> ir.Module {
  let assert Ok(m) = decode.decode(bytes)
  let assert Ok(typed) = validate.validate(m)
  let assert Ok(irm) = lower.lower(typed)
  irm
}

/// Emit `irm` to Core text, compile it, and load it into the test VM (D10).
fn load(irm: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(irm, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Every expression in `e`'s tree (itself plus all nested sub-expressions), for
/// structural inspection.
fn all_exprs(e: ir.Expr) -> List(ir.Expr) {
  let nested = case e {
    ir.Let(_, rhs, body) -> list.append(all_exprs(rhs), all_exprs(body))
    ir.Block(_, _, body) -> all_exprs(body)
    ir.Loop(_, _, _, body) -> all_exprs(body)
    ir.If(_, _, t, el) -> list.append(all_exprs(t), all_exprs(el))
    ir.Switch(_, _, arms, default) ->
      list.append(
        list.flat_map(arms, fn(a) { all_exprs(a.body) }),
        all_exprs(default),
      )
    ir.Charge(_, body) -> all_exprs(body)
    _ -> []
  }
  [e, ..nested]
}

/// The single defined function named `name`.
fn func(irm: ir.Module, name: String) -> ir.Function {
  let assert Ok(f) = list.find(irm.functions, fn(f) { f.name == name })
  f
}

/// A `BitArray` as a list of its bytes (for fuzz mutation).
fn ba_to_list(ba: BitArray) -> List(Int) {
  case ba {
    <<b:8, rest:bits>> -> [b, ..ba_to_list(rest)]
    _ -> []
  }
}

/// A list of bytes back into a `BitArray`.
fn list_to_ba(ints: List(Int)) -> BitArray {
  list.fold(ints, <<>>, fn(acc, b) { <<acc:bits, b:8>> })
}

/// Replace the byte at `idx` with `val` (a fresh list).
fn replace(ints: List(Int), idx: Int, val: Int) -> List(Int) {
  list.index_map(ints, fn(b, i) {
    case i == idx {
      True -> val
      False -> b
    }
  })
}

/// Inclusive integer range `[from, to]`.
fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}

// ───────────────────────────── module-level shape ─────────────────────────────

/// A lowered WASM module turns numerics ON and links no memory (D5): the Phase-1
/// capability axes.
pub fn module_flags_test() {
  let irm = build(add_wasm)
  irm.uses_numerics |> should.equal(True)
  irm.memories |> should.equal([])
}

/// The export survives lowering: `add` is exported (resolving to the function's IR
/// name).
pub fn export_preserved_test() {
  let irm = build(add_wasm)
  list.any(irm.exports, fn(e) {
    case e {
      ir.ExportFn(export_name, _) -> export_name == "add"
      ir.ExportGlobal(..) | ir.ExportTable(..) | ir.ExportMemory(..) -> False
    }
  })
  |> should.equal(True)
}

// ───────────────────────────── add: a single neutral numeric op ─────────────────────────────

/// `add` lowers to a function with a single neutral, width-tagged `Num(IAdd(W32), …)`
/// (D6 — never a WASM opcode string), over the two params.
pub fn add_structure_test() {
  let irm = build(add_wasm)
  let f = func(irm, "f0")
  f.result |> should.equal([ir.TI32])
  list.length(f.params) |> should.equal(2)
  // The body contains exactly the i32 add (neutral op, width 32).
  let adds =
    all_exprs(f.body)
    |> list.filter(fn(e) {
      case e {
        ir.Num(ir.IAdd(ir.W32), _) -> True
        _ -> False
      }
    })
  list.length(adds) |> should.equal(1)
}

// ───────────────────────────── sum_to: loop with carried locals ─────────────────────────────

/// `sum_to`'s WASM `loop` with the mutable locals `i`,`acc` lowers to an `ir.Loop`
/// carrying TWO `LoopParam`s (the spec mutable-locals → SSA promotion). This is exactly
/// why a loop body that *writes* locals across the back-edge must thread them as
/// loop-carried values. Both are i32; `i`'s init is the absorbed `local.set $i 1`
/// (`ConstI32(1)`), `acc`'s init is its zero-init binding (a `Var` — declared locals are
/// zero-initialised by an explicit `Let`, since emit_core ignores `Function.locals`).
pub fn sum_to_loop_params_test() {
  let irm = build(sum_to_wasm)
  let f = func(irm, "f0")
  let loops =
    all_exprs(f.body)
    |> list.filter_map(fn(e) {
      case e {
        ir.Loop(_, params, _, _) -> Ok(params)
        _ -> Error(Nil)
      }
    })
  // Exactly one loop, carrying the two mutated locals (both i32).
  let assert [params] = loops
  list.length(params) |> should.equal(2)
  list.map(params, fn(p) { p.ty }) |> should.equal([ir.TI32, ir.TI32])
  let assert [i_param, acc_param] = params
  // i is initialised to 1 (the pre-loop `local.set` is absorbed into the loop init).
  i_param.init |> should.equal(ir.ConstI32(1))
  // acc threads its zero-init binding in (a named reference, not an inline const).
  case acc_param.init {
    ir.Var(_) -> True
    _ -> False
  }
  |> should.equal(True)
}

/// Branches are resolved to NAMED labels, not numeric depths (D6): the `br $cont`
/// back-edge is a `Continue` naming the loop's own label, and the `br_if $break` exit
/// is a `Break` naming the enclosing block's label. Every referenced label is a label
/// actually defined by a `Block`/`Loop` in the function (no dangling depth).
pub fn sum_to_named_labels_test() {
  let irm = build(sum_to_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)

  let loop_labels =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.Loop(label, _, _, _) -> Ok(label)
        _ -> Error(Nil)
      }
    })
  let block_labels =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.Block(label, _, _) -> Ok(label)
        _ -> Error(Nil)
      }
    })
  let continue_labels =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.Continue(label, _) -> Ok(label)
        _ -> Error(Nil)
      }
    })
  let break_labels =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.Break(label, _) -> Ok(label)
        _ -> Error(Nil)
      }
    })

  // A back-edge Continue names the loop; an exit Break names the block.
  list.all(continue_labels, fn(l) { list.contains(loop_labels, l) })
  |> should.equal(True)
  list.all(break_labels, fn(l) { list.contains(block_labels, l) })
  |> should.equal(True)
  // Both transfers are actually present.
  { list.length(continue_labels) >= 1 } |> should.equal(True)
  { list.length(break_labels) >= 1 } |> should.equal(True)
}

// ───────────────────────────── fib: if + self-call ─────────────────────────────

/// `fib` lowers to an `If` (two arms, i32 result) and a direct self-`call` to its own
/// IR name (`CallDirect`, not a stack op).
pub fn fib_if_and_call_test() {
  let irm = build(fib_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  // There is an If yielding a single i32.
  list.any(exprs, fn(e) {
    case e {
      ir.If(_, [ir.TI32], _, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
  // Two direct self-calls fib(n-1), fib(n-2).
  let calls =
    list.filter(exprs, fn(e) {
      case e {
        ir.CallDirect("f0", _) -> True
        _ -> False
      }
    })
  list.length(calls) |> should.equal(2)
}

// ───────────────────────────── Phase-2: linear memory ─────────────────────────────

/// A memory program lowers each load/store opcode to a `MemLoad`/`MemStore` carrying the
/// SPEC-correct `MemAccess(bytes, signed)` and (for loads) `result` type — cite
/// binary/instructions. Crucially `i32.load8_s` and `i64.load8_s` share `MemAccess(1, True)`
/// but differ in `result` (`TI32` vs `TI64`) — exactly why `MemLoad` carries `result` (E2).
/// `f32.load` is byte-identical to `i32.load` (`MemAccess(4, False)`) but `result: TF32`
/// (raw bits, D5). `i32.store` is `MemAccess(4, False)` (sign irrelevant on a store).
pub fn mem_load_store_structure_test() {
  let irm = build(mem_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  let loads =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.MemLoad(_, op, _, _, result) -> Ok(#(op, result))
        _ -> Error(Nil)
      }
    })
  let stores =
    list.filter_map(exprs, fn(e) {
      case e {
        ir.MemStore(_, op, _, _, _) -> Ok(op)
        _ -> Error(Nil)
      }
    })
  // i32.load8_s ⇒ MemAccess(1, True) + TI32
  list.contains(loads, #(ir.MemAccess(1, True), ir.TI32)) |> should.equal(True)
  // i64.load8_s ⇒ MemAccess(1, True) + TI64 (same access bytes+sign, different result)
  list.contains(loads, #(ir.MemAccess(1, True), ir.TI64)) |> should.equal(True)
  // f32.load ⇒ MemAccess(4, False) + TF32
  list.contains(loads, #(ir.MemAccess(4, False), ir.TF32)) |> should.equal(True)
  // i32.load ⇒ MemAccess(4, False) + TI32
  list.contains(loads, #(ir.MemAccess(4, False), ir.TI32)) |> should.equal(True)
  // i32.store ⇒ MemAccess(4, False) (signed always False on a store)
  list.contains(stores, ir.MemAccess(4, False)) |> should.equal(True)
}

/// `memory.grow` lowers to a `MemGrow(delta)` (the delta carried as a value) and
/// `memory.size` to `MemSize` — cite binary/instructions (0x40 / 0x3F). The module also
/// declares its memory, so `Module.memory` is `Some`.
pub fn mem_size_grow_test() {
  let irm = build(grow_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.MemGrow(_, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
  list.any(exprs, fn(e) { e == ir.MemSize(0) }) |> should.equal(True)
  case irm.memories {
    [_, ..] -> True
    [] -> False
  }
  |> should.equal(True)
}

// ───────────────────────────── Phase-2: globals ─────────────────────────────

/// A global program lowers `global.set`/`global.get` to `GlobalSet`/`GlobalGet` referencing
/// the STABLE name `g<idx>` (here `g0`), and `Module.globals` is populated with bit-exact,
/// type-correct `GlobalDecl`s in index order (a mutable i32 init `100`, an immutable i64
/// init `7`). The `GlobalGet/Set` names match the declared global names.
pub fn globals_test() {
  let irm = build(global_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.GlobalSet("g0", ir.ConstI32(5)) -> True
      _ -> False
    }
  })
  |> should.equal(True)
  list.any(exprs, fn(e) { e == ir.GlobalGet("g0") }) |> should.equal(True)
  // Module.globals populated, in declaration (= index) order, with the const-literal inits.
  irm.globals
  |> should.equal([
    ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(100)])),
    ir.GlobalDecl("g1", ir.TI64, False, ir.Values([ir.ConstI64(7)])),
  ])
}

// ───────────────────────────── Phase-2: tables + call_indirect ─────────────────────────────

/// `call_indirect (type $t) (i32.const 0)` lowers to a single `CallIndirect("t0", index, ty,
/// args)` whose `ty` is the STRUCTURAL `module.types[y]` (`FuncType([], [TI32])` here) — the
/// runtime does the per-call type check (E3). The table is named `"t0"` (the MVP reserved
/// table 0). `Module.tables` and `Module.elements` are populated; the element's target name is
/// `"f<funcidx>"` (`"f0"`), which resolves to a real `Function`.
pub fn call_indirect_structure_test() {
  let irm = build(ci_full_wasm)
  let f = func(irm, "f1")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.CallIndirect("t0", ir.ConstI32(0), ir.FuncType([], [ir.TI32]), []) ->
        True
      _ -> False
    }
  })
  |> should.equal(True)
  // Table declared and named "t0".
  irm.tables |> should.equal([ir.TableDecl("t0", ir.FuncRef, 1, option.None)])
  // Active element segment into "t0" at offset 0, targeting function name "f0".
  irm.elements
  |> should.equal([
    ir.ElementSegment(
      ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
      ir.FuncRef,
      [ir.RefFunc("f0")],
    ),
  ])
  // The element target name resolves to a real defined function.
  list.any(irm.functions, fn(fn_) { fn_.name == "f0" }) |> should.equal(True)
}

// ───────────────────────────── Phase-2: select → If ─────────────────────────────

/// `select` (0x1B) lowers to the existing `If` (NO new IR node). Per exec/instructions the
/// result is `val1` when `cond ≠ 0`, else `val2`; so the lowered `If`'s then-branch is
/// `Values([val1])` (the first/deeper operand) and the else-branch is `Values([val2])`. The
/// operands are i32 here, so the `If` result arity is 1 and its type is `[TI32]`.
pub fn select_test() {
  let irm = build(select_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.If(
        ir.Var("p2"),
        [ir.TI32],
        ir.Values([ir.Var("p0")]),
        ir.Values([ir.Var("p1")]),
      ) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

/// A `select` over i64 operands recovers `TI64` as the result type — proving the SSA
/// value-type tracking (a select's result type is operand-determined, not opcode-determined,
/// §5). The lowered `If` carries `[TI64]`.
pub fn select_i64_test() {
  let irm = build(select64_wasm)
  let f = func(irm, "f0")
  let exprs = all_exprs(f.body)
  list.any(exprs, fn(e) {
    case e {
      ir.If(_, [ir.TI64], _, _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

// ───────────────────────────── Phase-2: the conversion block ─────────────────────────────

/// The `0xA7–0xBF` conversion block lowers each opcode to its IR `ConvOp` (cite
/// binary/instructions): wrap/extend/reinterpret reuse the EXISTING ConvOps, and the TRAPPING
/// trunc maps to `TruncS/U` (DISTINCT from the saturating `TruncSat*`). lower does not mark
/// the trapping trunc — emit_core wires the trap.
pub fn conversions_test() {
  let irm = build(conv_wasm)
  let f = func(irm, "f0")
  let convs =
    list.filter_map(all_exprs(f.body), fn(e) {
      case e {
        ir.Convert(op, _) -> Ok(op)
        _ -> Error(Nil)
      }
    })
  // wrap / extend → existing ConvOps
  list.contains(convs, ir.I32WrapI64) |> should.equal(True)
  list.contains(convs, ir.I64ExtendI32S) |> should.equal(True)
  list.contains(convs, ir.I64ExtendI32U) |> should.equal(True)
  // the 4 reinterprets → existing ReinterpretFToI / ReinterpretIToF
  list.contains(convs, ir.ReinterpretFToI(ir.FW32)) |> should.equal(True)
  list.contains(convs, ir.ReinterpretIToF(ir.W32)) |> should.equal(True)
  list.contains(convs, ir.ReinterpretFToI(ir.FW64)) |> should.equal(True)
  // trapping trunc → TruncS/U (NOT TruncSat*)
  list.contains(convs, ir.TruncU(ir.FW64, ir.W32)) |> should.equal(True)
  list.contains(convs, ir.TruncS(ir.FW32, ir.W32)) |> should.equal(True)
  // None of these are the saturating family.
  list.any(convs, fn(op) {
    case op {
      ir.TruncSatS(_, _) | ir.TruncSatU(_, _) -> True
      _ -> False
    }
  })
  |> should.equal(False)
}

// ───────────────────────────── Phase-2: float arithmetic ─────────────────────────────

/// `f64.add` lowers to the neutral, width-tagged `Num(FAdd(FW64), …)` (D6) — the float
/// arith ops share the integer NumOp shape, just at a float width.
pub fn float_add_structure_test() {
  let irm = build(fadd_wasm)
  let f = func(irm, "f0")
  f.result |> should.equal([ir.TF64])
  list.any(all_exprs(f.body), fn(e) {
    case e {
      ir.Num(ir.FAdd(ir.FW64), _) -> True
      _ -> False
    }
  })
  |> should.equal(True)
}

/// END-TO-END: `f64.add` runs spec-correctly through lower → emit_core → `rt_num` → BEAM.
/// Floats are raw IEEE-754 bit patterns end-to-end (D5): `1.5 + 2.5 == 4.0` is asserted on
/// the bit patterns (`0x3FF8…` + `0x4004…` == `0x4010…`). This proves the float-arith
/// lowering composes with the existing backend, not just that the IR shape is right.
pub fn float_add_e2e_test() {
  let mod = load(build(fadd_wasm))
  // 1.5 = 4609434218613702656, 2.5 = 4612811918334230528, 4.0 = 4616189618054758400
  catch_apply(mod, atom.create("fadd"), [
    4_609_434_218_613_702_656,
    4_612_811_918_334_230_528,
  ])
  |> should.equal(Ok(4_616_189_618_054_758_400))
}

// ───────────────────────────── Phase-2: module decls (memory/data/start) ─────────────────────────────

/// A module with a memory, an active data segment, and a `start` function populates
/// `Module.memory` (`Some`), `Module.data_segments` (the offset const-expr + raw bytes), and
/// `Module.start` (`Some("f<funcidx>")`). The data bytes are bit-exact (`"abc"`).
pub fn data_start_test() {
  let irm = build(data_start_wasm)
  irm.memories |> should.equal([ir.MemoryDecl(1, option.None, ir.Idx32)])
  irm.data_segments
  |> should.equal([
    ir.DataSegment(
      ir.DataActive(0, ir.Values([ir.ConstI32(0)])),
      bit_array.from_string("abc"),
    ),
  ])
  irm.start |> should.equal(option.Some("f0"))
}

// ───────────────────────────── Phase-2: .ir round-trip (unit 02) ─────────────────────────────

/// The lowered IR with the new Phase-2 variants round-trips through the `.ir` printer+parser
/// (D7, unit 02): `parse(print(m)) == m` (bit-exact, since the IR stores floats/ints as raw
/// bit patterns). Exercised over a memory module, a global module, a table+element module, and
/// a conversion module — covering `MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`GlobalGet`/
/// `GlobalSet`/`CallIndirect`/`TableDecl`/`ElementSegment`/`GlobalDecl`/`DataSegment` and the
/// new ConvOps.
pub fn ir_roundtrip_test() {
  [mem_wasm, grow_wasm, global_wasm, ci_full_wasm, conv_wasm, data_start_wasm]
  |> list.each(fn(bytes) {
    let m = build(bytes)
    let assert Ok(reparsed) = parser.parse_module(printer.print_module(m))
    reparsed |> should.equal(m)
  })
}

// ───────────────────────────── Phase-2: fail-closed const-expr ─────────────────────────────

/// A non-constant init expression (an extended-const `i32.add` chain in a global) is rejected
/// with a typed `Error(NonConstInitExpr(_))`, never a panic (D4 fail-closed). Validation
/// already blocks this, so the case is reached by handing `lower` a `TypedModule` directly —
/// proving the constructive const-expr lowering is itself fail-closed (Phase-2 MVP accepts
/// only a single `t.const`; cite valid/instructions constant expressions).
pub fn nonconst_init_fail_closed_test() {
  let m =
    ast.Module(
      imported_func_count: 0,
      types: [],
      tables: [],
      memories: [],
      globals: [
        ast.Global(ty: ast.I32, mutable: False, init: [
          ast.I32Const(1),
          ast.I32Const(2),
          ast.I32Add,
        ]),
      ],
      funcs: [],
      start: option.None,
      elements: [],
      data: [],
      exports: [],
    )
  let tm =
    validate.TypedModule(
      module: m,
      imported_func_count: 0,
      func_types: [],
      func_locals: [],
      global_types: [ast.I32],
    )
  case lower.lower(tm) {
    Error(lower.NonConstInitExpr(_)) -> True
    _ -> False
  }
  |> should.equal(True)
}

// ───────────────────────────── fail-closed totality ─────────────────────────────

/// The whole frontend (decode → validate → lower) is TOTAL over hostile input: every
/// stage yields `Ok`/`Error`, never a panic (overview D4 fail-closed). Single-byte
/// mutations of a real fixture exercise malformed bytes, ill-typed modules, and
/// out-of-scope constructs alike — none may crash.
pub fn frontend_totality_test() {
  let base = ba_to_list(sum_to_wasm)
  let len = list.length(base)
  let positions = int_range(0, len - 1)
  // A spread of bytes: zero, a valtype/blocktype byte, all-ones, empty blocktype,
  // `end`, and an opcode — covering structural, typing and unknown-opcode faults.
  let values = [0x00, 0x7f, 0xff, 0x40, 0x0b, 0x6a]
  list.all(positions, fn(pos) {
    list.all(values, fn(v) { chain_total(list_to_ba(replace(base, pos, v))) })
  })
  |> should.equal(True)
}

/// Run decode → validate → lower, confirming each stage returns a `Result` (forces
/// evaluation). `True` always; a crash would fail the test by panicking.
fn chain_total(bytes: BitArray) -> Bool {
  case decode.decode(bytes) {
    Error(_) -> True
    Ok(m) ->
      case validate.validate(m) {
        Error(_) -> True
        Ok(t) ->
          case lower.lower(t) {
            Ok(_) -> True
            Error(_) -> True
          }
      }
  }
}

// ───────────────────────────── END-TO-END on the BEAM ─────────────────────────────

/// `add(2,3) == 5`; and i32 addition wraps two's-complement through the whole chain
/// (`0x7FFFFFFF + 1 == 0x80000000 == 2147483648` unsigned) — WASM `i32.add` is mod 2^32.
pub fn add_e2e_test() {
  let mod = load(build(add_wasm))
  catch_apply(mod, atom.create("add"), [2, 3]) |> should.equal(Ok(5))
  catch_apply(mod, atom.create("add"), [2_147_483_647, 1])
  |> should.equal(Ok(2_147_483_648))
}

/// `sum_to(n) == n*(n+1)/2` running through the lowered `Loop`: `sum_to(100) == 5050`,
/// `sum_to(10) == 55`, `sum_to(0) == 0`.
pub fn sum_to_e2e_test() {
  let mod = load(build(sum_to_wasm))
  catch_apply(mod, atom.create("sum_to"), [100]) |> should.equal(Ok(5050))
  catch_apply(mod, atom.create("sum_to"), [10]) |> should.equal(Ok(55))
  catch_apply(mod, atom.create("sum_to"), [0]) |> should.equal(Ok(0))
}

/// `fib(10) == 55` via the lowered `If` + recursive `CallDirect`; boundary `fib(0)==0`,
/// `fib(1)==1`.
pub fn fib_e2e_test() {
  let mod = load(build(fib_wasm))
  catch_apply(mod, atom.create("fib"), [10]) |> should.equal(Ok(55))
  catch_apply(mod, atom.create("fib"), [0]) |> should.equal(Ok(0))
  catch_apply(mod, atom.create("fib"), [1]) |> should.equal(Ok(1))
}

/// REGRESSION (spec: a structured branch may target an `if`). A `br 0` inside an `if`
/// arm exits the `if` itself — `f` is `(i32.add (if (result i32) (local.get 0)
///   (then (br 0 (i32.const 100)) …dead…) (else (i32.const 5))) (i32.const 1))`.
///
/// Per the WASM spec a label index counts the enclosing structured blocks, and an `if`
/// IS one of them; `br 0` from a then/else arm forwards out of the `if` carrying its
/// result. So `f(1) == 101` (then taken: the `br` yields 100, then `+1`) and `f(0) == 6`
/// (else: 5, then `+1`). The IR `If` carries no label, so the frontend hosts the `if`'s
/// label in a wrapping `ir.Block`; before that fix this module failed to emit with
/// `UnboundLabel`.
pub fn br_to_if_e2e_test() {
  let mod = load(build(br_to_if_wasm))
  catch_apply(mod, atom.create("f"), [1]) |> should.equal(Ok(101))
  catch_apply(mod, atom.create("f"), [0]) |> should.equal(Ok(6))
}

// ───────────────────────────── fixtures ─────────────────────────────

const add_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60, 0x02,
  0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x61,
  0x64, 0x64, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01,
  0x6a, 0x0b,
>>

const sum_to_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x73, 0x75,
  0x6d, 0x5f, 0x74, 0x6f, 0x00, 0x00, 0x0a, 0x29, 0x01, 0x27, 0x01, 0x02, 0x7f,
  0x41, 0x01, 0x21, 0x01, 0x02, 0x40, 0x03, 0x40, 0x20, 0x01, 0x20, 0x00, 0x4a,
  0x0d, 0x01, 0x20, 0x02, 0x20, 0x01, 0x6a, 0x21, 0x02, 0x20, 0x01, 0x41, 0x01,
  0x6a, 0x21, 0x01, 0x0c, 0x00, 0x0b, 0x0b, 0x20, 0x02, 0x0b,
>>

const fib_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x66, 0x69,
  0x62, 0x00, 0x00, 0x0a, 0x1e, 0x01, 0x1c, 0x00, 0x20, 0x00, 0x41, 0x02, 0x48,
  0x04, 0x7f, 0x20, 0x00, 0x05, 0x20, 0x00, 0x41, 0x01, 0x6b, 0x10, 0x00, 0x20,
  0x00, 0x41, 0x02, 0x6b, 0x10, 0x00, 0x6a, 0x0b, 0x0b,
>>

// `(func (export "f") (param i32) (result i32)
//    (i32.add
//      (if (result i32) (local.get 0)
//        (then (br 0 (i32.const 100)) (i32.const 999))
//        (else (i32.const 5)))
//      (i32.const 1)))` — produced with wat2wasm. The `br 0` targets the `if`.
const br_to_if_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00,
  0x00, 0x0a, 0x17, 0x01, 0x15, 0x00, 0x20, 0x00, 0x04, 0x7f, 0x41, 0xe4, 0x00,
  0x0c, 0x00, 0x41, 0xe7, 0x07, 0x05, 0x41, 0x05, 0x0b, 0x41, 0x01, 0x6a, 0x0b,
>>

// ── Phase-2 fixtures (all produced with wat2wasm; the WAT is in the doc comment) ──

// `(memory 1 2) (func (export "m") (param i32) (result i32)
//    (i32.store (local.get 0) (i32.const 42))
//    (drop (i32.load8_s (local.get 0))) (drop (i64.load8_s (local.get 0)))
//    (drop (f32.load (local.get 0))) (i32.load (local.get 0)))`
const mem_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 2, 1, 0, 5, 4, 1,
  1, 1, 2, 7, 5, 1, 1, 109, 0, 0, 10, 34, 1, 32, 0, 32, 0, 65, 42, 54, 2, 0, 32,
  0, 44, 0, 0, 26, 32, 0, 48, 0, 0, 26, 32, 0, 42, 2, 0, 26, 32, 0, 40, 2, 0, 11,
>>

// `(memory 1) (func (export "g") (result i32)
//    (drop (memory.grow (i32.const 1))) (memory.size))`
const grow_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1,
  7, 5, 1, 1, 103, 0, 0, 10, 11, 1, 9, 0, 65, 1, 64, 0, 26, 63, 0, 11,
>>

// `(global $g (mut i32) (i32.const 100)) (global $h i64 (i64.const 7))
//  (func (export "gg") (result i32) (global.set $g (i32.const 5)) (global.get $g))`
const global_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0, 6, 12, 2, 127,
  1, 65, 228, 0, 11, 126, 0, 66, 7, 11, 7, 6, 1, 2, 103, 103, 0, 0, 10, 10, 1, 8,
  0, 65, 5, 36, 0, 35, 0, 11,
>>

// `(type $t (func (result i32))) (table 1 funcref) (elem (i32.const 0) $f)
//  (func $f (type $t) (result i32) (i32.const 42))
//  (func (export "ci") (result i32) (call_indirect (type $t) (i32.const 0)))`
const ci_full_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 3, 2, 0, 0, 4, 4, 1,
  112, 0, 1, 7, 6, 1, 2, 99, 105, 0, 1, 9, 7, 1, 0, 65, 0, 11, 1, 0, 10, 14, 2,
  4, 0, 65, 42, 11, 7, 0, 65, 0, 17, 0, 0, 11,
>>

// `(func (export "s") (param i32 i32 i32) (result i32)
//    (select (local.get 0) (local.get 1) (local.get 2)))`
const select_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 8, 1, 96, 3, 127, 127, 127, 1, 127, 3, 2, 1, 0,
  7, 5, 1, 1, 115, 0, 0, 10, 11, 1, 9, 0, 32, 0, 32, 1, 32, 2, 27, 11,
>>

// `(func (export "s64") (param i64 i64 i32) (result i64)
//    (select (local.get 0) (local.get 1) (local.get 2)))`
const select64_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 8, 1, 96, 3, 126, 126, 127, 1, 126, 3, 2, 1, 0,
  7, 7, 1, 3, 115, 54, 52, 0, 0, 10, 11, 1, 9, 0, 32, 0, 32, 1, 32, 2, 27, 11,
>>

// `(func (export "c") (param i64 i32 f32 f64) (result i32)
//    (drop (i32.wrap_i64 (local.get 0))) (drop (i64.extend_i32_s (local.get 1)))
//    (drop (i64.extend_i32_u (local.get 1))) (drop (i32.reinterpret_f32 (local.get 2)))
//    (drop (f32.reinterpret_i32 (local.get 1))) (drop (i64.reinterpret_f64 (local.get 3)))
//    (drop (i32.trunc_f64_u (local.get 3))) (i32.trunc_f32_s (local.get 2)))`
const conv_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 9, 1, 96, 4, 126, 127, 125, 124, 1, 127, 3, 2,
  1, 0, 7, 5, 1, 1, 99, 0, 0, 10, 35, 1, 33, 0, 32, 0, 167, 26, 32, 1, 172, 26,
  32, 1, 173, 26, 32, 2, 188, 26, 32, 1, 190, 26, 32, 3, 189, 26, 32, 3, 171, 26,
  32, 2, 168, 11,
>>

// `(memory 1) (data (i32.const 0) "abc") (start $init) (func $init)`
const data_start_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 5, 3, 1, 0, 1, 8,
  1, 0, 10, 4, 1, 2, 0, 11, 11, 9, 1, 0, 65, 0, 11, 3, 97, 98, 99,
>>

// `(func (export "fadd") (param f64 f64) (result f64) (f64.add (local.get 0) (local.get 1)))`
const fadd_wasm: BitArray = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 124, 124, 1, 124, 3, 2, 1, 0, 7,
  8, 1, 4, 102, 97, 100, 100, 0, 0, 10, 9, 1, 7, 0, 32, 0, 32, 1, 160, 11,
>>
