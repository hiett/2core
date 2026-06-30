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
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/ir
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
  irm.memory |> should.equal(option.None)
}

/// The export survives lowering: `add` is exported (resolving to the function's IR
/// name).
pub fn export_preserved_test() {
  let irm = build(add_wasm)
  list.any(irm.exports, fn(e) {
    case e {
      ir.ExportFn(export_name, _) -> export_name == "add"
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

// ───────────────────────────── out-of-scope: typed error, not a panic ─────────────────────────────

/// `call_indirect` is out of Phase-1 lowering scope and is rejected fail-closed before
/// it can run — never a panic. As of Phase-2 the validator *types* `call_indirect` (a
/// well-typed module with a declared table is now accepted), so the rejection moves to
/// `lower`, which returns `Unsupported("call_indirect")` until unit 09 lowers it.
pub fn call_indirect_rejected_test() {
  let assert Ok(m) = decode.decode(call_indirect_wasm)
  let assert Ok(tm) = validate.validate(m)
  case lower.lower(tm) {
    Error(lower.Unsupported("call_indirect")) -> True
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

// A module using `call_indirect` (out of Phase-1 scope) — produced with wat2wasm.
const call_indirect_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00, 0x01, 0x07,
  0x05, 0x01, 0x01, 0x67, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00,
  0x11, 0x00, 0x00, 0x0b,
>>
