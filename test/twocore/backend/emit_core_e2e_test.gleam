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
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import gleam/string
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance

// Test-only FFI (see `test/twocore_emit_test_ffi.erl`): apply `M:F(Args)` and capture a
// trap / capability-denial as `Error(text)` instead of crashing the test process.
@external(erlang, "twocore_emit_test_ffi", "catch_apply")
fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

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
    memory: option.None,
    globals: [],
    imports: [],
    functions: functions,
    exports: list.map(functions, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
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
