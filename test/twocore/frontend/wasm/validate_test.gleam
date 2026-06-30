//// Spec-based conformance tests for `twocore/frontend/wasm/validate` (Unit 10a).
////
//// Assertions target the WebAssembly core spec's VALIDATION rules
//// (<https://webassembly.github.io/spec/core/valid/>) and the abstract stack-typing
//// algorithm (<https://webassembly.github.io/spec/core/appendix/algorithm.html>) — NOT
//// whatever the implementation happens to emit. Each negative case cites the rule it
//// violates. This suite has **no IR dependency**: it gates the security boundary
//// independently of lowering/backend.
////
//// Fixtures are `.wasm` bytes. The valid ones are produced by `wat2wasm`; the invalid
//// ones by `wat2wasm --no-check` (so the bytes decode cleanly but must be REJECTED by
//// validation). Each invalid module decodes successfully — the failure is a typing
//// fault, exactly what `validate` must catch.

import gleam/option.{None, Some}
import gleeunit/should
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/validate

// ───────────────────────────── helper ─────────────────────────────

/// Decode then validate `bytes`. The decode must succeed (these fixtures are
/// structurally well-formed); the returned `Result` is the validation outcome.
fn validated(
  bytes: BitArray,
) -> Result(validate.TypedModule, validate.ValidateError) {
  let assert Ok(m) = decode.decode(bytes)
  validate.validate(m)
}

/// Assert a module is accepted (well-typed).
fn accept(bytes: BitArray) {
  case validated(bytes) {
    Ok(_) -> True
    Error(_) -> False
  }
  |> should.equal(True)
}

// ── hand-built `ast.Module` helpers (for the Phase-2 rejection cases) ──
// The unit's negative tests target the *typing rule* directly, so they construct
// ill-typed `ast.Module` values (each decodes from valid bytes in principle, but
// hand-building lets us hit out-of-range indices / multi-memory / bad limits / start
// signatures that `wat2wasm` would refuse to emit) and validate them in isolation.

/// A function type `params -> results`.
fn ft(params: List(ast.ValType), results: List(ast.ValType)) -> ast.FuncType {
  ast.FuncType(params, results)
}

/// A defined function with `type_idx`, no extra declared locals, and `body` (whose
/// trailing `ast.End` closes the implicit function frame).
fn func_(type_idx: Int, body: List(ast.Instr)) -> ast.Func {
  ast.Func(type_idx: type_idx, locals: [], body: body)
}

/// A memory type with `min` pages and optional `max`.
fn mem(min: Int, max: option.Option(Int)) -> ast.MemType {
  ast.MemType(ast.Limits(min, max))
}

/// A (funcref) table type with `min` entries and optional `max`.
fn tbl(min: Int, max: option.Option(Int)) -> ast.TableType {
  ast.TableType(ast.Limits(min, max))
}

/// An otherwise-empty module; callers override the fields they exercise.
fn module(
  types types: List(ast.FuncType),
  tables tables: List(ast.TableType),
  memories memories: List(ast.MemType),
  globals globals: List(ast.Global),
  funcs funcs: List(ast.Func),
  start start: option.Option(Int),
  elements elements: List(ast.ElementSegment),
  data data: List(ast.DataSegment),
) -> ast.Module {
  ast.Module(
    imported_func_count: 0,
    types: types,
    tables: tables,
    memories: memories,
    globals: globals,
    funcs: funcs,
    start: start,
    elements: elements,
    data: data,
    exports: [],
  )
}

// ───────────────────────────── valid acceptance ─────────────────────────────
// Spec: a module is valid iff every function body type-checks. The Phase-1 corpus
// and a few tricky-but-legal shapes must all be ACCEPTED.

/// `add(i32,i32)->i32` is well-typed.
pub fn accept_add_test() {
  accept(add_wasm)
}

/// `sum_to` (block + loop + br_if/br + mutable locals) is well-typed — exercises
/// `loop` label = INPUT types and a `br_if` to an enclosing block.
pub fn accept_sum_to_test() {
  accept(sum_to_wasm)
}

/// `fib` (an `if (result i32)` with `else` + a direct self-`call`) is well-typed.
pub fn accept_fib_test() {
  accept(fib_wasm)
}

/// An `if` with NO `else` whose blocktype params==results (here empty) is valid
/// (spec: an else-less `if` is valid when its inputs and results coincide).
pub fn accept_elseless_balanced_test() {
  accept(elseless_valid_wasm)
}

/// A `block` with a multi-value result type (`() -> (i32, i32)`, a `typeidx`
/// blocktype) is valid (spec: multi-value blocks).
pub fn accept_multivalue_block_test() {
  accept(mv_wasm)
}

/// An `if`/`else` that both yield i32 (`abs`) is valid.
pub fn accept_if_else_test() {
  accept(abs_wasm)
}

// ── polymorphic stack (the algorithm's hard part) ──
// Spec: after `unreachable` the operand stack is polymorphic; `Unknown` unifies with
// any expected type, so these are valid.

/// `(func (result i32) unreachable)` — `unreachable` makes the stack polymorphic, so
/// the missing i32 result unifies (spec: stack-polymorphic `unreachable`).
pub fn accept_unreachable_result_test() {
  accept(poly_unreachable_wasm)
}

/// `(func (result i32) unreachable i32.add)` — a stack-polymorphic `i32.add` after
/// `unreachable` validates (its operands come from the polymorphic `Unknown`).
pub fn accept_unreachable_then_op_test() {
  accept(poly_after_wasm)
}

// ───────────────────────────── invalid rejection ─────────────────────────────
// Each must be REJECTED with a typed ValidateError (never accepted, never a panic).

/// Operand-stack underflow: `i32.add` with no operands (spec: the operand stack must
/// provide the instruction's inputs).
pub fn reject_underflow_test() {
  validated(underflow_wasm)
  |> should.equal(Error(validate.Underflow))
}

/// Result type mismatch: a function declared `-> i32` whose body leaves an i64 (spec:
/// the body's result types must match the function type).
pub fn reject_result_mismatch_test() {
  validated(resultmismatch_wasm)
  |> should.equal(Error(validate.TypeMismatch))
}

/// Operand type mismatch: `i64.add` applied to i32 operands (spec: numeric typing
/// rule — operands must be the op's width).
pub fn reject_operand_mismatch_test() {
  validated(operandmismatch_wasm)
  |> should.equal(Error(validate.TypeMismatch))
}

/// Branch to an out-of-range label: `br 5` with only the function frame in scope
/// (spec: the branch label must reference an enclosing control frame).
pub fn reject_bad_label_test() {
  validated(badlabel_wasm)
  |> should.equal(Error(validate.UnknownLabel(5)))
}

/// Out-of-range local: `local.get 9` in a function with no locals (spec: the local
/// index must be in range).
pub fn reject_bad_local_test() {
  validated(badlocal_wasm)
  |> should.equal(Error(validate.UnknownLocal(9)))
}

/// `if`/`else` arms with different result types (then i32, else i64) — rejected
/// because the else arm does not produce the block's result type (spec: both arms of
/// an `if` share the blocktype results).
pub fn reject_if_else_mismatch_test() {
  validated(ifelsemismatch_wasm)
  |> should.equal(Error(validate.TypeMismatch))
}

/// Else-less `if` whose params differ from results (`if (result i32)` with no else):
/// only valid when params==results (spec: else-less `if`).
pub fn reject_elseless_unbalanced_test() {
  validated(elseless_wasm)
  |> should.equal(Error(validate.IfElseMismatch))
}

/// Call signature mismatch: `call` to a function expecting i64 with an i32 on the
/// stack (spec: a `call`'s operands must match the callee's parameter types).
pub fn reject_call_signature_test() {
  validated(callsig_wasm)
  |> should.equal(Error(validate.TypeMismatch))
}

/// Call to an out-of-range funcidx: `call 7` in a single-function module (spec: the
/// funcidx must be in range).
pub fn reject_bad_func_test() {
  validated(badfunc_wasm)
  |> should.equal(Error(validate.UnknownFunc(7)))
}

// ═════════════════════════ Phase-2 (unit 08) acceptance ═════════════════════════
// Spec `valid/instructions` + `valid/modules`: well-typed modules that use memory,
// globals, tables, floats, the conversion block, and `select` must be ACCEPTED, and
// the `TypedModule` must carry the typing facts lowering needs. Fixtures are real
// `wat2wasm` output (so they also exercise decode→validate).

/// `i32.store` then `i32.load` round-trip (spec: load pops an i32 address & pushes the
/// result; store pops value then address) — accepted with a declared memory.
pub fn accept_mem_roundtrip_test() {
  accept(mem_roundtrip_wasm)
}

/// `i32.load8_s` / `i32.load16_u` (the narrow-load width matrix) are accepted; each
/// pops an i32 address and pushes i32 (spec load typing).
pub fn accept_load_widths_test() {
  accept(load_widths_wasm)
}

/// `f64.add` (`[f64,f64]->[f64]`), `f32.sqrt` (`[f32]->[f32]`), `f32.eq`
/// (`[f32,f32]->[i32]`) — the float arith/unary/compare signatures (spec numeric
/// typing) are accepted.
pub fn accept_floats_test() {
  accept(floats_wasm)
}

/// A mutable global round-trips through `global.set` (valid only on a `var` global)
/// and `global.get` (spec `valid/instructions` global rules).
pub fn accept_mutable_global_test() {
  accept(mutable_global_wasm)
}

/// `call_indirect (type 0)` with a declared funcref table and an in-range typeidx
/// is accepted: it pops the i32 table index then the type's params and pushes its
/// results (spec `valid/instructions` call_indirect).
pub fn accept_call_indirect_test() {
  accept(call_indirect_wasm)
}

/// `i32.wrap_i64` (`[i64]->[i32]`), `f64.convert_i32_s` (`[i32]->[f64]`),
/// `i32.reinterpret_f32` (`[f32]->[i32]`) — representatives of the `0xA7–0xBF`
/// conversion block (width-only typing) are accepted.
pub fn accept_conversions_test() {
  accept(conversions_wasm)
}

/// `select` of two i32s with an i32 condition (`t t i32 -> t`) is accepted (spec
/// parametric `select`).
pub fn accept_select_i32_test() {
  accept(select_i32_wasm)
}

/// The `TypedModule` carries the value type of each global by index — here a single
/// mutable `i32` global → `global_types == [I32]` (the one fact lowering cannot
/// re-derive; deliverable §2).
pub fn typed_module_carries_global_types_test() {
  let assert Ok(tm) = validated(mutable_global_wasm)
  tm.global_types
  |> should.equal([ast.I32])
}

/// Active data + element segments with `i32.const` offsets and an in-range funcidx
/// are accepted (spec `valid/modules`: offsets are i32 const-exprs, elem funcidx in
/// range). Hand-built so we control both segments.
pub fn accept_active_segments_test() {
  module(
    types: [ft([], [])],
    tables: [tbl(1, None)],
    memories: [mem(1, None)],
    globals: [],
    funcs: [func_(0, [ast.End])],
    start: None,
    elements: [
      ast.ElementSegment(table: 0, offset: [ast.I32Const(0)], funcs: [0]),
    ],
    data: [
      ast.DataSegment(mem: 0, offset: [ast.I32Const(0)], bytes: <<1, 2, 3>>),
    ],
  )
  |> validate.validate()
  |> is_ok()
  |> should.equal(True)
}

// ═════════════════════════ Phase-2 (unit 08) rejection ═════════════════════════
// Each rejects with the spec-cited `ValidateError`. Modules are hand-built so we can
// target the exact rule (out-of-range indices / multi-memory / bad limits / start
// signature) that `wat2wasm` would refuse to emit.

/// Alignment too large: `i32.load align=3` (`2^3 = 8 > 4` natural bytes) — spec memarg
/// rule "`2^align` must not be larger than `N/8`" (`align.wast`).
pub fn reject_bad_align_i32_load_test() {
  module(
    types: [ft([ast.I32], [ast.I32])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.I32Load(ast.MemArg(align: 3, offset: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadAlignment))
}

/// Alignment too large on a narrow load: `i32.load8_s align=1` (`2^1 = 2 > 1`) — spec
/// memarg rule (`align.wast`).
pub fn reject_bad_align_load8_test() {
  module(
    types: [ft([ast.I32], [ast.I32])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.I32Load8S(ast.MemArg(align: 1, offset: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadAlignment))
}

/// `global.set` on a `const` (immutable) global is a validation error (spec
/// `valid/instructions` global.set rule; `global.wast`).
pub fn reject_immutable_global_set_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [],
    globals: [ast.Global(ty: ast.I32, mutable: False, init: [ast.I32Const(0)])],
    funcs: [func_(0, [ast.I32Const(5), ast.GlobalSet(0), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.ImmutableGlobal(0)))
}

/// An extended-const global init (`i32.const 0 i32.const 1 i32.add`) is NOT a Phase-2
/// constant expression — MVP permits only a single `t.const` (extended-const proposal;
/// `global.wast` `$z3`).
pub fn reject_extended_const_init_test() {
  module(
    types: [],
    tables: [],
    memories: [],
    globals: [
      ast.Global(ty: ast.I32, mutable: False, init: [
        ast.I32Const(0),
        ast.I32Const(1),
        ast.I32Add,
      ]),
    ],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.NonConstantExpr))
}

/// A `global.get` init expr has no valid referent in Phase 2 (only immutable imported
/// globals qualify, and there are none) — rejected (`global.wast` `$z5`;
/// extended-const proposal).
pub fn reject_global_get_init_test() {
  module(
    types: [],
    tables: [],
    memories: [],
    globals: [
      ast.Global(ty: ast.I32, mutable: False, init: [ast.I32Const(1)]),
      ast.Global(ty: ast.I32, mutable: False, init: [ast.GlobalGet(0)]),
    ],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.NonConstantExpr))
}

/// `i64.store` fed an `f32` value: the store pops its value type (i64) but the operand
/// is f32 (spec store typing).
pub fn reject_store_value_mismatch_test() {
  module(
    types: [ft([ast.I32, ast.F32], [])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.LocalGet(1),
        ast.I64Store(ast.MemArg(align: 0, offset: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// `i32.load` with an `f64` address: the load pops an i32 address but the operand is
/// f64 (spec load typing).
pub fn reject_load_address_mismatch_test() {
  module(
    types: [ft([ast.F64], [ast.I32])],
    tables: [],
    memories: [mem(1, None)],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.I32Load(ast.MemArg(align: 0, offset: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// `select` of an i32 and an i64: the two values must share a type (spec parametric
/// `select`).
pub fn reject_select_type_mismatch_test() {
  module(
    types: [ft([ast.I32, ast.I64, ast.I32], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.LocalGet(1),
        ast.LocalGet(2),
        ast.Select,
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// A global init whose const is the wrong type (`f32.const` for an `i64` global) —
/// the const-expr type must equal the global's declared type (spec const-exprs).
pub fn reject_global_init_type_mismatch_test() {
  module(
    types: [],
    tables: [],
    memories: [],
    globals: [ast.Global(ty: ast.I64, mutable: False, init: [ast.F32Const(0)])],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TypeMismatch))
}

/// `call_indirect` with a typeidx past the type section — the static typeidx must be
/// in range (spec `valid/instructions`; `call_indirect.wast`).
pub fn reject_call_indirect_bad_type_test() {
  module(
    types: [ft([], [])],
    tables: [tbl(1, None)],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.I32Const(0), ast.CallIndirect(5, 0), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownType(5)))
}

/// `call_indirect` in a module with no table — a table must exist (spec
/// `valid/instructions`).
pub fn reject_call_indirect_no_table_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.I32Const(0), ast.CallIndirect(0, 0), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownTable(0)))
}

/// An `i32.load` in a module with no memory — a memory must exist (spec
/// `valid/instructions`).
pub fn reject_load_no_memory_test() {
  module(
    types: [ft([ast.I32], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [
      func_(0, [
        ast.LocalGet(0),
        ast.I32Load(ast.MemArg(align: 0, offset: 0)),
        ast.End,
      ]),
    ],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownMemory(0)))
}

/// `memory.size` in a module with no memory — a memory must exist (spec
/// `valid/instructions`).
pub fn reject_memory_size_no_memory_test() {
  module(
    types: [ft([], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.MemorySize, ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownMemory(0)))
}

/// `global.get` out of range — the globalidx must be in range (spec
/// `valid/instructions`).
pub fn reject_global_get_out_of_range_test() {
  module(
    types: [ft([], [ast.I32])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.GlobalGet(3), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownGlobal(3)))
}

/// `global.set` out of range — the globalidx must be in range (spec
/// `valid/instructions`).
pub fn reject_global_set_out_of_range_test() {
  module(
    types: [ft([], [])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.I32Const(0), ast.GlobalSet(2), ast.End])],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownGlobal(2)))
}

/// More than one memory (MVP: at most one) — rejected (spec/MVP module limits).
pub fn reject_multiple_memories_test() {
  module(
    types: [],
    tables: [],
    memories: [mem(1, None), mem(1, None)],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TooManyMemories))
}

/// More than one table (MVP: at most one) — rejected (spec/MVP module limits).
pub fn reject_multiple_tables_test() {
  module(
    types: [],
    tables: [tbl(1, None), tbl(1, None)],
    memories: [],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.TooManyTables))
}

/// A memory limit with `min > max` is invalid (spec `valid/types`: `min <= max`).
pub fn reject_memory_min_gt_max_test() {
  module(
    types: [],
    tables: [],
    memories: [mem(2, Some(1))],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadLimits))
}

/// A memory whose `min` exceeds the `2^16`-page range is invalid (spec `valid/types`:
/// memory limit range is `2^16`).
pub fn reject_memory_over_range_test() {
  module(
    types: [],
    tables: [],
    memories: [mem(70_000, None)],
    globals: [],
    funcs: [],
    start: None,
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadLimits))
}

/// A `start` function whose type is not `[] -> []` is invalid (spec `valid/modules`
/// start rule).
pub fn reject_bad_start_type_test() {
  module(
    types: [ft([ast.I32], [])],
    tables: [],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.End])],
    start: Some(0),
    elements: [],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.BadStartType))
}

/// An active element segment whose funcidx is out of the function index space is
/// invalid (spec `valid/modules` elements: every funcidx in range).
pub fn reject_element_func_out_of_range_test() {
  module(
    types: [ft([], [])],
    tables: [tbl(1, None)],
    memories: [],
    globals: [],
    funcs: [func_(0, [ast.End])],
    start: None,
    elements: [
      ast.ElementSegment(table: 0, offset: [ast.I32Const(0)], funcs: [5]),
    ],
    data: [],
  )
  |> validate.validate()
  |> should.equal(Error(validate.UnknownFunc(5)))
}

/// `True` if a `Result` is `Ok`, discarding both payloads (for acceptance asserts on
/// hand-built modules where the exact `TypedModule` is not under test).
fn is_ok(r: Result(a, b)) -> Bool {
  case r {
    Ok(_) -> True
    Error(_) -> False
  }
}

// ───────────────────────────── fixtures ─────────────────────────────
// Valid (wat2wasm) and invalid (wat2wasm --no-check) `.wasm` byte literals.

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

const elseless_valid_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x01,
  0x7f, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20, 0x00, 0x04, 0x40, 0x01, 0x0b, 0x0b,
>>

// () -> (i32, i32) block (multi-value typeidx blocktype).
const mv_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x00,
  0x02, 0x7f, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x06, 0x01, 0x02, 0x6d, 0x76,
  0x00, 0x00, 0x0a, 0x0b, 0x01, 0x09, 0x00, 0x02, 0x00, 0x41, 0x01, 0x41, 0x02,
  0x0b, 0x0b,
>>

// abs(i32)->i32 via `if (result i32) ... else ... end`.
const abs_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x61, 0x62,
  0x73, 0x00, 0x00, 0x0a, 0x14, 0x01, 0x12, 0x00, 0x20, 0x00, 0x41, 0x00, 0x48,
  0x04, 0x7f, 0x41, 0x00, 0x20, 0x00, 0x6b, 0x05, 0x20, 0x00, 0x0b, 0x0b,
>>

const poly_unreachable_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b,
>>

const poly_after_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x00, 0x6a, 0x0b,
>>

const underflow_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x05, 0x01, 0x03, 0x00, 0x6a, 0x0b,
>>

const resultmismatch_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x42, 0x01, 0x0b,
>>

const operandmismatch_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01,
  0x7f, 0x01, 0x7e, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00,
  0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x00, 0x7c, 0x0b,
>>

const badlabel_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a,
  0x06, 0x01, 0x04, 0x00, 0x0c, 0x05, 0x0b,
>>

const badlocal_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x06, 0x01, 0x04, 0x00, 0x20, 0x09, 0x0b,
>>

const ifelsemismatch_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x41, 0x01, 0x04, 0x7f, 0x41, 0x05, 0x05, 0x42,
  0x07, 0x0b, 0x0b,
>>

const elseless_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
  0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41, 0x01, 0x04, 0x7f, 0x41, 0x05, 0x0b, 0x0b,
>>

const callsig_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60, 0x01,
  0x7e, 0x00, 0x60, 0x00, 0x00, 0x03, 0x03, 0x02, 0x00, 0x01, 0x07, 0x05, 0x01,
  0x01, 0x67, 0x00, 0x01, 0x0a, 0x0b, 0x02, 0x02, 0x00, 0x0b, 0x06, 0x00, 0x41,
  0x01, 0x10, 0x00, 0x0b,
>>

const badfunc_wasm: BitArray = <<
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00,
  0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a,
  0x06, 0x01, 0x04, 0x00, 0x10, 0x07, 0x0b,
>>

// ── Phase-2 acceptance fixtures (valid `wat2wasm` output) ──

const mem_roundtrip_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  6,
  1,
  96,
  1,
  127,
  1,
  127,
  3,
  2,
  1,
  0,
  5,
  3,
  1,
  0,
  1,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  16,
  1,
  14,
  0,
  32,
  0,
  65,
  42,
  54,
  2,
  0,
  32,
  0,
  40,
  2,
  0,
  11,
>>

const load_widths_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  6,
  1,
  96,
  1,
  127,
  1,
  127,
  3,
  2,
  1,
  0,
  5,
  3,
  1,
  0,
  1,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  15,
  1,
  13,
  0,
  32,
  0,
  44,
  0,
  0,
  32,
  0,
  47,
  1,
  0,
  106,
  11,
>>

const floats_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  7,
  1,
  96,
  2,
  125,
  124,
  1,
  127,
  3,
  2,
  1,
  0,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  16,
  1,
  14,
  0,
  32,
  1,
  32,
  1,
  160,
  26,
  32,
  0,
  145,
  32,
  0,
  91,
  11,
>>

const mutable_global_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  5,
  1,
  96,
  0,
  1,
  127,
  3,
  2,
  1,
  0,
  6,
  6,
  1,
  127,
  1,
  65,
  7,
  11,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  11,
  1,
  9,
  0,
  65,
  227,
  0,
  36,
  0,
  35,
  0,
  11,
>>

const call_indirect_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  6,
  1,
  96,
  1,
  127,
  1,
  127,
  3,
  2,
  1,
  0,
  4,
  4,
  1,
  112,
  0,
  1,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  11,
  1,
  9,
  0,
  32,
  0,
  65,
  0,
  17,
  0,
  0,
  11,
>>

const conversions_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  8,
  1,
  96,
  3,
  126,
  127,
  125,
  1,
  127,
  3,
  2,
  1,
  0,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  15,
  1,
  13,
  0,
  32,
  1,
  183,
  26,
  32,
  2,
  188,
  26,
  32,
  0,
  167,
  11,
>>

const select_i32_wasm: BitArray = <<
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  8,
  1,
  96,
  3,
  127,
  127,
  127,
  1,
  127,
  3,
  2,
  1,
  0,
  7,
  5,
  1,
  1,
  102,
  0,
  0,
  10,
  11,
  1,
  9,
  0,
  32,
  0,
  32,
  1,
  32,
  2,
  27,
  11,
>>
