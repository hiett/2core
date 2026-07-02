//// Unit 08 — end-to-end: hand-written IR → `.core` → loaded `.beam` → RUN on the BEAM.
////
//// The headline deliverable (overview §3): a hand-written IR `Module` compiles and runs
//// on the BEAM with SPEC-CORRECT results, proving the backend spine
//// (`08 emit_core` → `03 core_printer` → `04 build_beam`, with `06 rt_num` / `09 rt_trap`/
//// `rt_host`/`rt_meter`/`rt_stdlib` linked) before the WASM frontend exists. Results are
//// asserted against the WebAssembly spec (<https://webassembly.github.io/spec/core/>):
//// two's-complement wrap, shift-count masking, the div/rem zero & signed-overflow traps,
//// the deny-all capability boundary, and the resolved `own` stdlib.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/string
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance
import twocore/runtime/link

// Test-only FFI (see `test/twocore_emit_test_ffi.erl`): apply `M:F(Args)` and capture a
// trap / capability-denial as `Error(text)` instead of crashing the test process.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

// The SAME `catch_apply/3` FFI, re-typed for `Dynamic` arguments/results — used to drive the
// `instantiate/1(Imports)` ABI of an import-bearing module (the single argument is the whole
// positional `[Provided ...]` list). `erlang:apply` is untyped at runtime, so this is sound.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply_dyn(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)

// Coerce any Gleam value to `Dynamic` (identity at runtime) — to hand the `List(Provided)`
// import list to `instantiate/1` as a single opaque argument.
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(x: a) -> Dynamic

// ───────────────────────────── plumbing ─────────────────────────────

/// Emit `module` to Core text, compile it, and load it into the test VM; return the
/// loaded module atom. `let assert` here is the test's success contract — a failure to
/// emit/compile/load is a genuine test failure, not an expected path.
fn load(module: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, instance.safe_default())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// Build a numerics-on, memory-off module wrapping `functions`, exporting each by name.
fn module(name: String, functions: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
  )
}

// ───────────────────────────── add(i32,i32) + two's-complement wrap ─────────────────────────────

fn binop_fn(name: String, op: ir.NumOp, ty: ir.ValType) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("p0", ty), ir.Local("p1", ty)],
    result: [ty],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.Num(op, [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// `add(7, 35) == 42`; and i32 addition wraps two's-complement through codegen
/// (`0x7FFFFFFF + 1 == 0x80000000`, the unsigned bit pattern `2147483648`) — WASM `i32.add`
/// is modulo 2^32.
pub fn add_and_wrap_e2e_test() {
  let mod = load(module("add", [binop_fn("add", ir.IAdd(ir.W32), ir.TI32)]))
  assert catch_apply(mod, atom.create("add"), [7, 35]) == Ok(42)
  assert catch_apply(mod, atom.create("add"), [2_147_483_647, 1])
    == Ok(2_147_483_648)
}

/// `i32.shl` masks the shift count modulo 32 (WASM shift-count masking): `1 << 32 == 1`
/// (count 32 → 0) and `1 << 33 == 2` (count 33 → 1) — proven THROUGH codegen.
pub fn shift_count_masking_e2e_test() {
  let mod = load(module("shl", [binop_fn("shl", ir.IShl(ir.W32), ir.TI32)]))
  assert catch_apply(mod, atom.create("shl"), [1, 32]) == Ok(1)
  assert catch_apply(mod, atom.create("shl"), [1, 33]) == Ok(2)
}

// ───────────────────────────── sum_to(n) — constant-space loop ─────────────────────────────

fn sum_to_fn() -> ir.Function {
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
  )
}

/// `sum_to(n) == n*(n+1)/2`, and it runs in CONSTANT SPACE: the loop lowers to a `letrec`
/// whose back-edge is a tail `apply` (asserted structurally in `emit_core_test`), so 100k
/// iterations complete without growing the stack. `sum_to(100000) == 5000050000`.
pub fn sum_to_constant_space_e2e_test() {
  let mod = load(module("loop", [sum_to_fn()]))
  assert catch_apply(mod, atom.create("sum_to"), [10]) == Ok(55)
  assert catch_apply(mod, atom.create("sum_to"), [100_000]) == Ok(5_000_050_000)
}

// ───────────────────────────── fib / fac — if + direct self-call + recursion ─────────────────────────────

fn fib_fn() -> ir.Function {
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
  )
}

fn fac_fn() -> ir.Function {
  ir.Function(
    name: "fac",
    params: [ir.Local("p0", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["c"],
      ir.Num(ir.ILtU(ir.W64), [ir.Var("p0"), ir.ConstI64(2)]),
      ir.If(
        cond: ir.Var("c"),
        result: [ir.TI64],
        then_branch: ir.Return([ir.ConstI64(1)]),
        else_branch: ir.Let(
          ["n1"],
          ir.Num(ir.ISub(ir.W64), [ir.Var("p0"), ir.ConstI64(1)]),
          ir.Let(
            ["f1"],
            ir.CallDirect("fac", [ir.Var("n1")]),
            ir.Let(
              ["r"],
              ir.Num(ir.IMul(ir.W64), [ir.Var("p0"), ir.Var("f1")]),
              ir.Return([ir.Var("r")]),
            ),
          ),
        ),
      ),
    ),
  )
}

/// `fib`/`fac` (if + direct self-call + recursion) produce spec-correct values.
/// `fib(10) == 55`, `fib(20) == 6765`, `fac(5) == 120`, `fac(10) == 3628800`.
pub fn fib_fac_recursion_e2e_test() {
  let fmod = load(module("fib", [fib_fn()]))
  assert catch_apply(fmod, atom.create("fib"), [10]) == Ok(55)
  assert catch_apply(fmod, atom.create("fib"), [20]) == Ok(6765)
  let gmod = load(module("fac", [fac_fn()]))
  assert catch_apply(gmod, atom.create("fac"), [5]) == Ok(120)
  assert catch_apply(gmod, atom.create("fac"), [10]) == Ok(3_628_800)
}

// ───────────────────────────── div traps (zero & signed overflow) ─────────────────────────────

/// `div_u(x, 0)` TRAPS (divide by zero) and `div_s(INT_MIN, -1)` TRAPS (signed overflow),
/// surfaced via `rt_trap` as a catchable `{wasm_trap, Kind}` error — not a wrong value, not
/// a silent `badarith`. (i32 `INT_MIN` = `0x80000000` = 2147483648; `-1` = `0xFFFFFFFF` =
/// 4294967295 as unsigned bit patterns.)
pub fn div_traps_e2e_test() {
  let mod =
    load(
      module("divtrap", [
        binop_fn("divu", ir.IDivU(ir.W32), ir.TI32),
        binop_fn("divs", ir.IDivS(ir.W32), ir.TI32),
      ]),
    )

  let assert Error(zero) = catch_apply(mod, atom.create("divu"), [10, 0])
  assert string.contains(zero, "wasm_trap")
  assert string.contains(zero, "int_div_by_zero")

  let assert Error(over) =
    catch_apply(mod, atom.create("divs"), [2_147_483_648, 4_294_967_295])
  assert string.contains(over, "wasm_trap")
  assert string.contains(over, "int_overflow")

  // A non-trapping division returns the value (sanity that the ok-arm works).
  assert catch_apply(mod, atom.create("divu"), [20, 5]) == Ok(4)
}

// ───────────────────────────── CallHost — deny-all import vs resolved stdlib ─────────────────────────────

fn host_import_fn() -> ir.Function {
  ir.Function(
    name: "useimport",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallHost("env", "forbidden", [ir.Var("p0")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

fn gcd_fn() -> ir.Function {
  ir.Function(
    name: "mygcd",
    params: [ir.Local("p0", ir.TI64), ir.Local("p1", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallHost("std", "gcd", [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// A genuine host import is REJECTED end-to-end under the Safe deny-all host:
/// `{capability_denied, Cap, Name}` (fail-closed, D9). The capability boundary fires.
pub fn host_import_denied_e2e_test() {
  let mod = load(module("hostdeny", [host_import_fn()]))
  let assert Error(reason) = catch_apply(mod, atom.create("useimport"), [123])
  assert string.contains(reason, "capability_denied")
}

/// A resolved `own`-stdlib call (`("std","gcd")`) reaches `rt_stdlib:gcd/2` and returns the
/// spec gcd: `gcd(48, 36) == 12`, `gcd(1071, 462) == 21`.
pub fn stdlib_gcd_e2e_test() {
  let mod = load(module("stdgcd", [gcd_fn()]))
  assert catch_apply(mod, atom.create("mygcd"), [48, 36]) == Ok(12)
  assert catch_apply(mod, atom.create("mygcd"), [1071, 462]) == Ok(21)
}

// ──────────────── multi-value & zero-result function boundaries (REGRESSION) ────────────────

/// `swap2(a, b)` returns TWO values `<b, a>` (a multi-value result).
fn swap2_fn() -> ir.Function {
  ir.Function(
    name: "swap2",
    params: [ir.Local("p0", ir.TI64), ir.Local("p1", ir.TI64)],
    result: [ir.TI64, ir.TI64],
    locals: [],
    body: ir.Values([ir.Var("p1"), ir.Var("p0")]),
  )
}

/// `caller(x)` calls the multi-value `swap2(x, 7)`, binds its two results `<lo, hi>`, and
/// returns `lo - hi`.
fn use_swap2_fn() -> ir.Function {
  ir.Function(
    name: "caller",
    params: [ir.Local("p0", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["lo", "hi"],
      ir.CallDirect("swap2", [ir.Var("p0"), ir.ConstI64(7)]),
      ir.Let(
        ["d"],
        ir.Num(ir.ISub(ir.W64), [ir.Var("lo"), ir.Var("hi")]),
        ir.Return([ir.Var("d")]),
      ),
    ),
  )
}

/// REGRESSION: a function with MORE than one result (multi-value) compiles and its results
/// round-trip through a call in order. A BEAM function returns exactly one value, so a
/// multi-value result is packaged as a tuple at the boundary and destructured at the call
/// site (the `fac-ssa` shape that previously emitted `ArityMismatch` then failed to build
/// with "return count mismatch").
///
/// `swap2(x, 7) == <7, x>`, so `caller(x) == 7 - x`: `caller(2) == 5`; `caller(10) == 7-10
/// == -3`, the i64 two's-complement bit pattern `2^64 - 3`. The asymmetric subtraction
/// would expose a swapped destructure (it would compute `x - 7` instead).
pub fn multi_value_call_e2e_test() {
  let mod = load(module("multival", [swap2_fn(), use_swap2_fn()]))
  assert catch_apply(mod, atom.create("caller"), [2]) == Ok(5)
  assert catch_apply(mod, atom.create("caller"), [10])
    == Ok(18_446_744_073_709_551_613)
}

/// `voiddiv(a, b)` computes signed `a / b` and DROPS it — a zero-result (`void`) function.
fn voiddiv_fn() -> ir.Function {
  ir.Function(
    name: "voiddiv",
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [],
    locals: [],
    body: ir.Let(
      ["x"],
      ir.Num(ir.IDivS(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
      ir.Values([]),
    ),
  )
}

/// REGRESSION: a zero-result function compiles and still traps. A BEAM function must yield
/// exactly one value, so the empty result list is packaged as a single unit value (the
/// `traps.wast` `no_dce` shape that previously failed to build with "return count
/// mismatch"). The dropped division is NOT eliminated, so its trap still fires:
/// `voiddiv(6, 2)` runs and returns (result discarded); `voiddiv(6, 0)` traps with
/// `int_div_by_zero`.
pub fn zero_result_fn_e2e_test() {
  let mod = load(module("voidfn", [voiddiv_fn()]))
  let assert Ok(_) = catch_apply(mod, atom.create("voiddiv"), [6, 2])
  let assert Error(trap) = catch_apply(mod, atom.create("voiddiv"), [6, 0])
  assert string.contains(trap, "wasm_trap")
  assert string.contains(trap, "int_div_by_zero")
}

// ════════════════════ Phase-2: stateful WASM end-to-end (load → instantiate → invoke) ════════════════════
//
// These are the headline Phase-2 proof: a hand-built IR2 `Module` with the generated
// `instantiate/0` compiles, instantiates (seeding the per-instance cell), and runs spec-
// correctly on the BEAM — memory round-trip, grow, mutable global, `call_indirect` + the 3
// faults, a trapping `trunc`, and float ops. The instance's cell is process-local; `gleeunit`
// runs each test synchronously in one process, so `instantiate` then `invoke` share it.

/// Build a full Phase-2 module (memory/globals/tables/elements/data/start), exporting each
/// function by its own name. `name` is namespaced; unique per test so loads don't clobber.
fn full(
  name: String,
  memory: option.Option(ir.MemoryDecl),
  globals: List(ir.GlobalDecl),
  functions: List(ir.Function),
  tables: List(ir.TableDecl),
  elements: List(ir.ElementSegment),
  data: List(ir.DataSegment),
  start: option.Option(String),
) -> ir.Module {
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: case memory {
      option.Some(m) -> [m]
      option.None -> []
    },
    globals: globals,
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: data,
    tables: tables,
    elements: elements,
    start: start,
  )
}

/// Run the generated `instantiate/0` (seeds the cell), asserting it succeeds.
fn instantiate(mod: Atom) -> Nil {
  let assert Ok(_) = catch_apply(mod, atom.create("instantiate"), [])
  Nil
}

fn store_fn(name: String, bytes: Int) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("addr", ir.TI32), ir.Local("val", ir.TI32)],
    result: [],
    locals: [],
    body: ir.Let(
      [],
      ir.MemStore(
        0,
        ir.MemAccess(bytes, False),
        ir.Var("addr"),
        ir.Var("val"),
        0,
      ),
      ir.Values([]),
    ),
  )
}

fn load_fn(
  name: String,
  bytes: Int,
  signed: Bool,
  result: ir.ValType,
) -> ir.Function {
  ir.Function(
    name: name,
    params: [ir.Local("addr", ir.TI32)],
    result: [result],
    locals: [],
    body: ir.MemLoad(0, ir.MemAccess(bytes, signed), ir.Var("addr"), 0, result),
  )
}

/// MEMORY round-trip: `i32.store` then `i32.load` returns the stored bits; and the width
/// matrix sign-/zero-extends per `exec/memory` — a stored `0xFFFFFF80` reads back as itself
/// at i32.load, `load8_s` sign-extends the low byte `0x80` → `0xFFFFFF80`, and `load16_u`
/// zero-extends the low two bytes → `0xFF80`.
pub fn memory_store_load_roundtrip_e2e_test() {
  let mod =
    load(full(
      "mem",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [
        store_fn("store32", 4),
        load_fn("load32", 4, False, ir.TI32),
        load_fn("load8s", 1, True, ir.TI32),
        load_fn("load16u", 2, False, ir.TI32),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  // round-trip a full i32 word at address 0.
  let assert Ok(_) = catch_apply(mod, atom.create("store32"), [0, 305_419_896])
  assert catch_apply(mod, atom.create("load32"), [0]) == Ok(305_419_896)
  // little-endian + sign-/zero-extension on the width matrix.
  let assert Ok(_) =
    catch_apply(mod, atom.create("store32"), [0, 4_294_967_168])
  assert catch_apply(mod, atom.create("load8s"), [0]) == Ok(4_294_967_168)
  assert catch_apply(mod, atom.create("load16u"), [0]) == Ok(65_408)
}

/// MEMORY out-of-bounds load TRAPS (zero corruption): a load one byte past the single page
/// traps "out of bounds memory access" (`exec/memory` — strictly-greater bound).
pub fn memory_oob_load_traps_e2e_test() {
  let mod =
    load(full(
      "memoob",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [load_fn("load32", 4, False, ir.TI32)],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  // last in-bounds 4-byte word starts at 65532; 65533 ends at 65537 > 65536 → trap.
  assert catch_apply(mod, atom.create("load32"), [65_533]) |> is_trap
}

/// `memory.grow` grows + returns the OLD size, a load of the freshly-grown (zero-filled)
/// region returns `0`, and a grow past the declared max returns `-1` without allocating
/// (`memory.grow` semantics).
pub fn memory_grow_e2e_test() {
  let mod =
    load(full(
      "memgrow",
      option.Some(ir.MemoryDecl(1, option.Some(3), ir.Idx32)),
      [],
      [
        ir.Function(
          "grow",
          [ir.Local("d", ir.TI32)],
          [ir.TI32],
          [],
          ir.MemGrow(0, ir.Var("d")),
        ),
        ir.Function("size", [], [ir.TI32], [], ir.MemSize(0)),
        load_fn("load32", 4, False, ir.TI32),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  assert catch_apply(mod, atom.create("size"), []) == Ok(1)
  // grow(1) returns the OLD page count (1); the new region is in bounds and zero-filled.
  assert catch_apply(mod, atom.create("grow"), [1]) == Ok(1)
  assert catch_apply(mod, atom.create("size"), []) == Ok(2)
  assert catch_apply(mod, atom.create("load32"), [65_536]) == Ok(0)
  // grow past the declared max (2 + 5 > 3) returns -1 and does not allocate.
  assert catch_apply(mod, atom.create("grow"), [5]) == Ok(-1)
  assert catch_apply(mod, atom.create("size"), []) == Ok(2)
}

/// A mutable GLOBAL round-trips `global.set`/`global.get`, starting from its constant init.
pub fn mutable_global_e2e_test() {
  let mod =
    load(full(
      "global",
      option.None,
      [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(7)]))],
      [
        ir.Function("get", [], [ir.TI32], [], ir.GlobalGet("g0")),
        ir.Function(
          "set",
          [ir.Local("v", ir.TI32)],
          [],
          [],
          ir.Let([], ir.GlobalSet("g0", ir.Var("v")), ir.Values([])),
        ),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  assert catch_apply(mod, atom.create("get"), []) == Ok(7)
  let assert Ok(_) = catch_apply(mod, atom.create("set"), [99])
  assert catch_apply(mod, atom.create("get"), []) == Ok(99)
}

/// `call_indirect` to the RIGHT type runs, and each of the three faults traps with the spec
/// reason (`UndefinedElement` for OOB index, `UninitializedElement` for a null slot,
/// `IndirectCallTypeMismatch` for a wrong type) — never via a data-driven `apply`.
pub fn call_indirect_e2e_test() {
  let inc =
    ir.Function(
      "inc",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(1)]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let callfn =
    ir.Function(
      "callfn",
      [ir.Local("idx", ir.TI32)],
      [ir.TI32],
      [],
      ir.CallIndirect("t0", ir.Var("idx"), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.ConstI32(41),
      ]),
    )
  let callwrong =
    ir.Function(
      "callwrong",
      [ir.Local("idx", ir.TI32)],
      [ir.TI64],
      [],
      ir.CallIndirect("t0", ir.Var("idx"), ir.FuncType([ir.TI64], [ir.TI64]), [
        ir.ConstI64(0),
      ]),
    )
  let mod =
    load(full(
      "ci",
      option.None,
      [],
      [inc, callfn, callwrong],
      [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
      [
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
          ir.FuncRef,
          [ir.RefFunc("inc")],
        ),
      ],
      [],
      option.None,
    ))
  instantiate(mod)
  // slot 0 holds `inc` with type [i32]->[i32]: dispatch runs.
  assert catch_apply(mod, atom.create("callfn"), [0]) == Ok(42)
  // index past the table bound (size 4).
  let assert Error(undef) = catch_apply(mod, atom.create("callfn"), [10])
  assert string.contains(undef, "undefined_element")
  // in-bounds but null (uninitialised) slot.
  let assert Error(uninit) = catch_apply(mod, atom.create("callfn"), [2])
  assert string.contains(uninit, "uninitialized_element")
  // right slot, wrong expected type ([i64]->[i64] vs the stored [i32]->[i32]).
  let assert Error(mismatch) = catch_apply(mod, atom.create("callwrong"), [0])
  assert string.contains(mismatch, "indirect_call_type_mismatch")
}

/// A trapping `i32.trunc_f32_s`: in-range truncates toward zero; NaN traps "invalid
/// conversion to integer"; ±Inf and out-of-range trap "integer overflow" (`exec/numerics`).
pub fn trapping_trunc_e2e_test() {
  let mod =
    load(full(
      "trunc",
      option.None,
      [],
      [
        ir.Function(
          "trunc",
          [ir.Local("x", ir.TF32)],
          [ir.TI32],
          [],
          ir.Convert(ir.TruncS(ir.FW32, ir.W32), ir.Var("x")),
        ),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  // 3.7 → 3 (toward zero).
  assert catch_apply(mod, atom.create("trunc"), [1_080_452_301]) == Ok(3)
  // NaN → invalid conversion to integer.
  let assert Error(nan) =
    catch_apply(mod, atom.create("trunc"), [2_143_289_344])
  assert string.contains(nan, "invalid_conversion_to_integer")
  // 2^31 (just out of i32 range) → integer overflow.
  let assert Error(ov) = catch_apply(mod, atom.create("trunc"), [1_325_400_064])
  assert string.contains(ov, "int_overflow")
  // +Inf → integer overflow (NOT invalid conversion).
  let assert Error(inf) =
    catch_apply(mod, atom.create("trunc"), [2_139_095_040])
  assert string.contains(inf, "int_overflow")
}

/// Float ops through codegen: an ordered comparison (`f32.lt`) yields an i32 0/1, and
/// `f32.sqrt(4.0)` returns the bit pattern of `2.0`.
pub fn float_compare_and_sqrt_e2e_test() {
  let mod =
    load(full(
      "flt",
      option.None,
      [],
      [
        ir.Function(
          "lt",
          [ir.Local("a", ir.TF32), ir.Local("b", ir.TF32)],
          [ir.TI32],
          [],
          ir.Num(ir.FLt(ir.FW32), [ir.Var("a"), ir.Var("b")]),
        ),
        ir.Function(
          "sqrtf",
          [ir.Local("x", ir.TF32)],
          [ir.TF32],
          [],
          ir.Num(ir.FSqrt(ir.FW32), [ir.Var("x")]),
        ),
      ],
      [],
      [],
      [],
      option.None,
    ))
  instantiate(mod)
  // 1.0 < 2.0 → 1; 2.0 < 1.0 → 0 (f32 bit patterns).
  assert catch_apply(mod, atom.create("lt"), [1_065_353_216, 1_073_741_824])
    == Ok(1)
  assert catch_apply(mod, atom.create("lt"), [1_073_741_824, 1_065_353_216])
    == Ok(0)
  // sqrt(4.0) == 2.0  (0x40800000 → 0x40000000).
  assert catch_apply(mod, atom.create("sqrtf"), [1_082_130_432])
    == Ok(1_073_741_824)
}

/// An out-of-bounds active DATA segment traps AT INSTANTIATION (`instantiate/0` raises
/// "out of bounds memory access" — the cell is never left half-initialised).
pub fn oob_data_segment_traps_at_instantiation_e2e_test() {
  let mod =
    load(full(
      "dataoob",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [],
      [],
      [],
      [
        ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(65_535)])), <<
          1,
          2,
          3,
        >>),
      ],
      option.None,
    ))
  let assert Error(reason) = catch_apply(mod, atom.create("instantiate"), [])
  assert string.contains(reason, "memory_out_of_bounds")
}

/// An out-of-bounds active ELEMENT segment traps AT INSTANTIATION (`instantiate/0` raises
/// "out of bounds table access").
pub fn oob_element_segment_traps_at_instantiation_e2e_test() {
  let target =
    ir.Function(
      "target",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Return([
        ir.Var("p0"),
      ]),
    )
  let mod =
    load(full(
      "elemoob",
      option.None,
      [],
      [target],
      [ir.TableDecl("t0", ir.FuncRef, 2, option.None)],
      [
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(1)])),
          ir.FuncRef,
          [
            ir.RefFunc("target"),
            ir.RefFunc("target"),
          ],
        ),
      ],
      [],
      option.None,
    ))
  let assert Error(reason) = catch_apply(mod, atom.create("instantiate"), [])
  assert string.contains(reason, "table_out_of_bounds")
}

/// True iff an invoke result is a trap (any `{wasm_trap, _}` error).
fn is_trap(r: Result(Int, String)) -> Bool {
  case r {
    Error(t) -> string.contains(t, "wasm_trap")
    Ok(_) -> False
  }
}

// ════════════════════ Phase-4 (P4-02): THREADED state end-to-end ════════════════════
//
// The headline P4-02 proof (unit-doc §"Verification" test 6): a hand-built stateful IR `Module`
// compiled under `state_strategy: Threaded` instantiates, runs, and traps BYTE-IDENTICALLY to
// the `Cell` build — but as a purely-functional record-threading `.core` (no process dictionary
// in the linked output). The run-ABI is HAND-DRIVEN here (unit 08 owns it in the pipeline): the
// generated `instantiate/0` RETURNS the `InstanceState`; each export takes it LEADING and
// returns `{Package, St'}`; the test threads `St'` across successive invokes via a small FFI.

// Test-only FFI (see `test/twocore_threaded_test_ffi.erl`): run the record-returning
// `instantiate/0`, and apply an export with the record leading, capturing traps as `Error`.
@external(erlang, "twocore_threaded_test_ffi", "instantiate")
fn t_instantiate(module: Atom) -> Result(Dynamic, String)

// Invoke a VALUE-returning export: `{IntResult, St'}` on success (the package is coerced to
// `Int` at the FFI boundary, as the cell `catch_apply` does), a trap text on `Error`.
@external(erlang, "twocore_threaded_test_ffi", "invoke")
fn t_invoke_int(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(Int, Dynamic), String)

// Invoke a ZERO-RESULT export (`store`/`set`): the package is the discardable `'ok'` atom, so
// it stays `Dynamic`; only the threaded-out record `St'` matters.
@external(erlang, "twocore_threaded_test_ffi", "invoke")
fn t_invoke_unit(
  module: Atom,
  function: Atom,
  st: Dynamic,
  args: List(Int),
) -> Result(#(Dynamic, Dynamic), String)

/// A Safe binding switched to the tier-P `Threaded` state strategy (the same fixed
/// `twocore@runtime@*` modules; only the codegen shape differs).
fn threaded_binding() -> instance.Binding {
  instance.Binding(..instance.safe_default(), state_strategy: instance.Threaded)
}

/// Emit `module` under `Threaded` to Core text, compile it, and load it; return the module atom.
fn load_threaded(module: ir.Module) -> Atom {
  let assert Ok(cm) = emit_core.emit_module(module, threaded_binding())
  let core = core_printer.print_module(cm)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

/// THREADED memory round-trip: `instantiate/0` returns the record, `store32` threads the
/// UPDATED record forward, and `load32`/`load8s`/`load16u` read it back — sign-/zero-extending
/// per `exec/memory`. Diffed against the `Cell` oracle (same IR, `state_strategy: Cell`).
pub fn threaded_memory_store_load_roundtrip_e2e_test() {
  let m =
    full(
      "threadedmem",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [
        store_fn("store32", 4),
        load_fn("load32", 4, False, ir.TI32),
        load_fn("load8s", 1, True, ir.TI32),
        load_fn("load16u", 2, False, ir.TI32),
      ],
      [],
      [],
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Ok(st0) = t_instantiate(mod)
  // store a full i32 word at addr 0, threading the record forward, then load it back.
  let assert Ok(#(_, st1)) =
    t_invoke_unit(mod, atom.create("store32"), st0, [0, 305_419_896])
  let assert Ok(#(v, st2)) = t_invoke_int(mod, atom.create("load32"), st1, [0])
  assert v == 305_419_896
  // little-endian + sign-/zero-extension on the width matrix, still threading.
  let assert Ok(#(_, st3)) =
    t_invoke_unit(mod, atom.create("store32"), st2, [0, 4_294_967_168])
  let assert Ok(#(v8, st4)) = t_invoke_int(mod, atom.create("load8s"), st3, [0])
  assert v8 == 4_294_967_168
  let assert Ok(#(v16, _)) = t_invoke_int(mod, atom.create("load16u"), st4, [0])
  assert v16 == 65_408
  // diff vs the Cell oracle — byte-identical observable results (G7).
  let cmod = load(m)
  instantiate(cmod)
  let assert Ok(_) = catch_apply(cmod, atom.create("store32"), [0, 305_419_896])
  assert catch_apply(cmod, atom.create("load32"), [0]) == Ok(305_419_896)
}

/// THREADED `memory.grow`: returns the OLD page count and rebinds the record; a load of the
/// freshly-grown zero region returns `0`; a grow past the declared max returns `-1`.
pub fn threaded_memory_grow_e2e_test() {
  let m =
    full(
      "threadedgrow",
      option.Some(ir.MemoryDecl(1, option.Some(3), ir.Idx32)),
      [],
      [
        ir.Function(
          "grow",
          [ir.Local("d", ir.TI32)],
          [ir.TI32],
          [],
          ir.MemGrow(0, ir.Var("d")),
        ),
        ir.Function("size", [], [ir.TI32], [], ir.MemSize(0)),
        load_fn("load32", 4, False, ir.TI32),
      ],
      [],
      [],
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Ok(st0) = t_instantiate(mod)
  let assert Ok(#(s0, st1)) = t_invoke_int(mod, atom.create("size"), st0, [])
  assert s0 == 1
  // grow(1) returns the OLD page count (1) and rebinds the record.
  let assert Ok(#(old, st2)) = t_invoke_int(mod, atom.create("grow"), st1, [1])
  assert old == 1
  let assert Ok(#(s1, st3)) = t_invoke_int(mod, atom.create("size"), st2, [])
  assert s1 == 2
  // a load of the freshly-grown (zero-filled) region returns 0.
  let assert Ok(#(z, st4)) =
    t_invoke_int(mod, atom.create("load32"), st3, [65_536])
  assert z == 0
  // grow past the declared max (2 + 5 > 3) returns -1 and allocates nothing.
  let assert Ok(#(neg, st5)) = t_invoke_int(mod, atom.create("grow"), st4, [5])
  assert neg == -1
  let assert Ok(#(s2, _)) = t_invoke_int(mod, atom.create("size"), st5, [])
  assert s2 == 2
}

/// THE headline hand-driven proof: a mutable GLOBAL round-trips `global.set`/`global.get`, and
/// state PERSISTS across two invokes THROUGH THE THREADED RECORD (not a pdict cell). The OLD
/// record still reads the OLD value — purely-functional threading (immutable versions). Diffed
/// against the `Cell` oracle.
pub fn threaded_mutable_global_persists_across_invokes_e2e_test() {
  let m =
    full(
      "threadedglobal",
      option.None,
      [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(7)]))],
      [
        ir.Function("get", [], [ir.TI32], [], ir.GlobalGet("g0")),
        ir.Function(
          "set",
          [ir.Local("v", ir.TI32)],
          [],
          [],
          ir.Let([], ir.GlobalSet("g0", ir.Var("v")), ir.Values([])),
        ),
      ],
      [],
      [],
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Ok(st0) = t_instantiate(mod)
  // get reads the constant init 7 (record unchanged).
  let assert Ok(#(v0, st1)) = t_invoke_int(mod, atom.create("get"), st0, [])
  assert v0 == 7
  // set 99 → thread the UPDATED record forward.
  let assert Ok(#(_, st2)) = t_invoke_unit(mod, atom.create("set"), st1, [99])
  // get on the threaded record sees 99 — state PERSISTED across invokes via the value.
  let assert Ok(#(v2, _)) = t_invoke_int(mod, atom.create("get"), st2, [])
  assert v2 == 99
  // the ORIGINAL record st0 STILL reads 7 — the old version was never mutated (functional).
  let assert Ok(#(v_old, _)) = t_invoke_int(mod, atom.create("get"), st0, [])
  assert v_old == 7
  // diff vs the Cell oracle — same observable round-trip (G7).
  let cmod = load(m)
  instantiate(cmod)
  assert catch_apply(cmod, atom.create("get"), []) == Ok(7)
  let assert Ok(_) = catch_apply(cmod, atom.create("set"), [99])
  assert catch_apply(cmod, atom.create("get"), []) == Ok(99)
}

/// THREADED `call_indirect`: dispatch to the right type runs (threading the record through the
/// invoked closure), and each of the three faults traps with the spec reason — never via a
/// data-driven `apply` (the closure `St` is a parameter, not a dispatch key).
pub fn threaded_call_indirect_e2e_test() {
  let inc =
    ir.Function(
      "inc",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(1)]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let callfn =
    ir.Function(
      "callfn",
      [ir.Local("idx", ir.TI32)],
      [ir.TI32],
      [],
      ir.CallIndirect("t0", ir.Var("idx"), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.ConstI32(41),
      ]),
    )
  let callwrong =
    ir.Function(
      "callwrong",
      [ir.Local("idx", ir.TI32)],
      [ir.TI64],
      [],
      ir.CallIndirect("t0", ir.Var("idx"), ir.FuncType([ir.TI64], [ir.TI64]), [
        ir.ConstI64(0),
      ]),
    )
  let m =
    full(
      "threadedci",
      option.None,
      [],
      [inc, callfn, callwrong],
      [ir.TableDecl("t0", ir.FuncRef, 4, option.None)],
      [
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
          ir.FuncRef,
          [ir.RefFunc("inc")],
        ),
      ],
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Ok(st0) = t_instantiate(mod)
  // slot 0 holds `inc` [i32]->[i32]: dispatch runs, threading the record.
  let assert Ok(#(v, st1)) = t_invoke_int(mod, atom.create("callfn"), st0, [0])
  assert v == 42
  // index past the table bound (size 4).
  let assert Error(undef) = t_invoke_int(mod, atom.create("callfn"), st1, [10])
  assert string.contains(undef, "undefined_element")
  // in-bounds but null (uninitialised) slot.
  let assert Error(uninit) = t_invoke_int(mod, atom.create("callfn"), st1, [2])
  assert string.contains(uninit, "uninitialized_element")
  // right slot, wrong expected type ([i64]->[i64] vs the stored [i32]->[i32]).
  let assert Error(mismatch) =
    t_invoke_int(mod, atom.create("callwrong"), st1, [0])
  assert string.contains(mismatch, "indirect_call_type_mismatch")
}

/// An out-of-bounds active DATA segment traps AT INSTANTIATION under `Threaded` too
/// (`instantiate/0` raises "out of bounds memory access" — the record is abandoned).
pub fn threaded_oob_data_segment_traps_at_instantiation_e2e_test() {
  let m =
    full(
      "threadeddataoob",
      option.Some(ir.MemoryDecl(1, option.None, ir.Idx32)),
      [],
      [],
      [],
      [],
      [
        ir.DataSegment(ir.DataActive(0, ir.Values([ir.ConstI32(65_535)])), <<
          1,
          2,
          3,
        >>),
      ],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Error(reason) = t_instantiate(mod)
  assert string.contains(reason, "memory_out_of_bounds")
}

/// An out-of-bounds active ELEMENT segment traps AT INSTANTIATION under `Threaded`
/// (`instantiate/0` raises "out of bounds table access").
pub fn threaded_oob_element_segment_traps_at_instantiation_e2e_test() {
  let target =
    ir.Function(
      "target",
      [ir.Local("p0", ir.TI32)],
      [ir.TI32],
      [],
      ir.Return([ir.Var("p0")]),
    )
  let m =
    full(
      "threadedelemoob",
      option.None,
      [],
      [target],
      [ir.TableDecl("t0", ir.FuncRef, 2, option.None)],
      [
        ir.ElementSegment(
          ir.ElemActive("t0", ir.Values([ir.ConstI32(1)])),
          ir.FuncRef,
          [
            ir.RefFunc("target"),
            ir.RefFunc("target"),
          ],
        ),
      ],
      [],
      option.None,
    )
  let mod = load_threaded(m)
  let assert Error(reason) = t_instantiate(mod)
  assert string.contains(reason, "table_out_of_bounds")
}

// ════════════════════ Phase-5 (P5-06): references / tables / bulk / multi-mem / imports ════════════════════
//
// The P5-06 payoff (unit-doc §"Verification" test 6): hand-built IR3 modules using the new
// reference/table/bulk/multi-memory/import surface compile, instantiate, and RUN spec-correctly on
// the BEAM, under BOTH `Cell` and `Threaded`, with every new trap fail-closing. Results are held
// to the WebAssembly spec (reference-types + bulk-memory proposals, now the living standard).

/// A reference/table module: a funcref table `t0` (size 3), `inc : [i32]->[i32]` placed at slot 0
/// by an active element segment (slots 1,2 null), and functions exercising `ref.func` /
/// `table.set` / `table.get` / `ref.is_null` / `table.grow` / `call_indirect`.
fn reftype_module(name: String) -> ir.Module {
  let inc =
    ir.Function(
      "inc",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.Num(ir.IAdd(ir.W32), [ir.Var("x"), ir.ConstI32(1)]),
        ir.Return([ir.Var("r")]),
      ),
    )
  // `table.get $t0 i` then `ref.is_null` → i32 1 (null slot) / 0 (filled); an OOB index traps.
  let isnull =
    ir.Function(
      "isnull",
      [ir.Local("i", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(["r"], ir.TableGet("t0", ir.Var("i")), ir.RefIsNull(ir.Var("r"))),
    )
  // `call_indirect` through the pre-filled slot 0 (spec-correct dispatch).
  let call0 =
    ir.Function(
      "call0",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.CallIndirect("t0", ir.ConstI32(0), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.Var("x"),
      ]),
    )
  // `ref.func inc` → `table.set` slot 1 → `call_indirect` slot 1 (the set/get round-trip).
  let setcall =
    ir.Function(
      "setcall",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.RefFunc("inc"),
        ir.Let(
          [],
          ir.TableSet("t0", ir.ConstI32(1), ir.Var("r")),
          ir.CallIndirect(
            "t0",
            ir.ConstI32(1),
            ir.FuncType([ir.TI32], [ir.TI32]),
            [ir.Var("x")],
          ),
        ),
      ),
    )
  // `call_indirect` through the null slot 2 → traps UninitializedElement (spec §4.4.6).
  let callnull =
    ir.Function(
      "callnull",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.CallIndirect("t0", ir.ConstI32(2), ir.FuncType([ir.TI32], [ir.TI32]), [
        ir.Var("x"),
      ]),
    )
  // `table.grow(+1, ref.func inc)` → the new slot (at the OLD size) is callable.
  let growcall =
    ir.Function(
      "growcall",
      [ir.Local("x", ir.TI32)],
      [ir.TI32],
      [],
      ir.Let(
        ["r"],
        ir.RefFunc("inc"),
        ir.Let(
          ["old"],
          ir.TableGrow("t0", ir.ConstI32(1), ir.Var("r")),
          ir.CallIndirect(
            "t0",
            ir.Var("old"),
            ir.FuncType([ir.TI32], [ir.TI32]),
            [ir.Var("x")],
          ),
        ),
      ),
    )
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [],
    functions: [inc, isnull, call0, setcall, callnull, growcall],
    exports: [
      ir.ExportFn("isnull", "isnull"),
      ir.ExportFn("call0", "call0"),
      ir.ExportFn("setcall", "setcall"),
      ir.ExportFn("callnull", "callnull"),
      ir.ExportFn("growcall", "growcall"),
    ],
    data_segments: [],
    tables: [ir.TableDecl("t0", ir.FuncRef, 3, option.None)],
    elements: [
      ir.ElementSegment(
        ir.ElemActive("t0", ir.Values([ir.ConstI32(0)])),
        ir.FuncRef,
        [ir.RefFunc("inc")],
      ),
    ],
    start: option.None,
  )
}

/// REFERENCE/TABLE end-to-end (Cell): `ref.func`/`table.set`/`table.get`/`ref.is_null`/
/// `table.grow`/`call_indirect` run spec-correctly, and a null-slot `call_indirect` + an OOB
/// `table.get` fail-closed. Cite reference-types §4.4.6 (`table.get` OOB → `TableOutOfBounds`;
/// a null `call_indirect` slot → `UninitializedElement`; `table.grow` returns the old size).
pub fn reftype_table_e2e_test() {
  let mod = load(reftype_module("reftype"))
  instantiate(mod)
  // slot 0 = inc (not null); slot 1 = null; an OOB get traps.
  assert catch_apply(mod, atom.create("isnull"), [0]) == Ok(0)
  assert catch_apply(mod, atom.create("isnull"), [1]) == Ok(1)
  assert catch_apply(mod, atom.create("call0"), [41]) == Ok(42)
  let assert Error(uninit) = catch_apply(mod, atom.create("callnull"), [7])
  assert string.contains(uninit, "uninitialized_element")
  let assert Error(oob) = catch_apply(mod, atom.create("isnull"), [5])
  assert string.contains(oob, "table_out_of_bounds")
  // set slot 1 = inc, then call it; the slot is now non-null.
  assert catch_apply(mod, atom.create("setcall"), [5]) == Ok(6)
  assert catch_apply(mod, atom.create("isnull"), [1]) == Ok(0)
  // grow(+1, inc) and call the freshly-grown slot.
  assert catch_apply(mod, atom.create("growcall"), [9]) == Ok(10)
}

/// REFERENCE/TABLE end-to-end (Threaded): the SAME program threads the `InstanceState` record
/// through every table op — spec-correct results and the same fail-closed traps as `Cell` (G7).
pub fn reftype_table_threaded_e2e_test() {
  let mod = load_threaded(reftype_module("reftypethreaded"))
  let assert Ok(st0) = t_instantiate(mod)
  let assert Ok(#(a, st1)) = t_invoke_int(mod, atom.create("isnull"), st0, [0])
  assert a == 0
  let assert Ok(#(b, st2)) = t_invoke_int(mod, atom.create("isnull"), st1, [1])
  assert b == 1
  let assert Ok(#(c, st3)) = t_invoke_int(mod, atom.create("call0"), st2, [41])
  assert c == 42
  let assert Error(uninit) =
    t_invoke_int(mod, atom.create("callnull"), st3, [7])
  assert string.contains(uninit, "uninitialized_element")
  let assert Error(oob) = t_invoke_int(mod, atom.create("isnull"), st3, [5])
  assert string.contains(oob, "table_out_of_bounds")
  let assert Ok(#(d, st4)) = t_invoke_int(mod, atom.create("setcall"), st3, [5])
  assert d == 6
  // the threaded record carries the set — slot 1 is now non-null.
  let assert Ok(#(e, st5)) = t_invoke_int(mod, atom.create("isnull"), st4, [1])
  assert e == 0
  let assert Ok(#(g, _)) = t_invoke_int(mod, atom.create("growcall"), st5, [9])
  assert g == 10
}

/// A bulk-memory module: one memory + a PASSIVE data segment `<<1,2,3,4>>`, with
/// `memory.fill`/`memory.copy`/`memory.init`/`data.drop` + byte load/store.
fn bulk_module(name: String) -> ir.Module {
  let store8 = store_fn("store8", 1)
  let load8 = load_fn("load8", 1, False, ir.TI32)
  let fill =
    ir.Function(
      "fill",
      [ir.Local("d", ir.TI32), ir.Local("v", ir.TI32), ir.Local("n", ir.TI32)],
      [],
      [],
      ir.Let(
        [],
        ir.MemFill(0, ir.Var("d"), ir.Var("v"), ir.Var("n")),
        ir.Values([]),
      ),
    )
  let copy =
    ir.Function(
      "copy",
      [ir.Local("d", ir.TI32), ir.Local("s", ir.TI32), ir.Local("n", ir.TI32)],
      [],
      [],
      ir.Let(
        [],
        ir.MemCopy(0, 0, ir.Var("d"), ir.Var("s"), ir.Var("n")),
        ir.Values([]),
      ),
    )
  let meminit =
    ir.Function(
      "meminit",
      [ir.Local("d", ir.TI32), ir.Local("s", ir.TI32), ir.Local("n", ir.TI32)],
      [],
      [],
      ir.Let(
        [],
        ir.MemInit(0, 0, ir.Var("d"), ir.Var("s"), ir.Var("n")),
        ir.Values([]),
      ),
    )
  let dropdata =
    ir.Function(
      "dropdata",
      [],
      [],
      [],
      ir.Let([], ir.DataDrop(0), ir.Values([])),
    )
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [ir.MemoryDecl(1, option.None, ir.Idx32)],
    globals: [],
    imports: [],
    functions: [store8, load8, fill, copy, meminit, dropdata],
    exports: list.map(
      ["store8", "load8", "fill", "copy", "meminit", "dropdata"],
      fn(n) { ir.ExportFn(n, n) },
    ),
    data_segments: [ir.DataSegment(ir.DataPassive, <<1, 2, 3, 4>>)],
    tables: [],
    elements: [],
    start: option.None,
  )
}

/// BULK-MEMORY end-to-end (Cell): `memory.init` from a passive segment writes it; `memory.copy`
/// is overlap-correct; `memory.fill` writes a byte run; `data.drop` then `memory.init` from the
/// dropped segment with non-zero count TRAPS; an out-of-range `memory.fill` traps with no partial
/// write. Cite bulk-memory §4.4.7/§4.4.9 (eager bounds, dropped segment ⇒ length-0).
pub fn bulk_memory_e2e_test() {
  let mod = load(bulk_module("bulk"))
  instantiate(mod)
  // memory.init(dst=10, src=0, n=4) copies the passive segment <<1,2,3,4>> to offset 10.
  let assert Ok(_) = catch_apply(mod, atom.create("meminit"), [10, 0, 4])
  assert catch_apply(mod, atom.create("load8"), [10]) == Ok(1)
  assert catch_apply(mod, atom.create("load8"), [13]) == Ok(4)
  // memory.copy(dst=20, src=10, n=4) is memmove-correct.
  let assert Ok(_) = catch_apply(mod, atom.create("copy"), [20, 10, 4])
  assert catch_apply(mod, atom.create("load8"), [20]) == Ok(1)
  assert catch_apply(mod, atom.create("load8"), [23]) == Ok(4)
  // overlapping forward copy(dst=21, src=20, n=3): <<1,2,3>> → 21,22,23 (memmove, not a naive
  // forward loop which would smear 1s).
  let assert Ok(_) = catch_apply(mod, atom.create("copy"), [21, 20, 3])
  assert catch_apply(mod, atom.create("load8"), [21]) == Ok(1)
  assert catch_apply(mod, atom.create("load8"), [22]) == Ok(2)
  assert catch_apply(mod, atom.create("load8"), [23]) == Ok(3)
  // memory.fill(dest=30, value=0xAB, n=5) writes the low byte.
  let assert Ok(_) = catch_apply(mod, atom.create("fill"), [30, 0xAB, 5])
  assert catch_apply(mod, atom.create("load8"), [30]) == Ok(0xAB)
  assert catch_apply(mod, atom.create("load8"), [34]) == Ok(0xAB)
  // an out-of-range fill traps with no partial write (dest+n > 65536).
  let assert Error(fo) = catch_apply(mod, atom.create("fill"), [65_535, 0, 4])
  assert string.contains(fo, "memory_out_of_bounds")
  // data.drop then memory.init from the dropped (length-0) segment with n>0 traps.
  let assert Ok(_) = catch_apply(mod, atom.create("dropdata"), [])
  let assert Error(di) = catch_apply(mod, atom.create("meminit"), [0, 0, 4])
  assert string.contains(di, "memory_out_of_bounds")
  // n=0 from a dropped segment is a no-op (does NOT trap).
  let assert Ok(_) = catch_apply(mod, atom.create("meminit"), [0, 0, 0])
}

/// BULK-MEMORY end-to-end (Threaded): the SAME bulk ops thread the record; spec-correct writes +
/// the same fail-closed traps as `Cell` (G7).
pub fn bulk_memory_threaded_e2e_test() {
  let mod = load_threaded(bulk_module("bulkthreaded"))
  let assert Ok(st0) = t_instantiate(mod)
  let assert Ok(#(_, st1)) =
    t_invoke_unit(mod, atom.create("meminit"), st0, [10, 0, 4])
  let assert Ok(#(v1, st2)) = t_invoke_int(mod, atom.create("load8"), st1, [10])
  assert v1 == 1
  let assert Ok(#(_, st3)) =
    t_invoke_unit(mod, atom.create("copy"), st2, [20, 10, 4])
  let assert Ok(#(v2, st4)) = t_invoke_int(mod, atom.create("load8"), st3, [23])
  assert v2 == 4
  let assert Ok(#(_, st5)) =
    t_invoke_unit(mod, atom.create("fill"), st4, [30, 0xAB, 5])
  let assert Ok(#(v3, st6)) = t_invoke_int(mod, atom.create("load8"), st5, [34])
  assert v3 == 0xAB
  // data.drop threads the record; a later init from the dropped segment traps.
  let assert Ok(#(_, st7)) =
    t_invoke_unit(mod, atom.create("dropdata"), st6, [])
  let assert Error(di) =
    t_invoke_int(mod, atom.create("meminit"), st7, [0, 0, 4])
  assert string.contains(di, "memory_out_of_bounds")
}

/// A two-memory module: independent i32 store/load on memory 0 and memory 1 + each memory's size.
fn multimem_module(name: String) -> ir.Module {
  let store = fn(fname: String, mem: Int) {
    ir.Function(
      fname,
      [ir.Local("a", ir.TI32), ir.Local("v", ir.TI32)],
      [],
      [],
      ir.Let(
        [],
        ir.MemStore(mem, ir.MemAccess(4, False), ir.Var("a"), ir.Var("v"), 0),
        ir.Values([]),
      ),
    )
  }
  let load = fn(fname: String, mem: Int) {
    ir.Function(
      fname,
      [ir.Local("a", ir.TI32)],
      [ir.TI32],
      [],
      ir.MemLoad(mem, ir.MemAccess(4, False), ir.Var("a"), 0, ir.TI32),
    )
  }
  let fns = [
    store("store0", 0),
    load("load0", 0),
    store("store1", 1),
    load("load1", 1),
    ir.Function("size0", [], [ir.TI32], [], ir.MemSize(0)),
    ir.Function("size1", [], [ir.TI32], [], ir.MemSize(1)),
  ]
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [
      ir.MemoryDecl(1, option.None, ir.Idx32),
      ir.MemoryDecl(2, option.None, ir.Idx32),
    ],
    globals: [],
    imports: [],
    functions: fns,
    exports: list.map(fns, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
  )
}

/// MULTI-MEMORY end-to-end (Cell): a store to memory 1 round-trips from memory 1 and does NOT
/// disturb memory 0; each memory's `memory.size` is independent (memory 0 = 1 page, memory 1 = 2
/// pages, from their distinct declared minimums). Cite H3 (every memory instruction carries a
/// memory index; the memories are independent regions).
pub fn multi_memory_e2e_test() {
  let mod = load(multimem_module("multimem"))
  instantiate(mod)
  // sizes reflect the distinct declared minimums (1 vs 2 pages) → routing is by index.
  assert catch_apply(mod, atom.create("size0"), []) == Ok(1)
  assert catch_apply(mod, atom.create("size1"), []) == Ok(2)
  // store to memory 1; read it back from memory 1; memory 0 at the same address is untouched.
  let assert Ok(_) = catch_apply(mod, atom.create("store1"), [0, 42])
  assert catch_apply(mod, atom.create("load1"), [0]) == Ok(42)
  assert catch_apply(mod, atom.create("load0"), [0]) == Ok(0)
  // store to memory 0; both memories now hold their own value independently.
  let assert Ok(_) = catch_apply(mod, atom.create("store0"), [0, 7])
  assert catch_apply(mod, atom.create("load0"), [0]) == Ok(7)
  assert catch_apply(mod, atom.create("load1"), [0]) == Ok(42)
}

/// MULTI-MEMORY end-to-end (Threaded): the two memories thread through one record independently.
pub fn multi_memory_threaded_e2e_test() {
  let mod = load_threaded(multimem_module("multimemthreaded"))
  let assert Ok(st0) = t_instantiate(mod)
  let assert Ok(#(s0, st1)) = t_invoke_int(mod, atom.create("size0"), st0, [])
  assert s0 == 1
  let assert Ok(#(s1, st2)) = t_invoke_int(mod, atom.create("size1"), st1, [])
  assert s1 == 2
  let assert Ok(#(_, st3)) =
    t_invoke_unit(mod, atom.create("store1"), st2, [0, 42])
  let assert Ok(#(v1, st4)) = t_invoke_int(mod, atom.create("load1"), st3, [0])
  assert v1 == 42
  let assert Ok(#(v0, _)) = t_invoke_int(mod, atom.create("load0"), st4, [0])
  assert v0 == 0
}

/// An import module: imports `spectest.global_i32 : i32` (= 666) and `spectest.memory (1 2)`.
/// The imported global is local name `g0`; the imported memory is memory index 0. Reads the
/// global; stores/loads the imported memory.
fn import_module(name: String) -> ir.Module {
  let read_global =
    ir.Function("read_global", [], [ir.TI32], [], ir.GlobalGet("g0"))
  let store = store_fn("store32", 4)
  let load = load_fn("load32", 4, False, ir.TI32)
  ir.Module(
    name: "twocore@e2e@" <> name,
    uses_numerics: True,
    memories: [],
    globals: [],
    imports: [
      ir.ImportGlobal("spectest", "global_i32", ir.TI32, False),
      ir.ImportMemory("spectest", "memory", 1, option.Some(2), ir.Idx32),
    ],
    functions: [read_global, store, load],
    exports: [
      ir.ExportFn("read_global", "read_global"),
      ir.ExportFn("store32", "store32"),
      ir.ExportFn("load32", "load32"),
    ],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
  )
}

/// IMPORT end-to-end (Cell): a module importing a `spectest` global + memory is linked via
/// `link.link_imports` (fail-closed matching) and instantiated through the generated
/// `instantiate/1(Imports)`; it reads the provided global (`= 666`, the official `spectest`
/// value) and round-trips the provided memory. Cite H4 (imported globals/memories are provided
/// state, wired at the low indices) + R14 (`spectest.global_i32 = 666`).
pub fn import_spectest_e2e_test() {
  let m = import_module("import")
  let mod = load(m)
  let assert Ok(imports) = link.link_imports(m, [])
  let assert Ok(_) =
    catch_apply_dyn(mod, atom.create("instantiate"), [to_dynamic(imports)])
  // the imported global's value is the official spectest 666.
  assert catch_apply(mod, atom.create("read_global"), []) == Ok(666)
  // the imported memory round-trips a store/load.
  let assert Ok(_) = catch_apply(mod, atom.create("store32"), [0, 123_456])
  assert catch_apply(mod, atom.create("load32"), [0]) == Ok(123_456)
}

/// IMPORT end-to-end (Threaded): the same import wiring under `Threaded` — `instantiate/1(Imports)`
/// RETURNS the seeded record, then the reads thread it.
pub fn import_spectest_threaded_e2e_test() {
  let m = import_module("importthreaded")
  let mod = load_threaded(m)
  let assert Ok(imports) = link.link_imports(m, [])
  let assert Ok(st0) = t_instantiate_with(mod, to_dynamic(imports))
  let assert Ok(#(g, st1)) =
    t_invoke_int(mod, atom.create("read_global"), st0, [])
  assert g == 666
  let assert Ok(#(_, st2)) =
    t_invoke_unit(mod, atom.create("store32"), st1, [0, 123_456])
  let assert Ok(#(v, _)) = t_invoke_int(mod, atom.create("load32"), st2, [0])
  assert v == 123_456
}

// Test-only FFI: run `Mod:instantiate(Imports)` (the `instantiate/1` ABI), yielding the threaded
// record or a trap text.
@external(erlang, "twocore_threaded_test_ffi", "instantiate_with")
fn t_instantiate_with(module: Atom, imports: Dynamic) -> Result(Dynamic, String)
