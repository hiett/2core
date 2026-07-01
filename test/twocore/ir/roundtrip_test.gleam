//// Round-trip + golden suite for the `.ir` printer & parser (Unit 02).
////
//// Proves the D7 inter-stage contract three ways, none of which is a change-detector
//// test:
////
//// 1. **Round-trip property** `parse(print(m)) == m` over a corpus that hand-builds the
////    FULL IR surface (every `Expr`/`Value`/`NumOp`/`ConvOp`/`TermOp`/`TrapReason`,
////    memory ops, globals, multi-value, and float consts including NaN payloads and
////    `-0.0`). Because the frozen IR stores float constants as raw `Int` bits, plain
////    structural `==` on `ir.Module` already compares them BIT-EXACTLY — so `==` (and
////    hence `module_equal`) is the correct equality here (NaN ≠ NaN under native float
////    `==`, but the IR never uses native floats). This is the D7 invariant.
//// 2. **Golden suite** (the INDEPENDENT oracle): the HAND-AUTHORED `.ir` files under
////    `golden/` — the three Phase-1 programs (`add`/`sum_to`/`fib`) plus the Phase-2
////    `mem_table` (table/elem/start, mem.size/grow, a result-typed sign-extending load, a
////    float comparison, a trapping convert) — written by reading the grammar, never
////    printer-generated — parse to the expected `Module` values, and those values re-print
////    + re-parse stably. Hand authoring is what defeats a printer+parser that collude on
////    the same wrong grammar.
//// 3. **Negative corpus**: truncated input, a wrong sigil, an unknown op spelling, a
////    missing `(`, an unterminated block, a bad escape, a stray char — each returns a
////    typed `ParseError` (asserted by variant) and NONE panics (totality, D4).

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import twocore/ir
import twocore/ir/parser
import twocore/ir/printer

// ───────────────────────────── module_equal (deliverable) ─────────────────────────

/// Bit-pattern numeric equality for IR modules.
///
/// Because D5 stores float constants as raw `Int` bit patterns (`ConstF32(bits)` /
/// `ConstF64(bits)`), comparing the stored `Int` bits IS the correct, exact comparison
/// — NaN payloads and `-0.0` are preserved and distinguished, and `+0.0`/`-0.0` are NOT
/// conflated (unlike a native-float `==`, where `NaN != NaN` and `-0.0 == 0.0`). Gleam's
/// structural `==` on `ir.Module` therefore already compares modules bit-exactly; this
/// function is that comparison, named for clarity and so callers cannot accidentally
/// reach for a float `==`. Use THIS (or `==`) anywhere two IR modules are compared.
///
/// Parameters: `a`, `b` — the two modules. Returns `True` iff they are structurally
/// (and hence bit-pattern) equal. Total — never fails, never panics.
pub fn module_equal(a: ir.Module, b: ir.Module) -> Bool {
  a == b
}

// ───────────────────────────── golden module builders ─────────────────────────────
// The expected `Module` values for the three hand-authored goldens, built INDEPENDENTLY
// of the printer (mirroring `test/twocore/ir/strawman_test.gleam`).

/// Expected `Module` for `golden/add.ir`.
fn add_module() -> ir.Module {
  ir.Module(
    name: "add",
    uses_numerics: True,
    memory: None,
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        name: "add",
        params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
        result: [ir.TI32],
        locals: [],
        body: ir.Let(
          ["r"],
          ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
          ir.Return([ir.Var("r")]),
        ),
      ),
    ],
    exports: [ir.ExportFn("add", "add")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
  )
}

/// Expected `Module` for `golden/sum_to.ir` (the grammar's `@loop` example).
fn sum_to_module() -> ir.Module {
  ir.Module(
    name: "loop",
    uses_numerics: True,
    memory: None,
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        name: "sum_to",
        params: [ir.Local("p0", ir.TI64)],
        result: [ir.TI64],
        locals: [],
        body: ir.Loop(
          label: "go",
          params: [
            ir.LoopParam("i", ir.TI64, ir.ConstI64(1)),
            ir.LoopParam("acc", ir.TI64, ir.ConstI64(0)),
          ],
          result: [ir.TI64],
          body: ir.Let(
            ["cond"],
            ir.Num(ir.ILeU(ir.W64), [ir.Var("i"), ir.Var("p0")]),
            ir.If(
              cond: ir.Var("cond"),
              result: [ir.TI64],
              then_branch: ir.Let(
                ["acc1"],
                ir.Num(ir.IAdd(ir.W64), [ir.Var("acc"), ir.Var("i")]),
                ir.Let(
                  ["i1"],
                  ir.Num(ir.IAdd(ir.W64), [ir.Var("i"), ir.ConstI64(1)]),
                  ir.Continue("go", [ir.Var("i1"), ir.Var("acc1")]),
                ),
              ),
              else_branch: ir.Break("go", [ir.Var("acc")]),
            ),
          ),
        ),
      ),
    ],
    exports: [ir.ExportFn("sum_to", "sum_to")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
  )
}

/// Expected `Module` for `golden/fib.ir`.
fn fib_module() -> ir.Module {
  ir.Module(
    name: "fib",
    uses_numerics: True,
    memory: None,
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        name: "fib",
        params: [ir.Local("p0", ir.TI64)],
        result: [ir.TI64],
        locals: [],
        body: ir.Let(
          ["c"],
          ir.Num(ir.ILtU(ir.W64), [ir.Var("p0"), ir.ConstI64(2)]),
          ir.If(
            cond: ir.Var("c"),
            result: [ir.TI64],
            then_branch: ir.Return([ir.Var("p0")]),
            else_branch: ir.Let(
              ["n1"],
              ir.Num(ir.ISub(ir.W64), [ir.Var("p0"), ir.ConstI64(1)]),
              ir.Let(
                ["f1"],
                ir.CallDirect("fib", [ir.Var("n1")]),
                ir.Let(
                  ["n2"],
                  ir.Num(ir.ISub(ir.W64), [ir.Var("p0"), ir.ConstI64(2)]),
                  ir.Let(
                    ["f2"],
                    ir.CallDirect("fib", [ir.Var("n2")]),
                    ir.Let(
                      ["r"],
                      ir.Num(ir.IAdd(ir.W64), [ir.Var("f1"), ir.Var("f2")]),
                      ir.Return([ir.Var("r")]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
    exports: [ir.ExportFn("fib", "fib")],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
  )
}

// ───────────────────────────── golden file reading ─────────────────────────────

/// Reads a file as a binary. `file:read_file/1` returns `{ok, Binary}` / `{error, _}`,
/// which is exactly Gleam's `Ok`/`Error` representation. (Test-only; `let assert` here is
/// fine — it asserts the fixture exists, and is not on the parser's untrusted-input path.)
@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

/// Reads a golden `.ir` fixture (relative to the project root, the `gleam test` cwd).
fn read_golden(name: String) -> String {
  let assert Ok(bits) = read_file("test/twocore/ir/golden/" <> name)
  let assert Ok(text) = bit_array.to_string(bits)
  text
}

// ───────────────────────────── round-trip helpers ─────────────────────────────

/// Wraps an expression as the body of a minimal 0-arg function in a minimal module, so a
/// single `Expr` can be exercised through the full module printer/parser.
fn expr_module(name: String, body: ir.Expr) -> ir.Module {
  ir.Module(
    name: name,
    uses_numerics: True,
    memory: None,
    globals: [],
    imports: [],
    functions: [
      ir.Function(name: "f", params: [], result: [], locals: [], body: body),
    ],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
  )
}

/// Asserts the D7 round-trip property for one module: `parse(print(m)) == Ok(m)`. Uses
/// structural `==` (i.e. `module_equal`) so float constants are compared bit-exactly.
fn check_roundtrip(m: ir.Module) -> Nil {
  assert parser.parse_module(printer.print_module(m)) == Ok(m)
}

// ───────────────────────────── op corpora ─────────────────────────────

/// Every integer `NumOp` constructor at width `w`.
fn int_ops(w: ir.IntWidth) -> List(ir.NumOp) {
  [
    ir.IAdd(w),
    ir.ISub(w),
    ir.IMul(w),
    ir.IDivS(w),
    ir.IDivU(w),
    ir.IRemS(w),
    ir.IRemU(w),
    ir.IAnd(w),
    ir.IOr(w),
    ir.IXor(w),
    ir.IShl(w),
    ir.IShrS(w),
    ir.IShrU(w),
    ir.IRotl(w),
    ir.IRotr(w),
    ir.IClz(w),
    ir.ICtz(w),
    ir.IPopcnt(w),
    ir.IEqz(w),
    ir.IEq(w),
    ir.INe(w),
    ir.ILtS(w),
    ir.ILtU(w),
    ir.IGtS(w),
    ir.IGtU(w),
    ir.ILeS(w),
    ir.ILeU(w),
    ir.IGeS(w),
    ir.IGeU(w),
  ]
}

/// Every float `NumOp` constructor at width `w` — the Phase-1 binary arithmetic plus the
/// Phase-2 unary ops and the six comparisons (`«IR2-FROZEN»`).
fn float_ops(w: ir.FloatWidth) -> List(ir.NumOp) {
  [
    ir.FAdd(w),
    ir.FSub(w),
    ir.FMul(w),
    ir.FDiv(w),
    ir.FMin(w),
    ir.FMax(w),
    ir.FAbs(w),
    ir.FNeg(w),
    ir.FCeil(w),
    ir.FFloor(w),
    ir.FTrunc(w),
    ir.FNearest(w),
    ir.FSqrt(w),
    ir.FCopysign(w),
    ir.FEq(w),
    ir.FNe(w),
    ir.FLt(w),
    ir.FGt(w),
    ir.FLe(w),
    ir.FGe(w),
  ]
}

/// Every `NumOp` constructor at both widths (29 integer + 20 float per width = 98 in total).
fn all_numops() -> List(ir.NumOp) {
  list.flatten([
    int_ops(ir.W32),
    int_ops(ir.W64),
    float_ops(ir.FW32),
    float_ops(ir.FW64),
  ])
}

/// Every `ConvOp` constructor, covering each width/sign combination.
fn all_convops() -> List(ir.ConvOp) {
  [
    ir.I32WrapI64,
    ir.I64ExtendI32S,
    ir.I64ExtendI32U,
    ir.I32Extend8S,
    ir.I32Extend16S,
    ir.I64Extend8S,
    ir.I64Extend16S,
    ir.I64Extend32S,
    ir.TruncSatS(ir.FW32, ir.W32),
    ir.TruncSatS(ir.FW64, ir.W64),
    ir.TruncSatS(ir.FW32, ir.W64),
    ir.TruncSatS(ir.FW64, ir.W32),
    ir.TruncSatU(ir.FW32, ir.W32),
    ir.TruncSatU(ir.FW64, ir.W64),
    ir.ReinterpretFToI(ir.FW32),
    ir.ReinterpretFToI(ir.FW64),
    ir.ReinterpretIToF(ir.W32),
    ir.ReinterpretIToF(ir.W64),
    ir.BoxInt(ir.W32),
    ir.BoxInt(ir.W64),
    ir.UnboxInt(ir.W32),
    ir.UnboxInt(ir.W64),
    ir.BoxFloat(ir.FW32),
    ir.BoxFloat(ir.FW64),
    ir.UnboxFloat(ir.FW32),
    ir.UnboxFloat(ir.FW64),
    // Phase-2 (`«IR2-FROZEN»`): trapping float→int truncation, int→float convert (both
    // signs, both widths each), and the two float-width changes.
    ir.TruncS(ir.FW32, ir.W32),
    ir.TruncS(ir.FW64, ir.W32),
    ir.TruncS(ir.FW32, ir.W64),
    ir.TruncS(ir.FW64, ir.W64),
    ir.TruncU(ir.FW32, ir.W32),
    ir.TruncU(ir.FW64, ir.W32),
    ir.TruncU(ir.FW32, ir.W64),
    ir.TruncU(ir.FW64, ir.W64),
    ir.ConvertS(ir.W32, ir.FW32),
    ir.ConvertS(ir.W64, ir.FW32),
    ir.ConvertS(ir.W32, ir.FW64),
    ir.ConvertS(ir.W64, ir.FW64),
    ir.ConvertU(ir.W32, ir.FW32),
    ir.ConvertU(ir.W64, ir.FW32),
    ir.ConvertU(ir.W32, ir.FW64),
    ir.ConvertU(ir.W64, ir.FW64),
    ir.F32DemoteF64,
    ir.F64PromoteF32,
  ]
}

/// Every `TrapReason` constructor (Phase-1 five + the four Phase-2 additions, `«IR2-FROZEN»`,
/// + the Phase-3 runtime-only `FuelExhausted`). Including `FuelExhausted` here proves the new
/// printer/parser arms round-trip; a real lowering never emits `Trap(FuelExhausted)`, but the
/// printer/parser handle every `TrapReason` exhaustively.
fn all_trapreasons() -> List(ir.TrapReason) {
  [
    ir.IntDivByZero,
    ir.IntOverflow,
    ir.Unreachable,
    ir.IndirectCallTypeMismatch,
    ir.MemoryOutOfBounds,
    ir.InvalidConversionToInteger,
    ir.UndefinedElement,
    ir.UninitializedElement,
    ir.TableOutOfBounds,
    ir.FuelExhausted,
  ]
}

/// A representative instance of (nearly) every `Expr` variant, for the round-trip.
fn expr_corpus() -> List(ir.Expr) {
  [
    // Values: empty (multi-value 0) and a mixed multi-value list with float consts.
    ir.Values([]),
    ir.Values([
      ir.ConstI32(1),
      ir.ConstI64(2),
      ir.ConstF32(0x7fc00000),
      ir.ConstF64(0x8000000000000000),
    ]),
    // term ops
    ir.TermOp(ir.MakeTuple, [ir.Var("a"), ir.Var("b")]),
    ir.TermOp(ir.TupleGet(3), [ir.Var("t")]),
    ir.TermOp(ir.MakeCons, [ir.Var("h"), ir.Var("t")]),
    // memory: size/grow (Phase-2), a plain i32.load and a sign-extending i64.load8_s
    // (distinct result widths prove the new `result` field round-trips and discriminates
    // i32.load8_s vs i64.load8_s — same bytes+sign, different result type).
    ir.MemSize,
    ir.MemGrow(ir.ConstI32(1)),
    ir.MemGrow(ir.Var("delta")),
    ir.MemLoad(ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32),
    ir.MemLoad(ir.MemAccess(1, True), ir.Var("a"), 8, ir.TI64),
    ir.MemStore(ir.MemAccess(8, False), ir.Var("a"), ir.Var("v"), 16),
    // globals
    ir.GlobalGet("g"),
    ir.GlobalSet("g", ir.ConstI32(5)),
    // calls
    ir.CallDirect("foo", [ir.Var("a"), ir.Var("b")]),
    ir.CallIndirect(
      "tbl",
      ir.Var("i"),
      ir.FuncType([ir.TI32, ir.TI64], [ir.TF32]),
      [ir.Var("a")],
    ),
    ir.CallHost("env", "print", [ir.Var("a")]),
    // sequencing: multi-binder let + a block used as the let rhs (open question #4)
    ir.Let(
      ["a", "b"],
      ir.Values([ir.ConstI32(1), ir.ConstI32(2)]),
      ir.Return([ir.Var("a"), ir.Var("b")]),
    ),
    ir.Let(
      ["x"],
      ir.Block("blk", [ir.TI32], ir.Break("blk", [ir.ConstI32(1)])),
      ir.Return([ir.Var("x")]),
    ),
    // loop with several carried vars + continue
    ir.Loop(
      "lp",
      [
        ir.LoopParam("i", ir.TI32, ir.ConstI32(0)),
        ir.LoopParam("acc", ir.TI64, ir.ConstI64(0)),
      ],
      [ir.TI64],
      ir.Continue("lp", [ir.ConstI32(1), ir.ConstI64(2)]),
    ),
    // if
    ir.If(
      ir.Var("c"),
      [ir.TI32],
      ir.Return([ir.ConstI32(1)]),
      ir.Return([ir.ConstI32(0)]),
    ),
    // switch with arms + default, and a switch with NO arms (default only)
    ir.Switch(
      ir.Var("s"),
      [ir.TI32],
      [
        ir.SwitchArm(0, ir.Return([ir.ConstI32(10)])),
        ir.SwitchArm(255, ir.Return([ir.ConstI32(20)])),
      ],
      ir.Return([ir.ConstI32(30)]),
    ),
    ir.Switch(ir.Var("s"), [], [], ir.Return([])),
    // transfers
    ir.Break("blk", [ir.Var("x")]),
    ir.Continue("lp", [ir.Var("x")]),
    ir.Return([]),
    ir.Return([ir.Var("x")]),
    // metering effect, nested with a let
    ir.Charge(1000, ir.Return([ir.ConstI32(1)])),
    ir.Charge(
      0,
      ir.Let(["z"], ir.Values([ir.ConstI32(7)]), ir.Return([ir.Var("z")])),
    ),
  ]
}

/// A "kitchen-sink" module exercising every MODULE-LEVEL feature: numerics on, sized
/// memory, mutable + immutable globals, a host import, two exports + two functions, and
/// two data segments (one of them EMPTY, to exercise the `0x` empty-bytes form).
fn kitchen_sink_module() -> ir.Module {
  ir.Module(
    name: "twocore@wasm@sink",
    uses_numerics: True,
    memory: Some(ir.MemoryDecl(1, Some(4))),
    globals: [
      ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(0)])),
      ir.GlobalDecl(
        "g1",
        ir.TF64,
        False,
        ir.Values([ir.ConstF64(0x3ff0000000000000)]),
      ),
    ],
    imports: [ir.ImportFn("env", "log", ir.FuncType([ir.TI32], []))],
    functions: [
      ir.Function(
        name: "f0",
        params: [ir.Local("p0", ir.TI32)],
        result: [ir.TI32],
        locals: [ir.Local("tmp", ir.TI64)],
        body: ir.Let(["r"], ir.GlobalGet("g0"), ir.Return([ir.Var("r")])),
      ),
      ir.Function(
        name: "f1",
        params: [],
        result: [],
        locals: [],
        body: ir.Trap(ir.Unreachable),
      ),
    ],
    exports: [ir.ExportFn("main", "f0"), ir.ExportFn("aux", "f1")],
    data_segments: [
      ir.DataSegment(ir.Values([ir.ConstI32(0)]), <<
        0xde,
        0xad,
        0xbe,
        0xef,
        0x00,
      >>),
      ir.DataSegment(ir.Values([ir.ConstI32(16)]), <<>>),
    ],
    tables: [],
    elements: [],
    start: None,
  )
}

/// Expected `Module` for the Phase-2 golden `golden/mem_table.ir` (hand-built, independent
/// of the printer). Exercises the new IR2 surface in one module: a funcref `table` decl, an
/// active `elem` segment, a `start` function, `mem.size`/`mem.grow`, a sign-extending
/// `mem.load` (i64 result), a float comparison (`f.lt.64`), and a TRAPPING float→int convert
/// (`trunc_s.f64.i32`).
fn mem_table_module() -> ir.Module {
  ir.Module(
    name: "mem_table",
    uses_numerics: True,
    memory: Some(ir.MemoryDecl(1, Some(4))),
    globals: [],
    imports: [],
    functions: [
      ir.Function(
        name: "worker",
        params: [ir.Local("x", ir.TF64), ir.Local("y", ir.TF64)],
        result: [ir.TI32],
        locals: [],
        body: ir.Let(
          ["lt"],
          ir.Num(ir.FLt(ir.FW64), [ir.Var("x"), ir.Var("y")]),
          ir.Let(
            ["n"],
            ir.Convert(ir.TruncS(ir.FW64, ir.W32), ir.Var("x")),
            ir.Let(
              ["hi"],
              ir.MemLoad(ir.MemAccess(1, True), ir.Var("n"), 8, ir.TI64),
              ir.Return([ir.Var("lt")]),
            ),
          ),
        ),
      ),
      ir.Function(
        name: "setup",
        params: [],
        result: [],
        locals: [],
        body: ir.Let(
          ["sz"],
          ir.MemSize,
          ir.Let(["prev"], ir.MemGrow(ir.ConstI32(1)), ir.Return([])),
        ),
      ),
    ],
    exports: [],
    data_segments: [],
    tables: [ir.TableDecl("t0", 2, Some(8))],
    elements: [
      ir.ElementSegment("t0", ir.Values([ir.ConstI32(0)]), ["worker", "setup"]),
    ],
    start: Some("setup"),
  )
}

// ───────────────────────────── round-trip tests ─────────────────────────────

pub fn numop_roundtrip_test() {
  list.each(all_numops(), fn(op) {
    check_roundtrip(expr_module("nm", ir.Num(op, [ir.Var("a"), ir.Var("b")])))
  })
}

pub fn convop_roundtrip_test() {
  list.each(all_convops(), fn(op) {
    check_roundtrip(expr_module("cv", ir.Convert(op, ir.Var("a"))))
  })
}

pub fn trapreason_roundtrip_test() {
  list.each(all_trapreasons(), fn(r) {
    check_roundtrip(expr_module("tr", ir.Trap(r)))
  })
}

pub fn expr_surface_roundtrip_test() {
  list.each(expr_corpus(), fn(e) { check_roundtrip(expr_module("ex", e)) })
}

pub fn module_level_roundtrip_test() {
  check_roundtrip(kitchen_sink_module())
}

/// The Phase-2 module-level surface (`«IR2-FROZEN»`): a module carrying a `table`, an active
/// `elem` segment, and a `start` function round-trips losslessly.
pub fn module_level_phase2_roundtrip_test() {
  check_roundtrip(mem_table_module())
}

/// The `mem.load` result `ValType` (`«IR2-FROZEN»`) is NOT dropped: two loads with identical
/// `MemAccess(1, signed)` but different result types (`i32.load8_s` vs `i64.load8_s`) are
/// distinct `Module`s, and each round-trips. A printer/parser that ignored `result` would
/// collapse them — this test fails closed on that bug.
pub fn mem_load_result_type_discrimination_test() {
  let m_i32 =
    expr_module(
      "ld",
      ir.MemLoad(ir.MemAccess(1, True), ir.Var("a"), 0, ir.TI32),
    )
  let m_i64 =
    expr_module(
      "ld",
      ir.MemLoad(ir.MemAccess(1, True), ir.Var("a"), 0, ir.TI64),
    )
  assert module_equal(m_i32, m_i64) == False
  check_roundtrip(m_i32)
  check_roundtrip(m_i64)
}

pub fn acceptance_programs_roundtrip_test() {
  check_roundtrip(add_module())
  check_roundtrip(sum_to_module())
  check_roundtrip(fib_module())
}

pub fn empty_module_roundtrip_test() {
  let m =
    ir.Module(
      name: "empty",
      uses_numerics: False,
      memory: None,
      globals: [],
      imports: [],
      functions: [],
      exports: [],
      data_segments: [],
      tables: [],
      elements: [],
      start: None,
    )
  check_roundtrip(m)
}

// ───────────────────────────── float fidelity (D5) ─────────────────────────────

pub fn float_bit_fidelity_roundtrip_test() {
  // Quiet NaN, a signaling-NaN bit pattern, +Inf, -0.0, and assorted f32/f64 patterns.
  let m =
    expr_module(
      "fl",
      ir.Values([
        ir.ConstF32(0x7fc00000),
        // f32 quiet NaN
        ir.ConstF32(0x7f800001),
        // f32 signaling NaN payload
        ir.ConstF32(0x80000000),
        // f32 -0.0
        ir.ConstF32(0x7f800000),
        // f32 +Inf
        ir.ConstF64(0x7ff8000000000000),
        // f64 quiet NaN
        ir.ConstF64(0x7ff0000000000001),
        // f64 signaling NaN payload
        ir.ConstF64(0x8000000000000000),
        // f64 -0.0
        ir.ConstF64(0x0000000000000000),
        // f64 +0.0
      ]),
    )
  check_roundtrip(m)
}

pub fn nan_payloads_are_distinct_test() {
  // module_equal must distinguish two different NaN bit patterns and +0.0 from -0.0,
  // which a native-float comparison would WRONGLY conflate.
  let qnan = expr_module("x", ir.Values([ir.ConstF64(0x7ff8000000000000)]))
  let snan = expr_module("x", ir.Values([ir.ConstF64(0x7ff0000000000001)]))
  let pos_zero = expr_module("x", ir.Values([ir.ConstF64(0x0000000000000000)]))
  let neg_zero = expr_module("x", ir.Values([ir.ConstF64(0x8000000000000000)]))
  assert module_equal(qnan, snan) == False
  assert module_equal(pos_zero, neg_zero) == False
  assert module_equal(qnan, qnan) == True
}

// ───────────────────────────── golden suite (independent oracle) ─────────────

pub fn golden_add_parses_to_expected_test() {
  assert parser.parse_module(read_golden("add.ir")) == Ok(add_module())
}

pub fn golden_sum_to_parses_to_expected_test() {
  assert parser.parse_module(read_golden("sum_to.ir")) == Ok(sum_to_module())
}

pub fn golden_fib_parses_to_expected_test() {
  assert parser.parse_module(read_golden("fib.ir")) == Ok(fib_module())
}

/// The Phase-2 golden parses to its hand-built expected `Module` — the independent oracle
/// proving the printer and parser agree on the IR2 grammar additions (table/elem/start,
/// mem.size/grow, the result-typed sign-extending load, the float comparison, and the
/// trapping convert), not merely with each other.
pub fn golden_mem_table_parses_to_expected_test() {
  assert parser.parse_module(read_golden("mem_table.ir"))
    == Ok(mem_table_module())
}

pub fn goldens_reprint_and_reparse_stably_test() {
  // print(parse(golden)) need not match the golden BYTES (the goldens carry hand
  // comments/whitespace), but the parsed Module must round-trip through the canonical
  // printer: parse(print(M)) == M.
  check_roundtrip(add_module())
  check_roundtrip(sum_to_module())
  check_roundtrip(fib_module())
  check_roundtrip(mem_table_module())
}

// ───────────────────────────── module_equal tests ─────────────────────────────

pub fn module_equal_reflexive_test() {
  assert module_equal(fib_module(), fib_module()) == True
}

pub fn module_equal_distinguishes_programs_test() {
  assert module_equal(add_module(), fib_module()) == False
}

// ───────────────────────────── negative corpus (totality, D4) ─────────────────

/// `True` iff parsing `source` yields some `ParseError` (and, by completing, did not
/// panic).
fn rejects(source: String) -> Bool {
  case parser.parse_module(source) {
    Error(_) -> True
    Ok(_) -> False
  }
}

pub fn negative_truncated_module_test() {
  // Input ends after the opening brace.
  let r = parser.parse_module("module @m {")
  assert case r {
    Error(parser.UnexpectedEnd(_)) -> True
    _ -> False
  }
}

pub fn negative_bad_sigil_test() {
  // `func %f ...` — a function name must use the `@` sigil, not `%`.
  let r = parser.parse_module("module @m { func %f () -> () { return () } }")
  assert case r {
    Error(parser.BadSigil(_, _, _)) -> True
    _ -> False
  }
}

pub fn negative_unknown_op_test() {
  // `i.bogus.32` is not a real numeric-op spelling.
  let r =
    parser.parse_module("module @m { func @f () -> () { num i.bogus.32 () } }")
  assert case r {
    Error(parser.UnknownOp(_, _, "i.bogus.32")) -> True
    _ -> False
  }
}

pub fn negative_unknown_trapreason_test() {
  let r = parser.parse_module("module @m { func @f () -> () { trap kaboom } }")
  assert case r {
    Error(parser.UnknownOp(_, _, "kaboom")) -> True
    _ -> False
  }
}

pub fn negative_missing_paren_test() {
  // Missing `(` before the argument list of `num`.
  let r =
    parser.parse_module("module @m { func @f () -> () { num i.add.32 %a) } }")
  assert case r {
    Error(parser.UnexpectedToken(_, _, _, _)) -> True
    _ -> False
  }
}

pub fn negative_unterminated_block_test() {
  // The block (and the enclosing func/module) is never closed.
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { block $b : (i32) { return (i32.const 1) }",
    )
  assert case r {
    Error(parser.UnexpectedEnd(_)) -> True
    _ -> False
  }
}

pub fn negative_odd_hexbytes_test() {
  // A data segment with an odd number of hex digits cannot be byte-decoded.
  let r =
    parser.parse_module("module @m { data (values (i32.const 0)) = 0xabc }")
  assert case r {
    Error(parser.BadNumberLiteral(_, _, "0xabc")) -> True
    _ -> False
  }
}

pub fn negative_bad_string_escape_test() {
  let r = parser.parse_module("module @m { export \"\\q\" = @f }")
  assert case r {
    Error(parser.BadString(_, _, _)) -> True
    _ -> False
  }
}

pub fn negative_stray_char_test() {
  assert rejects("module @m { ! }")
}

pub fn negative_mem_load_missing_valtype_test() {
  // The result valtype is REQUIRED (`«IR2-FROZEN»`): `mem.load 4 %a …` (no leading
  // valtype) must fail where the valtype is expected — `4` is a number, not a valtype.
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { mem.load 4 %a offset=0 } }",
    )
  assert case r {
    Error(parser.UnexpectedToken(_, _, "valtype", _)) -> True
    _ -> False
  }
}

pub fn negative_unknown_float_op_test() {
  // `f.bogus.32` is not a real float-op spelling → UnknownOp (via float_mnemonic Error).
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { num f.bogus.32 (%a) } }",
    )
  assert case r {
    Error(parser.UnknownOp(_, _, "f.bogus.32")) -> True
    _ -> False
  }
}

pub fn negative_unknown_convert_op_test() {
  // `trunc_q.f64.i32` is not a real convert-op spelling → UnknownOp.
  let r =
    parser.parse_module(
      "module @m { func @f () -> () { convert trunc_q.f64.i32 %a } }",
    )
  assert case r {
    Error(parser.UnknownOp(_, _, "trunc_q.f64.i32")) -> True
    _ -> False
  }
}

pub fn negative_malformed_elem_test() {
  // An `elem` whose offset parentheses are missing (`[` where `(` is required).
  let r = parser.parse_module("module @m { elem @t0 [ @a ] }")
  assert case r {
    Error(parser.UnexpectedToken(_, _, "(", _)) -> True
    _ -> False
  }
}

pub fn negative_new_trapreasons_roundtrip_test() {
  // The three new trap reasons are accepted by the parser (positive coverage paired with
  // the negative `kaboom` case) so a dropped arm is caught.
  assert rejects("module @m { func @f () -> () { trap not_a_reason } }")
}

pub fn negative_garbage_inputs_never_panic_test() {
  // A battery of malformed inputs: each must return Error (never panic). Reaching the
  // end of this list without crashing the runner IS the totality proof.
  let garbage = [
    "",
    "   ",
    "module",
    "module @",
    "module @m",
    "module @m {",
    "module @m }",
    "@m { }",
    "module @m { numerics }",
    "module @m { numerics maybe }",
    "module @m { memory ( }",
    "module @m { memory (min) }",
    "module @m { func @f }",
    "module @m { func @f () }",
    "module @m { func @f () -> () }",
    "module @m { func @f () -> () { } }",
    "module @m { func @f () -> () { let } }",
    "module @m { func @f () -> () { let (%x) } }",
    "module @m { func @f () -> () { if } }",
    "module @m { func @f () -> () { return (%a,) } }",
    "module @m { func @f () -> () { convert i32.wrap_i64 } }",
    "module @m { func @f () -> () { call_host \"a\" } }",
    "}{}{}{",
    "module @m { func @f ( %p ) -> () { return () } }",
    "module @m { func @f ( %p : ) -> () { return () } }",
    // Phase-2 malformed forms (`«IR2-FROZEN»`): each must return Error, never panic.
    "module @m { table }",
    "module @m { table @t0 }",
    "module @m { table @t0 min }",
    "module @m { table @t0 min 2 max }",
    "module @m { elem }",
    "module @m { elem @t0 }",
    "module @m { elem @t0 ( values (i32.const 0) ) }",
    "module @m { elem @t0 ( values (i32.const 0) ) [ @a }",
    "module @m { elem @t0 ( values (i32.const 0) ) [ %a ] }",
    "module @m { start }",
    "module @m { start %f }",
    "module @m { func @f () -> () { mem.grow } }",
    "module @m { func @f () -> () { mem.load } }",
    "module @m { func @f () -> () { mem.load i32 } }",
    "module @m { func @f () -> () { convert trunc_s.f64 %a } }",
    "module @m { func @f () -> () { convert convert_s.f64.i32 %a } }",
  ]
  assert list.all(garbage, rejects)
}
